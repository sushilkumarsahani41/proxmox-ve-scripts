#!/usr/bin/env bash
# In-container management for Nginx Proxy Manager. Pushed to
# /usr/local/sbin/nginx-proxy-manager-manage.sh and re-pushed on every
# command, so the container always matches the host script's version.
#
# Delegates to the jc21/nginx-proxy-manager image and `docker compose` for
# everything — the image the project's own docs point at, since there is no
# vendor apt package or install script to delegate to instead.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/nginx-proxy-manager"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
DATA_DIR="${APP_DIR}/data"
LETSENCRYPT_DIR="${APP_DIR}/letsencrypt"
BACKUP_ROOT="/var/backups/nginx-proxy-manager"
PURGE=0

is_installed() { [[ -f "$COMPOSE_FILE" ]]; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; }
}

docker_compose() { ( cd "$APP_DIR" && docker compose "$@" ); }

write_compose_file() {
  mkdir -p "$APP_DIR" "$DATA_DIR" "$LETSENCRYPT_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - ${DATA_DIR}:/data
      - ${LETSENCRYPT_DIR}:/etc/letsencrypt
EOF
}

# No dedicated health endpoint is documented — the admin UI's own login
# page (a 200 on its root path) is the same fallback this project already
# uses for other services with no cleaner signal (see adguard-home-docker).
service_healthy() { curl -fsS -o /dev/null "http://localhost:81/" 2>/dev/null; }

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
  [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR" "${backup_dir}/data"
  [[ -d "$LETSENCRYPT_DIR" ]] && cp -a "$LETSENCRYPT_DIR" "${backup_dir}/letsencrypt"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/data" ]] && { rm -rf "$DATA_DIR"; cp -a "${backup_dir}/data" "$DATA_DIR"; }
  [[ -d "${backup_dir}/letsencrypt" ]] && { rm -rf "$LETSENCRYPT_DIR"; cp -a "${backup_dir}/letsencrypt" "$LETSENCRYPT_DIR"; }
}

print_access_info() {
  echo
  ok "Nginx Proxy Manager: http://$(container_ip):81"
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "Nginx Proxy Manager is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "Nginx Proxy Manager did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "Nginx Proxy Manager installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Nginx Proxy Manager is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up data/certificates to ${backup_dir}"

  if ! docker_compose pull; then
    warn "docker compose pull failed — leaving the running container untouched"
    die "update failed, nothing was changed"
  fi

  if ! docker_compose up -d; then
    warn "docker compose up failed after pulling the new image — restoring data from backup"
    restore_state "$backup_dir"
    die "update failed, data restored from ${backup_dir} — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  if ! wait_for_service; then
    warn "Nginx Proxy Manager did not come back up healthy after the update — restoring data from backup"
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
    die "Nginx Proxy Manager is not installed and there is no backed-up data to remove"
  fi

  if is_installed; then
    local backup_dir=""
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    docker_compose down >/dev/null 2>&1 || warn "docker compose down reported an issue — continuing"
    rm -f "$COMPOSE_FILE"
    rm -rf "$DATA_DIR" "$LETSENCRYPT_DIR"
    if [[ -n "$backup_dir" ]]; then
      ok "Nginx Proxy Manager removed, data kept at ${backup_dir}"
    else
      ok "Nginx Proxy Manager removed"
    fi
  elif [[ -d "$DATA_DIR" ]] || [[ -d "$LETSENCRYPT_DIR" ]]; then
    rm -rf "$DATA_DIR" "$LETSENCRYPT_DIR"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up data removed"
  fi
}

cmd_status() {
  is_installed || die "Nginx Proxy Manager is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo "address:  http://$(container_ip):81"
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
