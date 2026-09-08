#!/usr/bin/env bash
# In-container management for WireGuard. Pushed to
# /usr/local/sbin/wireguard-manage.sh and re-pushed on every command, so the
# container always matches the host script's version.
#
# Delegates to Debian's own wireguard-tools package for the protocol itself;
# everything else here (the wg0.conf this writes, NAT/forwarding rules, the
# client-management commands) is this project's own, since a "WireGuard
# server" isn't a single vendor-run daemon with its own config format the
# way every other service here is — wg-quick is a thin wrapper around the
# kernel's own WireGuard implementation, and the server/client config shape
# is just what wg-quick expects, not something a vendor installer sets up
# for you.
set -Eeuo pipefail

# @include lib/agent-ui.sh

WG_DIR="/etc/wireguard"
CONF="${WG_DIR}/wg0.conf"
CLIENTS_DIR="${WG_DIR}/clients"
BACKUP_ROOT="/var/backups/wireguard-lxc"
VPN_PORT="51820"
VPN_SUBNET="10.66.66"
PURGE=0

is_installed() { dpkg-query -W -f='${Status}' wireguard-tools 2>/dev/null | grep -q '^install ok installed'; }
has_data() {
  { [[ -d "$BACKUP_ROOT" ]] && [[ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; } \
    || { [[ -d "$WG_DIR" ]] && [[ -n "$(ls -A "$WG_DIR" 2>/dev/null)" ]]; }
}

wan_iface() { ip route show default 2>/dev/null | awk '{print $5; exit}'; }

service_healthy() { wg show wg0 >/dev/null 2>&1; }

wait_for_service() {
  local tries=15
  while (( tries > 0 )); do
    service_healthy && return 0
    sleep 1
    tries=$(( tries - 1 ))
  done
  return 1
}

# The next free client address in ${VPN_SUBNET}.0/24 — .1 is the server
# itself, so clients start at .2. Counts existing client configs rather than
# keeping a separate counter file, so it stays correct even if one was
# removed by hand.
next_client_ip() {
  local n=2
  while [[ -f "${CLIENTS_DIR}/.ip-${n}" ]]; do
    n=$(( n + 1 ))
  done
  echo "$n"
}

# Adds a peer to the running interface without dropping existing
# connections (`wg syncconf`, the documented safe way to apply a config
# change to a live wg-quick interface — a full `wg-quick down/up` would
# briefly drop every already-connected client, not just the new one).
sync_wg0() {
  wg syncconf wg0 <(wg-quick strip wg0)
}

add_client() {
  local name="$1"
  [[ -n "$name" ]] || die "add-client needs a name, e.g.: add-client phone"
  [[ -f "${CLIENTS_DIR}/${name}.conf" ]] && die "a client named '${name}' already exists"

  local ip; ip="$(next_client_ip)"
  local priv pub psk server_pub endpoint
  priv="$(wg genkey)"
  pub="$(printf '%s' "$priv" | wg pubkey)"
  psk="$(wg genpsk)"
  server_pub="$(printf '%s' "$(sed -n 's/^PrivateKey = //p' "$CONF" | head -n1)" | wg pubkey)"
  endpoint="$(container_ip):${VPN_PORT}"

  {
    echo ""
    echo "[Peer]"
    echo "# ${name}"
    echo "PublicKey = ${pub}"
    echo "PresharedKey = ${psk}"
    echo "AllowedIPs = ${VPN_SUBNET}.${ip}/32"
  } >> "$CONF"

  mkdir -p "$CLIENTS_DIR"
  : > "${CLIENTS_DIR}/.ip-${ip}"
  cat > "${CLIENTS_DIR}/${name}.conf" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${VPN_SUBNET}.${ip}/24
DNS = 1.1.1.1

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${endpoint}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  chmod 600 "${CLIENTS_DIR}/${name}.conf"

  if service_healthy; then
    sync_wg0 || warn "peer added to ${CONF} but syncing the live interface failed — a restart of wg-quick@wg0 will pick it up"
  fi

  ok "client '${name}' added (${VPN_SUBNET}.${ip})"
}

remove_client() {
  local name="$1"
  [[ -n "$name" ]] || die "remove-client needs a name"
  [[ -f "${CLIENTS_DIR}/${name}.conf" ]] || die "no client named '${name}'"

  # Each [Peer] block is its own blank-line-separated paragraph, tagged with
  # a `# <name>` comment line added by add_client — paragraph mode (RS="")
  # plus an exact per-line match (not a plain substring search, which would
  # also match "peer10" while looking for "peer1") finds the one block that
  # is this client's and drops it, leaving [Interface] and every other
  # [Peer] block untouched.
  awk -v marker="# ${name}" '
    BEGIN { RS=""; ORS="\n\n" }
    {
      found = 0
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) { if (lines[i] == marker) { found = 1; break } }
      if (!found) print
    }
  ' "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"

  local ip_marker
  ip_marker="$(sed -n 's/^Address = '"${VPN_SUBNET}"'\.\([0-9]*\)\/.*/\1/p' "${CLIENTS_DIR}/${name}.conf" | head -n1)"
  rm -f "${CLIENTS_DIR}/${name}.conf" "${CLIENTS_DIR}/.ip-${ip_marker}"

  if service_healthy; then
    sync_wg0 || warn "peer removed from ${CONF} but syncing the live interface failed — a restart of wg-quick@wg0 will pick it up"
  fi

  ok "client '${name}' removed"
}

list_clients() {
  [[ -d "$CLIENTS_DIR" ]] || { echo "no clients yet"; return 0; }
  local f base
  for f in "${CLIENTS_DIR}"/*.conf; do
    [[ -e "$f" ]] || { echo "no clients yet"; return 0; }
    base="$(basename "$f" .conf)"
    echo "$base"
  done
}

show_client() {
  local name="$1"
  [[ -n "$name" ]] || die "show-client needs a name"
  [[ -f "${CLIENTS_DIR}/${name}.conf" ]] || die "no client named '${name}'"
  echo "--- ${name}.conf ---"
  cat "${CLIENTS_DIR}/${name}.conf"
  if command -v qrencode >/dev/null 2>&1; then
    echo
    echo "--- scan with the WireGuard app ---"
    qrencode -t ansiutf8 < "${CLIENTS_DIR}/${name}.conf"
  fi
}

backup_state() {
  local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ -d "$WG_DIR" ]] && cp -a "$WG_DIR" "${backup_dir}/wireguard"
  echo "$backup_dir"
}

restore_state() {
  local backup_dir="$1"
  [[ -d "${backup_dir}/wireguard" ]] || return 0
  rm -rf "$WG_DIR"
  cp -a "${backup_dir}/wireguard" "$WG_DIR"
}

print_access_info() {
  echo
  ok "WireGuard: $(container_ip):${VPN_PORT} (UDP)"
  ok "First client config: pct exec <ctid> -- /usr/local/sbin/wireguard-manage.sh show-client peer1"
}

cmd_install() {
  require_root
  is_installed && die "WireGuard is already installed — use 'update' instead"

  ensure_pkg wireguard-tools qrencode iptables

  local iface; iface="$(wan_iface)"
  [[ -n "$iface" ]] || die "couldn't determine the default network interface — check: ip route show default"

  mkdir -p "$WG_DIR" "$CLIENTS_DIR"
  chmod 700 "$WG_DIR"

  local server_priv; server_priv="$(wg genkey)"
  cat > "$CONF" <<EOF
[Interface]
Address = ${VPN_SUBNET}.1/24
ListenPort = ${VPN_PORT}
PrivateKey = ${server_priv}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${iface} -j MASQUERADE
EOF
  chmod 600 "$CONF"

  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
  sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null 2>&1 || true

  systemctl enable --now wg-quick@wg0 >/dev/null 2>&1 \
    || die "wg-quick@wg0 failed to start — check: journalctl -u wg-quick@wg0"

  wait_for_service || die "WireGuard interface did not come up — check: journalctl -u wg-quick@wg0"

  add_client peer1

  ok "WireGuard installed"
  print_access_info
}

cmd_update() {
  require_root
  is_installed || die "WireGuard is not installed — use 'install' instead"

  local backup_dir
  backup_dir="$(backup_state)"
  ok "backed up keys and client configs to ${backup_dir}"

  apt-get update -qq
  if ! apt-get install -y -qq --only-upgrade wireguard-tools >/dev/null 2>&1; then
    warn "apt upgrade reported an issue — continuing to verify the running interface"
  fi

  systemctl restart wg-quick@wg0 2>/dev/null || true

  if ! wait_for_service; then
    warn "WireGuard did not come back up after the update — restoring from backup"
    restore_state "$backup_dir"
    systemctl restart wg-quick@wg0 2>/dev/null || true
    die "update failed, data restored from ${backup_dir} — check: journalctl -u wg-quick@wg0"
  fi

  ok "updated"
  print_access_info
}

cmd_uninstall() {
  require_root
  if ! is_installed && ! has_data; then
    die "WireGuard is not installed and there is no backed-up data to remove"
  fi

  local backup_dir=""
  if is_installed; then
    if [[ "$PURGE" -eq 0 ]]; then
      backup_dir="$(backup_state)"
    fi
    systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true
    apt-get remove -y -qq 'wireguard-tools*' >/dev/null 2>&1 || warn "apt remove reported an issue — continuing"
  fi

  # Not gated on is_installed: a previous plain uninstall already removed
  # the package (is_installed is now false) but deliberately left keys and
  # client configs on disk — a later --purge has to reach this regardless.
  if [[ "$PURGE" -eq 1 ]]; then
    apt-get purge -y -qq 'wireguard-tools*' >/dev/null 2>&1 || true
    rm -rf "$WG_DIR" /etc/sysctl.d/99-wireguard.conf "$BACKUP_ROOT"
    ok "WireGuard removed"
  elif [[ -n "$backup_dir" ]]; then
    ok "WireGuard removed, keys and client configs kept at ${WG_DIR}, backed up to ${backup_dir}"
  else
    ok "WireGuard was already not installed; nothing further to remove"
  fi
}

cmd_status() {
  is_installed || die "WireGuard is not installed"
  echo "service:  $(systemctl is-active wg-quick@wg0 2>/dev/null || echo unknown)"
  echo "address:  $(container_ip):${VPN_PORT} (UDP)"
  echo
  wg show wg0 2>&1 || true
  echo
  echo "clients:"
  list_clients | sed 's/^/  /'
}

main() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then shift; fi
  case "$cmd" in
    install)
      while (( "$#" )); do case "$1" in *) die "unknown option: $1" ;; esac; done
      cmd_install ;;
    update)
      while (( "$#" )); do case "$1" in *) die "unknown option: $1" ;; esac; done
      cmd_update ;;
    uninstall)
      while (( "$#" )); do
        case "$1" in
          --purge) PURGE=1; shift ;;
          *) die "unknown option: $1" ;;
        esac
      done
      cmd_uninstall ;;
    status) cmd_status ;;
    add-client) require_root; add_client "${1:-}" ;;
    remove-client) require_root; remove_client "${1:-}" ;;
    list-clients) list_clients ;;
    show-client) show_client "${1:-}" ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
