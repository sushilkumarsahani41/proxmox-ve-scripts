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

# Prints "<category> <service> <entry> <outpath> <filename> <url>" per service.
each_service() {
  local entry category service filename out
  for entry in "$SRC"/*/*/main.sh; do
    [[ -f "$entry" ]] || continue
    service="$(basename "$(dirname "$entry")")"
    category="$(basename "$(dirname "$(dirname "$entry")")")"
    [[ "$category" == "lib" ]] && continue
    [[ "$service" == _* ]] && continue
    filename="${service}$(suffix_for "$category")"
    out="$ROOT/$category/$filename"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$category" "$service" "$entry" "$out" "$filename" "$RAW_BASE/$category/$filename"
  done
}

build_all() {
  local only="${1:-}" built=0 category service entry out filename url
  while IFS=$'\t' read -r category service entry out filename url; do
    [[ -n "$only" && "$service" != "$only" ]] && continue
    mkdir -p "$(dirname "$out")"
    render "$entry" "$filename" "${entry#"$ROOT/"}" "$url" > "$out"
    chmod +x "$out"
    bash -n "$out" || err "$out failed syntax check"
    printf '  built  %-14s -> %s/%s\n' "$service" "$category" "$filename"
    built=$(( built + 1 ))
  done < <(each_service)
  [[ "$built" -eq 0 ]] && err "nothing built${only:+ (no service named '$only')}"
  printf '%d script(s) built.\n' "$built"
}

check_all() {
  local stale=0 category service entry out filename url tmp
  tmp="$(mktemp)"
  while IFS=$'\t' read -r category service entry out filename url; do
    render "$entry" "$filename" "${entry#"$ROOT/"}" "$url" > "$tmp"
    if [[ ! -f "$out" ]]; then
      printf '  MISSING  %s/%s\n' "$category" "$filename"; stale=1
    elif ! diff -q "$tmp" "$out" >/dev/null; then
      printf '  STALE    %s/%s\n' "$category" "$filename"; stale=1
    else
      printf '  ok       %s/%s\n' "$category" "$filename"
    fi
  done < <(each_service)
  rm -f "$tmp"
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
  while IFS=$'\t' read -r category service entry out filename url; do
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
