#!/bin/sh
# Unit tests for the watcher lifecycle in skills/dispatcher/dispatcher.py (DEV-795).
#
# Every case runs against a THROWAWAY instance under mktemp. That is not tidiness:
# ~/.locus/data/dispatcher/tc-portal/runtime/ is in use by a live dispatcher and the
# watcher processes this change exists to stop, and a test that reaped one of those
# out from under the running operation would be a self-inflicted outage.
#
# No test here makes a network call, and that is a property of the fixture rather
# than of mocking. The key `gh-test-1` does not match LINEAR_KEY, so `Watcher.issue`
# returns before it reaches Linear; the ledger entry names no repo or number, so
# `Watcher.pull_request` returns before it reaches GitHub. A watcher on it is a real
# process running the real loop that happens to have nothing to ask anyone. That is
# what makes it safe to leave one running in the background and reap it for real.
#
# What is NOT covered, and why:
#
#   * `Watcher.issue` and `Watcher.pull_request` themselves. Both are pure API
#     plumbing, and a mock of `gh` and `linear()` elaborate enough to test them
#     would be a larger bug surface than the code it checked.
#   * The 120-hour default reaching its deadline. Asserted through `--max-hours`
#     with a tiny value instead; the arithmetic is one multiplication.
#   * `reap` against a watcher belonging to another instance. Constructing a second
#     live instance's watcher means a second live watcher, and the sparing logic is
#     asserted on the parse instead (`parse_watch_argv` plus a path comparison).
set -eu

# No `review-desk` on PATH, deliberately. Watcher.review_desk asks it about any entry carrying a review_desk_id,
# and a real install — `~/.local/bin/review-desk` on the developer's own machine, most likely —
# would answer from the live store under `~/.review-desk`. This harness is about the logic, and
# absent is the state it was written against. Narrowed here rather than stubbed because nothing
# in it asserts anything about Review Desk.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")"
export PATH

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
disp="$root/skills/dispatcher/dispatcher.py"

