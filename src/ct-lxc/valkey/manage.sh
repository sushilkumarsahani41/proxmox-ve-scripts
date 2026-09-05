#!/usr/bin/env bash
# In-container management for Valkey. Pushed to
# /usr/local/sbin/valkey-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Delegates to Debian's own valkey-server package for everything except the
# two things that need this project's own decisions: opening up network
# access (Debian's config binds to 127.0.0.1 only) and setting `requirepass`
# (Debian ships none).
set -Eeuo pipefail

# @include lib/agent-ui.sh

CONF="/etc/valkey/valkey.conf"
DATA_DIR="/var/lib/valkey"
BACKUP_ROOT="/var/backups/valkey-lxc"
DBPASSWORD=""
PURGE=0

# dpkg -s alone isn't enough: it keeps succeeding after a plain `apt-get
# remove` (package state "deinstall ok config-files"), only failing once
# purged — see mariadb/manage.sh for the same fix and why it matters for a
# repeat --purge call.
is_installed() { dpkg-query -W -f='${Status}' valkey-server 2>/dev/null | grep -q '^install ok installed'; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; }
}

# The config file is the single source of truth for the current password —
# nothing else in this script keeps a second copy of it, the same reasoning
# as MariaDB's /root/.my.cnf: one place to read, so update/status/uninstall
# (which never receive --dbpassword — only `install` does) always see
# whatever is actually configured, not a stale value passed on a past run.
current_password() {
  sed -n 's/^requirepass[[:space:]]\+//p' "$CONF" 2>/dev/null | head -n1
}

configure_valkey() {
  local pass="$1"
  if grep -q '^bind ' "$CONF" 2>/dev/null; then
    sed -i 's/^bind .*/bind 0.0.0.0 -::1/' "$CONF"
  else
    printf 'bind 0.0.0.0 -::1\n' >> "$CONF"
  fi
  if grep -q '^requirepass ' "$CONF" 2>/dev/null; then
    sed -i "s/^requirepass .*/requirepass ${pass}/" "$CONF"
  elif grep -q '^# *requirepass' "$CONF" 2>/dev/null; then
    sed -i "s/^# *requirepass.*/requirepass ${pass}/" "$CONF"
  else
    printf 'requirepass %s\n' "$pass" >> "$CONF"
  fi
}

service_healthy() {
  valkey-cli -a "$(current_password)" --no-auth-warning ping 2>/dev/null | grep -q PONG
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

# SAVE (synchronous), not BGSAVE: a backup needs the snapshot finished before
# it's copied, not merely started.
backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  valkey-cli -a "$(current_password)" --no-auth-warning SAVE >/dev/null 2>&1 || true
  [[ -f "${DATA_DIR}/dump.rdb" ]] && cp -a "${DATA_DIR}/dump.rdb" "${backup_dir}/dump.rdb"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/dump.rdb" ]] || return 0
  systemctl stop valkey-server 2>/dev/null || true
  cp -a "${backup_dir}/dump.rdb" "${DATA_DIR}/dump.rdb"
  chown valkey:valkey "${DATA_DIR}/dump.rdb" 2>/dev/null || true
  systemctl start valkey-server 2>/dev/null || true
}

print_access_info() {
  echo
  ok "Valkey: valkey-cli -h $(container_ip) -a '<password>'"
}

cmd_install() {
  require_root
  is_installed && die "Valkey is already installed — use 'update' instead"

  apt-get update -qq
  apt-get install -y -qq valkey-server >/dev/null

  is_installed || die "valkey-server installed but is not detected — check: dpkg -s valkey-server"

  configure_valkey "$DBPASSWORD"
  restart_service valkey-server

  wait_for_service || die "Valkey did not come up healthy after install — check: systemctl status valkey-server"

  ok "Valkey installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Valkey is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up the dataset to ${backup_dir}/dump.rdb"

  apt-get update -qq
  if ! apt-get install -y -qq --only-upgrade valkey-server >/dev/null 2>&1; then
    warn "apt upgrade reported an issue — continuing to verify the running service"
  fi

  restart_service valkey-server

  if ! wait_for_service; then
    warn "Valkey did not come back up healthy after the update — restoring from backup"
    restore_state "$backup_dir"
    die "update failed, data restored from ${backup_dir}/dump.rdb — check: systemctl status valkey-server"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Valkey is not installed and there is no backed-up data to remove"
  fi

  local backup_dir=""
  if is_installed; then
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    apt-get remove -y -qq 'valkey*' >/dev/null 2>&1 || warn "apt remove reported an issue — continuing"
  fi

  # Not gated on is_installed: a previous plain uninstall already removed
  # the package (is_installed is now false) but deliberately left the data
  # directory on disk — a later --purge has to reach this regardless, or it
  # silently no-ops on exactly the data it was asked to remove.
  if [[ "$PURGE" -eq 1 ]]; then
    apt-get purge -y -qq 'valkey*' >/dev/null 2>&1 || true
    rm -rf /etc/valkey "$DATA_DIR" "$BACKUP_ROOT"
    ok "Valkey removed"
  elif [[ -n "$backup_dir" ]]; then
    ok "Valkey removed, data kept at ${DATA_DIR}, snapshot backed up to ${backup_dir}/dump.rdb"
  else
    ok "Valkey was already not installed; nothing further to remove"
  fi
}

cmd_status() {
  is_installed || die "Valkey is not installed"
  echo "service:  $(systemctl is-active valkey-server 2>/dev/null || echo unknown)"
  echo "address:  $(container_ip):6379"
  echo
  command -v ss >/dev/null 2>&1 && { ss -ltnp 2>/dev/null | grep -E ':6379\b' || true; }
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
      --dbpassword) DBPASSWORD="$2"; shift 2 ;;
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
