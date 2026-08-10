#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/lib/common.sh"
source "$root/lib/config.sh"
source "$root/lib/validate.sh"
source "$root/lib/detect.sh"
source "$root/lib/preseed.sh"
source "$root/lib/postinstall.sh"
source "$root/lib/initrd.sh"
source "$root/lib/grub.sh"
pass(){ printf 'PASS %s\n' "$1"; }
validate_mirror_url https://deb.debian.org/debian && pass validate
tmp_cfg=$(mktemp); printf 'TARGET_DISK=/dev/vdb\nSSH_PORT=2222\nASSUME_YES=yes\n' > "$tmp_cfg"
TARGET_DISK= SSH_PORT= ASSUME_YES=; load_config "$tmp_cfg"; rm -f "$tmp_cfg"
[[ $TARGET_DISK == /dev/vdb && $SSH_PORT == 2222 && $ASSUME_YES == yes ]] && pass config-parse
BOOT_MODE=uefi BOOT_SIZE_MB=1024 SWAP_SIZE_MB=4096; recipe=$(build_recipe); [[ $recipe == *'500 768 1024 ext4'* ]] && pass recipe
[[ $recipe != *'$bootable{ }'* ]] && pass recipe-no-bootable-uefi
BOOT_MODE=bios; recipe=$(build_recipe); [[ $recipe == *'$bootable{ } method{ format }'* ]] && pass recipe-bios-bootable
[[ $recipe != *'boot-crypto'* ]] && pass no-bogus-recipe
IPV4_ADDR=192.0.2.1; NETMASK=255.255.255.0; GATEWAY=192.0.2.254; DNS_SERVERS='1.1.1.1'; HOSTNAME=debian; DOMAIN=local; PRIMARY_IFACE=eth0
cmdline=$(build_cmdline)
[[ $cmdline == *'console=ttyS0,115200n8 console=tty0'* ]] && pass serial-console
[[ $cmdline != *'---'* ]] && pass no-trailing-separator
[[ $cmdline == *'net.ifnames=0'* && $cmdline == *'biosdevname=0'* ]] && pass deterministic-naming
[[ $cmdline == *'modprobe.blacklist='*bochs_drm* ]] && pass framebuffer-blacklist
[[ $cmdline == *'preseed/file=/preseed.cfg'* && $cmdline == *'preseed/initrd=true'* ]] && pass preseed-in-initrd
[[ $cmdline == *"ip=192.0.2.1::192.0.2.254:255.255.255.0:debian:eth0:off"* ]] && pass static-ip-param
