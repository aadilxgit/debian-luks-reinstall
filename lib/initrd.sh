#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${_REINSTALL_INITRD_SH:-}" ]]; then return 0; fi
_REINSTALL_INITRD_SH=1

# Build the offline installer payload (preseed.cfg + post-install scripts) and
# embed it into a REPACKED copy of the netboot initrd.
#
# Repacking (unpack -> add files -> cpio newc + gzip) is what the battle-tested
# reinstall tools do (bin456789/reinstall, xgungnir/debian-install). Appending
# a second gzip member works in the kernel, but repacking also normalizes file
# ownership/modes, so the embedded files are exactly what we staged.

build_payload() {
    : "${WORKDIR:?WORKDIR is required}"
    require_cmd find cpio gzip zcat cp chmod rm mkdir
    local payload="$WORKDIR/payload" artifacts="$WORKDIR/payload/opt/reinstall" root="$WORKDIR/initrd-root"
    mkdir -p "$payload/opt/reinstall"
    [[ -s "$WORKDIR/preseed.cfg" ]] || die "preseed.cfg missing or empty"
    [[ -s "$artifacts/late.sh" ]] || die "late.sh missing or empty"
    [[ -s "$artifacts/postinstall.sh" ]] || die "postinstall.sh missing or empty"
    [[ -s "$artifacts/secrets.env" ]] || die "secrets.env missing or empty"
    [[ -s "$WORKDIR/initrd.gz" ]] || die "downloaded initrd.gz missing"
    cp "$WORKDIR/preseed.cfg" "$payload/preseed.cfg"
    chmod 0644 "$payload/preseed.cfg"
    chmod 0700 "$payload/opt/reinstall/late.sh" "$payload/opt/reinstall/postinstall.sh"
    chmod 0600 "$artifacts/secrets.env"

    rm -rf "$root"
    mkdir -p "$root"
    log_info "unpacking stock initrd (~$(du -m "$WORKDIR/initrd.gz" | cut -f1) MB compressed) ..."
    if ! (cd "$root" && zcat "$WORKDIR/initrd.gz" | cpio -idm --quiet 2>/dev/null) && [[ ! -f "$root/init" ]]; then
        die "failed to unpack stock initrd (corrupt download? rerun without --dry-run)"
        return 1
    fi
    (cd "$payload" && cp -a . "$root"/)

    log_info "repacking initrd with preseed payload ..."
    (cd "$root" && find . -print | cpio --quiet -o -H newc -R 0:0 2>/dev/null | gzip -9 > "$WORKDIR/initrd.preseed.gz")
    if ! zcat "$WORKDIR/initrd.preseed.gz" | cpio -t 2>/dev/null | awk '$0~/(\.\/)?preseed\.cfg$/{found=1} END{exit !found}'; then
        die "preseed.cfg missing from repacked initrd"
        return 1
    fi
    if [[ ! -s "$WORKDIR/initrd.preseed.gz" ]]; then
        die "initrd repack failed"
        return 1
    fi
    log_info "repacked initrd: $WORKDIR/initrd.preseed.gz"
}
