#!/usr/bin/env bash
#
# build.sh — stitch src/ into the single-file scripts users actually download.
#
# The contract with users is "one file, nothing else to fetch, no dependencies".
# The contract with us is "fix a Proxmox bug in one place, not in N scripts".
# This resolves the two: shared code lives in src/lib/, each service is a thin
# src/<category>/<service>/main.sh, and the built result in <category>/ is a
# flat, self-contained script with everything inlined.
#
# Usage:
#   ./build.sh                 build everything
#   ./build.sh adguardhome     build one service
#   ./build.sh --check         verify committed scripts match src/ (CI-friendly)
#   ./build.sh --lint          shellcheck the built scripts, if available
#   ./build.sh --list          list known services
#
# Directives understood in source files:
#   # @usage                   -> bakes this file's header comment into a
#                                 pvs_usage_text function (runtime $0 is
#                                 unreadable when run via bash <(curl ...))
#   # @include <path>          -> inline src/<path>, recursively
#   # @embed <path> AS <fn>    -> inline src/<path> as a function that cats it,
#                                 for scripts pushed into the container

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
RAW_BASE="https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main"

ENTRY=""

err() { printf 'build: %s\n' "$1" >&2; exit 1; }

suffix_for() {
  case "$1" in
    ct-lxc) printf -- '-lxc.sh' ;;
    vm)     printf -- '-vm.sh' ;;
    *)      printf -- '.sh' ;;
  esac
}

# The leading comment block of a file, minus the shebang, minus the "# ".
header_doc() {
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^#[ ]?/,""); print; next} {exit}' "$1"
}

# 1-based line number of the first line that is neither shebang nor header
# comment — i.e. where the actual code starts.
body_start() {
  awk 'NR==1 && /^#!/ {next} /^#/ {next} {print NR; exit}' "$1"
}

# Emits the file as a function that cats a quoted heredoc, rather than as a
# VAR="$(cat <<EOF ...)" string. Both work on bash 5, but bash 3.2 (which is
# what macOS ships, and therefore what this gets developed against) mis-parses
# heredocs nested inside command substitution once there is more than one of
# them in a file. A plain function body has no such problem.
emit_embed_fn() {
  local fn="$1" file="$2" term
  term="EOF_$(printf '%s' "$fn" | tr '[:lower:]' '[:upper:]')"
  if grep -qx "$term" "$file"; then
    err "$file contains a line equal to the heredoc terminator '$term'"
  fi
  printf '%s() {\n' "$fn"
  printf 'cat <<%s\n' "'$term'"
  expand "$file" 0
  printf '%s\n}\n' "$term"
}

expand() {
  local file="$1" depth="$2" lineno=0 line inc spec path var
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$(( lineno + 1 ))
    if (( lineno == 1 )) && [[ "$line" == '#!'* ]] && (( depth > 0 )); then
      continue
    fi
    case "$line" in
      '# @include '*)
        inc="${line#"# @include "}"
        [[ -f "$SRC/$inc" ]] || err "missing include '$inc' (referenced by $file)"
        expand "$SRC/$inc" $(( depth + 1 ))
        ;;
      '# @embed '*)
        spec="${line#"# @embed "}"
        path="${spec%% AS *}"
        var="${spec##* AS }"
        [[ -f "$SRC/$path" ]] || err "missing embed '$path' (referenced by $file)"
        emit_embed_fn "$var" "$SRC/$path"
        ;;
      '# @usage')
        printf 'pvs_usage_text() {\n'
        printf 'cat <<%s\n' "'EOF_PVS_USAGE'"
        header_doc "$ENTRY"
        printf 'EOF_PVS_USAGE\n}\n'
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done < "$file"
}

render() {
  local entry="$1" filename="$2" relsrc="$3" url="$4" start
  ENTRY="$entry"
  start="$(body_start "$entry")"
  [[ -n "$start" ]] || err "$entry has a header but no code"

  printf '#!/usr/bin/env bash\n'
  header_doc "$entry" | sed 's/^/# /; s/^# $/#/'
  printf '#\n'
  printf '# ---------------------------------------------------------------------------\n'
  printf '# GENERATED FILE - DO NOT EDIT.\n'
  printf '# Built by build.sh from %s and src/lib/*.sh.\n' "$relsrc"
  printf '# Edit the source, then run ./build.sh. See CONTRIBUTING.md.\n'
  printf '# ---------------------------------------------------------------------------\n'
  printf '\n'
  printf 'PVS_SCRIPT_FILENAME=%s\n' "\"$filename\""
  printf 'PVS_SCRIPT_URL=%s\n' "\"$url\""
  printf '\n'
  tail -n "+${start}" "$entry" | sed '/./,$!d' > "$ROOT/.build-body.tmp"
  expand "$ROOT/.build-body.tmp" 1
  rm -f "$ROOT/.build-body.tmp"
}

