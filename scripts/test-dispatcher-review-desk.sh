#!/bin/sh
# Unit tests for the Review Desk half of skills/dispatcher/dispatcher.py (DEV-865).
#
# Three things are stood in for, and nothing else is:
#
#   review-desk  a shell script on PATH that answers from a recorded document and a mode file.
#                The real binary is Rust and needs a database; a recorded answer is what lets
#                the four kinds, an empty list, exit 1 and exit 2 all be driven from one place.
#                Every call it receives is appended to $work/rd.calls, so "the poller asked per
#                repository" is an assertion about argv rather than about an outcome.
#   gh           a shell script on PATH. The REAL `gh()` wrapper runs, so its JSON parsing and
#                its non-zero handling are under test; only the network is replaced.
#   linear()     mocked in the Python driver, because it goes out over urllib and no PATH fake
#                can reach it. It is the one thing a test here must not let through.
#
# Everything else is the real code path: the real argparse, the real `review_desk_run`, the real
# `allele_state` over a file this script writes, and the real cursor files.
#
# Nothing here touches ~/.locus/data/dispatcher or ~/.review-desk. Every instance is a throwaway
# under mktemp, which is not tidiness: a live dispatcher is polling one of those directories and
# a live Review Desk holds the other, and a test that wrote to either would be an outage.
#
# No test makes a network call, needs a credential, or needs a built binary, so this runs in CI
# beside the other harnesses.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
disp="$root/skills/dispatcher/dispatcher.py"

work=$(mktemp -d)
inst="$work/inst"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
PATH="$work/bin:$PATH"
export PATH
export RDWORK="$work"

pass=0
fail=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-60s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-60s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

# ---- the stand-in review-desk ---------------------------------------------------------------
# $RDWORK/rd.mode decides how `work list` answers. The exit codes are Review Desk's own, read off
# its README's table and confirmed against the real 0.1.0 binary: 0 including an empty list, 1
# understood-and-refused, 2 could-not-run.

cat > "$work/bin/review-desk" <<'STANDIN'
#!/bin/sh
printf '%s\n' "$*" >> "$RDWORK/rd.calls"
mode=$(cat "$RDWORK/rd.mode" 2>/dev/null || echo ok)
case "$1" in
  --version) echo "review-desk 9.9.9"; exit 0 ;;
esac
if [ "$1" = "db" ] && [ "$2" = "path" ]; then
  echo "{\"path\":\"$RDWORK/fake.db\"}"; exit 0
fi
case "$mode" in
  broken)
    echo '{"error":{"code":"cannot_open_database","message":"scripted broken","kind":"broken"}}'
    exit 2 ;;
  refused)
    echo '{"error":{"code":"not_found","message":"no review with id 7","kind":"refused"}}'
    exit 1 ;;
  notjson)
    # An older build whose `work list` prints a line for a person and no JSON at all.
    echo 'review-desk: nothing is waiting'; exit 0 ;;
  nowork)
    # The shape an even older build answers with: valid JSON, no `work` array.
    echo '{"reviews":[]}'; exit 0 ;;
  unexecutable) exit 126 ;;
esac
# mode ok: answer from a per-repository document if one exists, else the shared one.
doc="$RDWORK/rd.work"
for a in "$@"; do
  case "$prev" in --repo) slug=$(echo "$a" | tr '/' '-'); [ -f "$RDWORK/rd.work.$slug" ] && doc="$RDWORK/rd.work.$slug" ;; esac
  prev=$a
done
cat "$doc" 2>/dev/null || echo '{"work":[]}'
STANDIN
# `prev` is referenced before it is set on the first pass of that loop, and `set -u` is not in
# force inside the stand-in. Seed it anyway rather than relying on that.
sed -i.bak '1a\
prev=""
' "$work/bin/review-desk" && rm -f "$work/bin/review-desk.bak"
chmod +x "$work/bin/review-desk"

# ---- the stand-in gh ------------------------------------------------------------------------
# One case per call dispatcher.py actually makes. An unrecognised call exits 1 loudly rather
# than echoing null, so a new call site cannot pass these tests by being silently answered.

cat > "$work/bin/gh" <<'GHSTANDIN'
#!/bin/sh
printf '%s\n' "$*" >> "$RDWORK/gh.calls"
case "$*" in
  *"api graphql"*)
    echo '{"data":{"search":{"issueCount":0,"nodes":[]}}}'; exit 0 ;;
  "pr view "*)
    # Real `gh pr view` has NO `merged` field -- that one belongs to the REST API -- and it
    # exits 1 on an unknown one. The first version of this stand-in answered whatever it was
    # asked, so it confirmed a wrong field list instead of refusing it and a null `pr_state`
    # shipped. Refuse anything but `--json state`.
    case "$*" in
      *"--json state") : ;;
      *) echo 'Unknown JSON field: "'"${*##*--json }"'"' >&2; exit 1 ;;
    esac
    n=$3
    cat "$RDWORK/pr.$n.json" 2>/dev/null || echo '{"state":"OPEN"}'
    exit 0 ;;
  *--slurp*reviews*)
    cat "$RDWORK/reviews.json" 2>/dev/null || echo '[[]]'
    exit 0 ;;
  *"api repos/"*"/pulls/"*)
    echo '{"head":{"sha":"deadbee"},"state":"open","merged":false}'; exit 0 ;;
  *)
    echo "stand-in gh: unhandled call: $*" >&2; exit 1 ;;
