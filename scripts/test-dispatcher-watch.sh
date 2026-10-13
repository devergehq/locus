#!/bin/sh
# Unit tests for the watcher lifecycle in skills/dispatcher/dispatcher.py (DEV-795).
#
# Every case runs against a THROWAWAY instance under mktemp. That is not tidiness:
# ~/.locus/data/dispatcher/<instance>/runtime/ is in use by a live dispatcher and the
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
# Belt as well as braces. The narrowed PATH above is what keeps `review-desk` out of reach, and
# nothing here sets `review_desk_id` on a ledger entry so `Watcher.review_desk` returns before it
# asks anything. But DEV-959 added a block that puts `$work/bin` on the front of PATH for a `gh`
# stand-in, and the next person to need a `review-desk` stand-in is one line from a harness that
# opens the live store under `~/.review-desk` -- which a live dispatcher is writing to. Set here,
# inside $work, so that line cannot be the one that does it.
export REVIEW_DESK_DB="$work/review-desk.db"
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
  # `gh-test-1` has no `mode` in its entry, so `key_mode` reads the `gh-` prefix as a review and
  # the DEV-959 branch answers first. Same outcome, different sentence; the `done`-only path is
  # pinned on an implement key a few lines down, where it is still the one deciding.
  ok "  naming the PR state"                     "$(says "pull request is $state")" yes
  # The cursor is KEPT: pr_status lives only in it, so deleting it would make the next relaunch
  # under the persistent Monitor re-derive the merge over a full tick's API calls, forever.
  ok "  and keeps the cursor it read it from"    "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" yes
  ok "  and reports that it kept it"             "$(says cursor_removed.:.false)" yes
done
put gh-test-1 status=merged --by test
cursor
ok "a merged ledger status stops too"            "$(watch gh-test-1)" 0
ok "  and removes the cursor, being ledger-only" "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" no

echo "DEV-959: a review's eyes close when its pull request does, at any status"
# The bug, by status. `watch_stop_reason` was merge-aware on the `done` path alone, so a review
# worker that was anything else ran to the 120-hour ceiling: on 13 October the session for one
# real pull request was `active` mid-round when the pull request merged, and was still there
# hours later telling its principal "the draft was never posted".
for status in active needs-input stopped claimed; do
  put gh-test-1 "status=$status" --by test
  for state in merged closed; do
    cursor "$state"
    ok "'$status' plus a $state PR stops"        "$(watch gh-test-1)" 0
    ok "  naming what is left to do"             "$(says "nothing is left to revise")" yes
    ok "  and keeping the cursor"                "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" yes
  done
  cursor open
  ok "'$status' with an OPEN PR keeps watching"  "$(watch gh-test-1 --once)" 0
  ok "  and does not stop"                       "$(says watch_stopped)" no
done
# A cursor that has armed and not yet read the pull request is a watcher that is listening, and
# reading an absent `pr_status` as closed would stop every review watcher on its first pass.
put gh-test-1 status=active --by test
cursor
ok "no pr_status at all keeps watching"          "$(watch gh-test-1 --once)" 0
ok "  and does not stop"                         "$(says watch_stopped)" no

echo "DEV-962: and when its pull request goes to draft, which is reversible"
# A draft is NOT a state GitHub reports in `state` -- a draft pull request is `open` -- so this
# needed a field of its own on the cursor. Before it, a review worker whose pull request was
# pulled back to a draft went on waiting for a sign-off nobody could act on until the 120-hour
# ceiling; #9541's session was one of them.
#
# The stop is a PAUSE and the merge stop is an end, and the difference is what the two sentences
# carry: a draft keeps the rounds, the draft and any sign-off, and the review returns on the
# round it was on when the author marks it ready.
draft_cursor () {
  printf '{"pr": {"repo": "o/r", "number": 1}, "pr_status": "open", "pr_draft": %s}' "$1" \
    > "$inst/runtime/watch/gh-test-1.json"
}
# skip_drafts <true|false> -> the instance's own statement about whether a draft is work.
skip_drafts () { python3 -c "
import json, pathlib, sys
p = pathlib.Path('$inst/config.json'); c = json.loads(p.read_text())
c['github']['skip_drafts'] = sys.argv[1] == 'true'
p.write_text(json.dumps(c, indent=2))" "$1"; }
for status in active needs-input stopped claimed done; do
  put gh-test-1 "status=$status" --by test
  draft_cursor true
  ok "'$status' plus a draft PR stops"           "$(watch gh-test-1)" 0
  ok "  naming the draft, not a merge"           "$(says "pull request is a draft")" yes
  ok "  and saying it comes back when it is ready" "$(says "marks it ready again")" yes
  # `pull_request`, not `ledger`: `_common.md` reads `ledger` as "nothing more will arrive on
  # this key", which is false of a draft -- the key is coming back. Same distinction DEV-959
  # drew for the merge, and for the same reason.
  ok "  with reason pull_request, not ledger"    "$(says "\"reason\": \"pull_request\"")" yes
  ok "  and keeping the cursor"                  "$([ -f "$inst/runtime/watch/gh-test-1.json" ] && echo yes || echo no)" yes
  draft_cursor false
  ok "'$status' with a ready PR keeps watching"  "$(watch gh-test-1 --once)" 0
