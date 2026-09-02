#!/usr/bin/env bash
# In-container management for AdGuard Home. Pushed to
# /usr/local/sbin/adguardhome-manage.sh by the host script, and re-pushed on
# every command, so the container always matches the host script's version.
set -Eeuo pipefail

# @include lib/agent-ui.sh

AGH_DIR="/opt/AdGuardHome"
AGH_BIN="${AGH_DIR}/AdGuardHome"
BACKUP_ROOT="/var/backups/adguardhome"
VENDOR_INSTALL_URL="https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh"
CHANNEL="release"
PURGE=0

is_installed() { [[ -x "$AGH_BIN" ]]; }

# Architecture/download/channel logic is deliberately NOT reimplemented here —
# it is delegated to AdGuard's own official installer. Hardcoding a URL like
# ".../AdGuardHome_linux_amd64.tar.gz" is exactly how "amd64 only" bugs happen
# the moment upstream changes something.
run_vendor_installer() {
  info "running AdGuard Home's official installer (channel: ${CHANNEL})"
  local tmp_script
  tmp_script="$(mktemp)"
  trap 'rm -f "$tmp_script"' RETURN
  curl -fsSL "$VENDOR_INSTALL_URL" -o "$tmp_script"
  sh "$tmp_script" -c "$CHANNEL" -o /opt -v "$@"
}

backup_state() {
  local stamp backup_dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${stamp}"
  mkdir -p "$backup_dir"
  [[ -f "${AGH_DIR}/AdGuardHome.yaml" ]] && cp -a "${AGH_DIR}/AdGuardHome.yaml" "$backup_dir/"
  [[ -d "${AGH_DIR}/data" ]] && cp -a "${AGH_DIR}/data" "$backup_dir/"
  [[ -x "$AGH_BIN" ]] && cp -a "$AGH_BIN" "${backup_dir}/AdGuardHome.bin"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/AdGuardHome.yaml" ]] && cp -a "${backup_dir}/AdGuardHome.yaml" "${AGH_DIR}/"
  [[ -d "${backup_dir}/data" ]] && cp -a "${backup_dir}/data" "${AGH_DIR}/"
  return 0
}

service_is_running() { "$AGH_BIN" -s status 2>/dev/null | grep -qi "running"; }

wait_for_service() {
  local tries=15
  while (( tries > 0 )); do
    service_is_running && return 0
    sleep 1
    (( tries-- ))
  done
  return 1
}

rollback() {
  local backup_dir="$1"
  "$AGH_BIN" -s stop >/dev/null 2>&1 || true
  [[ -f "${backup_dir}/AdGuardHome.bin" ]] && cp -a "${backup_dir}/AdGuardHome.bin" "$AGH_BIN"
  restore_state "$backup_dir"
  "$AGH_BIN" -s start >/dev/null 2>&1 || true
}

print_access_info() {
  echo
  ok "AdGuard Home setup wizard: http://$(container_ip):3000"
}

cmd_install() {
  require_root
  ensure_pkg curl
  is_installed && die "AdGuard Home is already installed at ${AGH_DIR} — use 'update' instead"
  run_vendor_installer
  ok "AdGuard Home installed"
  print_access_info
}

cmd_update() {
  require_root
  ensure_pkg curl
  is_installed || die "AdGuard Home is not installed — use 'install' instead"

  local old_version backup_dir
  old_version="$("$AGH_BIN" --version 2>/dev/null || echo "unknown")"
  info "current version: ${old_version}"

  backup_dir="$(backup_state)"
  ok "backed up config/data to ${backup_dir}"

  "$AGH_BIN" -s stop >/dev/null 2>&1 || true

  if ! run_vendor_installer -r; then
    warn "vendor installer failed — rolling back"
    rollback "$backup_dir"
    die "update failed, previous version restored"
  fi

  "$AGH_BIN" -s stop >/dev/null 2>&1 || true
  restore_state "$backup_dir"
  "$AGH_BIN" -s start >/dev/null 2>&1 || true

  if ! wait_for_service; then
    warn "AdGuard Home did not come up after update — rolling back"
    rollback "$backup_dir"
    die "update failed, previous version restored"
  fi

  local new_version
  new_version="$("$AGH_BIN" --version 2>/dev/null || echo "unknown")"
  ok "updated: ${old_version} -> ${new_version}"
  print_access_info
}

cmd_uninstall() {
  require_root
  is_installed || die "AdGuard Home is not installed"
  "$AGH_BIN" -s stop >/dev/null 2>&1 || true
  "$AGH_BIN" -s uninstall >/dev/null 2>&1 || true
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$AGH_DIR"
    ok "AdGuard Home service and files removed"
  else
    rm -f "$AGH_BIN"
    ok "AdGuard Home service removed, config/data kept at ${AGH_DIR}"
  fi
}

cmd_status() {
  is_installed || die "AdGuard Home is not installed"
  echo "version:  $("$AGH_BIN" --version 2>/dev/null || echo unknown)"
  echo "service:  $("$AGH_BIN" -s status 2>/dev/null || echo unknown)"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E ':(53|3000)\b' || true
  fi
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
      --channel) CHANNEL="$2"; shift 2 ;;
      --purge) PURGE=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$cmd" in
    install) cmd_install ;;
    update) cmd_update ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
