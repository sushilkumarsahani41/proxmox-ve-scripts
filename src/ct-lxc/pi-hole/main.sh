#!/usr/bin/env bash
#
# pi-hole-lxc.sh — Pi-hole on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create an LXC (Debian by default, or Alpine with
#                       --os alpine — newest template the host has or can
#                       fetch, matching its own architecture: amd64 or
#                       arm64) and install Pi-hole inside it
#   update <ctid>       Update Pi-hole on an existing container: backs up
#                       /etc/pihole first, then delegates to `pihole -up`
#                       (Pi-hole's own update path — this project does not
#                       reimplement it). If FTL isn't running afterward, the
#                       config backup is restored and you're told to check
#                       it; there is no binary-level rollback, since `pihole
#                       -up` touches system packages, not one swappable file
#   uninstall <ctid>    Remove Pi-hole. Pi-hole's own uninstaller always
#                       wipes /etc/pihole — there is no "keep config"
#                       option upstream — so without --purge this backs it
#                       up first and tells you where; --purge skips that
#   status <ctid>       Show version, FTL/blocking state, listening ports
#
# Usage:
#   ./pi-hole-lxc.sh create [options]
#   ./pi-hole-lxc.sh update <ctid>
#   ./pi-hole-lxc.sh uninstall <ctid> [--purge]
#   ./pi-hole-lxc.sh status <ctid>
#
# create options:
#   -y, --defaults         Skip the questions and use the recommended values
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: pihole)
#   --os <name>             debian (default) or alpine — both verified
#                           against Pi-hole's own installer on a real arm64
#                           container; Debian has the wider package
#                           ecosystem if you ever exec in and debug
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 2)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 512)
#   --static <cidr>        Static IP, e.g. 192.168.1.53/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --password <pass>      Container root password (default: random, shown
#                           once after creation) — works for both
#                           `ssh root@<ip>` and `pct enter <ctid>` (the
#                           latter needs no password at all)
#   --upstream <name>      Upstream DNS: cloudflare (default), google,
#                           quad9, or opendns
#   --webpassword <pass>   Pi-hole admin web UI password (default: random,
#                           shown once after creation, min 8 characters —
#                           this is separate from --password above, which is
#                           the container's own root login)
#
# Run with no options on a terminal and it asks about each setting, showing
# the recommended value in brackets — Enter accepts it. Pass any option (or
# -y) and it runs straight through without asking, so scripts stay
# predictable.
#
# A DNS server wants a fixed address: a static IP is strongly recommended,
# since every client on the LAN will be pointed at this container's IP.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="pi-hole"
SERVICE_NAME="Pi-hole"
# @tagline The original network-wide DNS ad blocker

DEFAULT_HOSTNAME="pihole"
DEFAULT_DISK_GB="2"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"
# A DNS server wants a fixed address for the same reason AdGuard Home does.
DEFAULT_PREFER_STATIC="y"
# Pi-hole v6's own installer supports apk natively (Alpine's "community"
# repo, registers under OpenRC) — verified on a real arm64 container, the
# same as AdGuard Home, and for the same reason: manage.sh below delegates
# to Pi-hole's own installer/updater/uninstaller rather than reimplementing
# service management, so it needed zero OS-specific code either.
DEFAULT_OS="debian"
DEFAULT_OS_CHOICES="debian alpine"

UPSTREAM="cloudflare"
WEBPASSWORD=""

# @usage
# @embed ct-lxc/pi-hole/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/prompt.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Upstream DNS choices. A plain case, not a lookup table, for the same
# reason lib/pve.sh's OS helpers are one: bash 3.2 has no associative arrays.
# ---------------------------------------------------------------------------
upstream_label() {
  case "$1" in
    cloudflare) printf 'Cloudflare (1.1.1.1)' ;;
    google)     printf 'Google (8.8.8.8)' ;;
    quad9)      printf 'Quad9 (9.9.9.9)' ;;
    opendns)    printf 'OpenDNS (208.67.222.222)' ;;
    *) printf '%s' "$1" ;;
  esac
}

upstream_ips() {
  case "$1" in
    cloudflare) printf '1.1.1.1 1.0.0.1' ;;
    google)     printf '8.8.8.8 8.8.4.4' ;;
    quad9)      printf '9.9.9.9 149.112.112.112' ;;
    opendns)    printf '208.67.222.222 208.67.220.220' ;;
    *) die "unknown upstream '${1}'" ;;
  esac
}

# ---------------------------------------------------------------------------
# Service hooks
# ---------------------------------------------------------------------------
svc_parse_option() {
  case "$1" in
    --upstream)
      [[ -n "${2:-}" ]] || die "--upstream needs a value (cloudflare, google, quad9 or opendns)"
      case "$2" in
        cloudflare|google|quad9|opendns) ;;
        *) die "--upstream must be one of: cloudflare, google, quad9, opendns (got '$2')" ;;
      esac
      UPSTREAM="$2"; SVC_OPT_SHIFT=2; return 0 ;;
    --webpassword)
      [[ -n "${2:-}" ]] || die "--webpassword needs a value"
      v_password "$2" || die "--webpassword must be at least 8 characters"
      WEBPASSWORD="$2"; SVC_OPT_SHIFT=2; return 0 ;;
  esac
  return 1
}

# Generated here, not up front with ROOT_PASSWORD in lib/main.sh: this is a
# Pi-hole-specific credential (the web admin login), not something every
# service has, so it stays entirely inside this file rather than growing the
# shared library for one service's needs. Timing matches ROOT_PASSWORD's own
# lazy-generate — resolved once, right before install, after the wizard (if
# any) has had its say.
svc_install_args() {
  [[ -n "$WEBPASSWORD" ]] || WEBPASSWORD="$(generate_password)"
  # Resolved to actual IPs here, not passed as the raw "cloudflare" id: the
  # upstream_ips lookup above is defined in this host-side file and is not
  # part of what @embed inlines into manage.sh, so manage.sh never sees it —
  # passing IPs across that boundary avoids needing the same table twice.
  local ips
  ips="$(upstream_ips "$UPSTREAM")"
  SVC_INSTALL_ARGS=(--dns1 "${ips%% *}" --dns2 "${ips##* }" --webpassword "$WEBPASSWORD")
}

svc_prompt() {
  UPSTREAM="$(ask_choice "Upstream DNS provider" "$UPSTREAM" "$(printf 'cloudflare\ngoogle\nquad9\nopendns')")"
}

svc_plan_lines() {
  echo " Upstream DNS  : $(upstream_label "$UPSTREAM")"
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