esac
GHSTANDIN
chmod +x "$work/bin/gh"

echo '{"sessions":[],"archived_sessions":[]}' > "$work/allele.json"

# ---- the instance ---------------------------------------------------------------------------
# rd_block "" leaves config.json with NO review_desk block at all, which is the state every
# existing instance is in and the one the silence assertions are about.

instance () {
  rm -rf "$inst"; mkdir -p "$inst/runtime/ledger" "$inst/runtime/watch"
  python3 - "$inst/config.json" "$work/allele.json" "${1:-}" <<'PY'
import json, sys, pathlib
dest, state, block = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
cfg = {
  "linear": {"api_key_env": "TEST_NO_SUCH_TOKEN", "mcp_workspace": "ws", "team_key": "ZZ",
             "label_group_id": "g",
             "labels": {"todo": {"id": "L-todo", "name": "Agent - Todo"}},
             "modes": {"implement": {"trigger": "todo", "working": "todo"}}},
  "github": {"login": "devdeveloper", "review_query": "is:pr is:open", "skip_drafts": True},
  "allele": {"state_file": state, "default_project": "p",
             "repo_project_map": {"acme/portal": "portal"}},
  "traits": {"review": {"traits": "t", "role": "R"},
             "implement": {"traits": "t", "role": "R"}},
  "limits": {"max_workers": 15, "poll_interval_secs": 300, "watch_interval_secs": 300,
             "watch_max_hours": 1, "reemit_after_secs": 900, "blocked_alert_after_secs": 120,
             "max_lost_retries": 1},
}
if block:
    cfg["review_desk"] = json.loads(block)
dest.write_text(json.dumps(cfg, indent=2))
PY
  : > "$work/rd.calls"; : > "$work/gh.calls"
  echo ok > "$work/rd.mode"
  echo '{"work":[]}' > "$work/rd.work"
  rm -f "$work/rd.work."* "$work/pr."*.json "$work/reviews.json"
}

D () { python3 "$disp" --instance "$inst" "$@"; }
put () { D ledger put "$@" >/dev/null; }
says  () { grep -q -- "$1" "$work/out" && echo yes || echo no; }
count () { grep -c -- "$1" "$work/out" 2>/dev/null || true; }
# session <id> [status]: add a live allele session, so review_desk_live has something to find
session () {
  python3 - "$work/allele.json" "$1" "${2:-Idle}" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = json.loads(p.read_text())
s["sessions"].append({"id": sys.argv[2], "last_known_status": sys.argv[3],
                      "origin": {"kind": "dispatched"}})
p.write_text(json.dumps(s))
PY
}
no_sessions () { echo '{"sessions":[],"archived_sessions":[]}' > "$work/allele.json"; }

# work_doc <kind> <review_id> <repo> <pr> [entered_at] [ledger_id] [note]
work_doc () {
  python3 - "$work/rd.work" "$@" <<'PY'
import json, sys, pathlib
dest = pathlib.Path(sys.argv[1])
kind, rid, repo, pr = sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
entered = int(sys.argv[6]) if len(sys.argv) > 6 and sys.argv[6] else 1791520282
ledger = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else None
note = sys.argv[8] if len(sys.argv) > 8 and sys.argv[8] else None
dest.write_text(json.dumps({"work": [{
    "kind": kind, "review_id": rid, "repo": repo, "pr": pr, "head_sha": "3f9c2ab", "round": 1,
    "sign_off": None if kind == "review_requested" else "developer",
    "session_id": None, "ledger_id": ledger, "entered_at": entered, "note": note}]}))
PY
}

# ---- the Python driver ----------------------------------------------------------------------
# One Poller or Watcher scenario against the source named in $DISP, with `linear` mocked and
# nothing else. $DISP so the negative controls at the bottom can run the same scenarios against
# a reversed copy of the source.

cat > "$work/driver.py" <<'DRIVER'
import importlib.util, json, os, sys

