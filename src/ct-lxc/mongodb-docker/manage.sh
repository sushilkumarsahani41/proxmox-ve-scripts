#!/usr/bin/env bash
# In-container management for MongoDB (Docker). Pushed to
# /usr/local/sbin/mongodb-docker-manage.sh and re-pushed on every command, so
# the container always matches the host script's version.
#
# Delegates to the official mongo image and `docker compose` for everything.
# The image runs with no authentication at all unless both
# MONGO_INITDB_ROOT_USERNAME and MONGO_INITDB_ROOT_PASSWORD are set at first
# init — checked directly against the image's own entrypoint behaviour, not
# assumed from how postgres/mariadb's images work (those default to a
# password-required superuser either way).
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/mongodb-docker"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
DATA_DIR="${APP_DIR}/data"
BACKUP_ROOT="/var/backups/mongodb-docker"
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
  mongo:
    image: mongo:8
    restart: unless-stopped
    ports:
      - "27017:27017"
    environment:
      MONGO_INITDB_ROOT_USERNAME: root
      MONGO_INITDB_ROOT_PASSWORD: ${DBPASSWORD}
    volumes:
      - ${DATA_DIR}:/data/db
EOF
}

service_healthy() {
  docker_compose exec -T mongo mongosh --quiet --eval 'db.adminCommand("ping")' \
    -u root -p "${DBPASSWORD}" --authenticationDatabase admin >/dev/null 2>&1
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
  docker_compose exec -T mongo mongodump -u root -p "${DBPASSWORD}" --authenticationDatabase admin --archive \
    > "${backup_dir}/dump.archive" 2>/dev/null || true
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/dump.archive" ]] || return 0
  docker_compose exec -T mongo mongorestore -u root -p "${DBPASSWORD}" --authenticationDatabase admin --archive \
    < "${backup_dir}/dump.archive" >/dev/null 2>&1 || true
}

print_access_info() {
  echo
  ok "MongoDB: mongosh \"mongodb://root:<password>@$(container_ip):27017\""
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "MongoDB (Docker) is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "MongoDB did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "MongoDB (Docker) installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "MongoDB (Docker) is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up all databases to ${backup_dir}/dump.archive"

  if ! docker_compose pull; then
    warn "docker compose pull failed — leaving the running container untouched"
    die "update failed, nothing was changed"
  fi

  if ! docker_compose up -d; then
    warn "docker compose up failed after pulling the new image — restoring data from backup"
    restore_state "$backup_dir"
    die "update failed, data restored from ${backup_dir}/dump.archive — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  if ! wait_for_service; then
    warn "MongoDB did not come back up healthy after the update — restoring data from backup"
    restore_state "$backup_dir"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, data restored from ${backup_dir}/dump.archive — the image itself is not rolled back by this; check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "MongoDB (Docker) is not installed and there is no backed-up data to remove"
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
      ok "MongoDB (Docker) removed, data kept at ${backup_dir}"
    else
      ok "MongoDB (Docker) removed"
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
  is_installed || die "MongoDB (Docker) is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo "address:  $(container_ip):27017"
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
    DBPASSWORD="$(sed -n 's/^\s*MONGO_INITDB_ROOT_PASSWORD:\s*//p' "$COMPOSE_FILE" | head -n1)"
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
