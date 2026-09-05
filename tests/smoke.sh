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

  # summary()'s "you ran this from a pipe" hint is status text for a human,
  # like every info/ok/warn message in this project — it must never reach
  # stdout, only stderr. Found the hard way: it was a bare printf with no
  # redirect, invisible to the check above because ran_from_file() is true
  # whenever $0 ends in .sh, which it always does when this suite runs via
  # `./tests/smoke.sh` — so that check never actually took the pipe branch
  # locally. Force it here by overriding ran_from_file after sourcing, so
  # this asserts the real invariant (nothing but the box on stdout) instead
  # of one that happens to hold under how this suite itself gets invoked.
  pipe_stdout="$(
    ( set +u
      source "$lib" >/dev/null 2>&1
      ran_from_file() { return 1; }
      CT_HOSTNAME="test"
      summary 999 "192.168.1.53" 2>/dev/null
    ) | sed 's/\x1b\[[0-9;]*m//g' | awk 'NF {print length($0)}' | sort -u | wc -l
  )"
  [[ "$(echo "$pipe_stdout" | tr -d ' ')" == "1" ]]
  check $? "$name summary stays box-only on stdout even when run from a pipe"
done

# The spinner only runs when stdout is a terminal, so piping a script's output
# anywhere (which every check above does) skips that code entirely. That is
# exactly how a `set -e` fatal inside the spinner loop shipped. Allocate a real
# pty so this path is actually exercised.
# script(1) needs a controlling terminal of its own, which CI runners and
# sandboxes often lack; a bare openpty() does not grant one either — a plain
# subprocess with the pty fds dup'd onto it never becomes the session's
# controlling terminal, so a bash `read ... </dev/tty` inside it just hangs.
# forkpty() does the setsid+TIOCSCTTY dance needed, so use it for anything
# that only needs a tty on stdout (run_step's spinner) with stdin closed.
run_in_pty() {
  python3 - "$1" <<'PY_EOF'
import os, pty, sys

pid, master = pty.fork()
if pid == 0:
    os.close(0)
    os.execvp("bash", ["bash", "-c", sys.argv[1]])
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
_, status = os.waitpid(pid, 0)
sys.stdout.write(b"".join(chunks).decode("utf-8", "replace"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PY_EOF
}

# Like run_in_pty, but also feeds scripted answers to /dev/tty reads (the
# wizard prompts) at a fixed cadence, and stops as soon as $2 (a marker string)
# appears. $3 is a newline-separated list of lines to send, one per prompt.
run_in_pty_scripted() {
  python3 - "$1" "$2" "$3" <<'PY_EOF'
import os, pty, sys, time, select

cmd, marker, steps_raw = sys.argv[1], sys.argv[2], sys.argv[3]
steps = steps_raw.split("\n") if steps_raw else []

pid, master = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", cmd])

out = b""
si = 0
deadline = time.time() + 15
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.3)
    if master in r:
        try:
            data = os.read(master, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
        if marker.encode() in out:
            break
    elif si < len(steps):
        os.write(master, (steps[si] + "\n").encode())
        si += 1
os.close(master)
sys.stdout.write(out.decode("utf-8", "replace"))
try:
    os.kill(pid, 9)
except ProcessLookupError:
    pass
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

printf '\nKnown-bug regressions\n'
# Pi-hole's vendor installer restarts pihole-FTL *before* it finishes
# building and swapping in the real gravity database, leaving FTL holding a
# stale connection — every domainlist/adlist write then fails with "attempt
# to write a readonly database" until the service is restarted. Confirmed on
# a real container, fixed by an explicit restart_service call after both
# install and update. This can't be exercised behaviorally without a real
# gravity build, so guard it structurally: the built script must still
# contain the fix, so a refactor that drops the call fails loudly here
# instead of silently reintroducing a bug that only shows up hours later on
# someone else'"'"'s box.
if [[ -f "$ROOT/ct-lxc/pi-hole-lxc.sh" ]]; then
  n="$(grep -c 'restart_service pihole-FTL' "$ROOT/ct-lxc/pi-hole-lxc.sh")"
  if [[ "$n" -ge 2 ]]; then pass "pi-hole-lxc.sh restarts FTL after both install and update (gravity.db race fix)"
  else fail "pi-hole-lxc.sh restarts FTL after both install and update (gravity.db race fix) — found ${n}, need 2"; fi
fi

# Floci's EC2/RDS/ECS/... support spawns further sibling containers of its own
# via the Docker socket — `docker compose down` never learns about these,
# since compose only tracks what it declared. Confirmed on a real container:
# after uninstall, a container launched during testing (a "t2.micro" backed
# by a real amazonlinux image) was still sitting there, exited but not
# removed. Fixed by filtering on the `floci=true` label every such container
# carries (checked via `docker inspect`, not assumed) and removing them
# explicitly. Can't be exercised without a real Docker daemon, so guard it
# structurally the same way as the Pi-hole fix above.
if [[ -f "$ROOT/ct-lxc/floci-lxc.sh" ]]; then
  if grep -q "label=floci=true" "$ROOT/ct-lxc/floci-lxc.sh" && grep -q "remove_spawned_containers" "$ROOT/ct-lxc/floci-lxc.sh"; then
    pass "floci-lxc.sh cleans up Floci-spawned sibling containers on uninstall (orphan fix)"
  else
    fail "floci-lxc.sh cleans up Floci-spawned sibling containers on uninstall (orphan fix)"
  fi
fi

# OpenSSH's own compiled-in default is `PermitRootLogin prohibit-password` —
# root can never SSH in with a password, no matter how correct it is, unless
# a container explicitly overrides that. Debian's and Alpine's shipped
# sshd_config both leave the directive commented out, so the compiled-in
# default silently applied to every container this project ever created.
# Confirmed live with sshpass against a real container ("Permission denied"
# with the exact right password) before writing the fix, and confirmed SSH
# succeeds after it — on both Debian and Alpine (Alpine needed its own fix
# on top: the base image doesn't ship OpenSSH installed at all). Can't
# exercise a real sshd negotiation in this sandbox, so guard structurally:
# every built script must call enable_root_ssh during create, and lib/pve.sh
# must still know how to install/start sshd on Alpine specifically.
# Matches the specific do_create call site, not just any mention of the
# function name — enable_root_ssh is also called from the update path (to
# repair containers made before this fix existed), so a bare name search
# would still pass with the create-time call removed and only that one left.
if grep -q 'enable_root_ssh "\$CTID" "\$OS_ID"' "$ROOT/src/lib/main.sh" && grep -q "apk add -q openssh" "$ROOT/src/lib/pve.sh"; then
  pass "lib: enables root SSH login at create time, with an Alpine-specific install step (sshd-password fix)"
else
  fail "lib: enables root SSH login at create time, with an Alpine-specific install step (sshd-password fix)"
fi
for script_path in ${scripts[@]+"${scripts[@]}"}; do
  is_shim "$script_path" && continue
  name="$(basename "$script_path")"
  if grep -q 'enable_root_ssh "\$CTID" "\$OS_ID"' "$script_path"; then
    pass "$name calls enable_root_ssh during create (sshd-password fix)"
  else
    fail "$name calls enable_root_ssh during create (sshd-password fix)"
  fi
done

printf '\nInteractive guard rails\n'
for script_path in ${scripts[@]+"${scripts[@]}"}; do
  is_shim "$script_path" && continue
  name="$(basename "$script_path")"
  lib="$(loadable "$script_path")"

  # A prompt that fires without a human hangs a cron job or a CI step forever.
  # Piped output must never reach the wizard.
  ( set +u; source "$lib" >/dev/null 2>&1; wizard_wanted ) 2>/dev/null
  if [[ $? -ne 0 ]]; then pass "$name does not prompt when output is piped"
  else fail "$name does not prompt when output is piped"; fi

  # ...nor when the caller passed anything, nor when defaults were requested.
  ( set +u; source "$lib" >/dev/null 2>&1; OPTS_GIVEN=1; wizard_wanted ) 2>/dev/null
  if [[ $? -ne 0 ]]; then pass "$name does not prompt when options were given"
  else fail "$name does not prompt when options were given"; fi

  if command -v python3 >/dev/null 2>&1; then
    # On a tty with no options it *must* prompt, or the feature is dead code.
    out="$(run_in_pty "set +u; source '$lib' >/dev/null 2>&1; if wizard_wanted; then echo WIZARD-ON; else echo WIZARD-OFF; fi" 2>&1 || true)"
    if printf '%s' "$out" | grep -q 'WIZARD-ON'; then pass "$name prompts on a tty with no options"
    else fail "$name prompts on a tty with no options"; fi

    out="$(run_in_pty "set +u; source '$lib' >/dev/null 2>&1; ASSUME_DEFAULTS=1; if wizard_wanted; then echo WIZARD-ON; else echo WIZARD-OFF; fi" 2>&1 || true)"
    if printf '%s' "$out" | grep -q 'WIZARD-OFF'; then pass "$name honours --defaults on a tty"
    else fail "$name honours --defaults on a tty"; fi
  fi

  # A full pass through the wizard, on a real pty, with a deliberately bad
  # answer in the middle (v_cidr must reject and re-ask) and every other field
  # given a non-default value, so this fails if any prompt silently keeps its
  # old value or a probe function (storage_options et al.) prints a spurious
  # error into the transcript.
  if command -v python3 >/dev/null 2>&1; then
    # Two things vary per service and would otherwise silently desync a fixed
    # step count: whether the OS question appears at all (only when a service
    # lists more than one DEFAULT_OS_CHOICES), and what "accept the default"
    # means for the static-IP question (AdGuard/Pi-hole default it to yes,
    # Floci does not set DEFAULT_PREFER_STATIC and so defaults to no). Query
    # both from the service itself rather than assume either.
    os_count="$( ( set +u; source "$lib" >/dev/null 2>&1; printf '%s' "$OS_CHOICES" ) 2>/dev/null | wc -w | tr -d ' ')"
    os_step=""
    [[ "${os_count:-1}" -gt 1 ]] && os_step=$'\n'

    wiz_cmd="set +u; source '$lib' >/dev/null 2>&1; CTID=105; CT_HOSTNAME=adguardhome; ROOTFS_STORAGE=local; DISK_GB=4; CORES=1; MEMORY_MB=512; BRIDGE=vmbr0; CHANNEL=release; configure_interactive; echo WIZ-HOST=\$CT_HOSTNAME; echo WIZ-MEM=\$MEMORY_MB; echo WIZ-STATIC=\$STATIC_CIDR; echo WIZ-DONE"
    # ...OS?[skipped unless this service offers >1] -> accept, static? -> "y"
    # answered explicitly (not blank — its default varies per service), CIDR
    # (bad, rejected), CIDR (good), gateway, auto-generate password?[default
    # y] -> accept, then whatever the service's own svc_prompt asks (channel,
    # upstream DNS, platform, ...) -> accept ITS default too, since this runs
    # against every service and each one asks something different.
    wiz_steps=$'\nmydns'"${os_step}"$'\n\n\n1024\ny\nnotanip\n192.168.9.53/24\n192.168.9.1\n\n\n'
    out="$(run_in_pty_scripted "$wiz_cmd" "WIZ-DONE" "$wiz_steps" 2>&1 || true)"
    if printf '%s' "$out" | grep -q '\[x\]'; then
      fail "$name wizard prints no spurious errors on a full pass ($(printf '%s' "$out" | grep '\[x\]' | head -1))"
    else
      pass "$name wizard prints no spurious errors on a full pass"
    fi
    if printf '%s' "$out" | grep -q 'WIZ-HOST=mydns' \
      && printf '%s' "$out" | grep -q 'WIZ-MEM=1024' \
      && printf '%s' "$out" | grep -q 'WIZ-STATIC=192.168.9.53/24'; then
      pass "$name wizard applies every answer, including after a rejected one"
    else
      fail "$name wizard applies every answer, including after a rejected one"
    fi
    if printf '%s' "$out" | grep -q 'needs an address'; then
      pass "$name wizard re-asks on an invalid CIDR"
    else
      fail "$name wizard re-asks on an invalid CIDR"
    fi

    # Picking Alpine explicitly (by number, not just accepting the Debian
    # default) must actually reach OS_ID — and, downstream, the TEMPLATE_
    # PATTERN that os_template_pattern derives from it. Wrong result here
    # would mean --os and the wizard disagree about which OS a run used.
    # Only meaningful for a service that actually offers more than one OS —
    # skip it for a single-OS service rather than force an answer onto a
    # question that was never asked.
    if [[ "${os_count:-1}" -gt 1 ]]; then
      os_cmd="set +u; source '$lib' >/dev/null 2>&1; CTID=106; CT_HOSTNAME=adguardhome; ROOTFS_STORAGE=local; DISK_GB=4; CORES=1; MEMORY_MB=512; BRIDGE=vmbr0; CHANNEL=release; configure_interactive >/dev/null; echo OS-RESULT=\$OS_ID; echo OS-DONE"
      # CTID/hostname accept, OS pick "2" (alpine, by number), disk/cores/mem
      # accept, decline static, decline auto-password, short/mismatch/good
      # password, then accept whatever the service's own svc_prompt defaults
      # to (differs per service).
      os_steps=$'\n\n2\n\n\n\nn\nn\nshortpw\nCorrectHorse1\nWrongConfirm\nCorrectHorse1\nCorrectHorse1\n\n'
      os_out="$(run_in_pty_scripted "$os_cmd" "OS-DONE" "$os_steps" 2>&1 || true)"
      if printf '%s' "$os_out" | grep -q 'OS-RESULT=alpine'; then
        pass "$name wizard: picking Alpine by number sets OS_ID=alpine"
      else
        fail "$name wizard: picking Alpine by number sets OS_ID=alpine"
      fi
    fi

    # The custom-password branch (ask_secret): decline auto-generate, mistype
    # the confirmation once, then get it right. Exercises hidden input and the
    # length validator in the same pass. Static IP is declined with an
    # explicit "n" here (unambiguous regardless of this service's own
    # default), so no OS-count-style branching is needed for that part.
    pw_cmd="set +u; source '$lib' >/dev/null 2>&1; CTID=105; CT_HOSTNAME=adguardhome; OS_ID=debian; ROOTFS_STORAGE=local; DISK_GB=4; CORES=1; MEMORY_MB=512; BRIDGE=vmbr0; CHANNEL=release; configure_interactive >/dev/null; echo PW-RESULT=\$ROOT_PASSWORD; echo PW-DONE"
    pw_steps=$'\nmydns'"${os_step}"$'\n\n\n\nn\nn\nshortpw\nCorrectHorse1\nWrongConfirm\nCorrectHorse1\nCorrectHorse1\n\n'
    pw_out="$(run_in_pty_scripted "$pw_cmd" "PW-DONE" "$pw_steps" 2>&1 || true)"
    if printf '%s' "$pw_out" | grep -q 'PW-RESULT=CorrectHorse1'; then
      pass "$name wizard: custom password accepted after a short one and a mismatched confirmation"
    else
      fail "$name wizard: custom password accepted after a short one and a mismatched confirmation"
    fi
    if printf '%s' "$pw_out" | grep -qi 'shortpw'; then
      fail "$name wizard: a rejected password should never appear in output"
    else
      pass "$name wizard: a rejected password never appears in output"
    fi
  fi

  # generate_password pipes /dev/urandom through `tr | head -c 20`; head exits
  # the instant it has enough bytes while tr is still writing, which is SIGPIPE
  # (exit 141) on every single call by design, not an occasional fluke. Run it
  # enough times that a missing `|| true` guard would reliably show up as a
  # short/empty result or a "failed at line N" from the ERR trap.
  pwfail=0
  for _ in $(seq 1 15); do
    pw="$( ( set +u; source "$lib" >/dev/null 2>&1; generate_password ) 2>&1 )"
    [[ "${#pw}" -eq 20 && "$pw" != *'[x]'* ]] || { pwfail=1; break; }
  done
  if [[ "$pwfail" -eq 0 ]]; then pass "$name generate_password survives SIGPIPE from head across 15 runs"
  else fail "$name generate_password survives SIGPIPE from head across 15 runs (got: len=${#pw} '$pw')"; fi

  # OS support: the case-based helpers in lib/pve.sh, not a bash-4
  # associative array (this project stays parseable on bash 3.2 — see
  # CONTRIBUTING.md), so a typo in one branch is otherwise invisible until a
  # real host hits it.
  osfail=0
  for id in debian alpine; do
    label="$( ( set +u; source "$lib" >/dev/null 2>&1; os_label "$id" ) 2>&1 )"
    pattern="$( ( set +u; source "$lib" >/dev/null 2>&1; os_template_pattern "$id" ) 2>&1 )"
    bootstrap="$( ( set +u; source "$lib" >/dev/null 2>&1; os_bootstrap_cmd "$id" ) 2>&1 )"
    [[ -n "$label" && "$label" != *'[x]'* ]] || { osfail=1; fail "$name os_label('$id') = '$label'"; }
    [[ -n "$pattern" && "$pattern" != *'[x]'* ]] || { osfail=1; fail "$name os_template_pattern('$id') = '$pattern'"; }
    [[ -n "$bootstrap" && "$bootstrap" != *'[x]'* ]] || { osfail=1; fail "$name os_bootstrap_cmd('$id') = '$bootstrap'"; }
  done
  # The two bootstrap commands must actually differ (apt vs apk) — identical
  # output here would mean Alpine silently got Debian's, which fails loudly
  # only once someone runs --os alpine against a real host.
  deb_boot="$( ( set +u; source "$lib" >/dev/null 2>&1; os_bootstrap_cmd debian ) 2>&1 )"
  alp_boot="$( ( set +u; source "$lib" >/dev/null 2>&1; os_bootstrap_cmd alpine ) 2>&1 )"
  if [[ "$deb_boot" == *apt-get* && "$alp_boot" == *apk* && "$deb_boot" != "$alp_boot" ]]; then
    pass "$name debian and alpine bootstrap commands actually differ (apt vs apk)"
  else
    fail "$name debian and alpine bootstrap commands actually differ (apt vs apk)"
  fi
  [[ "$osfail" -eq 0 ]] && pass "$name os_label/os_template_pattern/os_bootstrap_cmd cover debian and alpine"

  # An unknown OS must be rejected at argument-parse time — before any pct/pvesm
  # call — not three steps into create after a container already exists. Check
  # the actual message, not just a non-zero exit: this must fail *because* the
  # OS is unknown, not because pct happens to be missing on this machine too.
  osargs_out="$("$script_path" create --os solaris 2>&1)"; osargs_rc=$?
  if [[ "$osargs_rc" -ne 0 ]] && printf '%s' "$osargs_out" | grep -q -- '--os must be one of'; then
    pass "$name rejects an unknown --os before touching the host"
  else
    fail "$name rejects an unknown --os before touching the host (rc=$osargs_rc: $osargs_out)"
  fi

  # Validators are the whole reason a typo does not become a broken container.
  bad=0
  for case in "v_posint 0" "v_posint abc" "v_posint -1" "v_hostname -bad" "v_hostname a_b" \
              "v_cidr 192.168.1.53" "v_cidr nonsense" "v_ip 192.168.1.53/24" "v_ip hello"; do
    if ( set +u; source "$lib" >/dev/null 2>&1; $case ) 2>/dev/null; then
      fail "$name validator accepted bad input: $case"; bad=1
    fi
  done
  for case in "v_posint 4" "v_posint 512" "v_hostname adguard-home" "v_cidr 192.168.1.53/24" "v_ip 192.168.1.1"; do
    if ! ( set +u; source "$lib" >/dev/null 2>&1; $case ) 2>/dev/null; then
      fail "$name validator rejected good input: $case"; bad=1
    fi
  done
  [[ "$bad" -eq 0 ]] && pass "$name validators accept good input and reject bad"
done

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