spec = importlib.util.spec_from_file_location("disp_under_test", os.environ["DISP"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
os.environ["DISPATCHER_INSTANCE"] = os.environ["INST"]
# The one thing no PATH fake can reach. Everything else -- gh, review-desk, allele's state file
# -- runs for real against a stand-in or a temp file.
m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}

scenario, rest = sys.argv[1], sys.argv[2:]

if scenario == "poll":
    ticks = int(rest[0]) if rest else 1
    p = m.Poller()
    for i in range(ticks):
        print(json.dumps({"tick": i + 1}))
        p.tick()

elif scenario == "poll_fresh":
    # One tick per PROCESS-equivalent: a new Poller each time, as a host driving `poll --once`
    # on a cadence produces. The rate limit is persisted, so this must still emit once.
    for i in range(int(rest[0])):
        print(json.dumps({"run": i + 1}))
        m.Poller().tick()

elif scenario == "watch":
    w = m.Watcher(rest[0], None, None)
    for i in range(int(rest[1]) if len(rest) > 1 else 1):
        print(json.dumps({"tick": i + 1}))
        w.tick()
    print(json.dumps({"cursor": w.state.get("rd_seen")}))

elif scenario == "watch_reenter":
    # Tick, rewrite the recorded document with a NEW entered_at, tick again. A draft sent back,
    # revised and sent back again is `ready` in between, so the second send-back is a new item.
    w = m.Watcher(rest[0], None, None)
    w.tick()
    import pathlib
    doc = pathlib.Path(os.environ["RDWORK"]) / "rd.work"
    payload = json.loads(doc.read_text())
    payload["work"][0]["entered_at"] = int(payload["work"][0]["entered_at"]) + 90
    doc.write_text(json.dumps(payload))
    print(json.dumps({"tick": 2}))
    w.tick()

elif scenario == "fill_absent":
    # `init`'s reconciliation, without `init`: cmd_init needs Linear auth to mint labels, and the
    # behaviour under test is one function over two dicts.
    template = json.loads((m.CODE_DIR / "config.example.json").read_text())["review_desk"]
    existing = json.loads(rest[0])
    added = m.fill_absent("review_desk", existing, template)
    print(json.dumps({"added": sorted(added), "result": existing}))

elif scenario == "cfg":
    print(json.dumps(m.review_desk_cfg(json.loads(rest[0]))))

else:
    sys.exit("unknown scenario " + scenario)
DRIVER

run () {
  src=$1; scenario=$2; shift 2
  set +e
  DISP="$src" INST="$inst" python3 "$work/driver.py" "$scenario" "$@" >"$work/out" 2>"$work/err"
  c=$?
  set -e
  echo "$c"
}

# =============================================================================================
printf '\nSilence -- no review_desk block, no review-desk on PATH\n'
# The ticket's first acceptance criterion. An instance that has never heard of Review Desk must
# produce output in which the words do not appear, which is what makes the other three harnesses
# able to stay unchanged.

instance ""
mv "$work/bin/review-desk" "$work/review-desk.hidden"
put gh-portal-1 mode=review status=active repo=acme/portal number=1 session_id=s1 --by test
rc=$(run "$disp" poll 2)
ok "a poll tick exits clean with no Review Desk"       "$rc" 0
ok "  and says nothing about review_desk"              "$(count review_desk)" 0
ok "  nor about Review Desk by name"                   "$(count 'Review Desk')" 0
ok "  and asked the absent command nothing"            "$(wc -l < "$work/rd.calls" | tr -d ' ')" 0
rc=$(run "$disp" watch gh-portal-1 1)
ok "a watch tick exits clean"                          "$rc" 0
ok "  and says nothing about review_desk"              "$(count review_desk)" 0
set +e; D status > "$work/out" 2>&1; set -e
ok "\`status\` names no review_desk source"              "$(count review_desk)" 0
mv "$work/review-desk.hidden" "$work/bin/review-desk"

# =============================================================================================
printf '\nWhether Review Desk is used -- the mode matrix, through doctor\n'

doctor () { set +e; D doctor > "$work/out" 2>&1; set -e; grep 'review desk' "$work/out" || true; }
# hide/show: an absent command, which is a different fact from a broken one
hide () { mv "$work/bin/review-desk" "$work/review-desk.hidden"; }
show () { mv "$work/review-desk.hidden" "$work/bin/review-desk"; }

instance ''
ok "no block at all reads as auto"                     "$(doctor | grep -c 'mode auto')" 1
ok "  and reports the version"                         "$(doctor | grep -c '9.9.9')" 1
ok "  and the database path"                           "$(doctor | grep -c 'db .*fake.db')" 1
ok "  and whether the dashboard answers"               "$(doctor | grep -c 'dashboard')" 1
ok "  a silent dashboard does not fail the check"      "$(doctor | grep -c '^✓')" 1

instance '{"mode":"auto"}'
hide
ok "auto with no binary passes, and says so"           "$(doctor | grep -c '^✓ review desk: auto')" 1
ok "  naming it as not installed"                      "$(doctor | grep -c 'not installed')" 1
show

instance '{"mode":"on"}'
hide
ok "on with no binary FAILS doctor"                    "$(doctor | grep -c '^✗')" 1
ok "  and says reviews still run the old way"          "$(doctor | grep -c 'still run the way they did')" 1
show
ok "on with the binary passes"                         "$(doctor | grep -c '^✓ review desk: mode on')" 1

instance '{"mode":"off"}'
hide
ok "off with no binary is not a failure"               "$(doctor | grep -c '^✓ review desk: off')" 1
show
ok "off with the binary is still off"                  "$(doctor | grep -c '^✓ review desk: off')" 1
ok "  and off asked the binary nothing"                "$(grep -c 'work list' "$work/rd.calls")" 0

instance '{"mode":"auto"}'
echo broken > "$work/rd.mode"
ok "an installed Review Desk exiting 2 FAILS doctor"   "$(doctor | grep -c '^✗')" 1
ok "  calling it installed and broken"                 "$(doctor | grep -c 'installed and broken')" 1
ok "  and quoting its own error code"                  "$(doctor | grep -c cannot_open_database)" 1

instance '{"mode":"off"}'
echo broken > "$work/rd.mode"
ok "off stays silent about a broken one"               "$(doctor | grep -c '^✓ review desk: off')" 1

instance '{"mode":"auto"}'
echo refused > "$work/rd.mode"
ok "exit 1 with no --review is read as too old"        "$(doctor | grep -c '^✗')" 1
instance '{"mode":"auto"}'
echo notjson > "$work/rd.mode"
ok "exit 0 with no JSON is read as too old"            "$(doctor | grep -c 'too old to use')" 1
instance '{"mode":"auto"}'
echo nowork > "$work/rd.mode"
ok "JSON with no \`work\` array is read as too old"      "$(doctor | grep -c 'too old to use')" 1
instance '{"mode":"auto"}'
echo unexecutable > "$work/rd.mode"
ok "a non-zero that is not 1 or 2 is broken"           "$(doctor | grep -c '^✗')" 1

instance '{"mode":"of"}'
ok "an unknown mode is named by doctor"                "$(doctor | grep -c 'not one of auto, on, off')" 1
ok "  and reports that it is read as auto"             "$(doctor | grep -c "read as 'auto'")" 1
instance '{"brief_gate":"sometimes"}'
ok "an unknown brief_gate is named too"                "$(doctor | grep -c 'brief_gate')" 1

# =============================================================================================
printf '\nFound is never cached -- a fix and a break are both seen on the next call\n'
# The ticket's wording: the result must not be cached past a broken install being fixed, or the
# other way round. Two doctor runs with nothing between them but the mode file.

instance '{"mode":"auto"}'
echo broken > "$work/rd.mode"
first=$(doctor | grep -c '^✗')
echo ok > "$work/rd.mode"
second=$(doctor | grep -c '^✓')
ok "broken then fixed: the very next call is clean"    "$first$second" "11"
echo broken > "$work/rd.mode"
ok "fixed then broken: the next call fails again"      "$(doctor | grep -c '^✗')" 1
ok "  and nothing on disk remembers found-ness"        "$(grep -c review_desk_found "$disp")" 0

# =============================================================================================
printf '\nThe poller -- a third source, per repository served\n'

instance '{"mode":"auto"}'
work_doc review_requested 1 acme/portal 412
rc=$(run "$disp" poll 1)
ok "review_requested with no session dispatches"       "$(count '"event": "review_desk_requested"')" 1
ok "  on a key derived like a review request"          "$(says '"key": "gh-portal-412"')" yes
ok "  carrying the Review Desk review id"              "$(says '"review_desk_id": 1')" yes
ok "  the head commit as recorded"                     "$(says '"head_sha": "3f9c2ab"')" yes
ok "  the pull request's state"                        "$(says '"pr_state": "open"')" yes
ok "  and the dashboard link"                          "$(says 'reviews/1')" yes
ok "  and it asked per repository served"              "$(grep -c -- '--repo acme/portal' "$work/rd.calls")" 1
ok "  and nothing else"                                "$(grep -c -- '--repo' "$work/rd.calls")" 1
ok "  the tick exits clean"                            "$rc" 0

# Two repositories: the config's map and one learned from a ledger entry.
instance '{"mode":"auto"}'
put gh-billing-77 mode=review status=lost repo=acme/billing number=77 --by test
work_doc review_requested 1 acme/portal 412
rc=$(run "$disp" poll 1)
ok "a repo from the ledger is polled too"              "$(grep -c -- '--repo acme/billing' "$work/rd.calls")" 1
ok "  alongside the one from the config"               "$(grep -c -- '--repo acme/portal' "$work/rd.calls")" 1

instance '{"mode":"auto"}'
python3 - "$inst/config.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); c = json.loads(p.read_text())
c["allele"]["repo_project_map"] = {"OWNER/REPO": "your-project"}
p.write_text(json.dumps(c, indent=2))
PY
rc=$(run "$disp" poll 1)
ok "the template's OWNER/REPO placeholder is not asked" "$(grep -c -- '--repo' "$work/rd.calls")" 0
ok "  so an unedited instance says nothing"            "$(count review_desk)" 0

printf '\n  the three kinds that resume, and the one that does not\n'
for kind in brief_settled draft_sent_back draft_approved; do
  instance '{"mode":"auto"}'
  work_doc "$kind" 3 acme/portal 414 1791520339 "" "F2 is the same point as F1"
  rc=$(run "$disp" poll 1)
  ok "$kind with no session resumes"                   "$(count '"event": "review_desk_resume"')" 1
  ok "  naming the kind"                               "$(says "\"kind\": \"$kind\"")" yes
  ok "  with the draft link"                           "$(says 'reviews/3/draft')" yes
