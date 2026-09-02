#!/usr/bin/env bash
# In-container management for My Service. Pushed to
# /usr/local/sbin/myservice-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Rule of thumb: don't reimplement upstream's install logic (architecture
# detection, download URLs, channels). Call their installer or their repo, and
# let them own it. Hardcoding ".../linux_amd64.tar.gz" is how "amd64 only" bugs
# get born.
set -Eeuo pipefail

# @include lib/agent-ui.sh

APP_DIR="/opt/myservice"
BACKUP_ROOT="/var/backups/myservice"
PURGE=0

is_installed() { [[ -d "$APP_DIR" ]]; }

backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d "${APP_DIR}/config" ]] && cp -a "${APP_DIR}/config" "$backup_dir/"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/config" ]] && cp -a "${backup_dir}/config" "${APP_DIR}/"
  return 0
}

cmd_install() {
  require_root
  ensure_pkg curl
  is_installed && die "My Service is already installed — use 'update' instead"

  # TODO: install it. Prefer upstream's own installer or apt repo.
  mkdir -p "$APP_DIR"

  ok "My Service installed"
  echo
  ok "My Service: http://$(container_ip):8080"
}

# Back up, upgrade, verify it came back, roll back if it didn't. The rollback
# is the point — an update that silently bricks a service you rely on is worse
# than no update command at all.
cmd_update() {
  require_root
  is_installed || die "My Service is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up config to ${backup_dir}"

  # TODO: perform the upgrade here.

  if ! systemctl is-active --quiet myservice; then
    warn "My Service did not come up after update — rolling back"
    restore_state "$backup_dir"
    systemctl restart myservice || true
    die "update failed, previous config restored"
  fi
  ok "updated"
}

cmd_uninstall() {
  require_root
  is_installed || die "My Service is not installed"
  systemctl disable --now myservice >/dev/null 2>&1 || true
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$APP_DIR"
    ok "My Service and its data removed"
  else
    ok "My Service stopped and disabled, data kept at ${APP_DIR}"
  fi
}

cmd_status() {
  is_installed || die "My Service is not installed"
  echo "service:  $(systemctl is-active myservice 2>/dev/null || echo unknown)"
  command -v ss >/dev/null 2>&1 && { ss -ltnp 2>/dev/null | grep -E ':8080\b' || true; }
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  while (( "$#" )); do
    case "$1" in
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
