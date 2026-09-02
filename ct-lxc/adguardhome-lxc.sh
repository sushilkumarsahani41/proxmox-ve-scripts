#!/usr/bin/env bash
#
# adguardhome-lxc.sh — AdGuard Home on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian 12 LXC (matching the host's own
#                       architecture — amd64 or arm64) and install
#                       AdGuard Home inside it
#   update <ctid>       Safely update AdGuard Home on an existing container:
#                       backs up config/data, lets the upstream installer do
#                       its reinstall, restores config/data, and rolls back
#                       automatically if the new version doesn't come up
#   uninstall <ctid>    Stop and remove AdGuard Home (--purge also wipes
#                       config/data)
#   status <ctid>       Show version + service state
#
# Usage:
#   ./adguardhome-lxc.sh create [options]
#   ./adguardhome-lxc.sh update <ctid> [--channel release|beta|edge]
#   ./adguardhome-lxc.sh uninstall <ctid> [--purge]
#   ./adguardhome-lxc.sh status <ctid>
#
# create options:
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: adguardhome)
#   -s, --storage <name>   Storage for the rootfs (default: local-lvm)
#   -t, --template-storage <name>  Storage to keep CT templates on (default: local)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 512)
#   --static <cidr>        Static IP, e.g. 192.168.1.53/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --channel <name>       AdGuard Home channel: release, beta, edge
#   --template <spec>      Skip template auto-detection entirely, e.g.
#                           local:vztmpl/debian-12-standard_12.7-1_arm64.tar.zst
#                           (use this if 'pveam available' can't see an arm64
#                           template on your box, e.g. some ARM/Pi Proxmox
#                           builds with a broken/incomplete appliance mirror)
#
# A DNS server wants a fixed address: --static is strongly recommended, since
# every client on the LAN will be pointed at this container's IP.
#
# ---------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT.
# Built by build.sh from src/ct-lxc/adguardhome/main.sh and src/lib/*.sh.
# Edit the source, then run ./build.sh. See CONTRIBUTING.md.
# ---------------------------------------------------------------------------

PVS_SCRIPT_FILENAME="adguardhome-lxc.sh"
PVS_SCRIPT_URL="https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/ct-lxc/adguardhome-lxc.sh"

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="adguardhome"
SERVICE_NAME="AdGuard Home"

DEFAULT_HOSTNAME="adguardhome"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"

CHANNEL="release"

