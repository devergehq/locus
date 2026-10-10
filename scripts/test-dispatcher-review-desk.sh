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
# Two PATHs, because "no review-desk on PATH" has to mean no review-desk on ANY entry. The
# developer who runs this harness is the one most likely to have the real binary installed —
# `~/.local/bin/review-desk` — and `hide` used to remove only the stand-in, so every absent-command
# assertion fell through to the real one. That failed seven assertions on their machine while
# passing in CI, and worse: the fall-through calls `work list`, which opens the live store under
# `~/.review-desk`. $MINPATH keeps the fakes and drops everything else.
FULLPATH="$PATH"
MINPATH="$work/bin:/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")"

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
# mode ok. `brief` and `finding` are not answered from a recorded document, because what is
# under test for those is the SHAPE of what a review worker is told to write rather than what
# the dispatcher does with an answer. $RDWORK/rd_brief.py stands in for the store's own
# validation instead.
case "$1" in
  brief|finding) exec python3 "$RDWORK/rd_brief.py" "$@" ;;
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

# ---- the stand-in's brief and finding ------------------------------------------------------
# The other commands answer from a recorded document. These two validate instead, because the
# behaviour under test is whether the document `workers/review.md` tells a worker to write is
# one Review Desk accepts. `finding add` validates nothing -- it allocates a sequence number,
# which is all the brief needs of it: a disagreement has to name a finding that exists.
#
# EVERY RULE BELOW WAS READ OFF THE REAL BINARY, by building review-desk's origin/master at
# 8631335 (DEV-882) and running it against a temporary database. The accepted field list is
# that binary's own refusal message, verbatim:
#
#   unknown field `blind_pass_state`, expected one of `problem`, `diagram`, `option_map`,
#   `options`, `approach_verdict`, `provenance`, `confirmation_required`,
#   `confirmation_not_required_because`, `headline`, `how_it_works_today`,
#   `flow_before_caption`, `flow_after_caption`, `flow_before`, `flow_after`, `problems`,
#   `support_table`, `blind_pass`, `parts`, `open_choices`, `disagreements`
#
# It is pinned here rather than read from `brief put --help` at run time for the reason the
# whole harness keeps the real binary off PATH: the one most likely to be installed on the
# machine running this is OLDER than DEV-882 and would pin the list as it was before the
# fields existed. Nothing here writes outside $RDWORK.

cat > "$work/rd_brief.py" <<'RDBRIEF'
import json, os, pathlib, sys

ACCEPTED = {
    "problem", "diagram", "option_map", "options", "approach_verdict", "provenance",
    "confirmation_required", "confirmation_not_required_because", "headline",
    "how_it_works_today", "flow_before_caption", "flow_after_caption", "flow_before",
    "flow_after", "problems", "support_table", "blind_pass", "parts", "open_choices",
    "disagreements",
}
# What `brief problem-statement` serves, and the whole of it. Built by naming what belongs in
# it, never by subtracting, which is the contract's own argument: a read that subtracts grows
# a leak every time the brief grows a field.
SERVED = ("problem", "how_it_works_today", "flow_before_caption", "flow_before", "problems")
VERDICTS = {"fixed", "partly", "stays", "not_assessed"}

work = pathlib.Path(os.environ["RDWORK"])


def refuse(message):
    sys.stderr.write("review-desk: %s\n" % message)
    raise SystemExit(1)


