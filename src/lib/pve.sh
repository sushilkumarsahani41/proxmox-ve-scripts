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

# ---------------------------------------------------------------------------
# OS support. A case statement rather than an associative array, because
# associative arrays need bash 4 and this project stays parseable on the
# bash 3.2 that ships on macOS (see CONTRIBUTING.md). Add a new OS by adding
# one case to each of the three functions below.
# ---------------------------------------------------------------------------

# Friendly name for prompts and the plan box.
os_label() {
  case "$1" in
    debian) printf 'Debian 13' ;;
    alpine) printf 'Alpine 3.24' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Matches the template name up through the variant, e.g.
# debian-13-standard_13.6-1_arm64.tar.zst or
# alpine-3.24-default_20260803_arm64.tar.xz — deliberately not pinned to one
# minor/point version, since a host's mirror snapshot moves independently of
# this script and pinning "debian-12" is exactly how a script breaks on a
# host whose mirror only carries 13 (see the arm64 test host this was found
# on). $2 is the file extension: Debian ships .tar.zst, Alpine ships .tar.xz.
os_template_pattern() {
  case "$1" in
    debian) printf 'debian-[0-9]+-standard' ;;
    alpine) printf 'alpine-[0-9]+\.[0-9]+-default' ;;
    *) die "unknown OS '${1}'" ;;
  esac
}

# What has to be true inside a *fresh* container before our own bash-based
# manage.sh can even be interpreted, let alone run — this has to be plain
# POSIX sh, not bash, because on Alpine bash is exactly the thing being
# installed. Debian's standard template already ships bash, so its bootstrap
# is just the curl check already needed for the vendor installers; Alpine's
# base image has neither bash nor curl, only busybox ash, apk and wget.
os_bootstrap_cmd() {
  case "$1" in
    debian) printf '%s' 'command -v curl >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq curl)' ;;
    alpine) printf '%s' 'apk update -q >/dev/null 2>&1; command -v bash >/dev/null 2>&1 || apk add -q bash; command -v curl >/dev/null 2>&1 || apk add -q curl' ;;
    *) die "unknown OS '${1}'" ;;
  esac
}

# The service name OpenSSH's own package registers under — not the same
# everywhere. Debian's package (and its systemd unit) is named "ssh", not
# "sshd"; Alpine's OpenRC init script is "sshd". Getting this wrong doesn't
# error, it just silently restarts nothing.
os_sshd_service() {
  case "$1" in
    debian) printf 'ssh' ;;
    alpine) printf 'sshd' ;;
    *) die "unknown OS '${1}'" ;;
  esac
}

template_regex() { printf '^%s_[^_]*_%s\.tar\.(zst|gz|xz)$' "$TEMPLATE_PATTERN" "$1"; }

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
  info "looking for a ${OS_LABEL} (${arch}) container template"

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
    warn "no ${OS_LABEL} template for arch '${arch}' is cached or offered (pattern: ${TEMPLATE_PATTERN})."
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

# Success here means more than "the CT booted": it means DNS, routing and the
# package manager all work, which is what every installer downstream actually
# depends on. Runs via `sh -c`, not bash — on a fresh Alpine container bash is
# exactly what this step installs, so the bootstrap command itself must be
# plain POSIX shell.
wait_for_network() {
  local ctid="$1" os_id="$2" tries=30 cmd
  cmd="$(os_bootstrap_cmd "$os_id")"
  info "waiting for container networking"
  while (( tries > 0 )); do
    if pct exec "$ctid" -- sh -c "$cmd" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    tries=$(( tries - 1 ))
  done
  die "container never came up with working networking/package manager"
}

