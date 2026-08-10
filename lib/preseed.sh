#!/usr/bin/env bash
set -euo pipefail
[[ ${_PRESEED_SH_LOADED:-0} == 1 ]] && return 0
_PRESEED_SH_LOADED=1

# partman expert recipe, shaped after the official d-i manual's crypto example
# (partman-auto-crypto is tested against that shape). Key points:
#  - the LUKS partition line carries NO $primary{ } (GPT is forced anyway)
#  - minimum sizes are small so the recipe fits small VPS disks; if it does
#    not fit, partman falls back to the stock 'atomic' recipe (choose_recipe)
#    instead of an interactive prompt
build_recipe(){
    local lead bootable=''
    if [[ $BOOT_MODE == uefi ]]; then
        lead='538 538 1075 free $iflabel{ gpt } $reusemethod{ } method{ efi } format{ } .'
    else
        lead='1 1 1 free $iflabel{ gpt } $reusemethod{ } method{ biosgrub } .'
        bootable='$bootable{ }'
    fi
    printf '%s 500 768 %s ext4 $defaultignore{ } $primary{ } %s method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ /boot } . 1500 2000 -1 ext4 method{ crypto } vg_name{ vg_crypt } . 512 %s %s linux-swap $lvmok{ } in_vg{ vg_crypt } lv_name{ swap } method{ swap } format{ } . 3000 10000 -1 ext4 $lvmok{ } in_vg{ vg_crypt } lv_name{ root } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ / } .' "$lead" "$BOOT_SIZE_MB" "$bootable" "$SWAP_SIZE_MB" "$SWAP_SIZE_MB"
}

# Kernel-module/entropy priming for the installer: on KVM the entropy pool is
# empty at start, and cryptsetup luksFormat reads /dev/random, which stalls the
# partitioner mid-way. Idempotent via a marker file.
build_early_command() {
    printf '%s' 'if [ ! -e /run/reinstall-early.done ]; then touch /run/reinstall-early.done; modprobe dm-mod 2>/dev/null || true; modprobe dm-crypt 2>/dev/null || true; modprobe aes 2>/dev/null || true; modprobe xts 2>/dev/null || true; dd if=/dev/urandom of=/dev/random bs=512 count=8 2>/dev/null || true; fi'
}

# Runs when partman starts: re-assert the guided/disk settings (d-i consumes
# them from the preseed), load haveged for entropy, and strip leftover
# partition signatures so autopartition-crypto starts from a clean disk.
build_partman_early_command() {
    local disk=${1:-}
    printf '%s' "debconf-set partman-auto/init_automatically_partition use_device; debconf-set partman-auto/select_disk \"$disk\"; debconf-set partman-auto/disk \"$disk\"; anna-install haveged-udeb >/dev/null 2>&1 || true; if command -v haveged >/dev/null 2>&1; then haveged -w 1024 >/var/log/haveged.log 2>&1 || true; fi; wipefs -a \"$disk\" 2>/dev/null || true; blockdev --rereadpt \"$disk\" 2>/dev/null || true"
}

build_preseed(){
    local tmp=$1 crypt=$2 early_cmd partman_early
    local mirror_host=${MIRROR#https://} mirror_dir=/debian
    if [[ $mirror_host == */* ]]; then mirror_dir=/${mirror_host#*/}; mirror_host=${mirror_host%%/*}; fi
    early_cmd=$(build_early_command)
    partman_early=$(build_partman_early_command "$TARGET_DISK")
    mkdir -p "$WORKDIR"
    cat >"$WORKDIR/preseed.cfg" <<EOF
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/dhcp_failed note
d-i netcfg/dhcp_options select Configure network manually
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_ipaddress string $IPV4_ADDR
d-i netcfg/get_netmask string $NETMASK
d-i netcfg/get_gateway string $GATEWAY
d-i netcfg/get_nameservers string $DNS_SERVERS
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string $HOSTNAME
d-i netcfg/get_domain string $DOMAIN
d-i mirror/country string manual
d-i mirror/protocol string http
d-i mirror/http/hostname string $mirror_host
d-i mirror/http/directory string $mirror_dir
d-i mirror/http/proxy string
d-i mirror/suite string $DEBIAN_SUITE
d-i passwd/make-user boolean true
d-i passwd/user-fullname string $ADMIN_USER
d-i passwd/username string $ADMIN_USER
d-i passwd/user-password-crypted password $crypt
d-i clock-setup/utc boolean true
d-i time/zone string $TIMEZONE
d-i clock-setup/ntp boolean true
# Preload the crypto/LVM/entropy installer components so guided crypto
# partitioning never falls back to interactive module selection.
d-i anna/choose_modules string partman-crypto partman-crypto-dm crypto-dm-modules dm-crypt-module partman-auto partman-auto-lvm partman-auto-crypto lvm2-udeb haveged-udeb
d-i preseed/early_command string $early_cmd
d-i partman-auto/method string crypto
d-i partman-auto/disk string $TARGET_DISK
d-i partman-auto/init_automatically_partition select use_device
# 'atomic' is a real stock recipe; 'boot-crypto' does not exist in
# partman-auto. It is only a fallback when the expert recipe below does not
# fit, but a nonexistent name turns that fallback into a hung interactive
# prompt on small disks.
d-i partman-auto/choose_recipe select atomic
d-i partman-auto/expert_recipe string $(build_recipe)
d-i partman-auto-lvm/guided_size string max
d-i partman-auto-lvm/new_vg_name string vg_crypt
d-i partman-auto/purge_lvm_from_device boolean true
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-md/confirm boolean true
d-i partman-md/confirm_nooverwrite boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-crypto/device_remove_crypto boolean true
d-i partman-crypto/passphrase password $tmp
d-i partman-crypto/passphrase-again password $tmp
d-i partman-crypto/weak_passphrase boolean true
d-i partman-crypto/confirm boolean true
d-i partman-crypto/confirm_nooverwrite boolean true
d-i partman-auto-crypto/erase_disks boolean false
d-i partman/early_command string $partman_early
d-i partman/mount_style select uuid
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman-partitioning/confirm_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
$( [[ $BOOT_MODE == uefi ]] && echo 'd-i partman-efi/non_efi_system boolean true' )
d-i base-installer/install-recommends boolean false
d-i apt-setup/non-free-firmware boolean true
tasksel tasksel/first multiselect standard
d-i pkgsel/include string cryptsetup cryptsetup-initramfs dropbear-initramfs lvm2 sudo ufw fail2ban python3-systemd unattended-upgrades apt-listchanges openssh-server ca-certificates
d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string $TARGET_DISK
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string /opt/reinstall/late.sh < /dev/null > /target/var/log/vps-postinst.log 2>&1
EOF
}
