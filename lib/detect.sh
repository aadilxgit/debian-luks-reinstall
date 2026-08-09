#!/usr/bin/env bash
set -euo pipefail
[[ ${_REINSTALL_DETECT_SH:-0} == 1 ]] && return 0
_REINSTALL_DETECT_SH=1

route_parse() { [[ $1 =~ default[[:space:]]+via[[:space:]]+([^[:space:]]+)[[:space:]]+dev[[:space:]]+([^[:space:]]+) ]] || return 1; GATEWAY=${BASH_REMATCH[1]}; PRIMARY_IFACE=${BASH_REMATCH[2]%%@*}; }
addr_parse() { [[ $1 =~ inet[[:space:]]+([0-9.]+)/([0-9]+) ]] || return 1; IPV4_ADDR=${BASH_REMATCH[1]}; prefix_to_netmask "${BASH_REMATCH[2]}"; NETMASK=$REPLY; }
prefix_to_netmask() { local p=$1 n=$((p)); (( n>=0 && n<=32 )) || return 1; local out='' i oct; for i in 1 2 3 4; do (( n>=8 )) && oct=255 || { ((n>0)) && oct=$((256-2**(8-n))) || oct=0; }; out+="${out:+.}$oct"; (( n>8 )) && n=$((n-8)) || n=0; done; REPLY=$out; }
dns_parse() { DNS_SERVERS=$(awk '/^[[:space:]]*nameserver[[:space:]]+/{print $2}' <<<"$1" | tr '\n' ' '); DNS_SERVERS=${DNS_SERVERS% }; }
disk_parse() { local src pk; src=$(awk 'NF{print $1; exit}' <<<"$1"); pk=$(awk 'NF{print $1; exit}' <<<"$2"); TARGET_DISK=${pk:+/dev/$pk}; [[ -n $TARGET_DISK ]] || TARGET_DISK=$src; }
route_collect() { local o iface physical; o=$(ip -4 route show default); route_parse "$o"; iface=$PRIMARY_IFACE; if [[ $iface =~ ^(docker|veth|br-|virbr|tun|tap|wg|flannel|tailscale|lo|kube|cni|zt) ]]; then while IFS= read -r physical; do [[ -e /sys/class/net/${physical%%@*}/device ]] && { PRIMARY_IFACE=${physical%%@*}; break; }; done < <(ip -o link show | awk -F': ' '{print $2}'); fi; }
addr_collect() { local o; o=$(ip -4 -o addr show dev "$PRIMARY_IFACE"); addr_parse "$o"; }
dns_collect() { local o; if [[ -r /etc/resolv.conf ]]; then o=$(cat /etc/resolv.conf); dns_parse "$o"; fi; [[ -n ${DNS_SERVERS:-} ]] || DNS_SERVERS="1.1.1.1 1.0.0.1"; }
boot_collect() { [[ -d /sys/firmware/efi ]] && BOOT_MODE=uefi || BOOT_MODE=bios; }
disk_collect() { local src pk; src=$(findmnt -no SOURCE /); pk=$(lsblk -no PKNAME "$src" | head -n1); if [[ -n $pk ]]; then TARGET_DISK=/dev/$pk; else TARGET_DISK=$src; fi; }
nic_collect() { local p; p=$(readlink -f "/sys/class/net/$PRIMARY_IFACE/device/driver/module" 2>/dev/null || true); NIC_MODULE=${p##*/}; }
ipv6_collect() { local r a; r=$(ip -6 route show default 2>/dev/null || true); if [[ $r =~ default[[:space:]]+via[[:space:]]+([^[:space:]]+) ]]; then IPV6_GATEWAY=${BASH_REMATCH[1]}; fi; a=$(ip -6 -o addr show dev "${PRIMARY_IFACE:-eth0}" scope global 2>/dev/null | head -n1 || true); if [[ $a =~ inet6[[:space:]]+([0-9a-fA-F:]+)/([0-9]+) ]]; then IPV6_ADDR=${BASH_REMATCH[1]}; IPV6_PREFIX=${BASH_REMATCH[2]}; fi; }
guard_virtualization() { if command -v systemd-detect-virt >/dev/null 2>&1; then if systemd-detect-virt --container >/dev/null 2>&1; then die "kexec cannot run inside a container ($(systemd-detect-virt)); aborting."; fi; else if [[ -e /proc/vz || $(tr '\0' '\n' </proc/1/environ) == *container=* ]]; then die "kexec cannot run inside a container; aborting."; fi; fi; }
detect_collect() { [[ -n $PRIMARY_IFACE ]] || route_collect; [[ -n $IPV4_ADDR ]] || addr_collect; [[ -n $BOOT_MODE ]] || boot_collect; [[ -n $DNS_SERVERS ]] || dns_collect; [[ -n $TARGET_DISK ]] || disk_collect; [[ -n $NIC_MODULE ]] || nic_collect; [[ -n $IPV6_ADDR ]] || ipv6_collect; }
