#!/usr/bin/env bash
set -Eeuo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
source "$BASE/lib/common.sh"
for f in config detect validate download preseed postinstall initrd kexec; do source "$BASE/lib/$f.sh"; done
cat >&2 <<'BANNER'
TTTTT  H   H  EEEEE        H   H   OOO   RRRR   SSSS  EEEEE
  T    H   H  E            H   H  O   O  R   R  S     E    
  T    HHHHH  EEEE         HHHHH  O   O  RRRR   SSSS  EEEE 
  T    H   H  E            H   H  O   O  R R    S     E    
  T    H   H  EEEEE        H   H   OOO   R  RR  SSSS  EEEEE

                         sends his reguards
BANNER
DRY_RUN=no CONFIG_FILE=""
while (($#)); do case $1 in --dry-run) DRY_RUN=yes;; --config) CONFIG_FILE=$2; shift;; --verbose|-v) LOG_LEVEL=DEBUG;; --log-file) LOG_FILE=$2; shift;; --assume-yes) ASSUME_YES=yes;; -h|--help) echo "Usage: reinstall.sh [--dry-run] [--config FILE] [--verbose] [--log-file PATH] [--assume-yes]"; exit 0;; esac; shift; done
LOG_FILE="${LOG_FILE:-/tmp/reinstall-$(date -u +%Y%m%d-%H%M%S).log}"
init_logging "$@"
apply_env_overrides
load_config "${CONFIG_FILE:-}"
set_defaults
apply_env_overrides
WORKDIR="${WORKDIR:-$(mktemp -d /dev/shm/reinstall.XXXXXX 2>/dev/null || mktemp -d /root/reinstall.XXXXXX)}"
export WORKDIR
trap 'rc=$?; log_error "unexpected failure (rc=$rc) at ${BASH_SOURCE##*/}:$LINENO: $BASH_COMMAND"; exit "$rc"' ERR
trap '[[ -n ${WORKDIR:-} && ${KEEP_WORKDIR:-no} != yes ]] && rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR"
redact_add "$LUKS_PASSPHRASE"
guard_virtualization
detect_collect
prompt_or_require_config
prompt_passphrase; redact_add "$LUKS_PASSPHRASE"
TMPPW=$(openssl rand -hex 32); redact_add "$TMPPW"
ADMIN_PW_CRYPT="${ADMIN_PASSWORD_HASH:-$(openssl passwd -6 "$(openssl rand -hex 16)")}"
build_preseed "$TMPPW" "$ADMIN_PW_CRYPT"
build_postinstall_artifacts "$TMPPW"
if [[ ${DRY_RUN:-no} == yes ]]; then render_partition_tree; cat "$WORKDIR/preseed.cfg"; build_cmdline; exit 0; fi
download_installer; verify_installer; build_payload; do_kexec
