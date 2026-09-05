#!/usr/bin/env bash
#
# adguard-home-docker-lxc.sh — AdGuard Home via Docker on Proxmox VE, create
# to teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/adguard-home-lxc.sh, which
# installs AdGuard Home natively (no Docker). Same service, different
# packaging — pick this one if you'd rather manage it as a container
# (pull-based updates, the official image).
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official adguard/adguardhome image
#   update <ctid>       Back up the config/work directories, then
#                       `docker compose pull && up -d` — restores the
#                       backup if health looks wrong afterward (the image
#                       itself isn't rolled back, only the data)
#   uninstall <ctid>    `docker compose down` (--purge also removes the
#                       data directories and backups)
#   status <ctid>       Show container status and the admin UI's health
#
# Usage:
#   ./adguard-home-docker-lxc.sh create [options]
#   ./adguard-home-docker-lxc.sh update <ctid>
#   ./adguard-home-docker-lxc.sh uninstall <ctid> [--purge]
#   ./adguard-home-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: adguard-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 1024 — Docker's own daemon
#                           adds overhead beyond AdGuard Home itself)
#   --static <cidr>        Static IP, e.g. 192.168.1.55/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation) — works for both
#                           `ssh root@<ip>` and `pct enter <ctid>` (the
#                           latter needs no password at all)
#
# There is no --webpassword-style flag here, same as the native version:
# AdGuard Home's own Docker image has no env var for seeding the admin
# account either — open the URL this prints and complete the setup wizard.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has
# no Alpine path.
#
# This needs internet access from the container to pull the image, and
# again on every `update`.
#
# ---------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT.
# Built by build.sh from src/ct-lxc/adguard-home-docker/main.sh and src/lib/*.sh.
# Edit the source, then run ./build.sh. See CONTRIBUTING.md.
# ---------------------------------------------------------------------------

PVS_SCRIPT_FILENAME="adguard-home-docker-lxc.sh"
PVS_SCRIPT_URL="https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/ct-lxc/adguard-home-docker-lxc.sh"

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="adguard-home-docker"
SERVICE_NAME="AdGuard Home (Docker)"
# @tagline AdGuard Home via the official Docker image

DEFAULT_HOSTNAME="adguard-docker"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"
# Docker needs both, verified together on a real host (see CONTRIBUTING.md).
# get.docker.com has no Alpine path, so this is Debian-only, same as Floci.
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

