#!/usr/bin/env bash
#
# tests/smoke.sh — what can be checked without a Proxmox host.
#
# It cannot verify that a container actually boots; it can verify that every
# built script parses, that its embedded in-container agent parses, that help
# works, that the dispatcher rejects nonsense, and that the committed scripts
# still match src/. That covers the failure mode that actually bites: a build
# or quoting mistake that only shows up after you've already pasted the
# one-liner into a PVE shell.

# Deliberately no `set -e`: this suite runs commands that are *supposed* to
# fail, and needs to inspect their exit codes rather than die on them.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$(( FAIL + 1 )); }
check() { if [[ "$1" -eq 0 ]]; then pass "$2"; else fail "$2"; fi; }

# Sourcing a built script would run it; drop the final `pvs_main "$@"` line so
# its functions can be poked at in isolation.
loadable() {
  local script="$1" out="$TMP/loadable.sh"
  sed '$d' "$script" > "$out"
  printf '%s' "$out"
}

printf '\nBuild is current\n'
"$ROOT/build.sh" --check >/dev/null 2>&1
check $? "committed scripts match src/"

printf '\nBuilt scripts\n'
shopt -s nullglob
scripts=( "$ROOT"/ct-lxc/*.sh "$ROOT"/vm/*.sh "$ROOT"/misc/*.sh )
if [[ ${#scripts[@]} -eq 0 ]]; then
  fail "no built scripts found — run ./build.sh"
fi

is_shim() { grep -q '^# @pvs-shim$' "$1"; }

for script in ${scripts[@]+"${scripts[@]}"}; do
  name="$(basename "$script")"

  # Deprecated-path shims are three lines that fetch the real script; the
  # checks below (help text, embedded agent, summary box) do not apply, and
  # running them would hit the network.
  if is_shim "$script"; then
    bash -n "$script" 2>/dev/null
    check $? "$name (shim) parses"
    target="$(sed -n 's|.*/main/\(.*\)") "\$@"|\1|p' "$script" | head -n1)"
    if [[ -n "$target" && -f "$ROOT/$target" ]]; then
      pass "$name (shim) points at $target"
    else
      fail "$name (shim) points at a missing target: ${target:-<unparsed>}"
    fi
    continue
  fi

  bash -n "$script" 2>/dev/null
  check $? "$name parses"

  [[ -x "$script" ]]
  check $? "$name is executable"

  # Help must work with no Proxmox anywhere in sight.
  rc=0; "$script" --help >"$TMP/help.txt" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]] && grep -q "Usage:" "$TMP/help.txt"; then pass "$name --help works"
  else fail "$name --help works (exit $rc)"; fi

  rc=0; "$script" definitely-not-a-command >"$TMP/bad.txt" 2>&1 || rc=$?
  if [[ $rc -ne 0 ]] && grep -q "unknown command" "$TMP/bad.txt"; then pass "$name rejects unknown commands"
  else fail "$name rejects unknown commands (exit $rc)"; fi

  lib="$(loadable "$script")"

  # The agent is a whole second script living inside a heredoc — a stray
  # terminator or a quoting slip there is invisible until it hits a container.
  ( set +u; source "$lib" >/dev/null 2>&1; manage_script ) > "$TMP/agent.sh" 2>/dev/null
  if [[ -s "$TMP/agent.sh" ]]; then
    bash -n "$TMP/agent.sh" 2>/dev/null
    check $? "$name embedded agent parses"
    head -1 "$TMP/agent.sh" | grep -q '^#!' 
    check $? "$name embedded agent keeps its shebang"
  else
    fail "$name embedded agent is empty"
  fi

  # Every line of the summary box must be the same width, or it looks broken
  # in the one place a user is guaranteed to be reading: the final output.
  widths="$(
    ( set +u
      source "$lib" >/dev/null 2>&1
      CT_HOSTNAME="test"
      summary 999 "192.168.1.53" 2>/dev/null
    ) | sed 's/\x1b\[[0-9;]*m//g' | grep -c '.' >/dev/null 2>&1 || true
    ( set +u
      source "$lib" >/dev/null 2>&1
      CT_HOSTNAME="test"
      summary 999 "192.168.1.53" 2>/dev/null
    ) | sed 's/\x1b\[[0-9;]*m//g' | awk 'NF {print length($0)}' | sort -u | wc -l
  )"
  [[ "$(echo "$widths" | tr -d ' ')" == "1" ]]
  check $? "$name summary box is aligned"
