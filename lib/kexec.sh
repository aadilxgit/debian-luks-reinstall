#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${_REINSTALL_KEXEC_SH:-}" ]]; then return 0; fi
_REINSTALL_KEXEC_SH=1

build_cmdline() {
    : "${PRIMARY_IFACE:?PRIMARY_IFACE is required}"
    : "${IPV4_ADDR:?IPV4_ADDR is required}"
    : "${NETMASK:?NETMASK is required}"
    : "${GATEWAY:?GATEWAY is required}"
    : "${DNS_SERVERS:?DNS_SERVERS is required}"
    : "${HOSTNAME:?HOSTNAME is required}"
    : "${DOMAIN:?DOMAIN is required}"
    local primary_dns="${DNS_SERVERS%% *}"
    CMDLINE="auto=true priority=critical DEBIAN_FRONTEND=newt locale=en_US.UTF-8 keymap=us interface=auto netcfg/choose_interface=auto netcfg/disable_autoconfig=true netcfg/get_ipaddress=$IPV4_ADDR netcfg/get_netmask=$NETMASK netcfg/get_gateway=$GATEWAY netcfg/get_nameservers=$primary_dns netcfg/confirm_static=true netcfg/get_hostname=$HOSTNAME netcfg/get_domain=$DOMAIN preseed/file=/preseed.cfg console=ttyS0,115200n8 console=tty0 ---"
    printf '%s\n' "$CMDLINE"
}

render_partition_tree() {
    printf '%s → [ESP 538–1075M] [/boot %sM ext4] [LUKS→vg_crypt→ root(rest) ext4, swap %sM]\n' "${TARGET_DISK:-<disk>}" "${BOOT_SIZE_MB:-1024}" "${SWAP_SIZE_MB:-4096}"
}

load_kexec() {
    require_cmd kexec
    : "${WORKDIR:?WORKDIR is required}"
    [[ -s "$WORKDIR/linux" ]] || die "installer kernel missing"
    [[ -s "$WORKDIR/initrd.preseed.gz" ]] || die "prepared initrd missing"
    build_cmdline >/dev/null
    run kexec -l "$WORKDIR/linux" --initrd="$WORKDIR/initrd.preseed.gz" --command-line="$CMDLINE"
}

confirm_kexec() {
    local summary
    summary=$(render_partition_tree)
    log_info "network: ${IPV4_ADDR:-} / ${NETMASK:-} via ${GATEWAY:-} (${PRIMARY_IFACE:-})"
    log_info "target: ${TARGET_DISK:-} boot=${BOOT_MODE:-} suite=${DEBIAN_SUITE:-trixie} ports=${DROPBEAR_PORT:-22}/${SSH_PORT:-2222}"
    log_info "partition: $summary"
    [[ "${ASSUME_YES:-no}" == yes ]] && return 0
    confirm_yes "Type YES to wipe ${TARGET_DISK:-target disk} and reinstall"
}

execute_kexec() {
    log_warn "point of no return: executing kexec"
    sync
    kexec -e
}

do_kexec() {
    load_kexec
    confirm_kexec || die "confirmation declined"
    execute_kexec
}