pvs_usage_text() {
cat <<'EOF_PVS_USAGE'

adguard-home-docker-lxc.sh — AdGuard Home via Docker on Proxmox VE, create
to teardown. Run this on a PVE host, as root.

This is the Docker counterpart to ct-lxc/adguard-home-lxc.sh, which
installs AdGuard Home natively (no Docker). Same service, different
packaging — pick this one if you'd rather manage it as a container
(pull-based updates, the official image).

  create              Create a Debian LXC with Docker inside it, then run
                      the official adguard/adguardhome image
  update <ctid>       Back up the config/work directories, then
                      `docker compose pull && up -d` — restores the
                      backup if health looks wrong afterward (the image
                      itself isn't rolled back, only the data)
  uninstall <ctid>    `docker compose down` (--purge also removes the
                      data directories and backups)
  status <ctid>       Show container status and the admin UI's health

Usage:
  ./adguard-home-docker-lxc.sh create [options]
  ./adguard-home-docker-lxc.sh update <ctid>
  ./adguard-home-docker-lxc.sh uninstall <ctid> [--purge]
  ./adguard-home-docker-lxc.sh status <ctid>

create options:
  -y, --defaults         Skip the questions and use the recommended values
  -i, --id <id>          Container ID (default: next free ID)
  -n, --hostname <name>  Container hostname (default: adguard-docker)
  -s, --storage <name>   Storage for the rootfs (default: auto-detected)
  -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
  -b, --bridge <name>    Network bridge (default: vmbr0)
  -d, --disk <GB>        Disk size in GB (default: 4)
  -c, --cores <n>        CPU cores (default: 1)
  -m, --memory <MB>      RAM in MB (default: 1024 — Docker's own daemon
                          adds overhead beyond AdGuard Home itself)
  --static <cidr>        Static IP, e.g. 192.168.1.55/24 (default: dhcp)
  --gateway <ip>         Gateway, required with --static
  --password <pass>      Container root password (default: random, shown
                          once after creation) — works for both
                          `ssh root@<ip>` and `pct enter <ctid>` (the
                          latter needs no password at all)

There is no --webpassword-style flag here, same as the native version:
AdGuard Home's own Docker image has no env var for seeding the admin
account either — open the URL this prints and complete the setup wizard.

Run with no options on a terminal and it asks about each setting, showing
the recommended value in brackets — Enter accepts it. Pass any option (or
-y) and it runs straight through without asking, so scripts stay
predictable.

Debian only, no --os choice: get.docker.com (Docker's own installer) has
no Alpine path.

This needs internet access from the container to pull the image, and
again on every `update`.
EOF_PVS_USAGE
}
manage_script() {
cat <<'EOF_MANAGE_SCRIPT'
#!/usr/bin/env bash
# In-container management for AdGuard Home (Docker). Pushed to
# /usr/local/sbin/adguard-home-docker-manage.sh and re-pushed on every
# command, so the container always matches the host script's version.
#
# Delegates to the official adguard/adguardhome image and `docker compose`
# for everything — the same principle as this project's native AdGuard Home
# script, applied to a vendor *image* instead of a vendor *script*.
set -Eeuo pipefail

# lib/agent-ui.sh — the small preamble every in-container management script
# needs. Kept separate from lib/ui.sh because this half runs inside the
# container (no spinner, no banner, no Proxmox anything) and gets embedded
# into the host script as a string, not executed alongside it.

if [[ -t 1 ]]; then
  C_INFO="\033[36m"; C_OK="\033[32m"; C_ERR="\033[31m"; C_WARN="\033[33m"; C_RESET="\033[0m"
else
  C_INFO=""; C_OK=""; C_ERR=""; C_WARN=""; C_RESET=""
fi
info() { printf "%b[*]%b %s\n" "$C_INFO" "$C_RESET" "$1" >&2; }
ok()   { printf "%b[+]%b %s\n" "$C_OK" "$C_RESET" "$1" >&2; }
warn() { printf "%b[!]%b %s\n" "$C_WARN" "$C_RESET" "$1" >&2; }
# `trap - ERR` first: die() is a deliberate exit, and without this the ERR
# trap fires on the way out and prints a second, useless "failed at line N"
# underneath the real explanation.
die()  { printf "%b[x]%b %s\n" "$C_ERR" "$C_RESET" "$1" >&2; trap - ERR; exit 1; }

trap 'die "failed at line $LINENO (exit code $?)"' ERR

require_root() { [[ "$(id -u)" -eq 0 ]] || die "must be run as root"; }

# apk (Alpine) or apt-get (Debian) — whichever is actually on this container,
# not whichever OS a service author assumed. Package *names* can still differ
# between the two (this only saves you from the manager itself), so a service
# that needs something Debian calls `sqlite3` and Alpine calls `sqlite` still
# has to know that.
ensure_pkg() {
  local missing=() pkg
  for pkg in "$@"; do
    command -v "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk update -q
    apk add -q "${missing[@]}"
  else
    die "missing: ${missing[*]} (no apt-get or apk available to install them)"
  fi
}

# `hostname -I` is a GNU-ism; busybox's hostname applet (Alpine) does not
# support it. `ip addr show` is implemented identically by busybox and
# iproute2, so parse that instead of branching per OS.
container_ip() { ip -4 addr show eth0 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2; }

# Restarts a service under whichever init system this container has —
# systemd on Debian, OpenRC on Alpine. This is the one place a service is
# expected to reach past its own vendor CLI into the init system directly:
# neither AdGuard Home's `-s` flag nor Pi-hole's `pihole` exposes a portable
# "restart my daemon" (Pi-hole's `reloaddns`/`reloadlists` explicitly do NOT
# restart the process — see cmd_install in pi-hole/manage.sh for why a real
# restart, not a reload, is what a fresh install actually needs).
restart_service() {
  local name="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$name"
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$name" restart
  else
    die "no systemctl or rc-service available to restart ${name}"
  fi
}

# Docker itself, for any service that ships as a container image rather than
# a native installer. get.docker.com (upstream Docker's own installer) has no
# Alpine path, so every Docker-based service in this project is Debian-only —
# same reasoning, and the same install step, first used for Floci. Shared
# here rather than duplicated per service.
ensure_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  info "installing Docker"
  local tmp_script
  tmp_script="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$tmp_script" || { rm -f "$tmp_script"; die "failed to download Docker's installer"; }
  sh "$tmp_script" >/dev/null 2>&1 || { rm -f "$tmp_script"; die "Docker installation failed"; }
  rm -f "$tmp_script"
  systemctl enable --now docker >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 || die "Docker installer finished but 'docker' is still not on PATH"
}

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
EOF_MANAGE_SCRIPT
}
# lib/ui.sh — terminal output: colours, logging, banner, spinner, summary box.
# Inlined into every built script by build.sh. No side effects on load.

if [[ -t 1 ]]; then
  C_INFO="\033[36m"; C_OK="\033[32m"; C_ERR="\033[31m"; C_WARN="\033[33m"
  C_BRAND="\033[1;36m"; C_DIM="\033[2m"; C_BOLD="\033[1m"; C_RESET="\033[0m"
  C_CLR="\r\033[K"
else
  C_INFO=""; C_OK=""; C_ERR=""; C_WARN=""; C_BRAND=""; C_DIM=""; C_BOLD=""; C_RESET=""
  C_CLR=""
fi

# info/ok/warn/die are status output for a human, never a function's return
# value — they ALWAYS go to stderr. Several functions below return their
# result by being invoked as `x="$(some_func ...)"`; if a status message
# printed to stdout instead, it would get captured right along with the real
# return value and corrupt it silently.
info() { printf "%b[*]%b %s\n" "$C_INFO" "$C_RESET" "$1" >&2; }
ok()   { printf "%b[+]%b %s\n" "$C_OK" "$C_RESET" "$1" >&2; }
warn() { printf "%b[!]%b %s\n" "$C_WARN" "$C_RESET" "$1" >&2; }
# C_CLR rewinds and wipes any half-drawn spinner line, so an error never gets
# printed onto the end of one ("creating container 100[x] failed at line 418").
# `trap - ERR` first: die() is a deliberate exit, and without this the ERR trap
# fires on the way out and prints a second, useless "failed at line N"
# underneath the real explanation.
die()  { printf "%b%b[x]%b %s\n" "$C_CLR" "$C_ERR" "$C_RESET" "$1" >&2; trap - ERR; exit 1; }

# The help text is baked in at build time (see the `# @usage` directive) rather
# than scraped from $0 at runtime, because $0 is an unreadable/one-shot pipe
# when the script is run the common way: bash <(curl -fsSL ...).
usage() { pvs_usage_text; }

BANNER_ART=' _____ ______ _____  ___ _____ _____ _   _   ___  ______ _   __
|  __ \| ___ \  ___|/ _ \_   _/  ___| | | | / _ \ | ___ \ | / /
| |  \/| |_/ / |__ / /_\ \| | \ `--.| |_| |/ /_\ \| |_/ / |/ /
| | __ |    /|  __||  _  || |  `--. \  _  ||  _  ||    /|    \
| |_\ \| |\ \| |___| | | || | /\__/ / | | || | | || |\ \| |\  \
 \____/\_| \_\____/\_| |_/\_/ \____/\_| |_/\_| |_/\_| \_\_| \_/'

BANNER_WIDTH=63

# Centre a line under the ASCII art rather than hand-counting spaces, so the
# title stays put whatever the service is called.
banner_center() {
  local text="$1" pad=0
  if [[ ${#text} -lt $BANNER_WIDTH ]]; then
    pad=$(( (BANNER_WIDTH - ${#text}) / 2 ))
  fi
  printf '%*s%s' "$pad" "" "$text"
}

banner() {
  [[ -t 1 ]] && clear
  printf "%b%s%b\n" "$C_BRAND" "$BANNER_ART" "$C_RESET"
  printf "%b%s%b\n" "$C_BOLD" "$(banner_center 'T E C H N O L O G I E S')" "$C_RESET"
  printf "%b%s%b\n" "$C_DIM"  "$(banner_center "GreatShark - ${SERVICE_NAME} - Proxmox VE")" "$C_RESET"
  printf "%b%s%b\n" "$C_DIM"  "---------------------------------------------------------------" "$C_RESET"
}

# Braille spinner frames are multibyte, and indexing them one character at a
# time only works when bash is in a UTF-8 locale. Outside one, ${str:i:1} slices
# bytes and emits mojibake, so fall back to plain ASCII rather than gamble on
# the terminal.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) SPINNER_FRAMES="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" ;;
  *)                             SPINNER_FRAMES='|/-\' ;;
esac

# Runs a command quietly with a spinner + message; on failure, prints its
# captured output so nothing important is ever silently swallowed.
run_step() {
  local msg="$1"; shift
  local log rc=0 i=0 n=${#SPINNER_FRAMES}
  log="$(mktemp)"

  "$@" >"$log" 2>&1 &
  local pid=$!

  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf "\r%b%s%b %s" "$C_INFO" "${SPINNER_FRAMES:$((i % n)):1}" "$C_RESET" "$msg" >&2
      sleep 0.1
      # NOT `(( i++ ))`: an arithmetic command whose result is 0 exits 1, and
      # post-increment yields the value *before* the increment — so the very
      # first tick, with i=0, returns failure and `set -e` kills the script
      # mid-spinner. Only reachable on a real terminal, which is exactly where
      # it matters.
      i=$(( i + 1 ))
    done
  fi

  wait "$pid" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf "\r%b[+]%b %s\n" "$C_OK" "$C_RESET" "$msg" >&2
    rm -f "$log"
    return 0
  fi

  printf "\r%b[x]%b %s\n" "$C_ERR" "$C_RESET" "$msg" >&2
  sed 's/^/    /' "$log" >&2
  rm -f "$log"
  exit "$rc"
}

# Reads " label : value" lines on stdin and draws them in a box, so services
# only have to say *what* to show, never how to pad it. Buffers first so the
# box widens to fit its longest line instead of ragged-edging on long URLs.
print_summary_box() {
  local colour="${1:-$C_OK}"
  local lines=() line width=63 rule
  while IFS= read -r line || [[ -n "$line" ]]; do
    lines+=("$line")
    if (( ${#line} + 1 > width )); then width=$(( ${#line} + 1 )); fi
  done
  rule="$(printf '%*s' "$width" '' | tr ' ' '-')"

  printf "\n%b" "$colour"
  printf '+%s+\n' "$rule"
  for line in ${lines[@]+"${lines[@]}"}; do
    printf '|%-*s|\n' "$width" "$line"
  done
  printf '+%s+\n' "$rule"
  printf "%b\n" "$C_RESET"
}
# lib/pve.sh — Proxmox VE host-side primitives: preflight, template
# resolution, container creation, readiness waiting, agent push.
# Inlined into every built script by build.sh.

require_pve_host() {
  command -v pct >/dev/null 2>&1 || die "pct not found — this script must run on a Proxmox VE host"
  [[ "$(id -u)" -eq 0 ]] || die "must be run as root on the Proxmox VE host"
}

require_ctid_exists() {
  local ctid="$1"
  pct status "$ctid" >/dev/null 2>&1 || die "container ${ctid} not found"
}

# Match the host, don't assume amd64 — Proxmox runs on arm64 boxes too.
resolve_arch() { dpkg --print-architecture; }

resolve_ctid() {
  if [[ -n "$CTID" ]]; then
    pct status "$CTID" >/dev/null 2>&1 && die "container ${CTID} already exists — pick another --id"
    echo "$CTID"
    return
  fi
  pvesh get /cluster/nextid
}

# Proxmox installs disagree about storage names: `local-lvm` on a stock
# install, `local-zfs` on ZFS root, and on dir-based images (the Raspberry Pi
# one, for instance) there is only `local`. Hardcoding local-lvm and letting
# `pct create` fail four steps later is a bad first five minutes.
resolve_storage() {
  local content="$1" explicit="$2" preferred="$3" candidates s

  if [[ -n "$explicit" ]]; then
    if ! pvesm status --content "$content" 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$explicit"; then
      warn "storage '${explicit}' is not an active storage supporting '${content}' on this host — trying anyway"
    fi
    echo "$explicit"
    return 0
  fi

  candidates="$(pvesm status --content "$content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')"
  [[ -n "$candidates" ]] || die "no active storage on this host supports '${content}' — pass one explicitly"

  for s in $preferred; do
    if printf '%s\n' "$candidates" | grep -qx "$s"; then
      echo "$s"
      return 0
    fi
  done
  printf '%s\n' "$candidates" | head -n1
}

# ---------------------------------------------------------------------------
# OS support. A case statement rather than an associative array, because
# associative arrays need bash 4 and this project stays parseable on the
# bash 3.2 that ships on macOS (see CONTRIBUTING.md). Add a new OS by adding
# one case to each of the three functions below.
# ---------------------------------------------------------------------------

# Friendly name for prompts and the plan box.
os_label() {
  case "$1" in
    debian) printf 'Debian 13' ;;
    alpine) printf 'Alpine 3.24' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Matches the template name up through the variant, e.g.
# debian-13-standard_13.6-1_arm64.tar.zst or
# alpine-3.24-default_20260803_arm64.tar.xz — deliberately not pinned to one
# minor/point version, since a host's mirror snapshot moves independently of
# this script and pinning "debian-12" is exactly how a script breaks on a
# host whose mirror only carries 13 (see the arm64 test host this was found
# on). $2 is the file extension: Debian ships .tar.zst, Alpine ships .tar.xz.
os_template_pattern() {
  case "$1" in
    debian) printf 'debian-[0-9]+-standard' ;;
    alpine) printf 'alpine-[0-9]+\.[0-9]+-default' ;;
    *) die "unknown OS '${1}'" ;;
  esac
}

# What has to be true inside a *fresh* container before our own bash-based
# manage.sh can even be interpreted, let alone run — this has to be plain
# POSIX sh, not bash, because on Alpine bash is exactly the thing being
# installed. Debian's standard template already ships bash, so its bootstrap
# is just the curl check already needed for the vendor installers; Alpine's
# base image has neither bash nor curl, only busybox ash, apk and wget.
os_bootstrap_cmd() {
  case "$1" in
    debian) printf '%s' 'command -v curl >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq curl)' ;;
    alpine) printf '%s' 'apk update -q >/dev/null 2>&1; command -v bash >/dev/null 2>&1 || apk add -q bash; command -v curl >/dev/null 2>&1 || apk add -q curl' ;;
    *) die "unknown OS '${1}'" ;;
  esac
}

# The service name OpenSSH's own package registers under — not the same
# everywhere. Debian's package (and its systemd unit) is named "ssh", not
# "sshd"; Alpine's OpenRC init script is "sshd". Getting this wrong doesn't
# error, it just silently restarts nothing.
os_sshd_service() {
  case "$1" in
    debian) printf 'ssh' ;;
    alpine) printf 'sshd' ;;
    *) die "unknown OS '${1}'" ;;
  esac
}

template_regex() { printf '^%s_[^_]*_%s\.tar\.(zst|gz|xz)$' "$TEMPLATE_PATTERN" "$1"; }

cached_template_files() {
  pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}' | sed 's|.*/||'
}

