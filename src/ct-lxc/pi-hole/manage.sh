#!/usr/bin/env bash
# In-container management for Pi-hole. Pushed to /usr/local/sbin/pi-hole-
# manage.sh and re-pushed on every command, so the container always matches
# the host script's version.
#
# Delegates everything it reasonably can to Pi-hole's own tooling — the
# vendor installer for install/update, `pihole uninstall` for removal,
# `pihole status`/`-v` for state — the same principle as every other service
# in this project: don't reimplement what upstream already maintains.
set -Eeuo pipefail

# @include lib/agent-ui.sh

PIHOLE_BIN="/usr/local/bin/pihole"
BACKUP_ROOT="/var/backups/pihole"
VENDOR_INSTALL_URL="https://install.pi-hole.net"
DNS1="1.1.1.1"
DNS2="1.0.0.1"
WEBPASSWORD=""
PURGE=0

is_installed() { [[ -x "$PIHOLE_BIN" ]]; }
# Separate from is_installed, same reasoning as AdGuard Home's manage.sh: a
# plain `uninstall` leaves the config backup behind (Pi-hole's own
# uninstaller wipes /etc/pihole itself, this project's backup is what
# actually keeps it — see cmd_uninstall), so "uninstall, then decide to
# purge after all" must not be refused for having no binary left to check.
has_data() { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; }

pihole_version() { "$PIHOLE_BIN" -v 2>&1 | sed -n 's/^Core version is //p' | awk '{print $1}'; }

# Pi-hole's own installer requires bash (uses arrays, mapfile) even though it
# runs fine on Alpine, whose base image has neither bash nor curl — but by
# the time this script runs, the host's OS bootstrap (see lib/pve.sh) has
# already guaranteed both exist, so this just needs curl for the download.
run_vendor_installer() {
  local tmp_script rc=0
  tmp_script="$(mktemp)"
  if curl -fsSL "$VENDOR_INSTALL_URL" -o "$tmp_script"; then
    PIHOLE_SKIP_OS_CHECK=true bash "$tmp_script" "$@" || rc=$?
  else
    rc=1
  fi
  rm -f "$tmp_script"
  return "$rc"
}

# Pi-hole's fresh-install wizard is a sequence of whiptail dialogs with no
# flag to skip them — `--unattended` alone only silences apt's own prompts.
# The documented way around this (confirmed against the real installer
# source, not assumed) is to seed a legacy setupVars.conf before running it:
# the installer's very first check is whether a config already exists, and
# if it does, it treats the run as an update/migration instead of a fresh
# install and skips every dialog, migrating these values into Pi-hole v6's
# own pihole.toml itself.
seed_setup_vars() {
  local ip_cidr
  # container_ip() (lib/agent-ui.sh) deliberately strips the prefix length for
  # URLs — Pi-hole's setupVars.conf wants the real one back, not a hardcoded
  # guess: this container could be on a /16 or anything else the LAN uses.
  ip_cidr="$(ip -4 addr show eth0 2>/dev/null | grep -oE 'inet [0-9./]+' | cut -d' ' -f2)"
  mkdir -p /etc/pihole
  cat > /etc/pihole/setupVars.conf <<EOF
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=${ip_cidr}
PIHOLE_DNS_1=${DNS1}
PIHOLE_DNS_2=${DNS2}
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=all
BLOCKING_ENABLED=true
WEBUIBOXEDLAYOUT=boxed
REV_SERVER=false
EOF
}

backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d /etc/pihole ]] && cp -a /etc/pihole "${backup_dir}/pihole"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/pihole" ]] || return 0
  rm -rf /etc/pihole
  cp -a "${backup_dir}/pihole" /etc/pihole
}

# Checks FTL specifically, not "blocking enabled" — a container with
# blocking deliberately switched off by the user is still a running,
# healthy Pi-hole, and must not read as broken.
service_is_running() { "$PIHOLE_BIN" status 2>&1 | grep -q "FTL is listening"; }

