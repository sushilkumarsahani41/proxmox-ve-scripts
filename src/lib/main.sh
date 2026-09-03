#!/usr/bin/env bash
# lib/main.sh — defaults, argument parsing and the create/update/uninstall/
# status dispatcher shared by every script. Include this LAST: it reads the
# DEFAULT_* values the service set above it, and the svc_* hooks it defines
# here are meant to be overridden by the service below it.

trap 'die "failed at line $LINENO (exit code $?)"' ERR

# Runtime knobs, seeded from the service's DEFAULT_* block.
CTID=""
CT_HOSTNAME="${DEFAULT_HOSTNAME}"
# Empty means "work it out from the host" — see resolve_storage().
ROOTFS_STORAGE="${DEFAULT_ROOTFS_STORAGE:-}"
TEMPLATE_STORAGE="${DEFAULT_TEMPLATE_STORAGE:-}"
TEMPLATE_PATTERN="${DEFAULT_TEMPLATE_PATTERN:-debian-[0-9]+-standard}"
# TEMPLATE_PATTERN is a regex and reads like one; keep it out of status lines.
TEMPLATE_LABEL="${DEFAULT_TEMPLATE_LABEL:-Debian}"
BRIDGE="${DEFAULT_BRIDGE:-vmbr0}"
DISK_GB="${DEFAULT_DISK_GB:-4}"
CORES="${DEFAULT_CORES:-1}"
MEMORY_MB="${DEFAULT_MEMORY_MB:-512}"
UNPRIVILEGED="${DEFAULT_UNPRIVILEGED:-1}"
NESTING="${DEFAULT_NESTING:-0}"
STATIC_CIDR=""
GATEWAY=""
TEMPLATE=""
MANAGE_PATH="/usr/local/sbin/${SERVICE_ID}-manage.sh"
SVC_OPT_SHIFT=0
SVC_INSTALL_ARGS=()
PREFER_STATIC="${DEFAULT_PREFER_STATIC:-n}"
# Any create flag at all means "you are scripting me": no prompts, so a command
# in a runbook behaves the same in six months as it does today.
OPTS_GIVEN=0
ASSUME_DEFAULTS=0

# ---- Service hooks: defaults here, overridden below the include if needed --
# svc_parse_option  — handle one service-specific flag; set SVC_OPT_SHIFT to
#                     how many argv entries it consumed and return 0, or
#                     return 1 to let the caller reject it as unknown.
svc_parse_option() { return 1; }
# svc_install_args  — fill SVC_INSTALL_ARGS with extra args for `install`.
svc_install_args() { SVC_INSTALL_ARGS=(); }
# svc_summary_lines — extra " label : value" lines for the closing box.
svc_summary_lines() { :; }
# svc_post_create   — anything to do on the host after install ($1=ctid $2=ip).
svc_post_create() { :; }
# svc_prompt        — extra questions for the interactive configure step.
svc_prompt() { :; }
# svc_plan_lines    — extra " label : value" lines for the pre-create summary.
svc_plan_lines() { :; }

parse_create_args() {
  [[ $# -gt 0 ]] && OPTS_GIVEN=1
  while (( "$#" )); do
    case "$1" in
      -i|--id) CTID="$2"; shift 2 ;;
      -n|--hostname) CT_HOSTNAME="$2"; shift 2 ;;
      -s|--storage) ROOTFS_STORAGE="$2"; shift 2 ;;
      -t|--template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
      -b|--bridge) BRIDGE="$2"; shift 2 ;;
      -d|--disk) DISK_GB="$2"; shift 2 ;;
      -c|--cores) CORES="$2"; shift 2 ;;
      -m|--memory) MEMORY_MB="$2"; shift 2 ;;
      --static) STATIC_CIDR="$2"; shift 2 ;;
      --gateway) GATEWAY="$2"; shift 2 ;;
      --template) TEMPLATE="$2"; shift 2 ;;
      -y|--yes|--defaults) ASSUME_DEFAULTS=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *)
        SVC_OPT_SHIFT=0
        if svc_parse_option "$@"; then
          shift "$SVC_OPT_SHIFT"
        else
          die "unknown option: $1 (see --help)"
        fi
        ;;
    esac
  done
  if [[ -n "$STATIC_CIDR" && -z "$GATEWAY" ]]; then
    die "--static requires --gateway"
  fi
  return 0
}

# How to tell the user to re-invoke us. When the script was run the piped way
# (bash <(curl ...)), $0 is a spent file descriptor, not a path — printing
# "./63 update 101" would be actively misleading. Rather than inlining the full
# 120-character curl incantation into every summary line (which shreds the box
# on a normal terminal), name the file it *would* be and tell them how to get
# it, once, underneath.
ran_from_file() { [[ -f "${0:-}" && "$(basename -- "${0:-}")" == *.sh ]]; }

self_cmd() {
  if ran_from_file; then
    printf './%s' "$(basename -- "$0")"
  else
    printf './%s' "$PVS_SCRIPT_FILENAME"
  fi
}

summary() {
  local ctid="$1" ip="$2" self
  self="$(self_cmd)"
  {
    echo " ${SERVICE_NAME} is up - CT ${ctid} (${CT_HOSTNAME})"
    echo ""
    svc_summary_lines "$ctid" "$ip"
    echo ""
    echo " Update       : ${self} update ${ctid}"
    echo " Status       : ${self} status ${ctid}"
    echo " Uninstall    : ${self} uninstall ${ctid}"
  } | print_summary_box

  if ! ran_from_file; then
    printf "%b[*]%b You ran this from a pipe, so there is no local copy yet. To manage CT %s later:\n" \
      "$C_INFO" "$C_RESET" "$ctid"
    printf "    curl -fsSL %s -o %s && chmod +x %s\n" \
      "$PVS_SCRIPT_URL" "$PVS_SCRIPT_FILENAME" "$PVS_SCRIPT_FILENAME"
  fi
}