available_template_files() {
  pveam available --section system 2>/dev/null | awk 'NF>1 {print $2}'
}

ensure_template() {
  local arch="$1" rx cached avail best update_err

  # A --template override skips all of this — use it verbatim.
  if [[ -n "$TEMPLATE" ]]; then
    echo "$TEMPLATE"
    return 0
  fi

  rx="$(template_regex "$arch")"
  info "looking for a ${OS_LABEL} (${arch}) container template"

  # Check what is already downloaded *before* touching the network. A template
  # sitting in local:vztmpl makes the whole appliance-mirror question moot, and
  # broken or unreachable mirrors are common enough (third-party mirrors, ARM
  # images, no internet at all) that failing there while the file is already on
  # disk would be absurd.
  cached="$(cached_template_files | grep -E "$rx" | sort -V | tail -n1 || true)"

  if ! update_err="$(pveam update 2>&1 >/dev/null)"; then
    warn "pveam update failed, continuing with whatever is already cached: ${update_err}"
  elif [[ -n "$update_err" ]]; then
    warn "pveam update: ${update_err}"
  fi

  avail="$(available_template_files | grep -E "$rx" | sort -V | tail -n1 || true)"

  # Newest of the two, but never re-download something we already have.
  best="$(printf '%s\n%s\n' "$cached" "$avail" | grep -v '^$' | sort -V | tail -n1 || true)"

  if [[ -z "$best" ]]; then
    warn "no ${OS_LABEL} template for arch '${arch}' is cached or offered (pattern: ${TEMPLATE_PATTERN})."
    warn "cached on ${TEMPLATE_STORAGE}:"
    cached_template_files | sed 's/^/      /' >&2 || true
    warn "offered by the appliance list for ${arch}:"
    available_template_files | grep -E "_${arch}\." | sed 's/^/      /' >&2 \
      || echo "      (nothing for ${arch} — the appliance list looks broken or incomplete on this host)" >&2
    die "fix the appliance list (see warnings above), or skip auto-detection entirely with: --template <storage>:vztmpl/<filename>"
  fi

  if [[ "$best" == "$cached" ]]; then
    info "using cached template ${best}"
  else
    run_step "downloading template ${best}" pveam download "$TEMPLATE_STORAGE" "$best"
  fi
  echo "${TEMPLATE_STORAGE}:vztmpl/${best}"
}

