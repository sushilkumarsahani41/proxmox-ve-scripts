#!/usr/bin/env bash
# In-container management for Tailscale (Docker). Pushed to
# /usr/local/sbin/tailscale-docker-manage.sh and re-pushed on every command,
# so the container always matches the host script's version.
#
# Delegates to the official tailscale/tailscale image and `docker compose`
# for everything — confirmed genuinely multi-arch (amd64/arm64/386/arm) via
# Docker Hub directly. The container needs its own NET_ADMIN capability and
# /dev/net/tun device on top of the LXC-level passthrough this project's
# lib/pve.sh already grants the container itself (see enable_tun_device) —
# two separate layers, both required, neither substitutes for the other.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/tailscale-docker"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
STATE_DIR="${APP_DIR}/state"
BACKUP_ROOT="/var/backups/tailscale-docker"
AUTH_KEY=""
PURGE=0

is_installed() { [[ -f "$COMPOSE_FILE" ]]; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$STATE_DIR" ]] && [[ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]]; }
}

docker_compose() { ( cd "$APP_DIR" && docker compose "$@" ); }

write_compose_file() {
  mkdir -p "$APP_DIR" "$STATE_DIR"
  local authkey_line=""
  if [[ -n "$AUTH_KEY" ]]; then
    authkey_line="      TS_AUTHKEY: ${AUTH_KEY}"
  fi
  cat > "$COMPOSE_FILE" <<EOF
services:
  tailscale:
    image: tailscale/tailscale:stable
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      TS_STATE_DIR: /var/lib/tailscale
${authkey_line}
    volumes:
      - ${STATE_DIR}:/var/lib/tailscale
EOF
}

# `tailscale status` exits non-zero for a logged-out node — a perfectly
# healthy state for a fresh install with no --authkey, not a failure. Found
# live: the container came up fine and even printed a real login URL, but
# this check still reported it unhealthy. `tailscale version` only proves
# the CLI can reach the daemon at all, regardless of tailnet login state —
# the same thing the native script's `systemctl is-active tailscaled` check
# verifies, just phrased for a CLI instead of a service manager.
service_healthy() { docker_compose exec -T tailscale tailscale version >/dev/null 2>&1; }

wait_for_service() {
  local tries=15
  while (( tries > 0 )); do
    service_healthy && return 0
    sleep 1
    tries=$(( tries - 1 ))
  done
  return 1
}

backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d "$STATE_DIR" ]] && cp -a "$STATE_DIR" "${backup_dir}/state"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/state" ]] || return 0
  rm -rf "$STATE_DIR"
  cp -a "${backup_dir}/state" "$STATE_DIR"
}

print_access_info() {
  echo
  if docker_compose exec -T tailscale tailscale ip -4 >/dev/null 2>&1; then
    ok "Tailscale: $(docker_compose exec -T tailscale tailscale ip -4 2>/dev/null | head -n1) (joined the tailnet)"
  else
    ok "Tailscale (Docker) installed, not yet joined a tailnet — run: docker compose -f ${COMPOSE_FILE} exec tailscale tailscale up"
  fi
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "Tailscale (Docker) is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "Tailscale did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "Tailscale (Docker) installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Tailscale (Docker) is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up state to ${backup_dir}"

  if ! docker_compose pull; then
    warn "docker compose pull failed — leaving the running container untouched"
    die "update failed, nothing was changed"
  fi

  if ! docker_compose up -d; then
    warn "docker compose up failed after pulling the new image — restoring state from backup"
    restore_state "$backup_dir"
    die "update failed, state restored from ${backup_dir} — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  if ! wait_for_service; then
    warn "Tailscale did not come back up healthy after the update — restoring state from backup"
    restore_state "$backup_dir"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, state restored from ${backup_dir} — the image itself is not rolled back by this; check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Tailscale (Docker) is not installed and there is no backed-up data to remove"
  fi

  if is_installed; then
    local backup_dir=""
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    docker_compose exec -T tailscale tailscale logout >/dev/null 2>&1 || true
    docker_compose down >/dev/null 2>&1 || warn "docker compose down reported an issue — continuing"
    rm -f "$COMPOSE_FILE"
    rm -rf "$STATE_DIR"
    if [[ -n "$backup_dir" ]]; then
      ok "Tailscale (Docker) removed, state kept at ${backup_dir}"
    else
      ok "Tailscale (Docker) removed"
    fi
  elif [[ -d "$STATE_DIR" ]]; then
    rm -rf "$STATE_DIR"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up data removed"
  fi
}

cmd_status() {
  is_installed || die "Tailscale (Docker) is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo
  docker_compose exec -T tailscale tailscale status 2>&1 || true
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
      --authkey) AUTH_KEY="$2"; shift 2 ;;
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