blocking_state() {
  if "$PIHOLE_BIN" status 2>&1 | grep -q "blocking is enabled"; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

wait_for_service() {
  local tries=15
  while (( tries > 0 )); do
    service_is_running && return 0
    sleep 1
    tries=$(( tries - 1 ))
  done
  return 1
}

print_access_info() {
  echo
  ok "Pi-hole admin UI: http://$(container_ip)/admin"
}

cmd_install() {
  require_root
  ensure_pkg curl
  is_installed && die "Pi-hole is already installed — use 'update' instead"

  seed_setup_vars
  run_vendor_installer --unattended || die "Pi-hole installer failed — see /etc/pihole/install.log"

  is_installed || die "installer reported success but ${PIHOLE_BIN} is missing"

  # The vendor installer starts pihole-FTL *before* it finishes building and
  # atomically swapping in the real gravity database (its own log literally
  # says "Restarting pihole-FTL service" first, then "Creating new gravity
  # database" / "Swapping databases" afterward). FTL keeps its database
  # connection open across that swap, which leaves it holding a stale
  # reference to the pre-swap file — confirmed on a real container, where
  # every domainlist/adlist write failed with "attempt to write a readonly
  # database" until FTL was restarted. `pihole reloaddns`/`reloadlists`
  # explicitly do not restart the process, so only a real restart clears it.
  restart_service pihole-FTL
  wait_for_service || die "pihole-FTL did not come back up after the post-install restart"

  "$PIHOLE_BIN" setpassword "$WEBPASSWORD" >/dev/null 2>&1 \
    || warn "Pi-hole installed, but setting the admin password failed — set one with: pihole setpassword"

  ok "Pi-hole installed"
  print_access_info
}

# Delegates the actual upgrade to `pihole -up` — Pi-hole's own update path,
# which touches system packages (apt/apk) across several components (FTL,
# the web interface, core scripts), not one file this project could swap
# back on failure the way AdGuard Home's single static binary allows. So the
# safety net here is narrower and honestly described: /etc/pihole (config,
# gravity database, custom lists) is backed up and restored if anything
# looks wrong afterward, but there is no undo for the software packages
# themselves — `pihole -up` is Pi-hole's own maintained upgrade path, and
# trusted the same way this project trusts every other vendor installer.
cmd_update() {
  require_root
  is_installed || die "Pi-hole is not installed — use 'install' instead"

  local old_version backup_dir
  old_version="$(pihole_version)"
  info "current version: ${old_version}"

  backup_dir="$(backup_state)"
  ok "backed up /etc/pihole to ${backup_dir}"

  if ! "$PIHOLE_BIN" -up; then
    warn "pihole -up reported failure — restoring config from backup"
    restore_state "$backup_dir"
    die "update failed, config restored from ${backup_dir} — packages may still be partially updated; consider 'pihole -r' (repair) or checking /etc/pihole/install.log"
  fi

  # Same reasoning as cmd_install's restart: an actual version bump runs
  # through gravity-touching steps again internally, and FTL keeping a
  # database connection open across that is what causes the stale-reference
  # bug documented there — `service_is_running` below only checks that FTL
  # is listening for DNS, which stays true even when writes are broken, so a
  # restart here is what actually closes the gap rather than the check that
  # follows it.
  restart_service pihole-FTL

  if ! wait_for_service; then
    warn "FTL did not come back up after update — restoring config from backup"
    restore_state "$backup_dir"
    die "update failed, config restored from ${backup_dir} — packages were updated by 'pihole -up' itself and are not rolled back; consider 'pihole -r' (repair)"
  fi

  local new_version
  new_version="$(pihole_version)"
  ok "updated: ${old_version} -> ${new_version}"
  print_access_info
}

# Pi-hole's own uninstaller always deletes /etc/pihole outright — there is no
# upstream flag for "remove the software but keep my config", the way
# AdGuard Home's uninstall naturally leaves its install directory alone. So
# without --purge, this project backs /etc/pihole up *before* calling it,
# which is what actually delivers on "keep config/data" here.
cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Pi-hole is not installed and there is no backed-up config to remove"
  fi

  if is_installed; then
    local backup_dir="" log rc=0
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    log="$(mktemp)"
    printf 'y\ny\n' | "$PIHOLE_BIN" uninstall >"$log" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      sed 's/^/    /' "$log" >&2
      rm -f "$log"
      die "pihole uninstall reported failure (exit ${rc})${backup_dir:+ — config was still backed up to ${backup_dir}}"
    fi
    rm -f "$log"
    if [[ -n "$backup_dir" ]]; then
      ok "Pi-hole removed, config/gravity database kept at ${backup_dir}"
    else
      ok "Pi-hole removed"
    fi
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$BACKUP_ROOT"
    ok "all backed-up config removed"
  fi
}

cmd_status() {
  is_installed || die "Pi-hole is not installed"
  echo "version:  $(pihole_version)"
  echo "service:  $(service_is_running && echo running || echo stopped)"
  echo "blocking: $(blocking_state)"
  echo "address:  http://$(container_ip)/admin"
  if command -v ss >/dev/null 2>&1; then
    echo "ports:"
    ss -ltunp 2>/dev/null | awk 'NR==1 || /:(53|80|443) /' | sed 's/^/  /' || true
  fi
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
      --dns1) DNS1="$2"; shift 2 ;;
      --dns2) DNS2="$2"; shift 2 ;;
      --webpassword) WEBPASSWORD="$2"; shift 2 ;;
      --purge) PURGE=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$cmd" in
    install) cmd_install ;;
    update) cmd_update ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