# What this host can actually offer, for the interactive picker. Offering a
# free-text field for something with three valid answers is how typos become
# support questions.
#
# Each ends in `|| true`: these run inside a bare $(...) substitution (an
# argument to ask_choice, not an if/while condition), and with errtrace (-E)
# the ERR trap fires *inside that subshell* for any failing command in it —
# missing binary, empty grep match, whatever — printing a false "failed at
# line N" and aborting the probe, even though the caller only wants a best
# effort and already falls back to the current default on empty input.
storage_options() {
  pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' || true
}

bridge_options() {
  ip -br link show type bridge 2>/dev/null | awk '{print $1}' || true
}

host_gateway() {
  ip route 2>/dev/null | awk '/^default/ {print $3; exit}' || true
}

build_net_arg() {
  if [[ -n "$STATIC_CIDR" ]]; then
    echo "name=eth0,bridge=${BRIDGE},ip=${STATIC_CIDR},gw=${GATEWAY}"
  else
    echo "name=eth0,bridge=${BRIDGE},ip=dhcp"
  fi
}

# Success here means more than "the CT booted": it means DNS, routing and the
# package manager all work, which is what every installer downstream actually
# depends on. Runs via `sh -c`, not bash — on a fresh Alpine container bash is
# exactly what this step installs, so the bootstrap command itself must be
# plain POSIX shell.
wait_for_network() {
  local ctid="$1" os_id="$2" tries=30 cmd
  cmd="$(os_bootstrap_cmd "$os_id")"
  info "waiting for container networking"
  while (( tries > 0 )); do
    if pct exec "$ctid" -- sh -c "$cmd" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    tries=$(( tries - 1 ))
  done
  die "container never came up with working networking/package manager"
}

# OpenSSH's own compiled-in default is `PermitRootLogin prohibit-password` —
# root can SSH in with a key, never with a password, no matter how correct
# it is. Debian's and Alpine's shipped sshd_config both leave that directive
# commented out (so the compiled-in default applies) rather than setting it
# explicitly — confirmed by reading a real container's sshd_config, not
# assumed. The practical effect: the root password this project generates
# and prints was completely unusable for `ssh root@<ip>` — only `pct enter`/
# `pct exec` (which never go through sshd at all) worked with it. Reproduced
# directly with sshpass against a real container ("Permission denied") before
# writing this fix, and confirmed SSH succeeds after it runs.
#
# This is a real security trade-off, not a pure bug fix — root+password
# becomes reachable from the whole LAN, not just from the PVE host — made
# deliberately for this project's stated use case (hobby, personal-LAN,
# tinkering) rather than a public-internet-facing hardening target. The
# generated password is a random 20 characters, not something guessable.
#
# Idempotent: replaces the directive if present (commented or not) rather
# than assuming it's absent, so re-running this against an already-patched
# container is harmless.
enable_root_ssh() {
  local ctid="$1" os_id="$2" svc cmd
  svc="$(os_sshd_service "$os_id")"

  # Debian's base template ships OpenSSH server already installed, enabled,
  # and running. Alpine's does not ship it at all — confirmed directly
  # (`/etc/ssh` doesn't exist on a fresh container) rather than assumed from
  # Debian's behaviour transferring over. Installing it here, not folded into
  # os_bootstrap_cmd, because this step already knows it needs sshd
  # specifically; a service that never touches SSH shouldn't pay for it.
  if [[ "$os_id" == "alpine" ]]; then
    pct exec "$ctid" -- sh -c 'apk info -e openssh >/dev/null 2>&1 || apk add -q openssh' \
      || die "failed to install openssh on Alpine"
    pct exec "$ctid" -- rc-update add "$svc" default >/dev/null 2>&1 || true
  fi

  # Plain basic-regex sed/grep throughout, no -E: Alpine's base image ships
  # BusyBox's sed, and this project does not assume it understands GNU-style
  # extended-regex flags. The patterns don't need extended regex anyway.
  cmd='CFG=/etc/ssh/sshd_config
for pair in "PermitRootLogin yes" "PasswordAuthentication yes"; do
  key=${pair%% *}
  if grep -q "^[#[:space:]]*${key}[[:space:]]" "$CFG" 2>/dev/null; then
    sed -i "s|^[#[:space:]]*${key}[[:space:]].*|${pair}|" "$CFG"
  else
    printf "%s\n" "$pair" >> "$CFG"
  fi
done'
  pct exec "$ctid" -- sh -c "$cmd" || die "failed to update sshd_config for root password login"

  # restart on Debian (already running); Alpine's package installs the
  # service but does not start it, so start (not just restart) it there.
  if [[ "$os_id" == "alpine" ]]; then
    pct exec "$ctid" -- rc-service "$svc" restart 2>/dev/null || pct exec "$ctid" -- rc-service "$svc" start \
      || die "sshd_config was updated but starting '${svc}' failed"
  else
    pct exec "$ctid" -- systemctl restart "$svc" || die "sshd_config was updated but restarting '${svc}' failed"
  fi
}

