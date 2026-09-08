#!/usr/bin/env bash
#
# traefik-docker-lxc.sh — Traefik via Docker on Proxmox VE, create to
# teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/traefik-lxc.sh, which downloads
# the official binary release and runs it under a systemd unit this project
# writes itself. Same proxy, different packaging — pick this one for
# pull-based updates and the official Docker Official Image.
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official traefik image
#   update <ctid>       Back up config, `docker compose pull && up -d`,
#                       verify the dashboard answers — restores the backup
#                       and reports if not
#   uninstall <ctid>    `docker compose down` (--purge also removes the
#                       config and backups)
#   status <ctid>       Show container status and whether Traefik answers
#
# Usage:
#   ./traefik-docker-lxc.sh create [options]
#   ./traefik-docker-lxc.sh update <ctid>
#   ./traefik-docker-lxc.sh uninstall <ctid> [--purge]
#   ./traefik-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: traefik-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 2)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 512)
#   --static <cidr>        Static IP, e.g. 192.168.1.62/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#
# Routes go in /opt/traefik-docker/config/dynamic.yml on the container
# (Traefik watches it and reloads automatically). Same "insecure" dashboard
# trade-off as the native script — fine on a private LAN, not meant to be
# exposed past it as-is.
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
SERVICE_ID="traefik-docker"
SERVICE_NAME="Traefik (Docker)"
# @tagline Traefik via the official Docker image

DEFAULT_HOSTNAME="traefik-docker"
DEFAULT_DISK_GB="2"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"
DEFAULT_PREFER_STATIC="y"
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

# @usage
# @embed ct-lxc/traefik-docker/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " Dashboard     : http://${2}:8080/dashboard/"
  echo " Routes go in  : /opt/traefik-docker/config/dynamic.yml"
}

pvs_main "$@"
