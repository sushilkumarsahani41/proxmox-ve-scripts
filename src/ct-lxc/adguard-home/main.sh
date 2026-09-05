#!/usr/bin/env bash
#
# adguard-home-lxc.sh — AdGuard Home on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create an LXC (Debian by default, or Alpine with
#                       --os alpine — newest template the host has or can
#                       fetch, matching its own architecture: amd64 or
#                       arm64) and install AdGuard Home inside it
#   update <ctid>       Safely update AdGuard Home on an existing container:
#                       backs up config/data, lets the upstream installer do
#                       its reinstall, restores config/data, and rolls back
#                       automatically if the new version doesn't come up
#   uninstall <ctid>    Stop and remove AdGuard Home (--purge also wipes
#                       config/data)
#   status <ctid>       Show version + service state
#
# Usage:
#   ./adguard-home-lxc.sh create [options]
#   ./adguard-home-lxc.sh update <ctid> [--channel release|beta|edge]
#   ./adguard-home-lxc.sh uninstall <ctid> [--purge]
#   ./adguard-home-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: adguardhome)
#   --os <name>             debian (default) or alpine — Alpine boots faster
#                           and has a smaller footprint; Debian has the wider
#                           package ecosystem if you ever exec into the box
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 512)
#   --static <cidr>        Static IP, e.g. 192.168.1.53/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Root password (default: random, shown once after
#                           creation) — works for both `ssh root@<ip>` and
#                           `pct enter <ctid>` (the latter needs no password
#                           at all, if you'd rather skip this entirely)
#   --channel <name>       AdGuard Home channel: release, beta, edge
#   --template <spec>      Skip template auto-detection entirely, e.g.
#                           local:vztmpl/debian-13-standard_13.6-1_arm64.tar.zst
#                           or local:vztmpl/alpine-3.24-default_arm64.tar.xz
#                           (rarely needed — detection already falls back to
#                           templates already cached on the host when the
#                           appliance mirror is broken or unreachable)
#
# Run with no options on a terminal and it asks about each setting, showing the
# recommended value in brackets — Enter accepts it. Pass any option (or -y) and
# it runs straight through without asking, so scripts stay predictable.
#
# A DNS server wants a fixed address: a static IP is strongly recommended, since
# every client on the LAN will be pointed at this container's IP.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="adguard-home"
SERVICE_NAME="AdGuard Home"
# @tagline Network-wide DNS ad and tracker blocking

DEFAULT_HOSTNAME="adguard"
DEFAULT_DISK_GB="2"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"
# AdGuard Home's own installer registers itself with whatever init system it
# finds (systemd on Debian, OpenRC on Alpine) and exposes identical `-s
# start|stop|status` control either way, so manage.sh below needed zero
# OS-specific code to support this — verified on a real arm64 Alpine
# container, not assumed. Debian stays the recommended default: longer track
# record in this project, and apt if you ever need to exec in and debug.
DEFAULT_OS="debian"
DEFAULT_OS_CHOICES="debian alpine"
# Every client on the LAN ends up pointed at this container's address, so a
# lease that can change is a footgun. The prompt defaults to yes accordingly.
DEFAULT_PREFER_STATIC="y"

CHANNEL="release"

# @usage
# @embed ct-lxc/adguard-home/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

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

svc_prompt() {
  CHANNEL="$(ask_choice "AdGuard Home channel" "$CHANNEL" "$(printf 'release\nbeta\nedge')")"
}

svc_plan_lines() {
  echo " Channel       : ${CHANNEL}"
}

svc_summary_lines() {
  echo " Setup wizard : http://${2}:3000"
  echo " DNS server   : ${2}:53  (point your router/clients here)"
}

pvs_main "$@"
