#!/usr/bin/env bash
# In-container management for Tailscale. Pushed to
# /usr/local/sbin/tailscale-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Delegates entirely to Tailscale's own official install script
# (tailscale.com/install.sh), which adds Tailscale's apt repo and installs
# the real tailscale/tailscaled packages — this project doesn't reimplement
# any of that.
set -Eeuo pipefail

# @include lib/agent-ui.sh

DATA_DIR="/var/lib/tailscale"
BACKUP_ROOT="/var/backups/tailscale-lxc"
INSTALLER_URL="https://tailscale.com/install.sh"
AUTH_KEY=""
PURGE=0

is_installed() { dpkg-query -W -f='${Status}' tailscale 2>/dev/null | grep -q '^install ok installed'; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; }
}

service_healthy() { systemctl is-active --quiet tailscaled; }

wait_for_service() {
  local tries=15
  while (( tries > 0 )); do
    service_healthy && return 0
    sleep 1
    tries=$(( tries - 1 ))
  done
  return 1
}

backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR" "${backup_dir}/tailscale"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/tailscale" ]] || return 0
  rm -rf "$DATA_DIR"
  cp -a "${backup_dir}/tailscale" "$DATA_DIR"
}

print_access_info() {
  echo
  if tailscale ip -4 >/dev/null 2>&1; then
    ok "Tailscale: $(tailscale ip -4 2>/dev/null | head -n1) (joined the tailnet)"
  else
    ok "Tailscale installed, not yet joined a tailnet — run: pct exec <ctid> -- tailscale up"
  fi
}

cmd_install() {
  require_root
  is_installed && die "Tailscale is already installed — use 'update' instead"

  local tmp_script
  tmp_script="$(mktemp)"
  curl -fsSL "$INSTALLER_URL" -o "$tmp_script" || { rm -f "$tmp_script"; die "failed to download Tailscale's installer"; }
  sh "$tmp_script" >/dev/null || { rm -f "$tmp_script"; die "Tailscale installation failed"; }
  rm -f "$tmp_script"

  is_installed || die "tailscale installed but is not detected — check: dpkg -s tailscale"

  systemctl enable --now tailscaled >/dev/null 2>&1
  wait_for_service || die "tailscaled did not come up after install — check: systemctl status tailscaled"

  if [[ -n "$AUTH_KEY" ]]; then
    tailscale up --authkey="$AUTH_KEY" || die "tailscale up failed with the given --authkey — check: journalctl -u tailscaled"
  fi

  ok "Tailscale installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Tailscale is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up state to ${backup_dir}"

  apt-get update -qq
  if ! apt-get install -y -qq --only-upgrade tailscale >/dev/null 2>&1; then
    warn "apt upgrade reported an issue — continuing to verify the running service"
  fi

  systemctl restart tailscaled 2>/dev/null || true

  if ! wait_for_service; then
    warn "tailscaled did not come back up after the update — restoring from backup"
    restore_state "$backup_dir"
    systemctl restart tailscaled 2>/dev/null || true
    die "update failed, data restored from ${backup_dir} — check: systemctl status tailscaled"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Tailscale is not installed and there is no backed-up data to remove"
  fi

  local backup_dir=""
  if is_installed; then
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    # Best-effort: lets this node disappear from the tailnet admin console
    # cleanly instead of lingering as "offline" forever. Not fatal if it
    # was never joined in the first place.
    tailscale logout >/dev/null 2>&1 || true
    apt-get remove -y -qq 'tailscale*' >/dev/null 2>&1 || warn "apt remove reported an issue — continuing"
  fi

  # Not gated on is_installed: a previous plain uninstall already removed
  # the package (is_installed is now false) but deliberately left state on
  # disk — a later --purge has to reach this regardless.
  if [[ "$PURGE" -eq 1 ]]; then
    apt-get purge -y -qq 'tailscale*' >/dev/null 2>&1 || true
    rm -rf "$DATA_DIR" "$BACKUP_ROOT"
    ok "Tailscale removed"
  elif [[ -n "$backup_dir" ]]; then
    ok "Tailscale removed, state kept at ${DATA_DIR}, backed up to ${backup_dir}"
  else
    ok "Tailscale was already not installed; nothing further to remove"
  fi
}

cmd_status() {
  is_installed || die "Tailscale is not installed"
  echo "service:  $(systemctl is-active tailscaled 2>/dev/null || echo unknown)"
  echo
  tailscale status 2>&1 || true
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
      --authkey) AUTH_KEY="$2"; shift 2 ;;
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