def opt(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


def load(review):
    path = work / ("rd.brief.%s.json" % review)
    return json.loads(path.read_text()) if path.exists() else None


def put(argv, review):
    source = opt(argv, "--file")
    raw = sys.stdin.read() if source == "-" else pathlib.Path(source).read_text()
    doc = json.loads(raw)

    unknown = sorted(set(doc) - ACCEPTED)
    if unknown:
        refuse("cannot use the JSON: unknown field `%s`" % unknown[0])
    if not doc.get("problem"):
        refuse("problem is required")

    required = doc.get("confirmation_required", True)
    if required is False and not doc.get("confirmation_not_required_because"):
        refuse("confirmation_not_required_because is required when confirmation_required is false")
    held = load(review)
    if held is not None and held.get("confirmation_required", True) is True and required is False:
        refuse('confirmation_required holds "false", which is not a valid confirmation_required; '
               "this brief was written as requiring the developer's confirmation, and a "
               "confirmation already asked for cannot be withdrawn by rewriting the brief")

    numbers = set()
    for problem in doc.get("problems", []):
        number = problem.get("number")
        if not isinstance(number, int) or number < 1:
            refuse("problems[].number holds %r; one or more" % number)
        if number in numbers:
            refuse("problems[].number %d appears twice" % number)
        numbers.add(number)
    for field in ("flow_before", "flow_after"):
        for row in doc.get(field, []):
            for box in row:
                mark = box.get("problem")
                if mark is not None and mark not in numbers:
                    refuse("%s names problem %s, which this brief does not carry" % (field, mark))
            if not 1 <= len(row) <= 3:
                refuse("%s has a row of %d boxes; one to three" % (field, len(row)))

    if "option_map" in doc and "options" in doc:
        refuse("option_map and options are the same fact; giving both is refused")

    keys = set()
    for option in doc.get("options", []):
        if option.get("key") in keys:
            refuse("options[].key %s appears twice" % option.get("key"))
        keys.add(option.get("key"))
        if not option.get("argument_for") or not option.get("argument_against"):
            refuse("options[].argument_for and .argument_against are required")
        for verdict in option.get("verdicts", []):
            if verdict.get("problem") not in numbers:
                refuse("options[].verdicts[].problem names problem %s, which this brief does "
                       "not carry" % verdict.get("problem"))
            if verdict.get("verdict") not in VERDICTS:
                refuse("options[].verdicts[].verdict holds %r" % verdict.get("verdict"))
            if verdict.get("verdict") != "not_assessed" and not verdict.get("why"):
                refuse("options[].verdicts[].why is required for every verdict but not_assessed")

    for part in doc.get("parts", []):
        for fixes in part.get("fixes", []):
            if fixes not in numbers:
                refuse("parts[].fixes names problem %s, which this brief does not carry" % fixes)
        for entry in part.get("files", []):
            if entry.get("in_diff") is False and (entry.get("lines_added") or
                                                  entry.get("lines_removed")):
                refuse("parts[].files[] claims a file outside the diff with lines changed")

    blind = doc.get("blind_pass")
    if blind is not None:
        if not blind.get("given") or not blind.get("looked_up"):
            refuse("blind_pass.given and blind_pass.looked_up are required")
        if (blind.get("pick_key") is None) != (blind.get("pick_why") is None):
            refuse("blind_pass.pick_why is non-null exactly when blind_pass.pick_key is")
        if blind.get("pick_key") is not None and blind["pick_key"] not in keys:
            refuse('blind_pass.pick_key holds "%s", which is not a valid blind_pass.pick_key; '
                   "expected one of: the key of one of this brief's own options"
                   % blind["pick_key"])
    else:
        # The other direction, and the one the `not_run` row of review.md's state table is
        # written against: an option attributed to a pass the brief does not record would badge
        # the Alternatives page "Blind" with no blind column to put it in. Without this the
        # `not_run` recipe had no control -- a brief that omitted `blind_pass` and left an
        # option on `blind_pass` read green here and exits 1 against the real store.
        for option in doc.get("options", []):
            if option.get("proposed_by") in ("blind_pass", "both"):
                refuse("options.proposed_by holds option %s: %s; an option from a pass this "
                       "brief does not record is a pass nothing can show"
                       % (option.get("key"), option.get("proposed_by")))

    counter = work / ("rd.findings.%s" % review)
    highest = int(counter.read_text()) if counter.exists() else 0
    pointers = [(row.get("finding_seq"), True) for row in doc.get("disagreements", [])]
    # An open choice MAY name a finding and is checked the same way when it does -- a choice is
    # a choice, not a fault, but a pointer that dangles is a pointer that dangles.
    pointers += [(choice.get("finding_seq"), False) for choice in doc.get("open_choices", [])]
    for seq, must in pointers:
        if seq is None and not must:
            continue
        if seq is None or not 1 <= seq <= highest:
            refuse("brief refers to finding %s/%s, which does not exist" % (review, seq))

    (work / ("rd.brief.%s.json" % review)).write_text(json.dumps(doc))
    # Both derived, by the contract's own rules, so a test can assert the state a document
    # produces rather than a state somebody wrote.
    if blind is None:
        state = "not_run"
    elif any(o.get("proposed_by") in ("blind_pass", "both") for o in doc.get("options", [])):
        state = "ran"
    else:
        state = "ran_and_found_nothing"
    (work / ("rd.state.%s" % review)).write_text(state)
    (work / ("rd.layer2.%s" % review)).write_text("done" if required is False
                                                  else "waiting_on_you")
    print("brief stored for review %s" % review)


def problem_statement(argv, review):
    doc = load(review)
    if doc is None:
        refuse("no brief for review %s" % review)
    served = {
        "review_id": int(review),
        "problem": doc.get("problem"),
        "how_it_works_today": doc.get("how_it_works_today"),
        "flow_before_caption": doc.get("flow_before_caption"),
        "flow_before": doc.get("flow_before", []),
        "problems": [{"number": p.get("number"), "was_wrong": p.get("was_wrong")}
                     for p in doc.get("problems", [])],
    }
    if "--json" in argv:
        print(json.dumps({"problem_statement": served}, sort_keys=True))
        return
    print("review %s — the problem, and nothing of the change" % review)
    print("  problem: %s" % served["problem"])


def finding_add(argv, review):
    counter = work / ("rd.findings.%s" % review)
    seq = (int(counter.read_text()) if counter.exists() else 0) + 1
    counter.write_text(str(seq))
    if opt(argv, "--file") == "-":
        sys.stdin.read()
    print(seq)


argv = sys.argv[1:]
review = opt(argv, "--review")
if argv[:2] == ["brief", "put"]:
    put(argv, review)
elif argv[:2] == ["brief", "problem-statement"]:
    problem_statement(argv, review)
elif argv[:2] == ["finding", "add"]:
    finding_add(argv, review)
else:
    refuse("stand-in: unhandled call: %s" % " ".join(argv))
RDBRIEF

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
  python3 - "$inst/config.json" "$work/allele.json" "${1:-}" "${2:-}" <<'PY'
import json, sys, pathlib
dest, state, block, review = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
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
if review:
    cfg["review"] = json.loads(review)
dest.write_text(json.dumps(cfg, indent=2))
PY
  : > "$work/rd.calls"; : > "$work/gh.calls"
  echo ok > "$work/rd.mode"
  echo '{"work":[]}' > "$work/rd.work"
  rm -f "$work/rd.work."* "$work/pr."*.json "$work/reviews.json"
  rm -f "$work/rd.brief."*.json "$work/rd.findings."* "$work/rd.state."* "$work/rd.layer2."*
}

D () { python3 "$disp" --instance "$inst" "$@"; }
# hide/show: an absent command, which is a different fact from a broken one. Both halves matter —
# the stand-in goes away AND the PATH narrows to the fakes, or a real install answers instead.
hide () { mv "$work/bin/review-desk" "$work/review-desk.hidden"; PATH="$MINPATH"; export PATH; }
show () { mv "$work/review-desk.hidden" "$work/bin/review-desk"; PATH="$FULLPATH"; export PATH; }
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
    # behaviour under test is one function over two dicts. The section defaults to `review_desk`,
    # so the calls written before `review` existed read exactly as they did.
    section = rest[1] if len(rest) > 1 else "review_desk"
    template = json.loads((m.CODE_DIR / "config.example.json").read_text())[section]
    existing = json.loads(rest[0])
    added = m.fill_absent(section, existing, template)
    print(json.dumps({"added": sorted(added), "result": existing}))

elif scenario == "cfg":
    print(json.dumps(m.review_desk_cfg(json.loads(rest[0]))))

elif scenario == "review_cfg":
    print(json.dumps(m.review_cfg(json.loads(rest[0]))))

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
hide
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
show

# =============================================================================================
printf '\nWhether Review Desk is used -- the mode matrix, through doctor\n'

