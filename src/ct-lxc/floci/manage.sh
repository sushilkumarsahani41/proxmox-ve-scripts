#!/usr/bin/env bash
# In-container management for Floci. Pushed to /usr/local/sbin/floci-
# manage.sh and re-pushed on every command, so the container always matches
# the host script's version.
#
# Unlike AdGuard Home or Pi-hole, there is no vendor shell installer here —
# Floci ships as a Docker image, so this script's job is: get Docker running
# inside this LXC (nothing else in this project needs that), write a
# docker-compose.yaml for the chosen platform + Floci UI, and let `docker
# compose` do what it already does well.
set -Eeuo pipefail

# @include lib/agent-ui.sh

FLOCI_DIR="/opt/floci"
COMPOSE_FILE="${FLOCI_DIR}/compose.yaml"
DATA_DIR="${FLOCI_DIR}/data"
BACKUP_ROOT="/var/backups/floci"
PLATFORM="aws"
PURGE=0

# Kept in sync with the case functions of the same name in the host-side
# main.sh (which is not part of what @embed inlines here) — see the comment
# on svc_install_args there for why this table exists in two places instead
# of one.
platform_image() {
  case "$1" in
    aws)   printf 'floci/floci:latest' ;;
    azure) printf 'floci/floci-az:latest' ;;
    gcp)   printf 'floci/floci-gcp:latest' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

platform_service_name() {
  case "$1" in
    aws)   printf 'floci' ;;
    azure) printf 'floci-az' ;;
    gcp)   printf 'floci-gcp' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

platform_port() {
  case "$1" in
    aws)   printf '4566' ;;
    azure) printf '4577' ;;
    gcp)   printf '4588' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

platform_health_path() {
  case "$1" in
    aws|azure) printf '/_floci/health' ;;
    gcp)       printf '/_floci-gcp/health' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

platform_endpoint_env() {
  case "$1" in
    aws)   printf 'FLOCI_ENDPOINT' ;;
    azure) printf 'FLOCI_AZURE_ENDPOINT' ;;
    gcp)   printf 'FLOCI_GCP_ENDPOINT' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

is_installed() { [[ -f "$COMPOSE_FILE" ]]; }
has_data() { [[ -d "$DATA_DIR" ]] || [[ -d "$BACKUP_ROOT" ]]; }

docker_compose() {
  ( cd "$FLOCI_DIR" && docker compose "$@" )
}

# ensure_docker() lives in lib/agent-ui.sh — shared by every Docker-based
# service in this project, not just this one.

# Writes the compose file fresh every time (install and update both call
# this), so switching how a platform is wired here takes effect on the next
# `update` without anyone having to hand-edit a file inside the container.
write_compose_file() {
  local platform="$1" svc image port endpoint_env
  svc="$(platform_service_name "$platform")"
  image="$(platform_image "$platform")"
  port="$(platform_port "$platform")"
  endpoint_env="$(platform_endpoint_env "$platform")"

  mkdir -p "$FLOCI_DIR" "$DATA_DIR"

  {
    echo "services:"
    echo "  ${svc}:"
    echo "    image: ${image}"
    echo "    restart: unless-stopped"
    echo "    ports:"
    echo "      - \"${port}:${port}\""
    echo "    volumes:"
    # Docker-backed services (Lambda, RDS, ElastiCache, MSK, EKS, and more,
    # depending on platform) need this to spawn and manage sibling
    # containers — see README's "Real Docker Integration" section. Left out
    # entirely means those specific services fail; everything else still
    # works fine without it.
    echo "      - /var/run/docker.sock:/var/run/docker.sock"
    echo "      - ${DATA_DIR}:/app/data"
    echo "    user: root"
    # The `environment:` key itself is only written when there's something
    # under it — an empty mapping isn't valid compose YAML, and only aws
    # currently needs any (see below). Found by actually running this
    # through `docker compose up` for gcp, not by reading the generated file:
    # `services.floci-gcp.environment must be a mapping` — this project's
    # manual pre-write verification tested Azure/Debian by hand with a
    # compose file that simply omitted the key entirely for those platforms,
    # which this function did not originally match.
    if [[ "$platform" == "aws" ]]; then
      echo "    environment:"
      # FLOCI_HOSTNAME: without it, Floci embeds "localhost" into every URL
      # it generates (SQS QueueUrls, SNS callback URLs, ...), which breaks
      # the moment anything other than Floci itself needs to reach that URL
      # — Lambda containers Floci spawns, most notably. Confirmed necessary
      # against a real container, not assumed from the docs alone.
      echo "      FLOCI_HOSTNAME: ${svc}"
      echo "      FLOCI_STORAGE_MODE: persistent"
      echo "      FLOCI_STORAGE_PERSISTENT_PATH: /app/data"
    fi
    echo ""
    echo "  floci-ui:"
    echo "    image: floci/floci-ui:latest"
    echo "    restart: unless-stopped"
    echo "    ports:"
    echo "      - \"4500:4500\""
    echo "    environment:"
    echo "      ${endpoint_env}: http://${svc}:${port}"
    echo "      AWS_REGION: us-east-1"
    echo "      AWS_ACCESS_KEY_ID: test"
    echo "      AWS_SECRET_ACCESS_KEY: test"
    echo "    depends_on:"
    echo "      - ${svc}"
  } > "$COMPOSE_FILE"

  printf '%s' "$platform" > "${FLOCI_DIR}/platform"
}