done
# An absent `pr_draft` is a cursor that has armed and not yet read the pull request, exactly as
# an absent `pr_status` is. Reading it as a draft would stop every review watcher on its first
# pass -- the same failure the `pr_status` control above exists for.
put gh-test-1 status=active --by test
cursor open
ok "no pr_draft at all keeps watching"           "$(watch gh-test-1 --once)" 0
ok "  and does not stop"                         "$(says watch_stopped)" no
# **A merge beats a draft**, because a draft that then merges is over rather than paused. The
# order of the two branches is what says so; this is the assertion that keeps it.
put gh-test-1 status=active --by test
printf '{"pr": {"repo": "o/r", "number": 1}, "pr_status": "merged", "pr_draft": true}' \
  > "$inst/runtime/watch/gh-test-1.json"
ok "a merged draft stops as a merge"             "$(watch gh-test-1)" 0
ok "  naming what is left to do, not the draft"  "$(says "nothing is left to revise")" yes
# **Gated on the instance's own `skip_drafts`**, which is the same key the poller's draft
# handling is gated on -- so an instance that reviews drafts neither takes them out of play nor
# stops their workers, and the two halves cannot disagree.
skip_drafts false
put gh-test-1 status=active --by test
draft_cursor true
ok "with skip_drafts off a draft keeps watching" "$(watch gh-test-1 --once)" 0
ok "  and does not stop"                         "$(says watch_stopped)" no
skip_drafts true
# And only a REVIEW's, like the merge stop: an implement worker's pull request is routinely a
# draft while it is being written, and stopping its watcher would make it deaf for most of its
# life.
put impl-test-1 mode=implement status=active --by test
printf '{"pr": {"repo": "o/r", "number": 1}, "pr_status": "open", "pr_draft": true}' \
  > "$inst/runtime/watch/impl-test-1.json"
ok "implement with a draft PR keeps watching"    "$(watch impl-test-1 --once)" 0
ok "  and does not stop"                         "$(says watch_stopped)" no

echo "  and only a review's: every other mode is left as it was"
# Narrow on purpose. `implement.md` writes `status=done --note \"merged\"` only once it has SEEN
# the merge, and a merged pull request still collects review comments its author should answer --
# so stopping an implement worker's watcher at the merge would make it deaf at exactly the moment
# it has something to answer. The key is lower-case so it cannot match LINEAR_KEY: `Watcher.issue`
# would otherwise reach api.linear.app from a unit test.
impl_cursor () {
  printf '{"pr": {"repo": "o/r", "number": 1}, "pr_status": "%s"}' "$1" \
    > "$inst/runtime/watch/impl-test-1.json"
}
for status in active needs-input stopped; do
  put impl-test-1 mode=implement "status=$status" --by test
  impl_cursor merged
  ok "implement '$status' keeps watching a merge" "$(watch impl-test-1 --once)" 0
  ok "  and does not stop"                        "$(says watch_stopped)" no
done
# The `done` path is unchanged for them, which is DEV-795's own fix and must not have moved.
put impl-test-1 mode=implement status=done --by test
impl_cursor merged
ok "implement 'done' plus a merge still stops"   "$(watch impl-test-1)" 0
ok "  by the done path, in its own words"        "$(says "ledger status 'done' and its PR is merged")" yes

echo "watch_stopped says WHICH thing closed the watcher's eyes"
# `cmd_watch` hard-coded `reason: "ledger"` on every stop, which was true while the ledger was
# the only thing that could decide one. `_common.md` reads `ledger` as "your key's status says
# nothing more will arrive on it ... nothing to do" -- told to an `active` worker on a merged
# pull request, that is a lie in the one direction that matters.
put gh-test-1 status=active --by test
cursor merged
run gh-test-1
ok "a merge stops it with reason pull_request"    "$(says '"reason": "pull_request"')" yes
ok "  and not with reason ledger"                 "$(says '"reason": "ledger"')" no
put gh-test-1 status=discarded --by test
cursor merged
run gh-test-1
ok "a dead ledger status still says ledger"       "$(says '"reason": "ledger"')" yes
put gh-test-1 status=done --by test
cursor merged
run gh-test-1
ok "and so does done plus a merge, on an implement key" "$(says '"reason": "pull_request"')" yes