doctor () { set +e; D doctor > "$work/out" 2>&1; set -e; grep 'review desk' "$work/out" || true; }

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
printf '\nthe blind options pass -- a setting of its own, outside review_desk (DEV-886)\n'
# The pass runs with Review Desk missing, off or broken, so its switch may not live under
# `review_desk`. Three things are asserted: the default is on, in code and not only in the
# template; the brief NAMES it either way, because a worker reads no config; and `doctor` crosses
# a value that `review_cfg` would otherwise default past.

rc=$(run "$disp" review_cfg '{}')
ok "a config with no review block defaults on"         "$(says '"blind_options_pass": true')" yes
rc=$(run "$disp" review_cfg '{"review":{"blind_options_pass":false}}')
ok "  and false is read as false"                      "$(says '"blind_options_pass": false')" yes
rc=$(run "$disp" review_cfg '{"review":{"blind_options_pass":null}}')
ok "  while null is absent, not off"                   "$(says '"blind_options_pass": true')" yes
ok "the setting is not under review_desk"              "$(python3 -c "
import json, sys
sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
t = json.loads((d.CODE_DIR / 'config.example.json').read_text())
print('blind_options_pass' not in t['review_desk'] and t['review'] == d.REVIEW_DEFAULTS)")" True
ok "the template's review block has no threshold"      "$(python3 -c "
import json, sys
sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
t = json.loads((d.CODE_DIR / 'config.example.json').read_text())['review']
print(sorted(t) == ['blind_options_pass'])")" True
rc=$(run "$disp" fill_absent '{}' review)
ok "an older config learns the one key"                "$(says '"added": \["review.blind_options_pass"\]')" yes
rc=$(run "$disp" fill_absent '{"blind_options_pass":false}' review)
ok "  and a value the operator set is left alone"      "$(says '"blind_options_pass": false')" yes

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 title=T url=u --by test
set +e; D brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "a review brief says the pass is on"                "$(says 'Blind options pass: \*\*on\*\*')" yes
ok "  and points at step 3"                            "$(says 'review.md. step 3')" yes
instance '{"mode":"auto"}' '{"blind_options_pass":false}'
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 title=T url=u --by test
set +e; D brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "off is named in the brief, not omitted"            "$(says 'Blind options pass: \*\*off\*\*')" yes
ok "  and the worker is told to say so once"           "$(says 'say so once')" yes
instance '{"mode":"off"}' '{"blind_options_pass":true}'
put EX-1 mode=implement status=claimed title=T url=u --by test
set +e; D brief EX-1 > "$work/out" 2>&1; set -e
ok "a non-review brief says nothing about it"          "$(count 'Blind options pass')" 0

# `doctor` reaches Linear for nothing in these two checks, but it does run every other check in
# the command, so only its exit code and the line are asserted.
instance '{"mode":"off"}' '{"blind_options_pass":"off"}'
set +e; D doctor > "$work/out" 2>&1; set -e
ok "doctor crosses a string where a bool belongs"      "$(says '✗ review mode: review.blind_options_pass')" yes
instance '{"mode":"off"}'
set +e; D doctor > "$work/out" 2>&1; set -e
ok "  and reports the default as a default"            "$(says '✓ review mode: blind options pass on (default)')" yes

# =============================================================================================
printf '\nThe brief, in two writes -- the understanding into the record (DEV-883)\n'
# `brief put` is the ONLY command that saves any of the understanding, and it REPLACES, so
# workers/review.md has the worker write it twice: the problem half before step 3 dispatches
# the blind pass, the whole brief after step 5. Nothing in dispatcher.py issues either call --
# the worker does, from that brief -- so what is under test here is the brief's own
# prescription, crossed against the field list the real binary accepts and then driven through
# the stand-in.
#
# The store the stand-in writes lives under $work, like everything else here. REVIEW_DESK_DB is
# never set and never read, so no test can reach ~/.review-desk even with it installed.
#
# NO BRACE IN AN INLINE `python3 -c` INSIDE `$( )`. Bash brace-expands a word before it parses
# the quoting inside a command substitution, so a Python set or dict literal there splits the
# word in two, runs the substitution twice with one alternative each, and hands `ok` four
# arguments. It cost an hour to find; the helpers below exist so no assertion has to.

cat > "$work/brieftable.py" <<'TABLE'
"""Read workers/review.md's two tables and report what they name.

The slot-to-field table says which field each `understand.md` slot goes in and which of the two
brief writes it lands in. The pour table says which field each section of the blind pass's
brief is poured from. Both are prose a worker obeys, so both are crossed here against what the
real binary accepts and what its problem-only read actually serves.
"""
import json, pathlib, re, sys

ACCEPTED = {
    "problem", "diagram", "option_map", "options", "approach_verdict", "provenance",
    "confirmation_required", "confirmation_not_required_because", "headline",
    "how_it_works_today", "flow_before_caption", "flow_after_caption", "flow_before",
    "flow_after", "problems", "support_table", "blind_pass", "parts", "open_choices",
    "disagreements",
}
SERVED = {"problem", "how_it_works_today", "flow_before_caption", "flow_before", "problems"}
# One per row of review-desk's contract/README.md, "The brief, by page", plus the three fields
# a brief written the old way already had. A field this list names and the table does not is a
# page DEV-885 draws from nothing.
REQUIRED = [
    "headline", "how_it_works_today", "flow_before", "flow_before_caption", "flow_after",
    "flow_after_caption", "problems[].number", ".was_wrong", ".now_fixed", ".detail_title",
    ".detail_before", ".detail_after", "support_table", "options[].key", "options[].verdicts",
    ".proposed_by", ".argument_for", ".argument_against", ".chosen", "blind_pass.given",
    ".pick_key", ".pick_why", ".questions", ".looked_up", "parts[]", ".in_diff",
    "open_choices[]", "disagreements[]", ".finding_seq", "approach_verdict", "provenance",
]


def rows(lines, header):
    start = next(i for i, l in enumerate(lines) if l.startswith(header))
    out = []
    for line in lines[start + 2:]:
        if not line.startswith("|"):
            break
        out.append([c.strip() for c in line.strip().strip("|").split("|")])
    return out


def tokens(cell):
    return re.findall(r"`([^`]+)`", cell)