# Prompt only when there is a human to answer, nothing was passed on the
# command line, and defaults were not explicitly requested.
wizard_wanted() {
  [[ "$ASSUME_DEFAULTS" -eq 1 ]] && return 1
  [[ "$OPTS_GIVEN" -eq 1 ]] && return 1
  interactive || return 1
  return 0
}

plan_lines() {
  echo " ${SERVICE_NAME} - about to create"
  echo ""
  echo " Container ID  : ${CTID}"
  echo " Hostname      : ${CT_HOSTNAME}"
  echo " Storage pool  : ${ROOTFS_STORAGE}"
  echo " Disk size     : ${DISK_GB} GB"
  echo " CPU cores     : ${CORES}"
  echo " Memory        : ${MEMORY_MB} MB"
  if [[ -n "$STATIC_CIDR" ]]; then
    echo " Network       : ${STATIC_CIDR} via ${GATEWAY} on ${BRIDGE}"
  else
    echo " Network       : DHCP on ${BRIDGE}"
  fi
  svc_plan_lines
}

configure_interactive() {
  printf '\n' >&2
  info "Enter accepts the recommended value shown in brackets."
  printf '\n' >&2

  CTID="$(ask "Container ID" "$CTID" v_ctid)"
  CT_HOSTNAME="$(ask "Hostname" "$CT_HOSTNAME" v_hostname)"
  ROOTFS_STORAGE="$(ask_choice "Storage pool" "$ROOTFS_STORAGE" "$(storage_options)")"
  DISK_GB="$(ask "Disk size (GB)" "$DISK_GB" v_posint)"
  CORES="$(ask "CPU cores" "$CORES" v_posint)"
  MEMORY_MB="$(ask "Memory (MB)" "$MEMORY_MB" v_posint)"
  BRIDGE="$(ask_choice "Network bridge" "$BRIDGE" "$(bridge_options)")"

  if ask_yesno "Assign a static IP?" "$PREFER_STATIC"; then
    STATIC_CIDR="$(ask "Static address (CIDR)" "$STATIC_CIDR" v_cidr)"
    GATEWAY="$(ask "Gateway" "${GATEWAY:-$(host_gateway)}" v_ip)"
  else
    STATIC_CIDR=""
    GATEWAY=""
  fi

  svc_prompt
}

confirm_plan() {
  if ! wizard_wanted; then
    plan_lines | print_summary_box "$C_INFO"
    return 0
  fi
  while true; do
    plan_lines | print_summary_box "$C_INFO"
    if ask_yesno "Create with these settings?" "y"; then
      return 0
    fi
    configure_interactive
  done
}

do_create() {
  require_pve_host
  local arch template net_arg ip

  arch="$(resolve_arch)"
  ROOTFS_STORAGE="$(resolve_storage rootdir "$ROOTFS_STORAGE" "local-lvm local-zfs local")"
  TEMPLATE_STORAGE="$(resolve_storage vztmpl "$TEMPLATE_STORAGE" "local")"
  CTID="$(resolve_ctid)"

  confirm_plan

  template="$(ensure_template "$arch")"
  net_arg="$(build_net_arg)"

  info "target: CT ${CTID} (${CT_HOSTNAME}) on ${arch}, rootfs ${ROOTFS_STORAGE}"

  create_container "$CTID" "$template" "$net_arg"
  wait_for_network "$CTID"
  run_step "pushing management script" push_manage_script "$CTID"

  info "installing ${SERVICE_NAME}"
  svc_install_args
  pct_exec_manage "$CTID" install ${SVC_INSTALL_ARGS[@]+"${SVC_INSTALL_ARGS[@]}"}

  ip="$(container_ip "$CTID")"
  svc_post_create "$CTID" "${ip:-}"
  summary "$CTID" "${ip:-<CT-ip>}"
}

# The agent inside the container has already printed a precise explanation by
# the time it exits non-zero. Letting that bubble into the ERR trap appends a
# second, contentless "failed at line 749" underneath it, which reads like a
# crash rather than the deliberate refusal it is. Pass the status through
# instead.
pct_exec_manage() {
  local ctid="$1"; shift
  local rc=0
  pct exec "$ctid" -- "$MANAGE_PATH" "$@" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    trap - ERR
    exit "$rc"
  fi
}

do_manage() {
  local ctid="$1" action="$2"; shift 2
  require_pve_host
  require_ctid_exists "$ctid"
  push_manage_script "$ctid"
  pct_exec_manage "$ctid" "$action" "$@"
}

pvs_main() {
  local cmd
  banner
  if [[ $# -eq 0 || "$1" == -* ]]; then
    cmd="create"
  else
    cmd="$1"; shift
  fi

  case "$cmd" in
    create)
      parse_create_args "$@"
      do_create
      ;;
    update|uninstall|status)
      [[ $# -ge 1 ]] || die "usage: ${PVS_SCRIPT_FILENAME} ${cmd} <ctid> [options]"
      local ctid="$1"; shift
      do_manage "$ctid" "$cmd" "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $cmd (see --help)"
      ;;
  esac
}
