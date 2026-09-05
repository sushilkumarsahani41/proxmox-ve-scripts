#!/usr/bin/env bash
#
# install.sh — pick a service and run its script.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/install.sh)
#   bash <(curl -fsSL https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/install.sh) adguardhome --static 192.168.1.53/24 --gateway 192.168.1.1
#
# With no arguments it shows a menu. With a service name it runs that
# script directly, passing everything after the name straight through.
#
# ---------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT. Built by build.sh from the src/ tree.
# ---------------------------------------------------------------------------

set -Eeuo pipefail

PVS_BASE="https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main"

# id|name|tagline|path|aliases
PVS_CATALOG="
adguard-home|AdGuard Home|Network-wide DNS ad and tracker blocking|ct-lxc/adguard-home-lxc.sh|adguardhome
floci|Floci|Free local AWS/Azure/GCP emulator with a web console|ct-lxc/floci-lxc.sh|
pi-hole|Pi-hole|The original network-wide DNS ad blocker|ct-lxc/pi-hole-lxc.sh|pihole
sharkshell|SharkShell|Self-hosted web SSH client with 2FA and an MCP server|ct-lxc/sharkshell-lxc.sh|
"

if [[ -t 1 ]]; then
  C_BRAND="\033[1;36m"; C_DIM="\033[2m"; C_BOLD="\033[1m"
  C_OK="\033[32m"; C_ERR="\033[31m"; C_RESET="\033[0m"
else
  C_BRAND=""; C_DIM=""; C_BOLD=""; C_OK=""; C_ERR=""; C_RESET=""
fi

die() { printf "%b[x]%b %s\n" "$C_ERR" "$C_RESET" "$1" >&2; exit 1; }

banner() {
  [[ -t 1 ]] && clear
  printf "%b%s%b\n" "$C_BRAND" ' _____ ______ _____  ___ _____ _____ _   _   ___  ______ _   __
|  __ \| ___ \  ___|/ _ \_   _/  ___| | | | / _ \ | ___ \ | / /
| |  \/| |_/ / |__ / /_\ \| | \ `--.| |_| |/ /_\ \| |_/ / |/ /
| | __ |    /|  __||  _  || |  `--. \  _  ||  _  ||    /|    \
| |_\ \| |\ \| |___| | | || | /\__/ / | | || | | || |\ \| |\  \
 \____/\_| \_\____/\_| |_/\_/ \____/\_| |_/\_| |_/\_| \_\_| \_/' "$C_RESET"
  printf "%b%s%b\n" "$C_BOLD" "                    T E C H N O L O G I E S" "$C_RESET"
  printf "%b%s%b\n" "$C_DIM"  "                  Proxmox VE Automation" "$C_RESET"
  printf "%b%s%b\n" "$C_DIM"  "---------------------------------------------------------------" "$C_RESET"
}

catalog_rows() { printf '%s\n' "$PVS_CATALOG" | grep -v '^$'; }

# Matches the canonical id first, then any alias, so a link handed out under an
# older name still resolves.
path_for() {
  catalog_rows | awk -F'|' -v want="$1" '
    $1 == want { print $4; exit }
    {
      n = split($5, a, " ")
      for (i = 1; i <= n; i++) if (a[i] == want) { print $4; exit }
    }'
}

list_services() {
  printf '\n%bAvailable:%b\n\n' "$C_BOLD" "$C_RESET"
  catalog_rows | awk -F'|' '{printf "  %-16s %s\n", $1, $3}'
  printf '\n'
}

# Runs the chosen script straight from its own URL rather than saving it, so
# that script sees $0 as a pipe and prints its own accurate "save a copy to
# manage this later" advice, pointing at its own direct URL rather than at a
# temp file that will not exist tomorrow.
run_service() {
  local id="$1"; shift
  local path
  path="$(path_for "$id")"
  [[ -n "$path" ]] || { list_services; die "unknown service: ${id}"; }
  exec bash <(curl -fsSL "${PVS_BASE}/${path}") "$@"
}

menu() {
  local ids count choice
  ids="$(catalog_rows | awk -F'|' '{print $1}')"
  count="$(printf '%s\n' "$ids" | grep -c .)"

  printf '\n%bWhat do you want to install?%b\n\n' "$C_BOLD" "$C_RESET"
  catalog_rows | awk -F'|' '{printf "  %2d) %-16s %s\n", NR, $2, $3}'
  printf '\n   q) quit\n\n'

  # Read from the terminal explicitly: stdin is the script itself under
  # `curl | bash`, and would otherwise be consumed or empty.
  printf 'Choice [1-%s]: ' "$count"
  read -r choice </dev/tty || die "no terminal to read a choice from — pass a service name instead"

  case "$choice" in
    q|Q|"") printf 'Nothing to do.\n'; exit 0 ;;
    *[!0-9]*) die "not a number: ${choice}" ;;
  esac
  [[ "$choice" -ge 1 && "$choice" -le "$count" ]] || die "choose between 1 and ${count}"

  run_service "$(printf '%s\n' "$ids" | sed -n "${choice}p")"
}

main() {
  case "${1:-}" in
    -l|--list|list) banner; list_services; exit 0 ;;
    -h|--help|help)
      banner
      printf '\n  bash <(curl -fsSL %s/install.sh)              interactive menu\n' "$PVS_BASE"
      printf '  bash <(curl -fsSL %s/install.sh) <service>    run one directly\n' "$PVS_BASE"
      printf '\n  Anything after <service> is passed straight to that script,\n'
      printf '  so --help and every create option work as normal.\n'
      list_services
      exit 0 ;;
  esac

  command -v curl >/dev/null 2>&1 || die "curl is required"

  # Only the menu draws a banner. When a service is named outright, the script
  # being launched draws its own combined header a moment later, and drawing
  # one here first would just flash a banner off the screen.
  if [[ $# -eq 0 ]]; then
    banner
    menu
  else
    local id="$1"; shift
    run_service "$id" "$@"
  fi
}

main "$@"
