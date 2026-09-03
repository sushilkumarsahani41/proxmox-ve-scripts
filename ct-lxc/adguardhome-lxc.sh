#!/usr/bin/env bash
#
# adguardhome-lxc.sh — AdGuard Home on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian LXC (newest Debian template the host
#                       has or can fetch, matching its own architecture —
#                       amd64 or arm64) and install AdGuard Home inside it
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
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 512)
#   --static <cidr>        Static IP, e.g. 192.168.1.53/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --channel <name>       AdGuard Home channel: release, beta, edge
#   --template <spec>      Skip template auto-detection entirely, e.g.
#                           local:vztmpl/debian-13-standard_13.6-1_arm64.tar.zst
#                           (rarely needed — detection already falls back to
#                           templates already cached on the host when the
#                           appliance mirror is broken or unreachable)
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
# @tagline Network-wide DNS ad and tracker blocking

DEFAULT_HOSTNAME="adguardhome"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"

CHANNEL="release"

pvs_usage_text() {
cat <<'EOF_PVS_USAGE'

adguardhome-lxc.sh — AdGuard Home on Proxmox VE, create to teardown.
Run this on a PVE host, as root.

  create              Create a Debian LXC (newest Debian template the host
                      has or can fetch, matching its own architecture —
                      amd64 or arm64) and install AdGuard Home inside it
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
  -s, --storage <name>   Storage for the rootfs (default: auto-detected)
  -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
  -b, --bridge <name>    Network bridge (default: vmbr0)
  -d, --disk <GB>        Disk size in GB (default: 4)
  -c, --cores <n>        CPU cores (default: 1)
  -m, --memory <MB>      RAM in MB (default: 512)
  --static <cidr>        Static IP, e.g. 192.168.1.53/24 (default: dhcp)
  --gateway <ip>         Gateway, required with --static
  --channel <name>       AdGuard Home channel: release, beta, edge
  --template <spec>      Skip template auto-detection entirely, e.g.
                          local:vztmpl/debian-13-standard_13.6-1_arm64.tar.zst
                          (rarely needed — detection already falls back to
                          templates already cached on the host when the
                          appliance mirror is broken or unreachable)

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
# `trap - ERR` first: die() is a deliberate exit, and without this the ERR
# trap fires on the way out and prints a second, useless "failed at line N"
# underneath the real explanation.
die()  { printf "%b[x]%b %s\n" "$C_ERR" "$C_RESET" "$1" >&2; trap - ERR; exit 1; }

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

# Deliberately separate from is_installed: a plain `uninstall` removes the
# binary but keeps ${AGH_DIR}, so "uninstall, then decide to purge after all"
# is a natural sequence that must not be refused for having nothing to remove.
has_data() { [[ -d "$AGH_DIR" ]]; }

agh_version() { "$AGH_BIN" --version 2>&1 | sed -n 's/^AdGuard Home, version //p' | tail -n1; }

# Architecture/download/channel logic is deliberately NOT reimplemented here —
# it is delegated to AdGuard's own official installer. Hardcoding a URL like
# ".../AdGuardHome_linux_amd64.tar.gz" is exactly how "amd64 only" bugs happen
# the moment upstream changes something.
# Cleanup is explicit rather than a `trap ... RETURN`: a RETURN trap set inside
# a function is not scoped to that function (that needs `set -o functrace`), so
# it stays installed and fires again on the *next* function return — by which
# point $tmp_script is out of scope and `set -u` kills the script. That bug hid
# here happily, because it only triggered after the install had already
# succeeded.
run_vendor_installer() {
  info "running AdGuard Home's official installer (channel: ${CHANNEL})"
  local tmp_script rc=0
  tmp_script="$(mktemp)"
  if curl -fsSL "$VENDOR_INSTALL_URL" -o "$tmp_script"; then
    sh "$tmp_script" -c "$CHANNEL" -o /opt -v "$@" || rc=$?
  else
    rc=1
  fi
  rm -f "$tmp_script"
  return "$rc"
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

# AdGuard Home writes `-s status` to STDERR, not stdout. The 2>&1 here is
# load-bearing: without it this reads an empty string, concludes the service is
# down, and cmd_update rolls back every single time — including after a
# perfectly good upgrade. systemd is the cross-check, since the vendor
# installer registers a unit anyway.
service_state() {
  local out
  out="$("$AGH_BIN" -s status 2>&1 || true)"
  case "$out" in
    *"service: running"*) echo "running"; return 0 ;;
    *"service: stopped"*) echo "stopped"; return 0 ;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    case "$(systemctl is-active AdGuardHome 2>/dev/null || true)" in
      active) echo "running" ;;
      inactive|failed) echo "stopped" ;;
      *) echo "unknown" ;;
    esac
  else
    echo "unknown"
  fi
}

