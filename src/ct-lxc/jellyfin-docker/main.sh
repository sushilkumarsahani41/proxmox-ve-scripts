#!/usr/bin/env bash
#
# jellyfin-docker-lxc.sh — Jellyfin via Docker on Proxmox VE, create to
# teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/jellyfin-lxc.sh, which installs
# Jellyfin natively via its own official installer. Same service, different
# packaging — pick this one for pull-based updates and the official image.
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official jellyfin/jellyfin image
#   update <ctid>       Back up Jellyfin's config directory, then
#                       `docker compose pull && up -d` — restores the
#                       backup and reports if the web UI doesn't come back
#   uninstall <ctid>    `docker compose down` (--purge also removes the
#                       config/cache directories and backups — your media
#                       directory is never touched, purge or not, see below)
#   status <ctid>       Show container status and the web UI's health
#
# Usage:
#   ./jellyfin-docker-lxc.sh create [options]
#   ./jellyfin-docker-lxc.sh update <ctid>
#   ./jellyfin-docker-lxc.sh uninstall <ctid> [--purge]
#   ./jellyfin-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: jellyfin-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 8 — for Jellyfin's own
#                           config/cache; point your media library at
#                           separately attached storage)
#   -c, --cores <n>        CPU cores (default: 2)
#   -m, --memory <MB>      RAM in MB (default: 2048)
#   --static <cidr>        Static IP, e.g. 192.168.1.59/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#
# There is no --webpassword-style flag, same as the native version: Jellyfin
# creates its admin account through a first-visit web setup wizard.
#
# Media lives at /opt/jellyfin-docker/media inside the container, bind-mounted
# into the container at /media — copy files in via `pct push`/`pct enter`, or
# replace it with a mount point to real storage after create (`pct set <ctid>
# -mp0 /host/path,mp=/opt/jellyfin-docker/media`). Uninstall (with or without
# --purge) never deletes this directory — only Jellyfin's own config/cache
# are ever removed, since media is *your* data, not Jellyfin's.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has no
# Alpine path. This needs internet access from the container to pull the
# image, and again on every `update`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="jellyfin-docker"
SERVICE_NAME="Jellyfin (Docker)"
# @tagline Jellyfin via the official Docker image

DEFAULT_HOSTNAME="jellyfin-docker"
DEFAULT_DISK_GB="8"
DEFAULT_CORES="2"
DEFAULT_MEMORY_MB="2048"
DEFAULT_PREFER_STATIC="y"
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

# @usage
# @embed ct-lxc/jellyfin-docker/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " Setup wizard  : http://${2}:8096"
  echo " Media folder  : /opt/jellyfin-docker/media inside the container"
}

pvs_main "$@"
