#!/usr/bin/env bash
# In-container management for Traefik (Docker). Pushed to
# /usr/local/sbin/traefik-docker-manage.sh and re-pushed on every command,
# so the container always matches the host script's version.
#
# Delegates to the official traefik image (a genuine Docker Official Image —
# confirmed against Docker Hub's own library namespace, not a vendor's own
# unofficial upload) and `docker compose` for everything — the same
# principle as this project's native Traefik script, applied to a vendor
# *image* instead of a vendor-less binary this project has to package itself.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/traefik-docker"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
CONFIG_DIR="${APP_DIR}/config"
STATIC_CONF="${CONFIG_DIR}/traefik.yml"
DYNAMIC_CONF="${CONFIG_DIR}/dynamic.yml"
BACKUP_ROOT="/var/backups/traefik-docker"
PURGE=0

is_installed() { [[ -f "$COMPOSE_FILE" ]]; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$CONFIG_DIR" ]] && [[ -n "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]]; }
}

docker_compose() { ( cd "$APP_DIR" && docker compose "$@" ); }

write_config() {
  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$STATIC_CONF" ]]; then
    cat > "$STATIC_CONF" <<EOF
entryPoints:
  web:
    address: ":80"

api:
  dashboard: true
  insecure: true

ping: {}

providers:
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true

log:
  level: INFO
EOF
  fi
  if [[ ! -f "$DYNAMIC_CONF" ]]; then
    cat > "$DYNAMIC_CONF" <<'EOF'
# Traefik watches this file and reloads automatically — no restart needed.
# Example:
#
# http:
#   routers:
#     my-app:
#       rule: "Host(`app.example.com`)"
#       service: my-app
#   services:
#     my-app:
#       loadBalancer:
#         servers:
#           - url: "http://192.168.1.50:8080"
http: {}
EOF
  fi
}

write_compose_file() {
  mkdir -p "$APP_DIR"
  write_config
  cat > "$COMPOSE_FILE" <<EOF
services:
  traefik:
    image: traefik:v3.7
    restart: unless-stopped
    command:
      - "--configFile=/etc/traefik/traefik.yml"
    ports:
      - "80:80"
      - "8080:8080"
    volumes:
      - ${CONFIG_DIR}:/etc/traefik
EOF
}

service_healthy() { curl -fsS "http://localhost:8080/ping" 2>/dev/null | grep -q '^OK$'; }

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
  ok "Traefik dashboard: http://$(container_ip):8080/dashboard/"
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "Traefik (Docker) is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "Traefik did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "Traefik (Docker) installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Traefik (Docker) is not installed — use 'install' instead"

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
    warn "Traefik did not come back up healthy after the update — restoring config from backup"
    restore_state "$backup_dir"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, config restored from ${backup_dir} — the image itself is not rolled back by this; check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Traefik (Docker) is not installed and there is no backed-up data to remove"
  fi

  if is_installed; then
    local backup_dir=""
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    docker_compose down >/dev/null 2>&1 || warn "docker compose down reported an issue — continuing"
    rm -f "$COMPOSE_FILE"
    rm -rf "$CONFIG_DIR"
    if [[ -n "$backup_dir" ]]; then
      ok "Traefik (Docker) removed, config kept at ${backup_dir}"
    else
      ok "Traefik (Docker) removed"
    fi
  elif [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up data removed"
  fi
}

cmd_status() {
  is_installed || die "Traefik (Docker) is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo "address:  http://$(container_ip):8080/dashboard/"
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
