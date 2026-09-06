#!/bin/sh
# Unit tests for the Locus plugin hooks.
#
# Runs the hook scripts the way Claude Code runs them — JSON on stdin, verdict
# in the exit code — with no Claude Code involved. The Stop verifier is the
# reason this file exists: a hook that can block is a hook that can deadlock,
# and the guards against that need to be checked on every commit, not once by
# hand on the day they were written.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CLAUDE_PLUGIN_ROOT="$root"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export LOCUS_ACTIVATION_LOG_DIR="$work/log"

pass=0
fail=0

ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf '  ok    %-58s %s\n' "$1" "$2"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-58s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

# ---------------------------------------------------------------- fixtures --
transcript="$work/transcript.jsonl"
write_transcript () {
  # $1 = user prompt text, $2 = "skill" to include a locus-algorithm tool_use
  {
    printf '{"type":"user","promptId":"P1","isMeta":true,"message":{"role":"user","content":"injected dispatcher context"}}\n'
    printf '{"type":"user","promptId":"P1","message":{"role":"user","content":%s}}\n' \
      "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    if [ "${2:-}" = "skill" ]; then
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"locus-algorithm"}}]}}\n'
    fi
    # The form a real session actually emits: Claude Code namespaces plugin
    # skills, so the live invocation is `locus:locus-algorithm`.
    if [ "${2:-}" = "nsskill" ]; then
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"locus:locus-algorithm","args":"x"}}]}}\n'
    fi
  } > "$transcript"
}

stop_event () {
  # $1 = last_assistant_message, $2 = stop_hook_active (true|false)
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "S1",
    "prompt_id": "P1",
    "hook_event_name": "Stop",
    "transcript_path": sys.argv[1],
    "last_assistant_message": sys.argv[2],
    "stop_hook_active": sys.argv[3] == "true",
}))' "$transcript" "$1" "$2"
}

run_stop () {
  set +e
  printf '%s' "$1" | "$root/hooks/stop.sh" >/dev/null 2>"$work/stderr"
  code=$?
  set -e
  echo "$code"
}

# ------------------------------------------------------------- dispatcher --
echo "UserPromptSubmit dispatcher"

out=$(printf '{"prompt":"hi"}' | "$root/hooks/user-prompt-submit.sh")
ok "emits valid JSON" \
   "$(printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin); print("yes")' 2>/dev/null || echo no)" yes
ok "hookEventName is UserPromptSubmit" \
   "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])')" \
   UserPromptSubmit
ok "additionalContext is under 1024 bytes" \
   "$(printf '%s' "$out" | python3 -c 'import json,sys; print("yes" if len(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"].encode()) < 1024 else "no")')" \
   yes
ok "names the locus-algorithm skill" \
   "$(printf '%s' "$out" | grep -c 'locus-algorithm' >/dev/null && echo yes || echo no)" yes
ok "states the classification rule" \
   "$(printf '%s' "$out" | grep -c 'Classification: Non-trivial' >/dev/null && echo yes || echo no)" yes

# ----------------------------------------------------------- SessionStart --
echo "SessionStart re-entry"

ok "silent on source=startup" \
   "$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | "$root/hooks/session-start.sh" | wc -c | tr -d ' ')" 0
ok "injects on source=compact" \
   "$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | "$root/hooks/session-start.sh" | grep -c 'locus-algorithm' | tr -d ' ')" 1
ok "compact envelope names SessionStart" \
   "$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | "$root/hooks/session-start.sh" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])')" \
   SessionStart

# ----------------------------------------------------------- Stop verifier --
echo "Stop verifier"

