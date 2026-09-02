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

# @usage
# @embed ct-lxc/adguardhome/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
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

svc_summary_lines() {
  echo " Setup wizard : http://${2}:3000"
  echo " DNS server   : ${2}:53  (point your router/clients here)"
}

pvs_main "$@"
