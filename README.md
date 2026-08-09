# Debian LUKS Reinstall

A Bash tool that kexecs a Debian 13 (trixie) text installer, creates GPT + unencrypted `/boot` and full-disk LUKS/LVM storage, rotates the temporary installer key to the requested passphrase, configures Dropbear remote unlock, and applies SSH, firewall, PAM, sysctl, and unattended-upgrade hardening.

## Warning

This tool irreversibly erases the selected disk. Use it only on a VPS with console or provider recovery access. The final `kexec -e` transfers control to the installer; the current operating system is not restored.

## Requirements

The running system must be:

- Debian-family or another Linux system with Bash and root access.
- amd64.
- A VM or bare-metal host, not an LXC, Docker, OpenVZ, or other container.
- Able to load an unsigned Debian installer kernel with `kexec`.
- Connected through a usable static IPv4 configuration.

Host commands required before the destructive phase include `wget`, `kexec`, `cpio`, `gzip`, `zcat`, `sha256sum`, `awk`, `ip`, `lsblk`, `findmnt`, `blkid`, `openssl`, and `systemd-detect-virt`.

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

A dry run generates and prints the preseed and partition summary without downloading binaries or loading kexec:

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
8. Initrd payload assembly and root-level `preseed.cfg` verification.
9. kexec load.
10. Final `YES` confirmation before disk erasure.
11. Installer execution.

For automation, use `ASSUME_YES=yes` or `--assume-yes`. This bypasses the final destructive confirmation and must not be used without an external approval gate.

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

## Logs and secrets

- Pre-kexec log: configured by `--log-file`, default `/tmp/reinstall-<timestamp>.log` in this implementation.
- Persistent post-install log: `/var/log/vps-postinst.log`.
- Installer secrets are embedded in the RAM-only initrd payload and are removed from the target after the post-install worker exits.
- Logs redact registered passphrases. Never enable global shell tracing.

## Common errors and fixes

### `must run as root`

Run the tool with `sudo` or from a root shell. Do not grant partial capabilities; disk partitioning and kexec require root.

### `kexec cannot run inside a container`

Run the tool from the VPS host or a full VM. Container kernels cannot safely kexec the replacement installer.

### `missing command: kexec` or `missing command: cpio`

Install the host prerequisites using the distribution package manager, then rerun the dry run. Do not proceed until the required command is available.

### `mirror URL validation failed`

Use an HTTPS URL with a valid DNS authority and no userinfo, query, or fragment:

```text
https://deb.debian.org/debian
```

The installer binary download rejects redirects and verifies both downloaded files against `SHA256SUMS`.

### `checksum entries missing` or `checksum verification failed`

Stop. Do not kexec. Check network integrity, mirror availability, suite path, and local disk space. Delete the work directory and retry only after confirming the mirror serves the trixie amd64 netboot files.

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

If the installer fails before reboot, retain the log and use the provider console. If the new system fails to boot, use provider recovery media or console access. Do not attempt ad-hoc partition or LUKS erasure commands on the target disk; preserve the post-install log and LUKS header for diagnosis.