# Pushes the embedded management script into $ctid, always overwriting so the
# container stays in sync with whatever version of this file you're running.
push_manage_script() {
  local ctid="$1" tmp
  tmp="$(mktemp)"
  manage_script > "$tmp"
  # `pct push` does not create parent directories. Debian's standard template
  # ships /usr/local/sbin already; Alpine's minimal base does not (only
  # /usr/local/{bin,lib,share}) — mkdir -p first rather than assume either.
  pct exec "$ctid" -- mkdir -p "$(dirname "$MANAGE_PATH")"
  pct push "$ctid" "$tmp" "$MANAGE_PATH"
  rm -f "$tmp"
  pct exec "$ctid" -- chmod +x "$MANAGE_PATH"
}

# `hostname -I` is a GNU-ism; busybox's hostname applet (Alpine) does not
# support it and errors out. `ip addr show` is implemented identically by
# busybox and iproute2, so parse that instead of branching per OS.
container_ip() {
  pct exec "$1" -- sh -c "ip -4 addr show eth0 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2"
}

create_container() {
  local ctid="$1" template="$2" net_arg="$3"
  run_step "creating container ${ctid}" \
    pct create "$ctid" "$template" \
      --hostname "$CT_HOSTNAME" \
      --cores "$CORES" \
      --memory "$MEMORY_MB" \
      --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
      --net0 "$net_arg" \
      --unprivileged "$UNPRIVILEGED" \
      --features "nesting=${NESTING},keyctl=${KEYCTL}" \
      --password "$ROOT_PASSWORD" \
      --onboot 1 \
      --start 0
  run_step "starting container ${ctid}" pct start "$ctid"
}
# lib/prompt.sh — interactive configuration. Every prompt offers the
# recommended value in brackets, so Enter is always a valid answer.

# Prompts read from /dev/tty, never stdin. Under `bash <(curl ...)` stdin can be
# the script itself; a `read` that swallowed it would corrupt the run in a way
# that is very hard to diagnose.
interactive() {
  [[ -t 1 ]] || return 1
  [[ -r /dev/tty ]] || return 1
  return 0
}

ask() {
  local prompt="$1" default="$2" validator="${3:-}" answer
  while true; do
    printf "  %b%s%b [%b%s%b]: " \
      "$C_BOLD" "$prompt" "$C_RESET" "$C_INFO" "$default" "$C_RESET" >&2
    IFS= read -r answer </dev/tty || { printf '\n' >&2; answer=""; }
    [[ -z "$answer" ]] && answer="$default"
    if [[ -z "$validator" ]] || "$validator" "$answer"; then
      printf '%s' "$answer"
      return 0
    fi
  done
}

ask_yesno() {
  local prompt="$1" default="${2:-y}" answer hint
  case "$default" in
    y|Y) hint="Y/n" ;;
    *)   hint="y/N" ;;
  esac
  while true; do
    printf "  %b%s%b [%b%s%b]: " \
      "$C_BOLD" "$prompt" "$C_RESET" "$C_INFO" "$hint" "$C_RESET" >&2
    IFS= read -r answer </dev/tty || answer=""
    [[ -z "$answer" ]] && answer="$default"
    case "$answer" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No)    return 1 ;;
      *) warn "please answer y or n" ;;
    esac
  done
}

# Numbered pick from a newline-separated list. Accepts either the number or the
# value typed out. With only one option there is nothing to choose, so it
# returns silently rather than asking a question with one answer.
ask_choice() {
  local prompt="$1" default="$2" options="$3" count opt i answer pick
  count="$(printf '%s\n' "$options" | grep -c . || true)"
  if [[ -z "$count" || "$count" -le 1 ]]; then
    printf '%s' "$default"
    return 0
  fi

  printf '\n' >&2
  i=1
  while IFS= read -r opt; do
    [[ -z "$opt" ]] && continue
    if [[ "$opt" == "$default" ]]; then
      printf "    %2d) %s%b  (recommended)%b\n" "$i" "$opt" "$C_DIM" "$C_RESET" >&2
    else
      printf "    %2d) %s\n" "$i" "$opt" >&2
    fi
    i=$(( i + 1 ))
  done < <(printf '%s\n' "$options" | grep .)

  while true; do
    answer="$(ask "$prompt" "$default")"
    if [[ "$answer" =~ ^[0-9]+$ ]] && [[ "$answer" -ge 1 && "$answer" -le "$count" ]]; then
      pick="$(printf '%s\n' "$options" | grep . | sed -n "${answer}p")"
      printf '%s' "$pick"
      return 0
    fi
    if printf '%s\n' "$options" | grep -qx -- "$answer"; then
      printf '%s' "$answer"
      return 0
    fi
    warn "pick a number from the list, or type the name exactly"
  done
}

# 20 alphanumeric characters from /dev/urandom — plenty of entropy (~119 bits)
# without needing openssl, and free of shell/quoting metacharacters since it
# only ever travels as a single argv element, never through eval.
#
# `|| true` is load-bearing, not decorative: `head -c 20` closes its end of the
# pipe the instant it has 20 bytes, tr is still writing when that happens, and
# writing to a reader that has hung up is SIGPIPE — exit 141. Under pipefail
# that is the pipeline's exit status, and since this runs in a bare $(...)
# substitution the ERR trap fires on it and kills the whole script. Not a rare
# edge case: it is what happens on *every* call, deterministically, because
# head always finishes first by design.
generate_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 20 || true
}

