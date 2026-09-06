#!/usr/bin/env bash
#
# plex-docker-lxc.sh — Plex Media Server via Docker on Proxmox VE, create to
# teardown. Run this on a PVE host, as root.
#
# This is the Docker counterpart to ct-lxc/plex-lxc.sh, which installs Plex
# natively via its own official apt repository. Same service, different
# packaging — pick this one for pull-based updates and the official image.
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       the official plexinc/pms-docker image
#   update <ctid>       Back up Plex's config directory, then
#                       `docker compose pull && up -d` — restores the
#                       backup and reports if the server doesn't come back
#   uninstall <ctid>    `docker compose down` (--purge also removes the
#                       config/transcode directories and backups — your
#                       media directory is never touched, purge or not,
#                       see below)
#   status <ctid>       Show container status and whether Plex answers
#
# Usage:
#   ./plex-docker-lxc.sh create [options]
#   ./plex-docker-lxc.sh update <ctid>
#   ./plex-docker-lxc.sh uninstall <ctid> [--purge]
#   ./plex-docker-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: plex-docker)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 8 — for Plex's own
#                           config/transcode cache; point your media
#                           library at separately attached storage)
#   -c, --cores <n>        CPU cores (default: 2)
#   -m, --memory <MB>      RAM in MB (default: 2048)
#   --static <cidr>        Static IP, e.g. 192.168.1.60/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation)
#   --claim <token>        A claim token from https://plex.tv/claim — Plex's
#                           own PLEX_CLAIM mechanism, automatically signs the
#                           new server in to your plex.tv account on first
#                           boot. These expire ~4 minutes after being
#                           generated and are single-use, so fetch one and
#                           run this command immediately after — not worth
#                           the wizard asking for interactively, since
#                           answering the rest of the questions would very
#                           likely burn through the window first. Omit it
#                           and sign in through the web UI afterward instead
#                           (same as the native script, and same as Jellyfin).
#
# Media lives at /opt/plex-docker/media inside the container, bind-mounted
# into the container at /data — copy files in via `pct push`/`pct enter`, or
# replace it with a mount point to real storage after create (`pct set <ctid>
# -mp0 /host/path,mp=/opt/plex-docker/media`). Uninstall (with or without
# --purge) never deletes this directory — only Plex's own config/transcode
# directories are ever removed, since media is *your* data, not Plex's.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# Debian only, no --os choice: get.docker.com (Docker's own installer) has no
# Alpine path. This needs internet access from the container to pull the
# image, and again on every `update`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="plex-docker"
SERVICE_NAME="Plex (Docker)"
# @tagline Plex via the official Docker image

DEFAULT_HOSTNAME="plex-docker"
DEFAULT_DISK_GB="8"
DEFAULT_CORES="2"
DEFAULT_MEMORY_MB="2048"
DEFAULT_PREFER_STATIC="y"
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

CLAIM_TOKEN=""

# @usage
# @embed ct-lxc/plex-docker/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_parse_option() {
  case "$1" in
    --claim)
      [[ -n "${2:-}" ]] || die "--claim needs a value — get one from https://plex.tv/claim (valid ~4 minutes)"
      CLAIM_TOKEN="$2"; SVC_OPT_SHIFT=2; return 0 ;;
  esac
  return 1
}

# Deliberately no svc_prompt for this: a claim token is single-use and
# expires ~4 minutes after being generated, and getting through the rest of
# the interactive wizard (storage, network, static IP...) before the
# container is even created could easily burn through that window. Only
# offered as a --claim flag, for someone who fetched one and is running this
# command right now — not as a wizard question with an unpredictable delay
# between "answered" and "actually used".
svc_install_args() {
  if [[ -n "$CLAIM_TOKEN" ]]; then
    SVC_INSTALL_ARGS=(--claim "$CLAIM_TOKEN")
  else
    SVC_INSTALL_ARGS=()
  fi
}

svc_plan_lines() {
  if [[ -n "$CLAIM_TOKEN" ]]; then
    echo " Claim token   : provided — will attempt to claim automatically"
  fi
  return 0
}

svc_summary_lines() {
  echo " Setup & sign-in: http://${2}:32400/web"
  echo " Media folder   : /opt/plex-docker/media inside the container"
}

pvs_main "$@"