service_is_running() { [[ "$(service_state)" == "running" ]]; }

wait_for_service() {
  local tries=15
  while (( tries > 0 )); do
    service_is_running && return 0
    sleep 1
    tries=$(( tries - 1 ))
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
  old_version="$(agh_version)"
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
  new_version="$(agh_version)"
  ok "updated: ${old_version} -> ${new_version}"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "AdGuard Home is not installed and there is nothing left at ${AGH_DIR}"
  fi
  if is_installed; then
    "$AGH_BIN" -s stop >/dev/null 2>&1 || true
    "$AGH_BIN" -s uninstall >/dev/null 2>&1 || true
  fi
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
  echo "version:  $(agh_version)"
  echo "service:  $(service_state)"
  echo "address:  http://$(container_ip):3000"
  # -u as well as -t: DNS is UDP, and port 53 is the entire point of this
  # container. It stays unbound until the setup wizard has been completed.
  if command -v ss >/dev/null 2>&1; then
    echo "ports:"
    ss -ltunp 2>/dev/null | awk 'NR==1 || /:(53|3000) /' | sed 's/^/  /' || true
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

banner() {
  [[ -t 1 ]] && clear
  printf "%b%s%b\n" "$C_BRAND" "$BANNER_ART" "$C_RESET"
  printf "%b%s%b\n" "$C_BOLD" "                    T E C H N O L O G I E S" "$C_RESET"
  printf "%b%s%b\n" "$C_DIM"  "             ${SERVICE_NAME} - Proxmox VE Automation" "$C_RESET"
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

# Container templates are named like: debian-13-standard_13.6-1_arm64.tar.zst
# TEMPLATE_PATTERN matches the leading name part, and the default deliberately
# accepts *any* Debian major version — pinning "debian-12" means the script
# breaks on a host whose mirror only offers 13, which is exactly what a current
# PVE 9 arm64 install looks like.
template_regex() { printf '^%s_[^_]*_%s\.tar\.(zst|gz)$' "$TEMPLATE_PATTERN" "$1"; }

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
  info "looking for a ${TEMPLATE_LABEL} (${arch}) container template"

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
    warn "no ${TEMPLATE_LABEL} template for arch '${arch}' is cached or offered (pattern: ${TEMPLATE_PATTERN})."
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
    tries=$(( tries - 1 ))
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
# Empty means "work it out from the host" — see resolve_storage().
ROOTFS_STORAGE="${DEFAULT_ROOTFS_STORAGE:-}"
TEMPLATE_STORAGE="${DEFAULT_TEMPLATE_STORAGE:-}"
TEMPLATE_PATTERN="${DEFAULT_TEMPLATE_PATTERN:-debian-[0-9]+-standard}"
# TEMPLATE_PATTERN is a regex and reads like one; keep it out of status lines.
TEMPLATE_LABEL="${DEFAULT_TEMPLATE_LABEL:-Debian}"
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
  ROOTFS_STORAGE="$(resolve_storage rootdir "$ROOTFS_STORAGE" "local-lvm local-zfs local")"
  TEMPLATE_STORAGE="$(resolve_storage vztmpl "$TEMPLATE_STORAGE" "local")"
  template="$(ensure_template "$arch")"
  net_arg="$(build_net_arg)"

  info "target: CT ${ctid} (${CT_HOSTNAME}) on ${arch}, rootfs ${ROOTFS_STORAGE}, template ${template}"

  create_container "$ctid" "$template" "$net_arg"
  wait_for_network "$ctid"
  run_step "pushing management script" push_manage_script "$ctid"

  info "installing ${SERVICE_NAME}"
  svc_install_args
  pct_exec_manage "$ctid" install ${SVC_INSTALL_ARGS[@]+"${SVC_INSTALL_ARGS[@]}"}

  ip="$(container_ip "$ctid")"
  svc_post_create "$ctid" "${ip:-}"
  summary "$ctid" "${ip:-<CT-ip>}"
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

do_manage() {
  local ctid="$1" action="$2"; shift 2
  require_pve_host
  require_ctid_exists "$ctid"
  push_manage_script "$ctid"
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
