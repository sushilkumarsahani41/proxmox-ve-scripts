#!/usr/bin/env bash
#
# sharkshell-docker-lxc.sh — SharkShell via Docker on Proxmox VE, create to
# teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/sharkshell-lxc.sh, which builds
# SharkShell from source on the container (no Docker, deploy.sh). Same
# service, different packaging — pick this one if you'd rather manage it as
# a container (pull-based updates, the official image, no Node/npm build on
# the container at all).
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official greatsharktech/sharkshell image
#   update <ctid>       Stop the container (for a consistent file-level
#                       backup of its built-in Postgres data), back up,
#                       `docker compose pull && up -d` — restores the
#                       backup if health looks wrong afterward (the image
#                       itself isn't rolled back, only the data)
#   uninstall <ctid>    Stop, back up (unless --purge), `docker compose
#                       down` (--purge also removes the data and backups)
#   status <ctid>       Show container status and the app's health
#
# Usage:
#   ./sharkshell-docker-lxc.sh create [options]
#   ./sharkshell-docker-lxc.sh update <ctid>
#   ./sharkshell-docker-lxc.sh uninstall <ctid> [--purge]
#   ./sharkshell-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: sharkshell-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1 — no build happens on the
#                           container, unlike the source-build version)
#   -m, --memory <MB>      RAM in MB (default: 1024)
#   --static <cidr>        Static IP, e.g. 192.168.1.62/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation) — works for both
#                           `ssh root@<ip>` and `pct enter <ctid>` (the
#                           latter needs no password at all)
#
# There is no --webpassword-style flag: SharkShell creates its admin account
# through a first-visit web setup screen, not a CLI or env-var seed — open
# the URL this prints and complete it there.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has
# no Alpine path.
#
# greatsharktech/sharkshell is published amd64-only — there is no arm64
# manifest, so `create` will pull the image, fail, and leave the container
# up with Docker installed but nothing running (fix or wait for an arm64
# build, then re-run `update` on the same container to retry the pull). Runs
# fine on an amd64 PVE host; on arm64 (e.g. a Raspberry Pi) use
# ./sharkshell-lxc.sh instead, which builds from source and isn't affected.
#
# This needs internet access from the container to pull the image, and
# again on every `update`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="sharkshell-docker"
SERVICE_NAME="SharkShell (Docker)"
# @tagline SharkShell via the official Docker image

DEFAULT_HOSTNAME="sharkshell-docker"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"
# Docker needs both, verified together on a real host (see CONTRIBUTING.md).
# get.docker.com has no Alpine path, so this is Debian-only, same as Floci.
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

# @usage
# @embed ct-lxc/sharkshell-docker/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " SharkShell URL: http://${2}"
  echo " First visit   : complete the Admin Account Setup screen"
}

pvs_main "$@"
