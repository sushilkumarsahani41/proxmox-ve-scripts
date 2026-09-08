#!/usr/bin/env bash
# In-container management for Traefik. Pushed to
# /usr/local/sbin/traefik-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Traefik ships no apt package and no install script — its only official
# non-Docker artifact is the binary tarball on GitHub Releases (verified
# directly against a real release's asset list: amd64/arm64/armv7 builds
# exist for every version, not assumed). This project writes the systemd
# unit itself, the same as any vendor that ships a binary but no packaging.
set -Eeuo pipefail

# @include lib/agent-ui.sh

BIN="/usr/local/bin/traefik"
CONF_DIR="/etc/traefik"
STATIC_CONF="${CONF_DIR}/traefik.yml"
DYNAMIC_CONF="${CONF_DIR}/dynamic.yml"
DATA_DIR="/var/lib/traefik"
UNIT="/etc/systemd/system/traefik.service"
BACKUP_ROOT="/var/backups/traefik-lxc"
PURGE=0

is_installed() { [[ -x "$BIN" ]]; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$CONF_DIR" ]] && [[ -n "$(ls -A "$CONF_DIR" 2>/dev/null)" ]]; }
}

arch_asset() {
  case "$(dpkg --print-architecture)" in
    amd64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    armhf) echo "armv7" ;;
    *) die "Traefik has no published build for architecture '$(dpkg --print-architecture)'" ;;
  esac
}

latest_release_tag() {
  curl -fsSL https://api.github.com/repos/traefik/traefik/releases/latest \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1
}

install_traefik_binary() {
  local tag arch url tmp_dir
  tag="$(latest_release_tag)"
  [[ -n "$tag" ]] || die "couldn't determine Traefik's latest release — check network access to api.github.com"
  arch="$(arch_asset)"
  url="https://github.com/traefik/traefik/releases/download/${tag}/traefik_${tag}_linux_${arch}.tar.gz"
  tmp_dir="$(mktemp -d)"
  curl -fsSL "$url" -o "${tmp_dir}/traefik.tar.gz" || { rm -rf "$tmp_dir"; die "failed to download Traefik ${tag} for linux_${arch}"; }
  tar -xzf "${tmp_dir}/traefik.tar.gz" -C "$tmp_dir" traefik || { rm -rf "$tmp_dir"; die "downloaded archive did not contain a traefik binary"; }
  install -m 755 "${tmp_dir}/traefik" "$BIN"
  rm -rf "$tmp_dir"
}

write_config() {
  mkdir -p "$CONF_DIR" "$DATA_DIR"
  if [[ ! -f "$STATIC_CONF" ]]; then
    cat > "$STATIC_CONF" <<EOF
entryPoints:
  web:
    address: ":80"

api:
  dashboard: true
  insecure: true

ping: {}

providers:
  file:
    filename: ${DYNAMIC_CONF}
    watch: true

log:
  level: INFO
EOF
  fi
  if [[ ! -f "$DYNAMIC_CONF" ]]; then
    cat > "$DYNAMIC_CONF" <<'EOF'
# Traefik watches this file and reloads automatically — no restart needed.
# Example:
#
# http:
#   routers:
#     my-app:
#       rule: "Host(`app.example.com`)"
#       service: my-app
#   services:
#     my-app:
#       loadBalancer:
#         servers:
#           - url: "http://192.168.1.50:8080"
http: {}
EOF
  fi
}

write_systemd_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=Traefik
After=network.target

[Service]
ExecStart=${BIN} --configFile=${STATIC_CONF}
WorkingDirectory=${CONF_DIR}
Restart=on-failure
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

service_healthy() { curl -fsS "http://localhost:8080/ping" 2>/dev/null | grep -q '^OK$'; }

wait_for_service() {
  local tries=30
  while (( tries > 0 )); do
    service_healthy && return 0
    sleep 2
    tries=$(( tries - 1 ))
  done
  return 1
}

backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d "$CONF_DIR" ]] && cp -a "$CONF_DIR" "${backup_dir}/traefik-etc"
  [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR" "${backup_dir}/traefik-lib"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/traefik-etc" ]] && { rm -rf "$CONF_DIR"; cp -a "${backup_dir}/traefik-etc" "$CONF_DIR"; }
  [[ -d "${backup_dir}/traefik-lib" ]] && { rm -rf "$DATA_DIR"; cp -a "${backup_dir}/traefik-lib" "$DATA_DIR"; }
}

print_access_info() {
  echo
  ok "Traefik dashboard: http://$(container_ip):8080/dashboard/"
}

cmd_install() {
  require_root
  is_installed && die "Traefik is already installed — use 'update' instead"

  ensure_pkg curl
  install_traefik_binary
  write_config
  write_systemd_unit

  systemctl enable --now traefik >/dev/null 2>&1 \
    || die "traefik.service failed to start — check: journalctl -u traefik"

  wait_for_service || die "Traefik did not come up healthy after install — check: journalctl -u traefik"

  ok "Traefik installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "Traefik is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up config to ${backup_dir}"

  # install_traefik_binary dies with its own specific message (bad network,
  # no release found, unsupported arch) on failure — nothing left to add by
  # wrapping this in another die, and the existing binary/service is
  # untouched either way since nothing below has run yet.
  install_traefik_binary

  systemctl restart traefik 2>/dev/null || true

  if ! wait_for_service; then
    warn "Traefik did not come back up healthy after the update — restoring config from backup"
    restore_state "$backup_dir"
    systemctl restart traefik 2>/dev/null || true
    die "update failed, config restored from ${backup_dir} — the binary itself is not rolled back by this; check: journalctl -u traefik"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "Traefik is not installed and there is no backed-up data to remove"
  fi

  local backup_dir=""
  if is_installed; then
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    systemctl disable --now traefik >/dev/null 2>&1 || true
    rm -f "$BIN" "$UNIT"
    systemctl daemon-reload
  fi

  # Not gated on is_installed: a previous plain uninstall already removed
  # the binary (is_installed is now false) but deliberately left config/data
  # on disk — a later --purge has to reach this regardless.
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$CONF_DIR" "$DATA_DIR" "$BACKUP_ROOT"
    ok "Traefik removed"
  elif [[ -n "$backup_dir" ]]; then
    ok "Traefik removed, config kept at ${CONF_DIR}, backed up to ${backup_dir}"
  else
    ok "Traefik was already not installed; nothing further to remove"
  fi
}

cmd_status() {
  is_installed || die "Traefik is not installed"
  echo "service:  $(systemctl is-active traefik 2>/dev/null || echo unknown)"
  echo "address:  http://$(container_ip):8080/dashboard/"
  echo
  command -v ss >/dev/null 2>&1 && { ss -ltnp 2>/dev/null | grep -E ':(80|8080)\b' || true; }
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
