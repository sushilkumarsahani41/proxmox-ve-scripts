#!/usr/bin/env bash
# In-container management for SharkShell (Docker). Pushed to /usr/local/
# sbin/sharkshell-docker-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Delegates to the official greatsharktech/sharkshell image and `docker
# compose` for everything — the same principle as this project's
# source-build SharkShell script, applied to a vendor *image* instead of a
# vendor *script*.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/sharkshell-docker"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
PGDATA_DIR="${APP_DIR}/pgdata"
SECRETS_DIR="${APP_DIR}/secrets"
BACKUP_ROOT="/var/backups/sharkshell-docker"
HEALTH_URL="http://127.0.0.1/api/auth/setup-status"
PURGE=0

is_installed() { [[ -f "$COMPOSE_FILE" ]]; }
# Checks both the backup archive and the live data directories: a plain
# uninstall backs up then removes PGDATA_DIR/SECRETS_DIR, but a container
# could also be mid-lifecycle (installed, never uninstalled) or have hit this
# same check after a partial failure — either way, "is there data purge
# should remove" has two possible locations, not one.
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$PGDATA_DIR" ]] && [[ -n "$(ls -A "$PGDATA_DIR" 2>/dev/null)" ]]; } \
    || { [[ -d "$SECRETS_DIR" ]] && [[ -n "$(ls -A "$SECRETS_DIR" 2>/dev/null)" ]]; }
}

docker_compose() { ( cd "$APP_DIR" && docker compose "$@" ); }

# Bind mounts, not the named volumes the project's own docker-compose.yml
# uses — functionally identical to Docker, but a known host path is what
# lets backup_state() below just be a directory copy instead of a
# `docker run --rm -v ...:/data ... tar` dance.
write_compose_file() {
  mkdir -p "$APP_DIR" "$PGDATA_DIR" "$SECRETS_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  sharkshell:
    image: greatsharktech/sharkshell:latest
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ${PGDATA_DIR}:/app/pgdata
      - ${SECRETS_DIR}:/app/secrets
EOF
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

# The image runs its own Postgres inside the same container, backed by the
# bind-mounted pgdata directory — a plain file copy of that directory is
# only safe (crash-consistent) while Postgres isn't writing to it, so this
# stops the container first. Not extra disruption in practice: both callers
# (cmd_update, cmd_uninstall) already restart or remove the container right
# afterward.
backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  docker_compose stop >/dev/null 2>&1 || true
  [[ -d "$PGDATA_DIR" ]] && cp -a "$PGDATA_DIR" "${backup_dir}/pgdata"
  [[ -d "$SECRETS_DIR" ]] && cp -a "$SECRETS_DIR" "${backup_dir}/secrets"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/pgdata" ]] && { rm -rf "$PGDATA_DIR"; cp -a "${backup_dir}/pgdata" "$PGDATA_DIR"; }
  [[ -d "${backup_dir}/secrets" ]] && { rm -rf "$SECRETS_DIR"; cp -a "${backup_dir}/secrets" "$SECRETS_DIR"; }
}

print_access_info() {
  echo
  ok "SharkShell: http://$(container_ip)"
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "SharkShell (Docker) is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "SharkShell did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "SharkShell (Docker) installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "SharkShell (Docker) is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up data to ${backup_dir}"

  if ! docker_compose pull; then
    warn "docker compose pull failed — restarting the existing container untouched"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, nothing was changed"
  fi

  if ! docker_compose up -d; then
    warn "docker compose up failed after pulling the new image — restoring data from backup"
    restore_state "$backup_dir"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, data restored from ${backup_dir} — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  if ! wait_for_service; then
    warn "SharkShell did not come back up healthy after the update — restoring data from backup"
    restore_state "$backup_dir"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, data restored from ${backup_dir} — the image itself is not rolled back by this; check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "SharkShell (Docker) is not installed and there is no backed-up data to remove"
  fi

  if is_installed; then
    local backup_dir=""
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    docker_compose down >/dev/null 2>&1 || warn "docker compose down reported an issue — continuing"
    rm -f "$COMPOSE_FILE"
    # Data lives in exactly one place after this, never both: the backup
    # copy just made, or nowhere at all on --purge.
    rm -rf "$PGDATA_DIR" "$SECRETS_DIR"
    if [[ -n "$backup_dir" ]]; then
      ok "SharkShell (Docker) removed, data kept at ${backup_dir}"
    else
      ok "SharkShell (Docker) removed"
    fi
  elif [[ -d "$PGDATA_DIR" ]] || [[ -d "$SECRETS_DIR" ]]; then
    # Not installed (compose file already gone) but data survived somehow —
    # e.g. a previous run of this exact bug. Clean it up rather than leave
    # it orphaned forever.
    rm -rf "$PGDATA_DIR" "$SECRETS_DIR"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up data removed"
  fi
}

cmd_status() {
  is_installed || die "SharkShell (Docker) is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo "address:  http://$(container_ip)"
  echo
  docker_compose ps 2>&1 || true
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
