#!/usr/bin/env bash
#
# plex-lxc.sh — Plex Media Server on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian LXC and install Plex from its own
#                       official apt repository (repo.plex.tv)
#   update <ctid>       Back up /var/lib/plexmediaserver, apt upgrade,
#                       verify the server answers — restores the backup
#                       and reports if not
#   uninstall <ctid>    Remove Plex (apt remove, data/config kept on
#                       disk). --purge also drops the data directory, the
#                       apt repo, and backups
#   status <ctid>       Show service state, listening port
#
# Usage:
#   ./plex-lxc.sh create [options]
#   ./plex-lxc.sh update <ctid>
#   ./plex-lxc.sh uninstall <ctid> [--purge]
#   ./plex-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: plex)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 8 — this is just for
#                           Plex itself and its metadata cache; point your
#                           media library at separately attached storage,
#                           this script has no opinion on that)
#   -c, --cores <n>        CPU cores (default: 2 — transcoding is
#                           CPU-hungry the moment a client can't direct-play)
#   -m, --memory <MB>      RAM in MB (default: 2048)
#   --static <cidr>        Static IP, e.g. 192.168.1.60/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation) — works for both
#                           `ssh root@<ip>` and `pct enter <ctid>` (the
#                           latter needs no password at all)
#
# Unlike every other service in this project, Plex genuinely requires a
# plex.tv account to finish setup — there is no local-only admin account.
# Open the URL this prints and sign in there to claim the server. (The
# Docker variant, plex-docker-lxc.sh, can automate this one step via
# --claim; the native install has no equivalent official mechanism, so this
# script doesn't attempt one.)
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# A media server wants a fixed address, the same reason AdGuard Home,
# Pi-hole, and Jellyfin do here — static IP is recommended.
#
# Debian only, no --os choice: Plex's own apt repository covers Debian and
# Ubuntu, not Alpine.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="plex"
SERVICE_NAME="Plex"
# @tagline Stream your media library, with optional remote access

DEFAULT_HOSTNAME="plex"
DEFAULT_DISK_GB="8"
DEFAULT_CORES="2"
DEFAULT_MEMORY_MB="2048"
DEFAULT_PREFER_STATIC="y"

# @usage
# @embed ct-lxc/plex/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " Setup & sign-in: http://${2}:32400/web"
}

pvs_main "$@"
