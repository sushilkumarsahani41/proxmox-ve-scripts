#!/usr/bin/env bash
#
# sharkshell-lxc.sh — SharkShell on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian LXC and install SharkShell via its
#                       own script-based deploy (no Docker): Node.js,
#                       nginx, and PostgreSQL, all built on the container
#   update <ctid>       Back up the database, then delegate to `sharkshell
#                       update` (SharkShell's own git-pull + rebuild +
#                       restart) — this project does not reimplement it
#   uninstall <ctid>    Back up the database (unless --purge), then
#                       delegate to `sharkshell uninstall --force`
#   status <ctid>       Show service, health, version, and the admin URL
#
# Usage:
#   ./sharkshell-lxc.sh create [options]
#   ./sharkshell-lxc.sh update <ctid>
#   ./sharkshell-lxc.sh uninstall <ctid> [--purge]
#   ./sharkshell-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: sharkshell)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 6 — Node/nginx/Postgres
#                           packages plus two node_modules trees add up to
#                           more than the ~1GB SharkShell's own docs estimate)
#   -c, --cores <n>        CPU cores (default: 2 — frontend and backend both
#                           get compiled on the container itself)
#   -m, --memory <MB>      RAM in MB (default: 2048 — SharkShell's own docs
#                           cite ~1.5GB during the build, ~512MB at runtime)
#   --static <cidr>        Static IP, e.g. 192.168.1.61/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation). pct enter <ctid> from the
#                           host always works without one.
#
# There is no --webpassword-style flag here: SharkShell creates its admin
# account through a first-visit web setup screen, not a CLI seed — open the
# URL this prints and follow it.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# Debian only, no --os choice: SharkShell's own deploy.sh also supports
# Alpine (apk + OpenRC), but that path has not been verified by this
# project the way its Debian path has — see CONTRIBUTING.md before adding
# it.
#
# This needs internet access from the container to clone the source and to
# fetch Node.js and npm packages during the build — this is a build-once
# service, not something that keeps pulling from the network afterward.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="sharkshell"
SERVICE_NAME="SharkShell"
# @tagline Self-hosted web SSH client with 2FA and an MCP server

DEFAULT_HOSTNAME="sharkshell"
DEFAULT_DISK_GB="6"
DEFAULT_CORES="2"
DEFAULT_MEMORY_MB="2048"
# A web SSH client wants a fixed address for the same reason a DNS server
# does — this is the thing people bookmark and script other tools against.
DEFAULT_PREFER_STATIC="y"

# @usage
# @embed ct-lxc/sharkshell/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_summary_lines() {
  echo " SharkShell URL: http://${2}"
  echo " First visit   : complete the Admin Account Setup screen — open"
  echo "                 registration is disabled immediately afterward"
}

pvs_main "$@"
