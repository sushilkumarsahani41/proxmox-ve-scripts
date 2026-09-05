#!/usr/bin/env bash
#
# mongodb-lxc.sh — MongoDB on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
# MongoDB's own apt repository (repo.mongodb.org) is checked directly, not
# assumed from its docs: for MongoDB 8.0, `mongodb-org-server` is only
# actually published for Debian 12 "bookworm" on amd64 — Debian 13's suite
# and every arm64 build under either suite carry nothing but the mongosh
# shell client, no server package at all. This script follows that
# constraint rather than fighting it: it pins Debian 12 (not this project's
# usual "newest Debian" auto-detection) and refuses outright on arm64 with a
# clear error, pointing at mongodb-docker-lxc.sh instead — the official
# `mongo` Docker image is genuinely multi-arch and has no such limit.
#
# Because of that, this script has not been verified end-to-end on real
# hardware the way every other script in this project has — this project's
# own test host is an arm64 Raspberry Pi, which this script refuses to run
# on by design. It has been built and syntax-checked against the same
# rigor as everything else here, but the actual install has not been
# confirmed against a live amd64 Proxmox host. Verify it for real before
# relying on it, and please report back if something's off.
#
#   create              Create a Debian 12 LXC (amd64 only) and install
#                       MongoDB from MongoDB's own apt repository
#   update <ctid>       mongodump backup, apt upgrade, verify it's back up
#                       and answering — restores the dump and reports if not
#   uninstall <ctid>    Remove MongoDB (apt remove, data/config kept on
#                       disk). --purge also drops the data directory, apt
#                       source, and backups
#   status <ctid>       Show version, service state, listening port
#
# Usage:
#   ./mongodb-lxc.sh create [options]
#   ./mongodb-lxc.sh update <ctid>
#   ./mongodb-lxc.sh uninstall <ctid> [--purge]
#   ./mongodb-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: mongodb)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 1024)
#   --static <cidr>        Static IP, e.g. 192.168.1.58/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#   --dbpassword <pass>    Password for the `root` database user (default:
#                           random, shown once after creation, min 8
#                           characters)
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# Same network trade-off as every database script here: the container
# publishes 27017 on all interfaces, reachable from your LAN with the
# printed password — not something to expose directly to the internet.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="mongodb"
SERVICE_NAME="MongoDB"
# @tagline The document database (Debian 12 + amd64 only)

DEFAULT_HOSTNAME="mongodb"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="1024"
DEFAULT_PREFER_STATIC="y"
# Pinned, not this project's usual "newest Debian" default — MongoDB's own
# apt repo has no server package for Debian 13 at all (see the header above).
DEFAULT_OS="debian12"

DBPASSWORD=""

# @usage
# @embed ct-lxc/mongodb/manage.sh AS manage_script
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
  echo " Connect       : mongosh \"mongodb://root:<password>@${2}:27017\""
  echo " DB password   : ${DBPASSWORD}"
  echo " Port          : ${2}:27017"
}

pvs_main "$@"
