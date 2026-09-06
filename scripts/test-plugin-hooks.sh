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
ok "blocks a turn with no classification line" \
   "$(run_stop "$(stop_event 'Here you go, all done.' false)")" 2
ok "block reason is non-empty" \
   "$([ -s "$work/stderr" ] && echo yes || echo no)" yes
ok "allows a trivial classification" \
   "$(run_stop "$(stop_event '**Classification: Trivial**

Renamed it.' false)")" 0
ok "blocks non-trivial with no skill invocation" \
   "$(run_stop "$(stop_event '**Classification: Non-trivial**

I will wing it.' false)")" 2

write_transcript "please refactor the auth module" skill
ok "allows non-trivial when the skill fired" \
   "$(run_stop "$(stop_event '**Classification: Non-trivial**

Phase 1 OBSERVE.' false)")" 0

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
   "$(run_stop "$(stop_event 'locus: skip — no classification needed' false)")" 2

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
ok "the ceiling re-entry did not log a second record" \
   "$(python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print("yes" if all(r["prompt_id"] == "P1" for r in rows) else "no")' "$logfile")" yes

# ------------------------------------------------------------------ report --
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
