#!/usr/bin/env bash
# In-container management for PostgreSQL (Docker). Pushed to
# /usr/local/sbin/postgresql-docker-manage.sh and re-pushed on every
# command, so the container always matches the host script's version.
#
# Delegates to the official postgres image and `docker compose` for
# everything — the same principle as this project's native PostgreSQL
# script, applied to a vendor *image* instead of a vendor *package*.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/postgresql-docker"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
DATA_DIR="${APP_DIR}/pgdata"
BACKUP_ROOT="/var/backups/postgresql-docker"
DBPASSWORD=""
PURGE=0

is_installed() { [[ -f "$COMPOSE_FILE" ]]; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; }
}

docker_compose() { ( cd "$APP_DIR" && docker compose "$@" ); }

write_compose_file() {
  mkdir -p "$APP_DIR" "$DATA_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  postgres:
    image: postgres:17
    restart: unless-stopped
    ports:
      - "5432:5432"
    environment:
      POSTGRES_PASSWORD: ${DBPASSWORD}
    volumes:
      - ${DATA_DIR}:/var/lib/postgresql/data
EOF
}

service_healthy() { docker_compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; }

wait_for_service() {
  local tries=30
  while (( tries > 0 )); do
    service_healthy && return 0
    sleep 2
    tries=$(( tries - 1 ))
  done
  return 1
}

# A SQL dump via pg_dumpall, not a raw file copy: portable across the
# image's own version bumps and restorable with nothing but psql, matching
# the native script's own approach. Run through the container itself
# (`docker compose exec`), not against the bind-mounted directory, since a
# copy of a live cluster's data files is not a safe backup the way an
# explicit dump is.
backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  docker_compose exec -T postgres pg_dumpall -U postgres > "${backup_dir}/dump.sql" 2>/dev/null || true
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/dump.sql" ]] || return 0
  docker_compose exec -T postgres psql -U postgres < "${backup_dir}/dump.sql" >/dev/null 2>&1 || true
}

print_access_info() {
  echo
  ok "PostgreSQL: psql -h $(container_ip) -U postgres"
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "PostgreSQL (Docker) is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "PostgreSQL did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "PostgreSQL (Docker) installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "PostgreSQL (Docker) is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up all databases to ${backup_dir}/dump.sql"

  if ! docker_compose pull; then
    warn "docker compose pull failed — leaving the running container untouched"
    die "update failed, nothing was changed"
  fi

  if ! docker_compose up -d; then
    warn "docker compose up failed after pulling the new image — restoring data from backup"
    restore_state "$backup_dir"
    die "update failed, data restored from ${backup_dir}/dump.sql — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  if ! wait_for_service; then
    warn "PostgreSQL did not come back up healthy after the update — restoring data from backup"
    restore_state "$backup_dir"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, data restored from ${backup_dir}/dump.sql — the image itself is not rolled back by this; check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "PostgreSQL (Docker) is not installed and there is no backed-up data to remove"
  fi

  if is_installed; then
    local backup_dir=""
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    docker_compose down >/dev/null 2>&1 || warn "docker compose down reported an issue — continuing"
    rm -f "$COMPOSE_FILE"
    rm -rf "$DATA_DIR"
    if [[ -n "$backup_dir" ]]; then
      ok "PostgreSQL (Docker) removed, data kept at ${backup_dir}"
    else
      ok "PostgreSQL (Docker) removed"
    fi
  elif [[ -d "$DATA_DIR" ]]; then
    rm -rf "$DATA_DIR"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up data removed"
  fi
}

cmd_status() {
  is_installed || die "PostgreSQL (Docker) is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo "address:  $(container_ip):5432"
  echo
  docker_compose ps 2>&1 || true
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
  if [[ -z "$DBPASSWORD" ]] && [[ -f "$COMPOSE_FILE" ]]; then
    DBPASSWORD="$(sed -n 's/^\s*POSTGRES_PASSWORD:\s*//p' "$COMPOSE_FILE" | head -n1)"
  fi
  case "$cmd" in
    install) cmd_install ;;
    update) cmd_update ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
