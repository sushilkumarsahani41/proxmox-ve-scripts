#!/usr/bin/env bash
# In-container management for Jellyfin (Docker). Pushed to
# /usr/local/sbin/jellyfin-docker-manage.sh and re-pushed on every command,
# so the container always matches the host script's version.
#
# Delegates to the official jellyfin/jellyfin image and `docker compose` for
# everything — the same principle as this project's native Jellyfin script,
# applied to a vendor *image* instead of a vendor *installer*.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/jellyfin-docker"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
CONFIG_DIR="${APP_DIR}/config"
CACHE_DIR="${APP_DIR}/cache"
MEDIA_DIR="${APP_DIR}/media"
BACKUP_ROOT="/var/backups/jellyfin-docker"
PURGE=0

is_installed() { [[ -f "$COMPOSE_FILE" ]]; }
# Only CONFIG_DIR — never MEDIA_DIR, which is the user's own media, not
# Jellyfin's generated state (see cmd_uninstall for why it's never removed).
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$CONFIG_DIR" ]] && [[ -n "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]]; }
}

docker_compose() { ( cd "$APP_DIR" && docker compose "$@" ); }

write_compose_file() {
  mkdir -p "$APP_DIR" "$CONFIG_DIR" "$CACHE_DIR" "$MEDIA_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    restart: unless-stopped
    ports:
      - "8096:8096"
      - "7359:7359/udp"
    volumes:
      - ${CONFIG_DIR}:/config
      - ${CACHE_DIR}:/cache
      - ${MEDIA_DIR}:/media
EOF
}

service_healthy() {
  curl -fsS -o /dev/null "http://localhost:8096/health" 2>/dev/null \
    || curl -fsS -o /dev/null "http://localhost:8096/" 2>/dev/null
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

# CONFIG_DIR only — CACHE_DIR is pure transcode scratch space (not worth
# backing up, will just repopulate) and MEDIA_DIR is the user's own media,
# not Jellyfin's data, and could be arbitrarily large besides.
backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d "$CONFIG_DIR" ]] && cp -a "$CONFIG_DIR" "${backup_dir}/config"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/config" ]] || return 0
  rm -rf "$CONFIG_DIR"
  cp -a "${backup_dir}/config" "$CONFIG_DIR"
}

print_access_info() {
  echo
  ok "Jellyfin setup wizard: http://$(container_ip):8096"
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "Jellyfin (Docker) is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "Jellyfin did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "Jellyfin (Docker) installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Jellyfin (Docker) is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up config to ${backup_dir}"

  if ! docker_compose pull; then
    warn "docker compose pull failed — leaving the running container untouched"
    die "update failed, nothing was changed"
  fi

  if ! docker_compose up -d; then
    warn "docker compose up failed after pulling the new image — restoring config from backup"
    restore_state "$backup_dir"
    die "update failed, config restored from ${backup_dir} — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  if ! wait_for_service; then
    warn "Jellyfin did not come back up healthy after the update — restoring config from backup"
    restore_state "$backup_dir"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, config restored from ${backup_dir} — the image itself is not rolled back by this; check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "updated"
  print_access_info
}

# Never touches MEDIA_DIR, purge or not — that directory holds whatever the
# user copied or mounted in themselves, not anything Jellyfin generated.
# "uninstall keeps data unless --purge" is about Jellyfin's own state
# (config, thumbnails, the metadata database), not about deleting someone's
# actual media library as a side effect of removing the server that plays it.
cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Jellyfin (Docker) is not installed and there is no backed-up data to remove"
  fi

  if is_installed; then
    local backup_dir=""
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    docker_compose down >/dev/null 2>&1 || warn "docker compose down reported an issue — continuing"
    rm -f "$COMPOSE_FILE"
    rm -rf "$CONFIG_DIR" "$CACHE_DIR"
    if [[ -n "$backup_dir" ]]; then
      ok "Jellyfin (Docker) removed, config kept at ${backup_dir} — media at ${MEDIA_DIR} left untouched"
    else
      ok "Jellyfin (Docker) removed — media at ${MEDIA_DIR} left untouched"
    fi
  elif [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR" "$CACHE_DIR"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up data removed"
  fi
}

cmd_status() {
  is_installed || die "Jellyfin (Docker) is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo "address:  http://$(container_ip):8096"
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
