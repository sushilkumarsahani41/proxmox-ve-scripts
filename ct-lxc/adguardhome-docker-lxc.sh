#!/usr/bin/env bash
#
# adguardhome-docker-lxc.sh — deprecated path, kept so existing links keep working.
# The script now lives at ct-lxc/adguard-home-docker-lxc.sh
#
# GENERATED FILE - DO NOT EDIT. Built by build.sh.
# @pvs-shim

set -Eeuo pipefail
printf "note: this path has moved to ct-lxc/adguard-home-docker-lxc.sh — update your bookmark.\n" >&2
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
exec bash <(curl -fsSL "https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/ct-lxc/adguard-home-docker-lxc.sh") "$@"
