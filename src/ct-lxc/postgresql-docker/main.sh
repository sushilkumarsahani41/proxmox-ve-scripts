#!/usr/bin/env bash
#
# postgresql-docker-lxc.sh — PostgreSQL via Docker on Proxmox VE, create to
# teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/postgresql-lxc.sh, which installs
# PostgreSQL natively from Debian's own repository. Same database, different
# packaging — pick this one for pull-based updates and the official image.
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official postgres image
#   update <ctid>       pg_dumpall backup, `docker compose pull && up -d`,
#                       verify it's back up and answering — restores the
#                       dump and reports if not
#   uninstall <ctid>    Back up (unless --purge), `docker compose down`
#                       (--purge also removes the data and backups)
#   status <ctid>       Show container status and readiness
#
# Usage:
#   ./postgresql-docker-lxc.sh create [options]
#   ./postgresql-docker-lxc.sh update <ctid>
#   ./postgresql-docker-lxc.sh uninstall <ctid> [--purge]
#   ./postgresql-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: postgresql-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 1024)
#   --static <cidr>        Static IP, e.g. 192.168.1.54/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#   --dbpassword <pass>    Password for the `postgres` role (default: random,
#                           shown once after creation, min 8 characters)
#
# Same network trade-off as the native script: the container publishes 5432
# on all interfaces, reachable from your LAN with the printed password — not
# something to expose directly to the internet.
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has no
# Alpine path. This needs internet access from the container to pull the
# image, and again on every `update`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="postgresql-docker"
SERVICE_NAME="PostgreSQL (Docker)"
# @tagline PostgreSQL via the official Docker image

DEFAULT_HOSTNAME="postgresql-docker"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

DBPASSWORD=""

# @usage
# @embed ct-lxc/postgresql-docker/manage.sh AS manage_script
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
  echo " Connect       : psql -h ${2} -U postgres"
  echo " DB password   : ${DBPASSWORD}"
  echo " Port          : ${2}:5432"
}

pvs_main "$@"