done
ok "draft_sent_back carries the developer's note"      "$(says 'F2 is the same point as F1')" yes
ok "  and how layer 2 was settled"                     "$(says '"sign_off": "developer"')" yes

instance '{"mode":"auto"}'
work_doc brief_settled 4 acme/portal 415
python3 - "$work/rd.work" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d["work"][0]["sign_off"] = "waived"
p.write_text(json.dumps(d))
PY
rc=$(run "$disp" poll 1)
ok "a waived brief is reported as waived, not confirmed" "$(says '"sign_off": "waived"')" yes

printf '\n  a live session owns its own item\n'
instance '{"mode":"auto"}'
work_doc draft_approved 5 acme/portal 416 1791520400 gh-portal-416
put gh-portal-416 mode=review status=active repo=acme/portal number=416 session_id=live-1 --by test
session live-1
rc=$(run "$disp" poll 1)
ok "an item with a live session emits nothing"         "$(count review_desk)" 0
ok "  and the tick is otherwise clean"                 "$rc" 0
# `done` is in ALIVE on purpose: a review worker reports done and stays up with its watcher.
put gh-portal-416 status=done --by test
rc=$(run "$disp" poll 1)
ok "a \`done\` key with a live session still owns it"    "$(count review_desk)" 0
# The session dies. Now it is a replacement's.
no_sessions
instance_keep=1
rc=$(run "$disp" poll 1)
ok "once the session is gone, a replacement is sent"   "$(count '"event": "review_desk_resume"')" 1
ok "  and the event carries the dead ledger status"    "$(says '"ledger_status": "done"')" yes
ok "  on the key Review Desk was linked to"            "$(says '"key": "gh-portal-416"')" yes

