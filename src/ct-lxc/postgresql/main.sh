#!/usr/bin/env bash
#
# postgresql-lxc.sh — PostgreSQL on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian LXC and install PostgreSQL from
#                       Debian's own repository (no third-party apt repo
#                       needed — Debian 13 ships PostgreSQL 17 directly)
#   update <ctid>       pg_dumpall backup, apt upgrade, verify it's back up
#                       and answering — restores the dump and reports if not
#   uninstall <ctid>    Remove PostgreSQL (apt remove, data/config kept on
#                       disk). --purge also drops the cluster and backups
#   status <ctid>       Show version, service state, listening port
#
# Usage:
#   ./postgresql-lxc.sh create [options]
#   ./postgresql-lxc.sh update <ctid>
#   ./postgresql-lxc.sh uninstall <ctid> [--purge]
#   ./postgresql-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: postgresql)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 1024)
#   --static <cidr>        Static IP, e.g. 192.168.1.54/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation) — works for both
#                           `ssh root@<ip>` and `pct enter <ctid>` (the
#                           latter needs no password at all)
#   --dbpassword <pass>    Password for the `postgres` role (default: random,
#                           shown once after creation, min 8 characters —
#                           separate from --password above)
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# The `postgres` role is opened up for password auth over the network
# (listen_addresses='*', a pg_hba.conf line for 0.0.0.0/0 with
# scram-sha-256) — this project's whole point is a database you can actually
# connect to from another machine on your LAN, not just from inside the
# container. That is a real trade-off, not a hardening default: don't expose
# this container directly to the internet. Local access (`pct exec`/`pct
# enter`) never needed a password to begin with — Postgres's own default
# `peer` auth for the Unix socket already covers that, untouched by any of
# this.
#
# Debian only — Alpine's own postgresql package exists but has not been
# verified against this script.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="postgresql"
SERVICE_NAME="PostgreSQL"
# @tagline The advanced open-source relational database

DEFAULT_HOSTNAME="postgresql"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"

DBPASSWORD=""

# @usage
# @embed ct-lxc/postgresql/manage.sh AS manage_script
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
