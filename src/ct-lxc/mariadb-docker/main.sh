#!/usr/bin/env bash
#
# mariadb-docker-lxc.sh — MariaDB via Docker on Proxmox VE, create to
# teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/mariadb-lxc.sh, which installs
# MariaDB natively from Debian's own repository. Same database, different
# packaging — pick this one for pull-based updates and the official image.
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official mariadb image
#   update <ctid>       mysqldump backup, `docker compose pull && up -d`,
#                       verify it's back up and answering — restores the
#                       dump and reports if not
#   uninstall <ctid>    Back up (unless --purge), `docker compose down`
#                       (--purge also removes the data and backups)
#   status <ctid>       Show container status and readiness
#
# Usage:
#   ./mariadb-docker-lxc.sh create [options]
#   ./mariadb-docker-lxc.sh update <ctid>
#   ./mariadb-docker-lxc.sh uninstall <ctid> [--purge]
#   ./mariadb-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: mariadb-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 1024)
#   --static <cidr>        Static IP, e.g. 192.168.1.55/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#   --dbpassword <pass>    Password for the database `root` account (default:
#                           random, shown once after creation, min 8
#                           characters)
#
# Same network trade-off as the native script: the container publishes 3306
# on all interfaces, reachable from your LAN with the printed password.
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has no
# Alpine path. This needs internet access from the container to pull the
# image, and again on every `update`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="mariadb-docker"
SERVICE_NAME="MariaDB (Docker)"
# @tagline MariaDB via the official Docker image

DEFAULT_HOSTNAME="mariadb-docker"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

DBPASSWORD=""

# @usage
# @embed ct-lxc/mariadb-docker/manage.sh AS manage_script
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
  echo " Connect       : mariadb -h ${2} -u root -p"
  echo " DB password   : ${DBPASSWORD}"
  echo " Port          : ${2}:3306"
}

pvs_main "$@"