def roots(cell):
    """The top-level fields a Field cell names.

    A token starting with `.` is a sub-path of the token before it, which is how one row can
    name a field and four of its members without repeating the root five times.
    """
    found, current = [], None
    for token in tokens(cell):
        if token.startswith("-"):
            # A flag, not a field path. The Counts slot's destination is `layer set --detail`
            # rather than a brief field, and a field path never begins with a dash.
            continue
        if token.startswith("."):
            if current:
                found.append(current)
        else:
            current = re.split(r"[\[.]", token)[0]
            found.append(current)
    return found


def slot_name(cell):
    """The slot a Slot cell names: the leading bolded phrase, and nothing after it.

    `**Was wrong / now** - the now line` is the "Was wrong / now" slot. A row that qualifies
    which half of a two-line slot it means is still that slot.
    """
    match = re.match(r"\*\*([^*]+)\*\*", cell)
    return match.group(1).strip() if match else cell


def understand_slots(path):
    """Every slot `understand.md` defines, from its three slot tables and nowhere else.

    By table header, not by "a row starting bold": the worked example has bolded first cells
    too, and `**The blind pass would pick**` is prose about the Blind pick slot rather than a
    slot of its own. Reading those as slots would let review.md name one and still pass.
    """
    lines = pathlib.Path(path).read_text().split("\n")
    found = set()
    for index, line in enumerate(lines):
        if line.startswith("| Slot | What goes in it"):
            for row in lines[index + 2:]:
                if not row.startswith("|"):
                    break
                found.add(slot_name([c.strip() for c in row.strip().strip("|").split("|")][0]))
    return found


lines = pathlib.Path(sys.argv[1]).read_text().split("\n")

slots = rows(lines, "| `understand.md` slot | Field | Write |")
all_tokens, all_roots = [], set()
write = {"1": set(), "2": set()}
for slot, field, which in slots:
    all_tokens += tokens(field)
    these = roots(field)
    all_roots |= set(these)
    write[which.strip("* ")] |= set(these)

joined = " ".join(all_tokens)
poured = rows(lines, "| Template section | Poured from |")
pour_roots = sorted({r for _, source in poured for r in roots(source)})

named = {slot_name(slot) for slot, _, _ in slots}
defined = understand_slots(sys.argv[2]) if len(sys.argv) > 2 else set()

print(json.dumps({
    "slots_named": sorted(named),
    "slots_defined": sorted(defined),
    # A slot review.md names that `understand.md` does not define is a slot a worker has to
    # improvise. One `understand.md` defines that review.md does not name is a slot with
    # nowhere to go, which is the defect DEV-883 exists to close -- so both directions.
    "slots_improvised": sorted(named - defined) if defined else ["(no understand.md given)"],
    "slots_unsaved": sorted(defined - named) if defined else ["(no understand.md given)"],
    "roots": sorted(all_roots),
    "unknown_roots": sorted(all_roots - ACCEPTED),
    "missing_contract": [r for r in REQUIRED if r not in joined],
    "write1": sorted(write["1"]),
    "write2": sorted(write["2"]),
    "in_both": sorted(write["1"] & write["2"]),
    "served_expected": sorted(SERVED),
    "pour_roots": pour_roots,
    "pour_unserved": [r for r in pour_roots if r not in SERVED],
    "pour_sections": [section for section, _ in poured],
}, sort_keys=True))
TABLE

# The top-level keys of a JSON document, optionally dropping a prefix. A helper rather than an
# inline python because its one-liner would need a set literal. See the brace note above.
cat > "$work/keys.py" <<'KEYS'
import json, sys
doc = json.load(open(sys.argv[1]))
drop = sys.argv[2] if len(sys.argv) > 2 else None
print(sorted(k for k in doc if not (drop and k.startswith(drop))))
KEYS

# The pour, done exactly as the brief's table says: The system from how_it_works_today, How it
# works today from flow_before, What is wrong from problems[].was_wrong.
cat > "$work/pour.py" <<'POUR'
import json, sys
d = json.load(open(sys.argv[1]))["problem_statement"]
out = ["## The system", d["how_it_works_today"] or "", "", "## How it works today"]
# One number per ROW, boxes in a split row sharing it -- which is what review.md says and what
# the real CLI's own plain rendering does. Numbering per box made a split row renumber every
# step after it, and the first version of this file did exactly that.
for index, row in enumerate(d["flow_before"], 1):
    for box in row:
        out.append("%d. %s - %s" % (index, box["title"], box.get("note") or ""))
out += ["", "## What is wrong"]
for problem in d["problems"]:
    out.append("%d. **%s**" % (problem["number"], problem["was_wrong"]))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
POUR

brief_md="$root/skills/dispatcher/workers/review.md"
understand_md="$root/skills/review-craft/understand.md"
# `ask <expr> [file]` answers one question about that reading, so an assertion reads as the
# question it asks.
ask () { python3 "$work/brieftable.py" "${2:-$brief_md}" "${3:-$understand_md}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)"; }
keys () { python3 "$work/keys.py" "$@"; }
rc () { set +e; review-desk "$@" > "$work/out" 2>"$work/err"; echo $?; set -e; }
quiet () { set +e; review-desk "$@" > "$work/ps" 2>"$work/err"; set -e; }

instance '{"mode":"auto"}'

printf '\n  the fields the brief names are ones Review Desk accepts, and cover the pages\n'
ok "no field named is one the store would refuse"   "$(ask "d['unknown_roots']")" "[]"
ok "  and every field the three pages draw is named" "$(ask "d['missing_contract']")" "[]"
ok "  the superseded diagram is not among them"     "$(ask "d['roots'].count('diagram')")" 0
ok "  and the brief says to stop writing it"        "$(grep -c 'Stop writing .diagram.' "$brief_md")" 1
ok "  the derived state is never written"           "$(grep -c 'never write .blind_pass_state.' "$brief_md")" 1

