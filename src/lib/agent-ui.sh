#!/usr/bin/env bash
# lib/agent-ui.sh — the small preamble every in-container management script
# needs. Kept separate from lib/ui.sh because this half runs inside the
# container (no spinner, no banner, no Proxmox anything) and gets embedded
# into the host script as a string, not executed alongside it.

if [[ -t 1 ]]; then
  C_INFO="\033[36m"; C_OK="\033[32m"; C_ERR="\033[31m"; C_WARN="\033[33m"; C_RESET="\033[0m"
else
  C_INFO=""; C_OK=""; C_ERR=""; C_WARN=""; C_RESET=""
fi
info() { printf "%b[*]%b %s\n" "$C_INFO" "$C_RESET" "$1" >&2; }
ok()   { printf "%b[+]%b %s\n" "$C_OK" "$C_RESET" "$1" >&2; }
warn() { printf "%b[!]%b %s\n" "$C_WARN" "$C_RESET" "$1" >&2; }
# `trap - ERR` first: die() is a deliberate exit, and without this the ERR
# trap fires on the way out and prints a second, useless "failed at line N"
# underneath the real explanation.
die()  { printf "%b[x]%b %s\n" "$C_ERR" "$C_RESET" "$1" >&2; trap - ERR; exit 1; }

trap 'die "failed at line $LINENO (exit code $?)"' ERR

require_root() { [[ "$(id -u)" -eq 0 ]] || die "must be run as root"; }

# apk (Alpine) or apt-get (Debian) — whichever is actually on this container,
# not whichever OS a service author assumed. Package *names* can still differ
# between the two (this only saves you from the manager itself), so a service
# that needs something Debian calls `sqlite3` and Alpine calls `sqlite` still
# has to know that.
ensure_pkg() {
  local missing=() pkg
  for pkg in "$@"; do
    command -v "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk update -q
    apk add -q "${missing[@]}"
  else
    die "missing: ${missing[*]} (no apt-get or apk available to install them)"
  fi
}

# `hostname -I` is a GNU-ism; busybox's hostname applet (Alpine) does not
# support it. `ip addr show` is implemented identically by busybox and
# iproute2, so parse that instead of branching per OS.
container_ip() { ip -4 addr show eth0 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2; }