work=$(mktemp -d)
inst="$work/inst"
cleanup () {
  # Kill anything this test started, and nothing else: only pids recorded in $work.
  for f in "$work"/*.pid; do
    [ -f "$f" ] || continue
    kill "$(cat "$f")" 2>/dev/null || true
  done
  rm -rf "$work"
}
trap cleanup EXIT

pass=0
fail=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-56s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-56s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

D () { python3 "$disp" --instance "$inst" "$@"; }
# put <key> <fields...> -> set ledger fields, quietly
put () { D ledger put "$@" >/dev/null; }
# says <text> -> yes/no: is this text anywhere in the last run's stdout?
says () { grep -q -- "$1" "$work/out" && echo yes || echo no; }
# watch <args...> -> exit code, stdout in $work/out
watch () { set +e; D watch "$@" >"$work/out" 2>"$work/err"; c=$?; set -e; echo "$c"; }
# run <args...> -> run a watcher for its output only, discarding the exit code
run () { watch "$@" >/dev/null; }
# interval <secs> -> rewrite the throwaway config's watch_interval_secs
interval () { python3 -c "
import json, pathlib, sys
p = pathlib.Path('$inst/config.json'); c = json.loads(p.read_text())
c['limits']['watch_interval_secs'] = int(sys.argv[1])
p.write_text(json.dumps(c, indent=2))" "$1"; }

mkdir -p "$inst/runtime"
python3 - "$root" "$inst" <<'PY'
import json, sys, pathlib
root, inst = sys.argv[1], pathlib.Path(sys.argv[2])
cfg = json.loads((pathlib.Path(root) / "skills/dispatcher/config.example.json").read_text())
cfg["limits"]["watch_interval_secs"] = 1          # so a multi-tick test finishes in a second
cfg["limits"]["poll_interval_secs"] = 1
(inst / "config.json").write_text(json.dumps(cfg, indent=2))
PY

echo "A watcher stops when its key is finished with it"
put gh-test-1 status=active --by test
ok "a live key ticks and exits 0 with --once"    "$(watch gh-test-1 --once)" 0
ok "  and says nothing about stopping"           "$(says watch_stopped)" no
ok "  and leaves a cursor behind"                "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" yes

for status in discarded failed lost skipped deferred; do
  put gh-test-1 "status=$status" --by test
  ok "'$status' stops the loop with no --once"   "$(watch gh-test-1)" 0
  ok "  and names the reason"                    "$(says "\"reason\": \"ledger\"")" yes
  ok "  and removes the cursor"                  "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" no
  put gh-test-1 status=active --by test
  run gh-test-1 --once                           # rebuild the cursor for the next status
done

echo "A relaunch onto a dead key costs no ticks"
put gh-test-1 status=discarded --by test
ok "exits before the first tick"                 "$(run gh-test-1; python3 -c "
import json
print(*[e['ticks'] for e in map(json.loads, open('$work/out')) if e['event'] == 'watch_stopped'])")" 0

echo "'done' is terminal unless there is a review to wait for"
# cursor [pr-state] -> rewrite gh-test-1's cursor. No argument means "no PR known at all",
# which is the case investigate/decide/decompose workers leave behind: they write status=done
# and never open a PR. Gating the whole done branch on pr_status left every one of those
# running the full ceiling, and doctor called it "working".
cursor () {
  if [ $# -eq 0 ]; then
    printf '{}' > "$inst/runtime/watch/gh-test-1.json"
  else
    printf '{"pr": {"repo": "o/r", "number": 1}, "pr_status": "%s"}' "$1" \
      > "$inst/runtime/watch/gh-test-1.json"
  fi
}
put gh-test-1 status=done --by test
cursor
ok "done with no PR at all stops in one tick"    "$(watch gh-test-1)" 0
ok "  saying there is no PR to watch"             "$(says 'no pull request to watch')" yes
cursor open
ok "done with an OPEN PR keeps watching"         "$(watch gh-test-1 --once)" 0
ok "  and does not stop"                          "$(says watch_stopped)" no
cursor open
ok "--exit-on-done stops on done regardless"     "$(watch gh-test-1 --exit-on-done)" 0
ok "  naming the flag"                            "$(says exit-on-done)" yes
for state in merged closed; do
  cursor "$state"
  ok "done plus a $state PR stops in one tick"   "$(watch gh-test-1)" 0
  ok "  naming the PR state"                     "$(says "its PR is $state")" yes
  # The cursor is KEPT: pr_status lives only in it, so deleting it would make the next relaunch
  # under the persistent Monitor re-derive the merge over a full tick's API calls, forever.
  ok "  and keeps the cursor it read it from"    "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" yes
  ok "  and reports that it kept it"             "$(says cursor_removed.:.false)" yes
done
put gh-test-1 status=merged --by test
cursor
ok "a merged ledger status stops too"            "$(watch gh-test-1)" 0
ok "  and removes the cursor, being ledger-only" "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" no

echo "The ceiling binds even when the ledger never moves"
put gh-test-1 status=active --by test
ok "--max-ticks 2 stops after 2 ticks"           "$(run gh-test-1 --max-ticks 2; grep -c '"reason": "max_ticks"' "$work/out")" 1
ok "  reporting the tick count"                   "$(says '"ticks": 2')" yes
ok "  and keeping the cursor"                     "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" yes
ok "--max-hours 0 stops after one tick"          "$(run gh-test-1 --max-hours 0; grep -c '"reason": "ceiling"' "$work/out")" 1
ok "  and keeps the cursor too"                   "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" yes
ok "a key with no ledger entry is announced"     "$(run gh-absent-9 --once; says watch_unknown_key)" yes

echo "Cursor files for finished keys are removable"
put gh-test-2 status=discarded --by test
: > "$work/x"; printf '{}' > "$inst/runtime/watch/gh-test-2.json"
printf '{}' > "$inst/runtime/watch/gh-test-2.reviewer.json"
printf '{}' > "$inst/runtime/watch/no-such-key.json"
put gh-test-1 status=active --by test
printf '{}' > "$inst/runtime/watch/gh-test-1.json"
set +e; D reap --dry-run > "$work/out" 2>&1; set -e
ok "dry run names the finished key's cursor"     "$(says 'would prune gh-test-2.json')" yes
ok "dry run names its --as cursor too"           "$(says 'would prune gh-test-2.reviewer.json')" yes
ok "dry run leaves a live key's cursor alone"    "$(says 'would prune gh-test-1.json')" no
ok "dry run deletes nothing"                     "$([ -f "$inst/runtime/watch/gh-test-2.json" ] && echo yes || echo no)" yes
set +e; D reap > "$work/out" 2>&1; set -e
ok "reap removes the finished key's cursor"      "$([ -f "$inst/runtime/watch/gh-test-2.json" ] && echo yes || echo no)" no
ok "reap removes its --as cursor"                "$([ -f "$inst/runtime/watch/gh-test-2.reviewer.json" ] && echo yes || echo no)" no
ok "reap keeps the live key's cursor"            "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" yes
ok "reap keeps an unattributable cursor"         "$([ -f "$inst/runtime/watch/no-such-key.json" ] && echo yes || echo no)" yes
ok "  and says it did"                           "$(says 'match no ledger entry')" yes
# A leftover FILE must not stop the Dispatcher starting. SKILL.md's start-up step says "anything
# cross: tell your principal and stop", and tc-portal holds 112 of these. An orphaned PROCESS
# earns that hard stop because it spends API budget; a dead file costs disk and can wait.
printf '{}' > "$inst/runtime/watch/gh-test-2.json"
put gh-test-2 status=discarded --by test
set +e; D doctor > "$work/out" 2>&1; set -e
ok "a stale cursor is reported, not failed"      "$(grep -q "watch cursors" "$work/out" && grep -q "x watch cursors" "$work/out" && echo yes || echo no)" no
ok "  and is still named for the next reap"      "$(says 'for finished keys')" yes

echo "doctor and reap see a real live watcher"
# The interval goes up to a minute first, and that is the point of the case rather than a
# detail of it: at one second the watcher notices the discarded status and exits on its own
# before `reap` can be tested at all -- the fix defeating the test for the fix. A watcher
# asleep on a key that went dead under it is also exactly the state the nine orphans are in.
interval 60
put gh-test-3 status=active --by test
python3 "$disp" --instance "$inst" watch gh-test-3 >"$work/w.log" 2>&1 &
echo $! > "$work/w.pid"
sleep 2
set +e; D doctor > "$work/out" 2>&1; set -e
ok "doctor lists the live watcher's pid"         "$(says "$(cat "$work/w.pid")")" yes
ok "  with its key"                              "$(says gh-test-3)" yes
ok "  its ledger status"                         "$(says active)" yes
ok "  and calls it working, not an orphan"       "$(says 'ORPHAN')" no
put gh-test-3 status=discarded --by test
set +e; D doctor > "$work/out" 2>&1; set -e
ok "doctor flags it once the key is discarded"   "$(says 'ORPHAN')" yes
ok "  and fails the watchers check"              "$(says '✗ watchers')" yes
set +e; D reap --dry-run > "$work/out" 2>&1; set -e
ok "reap --dry-run would kill it"                "$(says "would kill  pid $(cat "$work/w.pid")")" yes
ok "  and it is still alive"                     "$(kill -0 "$(cat "$work/w.pid")" 2>/dev/null && echo yes || echo no)" yes
set +e; D reap > "$work/out" 2>&1; set -e
ok "reap reports the kill with its pid"          "$(says "killed      pid $(cat "$work/w.pid")")" yes
sleep 1
ok "  and the process is gone"                   "$(kill -0 "$(cat "$work/w.pid")" 2>/dev/null && echo yes || echo no)" no
set +e; D doctor > "$work/out" 2>&1; set -e
ok "doctor is clean afterwards"                  "$(says 'ORPHAN')" no
interval 1

ok "the usage header claims no --all flag"       "$(grep -c -- "reap .--dry-run. .--all." "$disp")" 0

echo "reap refuses the processes that look like watchers but are not"
ok "a zsh -c wrapper is not a watcher"           "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
argv = \"/bin/zsh -c source /x/snapshot.sh 2>/dev/null || true && eval 'python3 /p/dispatcher.py --instance /i/tc-portal watch DAR-667 --pr o/r#1'\".split()
print(d.parse_watch_argv(argv))")" None
ok "a framework Python IS a watcher"             "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
argv = ['/opt/homebrew/Cellar/python@3.10/3.10.17/Frameworks/Python.framework/Versions/3.10/Resources/Python.app/Contents/MacOS/Python',
        '/p/dispatcher.py', '--instance', '/i/tc-portal', 'watch', 'DAR-667', '--pr', 'o/r#9471']
print(d.parse_watch_argv(argv)['key'])")" DAR-667
ok "--pr's value is not read as the key"         "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', 'watch', '--pr', 'Trilogy-Care/tc-portal#9395', 'DAR-614'])['key'])")" DAR-614
ok "--instance=PATH equals form parses"          "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', '--instance=/i/tc-portal', 'watch', 'K'])['instance'])")" /i/tc-portal
ok "--max-hours value is not read as the key"    "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', 'watch', '--max-hours', '2', 'DAR-563'])['key'])")" DAR-563
ok "--max-ticks value is not read as the key"    "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', 'watch', '--max-ticks', '5', 'DAR-563'])['key'])")" DAR-563
ok "--exit-on-done consumes no value"            "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', 'watch', '--exit-on-done', 'DAR-563'])['key'])")" DAR-563
ok "python3 -c holding the script is not one"    "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '-c', '/p/dispatcher.py', 'watch', 'K']))")" None
ok "a poll process is not a watcher"             "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', '--instance', '/i/x', 'poll']))")" None
ok "a claude session quoting the docs is not"    "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
argv = 'claude --prompt cmd_watch in dispatcher.py never stops, run dispatcher.py watch DAR-1'.split()
print(d.parse_watch_argv(argv))")" None
ok "the script run directly is a watcher"        "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['/p/dispatcher.py', 'watch', 'DAR-9'])['key'])")" DAR-9

echo "A watcher whose argv names no instance is only ours with evidence"
# Everything reap signals comes through attribute_instance. An argv with no --instance could
# belong to an instance reached through $DISPATCHER_INSTANCE, which instance_path allows to be
# an absolute path ANYWHERE -- so "the only instance installed" is not proof of ownership, and
# on a single-instance box that assumption would have made another instance's live watcher
# reapable. A cursor of ours is the only evidence available, since a process cannot read
# another process's environment.
att () { python3 -c "
import sys, pathlib
sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
d._instance = pathlib.Path('$inst')
print(d.attribute_instance({'key': '$1', 'as': None, 'instance': $2}, $3))"; }
printf '{}' > "$inst/runtime/watch/has-cursor.json"
rm -f "$inst/runtime/watch/no-cursor.json"
ok "--instance in argv answers outright"        "$(att no-cursor \"/i/named\" None)" /i/named
ok "no --instance, sole, our cursor: ours"      "$(att has-cursor None "pathlib.Path('$inst')")" "$inst"
ok "no --instance, sole, no cursor: unknown"    "$(att no-cursor None "pathlib.Path('$inst')")" None
ok "no --instance and no sole: unknown"         "$(att has-cursor None None)" None
ok "a relative --instance is not attributed"    "$(att has-cursor \"rel/path\" None)" None

echo "etime parses all four widths ps emits"
for pair in "04:26 266" "15:05:54 54354" "01-20:16:46 159406" "06-14:12:27 569547"; do
  set -- $pair
  ok "etime $1"                                  "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d; print(d.etime_secs('$1'))")" "$2"
done

echo "status reports consecutive quiet ticks"
ok "a quiet tick increments the count"           "$(python3 -c "
import os, sys
os.environ['DISPATCHER_RUNTIME'] = '$inst/runtime'
sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
d._instance = __import__('pathlib').Path('$inst')
cfg = d.load_config()
p = d.Poller()
for _ in range(3): p.mark_quiet(True, cfg)
print(p.state['quiet_ticks'])")" 3
ok "an event resets it to zero"                  "$(python3 -c "
import os, sys
os.environ['DISPATCHER_RUNTIME'] = '$inst/runtime'
sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
d._instance = __import__('pathlib').Path('$inst')
cfg = d.load_config()
p = d.Poller()
for _ in range(3): p.mark_quiet(True, cfg)
p.mark_quiet(False, cfg)
print(p.state['quiet_ticks'], 'quiet_since' in p.state)")" "0 False"

echo "A quiet run is logged when it ends, so a threshold can come from a distribution"
rm -f "$inst/runtime/quiet-log.jsonl"
ok "the run length lands in quiet-log.jsonl"     "$(python3 -c "
import os, sys, json
os.environ['DISPATCHER_RUNTIME'] = '$inst/runtime'
sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
d._instance = __import__('pathlib').Path('$inst')
cfg = d.load_config()
p = d.Poller()
for _ in range(5): p.mark_quiet(True, cfg)
p.mark_quiet(False, cfg)          # run of 5 ends here
for _ in range(2): p.mark_quiet(True, cfg)
p.mark_quiet(False, cfg)          # run of 2 ends here
p.mark_quiet(False, cfg)          # not a run: logs nothing
print([json.loads(l)['ticks'] for l in open(d.quiet_log())])")" "[5, 2]"
ok "  with the seconds it lasted"                "$(python3 -c "
import json, sys
r = [json.loads(l) for l in open('$inst/runtime/quiet-log.jsonl')][0]
print(r['ticks'], r['interval_secs'], r['secs'])")" "5 1 5"
ok "  and the field order is the format"         "$(python3 -c "
import json
print(','.join(json.loads(open('$inst/runtime/quiet-log.jsonl').readline()).keys()))")" "ended_at,started_at,ticks,interval_secs,secs"
set +e; D status > "$work/out" 2>&1; set -e
ok "status reports the longest run seen"         "$(says 'longest 5 ticks')" yes

echo "A watcher's plugin version is read from its own script path"
ok "a 0.5.2 orphan is matched, not missed"       "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
argv = ['/usr/bin/python3', '/Users/x/.claude/plugins/cache/locus/locus/0.5.2/skills/dispatcher/dispatcher.py',
        '--instance', '/i/tc-portal', 'watch', 'gh-tc-portal-9395']
print(d.parse_watch_argv(argv)['key'])")" gh-tc-portal-9395
ok "  and its version is reported"               "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.script_version('/Users/x/.claude/plugins/cache/locus/locus/0.5.2/skills/dispatcher/dispatcher.py'))")" 0.5.2
ok "  a path with no version reads as unknown"   "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.script_version('/home/me/src/locus/skills/dispatcher/dispatcher.py'))")" None
set +e; D status > "$work/out" 2>&1; set -e
ok "a never-polled instance says so"             "$(says 'never polled')" yes
python3 - "$inst" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "runtime/poll-state.json"
p.write_text(json.dumps({"started": "2026-09-30T00:00:00+00:00", "quiet_ticks": 7,
                         "quiet_since": "2026-09-30T01:00:00+00:00"}))
PY
set +e; D status > "$work/out" 2>&1; set -e
ok "status prints the count"                     "$(says 'quiet ticks: 7 consecutive')" yes
ok "  with the time it went quiet"               "$(says 'since 2026-09-30T01:00:00')" yes

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