printf '\n  no slot improvises -- the two files name the same slots\n'
# review.md's Slot column and understand.md's three slot tables, crossed both ways. One
# direction catches a field a worker would have to invent a slot for; the other catches a slot
# with nowhere to go, which is the defect this issue exists to close.
ok "review.md names no slot understand.md lacks"    "$(ask "d['slots_improvised']")" "[]"
ok "  and leaves no slot of it unsaved"             "$(ask "d['slots_unsaved']")" "[]"
ok "  over every slot, not a handful"               "$(ask "len(d['slots_defined']) >= 20")" True
ok "the colliding slot name is gone"                "$(grep -c '^| \*\*How it works today\*\* |' "$understand_md")" 0
ok "  replaced by the plain-words slot"             "$(grep -c '^| \*\*The system\*\* |' "$understand_md")" 1
ok "  and by the table, named as its own slot"      "$(grep -c '^| \*\*Supporting table\*\* |' "$understand_md")" 1
ok "  with the table called change-half"            "$(grep -c 'Supporting table is change-half' "$understand_md")" 1
ok "the record's verdict words are in understand.md" "$(grep -c '`fixed`, `partly`, `stays`, or `not_assessed`' "$understand_md")" 1
ok "  and in the blind brief's own JSON"            "$(grep -c '"verdict": "fixed | partly | stays"' "$understand_md")" 1
ok "  and the template no longer carries the old ones" "$(grep -c '"verdict": "yes | partly | no"' "$understand_md")" 0
ok "  which survive only as the revision's quotation" "$(grep -c 'used to say .yes | partly | no.' "$understand_md")" 1
ok "  and the brief says nothing maps anything"     "$(grep -c 'Nothing maps anything' "$brief_md")" 1

printf '\n  the wording DEV-884 brings, adopted early so the rebase cannot lose it\n'
# #72 edits the same file. Its three wording changes and its linter paragraph were taken verbatim
# onto this branch, so `git merge-file` leaves only conflicts whose losing side is text this
# branch supersedes -- measured at 4, each an old slot row or the stale paragraph. Without these
# assertions a resolver taking "ours" wholesale would revert them and nothing would say so:
# #72's own harness never reads this file.
ok "the headline cap is at most, not under"         "$(grep -c 'One sentence, at most 20 words' "$understand_md")" 1
ok "  and a was-wrong line carries the same cap"    "$(grep -c 'Two lines each, at most 20 words a line' "$understand_md")" 1
ok "  an option title too"                          "$(grep -c 'a title of at most 12 words' "$understand_md")" 1
ok "  in the blind brief's JSON as well"            "$(grep -c 'at most 12 words, plain English' "$understand_md")" 1
ok "the 150-word top-layer budget is stated here"   "$(grep -c 'The whole top layer' "$understand_md")" 1
ok "  and so is the linter that enforces it"        "$(grep -c 'Check it before you show it' "$understand_md")" 1

printf '\n  write 1 is the problem half, and nothing else\n'
ok "write 1 names exactly what the read serves"     "$(ask "d['write1']")" "$(ask "d['served_expected']")"
ok "  and only the numbered problems are in both"   "$(ask "d['in_both']")" "['problems']"
ok "  write 1 is ordered before step 3 dispatches"  "$(grep -c 'before step 3 dispatches' "$brief_md")" 1
ok "  and after the ledger link, so it is seen live" "$(grep -c 'Write 1 comes after .Open it, link it' "$brief_md")" 1
ok "  and step 2 says so where a worker reads it"   "$(grep -c 'save the problem half before you go on to step 3' "$brief_md")" 1
ok "  the brief says why write 1 is the permissive one" "$(grep -c 'Why write 1 is the permissive one' "$brief_md")" 1

printf '\n  the blind brief is poured from the problem-only read, not retyped\n'
ok "the read is named as its source"                "$(grep -c 'brief problem-statement --review <id> --json' "$brief_md")" 1
ok "  and read after write 1, not before"           "$(grep -c 'After write 1, read it' "$brief_md")" 1
ok "every section is poured from a served field"    "$(ask "d['pour_unserved']")" "[]"
ok "  and all three sections are accounted for"     "$(ask "len(d['pour_sections'])")" 3
ok "without Review Desk the template is by hand"    "$(grep -c 'Without Review Desk, fill the' "$brief_md")" 1

printf '\n  write 1, driven through the stand-in\n'
cat > "$work/half.json" <<'JSON'
{
  "problem": "A retried delivery is sent again from the start.",
  "how_it_works_today": "The portal posts a webhook when an order changes.",
  "flow_before_caption": "Today",
  "flow_before": [[{"title": "An order changes", "note": "the app enqueues a job"}],
                  [{"title": "The job posts", "note": "nothing identifies the delivery"},
                   {"title": "It times out", "problem": 1}],
                  [{"title": "The queue retries it", "note": "from the start, as a new post"}],
                  [{"title": "The receiver stores both", "note": "two orders, one event",
                    "problem": 2}]],
  "problems": [{"number": 1, "was_wrong": "A retry arrives as a second delivery."},
               {"number": 2, "was_wrong": "Nothing records that it was a retry."}],
  "confirmation_required": false,
  "confirmation_not_required_because": "problem half only — the full brief follows at step 5"
}
JSON
ok "the problem half is accepted"                   "$(rc brief put --review 1 --file "$work/half.json")" 0
ok "  and its fields are the table's write 1"       "$(keys "$work/half.json" confirmation_)" "$(ask "d['write1']")"
ok "  its store is under the temp dir"              "$(test -f "$work/rd.brief.1.json" && echo yes || echo no)" yes
ok "  its reason is marked as scaffolding"          "$(python3 -c "
import json
print(json.load(open('$work/half.json'))['confirmation_not_required_because'][:17])")" "problem half only"
ok "  which the brief requires as the opening phrase" "$(grep -c 'Begin it .problem half only' "$brief_md")" 1
ok "  layer 2 settles at write 1, as the brief says" "$(cat "$work/rd.layer2.1")" done
ok "  and the brief warns it moves twice"           "$(grep -c 'moves twice without you' "$brief_md")" 1
ok "a problem half is recognisable from the record" "$(python3 -c "
import json
d = json.load(open('$work/rd.brief.1.json'))
print(not d.get('options') and all(p.get('now_fixed') is None for p in d['problems']))")" True
ok "  which the brief says to use, not memory"      "$(grep -c 'recognisable from the record, not from your memory' "$brief_md")" 1

printf '\n  write 2, the whole of it\n'
echo '{"lens":"sibling diff","severity":"should","claim":"the description and the code disagree"}' \
  | review-desk finding add --review 1 --file - > "$work/seq"
