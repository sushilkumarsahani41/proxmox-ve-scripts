#!/usr/bin/env bash
#
# valkey-lxc.sh — Valkey on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
# Valkey is the Redis-protocol-compatible in-memory store that Debian itself
# now ships (Debian 13 dropped Redis from its archive over its 2024 license
# change and defaults to Valkey instead — same wire protocol, same commands,
# same RDB/AOF file formats, a different name). If something says "just
# needs Redis", this is it.
#
#   create              Create a Debian LXC and install Valkey from Debian's
#                       own repository
#   update <ctid>       RDB snapshot backup, apt upgrade, verify it's back
#                       up and answering — restores the snapshot and reports
#                       if not
#   uninstall <ctid>    Remove Valkey (apt remove, data/config kept on
#                       disk). --purge also drops the data directory and
#                       backups
#   status <ctid>       Show version, service state, listening port
#
# Usage:
#   ./valkey-lxc.sh create [options]
#   ./valkey-lxc.sh update <ctid>
#   ./valkey-lxc.sh uninstall <ctid> [--purge]
#   ./valkey-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: valkey)
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
#                           once after creation, min 8 characters — separate
#                           from --password above)
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# Debian's own package binds to 127.0.0.1 only and ships with no password —
# this script binds to all interfaces and sets `requirepass` instead, so
# this is a database you can actually connect a client to from your LAN, not
# just from inside the container. That is a real trade-off, not a hardening
# default: don't expose this container directly to the internet.
#
# Debian only — Alpine's own valkey/redis package exists but has not been
# verified against this script.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="valkey"
SERVICE_NAME="Valkey"
# @tagline Redis-protocol-compatible in-memory data store

DEFAULT_HOSTNAME="valkey"
DEFAULT_DISK_GB="2"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"
DEFAULT_PREFER_STATIC="y"

DBPASSWORD=""

# @usage
# @embed ct-lxc/valkey/manage.sh AS manage_script
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
