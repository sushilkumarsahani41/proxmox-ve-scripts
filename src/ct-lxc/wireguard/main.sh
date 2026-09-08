#!/usr/bin/env bash
#
# wireguard-lxc.sh — WireGuard VPN server on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian LXC, install wireguard-tools from
#                       Debian's own repository, and bring up a working
#                       server with one client already configured
#   update <ctid>       Back up /etc/wireguard, apt upgrade, verify the
#                       interface is still up — restores the backup and
#                       reports if not
#   uninstall <ctid>    Remove WireGuard (apt remove, keys/client configs
#                       kept on disk). --purge also drops them and backups
#   status <ctid>       Show the interface and connected peers (`wg show`)
#
# Usage:
#   ./wireguard-lxc.sh create [options]
#   ./wireguard-lxc.sh update <ctid>
#   ./wireguard-lxc.sh uninstall <ctid> [--purge]
#   ./wireguard-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: wireguard)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 2)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 512)
#   --static <cidr>        Static IP, e.g. 192.168.1.61/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#
# Adding, removing, or listing clients beyond the first one this creates is
# not a create-time flag — it's an ongoing thing you'll do over the life of
# the server, so it's a command on the container itself, not this script
# (pct exec needs the full path — it doesn't search /usr/local/sbin the way
# a login shell would):
#   pct exec <ctid> -- /usr/local/sbin/wireguard-manage.sh add-client <name>
#   pct exec <ctid> -- /usr/local/sbin/wireguard-manage.sh remove-client <name>
#   pct exec <ctid> -- /usr/local/sbin/wireguard-manage.sh list-clients
#   pct exec <ctid> -- /usr/local/sbin/wireguard-manage.sh show-client <name>
#                       (prints the client's .conf and a scannable QR code)
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# This is a VPN endpoint, so it wants a fixed address for the same reason
# AdGuard Home and Pi-hole do — static IP (or a port-forward to it) is how
# clients out on the internet actually reach it.
#
# Needs a `tun`-capable container: unprivileged LXCs have no access to
# /dev/net/tun by default, and this project has no --features flag for it —
# handled automatically (see CONTRIBUTING.md's write-up on enable_tun_device
# in lib/pve.sh if you're curious what that actually does to the container).
#
# Debian only — this delegates to Debian's own wireguard-tools package, not
# a third-party repo.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="wireguard"
SERVICE_NAME="WireGuard"
# @tagline Fast, modern VPN tunnel

DEFAULT_HOSTNAME="wireguard"
DEFAULT_DISK_GB="2"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"
DEFAULT_PREFER_STATIC="y"
DEFAULT_NEEDS_TUN="1"

# @usage
# @embed ct-lxc/wireguard/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " VPN endpoint  : ${2}:51820 (UDP)"
  echo " First client  : pct exec ${1} -- /usr/local/sbin/wireguard-manage.sh show-client peer1"
}

pvs_main "$@"
