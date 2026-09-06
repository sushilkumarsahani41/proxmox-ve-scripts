#!/usr/bin/env bash
# In-container management for Plex. Pushed to /usr/local/sbin/plex-manage.sh
# and re-pushed on every command, so the container always matches the host
# script's version.
#
# Delegates to Plex's own official apt repository (repo.plex.tv) for
# everything install-related — verified directly against the repo itself
# (real Packages files for both amd64 and arm64, not just Plex's own
# marketing copy) rather than assumed, since Plex's ARM support used to be
# far narrower than this. The modern (v2, keyring-based) repo setup
# commands are used here, not the deprecated apt-key method.
set -Eeuo pipefail

# @include lib/agent-ui.sh

KEYRING="/etc/apt/keyrings/plexmediaserver.v2.gpg"
APT_SOURCE="/etc/apt/sources.list.d/plex.list"
DATA_DIR="/var/lib/plexmediaserver"
BACKUP_ROOT="/var/backups/plex-lxc"
PURGE=0

# dpkg -s alone isn't enough: it keeps succeeding after a plain `apt-get
# remove` (package state "deinstall ok config-files"), only failing once
# purged.
is_installed() { dpkg-query -W -f='${Status}' plexmediaserver 2>/dev/null | grep -q '^install ok installed'; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; }
}

add_plex_repo() {
  ensure_pkg curl gpg
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.v2.key | gpg --dearmor --yes -o "$KEYRING"
  chmod 644 "$KEYRING"
  printf 'deb [signed-by=%s] https://repo.plex.tv/deb/ public main\n' "$KEYRING" > "$APT_SOURCE"
}

# /identity is Plex's own always-on, unauthenticated status endpoint —
# returns the server's machine identifier as XML, works whether or not the
# server has been claimed yet, so this can verify the daemon is actually
# answering without needing a plex.tv sign-in first.
service_healthy() { curl -fsS -o /dev/null "http://localhost:32400/identity" 2>/dev/null; }

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
  [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR" "${backup_dir}/plexmediaserver"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/plexmediaserver" ]] || return 0
  rm -rf "$DATA_DIR"
  cp -a "${backup_dir}/plexmediaserver" "$DATA_DIR"
}

print_access_info() {
  echo
  ok "Plex: http://$(container_ip):32400/web — sign in with a plex.tv account to finish setup"
}

cmd_install() {
  require_root
  is_installed && die "Plex is already installed — use 'update' instead"

  add_plex_repo
  apt-get update -qq
  apt-get install -y -qq plexmediaserver >/dev/null

  is_installed || die "plexmediaserver installed but is not detected — check: dpkg -s plexmediaserver"

  restart_service plexmediaserver
  wait_for_service || die "Plex did not come up healthy after install — check: systemctl status plexmediaserver"

  ok "Plex installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Plex is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up data to ${backup_dir}"

  apt-get update -qq
  if ! apt-get install -y -qq --only-upgrade 'plexmediaserver*' >/dev/null 2>&1; then
    warn "apt upgrade reported an issue — continuing to verify the running service"
  fi

  restart_service plexmediaserver

  if ! wait_for_service; then
    warn "Plex did not come back up healthy after the update — restoring from backup"
    restore_state "$backup_dir"
    restart_service plexmediaserver || true
    die "update failed, data restored from ${backup_dir} — check: systemctl status plexmediaserver"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Plex is not installed and there is no backed-up data to remove"
  fi

  local backup_dir=""
  if is_installed; then
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    apt-get remove -y -qq 'plexmediaserver*' >/dev/null 2>&1 || warn "apt remove reported an issue — continuing"
  fi

  # Not gated on is_installed: a previous plain uninstall already removed
  # the package (is_installed is now false) but deliberately left the data
  # directory on disk — a later --purge has to reach this regardless, or it
  # silently no-ops on exactly the data it was asked to remove.
  if [[ "$PURGE" -eq 1 ]]; then
    apt-get purge -y -qq 'plexmediaserver*' >/dev/null 2>&1 || true
    rm -rf "$DATA_DIR" "$KEYRING" "$APT_SOURCE" "$BACKUP_ROOT"
    ok "Plex removed"
  elif [[ -n "$backup_dir" ]]; then
    ok "Plex removed, data kept at ${DATA_DIR}, backed up to ${backup_dir}"
  else
    ok "Plex was already not installed; nothing further to remove"
  fi
}

cmd_status() {
  is_installed || die "Plex is not installed"
  echo "service:  $(systemctl is-active plexmediaserver 2>/dev/null || echo unknown)"
  echo "address:  http://$(container_ip):32400/web"
  echo
  command -v ss >/dev/null 2>&1 && { ss -ltnp 2>/dev/null | grep -E ':32400\b' || true; }
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
