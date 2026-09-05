#!/usr/bin/env bash
# In-container management for MongoDB. Pushed to
# /usr/local/sbin/mongodb-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Delegates to MongoDB's own apt repository (not in Debian's own archive —
# MongoDB Inc. dropped that years ago). That repo only actually publishes
# mongodb-org-server for Debian 12 "bookworm" on amd64 — checked directly
# against repo.mongodb.org's package listings, not assumed from the docs —
# so this refuses to even try on any other architecture.
set -Eeuo pipefail

# @include lib/agent-ui.sh

CONF="/etc/mongod.conf"
DATA_DIR="/var/lib/mongodb"
BACKUP_ROOT="/var/backups/mongodb-lxc"
CRED_FILE="/root/.mongodb-lxc-password"
KEYRING="/usr/share/keyrings/mongodb-server-8.0.gpg"
APT_SOURCE="/etc/apt/sources.list.d/mongodb-org-8.0.list"
DBPASSWORD=""
PURGE=0

# dpkg -s alone isn't enough: it keeps succeeding after a plain `apt-get
# remove` (package state "deinstall ok config-files"), only failing once
# purged — see mariadb/manage.sh for the same fix and why it matters for a
# repeat --purge call.
is_installed() { dpkg-query -W -f='${Status}' mongodb-org-server 2>/dev/null | grep -q '^install ok installed'; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; }
}

# The database itself only stores a hash, so the plaintext has to live
# somewhere for this script's own later use (backup on update, health
# checks) — root-only (0600), the same trust boundary MariaDB's
# /root/.my.cnf extends, since only root already has full access to this
# container anyway (pct exec, the generated root SSH password).
save_password() { printf '%s' "$1" > "$CRED_FILE"; chmod 600 "$CRED_FILE"; }
current_password() {
  if [[ -f "$CRED_FILE" ]]; then cat "$CRED_FILE"; else printf '%s' "$DBPASSWORD"; fi
}

require_amd64() {
  local arch; arch="$(dpkg --print-architecture)"
  [[ "$arch" == "amd64" ]] || die "MongoDB's official packages do not publish a server build for '${arch}' — this script only supports amd64. Use mongodb-docker-lxc.sh instead, which supports arm64 too."
}

add_mongodb_repo() {
  ensure_pkg curl gpg
  mkdir -p /usr/share/keyrings
  curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o "$KEYRING"
  printf 'deb [ arch=amd64 signed-by=%s ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main\n' \
    "$KEYRING" > "$APT_SOURCE"
}

# Only reachable locally (127.0.0.1, the shipped default) before the root
# user and authorization exist — mongod refuses --auth with no users to
# check credentials against, so the create-user step below has to run while
# auth is still off, and only after that is it safe to turn auth on and
# open the network.
ping_unauthenticated() { mongosh --quiet --eval 'db.adminCommand("ping")' >/dev/null 2>&1; }
ping_authenticated() {
  mongosh --quiet --eval 'db.adminCommand("ping")' \
    -u root -p "$(current_password)" --authenticationDatabase admin >/dev/null 2>&1
}

wait_for() {
  local check="$1" tries=30
  while (( tries > 0 )); do
    "$check" && return 0
    sleep 2
    tries=$(( tries - 1 ))
  done
  return 1
}

open_network_and_auth() {
  sed -i 's/^\(\s*bindIp:\s*\).*/\10.0.0.0/' "$CONF"
  if grep -q '^security:' "$CONF"; then
    sed -i '/^security:/a\  authorization: enabled' "$CONF"
  else
    printf 'security:\n  authorization: enabled\n' >> "$CONF"
  fi
}

backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  mongodump -u root -p "$(current_password)" --authenticationDatabase admin --archive \
    > "${backup_dir}/dump.archive" 2>/dev/null || true
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/dump.archive" ]] || return 0
  mongorestore -u root -p "$(current_password)" --authenticationDatabase admin --archive \
    < "${backup_dir}/dump.archive" >/dev/null 2>&1 || true
}

print_access_info() {
  echo
  ok "MongoDB: mongosh \"mongodb://root:<password>@$(container_ip):27017\""
}

cmd_install() {
  require_root
  require_amd64
  is_installed && die "MongoDB is already installed — use 'update' instead"

  add_mongodb_repo
  apt-get update -qq
  apt-get install -y -qq mongodb-org >/dev/null

  is_installed || die "mongodb-org-server installed but is not detected — check: dpkg -s mongodb-org-server"

  restart_service mongod
  wait_for ping_unauthenticated || die "mongod did not come up after install — check: systemctl status mongod"

  mongosh --quiet --eval "db.getSiblingDB('admin').createUser({user:'root',pwd:'${DBPASSWORD}',roles:['root']})" >/dev/null \
    || die "failed to create the root database user"
  save_password "$DBPASSWORD"

  open_network_and_auth
  restart_service mongod
  wait_for ping_authenticated || die "mongod did not come back up healthy after enabling authorization — check: systemctl status mongod"

  ok "MongoDB installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "MongoDB is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up all databases to ${backup_dir}/dump.archive"

  apt-get update -qq
  if ! apt-get install -y -qq --only-upgrade mongodb-org >/dev/null 2>&1; then
    warn "apt upgrade reported an issue — continuing to verify the running service"
  fi

  restart_service mongod

  if ! wait_for ping_authenticated; then
    warn "mongod did not come back up healthy after the update — restoring from backup"
    restore_state "$backup_dir"
    restart_service mongod || true
    die "update failed, data restored from ${backup_dir}/dump.archive — check: systemctl status mongod"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "MongoDB is not installed and there is no backed-up data to remove"
  fi

  local backup_dir=""
  if is_installed; then
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    apt-get remove -y -qq 'mongodb-org*' >/dev/null 2>&1 || warn "apt remove reported an issue — continuing"
  fi

  # Not gated on is_installed: a previous plain uninstall already removed
  # the package (is_installed is now false) but deliberately left the data
  # directory on disk — a later --purge has to reach this regardless, or it
  # silently no-ops on exactly the data it was asked to remove.
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$DATA_DIR" "$CONF" "$CRED_FILE" "$KEYRING" "$APT_SOURCE" "$BACKUP_ROOT"
    ok "MongoDB removed"
  elif [[ -n "$backup_dir" ]]; then
    ok "MongoDB removed, data kept at ${DATA_DIR}, dump backed up to ${backup_dir}/dump.archive"
  else
    ok "MongoDB was already not installed; nothing further to remove"
  fi
}

cmd_status() {
  is_installed || die "MongoDB is not installed"
  echo "service:  $(systemctl is-active mongod 2>/dev/null || echo unknown)"
  echo "address:  $(container_ip):27017"
  echo
  command -v ss >/dev/null 2>&1 && { ss -ltnp 2>/dev/null | grep -E ':27017\b' || true; }
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