pvs_usage_text() {
cat <<'EOF_PVS_USAGE'

adguardhome-lxc.sh — AdGuard Home on Proxmox VE, create to teardown.
Run this on a PVE host, as root.

  create              Create a Debian 12 LXC (matching the host's own
                      architecture — amd64 or arm64) and install
                      AdGuard Home inside it
  update <ctid>       Safely update AdGuard Home on an existing container:
                      backs up config/data, lets the upstream installer do
                      its reinstall, restores config/data, and rolls back
                      automatically if the new version doesn't come up
  uninstall <ctid>    Stop and remove AdGuard Home (--purge also wipes
                      config/data)
  status <ctid>       Show version + service state

Usage:
  ./adguardhome-lxc.sh create [options]
  ./adguardhome-lxc.sh update <ctid> [--channel release|beta|edge]
  ./adguardhome-lxc.sh uninstall <ctid> [--purge]
  ./adguardhome-lxc.sh status <ctid>

create options:
  -i, --id <id>          Container ID (default: next free ID)
  -n, --hostname <name>  Container hostname (default: adguardhome)
  -s, --storage <name>   Storage for the rootfs (default: local-lvm)
  -t, --template-storage <name>  Storage to keep CT templates on (default: local)
  -b, --bridge <name>    Network bridge (default: vmbr0)
  -d, --disk <GB>        Disk size in GB (default: 4)
  -c, --cores <n>        CPU cores (default: 1)
  -m, --memory <MB>      RAM in MB (default: 512)
  --static <cidr>        Static IP, e.g. 192.168.1.53/24 (default: dhcp)
  --gateway <ip>         Gateway, required with --static
  --channel <name>       AdGuard Home channel: release, beta, edge
  --template <spec>      Skip template auto-detection entirely, e.g.
                          local:vztmpl/debian-12-standard_12.7-1_arm64.tar.zst
                          (use this if 'pveam available' can't see an arm64
                          template on your box, e.g. some ARM/Pi Proxmox
                          builds with a broken/incomplete appliance mirror)

A DNS server wants a fixed address: --static is strongly recommended, since
every client on the LAN will be pointed at this container's IP.
EOF_PVS_USAGE
}
manage_script() {
cat <<'EOF_MANAGE_SCRIPT'
#!/usr/bin/env bash
# In-container management for AdGuard Home. Pushed to
# /usr/local/sbin/adguardhome-manage.sh by the host script, and re-pushed on
# every command, so the container always matches the host script's version.
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
die()  { printf "%b[x]%b %s\n" "$C_ERR" "$C_RESET" "$1" >&2; exit 1; }

trap 'die "failed at line $LINENO (exit code $?)"' ERR

require_root() { [[ "$(id -u)" -eq 0 ]] || die "must be run as root"; }

ensure_pkg() {
  local missing=() pkg
  for pkg in "$@"; do
    command -v "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  command -v apt-get >/dev/null 2>&1 || die "missing: ${missing[*]} (and apt-get is not available to install them)"
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}"
}

container_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

AGH_DIR="/opt/AdGuardHome"
AGH_BIN="${AGH_DIR}/AdGuardHome"
BACKUP_ROOT="/var/backups/adguardhome"
VENDOR_INSTALL_URL="https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh"
CHANNEL="release"
PURGE=0

is_installed() { [[ -x "$AGH_BIN" ]]; }

# Architecture/download/channel logic is deliberately NOT reimplemented here —
# it is delegated to AdGuard's own official installer. Hardcoding a URL like
# ".../AdGuardHome_linux_amd64.tar.gz" is exactly how "amd64 only" bugs happen
# the moment upstream changes something.
run_vendor_installer() {
  info "running AdGuard Home's official installer (channel: ${CHANNEL})"
  local tmp_script
  tmp_script="$(mktemp)"
  trap 'rm -f "$tmp_script"' RETURN
  curl -fsSL "$VENDOR_INSTALL_URL" -o "$tmp_script"
  sh "$tmp_script" -c "$CHANNEL" -o /opt -v "$@"
}

backup_state() {
  local stamp backup_dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${stamp}"
  mkdir -p "$backup_dir"
  [[ -f "${AGH_DIR}/AdGuardHome.yaml" ]] && cp -a "${AGH_DIR}/AdGuardHome.yaml" "$backup_dir/"
  [[ -d "${AGH_DIR}/data" ]] && cp -a "${AGH_DIR}/data" "$backup_dir/"
  [[ -x "$AGH_BIN" ]] && cp -a "$AGH_BIN" "${backup_dir}/AdGuardHome.bin"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/AdGuardHome.yaml" ]] && cp -a "${backup_dir}/AdGuardHome.yaml" "${AGH_DIR}/"
  [[ -d "${backup_dir}/data" ]] && cp -a "${backup_dir}/data" "${AGH_DIR}/"
  return 0
}

service_is_running() { "$AGH_BIN" -s status 2>/dev/null | grep -qi "running"; }

wait_for_service() {
  local tries=15
  while (( tries > 0 )); do
    service_is_running && return 0
    sleep 1
    (( tries-- ))
  done
  return 1
}

rollback() {
  local backup_dir="$1"
  "$AGH_BIN" -s stop >/dev/null 2>&1 || true
  [[ -f "${backup_dir}/AdGuardHome.bin" ]] && cp -a "${backup_dir}/AdGuardHome.bin" "$AGH_BIN"
  restore_state "$backup_dir"
  "$AGH_BIN" -s start >/dev/null 2>&1 || true
}