printf '\n  two consecutive polls dispatch once\n'
instance '{"mode":"auto"}'
work_doc review_requested 1 acme/portal 412
rc=$(run "$disp" poll 3)
ok "three ticks of one process emit one dispatch"      "$(count '"event": "review_desk_requested"')" 1
instance '{"mode":"auto"}'
work_doc review_requested 1 acme/portal 412
rc=$(run "$disp" poll_fresh 3)
ok "three fresh processes emit one dispatch"           "$(count '"event": "review_desk_requested"')" 1
ok "  because the rate limit is on disk"               "$(python3 -c "
import json;print('review_desk|review_requested|1|1791520282' in json.load(open('$inst/runtime/poll-state.json'))['emitted'])")" True

printf '\n  a merged or closed pull request is skipped\n'
for state in MERGED CLOSED; do
  instance '{"mode":"auto"}'
  work_doc review_requested 1 acme/portal 412
  if [ "$state" = MERGED ]; then
    echo '{"state":"MERGED"}' > "$work/pr.412.json"
  else
    echo '{"state":"CLOSED"}' > "$work/pr.412.json"
  fi
  rc=$(run "$disp" poll 1)
  ok "an item on a $state pull request is skipped"      "$(count review_desk)" 0
done
instance '{"mode":"auto"}'
work_doc review_requested 1 acme/portal 412
echo '{"state":"OPEN"}' > "$work/pr.412.json"
rc=$(run "$disp" poll 1)
ok "an item on an open one is not"                     "$(count '"event": "review_desk_requested"')" 1
ok "  and the pull request was read once"              "$(grep -c 'pr view' "$work/gh.calls")" 1
ok "  asking for the one field gh actually has"        "$(grep -c -- 'pr view 412 -R acme/portal --json state$' "$work/gh.calls")" 1

printf '\n  an empty list, a refusal and a break\n'
instance '{"mode":"auto"}'
echo '{"work":[]}' > "$work/rd.work"
rc=$(run "$disp" poll 1)
ok "an empty list emits nothing and is not an error"   "$(count review_desk)" 0
ok "  it exits clean"                                  "$rc" 0
set +e; D status > "$work/out" 2>&1; set -e
ok "  and \`status\` records the source, calmly"         "$(says 'review_desk 0 items')" yes
ok "  with no empty-streak alarm on THAT source"      "$(sed -n 's/.*review_desk //p' "$work/out" \
    | grep -c 'empty in a row')" 0

instance '{"mode":"auto"}'
echo broken > "$work/rd.mode"
rc=$(run "$disp" poll 3)
ok "exit 2 is one loud message over three ticks"       "$(count '"event": "review_desk_unavailable"')" 1
ok "  naming the state"                                "$(says '"state": "broken"')" yes
ok "  and the mode it happened under"                  "$(says '"mode": "auto"')" yes
ok "  quoting Review Desk's own error"                 "$(says 'scripted broken')" yes
ok "  and the poller survives it"                      "$rc" 0

instance '{"mode":"auto"}'
echo refused > "$work/rd.mode"
rc=$(run "$disp" poll 1)
ok "exit 1 is loud too, as too-old"                    "$(count '"event": "review_desk_unavailable"')" 1
ok "  and is reported as broken, not refused"          "$(says '"state": "broken"')" yes

instance '{"mode":"auto"}'
hide
rc=$(run "$disp" poll 1)
ok "auto with no binary stays silent in the poller"    "$(count review_desk)" 0
show
instance '{"mode":"on"}'
hide
rc=$(run "$disp" poll 3)
ok "on with no binary is one loud message"             "$(count '"event": "review_desk_unavailable"')" 1
ok "  naming the state absent"                         "$(says '"state": "absent"')" yes
ok "  and it still exits clean"                        "$rc" 0
show
instance '{"mode":"off"}'
echo broken > "$work/rd.mode"
work_doc review_requested 1 acme/portal 412
rc=$(run "$disp" poll 1)
ok "off polls nothing and says nothing"                "$(count review_desk)" 0
ok "  and asked the binary nothing"                    "$(grep -c 'work list' "$work/rd.calls")" 0

printf '\n  liveness that cannot be read dispatches nothing\n'
instance '{"mode":"auto"}'
work_doc draft_approved 5 acme/portal 416
printf 'not json' > "$work/allele.json"
rc=$(run "$disp" poll 1)
ok "an unreadable allele state dispatches nothing"     "$(count '"event": "review_desk_resume"')" 0
ok "  and says why, once"                              "$(count '"state": "unknown_liveness"')" 1
ok "  and exits clean"                                 "$rc" 0
no_sessions