# Prints one tab-separated row per service:
#   category  service  entry  outpath  filename  url  name  tagline  aliases
each_service() {
  local entry category service filename out name tagline aliases
  for entry in "$SRC"/*/*/main.sh; do
    [[ -f "$entry" ]] || continue
    service="$(basename "$(dirname "$entry")")"
    category="$(basename "$(dirname "$(dirname "$entry")")")"
    [[ "$category" == "lib" ]] && continue
    [[ "$service" == _* ]] && continue
    filename="${service}$(suffix_for "$category")"
    out="$ROOT/$category/$filename"
    name="$(sed -n 's/^SERVICE_NAME="\(.*\)"$/\1/p' "$entry" | head -n1)"
    tagline="$(sed -n 's/^# @tagline //p' "$entry" | head -n1)"
    aliases="$(sed -n 's/^# @alias //p' "$entry" | tr '\n' ' ' | sed 's/ *$//')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$category" "$service" "$entry" "$out" "$filename" "$RAW_BASE/$category/$filename" \
      "${name:-$service}" "$tagline" "$aliases"
  done
}

# A shim kept at an old path so links handed out before a rename keep working.
# It cannot just be a copy — that would silently go stale — so it fetches the
# current script instead, and says plainly that the path moved.
render_alias_shim() {
  local alias_name="$1" url="$2" newfile="$3"
  printf '#!/usr/bin/env bash\n'
  printf '#\n'
  printf '# %s-lxc.sh — deprecated path, kept so existing links keep working.\n' "$alias_name"
  printf '# The script now lives at %s\n' "$newfile"
  printf '#\n'
  printf '# GENERATED FILE - DO NOT EDIT. Built by build.sh.\n'
  printf '# @pvs-shim\n'
  printf '\n'
  printf 'set -Eeuo pipefail\n'
  printf 'printf "note: this path has moved to %s — update your bookmark.\\n" >&2\n' "$newfile"
  printf 'command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }\n'
  printf 'exec bash <(curl -fsSL "%s") "$@"\n' "$url"
}

# Generates the repo-root install.sh: one stable URL that can reach every
# script, so the command people are given never has to change when a service is
# added. The catalogue is baked in at build time rather than fetched, because a
# menu that needs a second network round-trip to render is a menu that hangs.
render_install() {
  local category service entry out filename url name tagline

  printf '#!/usr/bin/env bash\n'
  printf '#\n'
  printf '# install.sh — pick a service and run its script.\n'
  printf '#\n'
  printf '#   bash <(curl -fsSL %s/install.sh)\n' "$RAW_BASE"
  printf '#   bash <(curl -fsSL %s/install.sh) adguardhome --static 192.168.1.53/24 --gateway 192.168.1.1\n' "$RAW_BASE"
  printf '#\n'
  printf '# With no arguments it shows a menu. With a service name it runs that\n'
  printf '# script directly, passing everything after the name straight through.\n'
  printf '#\n'
  printf '# ---------------------------------------------------------------------------\n'
  printf '# GENERATED FILE - DO NOT EDIT. Built by build.sh from the src/ tree.\n'
  printf '# ---------------------------------------------------------------------------\n'
  printf '\n'
  printf 'set -Eeuo pipefail\n\n'
  printf 'PVS_BASE="%s"\n\n' "$RAW_BASE"
  printf '# id|name|tagline|path|aliases\n'
  printf 'PVS_CATALOG="\n'
  while IFS=$'\t' read -r category service entry out filename url name tagline aliases; do
    printf '%s|%s|%s|%s/%s|%s\n' "$service" "$name" "$tagline" "$category" "$filename" "$aliases"
  done < <(each_service)
  printf '"\n'

  cat <<'EOF_INSTALL'

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
EOF_INSTALL
}