done

# The spinner only runs when stdout is a terminal, so piping a script's output
# anywhere (which every check above does) skips that code entirely. That is
# exactly how a `set -e` fatal inside the spinner loop shipped. Allocate a real
# pty so this path is actually exercised.
# script(1) needs a controlling terminal of its own, which CI runners and
# sandboxes often lack; openpty does not. Python is only used to hand the
# script under test a genuine tty on stdout — nothing else depends on it.
run_in_pty() {
  python3 - "$1" <<'PY_EOF'
import os, pty, subprocess, sys

master, slave = pty.openpty()
proc = subprocess.Popen(["bash", "-c", sys.argv[1]],
                        stdout=slave, stderr=slave,
                        stdin=subprocess.DEVNULL, close_fds=True)
os.close(slave)
chunks = []
while True:
    try:
        data = os.read(master, 4096)
    except OSError:
        break
    if not data:
        break
    chunks.append(data)
os.close(master)
sys.stdout.write(b"".join(chunks).decode("utf-8", "replace"))
sys.exit(proc.wait())
PY_EOF
}

printf '\nInteractive (pty) paths\n'
if ! command -v python3 >/dev/null 2>&1; then
  printf '  \033[33mskip\033[0m python3 not available — pty paths untested\n'
else
  for script_path in ${scripts[@]+"${scripts[@]}"}; do
    is_shim "$script_path" && continue
    name="$(basename "$script_path")"
    lib="$(loadable "$script_path")"

    out="$(run_in_pty "set -Eeuo pipefail; source '$lib' >/dev/null 2>&1; run_step 'spinner check' sleep 0.4" 2>&1 || true)"
    if printf '%s' "$out" | grep -q '\[+\] spinner check'; then
      pass "$name run_step succeeds on a tty"
    else
      fail "$name run_step succeeds on a tty (got: $(printf '%s' "$out" | tr -d '\r' | tail -1))"
    fi

    # A failing step must report the failure and surface the captured output,
    # not vanish behind the spinner.
    out="$(run_in_pty "set -Eeuo pipefail; source '$lib' >/dev/null 2>&1; run_step 'failing step' bash -c 'echo NEEDLE >&2; exit 3'" 2>&1 || true)"
    if printf '%s' "$out" | grep -q '\[x\] failing step' && printf '%s' "$out" | grep -q 'NEEDLE'; then
      pass "$name run_step reports failure and its output on a tty"
    else
      fail "$name run_step reports failure and its output on a tty"
    fi
  done
fi

printf '\nDispatcher\n'
bash -n "$ROOT/install.sh" 2>/dev/null
check $? "install.sh parses"

rc=0; "$ROOT/install.sh" --list >"$TMP/list.txt" 2>&1 || rc=$?
if [[ $rc -eq 0 ]] && grep -q "Available:" "$TMP/list.txt"; then pass "install.sh --list works"
else fail "install.sh --list works (exit $rc)"; fi

rc=0; "$ROOT/install.sh" nosuchservice >"$TMP/bad.txt" 2>&1 || rc=$?
if [[ $rc -ne 0 ]] && grep -q "unknown service" "$TMP/bad.txt"; then pass "install.sh rejects unknown services"
else fail "install.sh rejects unknown services (exit $rc)"; fi

# A catalogue entry pointing at a path that does not exist would only fail once
# someone had already pasted the command into a PVE shell.
missing=0
while IFS='|' read -r id name tagline path aliases; do
  [[ -n "${path:-}" ]] || continue
  if [[ ! -f "$ROOT/$path" ]]; then
    fail "install.sh catalogue points at missing $path"
    missing=1
  fi
done < <(sed -n '/^PVS_CATALOG="$/,/^"$/p' "$ROOT/install.sh" | grep '|')
[[ "$missing" -eq 0 ]] && pass "install.sh catalogue paths all exist"

printf '\nSource files\n'
for f in "$ROOT"/src/lib/*.sh "$ROOT"/src/*/*/*.sh; do
  [[ -f "$f" ]] || continue
  bash -n "$f" 2>/dev/null
  check $? "${f#"$ROOT/"} parses"
done

printf '\n%d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
