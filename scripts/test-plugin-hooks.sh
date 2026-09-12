#!/bin/sh
# Unit tests for the plugin's hook wrapper.
#
# Everything about hook *behaviour* — the Stop gate, the dispatcher, the
# activation log — now lives in the binary and is covered by `cargo test`. What
# remains here is the one thing the binary cannot test about itself: what
# happens when the binary is missing.
#
# That case is why this file still exists. A wrapper that failed closed would
# wedge every session; a wrapper that failed silently would make "the Algorithm
# never ran" indistinguishable from "the Algorithm was never needed". Both are
# tested below.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CLAUDE_PLUGIN_ROOT="$root"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export CLAUDE_PLUGIN_DATA="$work/plugindata"
export CLAUDE_CODE_SESSION_ID="test-session"

# The usual tools, deliberately without `locus`.
NOLOCUS="/usr/bin:/bin:/usr/sbin:/sbin"

pass=0
fail=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-54s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-54s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

wrapper="$root/hooks/via-locus-binary.sh"
run ()   { set +e; env PATH="$1" "$wrapper" "$2" >"$work/out" 2>"$work/err"; c=$?; set -e; echo "$c"; }
runoff() { set +e; env PATH="$1" LOCUS_HOOKS=off "$wrapper" "$2" >"$work/out" 2>"$work/err"; c=$?; set -e; echo "$c"; }
fresh () { rm -rf "$CLAUDE_PLUGIN_DATA"; }
bytes () { wc -c < "$1" | tr -d ' '; }

echo "Wrapper shape"
ok "wrapper is executable"          "$([ -x "$wrapper" ] && echo yes || echo no)" yes
ok "exits 0 with no event argument" "$(run "$PATH" '')" 0
ok "hooks.json declares six events" \
   "$(python3 -c "import json;print(len(json.load(open('$root/hooks/hooks.json'))['hooks']))")" 6
ok "Notification deliberately absent" \
   "$(python3 -c "import json;print('absent' if 'Notification' not in json.load(open('$root/hooks/hooks.json'))['hooks'] else 'present')")" absent
ok "all six entries share one shape" \
   "$(python3 -c "
import json,re
h=json.load(open('$root/hooks/hooks.json'))['hooks']
pat=re.compile(r'^\\\$\{CLAUDE_PLUGIN_ROOT\}/hooks/via-locus-binary\.sh [a-z-]+\$')
print('yes' if all(pat.match(v[0]['hooks'][0]['command']) for v in h.values()) else 'no')")" yes
ok "no python remains under hooks/" "$(find "$root/hooks" -name '*.py' | wc -l | tr -d ' ')" 0
ok "hooks/ is wrapper plus config only" "$(find "$root/hooks" -type f | wc -l | tr -d ' ')" 2

echo "Deliberate opt-out is silent"
fresh
ok "LOCUS_HOOKS=off exits 0"        "$(runoff "$NOLOCUS" session-start)" 0
ok "LOCUS_HOOKS=off says nothing"   "$(bytes "$work/out")" 0
ok "LOCUS_HOOKS=off warns nothing"  "$(bytes "$work/err")" 0

echo "Missing binary is loud, never blocking"
fresh
ok "SessionStart exits 0"           "$(run "$NOLOCUS" session-start)" 0
ok "emits valid JSON" \
   "$(python3 -c 'import json,sys;json.load(open(sys.argv[1]));print("yes")' "$work/out" 2>/dev/null || echo no)" yes
ok "names the problem"              "$(grep -q 'not on PATH' "$work/out" && echo yes || echo no)" yes
ok "names the fix, not just the fault" "$(grep -q 'cargo install' "$work/out" && echo yes || echo no)" yes
ok "tells the model to tell the user"  "$(grep -q 'Tell the user' "$work/out" && echo yes || echo no)" yes
ok "carries a systemMessage" \
   "$(python3 -c 'import json,sys;print("yes" if "systemMessage" in json.load(open(sys.argv[1])) else "no")' "$work/out")" yes
ok "also warns on stderr"           "$([ -s "$work/err" ] && echo yes || echo no)" yes

echo "Missing binary speaks at most once per session"
fresh
run "$NOLOCUS" session-start >/dev/null
ok "first event speaks"  "$([ "$(bytes "$work/out")" -gt 0 ] && echo yes || echo no)" yes
run "$NOLOCUS" user-prompt-submit >/dev/null
ok "second event silent" "$(bytes "$work/out")" 0
run "$NOLOCUS" stop >/dev/null
ok "third event silent"  "$(bytes "$work/out")" 0

echo "No hook ever exits 2 when degraded"
for ev in session-start user-prompt-submit stop pre-tool-use post-tool-use pre-compact; do
  fresh
  ok "$ev does not block" "$(run "$NOLOCUS" "$ev")" 0
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