# =============================================================================================
printf '\nThe watcher -- the developer'"'"'s two acts, relayed to the session waiting\n'

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active --by test
work_doc draft_approved 7 acme/portal 412
rc=$(run "$disp" watch gh-portal-412 1)
ok "an entry with no review id polls nothing"          "$(grep -c 'work list' "$work/rd.calls")" 0
ok "  and emits nothing"                               "$(count draft_approved)" 0

put gh-portal-412 review_desk_id=7 --by test
rc=$(run "$disp" watch gh-portal-412 1)
ok "an entry with a review id polls its own review"    "$(grep -c -- '--review 7' "$work/rd.calls")" 1
ok "  and emits draft_approved"                        "$(count '"event": "draft_approved"')" 1
ok "  on the first tick, not the second"               "$(says '"tick": 1')" yes
ok "  with the draft link to approve at"               "$(says 'reviews/7/draft')" yes

for kind in brief_settled draft_sent_back draft_approved; do
  instance '{"mode":"auto"}'
  put gh-portal-412 mode=review status=active review_desk_id=7 --by test
  work_doc "$kind" 7 acme/portal 412 1791520339 "" "cut one of them"
  rc=$(run "$disp" watch gh-portal-412 3)
  ok "$kind is emitted once over three ticks"          "$(count "\"event\": \"$kind\"")" 1
  ok "  identified by kind, review and time"           "$(says "$kind|7|1791520339")" yes
done
ok "draft_sent_back relays the developer's note"       "$(says 'cut one of them')" yes

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
work_doc draft_sent_back 7 acme/portal 412 1791520339 "" "first note"
rc=$(run "$disp" watch_reenter gh-portal-412)
ok "re-entry with a new time emits again"              "$(count '"event": "draft_sent_back"')" 2
ok "  and both identities are in the cursor"           "$(python3 -c "
import json
print(len(json.load(open('$inst/runtime/watch/gh-portal-412.json'))['rd_seen']))")" 2

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
work_doc review_requested 7 acme/portal 412
rc=$(run "$disp" watch gh-portal-412 1)
ok "review_requested is not relayed to its own session" "$(count review_requested)" 0

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
echo broken > "$work/rd.mode"
rc=$(run "$disp" watch gh-portal-412 3)
ok "a broken Review Desk is a watch_error"             "$(count '"event": "watch_error"')" 1
ok "  naming the section"                              "$(says '"section": "review_desk"')" yes
ok "  and the watcher keeps ticking"                   "$rc" 0
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
hide
rc=$(run "$disp" watch gh-portal-412 1)
ok "an absent binary on a RECORDED review is loud"     "$(count '"event": "watch_error"')" 1
show
instance '{"mode":"off"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
work_doc draft_approved 7 acme/portal 412
rc=$(run "$disp" watch gh-portal-412 1)
ok "off relays nothing, even with a review id"         "$(count review_desk)" 0
ok "  and emits no draft_approved"                     "$(count draft_approved)" 0

# =============================================================================================
printf '\nThe posting check -- what makes posting once safe\n'
# Recorded GitHub output. `gh api --paginate --slurp` answers with an array of PAGES, so the
# fixture is a list of lists -- which is also what proves the flattening is real.

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=done repo=acme/portal number=412 review_desk_id=7 --by test
printf 'The queue-with-backoff approach fits the ticket.\n\n### Problem fit\n\nIt does.\n' \
  > "$work/body.md"
reviews () { cat > "$work/reviews.json"; }
# Writes stdout to $work/out and the exit code to $work/rc, and prints NOTHING: a helper that
# echoed the code would put a newline between it and the `says` that follows in the same $( ).
posted () { set +e; D review-posted gh-portal-412 --approved-at "$1" --body-file "$work/body.md" \
            --json > "$work/out" 2>"$work/err"; echo $? > "$work/rc"; set -e; }
rc_was () { cat "$work/rc"; }

reviews <<'JSON'
[[{"id": 9001, "state": "COMMENTED", "submitted_at": "2026-10-09T05:00:00Z",
   "user": {"login": "devdeveloper"},
   "body": "The queue-with-backoff approach fits the ticket.\n\n### Problem fit\n\nIt does.\n"}]]
JSON
ok "a matching review is found"                        "$(posted 1791518400)$(rc_was)$(says '"posted": true')" "0yes"
ok "  and its GitHub id is handed back"                "$(says '"review_id": 9001')" yes

ok "a review submitted BEFORE the approval is not it"  "$(posted 1791525000)$(rc_was)$(says '"posted": false')" "0yes"
# 2026-10-09T05:00:00Z is 1791522000. A tie resolves to "after" -- the side that SKIPS the post.
ok "a tie on the approval second counts as after"      "$(posted 1791522000)$(rc_was)$(says '"posted": true')" "0yes"

reviews <<'JSON'
[[{"id": 9002, "state": "COMMENTED", "submitted_at": "2026-10-09T05:00:00Z",
   "user": {"login": "someone-else"},
   "body": "The queue-with-backoff approach fits the ticket.\n\n### Problem fit\n\nIt does.\n"}]]
JSON
ok "a review by somebody else is not it"               "$(posted 1791518400)$(rc_was)$(says '"posted": false')" "0yes"

