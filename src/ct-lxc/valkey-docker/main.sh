#!/usr/bin/env bash
#
# valkey-docker-lxc.sh — Valkey via Docker on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/valkey-lxc.sh, which installs
# Valkey natively from Debian's own repository. Same database, different
# packaging — pick this one for pull-based updates and the official image.
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official valkey/valkey image
#   update <ctid>       RDB snapshot backup, `docker compose pull && up -d`,
#                       verify it's back up and answering — restores the
#                       snapshot and reports if not
#   uninstall <ctid>    Back up (unless --purge), `docker compose down`
#                       (--purge also removes the data and backups)
#   status <ctid>       Show container status and readiness
#
# Usage:
#   ./valkey-docker-lxc.sh create [options]
#   ./valkey-docker-lxc.sh update <ctid>
#   ./valkey-docker-lxc.sh uninstall <ctid> [--purge]
#   ./valkey-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: valkey-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 2)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 512)
#   --static <cidr>        Static IP, e.g. 192.168.1.56/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#   --dbpassword <pass>    Valkey's `requirepass` (default: random, shown
#                           once after creation, min 8 characters)
#
# Same network trade-off as the native script: the container publishes 6379
# on all interfaces, reachable from your LAN with the printed password.
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has no
# Alpine path. This needs internet access from the container to pull the
# image, and again on every `update`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="valkey-docker"
SERVICE_NAME="Valkey (Docker)"
# @tagline Valkey via the official Docker image

DEFAULT_HOSTNAME="valkey-docker"
DEFAULT_DISK_GB="2"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"
DEFAULT_PREFER_STATIC="y"
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

DBPASSWORD=""

# @usage
# @embed ct-lxc/valkey-docker/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_parse_option() {
  case "$1" in
    --dbpassword)
      [[ -n "${2:-}" ]] || die "--dbpassword needs a value"
      v_password "$2" || die "--dbpassword must be at least 8 characters"
      DBPASSWORD="$2"; SVC_OPT_SHIFT=2; return 0 ;;
  esac
  return 1
}

svc_install_args() {
  [[ -n "$DBPASSWORD" ]] || DBPASSWORD="$(generate_password)"
  SVC_INSTALL_ARGS=(--dbpassword "$DBPASSWORD")
}

svc_plan_lines() {
  if [[ -n "$DBPASSWORD" ]]; then
    echo " DB password   : (as entered, hidden)"
  else
    echo " DB password   : (auto-generated, shown once after creation)"
  fi
}

svc_summary_lines() {
  echo " Connect       : valkey-cli -h ${2} -a '<password>'"
  echo " DB password   : ${DBPASSWORD}"
  echo " Port          : ${2}:6379"
}

pvs_main "$@"