write_transcript "please refactor the auth module"
ok "blocks non-trivial with no skill invocation" \
   "$(run_stop "$(stop_event '**Classification: Non-trivial**

I will wing it.' false)")" 2
ok "block reason is non-empty" \
   "$([ -s "$work/stderr" ] && echo yes || echo no)" yes
ok "block reason names the skill, not the line" \
   "$(grep -c 'locus-algorithm' "$work/stderr" | tr -d ' ')" 1
ok "allows a trivial classification" \
   "$(run_stop "$(stop_event '**Classification: Trivial**

Renamed it.' false)")" 0

# DEV-580: the classification line is a logged signal, never a gate. Blocking on
# a missing line as well would reward emitting the cheap half of the behaviour.
ok "GATE: missing line, no skill — allowed (was 2 before DEV-580)" \
   "$(run_stop "$(stop_event 'Here you go, all done.' false)")" 0

write_transcript "please refactor the auth module" skill
ok "allows non-trivial when the skill fired" \
   "$(run_stop "$(stop_event '**Classification: Non-trivial**

Phase 1 OBSERVE.' false)")" 0
ok "GATE: missing line but skill fired — allowed" \
   "$(run_stop "$(stop_event 'Straight to work, no preamble.' false)")" 0
write_transcript "please refactor the auth module" nsskill
ok "detects the namespaced locus:locus-algorithm form" \
   "$(run_stop "$(stop_event '**Classification: Non-trivial**

Phase 1 OBSERVE.' false)")" 0

write_transcript "please refactor the auth module" skill
ok "GATE: trivial line but skill fired — allowed" \
   "$(run_stop "$(stop_event '**Classification: Trivial**

Done.' false)")" 0

# --- the two guards that stop this becoming a footgun ---
write_transcript "please refactor the auth module"
ok "GUARD ceiling: never blocks twice in a turn" \
   "$(run_stop "$(stop_event 'still no classification line' true)")" 0

write_transcript "just do it, locus: skip"
ok "GUARD escape: honours the escape phrase" \
   "$(run_stop "$(stop_event 'no classification line at all' false)")" 0

write_transcript "just do it, LOCUS: SKIP"
ok "GUARD escape: is case-insensitive" \
   "$(run_stop "$(stop_event 'no classification line at all' false)")" 0

write_transcript "please refactor the auth module"
ok "GUARD escape: the model cannot escape for itself" \
   "$(run_stop "$(stop_event '**Classification: Non-trivial**

locus: skip — I decided this does not need the skill.' false)")" 2

ok "GUARD kill switch: LOCUS_VERIFY=off allows" \
   "$(LOCUS_VERIFY=off run_stop "$(stop_event 'nothing at all' false)")" 0

# --- fail-open paths ---
ok "fails open on an unreadable transcript" \
   "$(run_stop "$(python3 -c 'import json; print(json.dumps({"prompt_id":"P1","transcript_path":"/nonexistent","last_assistant_message":"**Classification: Trivial**","stop_hook_active":False}))')")" 0
ok "fails open on malformed stdin" \
   "$(run_stop 'not json at all')" 0
ok "fails open with no python3 on PATH" \
   "$(PATH=/nonexistent run_stop "$(stop_event 'nothing at all' false)")" 0

# --------------------------------------------------------- activation log --
echo "Activation log"

logfile=$(find "$LOCUS_ACTIVATION_LOG_DIR" -name 'activation-*.jsonl' 2>/dev/null | head -1)
ok "a log file was written" "$([ -n "$logfile" ] && echo yes || echo no)" yes
ok "every line is standalone JSON" \
   "$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    if line.strip(): json.loads(line)
print("yes")' "$logfile" 2>/dev/null || echo no)" yes
for field in prompt_id classification blocked skill_fired escaped session_id; do
  ok "records carry $field" \
     "$(python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print("yes" if rows and all(sys.argv[2] in r for r in rows) else "no")' "$logfile" "$field")" yes
done
ok "every turn logs its classification key" \
   "$(python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print("yes" if all("classification" in r for r in rows) else "no")' "$logfile")" yes
ok "records carry event" \
   "$(python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print("yes" if all("event" in r for r in rows) else "no")' "$logfile")" yes
ok "records carry outcome" \
   "$(python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print("yes" if all("outcome" in r for r in rows) else "no")' "$logfile")" yes

# ------------------------------------------------- DEV-580 recovery outcome --
echo "Post-recovery outcome"

recovery_log="$work/rec"
fresh_log () { rm -rf "$recovery_log"; export LOCUS_ACTIVATION_LOG_DIR="$recovery_log"; }
outcomes () {
  python3 -c '
import json, glob, sys
rows = []
for p in glob.glob(sys.argv[1] + "/activation-*.jsonl"):
    rows += [json.loads(l) for l in open(p) if l.strip()]
print(",".join(r["event"] + ":" + r["outcome"] for r in rows))' "$1"
}

# blocked, then the model invokes the skill on the retry
fresh_log
write_transcript "please refactor the auth module"
run_stop "$(stop_event '**Classification: Non-trivial**

winging it' false)" >/dev/null
write_transcript "please refactor the auth module" skill
run_stop "$(stop_event '**Classification: Non-trivial**

Phase 1 OBSERVE.' true)" >/dev/null
ok "blocked then recovered logs turn+recovery" "$(outcomes "$recovery_log")" "turn:blocked,recovery:recovered"

# blocked, and the model still does not invoke the skill
fresh_log
write_transcript "please refactor the auth module"
run_stop "$(stop_event '**Classification: Non-trivial**

winging it' false)" >/dev/null
run_stop "$(stop_event '**Classification: Non-trivial**

still winging it' true)" >/dev/null
ok "blocked then not recovered logs unrecovered" "$(outcomes "$recovery_log")" "turn:blocked,recovery:unrecovered"

# a clean turn writes exactly one record and no recovery
fresh_log
write_transcript "please refactor the auth module" skill
run_stop "$(stop_event '**Classification: Non-trivial**

Phase 1 OBSERVE.' false)" >/dev/null
ok "a passing turn logs one record only" "$(outcomes "$recovery_log")" "turn:passed"

# another plugin's Stop hook caused the continue — we must not invent a record
fresh_log
write_transcript "please refactor the auth module"
run_stop "$(stop_event 'someone else blocked this' true)" >/dev/null
ok "no recovery record when the block was not ours" "$(outcomes "$recovery_log")" ""

# the recovery record joins its turn record on prompt_id
fresh_log
write_transcript "please refactor the auth module"
run_stop "$(stop_event '**Classification: Non-trivial**

winging it' false)" >/dev/null
write_transcript "please refactor the auth module" skill
run_stop "$(stop_event '**Classification: Non-trivial**

ok' true)" >/dev/null
ok "recovery shares the turn prompt_id" \
   "$(python3 -c '
import json, glob, sys
rows = []
for p in glob.glob(sys.argv[1] + "/activation-*.jsonl"):
    rows += [json.loads(l) for l in open(p) if l.strip()]
print("yes" if len({r["prompt_id"] for r in rows}) == 1 and len(rows) == 2 else "no")' "$recovery_log")" yes
ok "the marker is consumed, not left behind" \
   "$(find "$recovery_log/pending" -name '*.marker' 2>/dev/null | wc -l | tr -d ' ')" 0

# A blocked turn aborted before its recovery Stop (max-turns, user interrupt)
# leaves its marker behind. Harmless but unbounded, so writes sweep old ones.
fresh_log
mkdir -p "$recovery_log/pending"
touch -t 202001010000 "$recovery_log/pending/stale.marker"
touch "$recovery_log/pending/fresh.marker"
write_transcript "please refactor the auth module"
run_stop "$(stop_event '**Classification: Non-trivial**

winging it' false)" >/dev/null
ok "a stale marker is pruned on the next block" \
   "$([ -e "$recovery_log/pending/stale.marker" ] && echo present || echo pruned)" pruned
ok "a fresh marker survives the prune" \
   "$([ -e "$recovery_log/pending/fresh.marker" ] && echo present || echo pruned)" present

# ------------------------------------------------------------------ report --
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
