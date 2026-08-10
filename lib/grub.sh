#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${_REINSTALL_GRUB_SH:-}" ]]; then return 0; fi
_REINSTALL_GRUB_SH=1

# Boot the netboot installer through GRUB instead of kexec.
#
# Why not kexec: a kexec'd kernel skips firmware re-initialization. On KVM/QEMU
# VPSes (VirtFusion, etc.) the d-i kernel then inherits a dirty display/DRM
# state and hangs right after early boot — the "bochs-drm" freeze seen on the
# VNC console. Both battle-tested reinstall tools (bin456789/reinstall,
# xgungnir/debian-install) boot via a GRUB menuentry + grub-reboot instead,
# and bin456789 even force-disables kexec on providers that enable it.
#
# The cmdline below additionally blacklists every DRM/framebuffer driver so the
# installer renders plain VGA text on the VNC console (xgungnir's direct fix
# for the bochs freeze) and passes a static ip= so initramfs networking is up
# before netcfg runs.

GRUB_LABEL="Debian LUKS reinstall (netboot installer)"
GRUB_ENTRY_FILE=/etc/grub.d/40_debian_installer
GRUB_KERNEL=/boot/debian-installer-vmlinuz
GRUB_INITRD=/boot/debian-installer-initrd.gz

build_cmdline() {
    : "${IPV4_ADDR:?IPV4_ADDR is required}"
    : "${NETMASK:?NETMASK is required}"
    : "${GATEWAY:?GATEWAY is required}"
    : "${HOSTNAME:?HOSTNAME is required}"
    # netcfg/* preseed values live in preseed.cfg; the kernel cmdline only
    # carries what must be effective before the preseed file is loaded
    # (network autoconfiguration, framebuffer blacklist, preseed location).
    CMDLINE="auto=true priority=critical vga=normal nomodeset nofb video=off modprobe.blacklist=cirrus,bochs_drm,qxl,drm,drm_kms_helper,vga16fb,vesafb,vfb,uvesafb console=ttyS0,115200n8 console=tty0 ipv6.disable=0 preseed/file=/preseed.cfg preseed/initrd=true preseed/locale=en_US.UTF-8 DEBIAN_FRONTEND=text netcfg/dhcp_timeout=10 netcfg/choose_interface=auto netcfg/disable_dhcp=true net.ifnames=0 biosdevname=0 ip=${IPV4_ADDR}::${GATEWAY}:${NETMASK}:${HOSTNAME}:eth0:off"
    printf '%s\n' "$CMDLINE"
}

render_partition_tree() {
    printf '%s → [ESP 538–1075M] [/boot %sM ext4] [LUKS→vg_crypt→ root(rest) ext4, swap %sM]\n' "${TARGET_DISK:-<disk>}" "${BOOT_SIZE_MB:-1024}" "${SWAP_SIZE_MB:-4096}"
}

prepare_boot_files() {
    : "${WORKDIR:?WORKDIR is required}"
    require_cmd cp
    [[ -s "$WORKDIR/linux" ]] || die "installer kernel missing"
    [[ -s "$WORKDIR/initrd.preseed.gz" ]] || die "prepared initrd missing"
    cp -f "$WORKDIR/linux" "$GRUB_KERNEL"
    cp -f "$WORKDIR/initrd.preseed.gz" "$GRUB_INITRD"
    chmod 0644 "$GRUB_KERNEL" "$GRUB_INITRD"
    log_info "staged installer kernel/initrd: $GRUB_KERNEL, $GRUB_INITRD"
}