installed_platform() { cat "${FLOCI_DIR}/platform" 2>/dev/null || echo "aws"; }

service_healthy() {
  local platform="$1" port path
  port="$(platform_port "$platform")"
  path="$(platform_health_path "$platform")"
  curl -fsS -o /dev/null "http://localhost:${port}${path}" 2>/dev/null \
    && curl -fsS -o /dev/null "http://localhost:4500" 2>/dev/null
}

wait_for_service() {
  local platform="$1" tries=30
  while (( tries > 0 )); do
    service_healthy "$platform" && return 0
    sleep 2
    tries=$(( tries - 1 ))
  done
  return 1
}

backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR" "${backup_dir}/data"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/data" ]] || return 0
  rm -rf "$DATA_DIR"
  cp -a "${backup_dir}/data" "$DATA_DIR"
}

print_access_info() {
  echo
  ok "Floci console: http://$(container_ip):4500"
}

cmd_install() {
  require_root
  ensure_pkg curl
  is_installed && die "Floci is already installed — use 'update' instead"

  ensure_docker
  write_compose_file "$PLATFORM"

  info "pulling images and starting Floci (${PLATFORM}) + Floci UI"
  docker_compose up -d || die "docker compose up failed — see: docker compose -f ${COMPOSE_FILE} logs"

  if ! wait_for_service "$PLATFORM"; then
    warn "Floci did not become healthy within the expected time"
    docker_compose ps >&2 || true
    die "install did not verify healthy — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "Floci installed"
  print_access_info
}

# `docker compose pull` + `up -d` recreates any container whose image
# actually changed and leaves the rest alone — this is Docker's own update
# mechanism, not something this project reimplements. The data volume is
# backed up first regardless, since an image update rebuilding a container
# is exactly the kind of operation that's cheap to guard even when it's
# expected to be safe.
cmd_update() {
  require_root
  is_installed || die "Floci is not installed — use 'install' instead"

  local platform backup_dir
  platform="$(installed_platform)"

  # Regenerated, not left as whatever install last wrote: this file is ours,
  # not a vendor's, so a fix to write_compose_file should reach an existing
  # container the same way a fix to this whole script does — on the next
  # command that touches it, matching every other manage.sh in this project.
  write_compose_file "$platform"

  backup_dir="$(backup_state)"
  ok "backed up data to ${backup_dir}"

  if ! docker_compose pull; then
    warn "docker compose pull failed — leaving the running containers untouched"
    die "update failed, nothing was changed"
  fi

  if ! docker_compose up -d; then
    warn "docker compose up failed after pulling new images — restoring data from backup"
    restore_state "$backup_dir"
    die "update failed, data restored from ${backup_dir} — check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  if ! wait_for_service "$platform"; then
    warn "Floci did not come back up healthy after the update — restoring data from backup"
    restore_state "$backup_dir"
    docker_compose up -d >/dev/null 2>&1 || true
    die "update failed, data restored from ${backup_dir} — the images themselves are not rolled back by this, only the data; check: docker compose -f ${COMPOSE_FILE} logs"
  fi

  ok "updated"
  print_access_info
}

# Floci's EC2/RDS/ECS/... support works by spawning further containers of
# its own via the Docker socket — a running "EC2 instance" is a real
# container `docker compose` never declared and therefore does not know to
# stop. Confirmed on a real container: after `docker compose down`, an
# instance launched during testing was still sitting there, exited but not
# removed. Every container Floci spawns this way carries the label
# `floci=true` regardless of which service created it (checked via `docker
# inspect`, not assumed) — a precise, unambiguous filter, unlike matching on
# name prefixes which would risk catching containers `docker compose` itself
# named after our own project. These are always cleaned up, purge or not:
# they are live emulated infrastructure that only means anything while Floci
# is running, not data worth preserving the way /opt/floci/data is.
remove_spawned_containers() {
  docker ps -aq --filter 'label=floci=true' 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1
  return 0
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Floci is not installed and there is no backed-up data to remove"
  fi

  if is_installed; then
    local backup_dir=""
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    docker_compose down >/dev/null 2>&1 || warn "docker compose down reported an issue — continuing"
    remove_spawned_containers
    rm -f "$COMPOSE_FILE" "${FLOCI_DIR}/platform"
    if [[ "$PURGE" -eq 0 ]]; then
      ok "Floci removed, data kept at ${backup_dir}"
    else
      rm -rf "$DATA_DIR"
      ok "Floci removed"
    fi
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up data removed"
  fi

  info "Docker itself was left installed — this removes the Floci stack, not the container's Docker setup"
}

cmd_status() {
  is_installed || die "Floci is not installed"
  local platform port
  platform="$(installed_platform)"
  port="$(platform_port "$platform")"
  echo "platform: ${platform}"
  echo "service:  $(service_healthy "$platform" && echo running || echo unhealthy)"
  echo "console:  http://$(container_ip):4500"
  echo "api:      http://$(container_ip):${port}"
  echo
  docker_compose ps 2>&1 || true
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
      --platform) PLATFORM="$2"; shift 2 ;;
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
