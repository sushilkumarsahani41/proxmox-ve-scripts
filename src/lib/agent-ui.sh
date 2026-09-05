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

# Restarts a service under whichever init system this container has —
# systemd on Debian, OpenRC on Alpine. This is the one place a service is
# expected to reach past its own vendor CLI into the init system directly:
# neither AdGuard Home's `-s` flag nor Pi-hole's `pihole` exposes a portable
# "restart my daemon" (Pi-hole's `reloaddns`/`reloadlists` explicitly do NOT
# restart the process — see cmd_install in pi-hole/manage.sh for why a real
# restart, not a reload, is what a fresh install actually needs).
restart_service() {
  local name="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$name"
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$name" restart
  else
    die "no systemctl or rc-service available to restart ${name}"
  fi
}

# Docker itself, for any service that ships as a container image rather than
# a native installer. get.docker.com (upstream Docker's own installer) has no
# Alpine path, so every Docker-based service in this project is Debian-only —
# same reasoning, and the same install step, first used for Floci. Shared
# here rather than duplicated per service.
ensure_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  info "installing Docker"
  local tmp_script
  tmp_script="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$tmp_script" || { rm -f "$tmp_script"; die "failed to download Docker's installer"; }
  sh "$tmp_script" >/dev/null 2>&1 || { rm -f "$tmp_script"; die "Docker installation failed"; }
  rm -f "$tmp_script"
  systemctl enable --now docker >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 || die "Docker installer finished but 'docker' is still not on PATH"
}
