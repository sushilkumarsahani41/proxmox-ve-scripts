#!/usr/bin/env bash
#
# pi-hole-docker-lxc.sh — Pi-hole via Docker on Proxmox VE, create to
# teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/pi-hole-lxc.sh, which installs
# Pi-hole natively (apt, no Docker). Same service, different packaging —
# pick this one if you'd rather manage it as a container (pull-based
# updates, the official image, no apt package churn on the container).
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official pihole/pihole image
#   update <ctid>       Back up /etc/pihole, then `docker compose pull &&
#                       up -d` — restores the backup if health looks wrong
#                       afterward (the image itself isn't rolled back, only
#                       the data)
#   uninstall <ctid>    `docker compose down` (--purge also removes the
#                       data directory and backups)
#   status <ctid>       Show container status and the admin UI's health
#
# Usage:
#   ./pi-hole-docker-lxc.sh create [options]
#   ./pi-hole-docker-lxc.sh update <ctid>
#   ./pi-hole-docker-lxc.sh uninstall <ctid> [--purge]
#   ./pi-hole-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: pihole-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 1024 — Docker's own daemon
#                           adds overhead beyond Pi-hole itself)
#   --static <cidr>        Static IP, e.g. 192.168.1.54/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation) — works for both
#                           `ssh root@<ip>` and `pct enter <ctid>` (the
#                           latter needs no password at all)
#   --webpassword <pass>   Pi-hole admin web UI password (default: random,
#                           shown once after creation, min 8 characters)
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
SERVICE_ID="pi-hole-docker"
SERVICE_NAME="Pi-hole (Docker)"
# @tagline Pi-hole via the official Docker image

DEFAULT_HOSTNAME="pihole-docker"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"
# Docker needs both, verified together on a real host (see CONTRIBUTING.md).
# get.docker.com has no Alpine path, so this is Debian-only, same as Floci.
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

WEBPASSWORD=""

# @usage
# @embed ct-lxc/pi-hole-docker/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_parse_option() {
  case "$1" in
    --webpassword)
      [[ -n "${2:-}" ]] || die "--webpassword needs a value"
      v_password "$2" || die "--webpassword must be at least 8 characters"
      WEBPASSWORD="$2"; SVC_OPT_SHIFT=2; return 0 ;;
  esac
  return 1
}

svc_install_args() {
  [[ -n "$WEBPASSWORD" ]] || WEBPASSWORD="$(generate_password)"
  SVC_INSTALL_ARGS=(--webpassword "$WEBPASSWORD")
}

svc_plan_lines() {
  if [[ -n "$WEBPASSWORD" ]]; then
    echo " Web password  : (as entered, hidden)"
  else
    echo " Web password  : (auto-generated, shown once after creation)"
  fi
}

svc_summary_lines() {
  echo " Admin UI      : http://${2}/admin"
  echo " Admin password: ${WEBPASSWORD}"
  echo " DNS server    : ${2}:53  (point your router/clients here)"
}

pvs_main "$@"