print_access_info() {
  echo
  ok "AdGuard Home setup wizard: http://$(container_ip):3000"
}

cmd_install() {
  require_root
  ensure_pkg curl
  is_installed && die "AdGuard Home is already installed at ${AGH_DIR} — use 'update' instead"
  run_vendor_installer
  ok "AdGuard Home installed"
  print_access_info
}

cmd_update() {
  require_root
  ensure_pkg curl
  is_installed || die "AdGuard Home is not installed — use 'install' instead"

  local old_version backup_dir
  old_version="$("$AGH_BIN" --version 2>/dev/null || echo "unknown")"
  info "current version: ${old_version}"

  backup_dir="$(backup_state)"
  ok "backed up config/data to ${backup_dir}"

  "$AGH_BIN" -s stop >/dev/null 2>&1 || true

  if ! run_vendor_installer -r; then
    warn "vendor installer failed — rolling back"
    rollback "$backup_dir"
    die "update failed, previous version restored"
  fi

  "$AGH_BIN" -s stop >/dev/null 2>&1 || true
  restore_state "$backup_dir"
  "$AGH_BIN" -s start >/dev/null 2>&1 || true

  if ! wait_for_service; then
    warn "AdGuard Home did not come up after update — rolling back"
    rollback "$backup_dir"
    die "update failed, previous version restored"
  fi

  local new_version
  new_version="$("$AGH_BIN" --version 2>/dev/null || echo "unknown")"
  ok "updated: ${old_version} -> ${new_version}"
  print_access_info
}

cmd_uninstall() {
  require_root
  is_installed || die "AdGuard Home is not installed"
  "$AGH_BIN" -s stop >/dev/null 2>&1 || true
  "$AGH_BIN" -s uninstall >/dev/null 2>&1 || true
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$AGH_DIR"
    ok "AdGuard Home service and files removed"
  else
    rm -f "$AGH_BIN"
    ok "AdGuard Home service removed, config/data kept at ${AGH_DIR}"
  fi
}

cmd_status() {
  is_installed || die "AdGuard Home is not installed"
  echo "version:  $("$AGH_BIN" --version 2>/dev/null || echo unknown)"
  echo "service:  $("$AGH_BIN" -s status 2>/dev/null || echo unknown)"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E ':(53|3000)\b' || true
  fi
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
      --channel) CHANNEL="$2"; shift 2 ;;
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
else
  C_INFO=""; C_OK=""; C_ERR=""; C_WARN=""; C_BRAND=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

# info/ok/warn/die are status output for a human, never a function's return
# value — they ALWAYS go to stderr. Several functions below return their
# result by being invoked as `x="$(some_func ...)"`; if a status message
# printed to stdout instead, it would get captured right along with the real
# return value and corrupt it silently.
info() { printf "%b[*]%b %s\n" "$C_INFO" "$C_RESET" "$1" >&2; }
ok()   { printf "%b[+]%b %s\n" "$C_OK" "$C_RESET" "$1" >&2; }
warn() { printf "%b[!]%b %s\n" "$C_WARN" "$C_RESET" "$1" >&2; }
die()  { printf "%b[x]%b %s\n" "$C_ERR" "$C_RESET" "$1" >&2; exit 1; }

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

banner() {
  [[ -t 1 ]] && clear
  printf "%b%s%b\n" "$C_BRAND" "$BANNER_ART" "$C_RESET"
  printf "%b%s%b\n" "$C_BOLD" "                    T E C H N O L O G I E S" "$C_RESET"
  printf "%b%s%b\n" "$C_DIM"  "             ${SERVICE_NAME} · Proxmox VE Automation" "$C_RESET"
  printf "%b%s%b\n" "$C_DIM"  "---------------------------------------------------------------" "$C_RESET"
}