build_all() {
  local only="${1:-}" built=0 a category service entry out filename url
  while IFS=$'\t' read -r category service entry out filename url name tagline aliases; do
    [[ -n "$only" && "$service" != "$only" ]] && continue
    mkdir -p "$(dirname "$out")"
    render "$entry" "$filename" "${entry#"$ROOT/"}" "$url" > "$out"
    chmod +x "$out"
    bash -n "$out" || err "$out failed syntax check"
    printf '  built  %-14s -> %s/%s\n' "$service" "$category" "$filename"
    built=$(( built + 1 ))
    for a in $aliases; do
      render_alias_shim "$a" "$url" "$category/$filename" > "$ROOT/$category/${a}$(suffix_for "$category")"
      chmod +x "$ROOT/$category/${a}$(suffix_for "$category")"
      printf '  shim   %-14s -> %s/%s%s\n' "$a" "$category" "$a" "$(suffix_for "$category")"
      built=$(( built + 1 ))
    done
  done < <(each_service)
  [[ "$built" -eq 0 ]] && err "nothing built${only:+ (no service named '$only')}"
  render_install > "$ROOT/install.sh"
  chmod +x "$ROOT/install.sh"
  bash -n "$ROOT/install.sh" || err "install.sh failed syntax check"
  printf '  built  %-14s -> install.sh\n' "dispatcher"
  printf '%d script(s) built.\n' "$(( built + 1 ))"
}

check_all() {
  local stale=0 a shim category service entry out filename url tmp tmp2
  tmp="$(mktemp)"
  tmp2="$(mktemp)"
  while IFS=$'\t' read -r category service entry out filename url name tagline aliases; do
    render "$entry" "$filename" "${entry#"$ROOT/"}" "$url" > "$tmp"
    if [[ ! -f "$out" ]]; then
      printf '  MISSING  %s/%s\n' "$category" "$filename"; stale=1
    elif ! diff -q "$tmp" "$out" >/dev/null; then
      printf '  STALE    %s/%s\n' "$category" "$filename"; stale=1
    else
      printf '  ok       %s/%s\n' "$category" "$filename"
    fi
    for a in $aliases; do
      shim="$ROOT/$category/${a}$(suffix_for "$category")"
      render_alias_shim "$a" "$url" "$category/$filename" > "$tmp2"
      if [[ ! -f "$shim" ]]; then
        printf '  MISSING  %s/%s (alias)\n' "$category" "$(basename "$shim")"; stale=1
      elif ! diff -q "$tmp2" "$shim" >/dev/null; then
        printf '  STALE    %s/%s (alias)\n' "$category" "$(basename "$shim")"; stale=1
      else
        printf '  ok       %s/%s (alias)\n' "$category" "$(basename "$shim")"
      fi
    done
  done < <(each_service)
  render_install > "$tmp"
  if [[ ! -f "$ROOT/install.sh" ]]; then
    printf '  MISSING  install.sh\n'; stale=1
  elif ! diff -q "$tmp" "$ROOT/install.sh" >/dev/null; then
    printf '  STALE    install.sh\n'; stale=1
  else
    printf '  ok       install.sh\n'
  fi
  rm -f "$tmp" "$tmp2"
  if [[ "$stale" -eq 1 ]]; then
    printf 'Built scripts are out of date. Run ./build.sh\n' >&2
    exit 1
  fi
  printf 'All built scripts match src/.\n'
}

lint_all() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'shellcheck not installed — skipping (brew install shellcheck)\n' >&2
    return 0
  fi
  local category service entry out filename url rc=0
  while IFS=$'\t' read -r category service entry out filename url name tagline aliases; do
    [[ -f "$out" ]] || continue
    printf '  linting %s\n' "$out"
    shellcheck -S warning "$out" || rc=1
  done < <(each_service)
  return "$rc"
}

case "${1:-}" in
  --check) check_all ;;
  --lint)  lint_all ;;
  --list)  each_service | awk -F'\t' '{printf "  %-14s %s/%s\n", $2, $1, $5}' ;;
  -h|--help) header_doc "$0" ;;
  "")      build_all ;;
  -*)      err "unknown option: $1 (see --help)" ;;
  *)       build_all "$1" ;;
esac
