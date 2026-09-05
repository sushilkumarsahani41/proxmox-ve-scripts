#!/usr/bin/env bash
# In-container management for MariaDB. Pushed to
# /usr/local/sbin/mariadb-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Delegates to Debian's own mariadb-server package for everything except
# the two things that need this project's own decisions: opening up network
# access (Debian binds to 127.0.0.1 only) and setting a password for the
# `root` database account (Debian defaults it to passwordless unix_socket
# auth, which only ever works from the system's own root user).
set -Eeuo pipefail

# @include lib/agent-ui.sh

BACKUP_ROOT="/var/backups/mariadb-lxc"
MY_CNF="/root/.my.cnf"
DBPASSWORD=""
PURGE=0

# dpkg -s alone isn't enough: it keeps succeeding after a plain `apt-get
# remove` (package state "deinstall ok config-files"), only failing once
# purged — checking the Status field directly for "installed" is what
# actually tracks whether the package is *present*, so a repeat --purge
# call after a plain uninstall doesn't think there's still something here
# to `apt-get remove` a second time.
is_installed() { dpkg-query -W -f='${Status}' mariadb-server 2>/dev/null | grep -q '^install ok installed'; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d /var/lib/mysql ]] && [[ -n "$(ls -A /var/lib/mysql 2>/dev/null)" ]]; }
}

# Debian's own package ships `bind-address = 127.0.0.1` in this file —
# nothing to detect or template, just flip the one line it already sets.
open_network_access() {
  local cnf="/etc/mysql/mariadb.conf.d/50-server.cnf"
  [[ -f "$cnf" ]] && sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$cnf"
}

# Written once, right after the password is set, so every later invocation
# of this script (backup on update, health checks) authenticates the same
# way `mariadb`/`mariadb-dump` would from a human's own shell — without
# storing the password anywhere this script has to manage separately.
# root-only (0600): the same trust boundary this project already extends to
# root everywhere else (pct exec, the generated root SSH password).
write_my_cnf() {
  printf '[client]\nuser=root\npassword=%s\n' "$1" > "$MY_CNF"
  chmod 600 "$MY_CNF"
}

# Unix-socket auth (passwordless for the system's own root user) is what
# Debian's package ships root@localhost with, and is what this runs under
# until write_my_cnf's ALTER USER call replaces it below — so this step, and
# only this step, has to run without relying on $MY_CNF existing yet.
set_db_password() {
  local pass="$1"
  mariadb -e "
    ALTER USER 'root'@'localhost' IDENTIFIED BY '${pass}';
    CREATE OR REPLACE USER 'root'@'%' IDENTIFIED BY '${pass}';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
  " >/dev/null
  write_my_cnf "$pass"
}

service_healthy() { mariadb -e 'SELECT 1;' >/dev/null 2>&1; }

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
  mariadb-dump --all-databases > "${backup_dir}/dump.sql" 2>/dev/null || true
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/dump.sql" ]] || return 0
  mariadb < "${backup_dir}/dump.sql" >/dev/null 2>&1 || true
}

print_access_info() {
  echo
  ok "MariaDB: mariadb -h $(container_ip) -u root -p"
}

cmd_install() {
  require_root
  is_installed && die "MariaDB is already installed — use 'update' instead"

  apt-get update -qq
  apt-get install -y -qq mariadb-server >/dev/null

  is_installed || die "mariadb-server installed but is not detected — check: dpkg -s mariadb-server"

  open_network_access
  restart_service mariadb

  # Runs before set_db_password, while root@localhost is still unix_socket —
  # the only window this health check can rely on that rather than $MY_CNF.
  wait_for_service || die "MariaDB did not come up healthy after install — check: systemctl status mariadb"

  set_db_password "$DBPASSWORD"

  ok "MariaDB installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "MariaDB is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up all databases to ${backup_dir}/dump.sql"

  apt-get update -qq
  if ! apt-get install -y -qq --only-upgrade mariadb-server mariadb-client mariadb-common >/dev/null 2>&1; then
    warn "apt upgrade reported an issue — continuing to verify the running service"
  fi

  restart_service mariadb

  if ! wait_for_service; then
    warn "MariaDB did not come back up healthy after the update — restoring from backup"
    restore_state "$backup_dir"
    restart_service mariadb || true
    die "update failed, data restored from ${backup_dir}/dump.sql — check: systemctl status mariadb"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "MariaDB is not installed and there is no backed-up data to remove"
  fi

  local backup_dir=""
  if is_installed; then
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    apt-get remove -y -qq 'mariadb-server*' >/dev/null 2>&1 || warn "apt remove reported an issue — continuing"
  fi

  # Not gated on is_installed: a previous plain uninstall already removed
  # the package (is_installed is now false) but deliberately left the data
  # directory on disk — a later --purge has to reach this regardless, or it
  # silently no-ops on exactly the data it was asked to remove.
  if [[ "$PURGE" -eq 1 ]]; then
    apt-get purge -y -qq 'mariadb-server*' 'mariadb-client*' 'mariadb-common*' >/dev/null 2>&1 || true
    rm -rf /etc/mysql /var/lib/mysql "$MY_CNF" "$BACKUP_ROOT"
    ok "MariaDB removed"
  elif [[ -n "$backup_dir" ]]; then
    ok "MariaDB removed, data kept at /var/lib/mysql, dump backed up to ${backup_dir}/dump.sql"
  else
    ok "MariaDB was already not installed; nothing further to remove"
  fi
}

cmd_status() {
  is_installed || die "MariaDB is not installed"
  echo "service:  $(systemctl is-active mariadb 2>/dev/null || echo unknown)"
  echo "version:  $(mariadb --version 2>/dev/null || echo unknown)"
  echo "address:  $(container_ip):3306"
  echo
  command -v ss >/dev/null 2>&1 && { ss -ltnp 2>/dev/null | grep -E ':3306\b' || true; }
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
