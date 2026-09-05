#!/usr/bin/env bash
# In-container management for SharkShell. Pushed to /usr/local/sbin/
# sharkshell-manage.sh and re-pushed on every command, so the container
# always matches the host script's version.
#
# SharkShell ships its own install/update/uninstall tooling (deploy.sh,
# bin/sharkshell) — this delegates to that rather than reimplementing it,
# the same principle as every other service in this project. The one thing
# this file owns is cloning the source: SharkShell's own release-based
# one-liner resolves whatever GitHub currently calls "latest release", and
# a fix merged to main does not reach that path until a new release is cut
# — cloning main directly is SharkShell's own other documented deploy
# method, and sidesteps that entirely.
set -Eeuo pipefail

# @include lib/agent-ui.sh

SRC_DIR="/opt/sharkshell-src"
APP_DIR="/opt/sharkshell"
DATA_DIR="/var/lib/sharkshell"
SECRETS_DIR="$DATA_DIR/secrets"
SHARKSHELL_BIN="/usr/local/bin/sharkshell"
DEPLOY_REPO_URL="https://github.com/sushilkumarsahani41/SharkShell.git"
BACKUP_ROOT="/var/backups/sharkshell"
HEALTH_URL="http://127.0.0.1/api/auth/setup-status"
PURGE=0

is_installed() { [[ -x "$APP_DIR/run.sh" ]]; }
has_data() { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; }

# The built-in PostgreSQL is the only state worth protecting here — hosts,
# keys, orgs, everything a user has set up. `pg_dump` as the postgres OS
# user (peer auth, the same access pattern deploy.sh itself uses) needs no
# password and works whether or not the backend is currently running.
backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  if su -s /bin/sh postgres -c "pg_dump sharkshell" > "${backup_dir}/sharkshell.sql" 2>/dev/null; then
    :
  else
    rm -f "${backup_dir}/sharkshell.sql"
    warn "could not dump the database (external DB, or none configured yet) — continuing without a data backup"
  fi
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -s "${backup_dir}/sharkshell.sql" ]] || return 0
  su -s /bin/sh postgres -c "psql sharkshell" < "${backup_dir}/sharkshell.sql" >/dev/null 2>&1 || true
}

service_healthy() { curl -fsS -o /dev/null "$HEALTH_URL" 2>/dev/null; }

wait_for_service() {
  local tries=30
  while (( tries > 0 )); do
    service_healthy && return 0
    sleep 2
    tries=$(( tries - 1 ))
  done
  return 1
}

print_access_info() {
  echo
  ok "SharkShell: http://$(container_ip)"
}

cmd_install() {
  require_root
  ensure_pkg curl git
  is_installed && die "SharkShell is already installed — use 'update' instead"

  if [[ ! -d "$SRC_DIR/.git" ]]; then
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$DEPLOY_REPO_URL" "$SRC_DIR" || die "failed to clone SharkShell's source"
  fi

  bash "$SRC_DIR/deploy.sh" || die "deploy.sh failed — see the output above"

  is_installed || die "deploy.sh reported success but ${APP_DIR}/run.sh is missing"
  wait_for_service || warn "the health endpoint isn't responding yet — check: sharkshell logs"

  ok "SharkShell installed"
  print_access_info
}

# Delegates to `sharkshell update` — SharkShell's own git-pull + rebuild +
# restart. Its rollback promise is narrower than this wrapper's default:
# the database is backed up here and restored if health looks wrong
# afterward, but the code itself is not reverted (that's a `git` operation
# on $SRC_DIR the user can do by hand if they need to go back further than
# one commit).
cmd_update() {
  require_root
  is_installed || die "SharkShell is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up the database to ${backup_dir}"

  if ! "$SHARKSHELL_BIN" update; then
    warn "sharkshell update reported failure — restoring the database from backup"
    restore_state "$backup_dir"
    die "update failed, database restored from ${backup_dir} — check: sharkshell logs"
  fi

  if ! wait_for_service; then
    warn "SharkShell did not come back up healthy after the update — restoring the database from backup"
    restore_state "$backup_dir"
    "$SHARKSHELL_BIN" restart >/dev/null 2>&1 || true
    die "update failed, database restored from ${backup_dir} — the code itself is not rolled back; check: sharkshell logs, or git log in ${SRC_DIR}"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "SharkShell is not installed and there is no backed-up database to remove"
  fi

  if is_installed; then
    local backup_dir=""
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    "$SHARKSHELL_BIN" uninstall --force || die "sharkshell uninstall --force reported failure"
    if [[ -n "$backup_dir" ]]; then
      ok "SharkShell removed, database backed up to ${backup_dir}"
    else
      ok "SharkShell removed"
    fi
  fi

  # sharkshell uninstall deliberately leaves the git source alone ("the git
  # source repo ... [is] NOT touched") — fine for a plain uninstall (a
  # future create can reuse it), but --purge means gone, so this project's
  # own clone goes too.
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$SRC_DIR" "$BACKUP_ROOT"
    ok "source and all backed-up data removed"
  fi
}

cmd_status() {
  is_installed || die "SharkShell is not installed"
  # sharkshell status itself exits 1 when the service is down and unhealthy
  # — a legitimate status to report, not a crash in this wrapper. Let its
  # own output stand rather than layering an ERR-trap "failed at line N" on
  # top of it, but still surface that this run is reporting bad news.
  "$SHARKSHELL_BIN" status || warn "SharkShell is not currently healthy — see above"
  echo "address:  http://$(container_ip)"
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
