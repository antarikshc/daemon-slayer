#!/usr/bin/env bash
#
# DaemonSlayer end-to-end integration harness (SPEC.md §15).
#
# Proves the detection rules (§5) and kill paths (§7) against REAL processes with
# thresholds dialed down to seconds. Every scenario gets a fresh temp dir with its
# own config/state/log, starts the real agent, spawns real fake daemons, and
# asserts on the agent log / --status output. PASS/FAIL per scenario + summary;
# exit 0 only if all pass.
#
# Safety: aborts up front if any REAL Gradle/Kotlin daemon JVM is live, so the
# auto-kill scenarios can only ever touch our fakes. Every process we start is
# tracked and torn down; we verify zero fakedaemon survivors at the end.

set -u

# ─────────────────────────────────────────────────────────────────────────────
# Locations
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DS="$REPO_DIR/.build/debug/daemonslayer"
FD="$REPO_DIR/.build/debug/fakedaemon"

GRADLE_MARKER="org.gradle.launcher.daemon.bootstrap.GradleDaemon"
KOTLIN_MARKER="org.jetbrains.kotlin.daemon.KotlinCompileDaemon"

# Tracking for teardown.
#
# CRITICAL: the spawn_* helpers run inside $(...) command substitution, so any
# bash-array mutation inside them is lost in the subshell. We therefore track pids
# in FILES (subshell-safe): every spawned pid is appended to the per-scenario
# registry $CUR_PIDS_FILE and the global $ALL_PIDS_FILE. new_scenario() tears down
# the previous scenario's processes via its registry before the next starts — so a
# detached fake (PPID 1) from one scenario can never be seen by the next agent
# (orphan detection is global on the machine).
TMP_DIRS=()        # per-scenario temp dirs
REGISTRY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ds-int-reg.XXXXXX")"
ALL_PIDS_FILE="$REGISTRY_DIR/all_pids"
CUR_PIDS_FILE="$REGISTRY_DIR/cur_pids"   # repointed per scenario
: > "$ALL_PIDS_FILE"
declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
FAILED=0
AGENT_PID=""       # most-recently-started agent (for --status assertions)

# Record a fake/agent pid in the current-scenario + global registries.
track_pid() {
  [ -n "${1:-}" ] || return 0
  echo "$1" >> "$ALL_PIDS_FILE"
  [ -n "${CUR_PIDS_FILE:-}" ] && echo "$1" >> "$CUR_PIDS_FILE"
}

# Kill every pid listed in a registry file (agents with TERM, fakes/anything with
# -9), then wait until they're all gone from the process table (max ~6s).
kill_registry() {
  local file="$1"
  [ -f "$file" ] || return 0
  local pid
  while read -r pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done < "$file"
  while read -r pid; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done < "$file"
  local waited=0
  while [ "$waited" -lt 6 ]; do
    local alive=0
    while read -r pid; do [ -n "$pid" ] && is_alive "$pid" && alive=1; done < "$file"
    [ "$alive" -eq 0 ] && break
    sleep 1
    waited=$((waited + 1))
  done
}

