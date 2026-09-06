#!/usr/bin/env bash
# In-container management for Jellyfin. Pushed to
# /usr/local/sbin/jellyfin-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Delegates to Jellyfin's own official installer (repo.jellyfin.org/
# install-debuntu.sh) for install — it already knows the right apt repo per
# Debian codename and CPU architecture, so this project doesn't reimplement
# any of that. Verified by reading the actual script before trusting it:
# it supports amd64/armhf/arm64 and Debian bullseye/bookworm/trixie, and has
# exactly one interactive prompt (a "does this look right?" confirmation),
# skipped here via SKIP_CONFIRM=true — the same "seed past the interactive
# part" principle as this project's other vendor-installer services, just a
# one-variable version of it instead of a config file.
set -Eeuo pipefail

# @include lib/agent-ui.sh

CONFIG_DIR="/etc/jellyfin"
DATA_DIR="/var/lib/jellyfin"
BACKUP_ROOT="/var/backups/jellyfin-lxc"
INSTALLER_URL="https://repo.jellyfin.org/install-debuntu.sh"
PURGE=0

# dpkg -s alone isn't enough: it keeps succeeding after a plain `apt-get
# remove` (package state "deinstall ok config-files"), only failing once
# purged.
is_installed() { dpkg-query -W -f='${Status}' jellyfin 2>/dev/null | grep -q '^install ok installed'; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; }
}

service_healthy() {
  curl -fsS -o /dev/null "http://localhost:8096/health" 2>/dev/null \
    || curl -fsS -o /dev/null "http://localhost:8096/" 2>/dev/null
}

wait_for_service() {
  local tries=30
  while (( tries > 0 )); do
    service_healthy && return 0
    sleep 2
    tries=$(( tries - 1 ))
  done
  return 1
}

backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d "$CONFIG_DIR" ]] && cp -a "$CONFIG_DIR" "${backup_dir}/jellyfin-etc"
  [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR" "${backup_dir}/jellyfin-lib"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/jellyfin-etc" ]] && { rm -rf "$CONFIG_DIR"; cp -a "${backup_dir}/jellyfin-etc" "$CONFIG_DIR"; }
  [[ -d "${backup_dir}/jellyfin-lib" ]] && { rm -rf "$DATA_DIR"; cp -a "${backup_dir}/jellyfin-lib" "$DATA_DIR"; }
}

print_access_info() {
  echo
  ok "Jellyfin setup wizard: http://$(container_ip):8096"
}

cmd_install() {
  require_root
  is_installed && die "Jellyfin is already installed — use 'update' instead"

  local tmp_script
  tmp_script="$(mktemp)"
  curl -fsSL "$INSTALLER_URL" -o "$tmp_script" || { rm -f "$tmp_script"; die "failed to download Jellyfin's installer"; }
  SKIP_CONFIRM=true bash "$tmp_script" >/dev/null || { rm -f "$tmp_script"; die "Jellyfin installation failed"; }
  rm -f "$tmp_script"

  is_installed || die "jellyfin package installed but is not detected — check: dpkg -s jellyfin"

  wait_for_service || die "Jellyfin did not come up healthy after install — check: systemctl status jellyfin"

  ok "Jellyfin installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Jellyfin is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up config/data to ${backup_dir}"

  apt-get update -qq
  if ! apt-get install -y -qq --only-upgrade 'jellyfin*' >/dev/null 2>&1; then
    warn "apt upgrade reported an issue — continuing to verify the running service"
  fi

  restart_service jellyfin

  if ! wait_for_service; then
    warn "Jellyfin did not come back up healthy after the update — restoring from backup"
    restore_state "$backup_dir"
    restart_service jellyfin || true
    die "update failed, data restored from ${backup_dir} — check: systemctl status jellyfin"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Jellyfin is not installed and there is no backed-up data to remove"
  fi

  local backup_dir=""
  if is_installed; then
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    apt-get remove -y -qq 'jellyfin*' >/dev/null 2>&1 || warn "apt remove reported an issue — continuing"
  fi

  # Not gated on is_installed: a previous plain uninstall already removed
  # the package (is_installed is now false) but deliberately left the data
  # directory on disk — a later --purge has to reach this regardless, or it
  # silently no-ops on exactly the data it was asked to remove.
  if [[ "$PURGE" -eq 1 ]]; then
    apt-get purge -y -qq 'jellyfin*' >/dev/null 2>&1 || true
    rm -rf "$CONFIG_DIR" "$DATA_DIR" /etc/apt/sources.list.d/jellyfin.sources /etc/apt/keyrings/jellyfin.gpg "$BACKUP_ROOT"
    ok "Jellyfin removed"
  elif [[ -n "$backup_dir" ]]; then
    ok "Jellyfin removed, config/data kept at ${CONFIG_DIR} and ${DATA_DIR}, backed up to ${backup_dir}"
  else
    ok "Jellyfin was already not installed; nothing further to remove"
  fi
}

cmd_status() {
  is_installed || die "Jellyfin is not installed"
  echo "service:  $(systemctl is-active jellyfin 2>/dev/null || echo unknown)"
  echo "address:  http://$(container_ip):8096"
  echo
  command -v ss >/dev/null 2>&1 && { ss -ltnp 2>/dev/null | grep -E ':8096\b' || true; }
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
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