echo "A watcher arming over an already-closed pull request says so on its first tick"
# `pull_request` suppresses ALL history on a first tick, so a replacement dispatched after the
# merge heard nothing about the one fact that decides its whole brief. One exception, for the
# same reason `review_desk()` makes one: a state that has already happened cannot be waited for.
#
# This is the only block in this file that lets `Watcher.pull_request` run, so it is the only one
# that needs a `gh`. A stand-in on a PATH of its own, named per call so the assertions cannot
# pass off the wrong endpoint, and it refuses anything it was not written for rather than
# answering a shape the test happened to assume -- which is how `pr_state`'s null shipped.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'GHSTANDIN'
#!/bin/sh
case "$*" in
  "api repos/o/r/pulls/1")
    cat "$WATCHWORK/pr.json" ;;
  "api repos/o/r/pulls/1/reviews?per_page=100"|*"/comments?since="*)
    echo '[]' ;;
  *)
    echo "stand-in gh: unhandled call: $*" >&2; exit 1 ;;
esac
GHSTANDIN
chmod +x "$work/bin/gh"
export WATCHWORK="$work"
GHPATH="$work/bin:$PATH"

# ghwatch <args...> -> like `watch`, with the stand-in gh reachable
ghwatch () { set +e; PATH="$GHPATH" D watch "$@" >"$work/out" 2>"$work/err"; c=$?; set -e; echo "$c"; }

# A FRESH cursor, which is what makes the tick a first one. The merge-stop path keeps the cursor
# it read, so a replacement only ever gets here when `D reap` has pruned it or the key is new.
fresh () { rm -f "$inst/runtime/watch/gh-test-1.json" "$inst/runtime/watch/impl-test-1.json"; }

echo '{"head":{"sha":"deadbee"},"state":"closed","merged":true}' > "$work/pr.json"
put gh-test-1 mode=review status=active --by test
fresh
ok "a review arming over a merge is told at once" "$(ghwatch gh-test-1 --pr o/r#1 --once)" 0
ok "  as a pr_state carrying merged"              "$(says '"event": "pr_state".*"current": "merged"')" yes
ok "  marked as the first tick, not a change"     "$(says '"first": true')" yes
ok "  and with no previous state invented"        "$(says '"previous": null')" yes

echo '{"head":{"sha":"deadbee"},"state":"closed","merged":false}' > "$work/pr.json"
fresh
ok "a closed one is told too"                     "$(ghwatch gh-test-1 --pr o/r#1 --once)" 0
ok "  as a pr_state carrying closed"              "$(says '"event": "pr_state".*"current": "closed"')" yes

# The case the suppression was written for, and it must stay suppressed: nothing has happened.
echo '{"head":{"sha":"deadbee"},"state":"open","merged":false}' > "$work/pr.json"
fresh
ok "an OPEN pull request is still suppressed"     "$(ghwatch gh-test-1 --pr o/r#1 --once)" 0
ok "  saying nothing about its state"             "$(says '"event": "pr_state"')" no