# Hidden input, confirmed twice. Loops on mismatch or on failing $2 (a
# validator), same contract as ask().
ask_secret() {
  local prompt="$1" validator="${2:-}" pass1 pass2
  while true; do
    printf "  %b%s%b: " "$C_BOLD" "$prompt" "$C_RESET" >&2
    stty -echo </dev/tty 2>/dev/null
    IFS= read -r pass1 </dev/tty || pass1=""
    stty echo </dev/tty 2>/dev/null
    printf '\n' >&2

    if [[ -z "$pass1" ]]; then
      warn "cannot be empty"
      continue
    fi
    if [[ -n "$validator" ]] && ! "$validator" "$pass1"; then
      continue
    fi

    printf "  %bConfirm%b: " "$C_BOLD" "$C_RESET" >&2
    stty -echo </dev/tty 2>/dev/null
    IFS= read -r pass2 </dev/tty || pass2=""
    stty echo </dev/tty 2>/dev/null
    printf '\n' >&2

    if [[ "$pass1" != "$pass2" ]]; then
      warn "passwords did not match"
      continue
    fi
    printf '%s' "$pass1"
    return 0
  done
}

# Same shape as ask_choice, but over a space-separated list of OS ids (not
# newline-separated, since OS_CHOICES is a plain word list elsewhere) and
# displaying os_label() for each rather than the raw id — the answer returned
# is still the id ("debian"), never the label, since that is what every OS_ID
# consumer downstream expects.
ask_os() {
  local default="$1" choices="$2" ids id count i answer pick

  ids="$(printf '%s\n' $choices)"
  count="$(printf '%s\n' "$ids" | grep -c . || true)"
  if [[ -z "$count" || "$count" -le 1 ]]; then
    printf '%s' "$default"
    return 0
  fi

  printf '\n' >&2
  i=1
  for id in $choices; do
    if [[ "$id" == "$default" ]]; then
      printf "    %2d) %-8s %s%b  (recommended)%b\n" "$i" "$id" "$(os_label "$id")" "$C_DIM" "$C_RESET" >&2
    else
      printf "    %2d) %-8s %s\n" "$i" "$id" "$(os_label "$id")" >&2
    fi
    i=$(( i + 1 ))
  done

  while true; do
    answer="$(ask "Operating system" "$default")"
    if [[ "$answer" =~ ^[0-9]+$ ]] && [[ "$answer" -ge 1 && "$answer" -le "$count" ]]; then
      pick="$(printf '%s\n' "$ids" | sed -n "${answer}p")"
      printf '%s' "$pick"
      return 0
    fi
    if printf '%s\n' "$ids" | grep -qx -- "$answer"; then
      printf '%s' "$answer"
      return 0
    fi
    warn "pick a number from the list, or type the OS name exactly"
  done
}

# ---------------------------------------------------------------------------
# Validators. Each explains the problem itself, so ask() can just loop.
# ---------------------------------------------------------------------------
v_posint() {
  if [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]; then return 0; fi
  warn "must be a positive whole number"
  return 1
}

v_ctid() {
  if ! [[ "$1" =~ ^[0-9]+$ ]]; then warn "container ID must be a number"; return 1; fi
  if [[ "$1" -lt 100 ]]; then warn "container IDs start at 100"; return 1; fi
  if pct status "$1" >/dev/null 2>&1; then warn "container $1 already exists"; return 1; fi
  return 0
}