ok "a finding is numbered before the brief names it" "$(cat "$work/seq")" 1
python3 - "$work/half.json" "$work/full.json" <<'PY'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
doc.update({
    "headline": "A retry now carries the first delivery's key, so one event is delivered once.",
    "support_table": {"title": "Who decides", "columns": ["Question", "Today", "After"],
                      "rows": [["Who retries a delivery", "the queue", "the queue"],
                               ["What a repeat costs", "a second order", "nothing"],
                               ["Who names a delivery", "nobody", "the event"]]},
    "flow_after_caption": "After",
    "flow_after": [[{"title": "An order changes"}],
                   [{"title": "The job posts with a key", "problem": 1},
                    {"title": "The receiver drops a repeat", "problem": 2}],
                   [{"title": "The queue retries with the same key", "problem": 1}],
                   [{"title": "The receiver stores one", "problem": 2}]],
    "options": [
        {"key": "A", "title": "Retry inside the request", "argument_for": "no queue at all",
         "argument_against": "it blocks the response", "chosen": False, "proposed_by": "ticket",
         "verdicts": [{"problem": 1, "verdict": "partly", "why": "still a second delivery"},
                      {"problem": 2, "verdict": "stays", "why": "nothing is recorded"}]},
        {"key": "B", "title": "An idempotency key per event", "argument_for": "delivered once",
         "argument_against": "one more column", "chosen": True, "proposed_by": "both",
         "verdicts": [{"problem": 1, "verdict": "fixed", "why": "the receiver dedupes"},
                      {"problem": 2, "verdict": "fixed", "why": "the key is the record"}]},
        {"key": "C", "title": "Let the receiver ask us for what it missed",
         "argument_for": "nothing to retry", "argument_against": "not our system to change",
         "chosen": False, "proposed_by": "blind_pass",
         "verdicts": [{"problem": 1, "verdict": "not_assessed"},
                      {"problem": 2, "verdict": "not_assessed"}]},
    ],
    "blind_pass": {"given": "## The system\nposted when an order changes\n",
                   "pick_key": "B", "pick_why": "The cheapest option that fixes both.",
                   "looked_up": "nothing",
                   "questions": ["Does the receiver already drop a repeat?"]},
    "approach_verdict": "The right shape for the problem.",
    "provenance": "from the ticket, the description and the code at a1b2c3d",
    "parts": [{"title": "The key, stored per event", "summary": "one key, reused on a retry",
               "fixes": [1, 2],
               "files": [{"path": "jobs/DeliverWebhook.php", "lines_added": 96,
                          "lines_removed": 22, "in_diff": True},
                         {"path": "docs/webhooks.md", "lines_added": 0, "lines_removed": 0,
                          "in_diff": False}]}],
    "open_choices": [{"left_open": "Where the key is stored", "chosen": "a column on the event",
                      "why": "the publish stays one statement", "departs_from_ticket": False}],
    "disagreements": [{"description_says": "a retry is dropped after a day",
                       "code_does": "it is retried for ever", "finding_seq": 1}],
})
for problem in doc["problems"]:
    problem["now_fixed"] = "It is the same delivery, named by the same key."
    problem["detail_title"] = "The key"
    problem["detail_before"] = ["DeliverWebhook posted with no identifier."]
    problem["detail_after"] = ["It reuses the event's key on every attempt."]
doc.pop("confirmation_required")
doc.pop("confirmation_not_required_because")
pathlib.Path(sys.argv[2]).write_text(json.dumps(doc, indent=1))
PY
ok "the whole brief is accepted"                    "$(rc brief put --review 1 --file "$work/full.json")" 0
ok "  and its fields are the table's, all of them"  "$(keys "$work/full.json")" "$(ask "d['roots']")"
ok "  none of which is one the store would refuse"  "$(ask "d['unknown_roots']")" "[]"
ok "  false then true leaves layer 2 the developer's" "$(cat "$work/rd.layer2.1")" waiting_on_you
ok "  and the brief waits for the one after write 2" "$(grep -c 'wait for the .brief_settled. that follows write 2' "$brief_md")" 1

printf '\n  what the read withholds, with the whole brief on the record\n'
# The pour is read back AFTER write 2, which is the only way the absences below mean anything:
# every string asserted absent is one the record now holds.
quiet brief problem-statement --review 1 --json
ok "the read answers with one document"             "$(keys "$work/ps")" "['problem_statement']"
ok "  holding six fields, which are the problem half" "$(python3 -c "
import json
print(sorted(json.load(open('$work/ps'))['problem_statement']))")" "['flow_before', 'flow_before_caption', 'how_it_works_today', 'problem', 'problems', 'review_id']"
ok "  with no now-fixed line on any problem"        "$(python3 -c "
import json
d = json.load(open('$work/ps'))['problem_statement']
print(len([p for p in d['problems'] if 'now_fixed' in p]))")" 0
python3 "$work/pour.py" "$work/ps" "$work/poured.md"
ok "the poured brief carries the before flow"       "$(grep -c 'the app enqueues a job' "$work/poured.md")" 1
ok "  numbering by row, so a split row shares one"  "$(grep -c '^2\. [^*]' "$work/poured.md")" 2
ok "  one number per row and no more"               "$(grep -c '^4\. [^*]' "$work/poured.md")" 1
ok "  and never numbers past the last row"          "$(grep -c '^5\. ' "$work/poured.md")" 0
ok "  and carries every numbered problem"           "$(grep -c '^[12]\. \*\*' "$work/poured.md")" 2
ok "  but not the headline"                         "$(grep -c 'delivered once' "$work/poured.md")" 0
ok "  nor a box of the after flow"                  "$(grep -c 'posts with a key' "$work/poured.md")" 0
ok "  nor a now-fixed line"                         "$(grep -c 'named by the same key' "$work/poured.md")" 0
ok "  nor an option the author considered"           "$(grep -c 'idempotency key per event' "$work/poured.md")" 0
ok "  nor a part of the solution"                   "$(grep -c 'DeliverWebhook' "$work/poured.md")" 0

