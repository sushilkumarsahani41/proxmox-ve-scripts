#!/usr/bin/env bash
#
# myservice-lxc.sh — My Service on Proxmox VE, create to teardown.
# Run this on a PVE host, as root.
#
#   create              Create a Debian LXC (newest Debian template the host
#                       has or can fetch, matching its own architecture) and
#                       install My Service inside it
#   update <ctid>       Update My Service in an existing container
#   uninstall <ctid>    Remove My Service (--purge also wipes config/data)
#   status <ctid>       Show version + service state
#
# Usage:
#   ./myservice-lxc.sh create [options]
#   ./myservice-lxc.sh update <ctid>
#   ./myservice-lxc.sh uninstall <ctid> [--purge]
#   ./myservice-lxc.sh status <ctid>
#
# create options:
#   -i, --id <id>          Container ID (default: next free ID)
#   -n, --hostname <name>  Container hostname (default: myservice)
#   -s, --storage <name>   Storage for the rootfs (default: auto-detected)
#   -t, --template-storage <name>  Storage for CT templates (default: auto-detected)
#   -b, --bridge <name>    Network bridge (default: vmbr0)
#   -d, --disk <GB>        Disk size in GB (default: 4)
#   -c, --cores <n>        CPU cores (default: 1)
#   -m, --memory <MB>      RAM in MB (default: 512)
#   --static <cidr>        Static IP, e.g. 192.168.1.50/24 (default: dhcp)
#   --gateway <ip>         Gateway, required with --static
#   --template <spec>      Skip template auto-detection, e.g.
#                           local:vztmpl/debian-13-standard_13.6-1_arm64.tar.zst
#
# This whole comment block becomes --help output, so keep it accurate: the
# `# @usage` directive below bakes it into the built script verbatim.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Service definition
# ---------------------------------------------------------------------------
SERVICE_ID="myservice"          # used for /usr/local/sbin/<id>-manage.sh
SERVICE_NAME="My Service"       # shown in the banner and summary

DEFAULT_HOSTNAME="myservice"
DEFAULT_DISK_GB="4"
DEFAULT_CORES="1"
DEFAULT_MEMORY_MB="512"

# Optional, only if the defaults don't suit:
#   DEFAULT_ROOTFS_STORAGE="local-lvm"    # default: auto-detected
#   DEFAULT_TEMPLATE_STORAGE="local"      # default: auto-detected
#   DEFAULT_TEMPLATE_PATTERN="debian-13-standard"   # pin a major version
#   DEFAULT_BRIDGE="vmbr0"
#   DEFAULT_UNPRIVILEGED="1"     # 0 for things needing host devices
#   DEFAULT_NESTING="0"          # 1 for anything running Docker inside

# @usage
# @embed ct-lxc/_template/manage.sh AS manage_script
# @include lib/ui.sh
# @include lib/pve.sh
# @include lib/main.sh

# ---------------------------------------------------------------------------
# Service hooks — delete any you don't need, the defaults are no-ops
# ---------------------------------------------------------------------------

# Handle a service-specific flag. Set SVC_OPT_SHIFT to how many argv entries
# it ate and return 0; return 1 to let the caller reject it as unknown.
# svc_parse_option() {
#   case "$1" in
#     --version)
#       [[ -n "${2:-}" ]] || die "--version needs a value"
#       APP_VERSION="$2"; SVC_OPT_SHIFT=2; return 0 ;;
#   esac
#   return 1
# }

# Extra arguments passed to `<manage.sh> install` inside the container.
# svc_install_args() { SVC_INSTALL_ARGS=(--version "$APP_VERSION"); }

# Extra " label : value" lines for the closing summary box. $1=ctid $2=ip
svc_summary_lines() {
  echo " Web UI       : http://${2}:8080"
}

# Anything to do on the PVE host after install. $1=ctid $2=ip
# svc_post_create() { :; }

pvs_main "$@"