# Tear down only the CURRENT scenario's processes.
cleanup_scenario() {
  [ -n "${CUR_PIDS_FILE:-}" ] && kill_registry "$CUR_PIDS_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers
# ─────────────────────────────────────────────────────────────────────────────
c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_dim()   { printf '\033[2m%s\033[0m' "$1"; }

info() { echo "  $(c_dim "· $*")"; }

record() { # name, status(PASS/FAIL), detail
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  if [ "$2" = "PASS" ]; then
    echo "  $(c_green "✔ PASS") — $1"
  else
    echo "  $(c_red "✘ FAIL") — $1: ${3:-}"
    FAILED=1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Process helpers
# ─────────────────────────────────────────────────────────────────────────────

# Wait until $1 (a regex) appears in file $2, up to $3 seconds. Returns 0 if found.
wait_for_log() {
  local regex="$1" file="$2" timeout="${3:-30}"
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if [ -f "$file" ] && grep -Eq "$regex" "$file"; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Assert a regex is ABSENT from file for the full duration $2 (seconds).
# Returns 0 if it never appeared.
assert_absent_for() {
  local regex="$1" duration="$2" file="$3"
  local waited=0
  while [ "$waited" -lt "$duration" ]; do
    if [ -f "$file" ] && grep -Eq "$regex" "$file"; then return 1; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

is_alive() { kill -0 "$1" 2>/dev/null; }

# Wait until pid $1 is dead, up to $2 seconds. Returns 0 if it died.
wait_for_death() {
  local pid="$1" timeout="${2:-10}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if ! is_alive "$pid"; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  ! is_alive "$pid"
}

# Spawn a DETACHED fake (PPID 1) via a double-fork subshell. The subshell exits,
# the fake reparents to launchd. We capture its pid via pgrep on a UNIQUE token
# embedded in its argv ($1 = token, rest = args).
spawn_detached_fake() {
  local token="$1"; shift
  ( "$FD" "$@" "-Dproj=$token" >/dev/null 2>&1 & )
  # Wait for it to appear in the process table under our token.
  local pid="" waited=0
  while [ "$waited" -lt 5 ]; do
    pid="$(pgrep -f "proj=$token" | head -1)"
    if [ -n "$pid" ]; then break; fi
    sleep 1
    waited=$((waited + 1))
  done
  track_pid "$pid"
  echo "$pid"
}

# Spawn an ATTACHED (child) fake — we own it directly so we can kill it on demand
# (used for the O2 client that the test detaches mid-scenario). $1 = token.
spawn_child_fake() {
  local token="$1"; shift
  "$FD" "$@" "-Dproj=$token" >/dev/null 2>&1 &
  local pid=$!
  track_pid "$pid"
  echo "$pid"
}

# Spawn a LISTENER fake and return "PID PORT". Listener prints "LISTENING <port>"
# to stdout, which we capture from a per-scenario file. $1=token, $2=detached(0/1),
# rest = extra args.
spawn_listener_fake() {
  local token="$1" detached="$2"; shift 2
  local outfile="$TMP/listen-$token.out"
  if [ "$detached" = "1" ]; then
    ( "$FD" --listen "$@" "-Dproj=$token" >"$outfile" 2>/dev/null & )
  else
    "$FD" --listen "$@" "-Dproj=$token" >"$outfile" 2>/dev/null &
    track_pid "$!"
  fi
  # Wait for the LISTENING line + resolve the pid via token.
  local port="" pid="" waited=0
  while [ "$waited" -lt 6 ]; do
    if [ -f "$outfile" ]; then
      port="$(grep -o 'LISTENING [0-9]*' "$outfile" 2>/dev/null | head -1 | awk '{print $2}')"
    fi
    pid="$(pgrep -f "proj=$token" | head -1)"
    if [ -n "$port" ] && [ -n "$pid" ]; then break; fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$detached" = "1" ] && [ -n "$pid" ]; then track_pid "$pid"; fi
  echo "$pid $port"
}

# Start the agent for the current scenario. Uses $TMP/{config,state,agent.log}.
start_agent() {
  "$DS" --agent \
    --config "$TMP/config.json" \
    --state-file "$TMP/state.json" \
    --log-file "$TMP/agent.log" >/dev/null 2>&1 &
  local pid=$!
  track_pid "$pid"
  AGENT_PID="$pid"
  # Give it a moment to write its first log line / state.
  sleep 1
}

# Write a per-scenario config. Args are key overrides applied via sed-free heredoc
# substitution through shell variables. We expose the knobs each scenario tweaks.
write_config() {
  # Defaults (harness baseline).
  local r1_enabled="${R1_ENABLED:-true}"   r1_thr="${R1_THR:-0.1}"
  local r2_enabled="${R2_ENABLED:-false}"  r2_thr="${R2_THR:-15}"
  local r3_enabled="${R3_ENABLED:-false}"  r3_thr="${R3_THR:-120}"
  local r4_enabled="${R4_ENABLED:-false}"  r4_thr="${R4_THR:-2}"  r4_cpu="${R4_CPU:-50}"
  local ak_enabled="${AK_ENABLED:-false}"  ak_rules="${AK_RULES:-[\"ownerlessNoIDE\"]}"
  local prefixes="${PREFIXES:-[\"dev.invalid.nonexistent\"]}"
  local poll="${POLL:-2}" idlepoll="${IDLEPOLL:-2}"
  local snooze="${SNOOZE:-0.05}" escalation="${ESCALATION:-2}"
  local paused="${PAUSED:-false}"
  cat > "$TMP/config.json" <<EOF
{
  "pollIntervalSeconds": $poll,
  "idlePollIntervalSeconds": $idlepoll,
  "rules": {
    "ownerlessNoIDE":   { "enabled": $r1_enabled, "thresholdMinutes": $r1_thr },
    "ownerlessWithIDE": { "enabled": $r2_enabled, "thresholdMinutes": $r2_thr },
    "idleTooLong":      { "enabled": $r3_enabled, "thresholdMinutes": $r3_thr },
    "runaway":          { "enabled": $r4_enabled, "thresholdMinutes": $r4_thr, "cpuThresholdPercent": $r4_cpu }
  },
  "idleCpuSecondsPerPoll": 0.5,
  "snoozeMinutes": $snooze,
  "killEscalationSeconds": $escalation,
  "autoKill": { "enabled": $ak_enabled, "rules": $ak_rules },
  "ownerAppBundlePrefixes": $prefixes,
  "logLevel": "debug",
  "paused": $paused
}
EOF
}

# Fresh scenario sandbox. FIRST tears down the previous scenario's processes
# (so detached fakes can't leak into the next scenario's global orphan view),
# then resets the per-scenario config knobs to defaults.
new_scenario() {
  cleanup_scenario
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/ds-int.XXXXXX")"
  TMP_DIRS+=("$TMP")
  # Fresh per-scenario pid registry (subshell-safe tracking).
  CUR_PIDS_FILE="$REGISTRY_DIR/cur_pids.$(basename "$TMP")"
  : > "$CUR_PIDS_FILE"
  # Reset overridable knobs.
  unset R1_ENABLED R1_THR R2_ENABLED R2_THR R3_ENABLED R3_THR \
        R4_ENABLED R4_THR R4_CPU AK_ENABLED AK_RULES PREFIXES \
        POLL IDLEPOLL SNOOZE ESCALATION PAUSED
}

# ─────────────────────────────────────────────────────────────────────────────
# Teardown
# ─────────────────────────────────────────────────────────────────────────────
teardown() {
  # Kill the current scenario's processes, then everything ever started (global
  # registry) — both are subshell-safe pid files.
  cleanup_scenario
  kill_registry "$ALL_PIDS_FILE"
  for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
  rm -rf "$REGISTRY_DIR"
}
trap teardown EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo " DaemonSlayer integration harness"
echo "═══════════════════════════════════════════════════════════════════"

if [ ! -x "$DS" ] || [ ! -x "$FD" ]; then
  echo "Building (swift build)…"
  ( cd "$REPO_DIR" && swift build ) || { echo "swift build FAILED"; exit 2; }
fi
[ -x "$DS" ] || { echo "missing $DS"; exit 2; }
[ -x "$FD" ] || { echo "missing $FD"; exit 2; }

# SAFETY GUARD: abort if any REAL daemon JVM is live. Auto-kill scenarios kill
# whatever matches R1; they must only ever see our fakes. We check BEFORE spawning
# any fake, so a plain marker grep is unambiguous.
if pgrep -f "$GRADLE_MARKER" >/dev/null 2>&1 || pgrep -f "$KOTLIN_MARKER" >/dev/null 2>&1; then
  echo ""
  echo "$(c_red "ABORT"): a real Gradle/Kotlin daemon JVM is live on this machine."
  echo "The auto-kill scenarios would target it. Stop your daemons first:"
  pgrep -fl "$GRADLE_MARKER" 2>/dev/null
  pgrep -fl "$KOTLIN_MARKER" 2>/dev/null
  exit 3
fi
echo "Safety guard OK — no real Gradle/Kotlin daemons live."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# S1 — R1 notify: detached idle fake gradle, no IDE, notify-only.
# Expect: [notify-dryrun] ORPHAN_FOUND within ~25s; fake STILL ALIVE after.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s1() {
  new_scenario
  echo "S1: R1 ownerless-no-IDE → notify only"
  write_config   # defaults: R1 on notify-only, prefixes nonexistent
  start_agent
  local tok="s1-$$"
  local pid; pid="$(spawn_detached_fake "$tok" "$GRADLE_MARKER" 8.13 --exit-after 90)"
  if [ -z "$pid" ]; then record "S1 R1 notify" FAIL "fake didn't spawn"; return; fi
  info "detached fake gradle pid=$pid"
  if ! wait_for_log "notify-dryrun.*ORPHAN_FOUND" "$TMP/agent.log" 25; then
    record "S1 R1 notify" FAIL "no ORPHAN_FOUND in 25s"; return
  fi
  info "$(grep -E 'notify-dryrun.*ORPHAN_FOUND' "$TMP/agent.log" | head -1)"
  if ! is_alive "$pid"; then record "S1 R1 notify" FAIL "fake died (notify must not kill)"; return; fi
  # Confirm R1 specifically (not some other rule).
  if ! grep -Eq "via R1" "$TMP/agent.log"; then
    record "S1 R1 notify" FAIL "flagged but not via R1"; return
  fi
  record "S1 R1 notify" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S2 — R1 auto-kill: same but autoKill enabled for ownerlessNoIDE.
# Expect: fake SIGTERMed and dies; log shows kill + kill-summary "Killed 1" w/ freed bytes.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s2() {
  new_scenario
  echo "S2: R1 auto-kill → SIGTERM + kill summary"
  AK_ENABLED=true
  write_config
  start_agent
  local tok="s2-$$"
  local pid; pid="$(spawn_detached_fake "$tok" "$GRADLE_MARKER" 8.13 --exit-after 90)"
  if [ -z "$pid" ]; then record "S2 R1 auto-kill" FAIL "fake didn't spawn"; return; fi
  info "detached fake gradle pid=$pid"
  if ! wait_for_log "auto-kill" "$TMP/agent.log" 25; then
    record "S2 R1 auto-kill" FAIL "no auto-kill in 25s"; return
  fi
  if ! wait_for_death "$pid" 12; then
    record "S2 R1 auto-kill" FAIL "fake survived auto-kill"; return
  fi
  info "fake died"
  if ! wait_for_log "via SIGTERM" "$TMP/agent.log" 5; then
    record "S2 R1 auto-kill" FAIL "no SIGTERM in log"; return
  fi
  if ! wait_for_log "notify-dryrun.*Killed 1 JVM" "$TMP/agent.log" 6; then
    record "S2 R1 auto-kill" FAIL "no 'Killed 1' kill-summary dryrun"; return
  fi
  info "$(grep -E 'notify-dryrun.*Killed' "$TMP/agent.log" | head -1)"
  record "S2 R1 auto-kill" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 — R2 vs R1 selection: detached idle fake gradle, IDE running (Finder),
# R1+R2 both enabled (0.1 min each). Expect: flagged via ownerlessWithIDE (R2), NOT R1.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s3() {
  new_scenario
  echo "S3: R2 vs R1 selection (IDE running → R2)"
  R1_ENABLED=true R1_THR=0.1
  R2_ENABLED=true R2_THR=0.1
  PREFIXES='["com.apple.finder"]'   # Finder is always running → IDE "present"
  write_config
  start_agent
  local tok="s3-$$"
  local pid; pid="$(spawn_detached_fake "$tok" "$GRADLE_MARKER" 8.13 --exit-after 90)"
  if [ -z "$pid" ]; then record "S3 R2 vs R1" FAIL "fake didn't spawn"; return; fi
  info "detached fake gradle pid=$pid (Finder = IDE present)"
  if ! wait_for_log "notify-dryrun.*ORPHAN_FOUND" "$TMP/agent.log" 25; then
    record "S3 R2 vs R1" FAIL "no ORPHAN_FOUND in 25s"; return
  fi
  if ! grep -Eq "$pid .* via R2" "$TMP/agent.log"; then
    record "S3 R2 vs R1" FAIL "not flagged via R2"; return
  fi
  if grep -Eq "$pid .* via R1" "$TMP/agent.log"; then
    record "S3 R2 vs R1" FAIL "incorrectly flagged via R1 (IDE was running)"; return
  fi
  info "$(grep -E 'flagging.*via R2' "$TMP/agent.log" | head -1)"
  record "S3 R2 vs R1" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S4 — O2 client hold + release: fake gradle --listen; plain fake CLIENT (no
# daemon marker) --connect. R1 enabled, threshold 0.1. Expect: NO flag for ≥15s
# (client owns it), then kill the client → flag within ~15s after.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s4() {
  new_scenario
  echo "S4: O2 client hold then release"
  R1_THR=0.1
  write_config
  start_agent
  local gtok="s4g-$$"
  read -r gpid gport <<<"$(spawn_listener_fake "$gtok" 1 "$GRADLE_MARKER" 8.13 --exit-after 120)"
  if [ -z "$gpid" ] || [ -z "$gport" ]; then record "S4 O2 client" FAIL "listener gradle didn't start ($gpid/$gport)"; return; fi
  info "fake gradle pid=$gpid listening on $gport"
  # Plain client: NO daemon marker → not a watched daemon → counts as a real client.
  local ctok="s4c-$$"
  local cpid; cpid="$(spawn_child_fake "$ctok" --connect "$gport" --exit-after 120)"
  info "plain client pid=$cpid connected"
  # Wait until the agent actually OBSERVES the client attached, so the absence
  # window below measures the steady owned state — not the brief startup gap
  # before the TCP connection is established.
  if ! wait_for_log "pid=$gpid .* hasAttachedClient=true" "$TMP/agent.log" 12; then
    record "S4 O2 client" FAIL "agent never observed the client attaching"; return
  fi
  info "agent observed client attached to $gpid"
  # Phase 1: with client attached, no flag for ≥15s (~2.5× threshold). Anchored to
  # the gradle pid so an unrelated event can't trip it.
  if ! assert_absent_for "flagging.*$gpid" 15 "$TMP/agent.log"; then
    record "S4 O2 client" FAIL "flagged while client attached (O2 should own it)"; return
  fi
  info "no flag for 15s while client attached (correct)"
  # Phase 2: release the client → daemon becomes ownerless → flag within ~15s.
  kill -9 "$cpid" 2>/dev/null
  info "client killed; expecting flag now"
  if ! wait_for_log "$gpid .* via R1" "$TMP/agent.log" 15; then
    record "S4 O2 client" FAIL "no flag within 15s of client release"; return
  fi
  info "$(grep -E "flagging.*$gpid" "$TMP/agent.log" | head -1)"
  record "S4 O2 client" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S5 — Peer-daemon exclusion + O4 lockstep: fake gradle --listen (detached);
# fake kotlin (kotlin marker, detached) --connect to gradle's port — a
# daemon-to-daemon link, NOT a client. Expect: BOTH flagged, same poll, one
# ORPHAN_FOUND batch listing both pids.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s5() {
  new_scenario
  echo "S5: peer-daemon exclusion + O4 lockstep (both flagged together)"
  # 0.2 min = 6 samples @ 2s poll — long enough that the kotlin peer link is
  # established and observed (O4 lockstep engaged) before either daemon's R1
  # counter crosses the threshold, so they fire in ONE batch (spec §5.1 O4).
  R1_THR=0.2
  write_config
  start_agent
  local gtok="s5g-$$"
  read -r gpid gport <<<"$(spawn_listener_fake "$gtok" 1 "$GRADLE_MARKER" 8.13 --exit-after 120)"
  if [ -z "$gpid" ] || [ -z "$gport" ]; then record "S5 peer + O4" FAIL "listener gradle didn't start"; return; fi
  info "fake gradle pid=$gpid listening on $gport"
  local ktok="s5k-$$"
  local kpid; kpid="$(spawn_detached_fake "$ktok" --connect "$gport" "$KOTLIN_MARKER" --exit-after 120)"
  if [ -z "$kpid" ]; then record "S5 peer + O4" FAIL "kotlin fake didn't start"; return; fi
  info "fake kotlin pid=$kpid (peer link to gradle, NOT a client)"
  # Wait for the agent to OBSERVE the peer link (kotlin's linkedGradlePid resolved
  # to the gradle pid) before the hysteresis window can complete — this guarantees
  # both daemons are present and linked, so O4 lockstep fires them in ONE batch
  # rather than the gradle flagging alone a poll before the kotlin links up.
  if ! wait_for_log "pid=$kpid .* linkedGradlePid=$gpid" "$TMP/agent.log" 15; then
    record "S5 peer + O4" FAIL "agent never linked kotlin→gradle (peer link not seen)"; return
  fi
  # Also confirm the gradle is NOT seen as having a client (peer-daemon exclusion).
  if grep -Eq "pid=$gpid .* hasAttachedClient=true" "$TMP/agent.log"; then
    record "S5 peer + O4" FAIL "gradle wrongly saw the kotlin peer as a client"; return
  fi
  info "peer link observed (kotlin $kpid → gradle $gpid), no false client"
  if ! wait_for_log "notify-dryrun.*ORPHAN_FOUND" "$TMP/agent.log" 30; then
    record "S5 peer + O4" FAIL "no ORPHAN_FOUND in 30s (peer link wrongly vouched?)"; return
  fi
  # Both pids must appear in a single flagging line (same poll / one batch).
  local line; line="$(grep -E 'flagging 2 process.*ORPHAN_FOUND' "$TMP/agent.log" | head -1)"
  if [ -z "$line" ]; then
    record "S5 peer + O4" FAIL "no single batch of 2 processes"; return
  fi
  if ! echo "$line" | grep -q "$gpid" || ! echo "$line" | grep -q "$kpid"; then
    record "S5 peer + O4" FAIL "batch missing one of the pids ($gpid/$kpid): $line"; return
  fi
  info "$line"
  record "S5 peer + O4" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S6 — R4 runaway: detached fake gradle --burn-cpu, no listener, runaway enabled
# (0.1 min, cpu>50), R1 disabled. Expect: [notify-dryrun] RUNAWAY_FOUND within
# ~25s mentioning CPU.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s6() {
  new_scenario
  echo "S6: R4 runaway (clientless + burning CPU)"
  R1_ENABLED=false
  R4_ENABLED=true R4_THR=0.1 R4_CPU=50
  write_config
  start_agent
  local tok="s6-$$"
  local pid; pid="$(spawn_detached_fake "$tok" --burn-cpu "$GRADLE_MARKER" 8.13 --exit-after 90)"
  if [ -z "$pid" ]; then record "S6 R4 runaway" FAIL "fake didn't spawn"; return; fi
  info "detached burning fake gradle pid=$pid"
  if ! wait_for_log "notify-dryrun.*RUNAWAY_FOUND" "$TMP/agent.log" 25; then
    record "S6 R4 runaway" FAIL "no RUNAWAY_FOUND in 25s"; return
  fi
  local line; line="$(grep -E 'notify-dryrun.*RUNAWAY_FOUND' "$TMP/agent.log" | head -1)"
  if ! echo "$line" | grep -qi "CPU"; then
    record "S6 R4 runaway" FAIL "RUNAWAY_FOUND but no CPU mention: $line"; return
  fi
  info "$line"
  record "S6 R4 runaway" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S7 — Kotlin marker-file kill: detached fake kotlin with --marker AND the
# -Dkotlin.daemon.initiator.marker.file=<same path> argv (plus kotlin class
# marker); NO gradle running. autoKill R1. Expect: killer DELETES the marker, fake
# exits on its own → log shows marker-file kill method (not sigterm); file gone;
# process dead.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s7() {
  new_scenario
  echo "S7: Kotlin marker-file clean kill"
  AK_ENABLED=true
  write_config
  start_agent
  local tok="s7-$$"
  local marker="$TMP/kotlin-compiler-in-fakeproj-123.alive"
  local pid
  pid="$(spawn_detached_fake "$tok" \
        --marker "$marker" \
        "-Dkotlin.daemon.initiator.marker.file=$marker" \
        "$KOTLIN_MARKER" --exit-after 90)"
  if [ -z "$pid" ]; then record "S7 marker kill" FAIL "fake didn't spawn"; return; fi
  info "detached fake kotlin pid=$pid marker=$marker"
  # Standalone Kotlin (no gradle) is an instant orphan candidate under R1.
  if ! wait_for_log "marker-file shutdown" "$TMP/agent.log" 25; then
    record "S7 marker kill" FAIL "no marker-file shutdown attempt in 25s"; return
  fi
  if ! wait_for_death "$pid" 10; then
    record "S7 marker kill" FAIL "fake survived marker deletion"; return
  fi
  if [ -f "$marker" ]; then
    record "S7 marker kill" FAIL "marker file still present after kill"; return
  fi
  # Must be the marker method, NOT SIGTERM, for this pid.
  if ! grep -Eq "pid $pid .* exited cleanly after marker deletion" "$TMP/agent.log"; then
    record "S7 marker kill" FAIL "no clean-exit-after-marker log line"; return
  fi
  if grep -Eq "killing pid $pid .* via SIGTERM" "$TMP/agent.log"; then
    record "S7 marker kill" FAIL "escalated to SIGTERM (marker shutdown should have sufficed)"; return
  fi
  info "$(grep -E "pid $pid .* marker" "$TMP/agent.log" | head -2 | tr '\n' '|')"
  record "S7 marker kill" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S8 — SIGKILL escalation: detached fake gradle --ignore-sigterm, autoKill R1,
# killEscalationSeconds 2. Expect: log shows escalation to SIGKILL; process dead
# within ~10s of flagging.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s8() {
  new_scenario
  echo "S8: SIGKILL escalation (SIGTERM ignored)"
  AK_ENABLED=true
  ESCALATION=2
  write_config
  start_agent
  local tok="s8-$$"
  local pid; pid="$(spawn_detached_fake "$tok" --ignore-sigterm "$GRADLE_MARKER" 8.13 --exit-after 90)"
  if [ -z "$pid" ]; then record "S8 SIGKILL" FAIL "fake didn't spawn"; return; fi
  info "detached SIGTERM-ignoring fake gradle pid=$pid"
  if ! wait_for_log "killing pid $pid .* via SIGKILL" "$TMP/agent.log" 25; then
    record "S8 SIGKILL" FAIL "no SIGKILL escalation in log"; return
  fi
  if ! wait_for_death "$pid" 10; then
    record "S8 SIGKILL" FAIL "fake survived SIGKILL"; return
  fi
  info "$(grep -E "via SIGKILL" "$TMP/agent.log" | head -1)"
  record "S8 SIGKILL" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S9 — --status under fire: S1-style flagging; after flag, run --status → stdout
# has the fake's pid, "flagged", and the agent header (pid + last poll). Also run
# once against a bogus state path → "no state file" hint, no crash.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s9() {
  new_scenario
  echo "S9: --status under fire + no-state-file hint"
  write_config   # R1 notify-only defaults
  start_agent
  local tok="s9-$$"
  local pid; pid="$(spawn_detached_fake "$tok" "$GRADLE_MARKER" 8.13 --exit-after 90)"
  if [ -z "$pid" ]; then record "S9 --status" FAIL "fake didn't spawn"; return; fi
  info "detached fake gradle pid=$pid"
  if ! wait_for_log "notify-dryrun.*ORPHAN_FOUND" "$TMP/agent.log" 25; then
    record "S9 --status" FAIL "fake never flagged"; return
  fi
  # Give the agent a beat to persist state.json post-flag.
  sleep 2
  local status_out
  status_out="$("$DS" --status --config "$TMP/config.json" --state-file "$TMP/state.json" 2>/dev/null)"
  if ! echo "$status_out" | grep -q "$pid"; then
    record "S9 --status" FAIL "--status missing fake pid"; return
  fi
  if ! echo "$status_out" | grep -qi "flagged"; then
    record "S9 --status" FAIL "--status missing 'flagged' state"; return
  fi
  if ! echo "$status_out" | grep -Eq "Agent: pid $AGENT_PID .*last poll"; then
    record "S9 --status" FAIL "--status missing agent header (pid + last poll)"; return
  fi
  info "status shows pid=$pid flagged + agent header"
  # Bogus state path → "no state file" hint, no crash.
  local bogus_out rc
  bogus_out="$("$DS" --status --config "$TMP/config.json" --state-file "$TMP/does-not-exist/nope.json" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    record "S9 --status" FAIL "--status crashed on bogus state path (rc=$rc)"; return
  fi
  if ! echo "$bogus_out" | grep -q "no state file"; then
    record "S9 --status" FAIL "bogus state path missing 'no state file' hint"; return
  fi
  info "bogus state path → 'no state file' hint, exit 0"
  record "S9 --status" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S10 — Hysteresis reset: detached fake gradle --listen, R1 threshold 0.2 min
# (12s = 6 samples). Let 3 samples pass unowned, attach a client at ~6s, keep
# ≥12s → NO flag ever. Detach client → flag only after a FULL fresh window.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s10() {
  new_scenario
  echo "S10: hysteresis reset on ownership regain"
  R1_THR=0.2   # 12s @ poll 2s → 6 consecutive samples
  write_config
  start_agent
  local gtok="s10g-$$"
  read -r gpid gport <<<"$(spawn_listener_fake "$gtok" 1 "$GRADLE_MARKER" 8.13 --exit-after 120)"
  if [ -z "$gpid" ] || [ -z "$gport" ]; then record "S10 hysteresis" FAIL "listener gradle didn't start"; return; fi
  info "fake gradle pid=$gpid listening on $gport"
  # Let ~6s of unowned samples accrue (≈3 samples, below the 6 needed).
  sleep 6
  if grep -Eq "flagging.*$gpid" "$TMP/agent.log"; then
    record "S10 hysteresis" FAIL "flagged before threshold (only ~3 samples)"; return
  fi
  # Attach a client → ownership regained → counter must reset.
  local ctok="s10c-$$"
  local cpid; cpid="$(spawn_child_fake "$ctok" --connect "$gport" --exit-after 120)"
  info "client pid=$cpid attached at ~6s — counter must reset"
  # Keep the client ≥12s; assert NO flag the whole time.
  if ! assert_absent_for "flagging.*$gpid" 14 "$TMP/agent.log"; then
    record "S10 hysteresis" FAIL "flagged while owned (counter didn't reset)"; return
  fi
  info "no flag during 14s owned window (counter reset confirmed)"
  # Detach client → flag must arrive only after a FULL fresh 12s window.
  kill -9 "$cpid" 2>/dev/null
  info "client released; flag should arrive only after a full fresh window"
  if ! wait_for_log "flagging.*$gpid" "$TMP/agent.log" 22; then
    record "S10 hysteresis" FAIL "no flag after fresh window post-release"; return
  fi
  info "$(grep -E "flagging.*$gpid" "$TMP/agent.log" | head -1)"
  record "S10 hysteresis" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S11 — KillPolicy split (SPEC-UI §6/§13): an OWNED fakedaemon (gradle --listen +
# a connected plain client). The hidden debug hook `--kill-pid <pid> --policy …`
# is the ONLY way to drive a userForced kill (the agent poll loop cannot). Expect:
# respectOwnership REFUSES (process survives, "refused"); userForced KILLS it.
# No agent is needed here — the hook does its own fresh scan + resolve + kill.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s11() {
  new_scenario
  echo "S11: KillPolicy — userForced kills an owned daemon, respectOwnership refuses"
  write_config   # config only used for killEscalationSeconds / prefixes
  local gtok="s11g-$$"
  read -r gpid gport <<<"$(spawn_listener_fake "$gtok" 1 "$GRADLE_MARKER" 8.13 --exit-after 120)"
  if [ -z "$gpid" ] || [ -z "$gport" ]; then record "S11 KillPolicy" FAIL "listener gradle didn't start"; return; fi
  info "fake gradle pid=$gpid listening on $gport"
  local ctok="s11c-$$"
  local cpid; cpid="$(spawn_child_fake "$ctok" --connect "$gport" --exit-after 120)"
  info "plain client pid=$cpid connected → gradle is OWNED (O2)"
  # Let the connection establish so the resolver sees the attached client.
  sleep 3

  # respectOwnership → must REFUSE the owned daemon and leave it alive.
  local out rc
  out="$("$DS" --kill-pid "$gpid" --policy respectOwnership \
        --config "$TMP/config.json" --log-file "$TMP/kill1.log" 2>/dev/null)"; rc=$?
  info "respectOwnership: rc=$rc out=\"$out\""
  if ! is_alive "$gpid"; then
    record "S11 KillPolicy" FAIL "respectOwnership killed an owned daemon (should refuse)"; return
  fi
  if ! echo "$out" | grep -qi "refused\|owned"; then
    record "S11 KillPolicy" FAIL "respectOwnership did not report a refusal: $out"; return
  fi
  info "respectOwnership refused; daemon still alive (correct)"

  # userForced → must KILL the same owned daemon.
  out="$("$DS" --kill-pid "$gpid" --policy userForced \
        --config "$TMP/config.json" --log-file "$TMP/kill2.log" 2>/dev/null)"; rc=$?
  info "userForced: rc=$rc out=\"$out\""
  if ! echo "$out" | grep -qi "killed"; then
    record "S11 KillPolicy" FAIL "userForced did not report a kill: $out"; return
  fi
  if ! wait_for_death "$gpid" 10; then
    record "S11 KillPolicy" FAIL "userForced did not actually kill the owned daemon"; return
  fi
  info "userForced killed the owned daemon (correct)"
  record "S11 KillPolicy" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# S12 — Paused agent (SPEC-UI §7.1/§13): with paused=true a flaggable fakedaemon
# is NOT flagged, yet the state.json heartbeat keeps updating with paused=true.
# Flip paused=false (hot reload) → the flag fires. Proves the gate suspends poll
# work without killing the heartbeat, and resume re-arms detection.
# ─────────────────────────────────────────────────────────────────────────────
scenario_s12() {
  new_scenario
  echo "S12: paused agent — no flags while paused, heartbeat alive, resume flags"
  R1_THR=0.1
  PAUSED=true
  write_config
  start_agent
  local tok="s12-$$"
  local pid; pid="$(spawn_detached_fake "$tok" "$GRADLE_MARKER" 8.13 --exit-after 120)"
  if [ -z "$pid" ]; then record "S12 paused" FAIL "fake didn't spawn"; return; fi
  info "detached fake gradle pid=$pid (agent is PAUSED)"

  # Phase 1: while paused, NO flag for ≥15s (~well past the 0.1-min threshold).
  if ! assert_absent_for "flagging" 15 "$TMP/agent.log"; then
    record "S12 paused" FAIL "flagged while paused (gate failed)"; return
  fi
  info "no flag for 15s while paused (correct)"

  # Heartbeat: state.json keeps updating with paused=true. Capture writtenAt twice.
  if [ ! -f "$TMP/state.json" ]; then record "S12 paused" FAIL "no state.json heartbeat"; return; fi
  if ! grep -q '"paused" : true' "$TMP/state.json" && ! grep -q '"paused":true' "$TMP/state.json"; then
    record "S12 paused" FAIL "state.json missing paused=true"; return
  fi
  local w1; w1="$(grep -o '"writtenAt"[^,]*' "$TMP/state.json" | head -1)"
  sleep 4
  local w2; w2="$(grep -o '"writtenAt"[^,]*' "$TMP/state.json" | head -1)"
  if [ "$w1" = "$w2" ]; then
    record "S12 paused" FAIL "heartbeat stalled while paused (writtenAt unchanged)"; return
  fi
  info "heartbeat advancing with paused=true ($w1 → $w2)"

  # Phase 2: resume (paused=false via hot reload) → flag must fire.
  PAUSED=false R1_THR=0.1
  write_config
  info "flipped paused=false; expecting a flag now"
  if ! wait_for_log "flagging.*$pid|$pid .* via R1" "$TMP/agent.log" 20; then
    record "S12 paused" FAIL "no flag within 20s of resume"; return
  fi
  info "$(grep -E "flagging" "$TMP/agent.log" | head -1)"
  record "S12 paused" PASS
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all scenarios
# ─────────────────────────────────────────────────────────────────────────────
scenario_s1
scenario_s2
scenario_s3
scenario_s4
scenario_s5
scenario_s6
scenario_s7
scenario_s8
scenario_s9
scenario_s10
scenario_s11
scenario_s12

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " SUMMARY"
echo "═══════════════════════════════════════════════════════════════════"
pass_count=0
for i in "${!RESULT_NAMES[@]}"; do
  if [ "${RESULT_STATUS[$i]}" = "PASS" ]; then
    echo "  $(c_green PASS)  ${RESULT_NAMES[$i]}"
    pass_count=$((pass_count + 1))
  else
    echo "  $(c_red FAIL)  ${RESULT_NAMES[$i]}"
  fi
done
echo "───────────────────────────────────────────────────────────────────"
echo "  $pass_count/${#RESULT_NAMES[@]} scenarios passed"

# Verify zero fakedaemon survivors (belt-and-braces; teardown runs on exit too).
teardown
trap - EXIT INT TERM
leftover="$(pgrep -f "$FD" 2>/dev/null | tr '\n' ' ')"
if [ -n "$leftover" ]; then
  echo "  $(c_red "WARNING"): leftover fakedaemon pids: $leftover — killing"
  pgrep -f "$FD" 2>/dev/null | xargs -r kill -9 2>/dev/null
  FAILED=1
else
  echo "  $(c_green "✔") zero fakedaemon survivors — clean teardown"
fi
echo ""

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
