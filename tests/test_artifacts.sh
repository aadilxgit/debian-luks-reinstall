#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
count=$(awk '/^build_preseed\(\)/{n++} END{print n+0}' "$root/lib/preseed.sh")
[[ $count -eq 1 ]] || { echo "expected one build_preseed, got $count"; exit 1; }
grep -q 'payload/opt/reinstall/late.sh' "$root/lib/initrd.sh" || { echo 'initrd source path missing'; exit 1; }
! grep -q 'WORKDIR/late.sh' "$root/lib/initrd.sh" || { echo 'stale top-level path'; exit 1; }
grep -q 'restrict,command="/bin/cryptroot-unlock"' "$root/lib/postinstall.sh"
grep -q 'GRUB_CMDLINE_LINUX="ip=' "$root/lib/postinstall.sh"
grep -q '50unattended-upgrades' "$root/lib/postinstall.sh"
grep -q 'pam_faillock.so' "$root/lib/postinstall.sh"
grep -q 'net.ipv6.conf.default.accept_ra = 0' "$root/lib/postinstall.sh"
! grep -q '^ d-i debian-installer/locale' "$root/lib/preseed.sh"
grep -q 'choose_recipe select atomic' "$root/lib/preseed.sh" || { echo 'valid choose_recipe fallback missing'; exit 1; }
! grep -q 'choose_recipe select boot-crypto' "$root/lib/preseed.sh" || { echo 'bogus boot-crypto recipe still present'; exit 1; }
grep -q 'partman-auto/init_automatically_partition select use_device' "$root/lib/preseed.sh" || { echo 'guided disk selection missing'; exit 1; }
grep -q 'partman/mount_style select uuid' "$root/lib/preseed.sh" || { echo 'uuid mount style missing'; exit 1; }
grep -q 'preseed/early_command' "$root/lib/preseed.sh" || { echo 'early_command (entropy) missing'; exit 1; }
grep -q 'anna/choose_modules' "$root/lib/preseed.sh" || { echo 'anna module preload missing'; exit 1; }
grep -q 'grub-reboot' "$root/lib/grub.sh" || { echo 'grub-reboot missing'; exit 1; }
grep -q '40_debian_installer' "$root/lib/grub.sh" || { echo 'grub.d entry missing'; exit 1; }
grep -q 'modprobe.blacklist=cirrus,bochs_drm' "$root/lib/grub.sh" || { echo 'framebuffer blacklist missing'; exit 1; }
! grep -Eq 'kexec -[elf]|do_kexec|load_kexec|execute_kexec' "$root/reinstall.sh" "$root/lib"/*.sh || { echo 'kexec boot code remains'; exit 1; }
