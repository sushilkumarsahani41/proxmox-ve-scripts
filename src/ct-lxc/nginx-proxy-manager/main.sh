#!/usr/bin/env bash
#
# nginx-proxy-manager-lxc.sh — Nginx Proxy Manager on Proxmox VE, create to
# teardown. Run this on a PVE host, as root.
#
# Docker-only, the same shape as ct-lxc/floci-lxc.sh: Nginx Proxy Manager's
# own project ships no apt package, no install script, and no documented
# non-Docker install path at all — checked directly against its own docs
# and a real GitHub issue asking for exactly this, not assumed. Its own
# docker-compose examples point at `jc21/nginx-proxy-manager`, so that's
# the image used here.
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the jc21/nginx-proxy-manager image
#   update <ctid>       Back up data/certificates, `docker compose pull &&
#                       up -d`, verify the admin UI answers — restores the
#                       backup and reports if not
#   uninstall <ctid>    Back up (unless --purge), `docker compose down`
#                       (--purge also removes the data and backups)
#   status <ctid>       Show container status and readiness
#
# Usage:
#   ./nginx-proxy-manager-lxc.sh create [options]
#   ./nginx-proxy-manager-lxc.sh update <ctid>
#   ./nginx-proxy-manager-lxc.sh uninstall <ctid> [--purge]
#   ./nginx-proxy-manager-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: nginx-proxy-manager)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 1024)
#   --static <cidr>        Static IP, e.g. 192.168.1.64/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#
# There is no --webpassword-style flag: current releases of Nginx Proxy
# Manager no longer ship a fixed default admin login — its own frontend
# checks for an empty user table and walks you through creating your first
# admin account on first visit instead (confirmed directly against a fresh
# install's database, not from older tutorials still repeating the
# once-real admin@example.com / changeme default). There's no CLI or env
# var to seed an account instead, so open the URL this prints and complete
# the setup screen there, the same as Jellyfin and AdGuard Home.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# A reverse proxy wants a fixed address — it's the front door every other
# service on your LAN would point at. Static IP is recommended.
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has no
# Alpine path. This needs internet access from the container to pull the
# image, and again on every `update`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="nginx-proxy-manager"
SERVICE_NAME="Nginx Proxy Manager"
# @tagline Reverse proxy admin UI with free Let's Encrypt certificates

DEFAULT_HOSTNAME="nginx-proxy-manager"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

# @usage
# @embed ct-lxc/nginx-proxy-manager/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " Admin UI      : http://${2}:81"
  echo " First visit   : complete the setup screen to create your admin account"
}

pvs_main "$@"
