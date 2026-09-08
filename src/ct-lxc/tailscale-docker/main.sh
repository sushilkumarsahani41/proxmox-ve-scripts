#!/usr/bin/env bash
#
# tailscale-docker-lxc.sh — Tailscale via Docker on Proxmox VE, create to
# teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/tailscale-lxc.sh, which installs
# Tailscale natively via its own official install script. Same mesh VPN,
# different packaging — pick this one for pull-based updates and the
# official image.
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official tailscale/tailscale image
#   update <ctid>       Back up Tailscale's state, `docker compose pull &&
#                       up -d`, verify it's still running — restores the
#                       backup and reports if not
#   uninstall <ctid>    Log out of the tailnet, `docker compose down`
#                       (--purge also removes the state and backups)
#   status <ctid>       Show this node's tailnet status
#
# Usage:
#   ./tailscale-docker-lxc.sh create [options]
#   ./tailscale-docker-lxc.sh update <ctid>
#   ./tailscale-docker-lxc.sh uninstall <ctid> [--purge]
#   ./tailscale-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: tailscale-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 2)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 512)
#   --static <cidr>        Static IP, e.g. 192.168.1.63/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#   --authkey <key>        An auth key from
#                           https://login.tailscale.com/admin/settings/keys
#                           — joins the tailnet automatically on first boot
#                           via the image's own TS_AUTHKEY. Omit it and run
#                           `pct exec <ctid> -- docker exec tailscale-docker-tailscale-1
#                           tailscale up` yourself afterward.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# What actually matters for reaching this container afterward is its
# tailnet IP, not its LAN address — no static-IP recommendation here.
#
# Needs a `tun`-capable container at two levels, both handled automatically:
# the LXC itself (same as the native script — see enable_tun_device in
# lib/pve.sh) and the Docker container running inside it (this script's own
# compose file requests `NET_ADMIN` and the tun device the ordinary way any
# Tailscale-in-Docker setup would, on top of that).
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has no
# Alpine path. This needs internet access from the container to pull the
# image, and again on every `update`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="tailscale-docker"
SERVICE_NAME="Tailscale (Docker)"
# @tagline Tailscale via the official Docker image

DEFAULT_HOSTNAME="tailscale-docker"
DEFAULT_DISK_GB="2"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"
DEFAULT_NEEDS_TUN="1"

AUTH_KEY=""

# @usage
# @embed ct-lxc/tailscale-docker/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_parse_option() {
  case "$1" in
    --authkey)
      [[ -n "${2:-}" ]] || die "--authkey needs a value — get one from https://login.tailscale.com/admin/settings/keys"
      AUTH_KEY="$2"; SVC_OPT_SHIFT=2; return 0 ;;
  esac
  return 1
}

svc_install_args() {
  if [[ -n "$AUTH_KEY" ]]; then
    SVC_INSTALL_ARGS=(--authkey "$AUTH_KEY")
  else
    SVC_INSTALL_ARGS=()
  fi
}

svc_plan_lines() {
  if [[ -n "$AUTH_KEY" ]]; then
    echo " Auth key      : provided — will join the tailnet automatically"
  fi
  return 0
}

svc_summary_lines() {
  echo " Tailnet status: pct exec ${1} -- docker exec tailscale-docker-tailscale-1 tailscale status"
}

pvs_main "$@"