# Runs a command quietly with a spinner + message; on failure, prints its
# captured output so nothing important is ever silently swallowed.
SPINNER_FRAMES="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
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
      (( i++ ))
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
  local lines=() line width=63 rule
  while IFS= read -r line || [[ -n "$line" ]]; do
    lines+=("$line")
    if (( ${#line} + 1 > width )); then width=$(( ${#line} + 1 )); fi
  done
  rule="$(printf '%*s' "$width" '' | tr ' ' '-')"

  printf "\n%b" "$C_OK"
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

ensure_template() {
  local arch="$1" template update_err avail_out avail_err

  # A --template override skips all of this — use it verbatim.
  if [[ -n "$TEMPLATE" ]]; then
    echo "$TEMPLATE"
    return 0
  fi

  info "checking for a ${TEMPLATE_DISTRO} (${arch}) container template"

  if ! update_err="$(pveam update 2>&1 >/dev/null)"; then
    warn "pveam update failed, continuing with whatever is already cached: ${update_err}"
  elif [[ -n "$update_err" ]]; then
    warn "pveam update: ${update_err}"
  fi

  avail_err="$(mktemp)"
  avail_out="$(pveam available --section system 2>"$avail_err" || true)"
  if [[ -s "$avail_err" ]]; then
    warn "pveam available reported: $(cat "$avail_err")"
  fi
  rm -f "$avail_err"

  template="$(printf '%s\n' "$avail_out" \
    | awk -v a="$arch" -v d="$TEMPLATE_DISTRO" '$2 ~ "^"d".*_"a"\\.tar\\.(zst|gz)$" {print $2}' \
    | sort -V | tail -n1)"

  if [[ -z "$template" ]]; then
    warn "no ${TEMPLATE_DISTRO} template for arch '${arch}' found. Entries currently listed:"
    printf '%s\n' "$avail_out" | grep -iE "${TEMPLATE_DISTRO%%-*}" 1>&2 \
      || echo "  (none at all — the appliance list looks empty or broken on this host)" 1>&2
    die "fix the appliance list (see warnings above), or skip auto-detection entirely with: --template <storage>:vztmpl/<filename>"
  fi

  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$template"; then
    run_step "downloading template ${template}" pveam download "$TEMPLATE_STORAGE" "$template"
  fi
  echo "${TEMPLATE_STORAGE}:vztmpl/${template}"
}

build_net_arg() {
  if [[ -n "$STATIC_CIDR" ]]; then
    echo "name=eth0,bridge=${BRIDGE},ip=${STATIC_CIDR},gw=${GATEWAY}"
  else
    echo "name=eth0,bridge=${BRIDGE},ip=dhcp"
  fi
}

# Success here means more than "the CT booted": it means DNS, routing and apt
# all work, which is the thing every installer downstream actually depends on.
wait_for_network() {
  local ctid="$1" tries=30
  info "waiting for container networking"
  while (( tries > 0 )); do
    if pct exec "$ctid" -- sh -c 'command -v curl >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq curl)' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    (( tries-- ))
  done
  die "container never came up with working networking/apt"
}

# Pushes the embedded management script into $ctid, always overwriting so the
# container stays in sync with whatever version of this file you're running.
push_manage_script() {
  local ctid="$1" tmp
  tmp="$(mktemp)"
  manage_script > "$tmp"
  pct push "$ctid" "$tmp" "$MANAGE_PATH"
  rm -f "$tmp"
  pct exec "$ctid" -- chmod +x "$MANAGE_PATH"
}

container_ip() {
  pct exec "$1" -- hostname -I 2>/dev/null | awk '{print $1}'
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
      --features "nesting=${NESTING}" \
      --onboot 1 \
      --start 0
  run_step "starting container ${ctid}" pct start "$ctid"
}
# lib/main.sh — defaults, argument parsing and the create/update/uninstall/
# status dispatcher shared by every script. Include this LAST: it reads the
# DEFAULT_* values the service set above it, and the svc_* hooks it defines
# here are meant to be overridden by the service below it.

trap 'die "failed at line $LINENO (exit code $?)"' ERR

# Runtime knobs, seeded from the service's DEFAULT_* block.
CTID=""
CT_HOSTNAME="${DEFAULT_HOSTNAME}"
ROOTFS_STORAGE="${DEFAULT_ROOTFS_STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${DEFAULT_TEMPLATE_STORAGE:-local}"
TEMPLATE_DISTRO="${DEFAULT_TEMPLATE_DISTRO:-debian-12-standard}"
BRIDGE="${DEFAULT_BRIDGE:-vmbr0}"
DISK_GB="${DEFAULT_DISK_GB:-4}"
CORES="${DEFAULT_CORES:-1}"
MEMORY_MB="${DEFAULT_MEMORY_MB:-512}"
UNPRIVILEGED="${DEFAULT_UNPRIVILEGED:-1}"
NESTING="${DEFAULT_NESTING:-0}"
STATIC_CIDR=""
GATEWAY=""
TEMPLATE=""
MANAGE_PATH="/usr/local/sbin/${SERVICE_ID}-manage.sh"
SVC_OPT_SHIFT=0
SVC_INSTALL_ARGS=()

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

parse_create_args() {
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
  return 0
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
    echo " Update       : ${self} update ${ctid}"
    echo " Status       : ${self} status ${ctid}"
    echo " Uninstall    : ${self} uninstall ${ctid}"
  } | print_summary_box

  if ! ran_from_file; then
    printf "%b[*]%b You ran this from a pipe, so there is no local copy yet. To manage CT %s later:\n" \
      "$C_INFO" "$C_RESET" "$ctid"
    printf "    curl -fsSL %s -o %s && chmod +x %s\n" \
      "$PVS_SCRIPT_URL" "$PVS_SCRIPT_FILENAME" "$PVS_SCRIPT_FILENAME"
  fi
}

do_create() {
  require_pve_host
  local arch ctid template net_arg ip

  arch="$(resolve_arch)"
  ctid="$(resolve_ctid)"
  template="$(ensure_template "$arch")"
  net_arg="$(build_net_arg)"

  info "target: CT ${ctid} (${CT_HOSTNAME}) on ${arch}, template ${template}"

  create_container "$ctid" "$template" "$net_arg"
  wait_for_network "$ctid"
  run_step "pushing management script" push_manage_script "$ctid"

  info "installing ${SERVICE_NAME}"
  svc_install_args
  pct exec "$ctid" -- "$MANAGE_PATH" install ${SVC_INSTALL_ARGS[@]+"${SVC_INSTALL_ARGS[@]}"}

  ip="$(container_ip "$ctid")"
  svc_post_create "$ctid" "${ip:-}"
  summary "$ctid" "${ip:-<CT-ip>}"
}

do_manage() {
  local ctid="$1" action="$2"; shift 2
  require_pve_host
  require_ctid_exists "$ctid"
  push_manage_script "$ctid"
  pct exec "$ctid" -- "$MANAGE_PATH" "$action" "$@"
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
svc_parse_option() {
  case "$1" in
    --channel)
      [[ -n "${2:-}" ]] || die "--channel needs a value (release, beta or edge)"
      case "$2" in
        release|beta|edge) ;;
        *) die "--channel must be one of: release, beta, edge (got '$2')" ;;
      esac
      CHANNEL="$2"; SVC_OPT_SHIFT=2; return 0 ;;
  esac
  return 1
}

svc_install_args() { SVC_INSTALL_ARGS=(--channel "$CHANNEL"); }

svc_summary_lines() {
  echo " Setup wizard : http://${2}:3000"
  echo " DNS server   : ${2}:53  (point your router/clients here)"
}

pvs_main "$@"