# Write /etc/grub.d/40_debian_installer and regenerate the boot menu. Returns
# the grub.cfg path in REPLY.
install_grub_entry() {
    require_cmd findmnt blkid
    : "${WORKDIR:?WORKDIR is required}"
    [[ -s "$GRUB_KERNEL" ]] || die "installer kernel not staged (run prepare_boot_files first)"
    [[ -s "$GRUB_INITRD" ]] || die "installer initrd not staged (run prepare_boot_files first)"

    local boot_part boot_uuid boot_fs grub_dev fs_mod root_block
    local separate_boot kernel_path initrd_path
    if findmnt -no SOURCE /boot >/dev/null 2>&1; then
        boot_part=$(findmnt -no SOURCE /boot)
        separate_boot=1
    else
        boot_part=$(findmnt -no SOURCE /)
        separate_boot=0
    fi
    [[ -n $boot_part ]] || die "cannot determine boot filesystem"

    boot_uuid=$(blkid -s UUID -o value "$boot_part" 2>/dev/null || true)
    boot_fs=$(blkid -s TYPE -o value "$boot_part" 2>/dev/null || true)
    case "$boot_fs" in
        ext2|ext3|ext4) fs_mod=ext2 ;;
        xfs) fs_mod=xfs ;;
        btrfs) fs_mod=btrfs ;;
        vfat|fat|msdos) fs_mod=fat ;;
        f2fs) fs_mod=f2fs ;;
        *) fs_mod=ext2 ;;
    esac

    grub_dev=''
    if [[ $boot_part =~ ^/dev/ ]]; then
        local num=${boot_part##*[^0-9]}
        [[ $num =~ ^[0-9]+$ ]] && grub_dev="(hd0,$num)"
    fi
    [[ -n $boot_uuid || -n $grub_dev ]] || die "cannot locate boot filesystem for GRUB (no UUID and no partition number for $boot_part)"

    if [[ $separate_boot == 1 ]]; then
        kernel_path=/debian-installer-vmlinuz
        initrd_path=/debian-installer-initrd.gz
    else
        kernel_path=$GRUB_KERNEL
        initrd_path=$GRUB_INITRD
    fi

    local lvm_insmod=''
    [[ $boot_part == /dev/mapper/* ]] && lvm_insmod=$'    insmod lvm\n    insmod lvm2'

    if [[ -n $boot_uuid && -n $grub_dev ]]; then
        root_block="    if search --no-floppy --fs-uuid --set=root $boot_uuid; then
        true
    else
        set root='$grub_dev'
    fi"
    elif [[ -n $boot_uuid ]]; then
        root_block="    search --no-floppy --fs-uuid --set=root $boot_uuid"
    else
        root_block="    set root='$grub_dev'"
    fi

    build_cmdline >/dev/null
    cat >"$GRUB_ENTRY_FILE" <<EOF
#!/bin/sh
set -e
cat <<GRUB_EOF
menuentry '$GRUB_LABEL' {
    insmod part_gpt
    insmod part_msdos
    insmod $fs_mod
    insmod search_fs_uuid
${lvm_insmod}
    set gfxpayload=text
${root_block}
    echo "Loading Debian installer (netboot) ..."
    linux $kernel_path $CMDLINE
    initrd $initrd_path
}
GRUB_EOF
EOF
    chmod 0755 "$GRUB_ENTRY_FILE"

    local update_cmd cfg
    if command -v update-grub >/dev/null 2>&1; then
        update_cmd=(update-grub)
        cfg=${GRUB_CFG_FILE:-/boot/grub/grub.cfg}
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        update_cmd=(grub2-mkconfig -o "${GRUB_CFG_FILE:-/boot/grub2/grub.cfg}")
        cfg=${GRUB_CFG_FILE:-/boot/grub2/grub.cfg}
    else
        die "GRUB tooling missing (need update-grub or grub2-mkconfig; install grub2-common)"
    fi
    run "${update_cmd[@]}"
    if ! grep -q "menuentry '$GRUB_LABEL'" "$cfg"; then
        die "GRUB entry '$GRUB_LABEL' missing from $cfg after regeneration"
        return 1
    fi
    REPLY=$cfg
}

set_one_time_boot() {
    require_cmd grub-editenv
    local reboot_cmd
    if command -v grub-reboot >/dev/null 2>&1; then
        reboot_cmd=grub-reboot
    elif command -v grub2-reboot >/dev/null 2>&1; then
        reboot_cmd=grub2-reboot
    else
        die "missing grub-reboot/grub2-reboot (install grub2-common)"
    fi
    run "$reboot_cmd" "$GRUB_LABEL"
    grub-editenv list 2>/dev/null | grep -q '^next_entry=' \
        && log_info "one-time boot target set: next_entry -> $GRUB_LABEL" \
        || log_warn "grub-reboot ran but grubenv next_entry is unset; the installer entry will not auto-select"
}

remove_grub_entry() {
    log_step "removing GRUB installer entry"
    rm -f "$GRUB_ENTRY_FILE" "$GRUB_KERNEL" "$GRUB_INITRD"
    if command -v grub-editenv >/dev/null 2>&1; then
        grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null \
            || grub-editenv /boot/grub2/grubenv unset next_entry 2>/dev/null \
            || true
    fi
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null 2>&1 || true
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true
    fi
    log_info "GRUB installer entry, staged kernel/initrd, and next_entry cleared"
}

confirm_boot() {
    local summary
    summary=$(render_partition_tree)
    log_info "network: ${IPV4_ADDR:-} / ${NETMASK:-} via ${GATEWAY:-} (${PRIMARY_IFACE:-})"
    log_info "target: ${TARGET_DISK:-} boot=${BOOT_MODE:-} suite=${DEBIAN_SUITE:-trixie} ports=${DROPBEAR_PORT:-22}/${SSH_PORT:-2222}"
    log_info "partition: $summary"
    log_info "after the reboot, watch the VNC console: the installer boots in plain text mode"
    [[ "${ASSUME_YES:-no}" == yes ]] && return 0
    confirm_yes "Type YES to wipe ${TARGET_DISK:-target disk} and reinstall"
}

execute_reboot() {
    log_warn "point of no return: rebooting into the installer"
    sync
    reboot
}

do_grub_boot() {
    prepare_boot_files
    install_grub_entry
    set_one_time_boot
    confirm_boot || die "confirmation declined"
    execute_reboot
}
