#!/usr/bin/env bash
#
# adguard-home-docker-lxc.sh — AdGuard Home via Docker on Proxmox VE, create
# to teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/adguard-home-lxc.sh, which
# installs AdGuard Home natively (no Docker). Same service, different
# packaging — pick this one if you'd rather manage it as a container
# (pull-based updates, the official image).
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official adguard/adguardhome image
#   update <ctid>       Back up the config/work directories, then
#                       `docker compose pull && up -d` — restores the
#                       backup if health looks wrong afterward (the image
#                       itself isn't rolled back, only the data)
#   uninstall <ctid>    `docker compose down` (--purge also removes the
#                       data directories and backups)
#   status <ctid>       Show container status and the admin UI's health
#
# Usage:
#   ./adguard-home-docker-lxc.sh create [options]
#   ./adguard-home-docker-lxc.sh update <ctid>
#   ./adguard-home-docker-lxc.sh uninstall <ctid> [--purge]
#   ./adguard-home-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: adguard-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 1024 — Docker's own daemon
#                           adds overhead beyond AdGuard Home itself)
#   --static <cidr>        Static IP, e.g. 192.168.1.55/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation) — works for both
#                           `ssh root@<ip>` and `pct enter <ctid>` (the
#                           latter needs no password at all)
#
# There is no --webpassword-style flag here, same as the native version:
# AdGuard Home's own Docker image has no env var for seeding the admin
# account either — open the URL this prints and complete the setup wizard.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has
# no Alpine path.
#
# This needs internet access from the container to pull the image, and
# again on every `update`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="adguard-home-docker"
SERVICE_NAME="AdGuard Home (Docker)"
# @tagline AdGuard Home via the official Docker image
# @alias adguardhome-docker

DEFAULT_HOSTNAME="adguard-docker"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"
# Docker needs both, verified together on a real host (see CONTRIBUTING.md).
# get.docker.com has no Alpine path, so this is Debian-only, same as Floci.
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

# @usage
# @embed ct-lxc/adguard-home-docker/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " Setup wizard  : http://${2}:3000"
  echo " DNS server    : ${2}:53  (point your router/clients here)"
}

pvs_main "$@"
