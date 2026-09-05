#!/usr/bin/env bash
#
# floci-lxc.sh — Floci (free local AWS/Azure/GCP emulator) + Floci UI on
# Proxmox VE, create to teardown. Run this on a PVE host, as root.
#
#   create              Create a Debian LXC with Docker inside it, then run
#                       Floci (your chosen cloud platform's emulator) and
#                       Floci UI together via `docker compose`
#   update <ctid>       docker compose pull && docker compose up -d —
#                       backs up the persistent data volume first
#   uninstall <ctid>    docker compose down (--purge also removes the data
#                       volume and backups; Docker itself is left installed
#                       either way — this removes the Floci stack, not your
#                       container's whole Docker setup)
#   status <ctid>       Show container status and emulator/UI health
#
# Usage:
#   ./floci-lxc.sh create [options]
#   ./floci-lxc.sh update <ctid>
#   ./floci-lxc.sh uninstall <ctid> [--purge]
#   ./floci-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: floci)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 20 — see note below)
#   -c, --cores <n>        CPU cores (default: 2)
#   -m, --memory <MB>      RAM in MB (default: 2048)
#   --static <cidr>        Static IP, e.g. 192.168.1.60/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Root password (default: random, shown once after
#                           creation) — works for both `ssh root@<ip>` and
#                           `pct enter <ctid>` (the latter needs no password
#                           at all)
#   --platform <name>      Which cloud to emulate: aws (default), azure, or
#                           gcp. Floci UI supports these three — a 4th
#                           platform, floci-oci, exists but has no UI support
#                           yet, so it isn't offered here.
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# WHY 20GB, NOT THE 2GB OTHER SCRIPTS IN THIS PROJECT USE: Floci itself is
# small, but every AWS/Azure/GCP service backed by "real Docker" — RDS,
# ElastiCache, MSK, EKS, OpenSearch, and more — pulls a real image (Postgres,
# Redpanda, k3s, OpenSearch, each commonly 300MB-1GB+) the first time you use
# it, and those images accumulate on this container's own disk as you
# exercise more services. 20GB is comfortable for moderate use; pass a larger
# --disk up front if you already know you'll run several heavy services
# together, since growing an LXC's disk after creation is not a one-command
# operation the way it is on a VM.
#
# This needs internet access from the container to pull the Floci images (and
# every Docker-backed service's image, the first time you use that service) —
# unlike AdGuard Home or Pi-hole, this is not a "download once, run offline"
# service.
#
# WHAT THIS ACTUALLY INSTALLS: Docker (via get.docker.com — Debian only, no
# --os choice here, since Alpine's Docker path is entirely different and
# unverified for this), then `docker compose up` for your chosen platform's
# emulator plus Floci UI. The container needs nesting AND keyctl enabled to
# run Docker at all inside an LXC — this script turns both on for you, it is
# not something you configure.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="floci"
SERVICE_NAME="Floci"
# @tagline Free local AWS/Azure/GCP emulator with a web console

DEFAULT_HOSTNAME="floci"
DEFAULT_DISK_GB="20"
DEFAULT_CORES="2"
DEFAULT_MEMORY_MB="2048"
# Docker needs both, verified together on a real host (see CONTRIBUTING.md).
# Debian only: get.docker.com has no Alpine path, and Docker-in-LXC-on-Alpine
# is a wholly separate unverified question this project has not tested.
DEFAULT_NESTING="1"
DEFAULT_KEYCTL="1"

PLATFORM="aws"

# @usage
# @embed ct-lxc/floci/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Platform choices. A plain case, not a lookup table, for the same reason
# lib/pve.sh's OS helpers are one: bash 3.2 has no associative arrays. Every
# value here was verified for real — image pulled, container started,
# health-checked, and reached through Floci UI's own status probe — on a
# real arm64 host, not inferred from documentation alone.
# ---------------------------------------------------------------------------
platform_label() {
  case "$1" in
    aws)   printf 'AWS (Floci)' ;;
    azure) printf 'Azure (Floci-AZ)' ;;
    gcp)   printf 'GCP (Floci-GCP)' ;;
    *) printf '%s' "$1" ;;
  esac
}

platform_image() {
  case "$1" in
    aws)   printf 'floci/floci:latest' ;;
    azure) printf 'floci/floci-az:latest' ;;
    gcp)   printf 'floci/floci-gcp:latest' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

platform_service_name() {
  case "$1" in
    aws)   printf 'floci' ;;
    azure) printf 'floci-az' ;;
    gcp)   printf 'floci-gcp' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

platform_port() {
  case "$1" in
    aws)   printf '4566' ;;
    azure) printf '4577' ;;
    gcp)   printf '4588' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

# Confirmed by hand: AWS and Azure share the same health path, GCP does not.
platform_health_path() {
  case "$1" in
    aws|azure) printf '/_floci/health' ;;
    gcp)       printf '/_floci-gcp/health' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

# The env var Floci UI needs to find this platform's emulator by its compose
# service name instead of its own default of localhost (which would not
# resolve to anything from inside the UI's own container).
platform_endpoint_env() {
  case "$1" in
    aws)   printf 'FLOCI_ENDPOINT' ;;
    azure) printf 'FLOCI_AZURE_ENDPOINT' ;;
    gcp)   printf 'FLOCI_GCP_ENDPOINT' ;;
    *) die "unknown platform '${1}'" ;;
  esac
}

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_parse_option() {
  case "$1" in
    --platform)
      [[ -n "${2:-}" ]] || die "--platform needs a value (aws, azure or gcp)"
      case "$2" in
        aws|azure|gcp) ;;
        *) die "--platform must be one of: aws, azure, gcp (got '$2')" ;;
      esac
      PLATFORM="$2"; SVC_OPT_SHIFT=2; return 0 ;;
  esac
  return 1
}

svc_install_args() { SVC_INSTALL_ARGS=(--platform "$PLATFORM"); }

svc_prompt() {
  PLATFORM="$(ask_choice "Cloud platform to emulate" "$PLATFORM" "$(printf 'aws\nazure\ngcp')")"
}

svc_plan_lines() {
  echo " Platform      : $(platform_label "$PLATFORM")"
  echo " Disk note     : Docker images for services you use accumulate here"
}

svc_summary_lines() {
  local ip="$2" port
  port="$(platform_port "$PLATFORM")"
  echo " Console (UI)  : http://${ip}:4500"
  echo " Cloud API     : http://${ip}:${port} ($(platform_label "$PLATFORM"))"
  if [[ "$PLATFORM" == "aws" ]]; then
    echo " AWS creds     : any non-empty value works (e.g. test / test)"
  fi
}

pvs_main "$@"
