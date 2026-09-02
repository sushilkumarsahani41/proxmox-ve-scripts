#!/usr/bin/env bash
# lib/pve.sh — Proxmox VE host-side primitives: preflight, template
# resolution, container creation, readiness waiting, agent push.
# Inlined into every built script by build.sh.

require_pve_host() {
  command -v pct >/dev/null 2>&1 || die "pct not found — this script must run on a Proxmox VE host"
  [[ "$(id -u)" -eq 0 ]] || die "must be run as root on the Proxmox VE host"
}

require_ctid_exists() {
  local ctid="$1"
  pct status "$ctid" >/dev/null 2>&1 || die "container ${ctid} not found"
}

# Match the host, don't assume amd64 — Proxmox runs on arm64 boxes too.
resolve_arch() { dpkg --print-architecture; }

resolve_ctid() {
  if [[ -n "$CTID" ]]; then
    pct status "$CTID" >/dev/null 2>&1 && die "container ${CTID} already exists — pick another --id"
    echo "$CTID"
    return
  fi
  pvesh get /cluster/nextid
}

ensure_template() {
  local arch="$1" template update_err avail_out avail_err

  # A --template override skips all of this — use it verbatim.
  if [[ -n "$TEMPLATE" ]]; then
    echo "$TEMPLATE"
    return 0
  fi

  info "checking for a ${TEMPLATE_DISTRO} (${arch}) container template"

  if ! update_err="$(pveam update 2>&1 >/dev/null)"; then
    warn "pveam update failed, continuing with whatever is already cached: ${update_err}"
  elif [[ -n "$update_err" ]]; then
    warn "pveam update: ${update_err}"
  fi

  avail_err="$(mktemp)"
  avail_out="$(pveam available --section system 2>"$avail_err" || true)"
  if [[ -s "$avail_err" ]]; then
    warn "pveam available reported: $(cat "$avail_err")"
  fi
  rm -f "$avail_err"

  template="$(printf '%s\n' "$avail_out" \
    | awk -v a="$arch" -v d="$TEMPLATE_DISTRO" '$2 ~ "^"d".*_"a"\\.tar\\.(zst|gz)$" {print $2}' \
    | sort -V | tail -n1)"

  if [[ -z "$template" ]]; then
    warn "no ${TEMPLATE_DISTRO} template for arch '${arch}' found. Entries currently listed:"
    printf '%s\n' "$avail_out" | grep -iE "${TEMPLATE_DISTRO%%-*}" 1>&2 \
      || echo "  (none at all — the appliance list looks empty or broken on this host)" 1>&2
    die "fix the appliance list (see warnings above), or skip auto-detection entirely with: --template <storage>:vztmpl/<filename>"
  fi

  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$template"; then
    run_step "downloading template ${template}" pveam download "$TEMPLATE_STORAGE" "$template"
  fi
  echo "${TEMPLATE_STORAGE}:vztmpl/${template}"
}

build_net_arg() {
  if [[ -n "$STATIC_CIDR" ]]; then
    echo "name=eth0,bridge=${BRIDGE},ip=${STATIC_CIDR},gw=${GATEWAY}"
  else
    echo "name=eth0,bridge=${BRIDGE},ip=dhcp"
  fi
}

# Success here means more than "the CT booted": it means DNS, routing and apt
# all work, which is the thing every installer downstream actually depends on.
wait_for_network() {
  local ctid="$1" tries=30
  info "waiting for container networking"
  while (( tries > 0 )); do
    if pct exec "$ctid" -- sh -c 'command -v curl >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq curl)' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    (( tries-- ))
  done
  die "container never came up with working networking/apt"
}

# Pushes the embedded management script into $ctid, always overwriting so the
# container stays in sync with whatever version of this file you're running.
push_manage_script() {
  local ctid="$1" tmp
  tmp="$(mktemp)"
  manage_script > "$tmp"
  pct push "$ctid" "$tmp" "$MANAGE_PATH"
  rm -f "$tmp"
  pct exec "$ctid" -- chmod +x "$MANAGE_PATH"
}

container_ip() {
  pct exec "$1" -- hostname -I 2>/dev/null | awk '{print $1}'
}

create_container() {
  local ctid="$1" template="$2" net_arg="$3"
  run_step "creating container ${ctid}" \
    pct create "$ctid" "$template" \
      --hostname "$CT_HOSTNAME" \
      --cores "$CORES" \
      --memory "$MEMORY_MB" \
      --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
      --net0 "$net_arg" \
      --unprivileged "$UNPRIVILEGED" \
      --features "nesting=${NESTING}" \
      --onboot 1 \
      --start 0
  run_step "starting container ${ctid}" pct start "$ctid"
}