reviews <<'JSON'
[[{"id": 9003, "state": "COMMENTED", "submitted_at": "2026-10-09T05:00:00Z",
   "user": {"login": "devdeveloper"}, "body": "Looks good to me."}]]
JSON
ok "a different body is not it"                        "$(posted 1791518400)$(rc_was)$(says '"posted": false')" "0yes"

reviews <<'JSON'
[[{"id": 9004, "state": "PENDING", "submitted_at": "2026-10-09T05:00:00Z",
   "user": {"login": "devdeveloper"},
   "body": "The queue-with-backoff approach fits the ticket.\n\n### Problem fit\n\nIt does.\n"}]]
JSON
ok "a PENDING review is not posted"                    "$(posted 1791518400)$(rc_was)$(says '"posted": false')" "0yes"

# CRLF and trailing spaces, which is what GitHub actually hands back. Byte-exactness here is the
# bug: it reports "not posted" about the review it is looking at, and a duplicate goes up.
reviews <<'JSON'
[[{"id": 9005, "state": "COMMENTED", "submitted_at": "2026-10-09T05:00:00Z",
   "user": {"login": "devdeveloper"},
   "body": "The queue-with-backoff approach fits the ticket.  \r\n\r\n### Problem fit\r\n\r\nIt does.\r\n"}]]
JSON
ok "CRLF and trailing spaces still match"              "$(posted 1791518400)$(rc_was)$(says '"posted": true')" "0yes"

# Three pages, the hit on the last. `per_page=100` alone was the first version of this call.
reviews <<'JSON'
[[{"id": 1, "state": "COMMENTED", "submitted_at": "2026-10-01T00:00:00Z",
   "user": {"login": "bot"}, "body": "x"}],
 [{"id": 2, "state": "COMMENTED", "submitted_at": "2026-10-02T00:00:00Z",
   "user": {"login": "someone-else"}, "body": "y"}],
 [{"id": 9006, "state": "APPROVED", "submitted_at": "2026-10-09T05:00:00Z",
   "user": {"login": "devdeveloper"},
   "body": "The queue-with-backoff approach fits the ticket.\n\n### Problem fit\n\nIt does.\n"}]]
JSON
ok "a hit on page three is still found"                "$(posted 1791518400)$(rc_was)$(says '"review_id": 9006')" "0yes"
ok "  and every page was read"                         "$(says '"reviews_read": 3')" yes
# A fresh log: four earlier calls in this block wrote to the shared one, so a count over it
# would assert about the block rather than about this call.
: > "$work/gh.calls"
posted 1791518400
ok "  the call asked GitHub to paginate"               "$(grep -c -- '--paginate --slurp' "$work/gh.calls")" 1
reviews <<'JSON'
[]
JSON
ok "no reviews at all is not posted"                   "$(posted 1791518400)$(rc_was)$(says '"posted": false')" "0yes"
ok "an entry with no repo is refused, loudly"          "$(set +e; D review-posted gh-absent-1 \
    --approved-at 1 --body-file "$work/body.md" >/dev/null 2>&1; echo $?)" 1

# =============================================================================================
printf '\ninit teaches an older config the block, and changes nothing it already has\n'

instance '{"mode":"auto"}'
rc=$(run "$disp" fill_absent '{}')
ok "an absent block learns all four keys"              "$(says '"added": \["review_desk.brief_gate", "review_desk.command", "review_desk.mode", "review_desk.url"\]')" yes
rc=$(run "$disp" fill_absent '{"mode":"off","command":"/opt/rd"}')
ok "a mode the operator set is left alone"             "$(says '"mode": "off"')" yes
ok "  and so is a command they set"                    "$(says '"command": "/opt/rd"')" yes
ok "  while the missing keys are added"                "$(says '"added": \["review_desk.brief_gate", "review_desk.url"\]')" yes
rc=$(run "$disp" cfg '{}')
ok "a config with no block defaults to auto"           "$(says '"mode": "auto"')" yes
ok "  with review-desk as the command"                 "$(says '"command": "review-desk"')" yes
ok "  and brief_gate never"                            "$(says '"brief_gate": "never"')" yes
ok "the template's block matches those defaults"       "$(python3 -c "
import json, sys
sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
print(json.loads((d.CODE_DIR / 'config.example.json').read_text())['review_desk'] == d.REVIEW_DESK_DEFAULTS)")" True

# =============================================================================================
printf '\nbrief tells a review worker what it is resuming\n'

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 title=T url=u --by test
set +e; D brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "a review brief names Review Desk"                  "$(says 'Review Desk: .review-desk.')" yes
ok "  with the mode and the brief gate"                "$(says 'brief gate .never.')" yes
ok "  and points at the With Review Desk section"      "$(says 'With Review Desk')" yes
ok "  and says nothing about resuming"                 "$(count 'You are resuming')" 0
put gh-portal-412 review_desk_id=7 --by test
set +e; D brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "a recorded review is named as a resume"            "$(says 'You are resuming Review Desk review 7')" yes
ok "  with the command that reads the record"          "$(says 'review show --review 7')" yes
instance '{"mode":"off"}'
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 --by test
set +e; D brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "mode off adds no Review Desk line to a brief"      "$(count 'Review Desk')" 0
instance '{"mode":"auto"}'
put EX-1 mode=implement status=claimed title=T url=u --by test
set +e; D brief EX-1 > "$work/out" 2>&1; set -e
ok "a non-review brief is untouched"                   "$(count 'Review Desk')" 0
# `brief` shells out to `locus agent compose`, and `subprocess.run` RAISES for a binary that is
# not there rather than returning non-zero — so this command used to crash with a traceback on
# any machine without it, CI included. These are the first tests to drive `brief` at all.
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 --by test
set +e; PATH="$work/bin:/usr/bin:/bin:/usr/sbin:/sbin" D brief gh-portal-412 > "$work/out" 2>&1
brc=$?; set -e
ok "a brief works with no \`locus\` on PATH"             "$brc" 0
ok "  falling back to the plain role line"             "$(says 'You are R')" yes
ok "  and still naming Review Desk"                    "$(says 'Review Desk: ')" yes

