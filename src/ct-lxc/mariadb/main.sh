#!/usr/bin/env bash
#
# mariadb-lxc.sh — MariaDB on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian LXC and install MariaDB from
#                       Debian's own repository
#   update <ctid>       mysqldump backup, apt upgrade, verify it's back up
#                       and answering — restores the dump and reports if not
#   uninstall <ctid>    Remove MariaDB (apt remove, data/config kept on
#                       disk). --purge also drops the data directory and
#                       backups
#   status <ctid>       Show version, service state, listening port
#
# Usage:
#   ./mariadb-lxc.sh create [options]
#   ./mariadb-lxc.sh update <ctid>
#   ./mariadb-lxc.sh uninstall <ctid> [--purge]
#   ./mariadb-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: mariadb)
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
#                           characters — separate from --password above)
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# Debian's own package defaults database root to `unix_socket` auth (no
# password, but only from the system's own root account) and binds to
# 127.0.0.1 only. This script changes both: `root`@`localhost` and a new
# `root`@`%` both get the generated password, and the server binds to all
# interfaces — so this database is reachable from your LAN with the printed
# password, the whole point of a database you can actually connect a client
# to. That is a real trade-off, not a hardening default: don't expose this
# container directly to the internet.
#
# Debian only — Alpine's own mariadb package exists but has not been
# verified against this script.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="mariadb"
SERVICE_NAME="MariaDB"
# @tagline The community-developed fork of MySQL

DEFAULT_HOSTNAME="mariadb"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"

DBPASSWORD=""

# @usage
# @embed ct-lxc/mariadb/manage.sh AS manage_script
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
