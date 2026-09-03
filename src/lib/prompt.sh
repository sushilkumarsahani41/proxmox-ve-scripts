#!/usr/bin/env bash
# lib/prompt.sh — interactive configuration. Every prompt offers the
# recommended value in brackets, so Enter is always a valid answer.

# Prompts read from /dev/tty, never stdin. Under `bash <(curl ...)` stdin can be
# the script itself; a `read` that swallowed it would corrupt the run in a way
# that is very hard to diagnose.
interactive() {
  [[ -t 1 ]] || return 1
  [[ -r /dev/tty ]] || return 1
  return 0
}

ask() {
  local prompt="$1" default="$2" validator="${3:-}" answer
  while true; do
    printf "  %b%s%b [%b%s%b]: " \
      "$C_BOLD" "$prompt" "$C_RESET" "$C_INFO" "$default" "$C_RESET" >&2
    IFS= read -r answer </dev/tty || { printf '\n' >&2; answer=""; }
    [[ -z "$answer" ]] && answer="$default"
    if [[ -z "$validator" ]] || "$validator" "$answer"; then
      printf '%s' "$answer"
      return 0
    fi
  done
}

ask_yesno() {
  local prompt="$1" default="${2:-y}" answer hint
  case "$default" in
    y|Y) hint="Y/n" ;;
    *)   hint="y/N" ;;
  esac
  while true; do
    printf "  %b%s%b [%b%s%b]: " \
      "$C_BOLD" "$prompt" "$C_RESET" "$C_INFO" "$hint" "$C_RESET" >&2
    IFS= read -r answer </dev/tty || answer=""
    [[ -z "$answer" ]] && answer="$default"
    case "$answer" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No)    return 1 ;;
      *) warn "please answer y or n" ;;
    esac
  done
}

# Numbered pick from a newline-separated list. Accepts either the number or the
# value typed out. With only one option there is nothing to choose, so it
# returns silently rather than asking a question with one answer.
ask_choice() {
  local prompt="$1" default="$2" options="$3" count opt i answer pick
  count="$(printf '%s\n' "$options" | grep -c . || true)"
  if [[ -z "$count" || "$count" -le 1 ]]; then
    printf '%s' "$default"
    return 0
  fi

  printf '\n' >&2
  i=1
  while IFS= read -r opt; do
    [[ -z "$opt" ]] && continue
    if [[ "$opt" == "$default" ]]; then
      printf "    %2d) %s%b  (recommended)%b\n" "$i" "$opt" "$C_DIM" "$C_RESET" >&2
    else
      printf "    %2d) %s\n" "$i" "$opt" >&2
    fi
    i=$(( i + 1 ))
  done < <(printf '%s\n' "$options" | grep .)

  while true; do
    answer="$(ask "$prompt" "$default")"
    if [[ "$answer" =~ ^[0-9]+$ ]] && [[ "$answer" -ge 1 && "$answer" -le "$count" ]]; then
      pick="$(printf '%s\n' "$options" | grep . | sed -n "${answer}p")"
      printf '%s' "$pick"
      return 0
    fi
    if printf '%s\n' "$options" | grep -qx -- "$answer"; then
      printf '%s' "$answer"
      return 0
    fi
    warn "pick a number from the list, or type the name exactly"
  done
}

# 20 alphanumeric characters from /dev/urandom — plenty of entropy (~119 bits)
# without needing openssl, and free of shell/quoting metacharacters since it
# only ever travels as a single argv element, never through eval.
#
# `|| true` is load-bearing, not decorative: `head -c 20` closes its end of the
# pipe the instant it has 20 bytes, tr is still writing when that happens, and
# writing to a reader that has hung up is SIGPIPE — exit 141. Under pipefail
# that is the pipeline's exit status, and since this runs in a bare $(...)
# substitution the ERR trap fires on it and kills the whole script. Not a rare
# edge case: it is what happens on *every* call, deterministically, because
# head always finishes first by design.
generate_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 20 || true
}

# Hidden input, confirmed twice. Loops on mismatch or on failing $2 (a
# validator), same contract as ask().
ask_secret() {
  local prompt="$1" validator="${2:-}" pass1 pass2
  while true; do
    printf "  %b%s%b: " "$C_BOLD" "$prompt" "$C_RESET" >&2
    stty -echo </dev/tty 2>/dev/null
    IFS= read -r pass1 </dev/tty || pass1=""
    stty echo </dev/tty 2>/dev/null
    printf '\n' >&2

    if [[ -z "$pass1" ]]; then
      warn "cannot be empty"
      continue
    fi
    if [[ -n "$validator" ]] && ! "$validator" "$pass1"; then
      continue
    fi

    printf "  %bConfirm%b: " "$C_BOLD" "$C_RESET" >&2
    stty -echo </dev/tty 2>/dev/null
    IFS= read -r pass2 </dev/tty || pass2=""
    stty echo </dev/tty 2>/dev/null
    printf '\n' >&2

    if [[ "$pass1" != "$pass2" ]]; then
      warn "passwords did not match"
      continue
    fi
    printf '%s' "$pass1"
    return 0
  done
}

# ---------------------------------------------------------------------------
# Validators. Each explains the problem itself, so ask() can just loop.
# ---------------------------------------------------------------------------
v_posint() {
  if [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]; then return 0; fi
  warn "must be a positive whole number"
  return 1
}

v_ctid() {
  if ! [[ "$1" =~ ^[0-9]+$ ]]; then warn "container ID must be a number"; return 1; fi
  if [[ "$1" -lt 100 ]]; then warn "container IDs start at 100"; return 1; fi
  if pct status "$1" >/dev/null 2>&1; then warn "container $1 already exists"; return 1; fi
  return 0
}

v_hostname() {
  if [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then return 0; fi
  warn "letters, digits and hyphens only, and it cannot start or end with a hyphen"
  return 1
}

v_cidr() {
  if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then return 0; fi
  warn "needs an address *and* a prefix length, e.g. 192.168.1.53/24"
  return 1
}

v_password() {
  if [[ ${#1} -ge 8 ]]; then return 0; fi
  warn "must be at least 8 characters"
  return 1
}

v_ip() {
  if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 0; fi
  warn "expected an IPv4 address, e.g. 192.168.1.1"
  return 1
}
