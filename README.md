# Debian LUKS Reinstall

A Bash tool that boots a Debian 13 (trixie) netboot installer through a **one-time GRUB entry** (no kexec), creates GPT + unencrypted `/boot` and full-disk LUKS/LVM storage, rotates the temporary installer key to the requested passphrase, configures Dropbear remote unlock, and applies SSH, firewall, PAM, sysctl, and unattended-upgrade hardening.

## Warning

This tool irreversibly erases the selected disk. Use it only on a VPS with console or provider recovery access. The final reboot transfers control to the installer; the current operating system is not restored.

## Why GRUB instead of kexec

The original version booted the installer with `kexec -e`. On KVM/QEMU VPSes (VirtFusion, etc.) a kexec'd kernel skips firmware re-initialization, inherits a dirty display/DRM state, and hangs right after early boot — the VNC console freezes on the `bochs-drmfb` messages with no userspace output. This is a documented failure class of kexec on KVM, which is why the battle-tested reinstall tools (**bin456789/reinstall**, **xgungnir/debian-install**) boot the installer via GRUB instead, and bin456789 even force-disables kexec on providers that enable it.

This tool now does the same:

1. Stages the verified installer kernel/initrd as `/boot/debian-installer-vmlinuz` and `/boot/debian-installer-initrd.gz`.
2. Writes an executable `/etc/grub.d/40_debian_installer` entry (`insmod` for the boot filesystem, `search --fs-uuid` with `(hd0,N)` fallback, `gfxpayload=text`).
3. Regenerates `grub.cfg`, verifies the entry is present, then sets it as the one-time boot target with `grub-reboot` / `grub2-reboot` (grubenv `next_entry`).
4. Reboots. The provider boots the installer entry once; a failed run can be undone with `./reinstall.sh --reset` (removes the entry, staged files, and `next_entry`).

The installer cmdline additionally blacklists every DRM/framebuffer driver (`modprobe.blacklist=cirrus,bochs_drm,qxl,drm,drm_kms_helper,vga16fb,vesafb,vfb,uvesafb`, `nomodeset nofb video=off`) and uses `DEBIAN_FRONTEND=text`, so the installer renders plain VGA text on the VNC console — this is the direct fix for the bochs freeze seen on VirtFusion.

## Requirements

The running system must be:

- Debian-family or another Linux system with Bash and root access.
- amd64.
- A VM or bare-metal host, not an LXC, Docker, OpenVZ, or other container.
- Booted by GRUB (the tool stages a GRUB entry; `grub-reboot` or `grub2-reboot` must exist, from `grub2-common`).
- Connected through a usable static IPv4 configuration.

Host commands required before the destructive phase include `wget`, `cpio`, `gzip`, `zcat`, `find`, `sha256sum`, `awk`, `ip`, `lsblk`, `findmnt`, `blkid`, `openssl`, `update-grub` (or `grub2-mkconfig`), `grub-reboot` (or `grub2-reboot`), `grub-editenv`, and `systemd-detect-virt`.

### KVM VPS console

The installer cmdline keeps both consoles:

```text
console=ttyS0,115200n8 console=tty0
```

With the framebuffer drivers blacklisted, the VNC console shows the installer in text mode instead of freezing after the `bochs-drm` messages. If the web/VNC console still stops updating, connect to the provider's serial console before interrupting the install.

## Quick Start & Setup

Clone the repository on your remote VPS:

```bash
git clone https://github.com/aadilxgit/debian-luks-reinstall.git
cd debian-luks-reinstall
```

Copy the example configuration file and edit it:

```bash
cp reinstall.conf.example reinstall.conf
chmod 600 reinstall.conf
editor reinstall.conf
```

At minimum set:

```bash
TARGET_DISK="/dev/vda"
PRIMARY_IFACE="eth0"
IPV4_ADDR="203.0.113.10"
NETMASK="255.255.255.0"
GATEWAY="203.0.113.1"
DNS_SERVERS="1.1.1.1 8.8.8.8"
ADMIN_SSH_PUBKEY="ssh-ed25519 AAAA... operator"
```

`ADMIN_SSH_PUBKEY_FILE` may provide additional keys. The tool merges and validates both sources. `LUKS_PASSPHRASE` is preferably entered interactively or supplied through the environment; it must be at least eight characters.

Configuration precedence is:

1. Interactive confirmation and edits.
2. Environment variables.
3. Explicit or auto-loaded configuration file.
4. Hardware and network detection.
5. Built-in defaults.

The tool searches `--config FILE`, `$REINSTALL_CONF`, `./reinstall.conf`, and `/etc/reinstall.conf`. Configuration is parsed as allowlisted `KEY=VALUE` data; it is never sourced as shell code.

## Dry run

A dry run generates and prints the partition plan, preseed, and installer cmdline without downloading binaries or touching GRUB:

```bash
sudo ./reinstall.sh --dry-run --config reinstall.conf --log-file /tmp/reinstall.log
```

Review the target disk, interface, address, boot mode, ports, and generated preseed. Confirm that the passphrase does not appear in output or logs.

## Execute

Run from this directory:

```bash
sudo ./reinstall.sh --config reinstall.conf --log-file /var/log/reinstall.log
```

The sequence is:

