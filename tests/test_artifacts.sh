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
