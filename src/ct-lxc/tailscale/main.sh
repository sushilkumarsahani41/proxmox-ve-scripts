#!/usr/bin/env bash
#
# tailscale-lxc.sh — Tailscale mesh VPN on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian LXC and install Tailscale via its
#                       own official install script (adds Tailscale's apt
#                       repo, installs tailscale + tailscaled)
#   update <ctid>       Back up Tailscale's state, apt upgrade, verify
#                       tailscaled is still active — restores the backup
#                       and reports if not
#   uninstall <ctid>    Log out of the tailnet, remove the package (state
#                       kept on disk). --purge also drops it and backups
#   status <ctid>       Show this node's tailnet status (`tailscale status`)
#
# Usage:
#   ./tailscale-lxc.sh create [options]
#   ./tailscale-lxc.sh update <ctid>
#   ./tailscale-lxc.sh uninstall <ctid> [--purge]
#   ./tailscale-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: tailscale)
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
#                           — runs `tailscale up` automatically on install.
#                           Omit it and run `pct exec <ctid> -- tailscale up`
#                           yourself afterward (prints a login URL to visit)
#                           — these are typically valid for a much longer
#                           window than a one-shot claim token, so there's
#                           no rush the way Plex's --claim has.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# What actually matters for reaching this container afterward is its
# tailnet IP (100.x.x.x, shown by `status`), not its LAN address the way a
# DNS or media server's IP does — so unlike most other services here, this
# one has no static-IP recommendation of its own.
#
# Needs a `tun`-capable container: unprivileged LXCs have no access to
# /dev/net/tun by default, and this project has no --features flag for it —
# handled automatically (see CONTRIBUTING.md's write-up on enable_tun_device
# in lib/pve.sh if you're curious what that actually does to the container).
#
# Debian only — Tailscale's official install script covers many distros,
# but this project only wires up its Debian path.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="tailscale"
SERVICE_NAME="Tailscale"
# @tagline Zero-config mesh VPN, no port-forwarding needed

DEFAULT_HOSTNAME="tailscale"
DEFAULT_DISK_GB="2"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"
DEFAULT_NEEDS_TUN="1"

AUTH_KEY=""

# @usage
# @embed ct-lxc/tailscale/manage.sh AS manage_script
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
  echo " Join manually : pct exec ${1} -- tailscale up   (if no --authkey was given)"
  echo " Tailnet status: pct exec ${1} -- tailscale status"
}

pvs_main "$@"