# =============================================================================================
printf '\nNegative controls -- reverse each guard and require these tests to fail\n'
# Without these, every assertion above could be passing for a reason unrelated to the behaviour.
# Each substitution is counted rather than assumed: a sed that matched nothing would turn a
# control into a second copy of the test it is controlling.

sed 's/^        if review_desk_live(live, entry):$/        if False:  # LIVENESS REVERSED/' \
    "$disp" > "$work/nolive.py"
ok "the liveness reversal changed one line"            "$(grep -c 'LIVENESS REVERSED' "$work/nolive.py")" 1
instance '{"mode":"auto"}'
work_doc draft_approved 5 acme/portal 416 1791520400 gh-portal-416
put gh-portal-416 mode=review status=active repo=acme/portal number=416 session_id=live-1 --by test
session live-1
rc=$(run "$work/nolive.py" poll 1)
ok "no liveness: a live session gets a second one"     "$(count '"event": "review_desk_resume"')" 1
no_sessions

sed 's/^        if not self\.due(f"review_desk|{kind}|{rid}|{item\.get(.entered_at.)}", every):$/        if False:  # RATE LIMIT REVERSED/' \
    "$disp" > "$work/norate.py"
ok "the rate-limit reversal changed one line"          "$(grep -c 'RATE LIMIT REVERSED' "$work/norate.py")" 1
instance '{"mode":"auto"}'
work_doc review_requested 1 acme/portal 412
rc=$(run "$work/norate.py" poll 3)
ok "no rate limit: three ticks dispatch three times"   "$(count '"event": "review_desk_requested"')" 3

sed 's/^            if ident in seen:$/            if False:  # CURSOR REVERSED/' \
    "$disp" > "$work/nocursor.py"
ok "the cursor reversal changed one line"              "$(grep -c 'CURSOR REVERSED' "$work/nocursor.py")" 1
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
work_doc draft_approved 7 acme/portal 412
rc=$(run "$work/nocursor.py" watch gh-portal-412 3)
ok "no cursor: three ticks emit three times"           "$(count '"event": "draft_approved"')" 3

# The one whose failure is public: a byte-exact body comparison on GitHub's own CRLF.
sed 's/^    lines = (text or "")\.replace("\\r\\n", "\\n")\.replace("\\r", "\\n")\.split("\\n")$/    return (text or "")  # NORMALISE REVERSED/' \
    "$disp" > "$work/nonorm.py"
ok "the normalise reversal changed one line"           "$(grep -c 'NORMALISE REVERSED' "$work/nonorm.py")" 1
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=done repo=acme/portal number=412 --by test
reviews <<'JSON'
[[{"id": 9005, "state": "COMMENTED", "submitted_at": "2026-10-09T05:00:00Z",
   "user": {"login": "devdeveloper"},
   "body": "The queue-with-backoff approach fits the ticket.  \r\n\r\n### Problem fit\r\n\r\nIt does.\r\n"}]]
JSON
set +e
DISPATCHER_INSTANCE="$inst" python3 "$work/nonorm.py" review-posted gh-portal-412 \
  --approved-at 1791518400 --body-file "$work/body.md" --json > "$work/out" 2>"$work/err"
set -e
ok "no normalising: CRLF reads as not posted"          "$(says '"posted": false')" yes

sed 's/^    reviews = gh_pages(gh("api", "--paginate", "--slurp",$/    reviews = gh_pages(gh("api",  # PAGINATE REVERSED/' \
    "$disp" > "$work/nopage.py"
ok "the paginate reversal changed one line"            "$(grep -c 'PAGINATE REVERSED' "$work/nopage.py")" 1

# The control that did not exist when this field list was wrong, and would have caught it. The
# first version asked `gh pr view --json state,merged`; `merged` is the REST API's field and not
# one `gh pr view` has, so every call raised and `pr_state` was null for every item -- a merged
# pull request was never skipped. Restore the old field list and the skip must break.
sed 's/"--json", "state")$/"--json", "state,merged")/' "$disp" > "$work/oldfield.py"
ok "the field-list reversal changed one line"          "$(grep -c '"--json", "state,merged")' "$work/oldfield.py")" 1
instance '{"mode":"auto"}'
work_doc review_requested 1 acme/portal 412
echo '{"state":"MERGED"}' > "$work/pr.412.json"
rc=$(run "$work/oldfield.py" poll 1)
ok "old field list: a MERGED pull request is NOT skipped" "$(count '"event": "review_desk_requested"')" 1
ok "  and it reports a state it could not establish"   "$(says '"pr_state": null')" yes

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
