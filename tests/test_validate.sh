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
source "$root/lib/kexec.sh"
pass(){ printf 'PASS %s\n' "$1"; }
validate_mirror_url https://deb.debian.org/debian && pass validate
BOOT_MODE=uefi BOOT_SIZE_MB=1024 SWAP_SIZE_MB=4096; recipe=$(build_recipe); [[ $recipe == *'768 1024 1024 ext4'* ]] && pass recipe
PRIMARY_IFACE=eth0; IPV4_ADDR=192.0.2.1; NETMASK=255.255.255.0; GATEWAY=192.0.2.254; DNS_SERVERS='1.1.1.1'; HOSTNAME=debian; DOMAIN=local; build_cmdline | grep -q 'console=ttyS0,115200n8 console=tty0 ---' && pass kexec
