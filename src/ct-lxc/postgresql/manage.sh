#!/usr/bin/env bash
# In-container management for PostgreSQL. Pushed to
# /usr/local/sbin/postgresql-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Delegates to Debian's own postgresql package (Debian 13 ships PostgreSQL 17
# directly, no PGDG apt repo needed) — the version number is discovered at
# runtime, never hardcoded, since a future Debian release will ship a
# different one.
set -Eeuo pipefail

# @include lib/agent-ui.sh

BACKUP_ROOT="/var/backups/postgresql-lxc"
DBPASSWORD=""
PURGE=0

is_installed() { command -v psql >/dev/null 2>&1 && [[ -d /etc/postgresql ]]; }

pg_version() { ls /etc/postgresql 2>/dev/null | sort -V | tail -n1; }
pg_conf_dir() { printf '/etc/postgresql/%s/main' "$(pg_version)"; }

# Password auth over the network, on top of Debian's own default (peer auth
# for the Unix socket, untouched — `su postgres -c psql` and this script's
# own backup/restore never need a password because of it; only TCP clients
# do). `host ... 0.0.0.0/0 scram-sha-256` has to come before the narrower
# rules Debian ships, since pg_hba.conf is first-match-wins — appended at the
# end would never be reached for a 0.0.0.0/0 client if an earlier `reject`
# rule already matched everything.
open_network_access() {
  local conf_dir; conf_dir="$(pg_conf_dir)"
  if ! grep -q "^listen_addresses" "${conf_dir}/postgresql.conf" 2>/dev/null; then
    printf "listen_addresses = '*'\n" >> "${conf_dir}/postgresql.conf"
  else
    sed -i "s/^listen_addresses.*/listen_addresses = '*'/" "${conf_dir}/postgresql.conf"
  fi
  if ! grep -q "0.0.0.0/0" "${conf_dir}/pg_hba.conf" 2>/dev/null; then
    sed -i "1i host all all 0.0.0.0/0 scram-sha-256" "${conf_dir}/pg_hba.conf"
  fi
}

set_db_password() {
  local pass="$1"
  su postgres -c "psql -c \"ALTER USER postgres PASSWORD '${pass}';\"" >/dev/null
}

service_healthy() { su postgres -c 'pg_isready' >/dev/null 2>&1; }

wait_for_service() {
  local tries=30
  while (( tries > 0 )); do
    service_healthy && return 0
    sleep 2
    tries=$(( tries - 1 ))
  done
  return 1
}

# A plain SQL dump, not a filesystem copy: portable across the package's own
# upgrades within a Debian release, and restorable with nothing but `psql`,
# not tied to a specific on-disk cluster layout. Peer auth (Unix socket) as
# the postgres OS user needs no password regardless of what the `postgres`
# role's network password is set to — see open_network_access above.
backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  su postgres -c "pg_dumpall" > "${backup_dir}/dump.sql" 2>/dev/null || true
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/dump.sql" ]] || return 0
  su postgres -c "psql -f ${backup_dir}/dump.sql postgres" >/dev/null 2>&1 || true
}

has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d /var/lib/postgresql ]] && [[ -n "$(ls -A /var/lib/postgresql 2>/dev/null)" ]]; }
}

print_access_info() {
  echo
  ok "PostgreSQL: psql -h $(container_ip) -U postgres"
}

cmd_install() {
  require_root
  is_installed && die "PostgreSQL is already installed — use 'update' instead"

  apt-get update -qq
  apt-get install -y -qq postgresql >/dev/null

  is_installed || die "postgresql package installed but psql/config are not where expected"

  open_network_access
  restart_service postgresql

  wait_for_service || die "PostgreSQL did not come up healthy after install — check: systemctl status postgresql"

  set_db_password "$DBPASSWORD"

  ok "PostgreSQL installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "PostgreSQL is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up all databases to ${backup_dir}/dump.sql"

  apt-get update -qq
  if ! apt-get install -y -qq --only-upgrade postgresql postgresql-common "postgresql-$(pg_version)" >/dev/null 2>&1; then
    warn "apt upgrade reported an issue — continuing to verify the running service"
  fi

  restart_service postgresql

  if ! wait_for_service; then
    warn "PostgreSQL did not come back up healthy after the update — restoring from backup"
    restore_state "$backup_dir"
    restart_service postgresql || true
    die "update failed, data restored from ${backup_dir}/dump.sql — check: systemctl status postgresql"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "PostgreSQL is not installed and there is no backed-up data to remove"
  fi

  local backup_dir=""
  if is_installed; then
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    apt-get remove -y -qq 'postgresql*' >/dev/null 2>&1 || warn "apt remove reported an issue — continuing"
  fi

  # Not gated on is_installed: a previous plain uninstall already removed
  # the package (is_installed is now false) but deliberately left the
  # cluster on disk — a later --purge has to reach this regardless, or it
  # silently no-ops on exactly the data it was asked to remove.
  if [[ "$PURGE" -eq 1 ]]; then
    apt-get purge -y -qq 'postgresql*' >/dev/null 2>&1 || true
    rm -rf /etc/postgresql /var/lib/postgresql "$BACKUP_ROOT"
    ok "PostgreSQL removed"
  elif [[ -n "$backup_dir" ]]; then
    ok "PostgreSQL removed, cluster data kept at /var/lib/postgresql, dump backed up to ${backup_dir}/dump.sql"
  else
    ok "PostgreSQL was already not installed; nothing further to remove"
  fi
}

cmd_status() {
  is_installed || die "PostgreSQL is not installed"
  echo "service:  $(systemctl is-active postgresql 2>/dev/null || echo unknown)"
  echo "version:  $(su postgres -c 'psql --version' 2>/dev/null | head -n1 || echo unknown)"
  echo "address:  $(container_ip):5432"
  echo
  command -v ss >/dev/null 2>&1 && { ss -ltnp 2>/dev/null | grep -E ':5432\b' || true; }
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
