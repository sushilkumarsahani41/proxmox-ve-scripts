#!/usr/bin/env bash
# In-container management for AdGuard Home (Docker). Pushed to
# /usr/local/sbin/adguard-home-docker-manage.sh and re-pushed on every
# command, so the container always matches the host script's version.
#
# Delegates to the official adguard/adguardhome image and `docker compose`
# for everything — the same principle as this project's native AdGuard Home
# script, applied to a vendor *image* instead of a vendor *script*.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/adguard-home-docker"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
WORK_DIR="${APP_DIR}/work"
CONF_DIR="${APP_DIR}/conf"
BACKUP_ROOT="/var/backups/adguard-home-docker"
PURGE=0

is_installed() { [[ -f "$COMPOSE_FILE" ]]; }
# Checks both the backup archive and the live data directories: a plain
# uninstall backs up then removes WORK_DIR/CONF_DIR, but a container could
# also be mid-lifecycle (installed, never uninstalled) or have hit this same
# check after a partial failure — either way, "is there data purge should
# remove" has two possible locations, not one.
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$WORK_DIR" ]] && [[ -n "$(ls -A "$WORK_DIR" 2>/dev/null)" ]]; } \
    || { [[ -d "$CONF_DIR" ]] && [[ -n "$(ls -A "$CONF_DIR" 2>/dev/null)" ]]; }
}

docker_compose() { ( cd "$APP_DIR" && docker compose "$@" ); }

# Ports match AdGuard's own documented set for admin panel + HTTPS/DoH (see
# their Docker knowledge-base article) — DHCP (67/68) and DNSCrypt (5443)
# are left out, same as this project's native AdGuard Home script never
# configures either.
write_compose_file() {
  mkdir -p "$APP_DIR" "$WORK_DIR" "$CONF_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  adguardhome:
    image: adguard/adguardhome:latest
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:3000/tcp"
      - "80:80/tcp"
      - "443:443/tcp"
      - "443:443/udp"
    volumes:
      - ${WORK_DIR}:/opt/adguardhome/work
      - ${CONF_DIR}:/opt/adguardhome/conf
EOF
}

service_healthy() { curl -fsS -o /dev/null "http://localhost:3000/" 2>/dev/null || curl -fsS -o /dev/null "http://localhost/" 2>/dev/null; }

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
  [[ -d "$WORK_DIR" ]] && cp -a "$WORK_DIR" "${backup_dir}/work"
  [[ -d "$CONF_DIR" ]] && cp -a "$CONF_DIR" "${backup_dir}/conf"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/work" ]] && { rm -rf "$WORK_DIR"; cp -a "${backup_dir}/work" "$WORK_DIR"; }
  [[ -d "${backup_dir}/conf" ]] && { rm -rf "$CONF_DIR"; cp -a "${backup_dir}/conf" "$CONF_DIR"; }
}

print_access_info() {
  echo
  ok "AdGuard Home setup wizard: http://$(container_ip):3000"
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "AdGuard Home (Docker) is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "AdGuard Home did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "AdGuard Home (Docker) installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "AdGuard Home (Docker) is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up config/work to ${backup_dir}"

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
    warn "AdGuard Home did not come back up healthy after the update — restoring data from backup"
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
    die "AdGuard Home (Docker) is not installed and there is no backed-up data to remove"
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
    rm -rf "$WORK_DIR" "$CONF_DIR"
    if [[ -n "$backup_dir" ]]; then
      ok "AdGuard Home (Docker) removed, data kept at ${backup_dir}"
    else
      ok "AdGuard Home (Docker) removed"
    fi
  elif [[ -d "$WORK_DIR" ]] || [[ -d "$CONF_DIR" ]]; then
    # Not installed (compose file already gone) but data survived somehow —
    # e.g. a previous run of this exact bug. Clean it up rather than leave
    # it orphaned forever.
    rm -rf "$WORK_DIR" "$CONF_DIR"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up data removed"
  fi
}

cmd_status() {
  is_installed || die "AdGuard Home (Docker) is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo "address:  http://$(container_ip):3000"
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