# OpenSSH's own compiled-in default is `PermitRootLogin prohibit-password` —
# root can SSH in with a key, never with a password, no matter how correct
# it is. Debian's and Alpine's shipped sshd_config both leave that directive
# commented out (so the compiled-in default applies) rather than setting it
# explicitly — confirmed by reading a real container's sshd_config, not
# assumed. The practical effect: the root password this project generates
# and prints was completely unusable for `ssh root@<ip>` — only `pct enter`/
# `pct exec` (which never go through sshd at all) worked with it. Reproduced
# directly with sshpass against a real container ("Permission denied") before
# writing this fix, and confirmed SSH succeeds after it runs.
#
# This is a real security trade-off, not a pure bug fix — root+password
# becomes reachable from the whole LAN, not just from the PVE host — made
# deliberately for this project's stated use case (hobby, personal-LAN,
# tinkering) rather than a public-internet-facing hardening target. The
# generated password is a random 20 characters, not something guessable.
#
# Idempotent: replaces the directive if present (commented or not) rather
# than assuming it's absent, so re-running this against an already-patched
# container is harmless.
enable_root_ssh() {
  local ctid="$1" os_id="$2" svc cmd
  svc="$(os_sshd_service "$os_id")"

  # Debian's base template ships OpenSSH server already installed, enabled,
  # and running. Alpine's does not ship it at all — confirmed directly
  # (`/etc/ssh` doesn't exist on a fresh container) rather than assumed from
  # Debian's behaviour transferring over. Installing it here, not folded into
  # os_bootstrap_cmd, because this step already knows it needs sshd
  # specifically; a service that never touches SSH shouldn't pay for it.
  if [[ "$os_id" == "alpine" ]]; then
    pct exec "$ctid" -- sh -c 'apk info -e openssh >/dev/null 2>&1 || apk add -q openssh' \
      || die "failed to install openssh on Alpine"
    pct exec "$ctid" -- rc-update add "$svc" default >/dev/null 2>&1 || true
  fi

  # Plain basic-regex sed/grep throughout, no -E: Alpine's base image ships
  # BusyBox's sed, and this project does not assume it understands GNU-style
  # extended-regex flags. The patterns don't need extended regex anyway.
  cmd='CFG=/etc/ssh/sshd_config
for pair in "PermitRootLogin yes" "PasswordAuthentication yes"; do
  key=${pair%% *}
  if grep -q "^[#[:space:]]*${key}[[:space:]]" "$CFG" 2>/dev/null; then
    sed -i "s|^[#[:space:]]*${key}[[:space:]].*|${pair}|" "$CFG"
  else
    printf "%s\n" "$pair" >> "$CFG"
  fi
done'
  pct exec "$ctid" -- sh -c "$cmd" || die "failed to update sshd_config for root password login"

  # restart on Debian (already running); Alpine's package installs the
  # service but does not start it, so start (not just restart) it there.
  if [[ "$os_id" == "alpine" ]]; then
    pct exec "$ctid" -- rc-service "$svc" restart 2>/dev/null || pct exec "$ctid" -- rc-service "$svc" start \
      || die "sshd_config was updated but starting '${svc}' failed"
  else
    pct exec "$ctid" -- systemctl restart "$svc" || die "sshd_config was updated but restarting '${svc}' failed"
  fi
}

# Pushes the embedded management script into $ctid, always overwriting so the
# container stays in sync with whatever version of this file you're running.
push_manage_script() {
  local ctid="$1" tmp
  tmp="$(mktemp)"
  manage_script > "$tmp"
  # `pct push` does not create parent directories. Debian's standard template
  # ships /usr/local/sbin already; Alpine's minimal base does not (only
  # /usr/local/{bin,lib,share}) — mkdir -p first rather than assume either.
  pct exec "$ctid" -- mkdir -p "$(dirname "$MANAGE_PATH")"
  pct push "$ctid" "$tmp" "$MANAGE_PATH"
  rm -f "$tmp"
  pct exec "$ctid" -- chmod +x "$MANAGE_PATH"
}

# `hostname -I` is a GNU-ism; busybox's hostname applet (Alpine) does not
# support it and errors out. `ip addr show` is implemented identically by
# busybox and iproute2, so parse that instead of branching per OS.
container_ip() {
  pct exec "$1" -- sh -c "ip -4 addr show eth0 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2"
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
      --features "nesting=${NESTING},keyctl=${KEYCTL}" \
      --password "$ROOT_PASSWORD" \
      --onboot 1 \
      --start 0
  run_step "starting container ${ctid}" pct start "$ctid"
}