# And only a review. `implement.md` turns a `pr_state` merged into `status=done --note "merged"`,
# so a replacement implement worker -- re-queued because the work was NOT finished, arming at
# _common.md step 3 before it reads the ticket at step 4 -- would report itself done over a pull
# request somebody else closed, before reading anything.
echo '{"head":{"sha":"deadbee"},"state":"closed","merged":true}' > "$work/pr.json"
put impl-test-1 mode=implement status=active --by test
fresh
ok "an implement worker is NOT told on arming"    "$(ghwatch impl-test-1 --pr o/r#1 --once)" 0
ok "  so it writes no false done"                 "$(says '"event": "pr_state"')" no
# The merge is seen and acted on in the SAME pass, which is what the ticket's "within one watch
# interval" asks for. With the stop check only at the top of the loop it waited out a sleep as
# well -- on one live instance's 300-second interval, ten minutes of a watcher polling a
# shipped pull request. `--max-ticks 5` bounds the run; the stop must beat it to the exit.
echo '{"head":{"sha":"deadbee"},"state":"open","merged":false}' > "$work/pr.json"
put gh-test-1 mode=review status=active --by test
fresh
run_gh=$(ghwatch gh-test-1 --pr o/r#1 --once)
echo '{"head":{"sha":"deadbee"},"state":"closed","merged":true}' > "$work/pr.json"
interval 1
ok "a merge stops the watcher in the same pass"   "$(ghwatch gh-test-1 --pr o/r#1 --max-ticks 5)" 0
ok "  after one tick, not two"                    "$(python3 -c "
import json
print(*[e['ticks'] for e in map(json.loads, open('$work/out')) if e['event'] == 'watch_stopped'])")" 1
ok "  with the pull_request reason"               "$(says '"reason": "pull_request"')" yes
ok "  and not by running out of ticks"            "$(says max_ticks)" no
# `--once` is left alone: it means one pass and exit, and it already exits.
fresh
ok "--once over a merge still just ticks"         "$(ghwatch gh-test-1 --pr o/r#1 --once)" 0
ok "  and emits no stop reason"                   "$(says watch_stopped)" no

# It still hears the TRANSITION, which is the path implement.md was written against and which
# this must not have taken away: arm over an open pull request, then merge it under the watcher.
echo '{"head":{"sha":"deadbee"},"state":"open","merged":false}' > "$work/pr.json"
fresh
run_gh=$(ghwatch impl-test-1 --pr o/r#1 --once)
echo '{"head":{"sha":"deadbee"},"state":"closed","merged":true}' > "$work/pr.json"
ok "  but a merge UNDER it is still reported"     "$(ghwatch impl-test-1 --pr o/r#1 --once)" 0
ok "  as a transition out of open"                "$(says '"event": "pr_state".*"previous": "open", "current": "merged"')" yes

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
# DEV-959 made a review key's cursor prunable at ANY status, which is right -- a merged pull
# request is finished whatever the ledger says -- and it made `stop[0]` able to be absent for the
# first time: every branch before it was keyed on the status itself, so there was always a word to
# print. An entry with no `status` field now reaches this line, and it used to read "is None".
# `gh-test-4`, not -3: the live-watcher block below owns -3, and a cursor saying merged under a
# review key is now exactly what makes a watcher exit before that block can test reap at all.
put gh-test-4 mode=review --by test   # mode and no status: what `ledger_put` writes for that
printf '{"pr": {"repo": "o/r", "number": 4}, "pr_status": "merged"}' \
  > "$inst/runtime/watch/gh-test-4.json"
set +e; D reap --dry-run > "$work/out" 2>&1; set -e
ok "a merged review cursor is prunable at any status" "$(says 'would prune gh-test-4.json')" yes
ok "  and a statusless entry does not print None"     "$(says 'is None')" no
ok "  it says so in words instead"                    "$(says 'gh-test-4 is no status')" yes
rm -f "$inst/runtime/watch/gh-test-4.json"
# A leftover FILE must not stop the Dispatcher starting. SKILL.md's start-up step says "anything
# cross: tell your principal and stop", and one live instance holds 112 of these. An orphaned
# PROCESS earns that hard stop because it spends API budget; a dead file costs disk and can wait.
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
argv = \"/bin/zsh -c source /x/snapshot.sh 2>/dev/null || true && eval 'python3 /p/dispatcher.py --instance /i/acme-portal watch ACME-667 --pr o/r#1'\".split()
print(d.parse_watch_argv(argv))")" None
ok "a framework Python IS a watcher"             "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
argv = ['/opt/homebrew/Cellar/python@3.10/3.10.17/Frameworks/Python.framework/Versions/3.10/Resources/Python.app/Contents/MacOS/Python',
        '/p/dispatcher.py', '--instance', '/i/acme-portal', 'watch', 'ACME-667', '--pr', 'o/r#9471']
print(d.parse_watch_argv(argv)['key'])")" ACME-667
ok "--pr's value is not read as the key"         "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', 'watch', '--pr', 'Acme-Corp/acme-portal#9395', 'ACME-614'])['key'])")" ACME-614
ok "--instance=PATH equals form parses"          "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', '--instance=/i/acme-portal', 'watch', 'K'])['instance'])")" /i/acme-portal
ok "--max-hours value is not read as the key"    "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', 'watch', '--max-hours', '2', 'ACME-563'])['key'])")" ACME-563
ok "--max-ticks value is not read as the key"    "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', 'watch', '--max-ticks', '5', 'ACME-563'])['key'])")" ACME-563
ok "--exit-on-done consumes no value"            "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['python3', '/p/dispatcher.py', 'watch', '--exit-on-done', 'ACME-563'])['key'])")" ACME-563
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
argv = 'claude --prompt cmd_watch in dispatcher.py never stops, run dispatcher.py watch ACME-1'.split()
print(d.parse_watch_argv(argv))")" None
ok "the script run directly is a watcher"        "$(python3 -c "
import sys; sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(d.parse_watch_argv(['/p/dispatcher.py', 'watch', 'ACME-9'])['key'])")" ACME-9

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
        '--instance', '/i/acme-portal', 'watch', 'gh-acme-portal-9395']
print(d.parse_watch_argv(argv)['key'])")" gh-acme-portal-9395
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