printf '\n  the blind pass as three states, not two\n'
ok "an option only the blind pass raised reads as ran" "$(cat "$work/rd.state.1")" ran
ok "  and the brief says to mark it blind_pass"     "$(grep -c 'An option the pass raised and the ticket did not is .blind_pass.' "$brief_md")" 1
ok "  and not to flatten one they both raised"      "$(grep -c 'do not flatten it to' "$brief_md")" 1
python3 - "$work/full.json" "$work/nothingnew.json" "$work/notrun.json" <<'PY'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
for option in doc["options"]:
    option["proposed_by"] = "ticket"
pathlib.Path(sys.argv[2]).write_text(json.dumps(doc))
doc.pop("blind_pass")
pathlib.Path(sys.argv[3]).write_text(json.dumps(doc))
PY
ok "a pass that put none forward is accepted"       "$(rc brief put --review 1 --file "$work/nothingnew.json")" 0
ok "  and reads as ran-and-found-nothing"           "$(cat "$work/rd.state.1")" ran_and_found_nothing
ok "a pass that did not run is accepted"            "$(rc brief put --review 1 --file "$work/notrun.json")" 0
ok "  and reads as not-run"                         "$(cat "$work/rd.state.1")" not_run
ok "  and the brief gives a recipe for each state"  "$(grep -c 'ran_and_found_nothing' "$brief_md")" 1
# Why that recipe says "every option `ticket`" and not just "no `blind_pass`". Without this the
# row had no control: dropping the pass and leaving an option attributed to it reads as a clean
# `not_run` to anything that only checks for the pass, and exits 1 against the store.
python3 - "$work/notrun.json" "$work/orphan.json" <<'PY'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
doc["options"][2]["proposed_by"] = "blind_pass"
pathlib.Path(sys.argv[2]).write_text(json.dumps(doc))
PY
ok "an option left on a pass that is not recorded is refused" "$(rc brief put --review 1 --file "$work/orphan.json")" 1
ok "  naming the option and what it claims"         "$(grep -c 'options.proposed_by holds option C' "$work/err")" 1
ok "  which is why the recipe says every option ticket" "$(grep -c 'every option .ticket., and the reason in .provenance.' "$brief_md")" 1

printf '\n  the refusals the brief is written around\n'
instance '{"mode":"auto"}'
python3 - "$work/full.json" "$work/needsgate.json" "$work/droppedflow.json" "$work/old.json" \
         "$work/dropped.json" <<'PY'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
gated = dict(doc, confirmation_required=False,
             confirmation_not_required_because="brief_gate is never for this instance")
pathlib.Path(sys.argv[2]).write_text(json.dumps(gated))
# TWO documents, because a dropped problem is refused by everything that referred to it and
# only the first refusal is reported. This one keeps the flow marks, so a FLOW refuses it.
flow = json.loads(json.dumps(doc))
flow["problems"] = [p for p in flow["problems"] if p["number"] != 2]
pathlib.Path(sys.argv[3]).write_text(json.dumps(flow))
# And this one unmarks both flows, so what is left to refuse it is the orphaned VERDICT.
# Rows emptied by the filter go with them: an empty row is refused for its own reason.
dropped = json.loads(json.dumps(flow))
for field in ("flow_before", "flow_after"):
    kept = [[b for b in row if b.get("problem") != 2] for row in dropped[field]]
    dropped[field] = [row for row in kept if row]
pathlib.Path(sys.argv[5]).write_text(json.dumps(dropped))
old = json.loads(pathlib.Path(sys.argv[1]).read_text())
old["blind_pass_state"] = "ran"
pathlib.Path(sys.argv[4]).write_text(json.dumps(old))
PY
echo '{"lens":"l","severity":"should","claim":"c"}' \
  | review-desk finding add --review 2 --file - > /dev/null
ok "a brief asking for confirmation is accepted"    "$(rc brief put --review 2 --file "$work/full.json")" 0
ok "  and cannot then be rewritten as needing none" "$(rc brief put --review 2 --file "$work/needsgate.json")" 1
ok "  which is why write 1 writes false, not true"  "$(grep -c '.brief_gate: never. would be unreachable' "$brief_md")" 1

# The trap under `brief_gate: always`: write 2 is "write 1's fields written again", and write
# 1's fields include the REASON. Dropping only the flag leaves a brief that requires
# confirmation and carries a reason for needing none, which is refused -- after step 5, with
# the whole brief in hand. Both fields have to go.
python3 - "$work/full.json" "$work/reasononly.json" <<'PY'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
doc["confirmation_not_required_because"] = "problem half only — the full brief follows at step 5"
pathlib.Path(sys.argv[2]).write_text(json.dumps(doc))
PY
ok "write 1's reason carried into write 2 is refused" "$(rc brief put --review 5 --file "$work/reasononly.json")" 1
ok "  and the brief says to drop both gate fields"  "$(grep -c 'neither gate field' "$brief_md")" 1

# A new head commit is a different review id, so a later round holds no brief and the read it
# would pour from answers with nothing. The brief used to say a later round finds the problem
# half already there; it does not.
ok "the read on a review with no brief exits 1"     "$(rc brief problem-statement --review 9)" 1
ok "  and the brief says a new head is a new id"    "$(grep -c 'new head commit is a different' "$brief_md")" 1
ok "a disagreement before its finding is refused"   "$(rc brief put --review 3 --file "$work/full.json")" 1
ok "  naming the finding that does not exist"       "$(grep -c 'finding 3/1, which does not exist' "$work/err")" 1
ok "  and the brief says to add the finding first"  "$(grep -c 'so .finding add. it first' "$brief_md")" 1
echo '{"lens":"l","severity":"should","claim":"c"}' \
  | review-desk finding add --review 3 --file - > /dev/null
ok "  and is accepted once the finding exists"      "$(rc brief put --review 3 --file "$work/full.json")" 0
# A SECOND write, which is what the claim is about: review 1 holds the whole brief first, so
# the refusal is the one a worker meets at step 5 rather than one a first write would give too.
echo '{"lens":"l","severity":"should","claim":"c"}' \
  | review-desk finding add --review 1 --file - > /dev/null
