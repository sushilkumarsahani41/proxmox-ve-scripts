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

# Deliberately separate from is_installed: a plain `uninstall` removes the
# binary but keeps ${AGH_DIR}, so "uninstall, then decide to purge after all"
# is a natural sequence that must not be refused for having nothing to remove.
has_data() { [[ -d "$AGH_DIR" ]]; }

agh_version() { "$AGH_BIN" --version 2>&1 | sed -n 's/^AdGuard Home, version //p' | tail -n1; }

# Architecture/download/channel logic is deliberately NOT reimplemented here —
# it is delegated to AdGuard's own official installer. Hardcoding a URL like
# ".../AdGuardHome_linux_amd64.tar.gz" is exactly how "amd64 only" bugs happen
# the moment upstream changes something.
# Cleanup is explicit rather than a `trap ... RETURN`: a RETURN trap set inside
# a function is not scoped to that function (that needs `set -o functrace`), so
# it stays installed and fires again on the *next* function return — by which
# point $tmp_script is out of scope and `set -u` kills the script. That bug hid
# here happily, because it only triggered after the install had already
# succeeded.
run_vendor_installer() {
  info "running AdGuard Home's official installer (channel: ${CHANNEL})"
  local tmp_script rc=0
  tmp_script="$(mktemp)"
  if curl -fsSL "$VENDOR_INSTALL_URL" -o "$tmp_script"; then
    sh "$tmp_script" -c "$CHANNEL" -o /opt -v "$@" || rc=$?
  else
    rc=1
  fi
  rm -f "$tmp_script"
  return "$rc"
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

# AdGuard Home writes `-s status` to STDERR, not stdout. The 2>&1 here is
# load-bearing: without it this reads an empty string, concludes the service is
# down, and cmd_update rolls back every single time — including after a
# perfectly good upgrade. systemd is the cross-check, since the vendor
# installer registers a unit anyway.
service_state() {
  local out
  out="$("$AGH_BIN" -s status 2>&1 || true)"
  case "$out" in
    *"service: running"*) echo "running"; return 0 ;;
    *"service: stopped"*) echo "stopped"; return 0 ;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    case "$(systemctl is-active AdGuardHome 2>/dev/null || true)" in
      active) echo "running" ;;
      inactive|failed) echo "stopped" ;;
      *) echo "unknown" ;;
    esac
  else
    echo "unknown"
  fi
}

service_is_running() { [[ "$(service_state)" == "running" ]]; }

wait_for_service() {
  local tries=15
  while (( tries > 0 )); do
    service_is_running && return 0
    sleep 1
    tries=$(( tries - 1 ))
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
  old_version="$(agh_version)"
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
  new_version="$(agh_version)"
  ok "updated: ${old_version} -> ${new_version}"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "AdGuard Home is not installed and there is nothing left at ${AGH_DIR}"
  fi
  if is_installed; then
    "$AGH_BIN" -s stop >/dev/null 2>&1 || true
    "$AGH_BIN" -s uninstall >/dev/null 2>&1 || true
  fi
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
  echo "version:  $(agh_version)"
  echo "service:  $(service_state)"
  echo "address:  http://$(container_ip):3000"
  # -u as well as -t: DNS is UDP, and port 53 is the entire point of this
  # container. It stays unbound until the setup wizard has been completed.
  if command -v ss >/dev/null 2>&1; then
    echo "ports:"
    ss -ltunp 2>/dev/null | awk 'NR==1 || /:(53|3000) /' | sed 's/^/  /' || true
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
