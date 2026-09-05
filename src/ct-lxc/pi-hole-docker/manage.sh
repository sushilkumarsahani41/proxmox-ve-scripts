#!/usr/bin/env bash
# In-container management for Pi-hole (Docker). Pushed to /usr/local/sbin/
# pi-hole-docker-manage.sh and re-pushed on every command, so the container
# always matches the host script's version.
#
# Delegates to the official pihole/pihole image and `docker compose` for
# everything — install/update/uninstall here just means writing the right
# compose file and calling compose, the same principle as every other
# service in this project, applied to a vendor *image* instead of a vendor
# *script*.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/pi-hole-docker"
COMPOSE_FILE="${APP_DIR}/compose.yaml"
DATA_DIR="${APP_DIR}/etc-pihole"
BACKUP_ROOT="/var/backups/pi-hole-docker"
WEBPASSWORD=""
PURGE=0

is_installed() { [[ -f "$COMPOSE_FILE" ]]; }
# Checks both the backup archive and the live data directory: a plain
# uninstall backs up then removes DATA_DIR, but a container could also be
# mid-lifecycle (installed, never uninstalled) or have hit this same check
# after a partial failure — either way, "is there data purge should remove"
# has two possible locations, not one.
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; }
}

docker_compose() { ( cd "$APP_DIR" && docker compose "$@" ); }

# Config is v6's own concern (a fresh container builds gravity and its own
# pihole.toml itself, same as a fresh native install) — only the env vars
# that matter to *this* container's identity are set here.
#
# FTLCONF_dns_listeningMode=ALL: required specifically because this runs on
# Docker's default bridge network (see pi-hole/docker-pi-hole's own docs) —
# without it FTL only answers queries that already look like they came from
# inside the container, which is nothing arriving through the published
# port.
write_compose_file() {
  mkdir -p "$APP_DIR" "$DATA_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  pihole:
    image: pihole/pihole:latest
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80/tcp"
      - "443:443/tcp"
    environment:
      TZ: UTC
      FTLCONF_webserver_api_password: ${WEBPASSWORD}
      FTLCONF_dns_listeningMode: ALL
    volumes:
      - ${DATA_DIR}:/etc/pihole
EOF
}

service_healthy() { curl -fsS -o /dev/null "http://localhost/admin/" 2>/dev/null; }

wait_for_service() {
  local tries=30
  while (( tries > 0 )); do
    service_healthy && return 0
    sleep 2
    tries=$(( tries - 1 ))
  done
  return 1
}

# /etc/pihole holds everything Pi-hole itself considers durable — gravity
# database, custom lists, pihole.toml — so a plain directory copy is a
# complete backup, the same as this project's native Pi-hole script.
backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR" "${backup_dir}/etc-pihole"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/etc-pihole" ]] || return 0
  rm -rf "$DATA_DIR"
  cp -a "${backup_dir}/etc-pihole" "$DATA_DIR"
}

print_access_info() {
  echo
  ok "Pi-hole admin UI: http://$(container_ip)/admin"
}

cmd_install() {
  require_root
  ensure_docker
  is_installed && die "Pi-hole (Docker) is already installed — use 'update' instead"

  write_compose_file
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service; then
    warn "Pi-hole did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "Pi-hole (Docker) installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Pi-hole (Docker) is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up /etc/pihole to ${backup_dir}"

  # The image itself needs the same webpassword re-declared on every
  # `compose up`, or a recreate would fall back to no password at all —
  # write_compose_file needs WEBPASSWORD, which main() below reads from the
  # existing compose file rather than requiring it be passed to `update`.
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
    warn "Pi-hole did not come back up healthy after the update — restoring data from backup"
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
    die "Pi-hole (Docker) is not installed and there is no backed-up data to remove"
  fi

  if is_installed; then
    local backup_dir=""
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    docker_compose down >/dev/null 2>&1 || warn "docker compose down reported an issue — continuing"
    rm -f "$COMPOSE_FILE"
    # Data lives in exactly one place after this, never both: the backup
    # copy just made, or nowhere at all on --purge. Leaving it sitting at
    # DATA_DIR too (its natural, pre-uninstall location) would mean a later
    # `uninstall --purge` — is_installed now false, so it wouldn't even
    # reach this branch — silently leaves it behind; has_data() covers that
    # by checking DATA_DIR too, but simplest is to not leave it split across
    # two locations in the first place.
    rm -rf "$DATA_DIR"
    if [[ -n "$backup_dir" ]]; then
      ok "Pi-hole (Docker) removed, data kept at ${backup_dir}"
    else
      ok "Pi-hole (Docker) removed"
    fi
  elif [[ -d "$DATA_DIR" ]]; then
    # Not installed (compose file already gone) but DATA_DIR survived
    # somehow — e.g. a previous run of this exact bug. Clean it up rather
    # than leave it orphaned forever.
    rm -rf "$DATA_DIR"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up data removed"
  fi
}

cmd_status() {
  is_installed || die "Pi-hole (Docker) is not installed"
  echo "service:  $(service_healthy && echo running || echo unhealthy)"
  echo "address:  http://$(container_ip)/admin"
  echo
  docker_compose ps 2>&1 || true
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
      --webpassword) WEBPASSWORD="$2"; shift 2 ;;
      --purge) PURGE=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  # update/status/uninstall don't receive --webpassword (main.sh only passes
  # it on install) — recover the value already baked into the compose file
  # so a re-written file on update doesn't silently drop the password.
  if [[ -z "$WEBPASSWORD" ]] && [[ -f "$COMPOSE_FILE" ]]; then
    WEBPASSWORD="$(sed -n 's/^\s*FTLCONF_webserver_api_password:\s*//p' "$COMPOSE_FILE" | head -n1)"
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