v_hostname() {
  if [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then return 0; fi
  warn "letters, digits and hyphens only, and it cannot start or end with a hyphen"
  return 1
}

v_cidr() {
  if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then return 0; fi
  warn "needs an address *and* a prefix length, e.g. 192.168.1.53/24"
  return 1
}

v_password() {
  if [[ ${#1} -ge 8 ]]; then return 0; fi
  warn "must be at least 8 characters"
  return 1
}

v_ip() {
  if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 0; fi
  warn "expected an IPv4 address, e.g. 192.168.1.1"
  return 1
}
# lib/main.sh — defaults, argument parsing and the create/update/uninstall/
# status dispatcher shared by every script. Include this LAST: it reads the
# DEFAULT_* values the service set above it, and the svc_* hooks it defines
# here are meant to be overridden by the service below it.

trap 'die "failed at line $LINENO (exit code $?)"' ERR

# Runtime knobs, seeded from the service's DEFAULT_* block.
CTID=""
CT_HOSTNAME="${DEFAULT_HOSTNAME}"
# Empty means "work it out from the host" — see resolve_storage().
ROOTFS_STORAGE="${DEFAULT_ROOTFS_STORAGE:-}"
TEMPLATE_STORAGE="${DEFAULT_TEMPLATE_STORAGE:-}"
# Which OSes this service can run on, space-separated (os_label/os_template_
# pattern/os_bootstrap_cmd in lib/pve.sh must know each one), and which one is
# picked when nothing else says otherwise. A service that never declares
# DEFAULT_OS_CHOICES gets a single-OS list, so --os and the wizard question
# both stay silent/absent for it rather than presenting a choice of one.
OS_CHOICES="${DEFAULT_OS_CHOICES:-${DEFAULT_OS:-debian}}"
OS_ID="${DEFAULT_OS:-debian}"
# TEMPLATE_PATTERN/OS_LABEL are derived from OS_ID right before ensure_template
# runs (see do_create) — not set here, since OS_ID can still change via --os
# or the wizard after this file is sourced.
TEMPLATE_PATTERN=""
OS_LABEL=""
BRIDGE="${DEFAULT_BRIDGE:-vmbr0}"
DISK_GB="${DEFAULT_DISK_GB:-4}"
CORES="${DEFAULT_CORES:-1}"
MEMORY_MB="${DEFAULT_MEMORY_MB:-512}"
UNPRIVILEGED="${DEFAULT_UNPRIVILEGED:-1}"
NESTING="${DEFAULT_NESTING:-0}"
# Docker-in-LXC needs both nesting and keyctl — verified on a real host (get.docker.com
# install, hello-world, a real postgres container, port publishing reachable from the
# PVE host) with this exact pair; nesting alone was not tested in isolation, so
# services that need Docker should request both rather than assume nesting suffices.
KEYCTL="${DEFAULT_KEYCTL:-0}"
STATIC_CIDR=""
GATEWAY=""
TEMPLATE=""
# Empty here means "generate a random one right before create_container runs"
# — see do_create. Kept empty rather than generated up front so a wizard user
# who picks "set my own" overwrites it, and re-running the wizard after "n" at
# the plan prompt clears back to auto rather than keeping a stale generated one.
ROOT_PASSWORD=""
MANAGE_PATH="/usr/local/sbin/${SERVICE_ID}-manage.sh"
SVC_OPT_SHIFT=0
SVC_INSTALL_ARGS=()
PREFER_STATIC="${DEFAULT_PREFER_STATIC:-n}"
# Any create flag at all means "you are scripting me": no prompts, so a command
# in a runbook behaves the same in six months as it does today.
OPTS_GIVEN=0
ASSUME_DEFAULTS=0

# ---- Service hooks: defaults here, overridden below the include if needed --
# svc_parse_option  — handle one service-specific flag; set SVC_OPT_SHIFT to
#                     how many argv entries it consumed and return 0, or
#                     return 1 to let the caller reject it as unknown.
svc_parse_option() { return 1; }
# svc_install_args  — fill SVC_INSTALL_ARGS with extra args for `install`.
svc_install_args() { SVC_INSTALL_ARGS=(); }
# svc_summary_lines — extra " label : value" lines for the closing box.
svc_summary_lines() { :; }
# svc_post_create   — anything to do on the host after install ($1=ctid $2=ip).
svc_post_create() { :; }
# svc_prompt        — extra questions for the interactive configure step.
svc_prompt() { :; }
# svc_plan_lines    — extra " label : value" lines for the pre-create summary.
svc_plan_lines() { :; }

parse_create_args() {
  [[ $# -gt 0 ]] && OPTS_GIVEN=1
  while (( "$#" )); do
    case "$1" in
      -i|--id) CTID="$2"; shift 2 ;;
      -n|--hostname) CT_HOSTNAME="$2"; shift 2 ;;
      -s|--storage) ROOTFS_STORAGE="$2"; shift 2 ;;
      -t|--template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
      -b|--bridge) BRIDGE="$2"; shift 2 ;;
      -d|--disk) DISK_GB="$2"; shift 2 ;;
      -c|--cores) CORES="$2"; shift 2 ;;
      -m|--memory) MEMORY_MB="$2"; shift 2 ;;
      --static) STATIC_CIDR="$2"; shift 2 ;;
      --gateway) GATEWAY="$2"; shift 2 ;;
      --template) TEMPLATE="$2"; shift 2 ;;
      --os) OS_ID="$2"; shift 2 ;;
      --password) ROOT_PASSWORD="$2"; shift 2 ;;
      -y|--yes|--defaults) ASSUME_DEFAULTS=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *)
        SVC_OPT_SHIFT=0
        if svc_parse_option "$@"; then
          shift "$SVC_OPT_SHIFT"
        else
          die "unknown option: $1 (see --help)"
        fi
        ;;
    esac
  done
  if [[ -n "$STATIC_CIDR" && -z "$GATEWAY" ]]; then
    die "--static requires --gateway"
  fi
  if [[ -n "$ROOT_PASSWORD" ]]; then
    v_password "$ROOT_PASSWORD" || die "--password must be at least 8 characters"
  fi
  if ! os_supported "$OS_ID"; then
    die "--os must be one of: ${OS_CHOICES} (got '${OS_ID}')"
  fi
  return 0
}

os_supported() {
  local want="$1" id
  for id in $OS_CHOICES; do
    [[ "$id" == "$want" ]] && return 0
  done
  return 1
}

# How to tell the user to re-invoke us. When the script was run the piped way
# (bash <(curl ...)), $0 is a spent file descriptor, not a path — printing
# "./63 update 101" would be actively misleading. Rather than inlining the full
# 120-character curl incantation into every summary line (which shreds the box
# on a normal terminal), name the file it *would* be and tell them how to get
# it, once, underneath.
ran_from_file() { [[ -f "${0:-}" && "$(basename -- "${0:-}")" == *.sh ]]; }

self_cmd() {
  if ran_from_file; then
    printf './%s' "$(basename -- "$0")"
  else
    printf './%s' "$PVS_SCRIPT_FILENAME"
  fi
}

summary() {
  local ctid="$1" ip="$2" self
  self="$(self_cmd)"
  {
    echo " ${SERVICE_NAME} is up - CT ${ctid} (${CT_HOSTNAME})"
    echo ""
    svc_summary_lines "$ctid" "$ip"
    echo ""
    echo " Root SSH      : ssh root@${ip}"
    echo " Root password : ${ROOT_PASSWORD}"
    echo " Root login    : pct enter ${ctid}   (from the PVE host, no password needed)"
    echo ""
    echo " Update       : ${self} update ${ctid}"
    echo " Status       : ${self} status ${ctid}"
    echo " Uninstall    : ${self} uninstall ${ctid}"
  } | print_summary_box

  warn "the root password above is shown once and is not stored anywhere — save it now."

  if ! ran_from_file; then
    # Status text, not the function's return value — like every other
    # info/ok/warn message in this project, this belongs on stderr. It was a
    # bare printf with no redirect until a real service's summary box
    # exposed it: piped to stdout, this text lands right in the middle of
    # whatever else reads a summary's output (a smoke test measuring box
    # width, or a caller capturing it), not just on a human's terminal.
    printf "%b[*]%b You ran this from a pipe, so there is no local copy yet. To manage CT %s later:\n" \
      "$C_INFO" "$C_RESET" "$ctid" >&2
    printf "    curl -fsSL %s -o %s && chmod +x %s\n" \
      "$PVS_SCRIPT_URL" "$PVS_SCRIPT_FILENAME" "$PVS_SCRIPT_FILENAME" >&2
  fi
}

# Prompt only when there is a human to answer, nothing was passed on the
# command line, and defaults were not explicitly requested.
wizard_wanted() {
  [[ "$ASSUME_DEFAULTS" -eq 1 ]] && return 1
  [[ "$OPTS_GIVEN" -eq 1 ]] && return 1
  interactive || return 1
  return 0
}

plan_lines() {
  echo " ${SERVICE_NAME} - about to create"
  echo ""
  echo " Container ID  : ${CTID}"
  echo " Hostname      : ${CT_HOSTNAME}"
  echo " Operating sys : $(os_label "$OS_ID")"
  echo " Storage pool  : ${ROOTFS_STORAGE}"
  echo " Disk size     : ${DISK_GB} GB"
  echo " CPU cores     : ${CORES}"
  echo " Memory        : ${MEMORY_MB} MB"
  if [[ -n "$STATIC_CIDR" ]]; then
    echo " Network       : ${STATIC_CIDR} via ${GATEWAY} on ${BRIDGE}"
  else
    echo " Network       : DHCP on ${BRIDGE}"
  fi
  if [[ -n "$ROOT_PASSWORD" ]]; then
    echo " Root password : (as entered, hidden)"
  else
    echo " Root password : (auto-generated, shown once after creation)"
  fi
  svc_plan_lines
}

