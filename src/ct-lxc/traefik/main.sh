#!/usr/bin/env bash
#
# traefik-lxc.sh — Traefik reverse proxy on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
# Traefik has no official apt package or install script — its only official
# non-Docker distribution is a static binary published on GitHub Releases
# (checked directly: amd64/arm64/armv7 builds exist for every release). This
# script downloads the latest one and runs it under a systemd unit this
# project writes itself, the same shape this project already uses when a
# vendor genuinely ships no packaging of its own.
#
#   create              Create a Debian LXC and install the latest Traefik
#                       release binary
#   update <ctid>       Back up config, re-fetch the latest release,
#                       restart, verify the dashboard answers — restores
#                       the backup and reports if not
#   uninstall <ctid>    Stop and remove the binary/service (config and any
#                       ACME certificates kept on disk). --purge also drops
#                       those and backups
#   status <ctid>       Show service state and whether Traefik answers
#
# Usage:
#   ./traefik-lxc.sh create [options]
#   ./traefik-lxc.sh update <ctid>
#   ./traefik-lxc.sh uninstall <ctid> [--purge]
#   ./traefik-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: traefik)
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
# Routes go in /etc/traefik/dynamic.yml on the container (Traefik watches it
# and reloads automatically — no restart needed) — this script only stands
# up the proxy itself, not any routes through it, since what you're routing
# to is entirely yours to define.
#
# The dashboard runs in Traefik's own documented "insecure" mode (no auth,
# HTTP only) on port 8080 — fine on a private LAN, same reasoning this
# project already applies to root SSH and every database service here; put
# something in front of it (or a dynamic.yml router with auth middleware)
# before exposing this beyond your LAN.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# A reverse proxy wants a fixed address — it's the front door every other
# service on your LAN would point at. Static IP is recommended.
#
# Debian only — no Alpine path: the systemd unit this writes has no OpenRC
# equivalent here yet.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="traefik"
SERVICE_NAME="Traefik"
# @tagline Reverse proxy and load balancer with automatic reloads

DEFAULT_HOSTNAME="traefik"
DEFAULT_DISK_GB="2"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"
DEFAULT_PREFER_STATIC="y"

# @usage
# @embed ct-lxc/traefik/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " Dashboard     : http://${2}:8080/dashboard/"
  echo " Routes go in  : /etc/traefik/dynamic.yml (watched, no restart needed)"
}

pvs_main "$@"