1. Root and command preflight.
2. Container rejection.
3. Hardware/network detection and configuration confirmation.
4. Passphrase confirmation.
5. Preseed and post-install artifact generation.
6. HTTPS installer download.
7. SHA256 verification of kernel and initrd.
8. Initrd repack with the preseed payload embedded, verified with `cpio -t`.
9. GRUB entry staged (`/etc/grub.d/40_debian_installer`), menu regenerated, entry presence verified.
10. `grub-reboot` sets the one-time boot target; `grubenv next_entry` is verified.
11. Final `YES` confirmation before disk erasure.
12. Reboot into the installer. Watch the VNC console: it runs in plain text mode.

For automation, use `ASSUME_YES=yes` or `--assume-yes`. This bypasses the final destructive confirmation and must not be used without an external approval gate.

## Reset / cancel

To abort a staged run before it boots (or clean up after a failed attempt):

```bash
sudo ./reinstall.sh --reset
```

Removes `/etc/grub.d/40_debian_installer`, the staged `/boot/debian-installer-*` files, clears `grubenv next_entry`, and regenerates the GRUB menu.

## After installation

The installer uses the temporary random LUKS key only during installation. The post-install worker adds the user passphrase, verifies it with `cryptsetup open --test-passphrase`, and removes the temporary key only after verification succeeds.

Unlock the encrypted root remotely through Dropbear on port 22:

```bash
ssh -p 22 root@203.0.113.10
```

The authorized key runs `/bin/cryptroot-unlock`. After the system boots, connect to OpenSSH on the configured port, default 2222:

```bash
ssh -p 2222 admin@203.0.113.10
```

Root SSH login and password authentication are disabled. Keep a second console or SSH session available while validating access.

The installed system inherits the static network from the installer cmdline: the boot cmdline carries `ip=<addr>::<gw>:<mask>::eth0:off net.ifnames=0 biosdevname=0` (via `/etc/default/grub.d/90-netboot.cfg`), so the initramfs network and Dropbear unlock use `eth0` deterministically. `late_command` also rebuilds `/target/etc/fstab` from actual block-device UUIDs (old file kept as `fstab.reinstall.bak`), and on UEFI installs writes the ESP fallback path `EFI/BOOT/BOOTX64.EFI` (`grub-install --removable`) so the box boots even if the provider firmware ignores NVRAM entries.

## Logs and secrets

- Pre-reboot log: configured by `--log-file`, default `/tmp/reinstall-<timestamp>.log`.
- Persistent post-install log: `/var/log/vps-postinst.log`.
- Installer secrets are embedded in the RAM-only initrd payload and are removed from the target after the post-install worker exits.
- Logs redact registered passphrases. Never enable global shell tracing.

## Common errors and fixes

### `must run as root`

Run the tool with `sudo` or from a root shell. Do not grant partial capabilities; disk partitioning and GRUB updates require root.

### `cannot reinstall from inside a container`

Run the tool from the VPS host or a full VM.

### `missing command: grub-reboot` or `missing command: update-grub`

Install the host prerequisites (`grub2-common` on Debian/Ubuntu), then rerun the dry run. Do not proceed until the required command is available.

### `GRUB entry 'Debian LUKS reinstall (netboot installer)' missing from ...`

The menu regeneration did not include the staged entry. Check that `/etc/grub.d/40_debian_installer` is executable and that GRUB reads `/boot/grub/grub.cfg`; then run `./reinstall.sh --reset` and retry.

### `mirror URL validation failed`

Use an HTTPS URL with a valid DNS authority and no userinfo, query, or fragment:

```text
https://deb.debian.org/debian
```

The installer binary download rejects redirects and verifies both downloaded files against `SHA256SUMS`.

### `checksum entries missing` or `checksum verification failed`

Stop. Do not reboot. Check network integrity, mirror availability, suite path, and local disk space. Delete the work directory and retry only after confirming the mirror serves the trixie amd64 netboot files.

### `at least one valid SSH public key is required`

Set `ADMIN_SSH_PUBKEY` or `ADMIN_SSH_PUBKEY_FILE` to a complete `ssh-ed25519`, `ssh-rsa`, or ECDSA public key. Do not use a private key.

### Dropbear does not listen after reboot

Verify the configured NIC module, static `ip=` command line, and initramfs contents from the provider console. The target must include the NIC driver in `/etc/initramfs-tools/modules`, then run:

```bash
update-initramfs -u -k all
update-grub
```

### SSH still listens on port 22

Debian trixie uses `ssh.socket`. The post-install worker disables the socket and enables `ssh.service`. From the console verify:

```bash
systemctl is-enabled ssh.socket ssh.service
sshd -T | grep -E '^(port|allowusers|permitrootlogin|passwordauthentication)'
```

### LUKS unlock fails

Do not remove or erase LUKS keyslots manually. Use the provider console, inspect `/var/log/vps-postinst.log`, and confirm that the post-install sequence completed add, verify, then remove. The tool uses exact passphrase bytes with `printf '%s'`, without a trailing newline.

### Fail2ban reports no log path

Debian trixie uses the systemd journal by default. The generated jail sets `backend = systemd` and requires `python3-systemd`; do not add an `/var/log/auth.log` path unless rsyslog is intentionally installed.

## Verification

Run the non-destructive checks before release:

```bash
bash -n reinstall.sh lib/*.sh tests/*.sh
bash tests/test_artifacts.sh
bash tests/test_validate.sh
bash tests/run.sh
```

Never use `kexec -e` as a verification command. Use the dry run and provider console to validate configuration before the final confirmation.

## Recovery

If the installer fails before reboot, run `./reinstall.sh --reset` from the still-running system and retain the log. If the new system fails to boot, use provider recovery media or console access. Do not attempt ad-hoc partition or LUKS erasure commands on the target disk; preserve the post-install log and LUKS header for diagnosis.