configure_interactive() {
  printf '\n' >&2
  info "Enter accepts the recommended value shown in brackets."
  printf '\n' >&2

  CTID="$(ask "Container ID" "$CTID" v_ctid)"
  CT_HOSTNAME="$(ask "Hostname" "$CT_HOSTNAME" v_hostname)"
  OS_ID="$(ask_os "$OS_ID" "$OS_CHOICES")"
  ROOTFS_STORAGE="$(ask_choice "Storage pool" "$ROOTFS_STORAGE" "$(storage_options)")"
  DISK_GB="$(ask "Disk size (GB)" "$DISK_GB" v_posint)"
  CORES="$(ask "CPU cores" "$CORES" v_posint)"
  MEMORY_MB="$(ask "Memory (MB)" "$MEMORY_MB" v_posint)"
  BRIDGE="$(ask_choice "Network bridge" "$BRIDGE" "$(bridge_options)")"

  if ask_yesno "Assign a static IP?" "$PREFER_STATIC"; then
    STATIC_CIDR="$(ask "Static address (CIDR)" "$STATIC_CIDR" v_cidr)"
    GATEWAY="$(ask "Gateway" "${GATEWAY:-$(host_gateway)}" v_ip)"
  else
    STATIC_CIDR=""
    GATEWAY=""
  fi

  if ask_yesno "Auto-generate a secure root password?" "y"; then
    ROOT_PASSWORD=""
  else
    ROOT_PASSWORD="$(ask_secret "Root password (min 8 characters)" v_password)"
  fi

  svc_prompt
}

confirm_plan() {
  if ! wizard_wanted; then
    plan_lines | print_summary_box "$C_INFO"
    return 0
  fi
  while true; do
    plan_lines | print_summary_box "$C_INFO"
    if ask_yesno "Create with these settings?" "y"; then
      return 0
    fi
    configure_interactive
  done
}

do_create() {
  require_pve_host
  local arch template net_arg ip

  arch="$(resolve_arch)"
  ROOTFS_STORAGE="$(resolve_storage rootdir "$ROOTFS_STORAGE" "local-lvm local-zfs local")"
  TEMPLATE_STORAGE="$(resolve_storage vztmpl "$TEMPLATE_STORAGE" "local")"
  CTID="$(resolve_ctid)"

  confirm_plan
  [[ -n "$ROOT_PASSWORD" ]] || ROOT_PASSWORD="$(generate_password)"

  TEMPLATE_PATTERN="$(os_template_pattern "$OS_ID")"
  OS_LABEL="$(os_label "$OS_ID")"
  template="$(ensure_template "$arch")"
  net_arg="$(build_net_arg)"

  info "target: CT ${CTID} (${CT_HOSTNAME}) on ${arch}, ${OS_LABEL}, rootfs ${ROOTFS_STORAGE}"

  create_container "$CTID" "$template" "$net_arg"
  wait_for_network "$CTID" "$OS_ID"
  run_step "enabling root SSH login with the password above" enable_root_ssh "$CTID" "$OS_ID"
  run_step "pushing management script" push_manage_script "$CTID"

  info "installing ${SERVICE_NAME}"
  svc_install_args
  pct_exec_manage "$CTID" install ${SVC_INSTALL_ARGS[@]+"${SVC_INSTALL_ARGS[@]}"}

  ip="$(container_ip "$CTID")"
  svc_post_create "$CTID" "${ip:-}"
  summary "$CTID" "${ip:-<CT-ip>}"
}

# The agent inside the container has already printed a precise explanation by
# the time it exits non-zero. Letting that bubble into the ERR trap appends a
# second, contentless "failed at line 749" underneath it, which reads like a
# crash rather than the deliberate refusal it is. Pass the status through
# instead.
pct_exec_manage() {
  local ctid="$1"; shift
  local rc=0
  pct exec "$ctid" -- "$MANAGE_PATH" "$@" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    trap - ERR
    exit "$rc"
  fi
}

# Best-effort OS detection for a container this script did not just create
# (so OS_ID isn't already known) — reads /etc/os-release rather than
# guessing, since a container could have been made before --os existed at
# all. Falls back to debian, this project's default, if detection is
# inconclusive; enable_root_ssh degrades gracefully either way (Debian's
# path is idempotent even if the container was actually Alpine — worst case,
# a repair on an old container silently no-ops there instead of fixing it).
detect_os_id() {
  local ctid="$1" id
  id="$(pct exec "$ctid" -- sh -c '. /etc/os-release 2>/dev/null; echo "$ID"' 2>/dev/null)"
  case "$id" in
    alpine) echo "alpine" ;;
    *) echo "debian" ;;
  esac
}

do_manage() {
  local ctid="$1" action="$2"; shift 2
  require_pve_host
  require_ctid_exists "$ctid"
  push_manage_script "$ctid"
  if [[ "$action" == "update" ]]; then
    # Repairs a container made before this existed: root's SSH access was
    # silently unusable (OpenSSH's own default rejects password auth for
    # root) until enable_root_ssh started running at create time. Config-only
    # and idempotent — never touches the account's actual password, so a
    # container's existing one keeps working, it just starts working over
    # SSH too.
    enable_root_ssh "$ctid" "$(detect_os_id "$ctid")" 2>/dev/null || true
  fi
  pct_exec_manage "$ctid" "$action" "$@"
}

pvs_main() {
  local cmd
  banner
  if [[ $# -eq 0 || "$1" == -* ]]; then
    cmd="create"
  else
    cmd="$1"; shift
  fi

  case "$cmd" in
    create)
      parse_create_args "$@"
      do_create
      ;;
    update|uninstall|status)
      [[ $# -ge 1 ]] || die "usage: ${PVS_SCRIPT_FILENAME} ${cmd} <ctid> [options]"
      local ctid="$1"; shift
      do_manage "$ctid" "$cmd" "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $cmd (see --help)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " Setup wizard  : http://${2}:3000"
  echo " DNS server    : ${2}:53  (point your router/clients here)"
}

pvs_main "$@"