ok "the whole brief lands on review 1 first"        "$(rc brief put --review 1 --file "$work/full.json")" 0
ok "dropping a problem refuses the second write"    "$(rc brief put --review 1 --file "$work/droppedflow.json")" 1
ok "  on the flow box that marked it"               "$(grep -c 'flow_before names problem 2' "$work/err")" 1
ok "and unmarking the flows does not rescue it"     "$(rc brief put --review 1 --file "$work/dropped.json")" 1
ok "  the verdict that scored against it refuses too" "$(grep -c 'verdicts\[\].problem names problem 2' "$work/err")" 1
ok "  and the brief forbids dropping or renumbering" "$(grep -c 'Never drop a problem, and never renumber one' "$brief_md")" 1
ok "an unknown field is exit 1, not exit 2"         "$(rc brief put --review 4 --file "$work/old.json")" 1
ok "  and the brief reads that as a Review Desk too old" "$(grep -c 'older than the structured brief' "$brief_md")" 1

printf '\n  the brief is linted before it is sent, and never before that\n'
# brief_lint.py arrives with DEV-884 (#72). These assert what workers/review.md TELLS a worker
# to run and when; the assertion that the document above actually passes the linter waits for
# that merge, and is the one thing in this block still owed.
ok "the linter is named for write 2"                "$(grep -c 'Write 2 is linted before it is sent' "$brief_md")" 1
ok "  with the command a worker can run"            "$(grep -c 'brief_lint.py' "$brief_md")" 4
ok "  and step 6 checks before it shows"            "$(grep -c 'Check it, then show your principal' "$brief_md")" 1
ok "write 1 is explicitly NOT linted"               "$(grep -c 'Do not lint write 1' "$brief_md")" 1
# The number was MEASURED by running DEV-884's linter over the harness's own half.json: 4 of 16,
# and the four the sentence names. It is a string pin until #72 merges, at which point it becomes
# a run -- the first version of this assertion pinned 6, which was a count off a malformed
# fixture and which the sentence's own list contradicted.
ok "  with the count it would fail by"              "$(grep -c '4 of its 16 checks fail' "$brief_md")" 1
ok "the linter needs no Review Desk"                "$(grep -c 'It needs no Review Desk' "$brief_md")" 1
ok "  so it runs with Review Desk absent too"       "$(grep -c 'with Review Desk absent, write the' "$brief_md")" 1
ok "an absent linter is a broken install, said loudly" "$(grep -c 'brief_lint.py. that is not there is a broken install' "$brief_md")" 1
ok "  and not confused with Review Desk's exit 2"   "$(grep -c 'these are two different absences' "$brief_md")" 1

printf '\n  absent and broken are still what they were\n'
instance '{"mode":"auto"}'
echo broken > "$work/rd.mode"
ok "a broken Review Desk breaks brief put too, with 2" "$(rc brief put --review 1 --file "$work/half.json")" 2
ok "  which the brief answers once and carries on"  "$(grep -c 'once to the Dispatcher and then finish the review' "$brief_md")" 1
instance '{"mode":"auto"}'
hide
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 title=T url=u --by test
set +e; D brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "an absent Review Desk puts no command in a brief" "$(count 'brief put')" 0
ok "  nor the problem-only read"                      "$(count 'problem-statement')" 0
show

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

# The three controls for DEV-883's block. Each rewrites the BRIEF, not the code: what is under
# test there is a table of field names, so a control has to break the table.

# Two reversals, because the crossing has two halves and only one of them catches each. A
# renamed ROOT is a field the store refuses; a renamed MEMBER of a root it accepts is not, and
# is caught instead by the coverage check against the contract's page table. The first version
# of this control broke a member and asserted against the root check, which reported ok --
# which is the whole reason a control is written before the test is believed.
sed 's/`support_table\.title`/`support_tables.title`/' "$brief_md" > "$work/badroot.md"
ok "the root reversal changed one line"                "$(grep -c 'support_tables.title' "$work/badroot.md")" 1
ok "a field the store would refuse is NOT reported ok" "$(ask "d['unknown_roots'] == []" "$work/badroot.md")" False

sed 's/^| \*\*What the pass was given\*\* | `blind_pass\.given` |/| **What the pass was given** | `blind_pass.handed` |/' \
    "$brief_md" > "$work/badfield.md"
ok "the member reversal changed one line"              "$(grep -c 'blind_pass.handed' "$work/badfield.md")" 1
ok "  and it is the root check that does NOT catch it" "$(ask "d['unknown_roots']" "$work/badfield.md")" "[]"
ok "a renamed member is caught by the page coverage"   "$(ask "d['missing_contract']" "$work/badfield.md")" "['blind_pass.given']"

sed 's/^| \*\*The system\*\* | `how_it_works_today` | \*\*1\*\* |/| **The sytsem** | `how_it_works_today` | **1** |/' \
    "$brief_md" > "$work/badslot.md"
ok "the slot-name reversal changed one line"           "$(grep -c 'The sytsem' "$work/badslot.md")" 1
ok "a slot understand.md does not define is caught"    "$(ask "d['slots_improvised']" "$work/badslot.md")" "['The sytsem']"
ok "  and the slot it left behind is caught too"       "$(ask "d['slots_unsaved']" "$work/badslot.md")" "['The system']"

sed 's/| `## The system` | `how_it_works_today` |/| `## The system` | `headline` |/' \
    "$brief_md" > "$work/badpour.md"
ok "the pour reversal changed one line"                "$(grep -c '| `## The system` | `headline` |' "$work/badpour.md")" 1
ok "pouring from a field the read withholds is caught" "$(ask "d['pour_unserved']" "$work/badpour.md")" "['headline']"

sed 's/^| \*\*Before\*\* | `flow_before\[\]\[\]`, with `flow_before_caption` | \*\*1\*\* |/| **Before** | `flow_before[][]`, with `flow_before_caption` | 2 |/' \
    "$brief_md" > "$work/badwrite.md"
ok "the write-column reversal changed one line"        "$(grep -c '^| \*\*Before\*\* | .flow_before\[\]\[\]., with .flow_before_caption. | 2 |' "$work/badwrite.md")" 1
ok "a problem-half field moved to write 2 is caught"   "$(ask "d['write1'] == d['served_expected']" "$work/badwrite.md")" False

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
