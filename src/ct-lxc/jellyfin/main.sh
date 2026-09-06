#!/usr/bin/env bash
#
# jellyfin-lxc.sh — Jellyfin media server on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian LXC and install Jellyfin via its
#                       own official install-debuntu.sh (adds Jellyfin's
#                       apt repo, installs the jellyfin/jellyfin-server/
#                       jellyfin-web/jellyfin-ffmpeg metapackage)
#   update <ctid>       Back up /etc/jellyfin and /var/lib/jellyfin, apt
#                       upgrade, verify the web UI comes back — restores
#                       the backup and reports if not
#   uninstall <ctid>    Remove Jellyfin (apt remove, data/config kept on
#                       disk). --purge also drops the data directory, the
#                       apt repo, and backups
#   status <ctid>       Show version, service state, listening port
#
# Usage:
#   ./jellyfin-lxc.sh create [options]
#   ./jellyfin-lxc.sh update <ctid>
#   ./jellyfin-lxc.sh uninstall <ctid> [--purge]
#   ./jellyfin-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: jellyfin)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 8 — this is just for
#                           Jellyfin itself and its metadata cache; point
#                           your media library at separately attached
#                           storage, this script has no opinion on that)
#   -c, --cores <n>        CPU cores (default: 2 — transcoding is
#                           CPU-hungry the moment a client can't direct-play)
#   -m, --memory <MB>      RAM in MB (default: 2048)
#   --static <cidr>        Static IP, e.g. 192.168.1.59/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation) — works for both
#                           `ssh root@<ip>` and `pct enter <ctid>` (the
#                           latter needs no password at all)
#
# There is no --webpassword-style flag: Jellyfin creates its admin account
# through a first-visit web setup wizard, not a CLI or env-var seed — open
# the URL this prints and complete it there.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# A media server wants a fixed address, the same reason AdGuard Home and
# Pi-hole do here — static IP is recommended.
#
# Debian only, no --os choice: Jellyfin's own installer supports Debian and
# Ubuntu derivatives, not Alpine.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="jellyfin"
SERVICE_NAME="Jellyfin"
# @tagline Free media server for movies, TV, and music

DEFAULT_HOSTNAME="jellyfin"
DEFAULT_DISK_GB="8"
DEFAULT_CORES="2"
DEFAULT_MEMORY_MB="2048"
DEFAULT_PREFER_STATIC="y"

# @usage
# @embed ct-lxc/jellyfin/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " Setup wizard  : http://${2}:8096"
}

pvs_main "$@"
