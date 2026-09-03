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

# Proxmox installs disagree about storage names: `local-lvm` on a stock
# install, `local-zfs` on ZFS root, and on dir-based images (the Raspberry Pi
# one, for instance) there is only `local`. Hardcoding local-lvm and letting
# `pct create` fail four steps later is a bad first five minutes.
resolve_storage() {
  local content="$1" explicit="$2" preferred="$3" candidates s

  if [[ -n "$explicit" ]]; then
    if ! pvesm status --content "$content" 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$explicit"; then
      warn "storage '${explicit}' is not an active storage supporting '${content}' on this host — trying anyway"
    fi
    echo "$explicit"
    return 0
  fi

  candidates="$(pvesm status --content "$content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')"
  [[ -n "$candidates" ]] || die "no active storage on this host supports '${content}' — pass one explicitly"

  for s in $preferred; do
    if printf '%s\n' "$candidates" | grep -qx "$s"; then
      echo "$s"
      return 0
    fi
  done
  printf '%s\n' "$candidates" | head -n1
}

# Container templates are named like: debian-13-standard_13.6-1_arm64.tar.zst
# TEMPLATE_PATTERN matches the leading name part, and the default deliberately
# accepts *any* Debian major version — pinning "debian-12" means the script
# breaks on a host whose mirror only offers 13, which is exactly what a current
# PVE 9 arm64 install looks like.
template_regex() { printf '^%s_[^_]*_%s\.tar\.(zst|gz)$' "$TEMPLATE_PATTERN" "$1"; }

cached_template_files() {
  pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}' | sed 's|.*/||'
}

available_template_files() {
  pveam available --section system 2>/dev/null | awk 'NF>1 {print $2}'
}

ensure_template() {
  local arch="$1" rx cached avail best update_err

  # A --template override skips all of this — use it verbatim.
  if [[ -n "$TEMPLATE" ]]; then
    echo "$TEMPLATE"
    return 0
  fi

  rx="$(template_regex "$arch")"
  info "looking for a ${TEMPLATE_LABEL} (${arch}) container template"

  # Check what is already downloaded *before* touching the network. A template
  # sitting in local:vztmpl makes the whole appliance-mirror question moot, and
  # broken or unreachable mirrors are common enough (third-party mirrors, ARM
  # images, no internet at all) that failing there while the file is already on
  # disk would be absurd.
  cached="$(cached_template_files | grep -E "$rx" | sort -V | tail -n1 || true)"

  if ! update_err="$(pveam update 2>&1 >/dev/null)"; then
    warn "pveam update failed, continuing with whatever is already cached: ${update_err}"
  elif [[ -n "$update_err" ]]; then
    warn "pveam update: ${update_err}"
  fi

  avail="$(available_template_files | grep -E "$rx" | sort -V | tail -n1 || true)"

  # Newest of the two, but never re-download something we already have.
  best="$(printf '%s\n%s\n' "$cached" "$avail" | grep -v '^$' | sort -V | tail -n1 || true)"

  if [[ -z "$best" ]]; then
    warn "no ${TEMPLATE_LABEL} template for arch '${arch}' is cached or offered (pattern: ${TEMPLATE_PATTERN})."
    warn "cached on ${TEMPLATE_STORAGE}:"
    cached_template_files | sed 's/^/      /' >&2 || true
    warn "offered by the appliance list for ${arch}:"
    available_template_files | grep -E "_${arch}\." | sed 's/^/      /' >&2 \
      || echo "      (nothing for ${arch} — the appliance list looks broken or incomplete on this host)" >&2
    die "fix the appliance list (see warnings above), or skip auto-detection entirely with: --template <storage>:vztmpl/<filename>"
  fi

  if [[ "$best" == "$cached" ]]; then
    info "using cached template ${best}"
  else
    run_step "downloading template ${best}" pveam download "$TEMPLATE_STORAGE" "$best"
  fi
  echo "${TEMPLATE_STORAGE}:vztmpl/${best}"
}

# What this host can actually offer, for the interactive picker. Offering a
# free-text field for something with three valid answers is how typos become
# support questions.
#
# Each ends in `|| true`: these run inside a bare $(...) substitution (an
# argument to ask_choice, not an if/while condition), and with errtrace (-E)
# the ERR trap fires *inside that subshell* for any failing command in it —
# missing binary, empty grep match, whatever — printing a false "failed at
# line N" and aborting the probe, even though the caller only wants a best
# effort and already falls back to the current default on empty input.
storage_options() {
  pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' || true
}

bridge_options() {
  ip -br link show type bridge 2>/dev/null | awk '{print $1}' || true
}

host_gateway() {
  ip route 2>/dev/null | awk '/^default/ {print $3; exit}' || true
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
    tries=$(( tries - 1 ))
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
