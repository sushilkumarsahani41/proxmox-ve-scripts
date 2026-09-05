#!/usr/bin/env bash
# In-container management for Valkey (Docker). Pushed to
# /usr/local/sbin/valkey-docker-manage.sh and re-pushed on every command, so
# the container always matches the host script's version.
#
# Delegates to the official valkey/valkey image and `docker compose` for
# everything — the same principle as this project's native Valkey script,
# applied to a vendor *image* instead of a vendor *package*. The image takes
# no password environment variable (checked directly against its own docs,
# not assumed from how postgres/mariadb's images work) — `requirepass` is
# passed as a `command:` override instead, the same flag `valkey-server`
# accepts anywhere else.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/valkey-docker"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
DATA_DIR="${APP_DIR}/data"
BACKUP_ROOT="/var/backups/valkey-docker"
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
  valkey:
    image: valkey/valkey:8
    restart: unless-stopped
    command: ["valkey-server", "--requirepass", "${DBPASSWORD}", "--bind", "0.0.0.0", "-::1"]
    ports:
      - "6379:6379"
    volumes:
      - ${DATA_DIR}:/data
EOF
}

service_healthy() {
  docker_compose exec -T valkey valkey-cli -a "${DBPASSWORD}" --no-auth-warning ping 2>/dev/null | grep -q PONG
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
  docker_compose exec -T valkey valkey-cli -a "${DBPASSWORD}" --no-auth-warning SAVE >/dev/null 2>&1 || true
  [[ -f "${DATA_DIR}/dump.rdb" ]] && cp -a "${DATA_DIR}/dump.rdb" "${backup_dir}/dump.rdb"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/dump.rdb" ]] || return 0
  cp -a "${backup_dir}/dump.rdb" "${DATA_DIR}/dump.rdb"
}

print_access_info() {
  echo
  ok "Valkey: valkey-cli -h $(container_ip) -a '<password>'"
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "Valkey (Docker) is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "Valkey did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "Valkey (Docker) installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Valkey (Docker) is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up the dataset to ${backup_dir}/dump.rdb"

  if ! docker_compose pull; then
    warn "docker compose pull failed — leaving the running container untouched"
    die "update failed, nothing was changed"
  fi

  if ! docker_compose up -d; then
    warn "docker compose up failed after pulling the new image — restoring data from backup"
    restore_state "$backup_dir"
    die "update failed, data restored from ${backup_dir}/dump.rdb — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  if ! wait_for_service; then
    warn "Valkey did not come back up healthy after the update — restoring data from backup"
    restore_state "$backup_dir"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, data restored from ${backup_dir}/dump.rdb — the image itself is not rolled back by this; check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Valkey (Docker) is not installed and there is no backed-up data to remove"
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
      ok "Valkey (Docker) removed, data kept at ${backup_dir}"
    else
      ok "Valkey (Docker) removed"
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
  is_installed || die "Valkey (Docker) is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo "address:  $(container_ip):6379"
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
    DBPASSWORD="$(sed -n 's/.*--requirepass", "\([^"]*\)".*/\1/p' "$COMPOSE_FILE" | head -n1)"
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
