#!/bin/sh
# Unit tests for the Poller half of skills/dispatcher/dispatcher.py.
#
# These exist because DEV-794 was invisible for 19 days. `Poller.__init__` read `first_tick`
# out of the PERSISTED state file, so `backlog` was true once per instance lifetime rather than
# once per session, and SKILL.md step 4's whole start-up contract was unreachable. Nothing
# caught it, because nothing tested it.
#
# The fixture is therefore a POISONED state file -- one that already carries `started`, the way
# every real instance does. A fresh state file passes the interesting case trivially and proves
# nothing, which is the trap this harness is built to avoid. The last test reverses the fix in a
# copy of the source and requires the suite to FAIL against it, so a green run here cannot be
# green for the wrong reason.
#
# Unlike test-review-lint.sh, this drives the module through a Python driver rather than a fake
# `gh` on PATH. Two reasons: `linear()` goes out over urllib, so no PATH fake can reach it and a
# test that let it through would hit api.linear.app; and `record_error`'s durability is a
# statement about WHEN bytes reach disk, which needs an in-process crash, not a subprocess.
#
# DEV-996 adds a stand-in `review-desk` in $work/bin and the `runrd` helper that puts it on
# PATH, because that half of the ticket is a CALL rather than an outcome: what is under test is
# the argv the poller sends and that nothing it can answer -- absent, exit 2, an unknown
# subcommand -- reaches the tick's exit code. Every other scenario keeps the narrowed PATH below.
#
# What is pinned: that `first_tick` survives a persisted `started`, that the 30 Sep conditions
# surface all ten review requests as backlog, that the flag drops on a later tick of the same
# process, that `started` is not deleted, that a thrown section reaches stderr and a runtime
# file rather than only stdout, that the file is bounded, and that `status` reports it.
set -eu

# No `review-desk` on PATH, deliberately. Poller.review_desk asks it per repository served,
# and a real install — `~/.local/bin/review-desk` on the developer's own machine, most likely —
# would answer from the live store under `~/.review-desk`. This harness is about the logic, and
# absent is the state it was written against. Narrowed here rather than stubbed because nothing
# in it asserts anything about Review Desk.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")"
export PATH

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
disp="$root/skills/dispatcher/dispatcher.py"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A temporary database, for the one case the narrowed PATH above does not cover: since DEV-945
# the poller WRITES a review request into Review Desk as it sees one, and the search pages below
# are full of them. A `review-desk` reaching PATH by a route that line did not anticipate must
# not find the live store under `~/.review-desk`. Inside $work, so the trap above removes it.
export REVIEW_DESK_DB="$work/review-desk.db"

pass=0
fail=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-58s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-58s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

# ---- the instance: a config.json and a poisoned runtime, built fresh per scenario ----------

# instance <started-or-empty>: writes $work/inst. `started` present = the poisoned state that
# every instance created before the fix carries on disk.
instance () {
  rm -rf "$work/inst"; mkdir -p "$work/inst/runtime"
  cat > "$work/inst/config.json" <<'EOF'
{
  "linear": { "api_key_env": "TEST_NO_SUCH_TOKEN", "team_key": "ZZ", "label_group_id": "g",
    "labels": { "todo": { "id": "L-todo", "name": "Agent - Todo" } },
    "modes": { "implement": { "trigger": "todo", "working": "todo" } } },
  "github": { "login": "tester", "review_query": "is:pr is:open", "skip_drafts": true },
  "allele": { "state_file": "/dev/null", "default_project": "p", "repo_project_map": {} },
  "limits": { "max_workers": 15, "poll_interval_secs": 300, "watch_interval_secs": 300,
    "reemit_after_secs": 900, "blocked_alert_after_secs": 120, "max_lost_retries": 1 }
}
EOF
  if [ -n "$1" ]; then
    printf '{"started": "%s", "prs_present": null}\n' "$1" > "$work/inst/runtime/poll-state.json"
  fi
}

# entry <key> <status> [session-id]: a ledger entry, so an assertion about a `skipped` or `active`
# PR is testing behaviour rather than the absence of a file. Without these, "no skipped PR is
# resurrected" passes on an instance that has no skipped PR to resurrect.
entry () {
  mkdir -p "$work/inst/runtime/ledger"
  printf '{"key":"%s","mode":"review","status":"%s","session_id":"%s"}\n' "$1" "$2" "${3:-}" \
    > "$work/inst/runtime/ledger/$1.json"
}

# run <source> <scenario> [args]: the driver, against the source file named. stdout in
# $work/out, stderr in $work/err, exit code echoed.
run () {
  src=$1; scenario=$2; shift 2
  set +e
  DISP="$src" INST="$work/inst" python3 "$work/driver.py" "$scenario" "$@" \
      >"$work/out" 2>"$work/err"
  c=$?
  set -e
  echo "$c"
}
says   () { grep -q -- "$1" "$work/out" && echo yes || echo no; }
onerr  () { grep -q -- "$1" "$work/err" && echo yes || echo no; }
# flagged <true|false>: how many review_request events carry that backlog value
flagged () { grep -c "\"event\": \"review_request\".*\"backlog\": $1" "$work/out" || true; }

# ---- DEV-996: a stand-in review-desk, and the runs that can reach it -----------------------
#
# Off the default PATH, like the real thing: every scenario above this line asserts nothing about
# Review Desk and must go on seeing it absent. `runrd` is the only way in, and $RDWORK/rd.mode is
# how each of Review Desk's answers is driven -- `unknown` being the one every build in the world
# gives until DEV-996's other half ships, since `review requested` does not exist yet.
mkdir -p "$work/bin"
export RDWORK="$work"
cat > "$work/bin/review-desk" <<'STANDIN'
#!/bin/sh
printf '%s\n' "$*" >> "$RDWORK/rd.calls"
case "$(cat "$RDWORK/rd.mode" 2>/dev/null || echo ok)" in
  unknown)
    # clap's own refusal. review-desk's main.rs remaps clap's usage exit to 1 and gives the
    # document `code: usage`, which is what `review_desk_unknown` reads.
    printf '{"error":{"code":"usage","message":"error: unrecognized subcommand %s"}}\n' \
      "'requested'"
    exit 1 ;;
  broken)
    echo '{"error":{"code":"cannot_open_database","message":"scripted broken","kind":"broken"}}'
    exit 2 ;;
  refused)
    echo '{"error":{"code":"not_found","message":"no such repository"}}'
    exit 1 ;;
esac
echo '{"request":{"repo":"o/r","pr":1,"withdrawn":false}}'
exit 0
STANDIN
chmod +x "$work/bin/review-desk"

# runrd <source> <scenario> [args]: `run`, with the stand-in reachable. The calls log is reset
# here rather than per assertion, so "how many calls did this tick make" is a question about one
# run of the driver.
runrd () {
  : > "$work/rd.calls"
  src=$1; scenario=$2; shift 2
  set +e
  PATH="$work/bin:$PATH" RDWORK="$work" DISP="$src" INST="$work/inst" \
      python3 "$work/driver.py" "$scenario" "$@" >"$work/out" 2>"$work/err"
  c=$?
  set -e
  echo "$c"
}
# calls <pattern>: how many review-desk invocations matched. Assertions about argv, not outcomes.
calls () { grep -c -- "$1" "$work/rd.calls" 2>/dev/null || true; }

# desk <mode> [reemit_after_secs]: give the instance just built a `review_desk` block. Separate
# from `instance` so that every scenario above this section keeps the config it was written
# against, and so `mode: off` -- which must make no call at all -- is one word to express.
desk () {
  python3 - "$work/inst/config.json" "$1" "${2:-}" <<'DESK'
import json, sys
path, mode, every = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(path))
cfg["review_desk"] = {"mode": mode, "command": "review-desk", "url": "http://127.0.0.1:7777"}
if every:
    cfg["limits"]["reemit_after_secs"] = int(every)
json.dump(cfg, open(path, "w"))
DESK
}

# done_entry <key> <updated_at>: a ledger entry marked `done`, with the stamp DEV-996's second
# test of "new" compares against. `entry` above writes no `updated_at`, and that half of Patrick's
# definition is a comparison against it -- so an entry without one tests the fallback, not the rule.
done_entry () {
  mkdir -p "$work/inst/runtime/ledger"
  printf '{"key":"%s","mode":"review","status":"done","session_id":"s1","updated_at":"%s"}\n' \
    "$1" "$2" > "$work/inst/runtime/ledger/$1.json"
}

cat > "$work/driver.py" <<'EOF'
"""Exercise one Poller scenario against the dispatcher source named in $DISP."""
import importlib.util, json, os, pathlib, sys, time

spec = importlib.util.spec_from_file_location("disp_under_test", os.environ["DISP"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
os.environ["DISPATCHER_INSTANCE"] = os.environ["INST"]

# Ten open review requests: the 30 Sep conditions, by number.
PRS = [{"number": n, "title": f"PR {n}", "url": f"https://github.com/o/r/pull/{n}",
        "isDraft": False, "headRefOid": f"sha{n}", "createdAt": "2026-09-24T00:00:00Z",
        "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
       for n in (9481, 9464, 9435, 9432, 9431, 9430, 9429, 9428, 9426, 9394)]

def offline(review_nodes=PRS, gh_raises=None, live=None, live_raises=False):
    """No network: `linear` and `gh` are module globals, so replacing them is enough.

    `live` is the live `gh pr view --json state` answer per PR number, which is what DEV-959's
    guard CONFIRMS a closed-looking search row against. Defaulting it to OPEN rather than
    answering every call with the search document is not tidiness: the old fake returned the
    search dict for `pr view` too, so `pr_state` read `None` off it and every row looked open
    whatever the test meant. `live_raises` is GitHub not answering, which `pr_state` turns into
    `None` and which must NOT be read as closed.
    """
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({}, set())
    def fake_gh(*args):
        if args[:2] == ("pr", "view"):
            if live_raises:
                raise RuntimeError("gh pr view: boom")
            # `reviewRequests` is DEV-996's: `why_cleared` reads it to decide a withdrawal from
            # EVIDENCE rather than from the row's absence. Empty means the principal is no
            # longer being asked, which is what every clearance in this file meant before it.
            return {"state": (live or {}).get(int(args[2]), "OPEN"), "latestReviews": [],
                    "isDraft": False, "reviewRequests": []}
        if gh_raises:
            raise gh_raises
        return {"data": {"search": {"nodes": review_nodes}}}
    m.gh = fake_gh

scenario = sys.argv[1]

if scenario == "first_tick":
    offline()
    print(json.dumps({"first_tick": m.Poller().first_tick}))

elif scenario == "one_tick":
    offline()
    m.Poller().tick()
    print(json.dumps({"started_on_disk": m.read_json(m.poll_state(), {}).get("started")}))

elif scenario == "two_ticks":
    offline()
    p = m.Poller()
    print(json.dumps({"tick": 1})); p.tick()
    print(json.dumps({"tick": 2})); p.tick()

elif scenario == "section_throws":
    offline(gh_raises=RuntimeError("gh api graphql: boom"))
    m.Poller().tick()
    log = m.error_log()
    recs = [json.loads(l) for l in log.read_text().splitlines() if l.strip()]
    print(json.dumps({"records": len(recs), "section": recs[0]["section"],
                      "has_traceback": "Traceback" in recs[0]["traceback"]}))

elif scenario == "durable_before_state_write":
    # The point of the file: a section throws, then the process dies BEFORE tick() reaches its
    # state write. state["errors"] never reaches disk; the record must be there anyway.
    offline()
    p = m.Poller()
    p.error("review_requests", RuntimeError("died mid-tick"))   # no tick(), so no state write
    on_disk = m.read_json(m.poll_state(), {})
    print(json.dumps({"log_exists": m.error_log().exists(),
                      "errors_persisted": bool(on_disk.get("errors")),
                      "in_memory_errors": len(p.state["errors"])}))

elif scenario == "bounded":
    offline()
    p = m.Poller()
    # `record_error` truncates the message at 400 characters, so the marker goes FIRST or the
    # newest-kept assertion below tests nothing. 1200 records of ~470 bytes clears the 256K cap.
    written = 1200
    for i in range(written):
        p.record_error("review_requests", RuntimeError(f"#{i} " + "x" * 900))
    lines = [l for l in m.error_log().read_text().splitlines() if l.strip()]
    print(json.dumps({
        # Unbounded would be ~400 * 1.3KB. The cap plus one cycle's growth is the real ceiling.
        "under_cap": m.error_log().stat().st_size <= m.ERROR_LOG_MAX_BYTES * 2,
        "trimmed": len(lines) < written,
        # Every surviving line must still parse: the trim drops its partial first line.
        "all_parse": all(json.loads(l) for l in lines),
        # The newest record is the one kept, which is the whole point of trimming the head.
        "newest_kept": f"#{written - 1}" in json.loads(lines[-1])["error"]}))

elif scenario == "status":
    offline()
    p = m.Poller()
    p.record_error("review_requests", RuntimeError("gh api graphql: boom"))
    class A: all = False
    m.cmd_status(A())

elif scenario == "empty_guard":
    # DEV-799. Three ticks in ONE process: 3 PRs, an empty result, then recovery. gh-r-1 is
    # skipped by the principal, gh-r-2 is active, gh-r-3 is a genuine start-up item.
    matched = [3]
    holder = {"nodes": PRS[:3]}
    def gh_guard(*args):
        if args[:2] == ("api", "graphql"):
            return {"data": {"search": {"issueCount": matched[0], "nodes": holder["nodes"]}}}
        if args[0] == "pr" and args[1] == "view":
            return {"state": "OPEN", "latestReviews": [], "isDraft": False,
                    "reviewRequests": []}
        raise AssertionError("unexpected gh call %r" % (args,))
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({"s2": {"last_known_status": "Idle"}}, set())
    m.gh = gh_guard
    p = m.Poller()
    p.tick()
    # One array per line, keyed by name. Printed together, a grep for a key matched whichever
    # array happened to carry it -- three assertions passed without testing behaviour (#63 review).
    print(json.dumps({"phase": "after_full", "backlog": sorted(p.state["review_backlog"])}))
    print(json.dumps({"phase": "after_full_present", "present": sorted(p.state["prs_present"])}))
    # the empty tick: issueCount still says 3, so this is a fault and must not be believed
    holder["nodes"] = []
    p.tick()
    print(json.dumps({"phase": "after_empty", "backlog": sorted(p.state["review_backlog"])}))
    print(json.dumps({"phase": "after_empty_present", "present": sorted(p.state["prs_present"]),
                      "streak": p.state["sources"]["github"]["zero_streak"]}))
    holder["nodes"] = PRS[:3]
    p.tick()
    print(json.dumps({"phase": "after_recovery", "backlog": sorted(p.state["review_backlog"])}))

elif scenario == "genuine_empty":
    # issueCount == 0 is GitHub saying it matched nothing. Believed at once.
    holder = {"nodes": PRS[:2], "count": 2}
    def gh_g(*args):
        if args[:2] == ("api", "graphql"):
            return {"data": {"search": {"issueCount": holder["count"], "nodes": holder["nodes"]}}}
        return {"state": "OPEN", "latestReviews": []}
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({}, set())
    m.gh = gh_g
    p = m.Poller(); p.tick()
    holder.update(nodes=[], count=0)
    p.tick()
    print(json.dumps({"present": sorted(p.state["prs_present"]),
                      "believed": p.state["prs_present"] == {}}))
    p.tick()
    print(json.dumps({"believed_on_second": p.state["prs_present"] == {}}))

elif scenario == "two_zeroes":
    # No issueCount (the Linear shape): the SECOND consecutive zero is believed.
    holder = {"nodes": [{"identifier": "ZZ-1", "title": "t", "url": "u", "team": {"key": "ZZ"},
                         "project": {"name": "p"}, "labels": {"nodes": [{"id": "L-todo"}]}}]}
    m.linear = lambda cfg, q, v=None: {"issues": holder}
    m.allele_state = lambda cfg: ({}, set())
    m.gh = lambda *a: {"data": {"search": {"issueCount": 0, "nodes": []}}}
    p = m.Poller(); p.tick()
    marks = lambda: sorted(k for k in p.state["emitted"] if "trigger" in k)
    print(json.dumps({"phase": "full", "markers": marks()}))
    holder["nodes"] = []
    p.tick(); print(json.dumps({"phase": "zero_1", "markers": marks()}))
    p.tick(); print(json.dumps({"phase": "zero_2", "markers": marks()}))
    # A count, so "the second zero sweeps them" cannot be satisfied by the line being absent.
    print(json.dumps({"phase": "done", "zero_2_marker_count": len(marks())}))

elif scenario == "truncated":
    # DEV-799 / #63 S1. 52 open, page one of 50, then the same 52 rotated by two: search order is
    # not stable, so two keys leave `present` with no change in the world.
    ALL = [{"number": n, "title": "t", "url": "u", "isDraft": False, "headRefOid": "s",
            "createdAt": "2026-09-24T00:00:00Z", "author": {"login": "x"},
            "repository": {"nameWithOwner": "o/r"}} for n in range(9400, 9452)]
    # Tick 1 must NOT be truncated, or there is no committed `prs_present` for tick 2 to protect:
    # on a truncated tick nothing is committed, so the key keeps whatever it already held -- which
    # on a first-ever tick is None. 50 open and issueCount 50 first, then 52 with the page rotated.
    page = {"nodes": ALL[:50], "count": 50}
    def gh_t(*args):
        if args[:2] == ("api", "graphql"):
            return {"data": {"search": {"issueCount": page["count"], "nodes": page["nodes"]}}}
        return {"state": "OPEN", "latestReviews": []}
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({"s2": {"last_known_status": "Idle"}}, set())
    m.gh = gh_t
    p = m.Poller(); p.tick()
    print(json.dumps({"phase": "settled", "present": len(p.state["prs_present"]),
                      "9400_present": "gh-r-9400" in p.state["prs_present"]}))
    # Rotate the page so two keys LEAVE it (9400, 9401) and two ARRIVE (9450, 9451). The arriving
    # pair is the one that can trip the ungated emits, and an earlier version of this scenario gave
    # ledger entries only to the leaving pair -- so it stayed green over a live Blocker (#63 S8).
    page.update(nodes=ALL[2:52], count=52)
    sizes = []
    for tick in (2, 3, 4):
        p.tick()
        sizes.append(len(p.state["review_backlog"]))
        print(json.dumps({"phase": "trunc%d" % tick, "present": len(p.state["prs_present"]),
                          "backlog_len": sizes[-1],
                          "backlog_unique": len(set(p.state["review_backlog"]))}))
    # The property, not a count: it used to grow by a page per tick and carry duplicates. The exact
    # size depends on how many fixture keys the ledger prunes out, so asserting a number would rot.
    print(json.dumps({"phase": "growth", "stable": len(set(sizes)) == 1,
                      "no_duplicates": sizes[-1] == len(set(p.state["review_backlog"]))}))
    print(json.dumps({"phase": "rotated", "present": len(p.state["prs_present"]),
                      "9400_still_present": "gh-r-9400" in p.state["prs_present"]}))

elif scenario == "backlog_flag":
    offline()
    class A:
        once = True
        backlog = False if sys.argv[2] == "off" else True
    m.cmd_poll(A())

elif scenario == "trunc_runs":
    # The backlog leak measured in review was across fresh PROCESSES, not ticks: each new process
    # has a first tick, so each appends a whole page to `review_backlog`, and without the union
    # commit the prune that would dedupe it never runs. Four runs against one state file.
    ALL = [{"number": n, "title": "t", "url": "u", "isDraft": False, "headRefOid": "s",
            "createdAt": "2026-09-24T00:00:00Z", "author": {"login": "x"},
            "repository": {"nameWithOwner": "o/r"}} for n in range(9400, 9452)]
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({}, set())
    m.gh = lambda *a: ({"data": {"search": {"issueCount": 52, "nodes": ALL[:50]}}}
                       if a[:2] == ("api", "graphql") else {"state": "OPEN", "latestReviews": []})
    sizes = []
    for run in range(4):
        p = m.Poller(); p.tick()
        sizes.append(len(p.state["review_backlog"]))
    print(json.dumps({"phase": "runs", "sizes": sizes, "stable": len(set(sizes)) == 1}))

elif scenario == "cli":
    # #63 S7. The flag scenarios set the attribute on a stub and never reach argparse, so flipping
    # `--backlog`'s default reverted DEV-794 with the suite still green. This drives `main()` with a
    # real argv, which is the interface an operator actually types.
    offline()
    import sys as _s
    argv = ["dispatcher.py", "--instance", os.environ["INST"], "poll", "--once"] + sys.argv[2:]
    saved, _s.argv = _s.argv, argv
    try:
        m.main()
    except SystemExit:
        pass
    finally:
        _s.argv = saved

elif scenario == "no_backlog_first_call":
    # #63 S9. A session whose FIRST call carries --no-backlog: the requests must still be visible as
    # auto-dispatching, `poller_started` must still fire so something downstream knows a process ran
    # with the policy off, and `started` must still be written.
    offline()
    class A:
        once = True
        backlog = False
    m.cmd_poll(A())
    st = m.read_json(m.poll_state(), {})
    print(json.dumps({"started_written": bool(st.get("started")),
                      "backlog_on_disk": st.get("review_backlog")}))

elif scenario == "no_backlog_keeps_state":
    # `--no-backlog` must suppress the ANNOUNCEMENT without disturbing the persisted set of
    # undecided keys, or a host using it on its second call onwards would lose the backlog it
    # asked about on its first.
    offline()
    class A:
        once = True
        backlog = None          # default: announce
    m.cmd_poll(A())
    first = sorted(m.read_json(m.poll_state(), {})["review_backlog"])
    A.backlog = False           # --no-backlog
    m.cmd_poll(A())
    after = m.read_json(m.poll_state(), {})
    print(json.dumps({"first": first, "after": sorted(after["review_backlog"]),
                      "preserved": first == sorted(after["review_backlog"]),
                      "started": after.get("started")}))

elif scenario == "hostile_state":
    # #63 S4: a `sources` bucket and an error record written by some other version of this file.
    offline()
    # Two shapes at once: a bucket whose keys this version does not know (so `last_at` is absent),
    # and one whose stamp is present but unparseable. The first must read "never", the second
    # "unreadable" -- they are different facts and `ago` used to raise on the first.
    m.write_json(m.poll_state(), {"sources": {"github": {"count": 3, "seen_at": "x"},
                                              "linear": {"last_count": 1, "last_at": "garbage"}}})
    m.error_log().parent.mkdir(parents=True, exist_ok=True)
    m.error_log().write_text(json.dumps({"at": None, "section": "s", "error": "e"}) + "\n")
    class A: all = False
    m.cmd_status(A())
    print(json.dumps({"status_survived": True}))

elif scenario == "pr_state_rows":
    # DEV-959. One page carrying every state a row can come back with, including a row with NO
    # `state` key at all -- which is what every fixture above this line is, and which must keep
    # reading as open or this scenario silently rewrites the rest of the file.
    def row(n, state):
        r = {"number": n, "title": f"PR {n}", "url": f"https://github.com/o/r/pull/{n}",
             "isDraft": False, "headRefOid": f"sha{n}", "createdAt": "2026-10-01T00:00:00Z",
             "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
        if state is not None:
            r["state"] = state
        return r
    # 9607 is the one that matters most: the search says MERGED and the LIVE read says OPEN.
    # The search's `state` only narrows, so this row must be dispatched like any other.
    offline(review_nodes=[row(9601, "OPEN"), row(9602, "MERGED"), row(9603, "CLOSED"),
                          row(9604, None), row(9605, "merged"), row(9607, "MERGED")],
            live={9602: "MERGED", 9603: "CLOSED", 9605: "MERGED", 9607: "OPEN"})
    # Both write paths are replaced rather than let through to the stand-in: what is under test
    # is which call is made for which row, and either one reaching a `review-desk` on PATH would
    # be a write. `record_request` is the OPEN path; `open_request` behind a clean `find_request`
    # is the closed path's narrowed one (DEV-959 as Patrick amended it: a closed pull request
    # Review Desk has never held a review of is still recorded, once).
    asked, opened = [], []
    # `(action, previous)` since DEV-962: a mock that hands back one value makes the
    # caller's unpacking a TypeError and takes the whole GitHub section with it.
    m.Poller.record_request = \
        lambda self, rd, key, *a, **k: (asked.append(key), (None, None))[1]
    m.Poller.find_request = lambda self, rd, repo, number, every: None
    # The DOCUMENT, not the review: `action` is a sibling of `review` in the answer
    # since DEV-962, and `record_if_never_reviewed` reads the review out of it.
    m.Poller.open_request = lambda self, rd, key, *a, **k: (
        opened.append(key) or {"review": {"id": 77}, "created": True,
                               "action": "created", "head_moved_from": None})
    p = m.Poller()
    p.tick()
    # One array per line, keyed by name. Printed together, a grep for a key matches whichever
    # array happens to carry it -- the trap `empty_guard` has a comment about, and the trap the
    # first version of this scenario walked into: all three "records no request" assertions read
    # their key off the `present` list and failed for that reason alone.
    print(json.dumps({"phase": "recorded", "keys": sorted(asked)}))
    print(json.dumps({"phase": "opened", "keys": sorted(opened)}))
    print(json.dumps({"phase": "present", "keys": sorted(p.state["prs_present"])}))

elif scenario == "closed_held":
    # The same page, but Review Desk already HOLDS a review of every pull request on it. The
    # never-reviewed carve-out must not fire: a round on a shipped pull request is the harm the
    # whole ticket is about.
    def row(n, state):
        r = {"number": n, "title": f"PR {n}", "url": f"u{n}", "isDraft": False,
             "headRefOid": f"sha{n}", "createdAt": "2026-10-01T00:00:00Z", "state": state,
             "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
        return r
    offline(review_nodes=[row(9631, "MERGED"), row(9632, "CLOSED")],
            live={9631: "MERGED", 9632: "CLOSED"})
    opened = []
    m.Poller.record_request = lambda self, rd, key, *a, **k: (None, None)
    # A dict is `review find` saying "here is the newest round", which is a review that exists.
    m.Poller.find_request = lambda self, rd, repo, number, every: {"id": 5, "head_sha": "x"}
    # The DOCUMENT, not the review: `action` is a sibling of `review` in the answer
    # since DEV-962, and `record_if_never_reviewed` reads the review out of it.
    m.Poller.open_request = lambda self, rd, key, *a, **k: (
        opened.append(key) or {"review": {"id": 77}, "created": True,
                               "action": "created", "head_moved_from": None})
    p = m.Poller()
    p.tick()
    print(json.dumps({"phase": "opened", "keys": sorted(opened)}))

elif scenario == "closed_unlookable":
    # `find_request` returns None for an install it could not USE as well as for a store that
    # held nothing, and writing on the first would be the blind write the look exists to stop.
    # The flags it sets are the discriminator; this scenario sets each of them in turn.
    def row(n):
        return {"number": n, "title": f"PR {n}", "url": f"u{n}", "isDraft": False,
                "headRefOid": f"sha{n}", "createdAt": "2026-10-01T00:00:00Z", "state": "MERGED",
                "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
    flag = sys.argv[2]
    offline(review_nodes=[row(9641)], live={9641: "MERGED"})
    opened = []
    def looked(self, rd, repo, number, every):
        if flag == "refused":
            return "refused"
        setattr(self, flag, True)      # record_stopped or look_stopped
        return None
    m.Poller.record_request = lambda self, rd, key, *a, **k: (None, None)
    m.Poller.find_request = looked
    # The DOCUMENT, not the review: `action` is a sibling of `review` in the answer
    # since DEV-962, and `record_if_never_reviewed` reads the review out of it.
    m.Poller.open_request = lambda self, rd, key, *a, **k: (
        opened.append(key) or {"review": {"id": 77}, "created": True,
                               "action": "created", "head_moved_from": None})
    p = m.Poller()
    p.tick()
    print(json.dumps({"phase": "opened", "keys": sorted(opened)}))

elif scenario == "closed_unreadable":
    # GitHub not answering `pr pr view`. `pr_state` returns None, which this file's own
    # disposition refuses to read as closed -- so the row is dispatched and a human sorts it out.
    def row(n, state):
        return {"number": n, "title": f"PR {n}", "url": f"u{n}", "isDraft": False,
                "headRefOid": f"sha{n}", "createdAt": "2026-10-01T00:00:00Z", "state": state,
                "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
    offline(review_nodes=[row(9611, "MERGED")], live_raises=True)
    asked, opened = [], []
    # `(action, previous)` since DEV-962: a mock that hands back one value makes the
    # caller's unpacking a TypeError and takes the whole GitHub section with it.
    m.Poller.record_request = \
        lambda self, rd, key, *a, **k: (asked.append(key), (None, None))[1]
    m.Poller.find_request = lambda self, rd, repo, number, every: None
    # The DOCUMENT, not the review: `action` is a sibling of `review` in the answer
    # since DEV-962, and `record_if_never_reviewed` reads the review out of it.
    m.Poller.open_request = lambda self, rd, key, *a, **k: (
        opened.append(key) or {"review": {"id": 77}, "created": True,
                               "action": "created", "head_moved_from": None})
    p = m.Poller()
    p.tick()
    print(json.dumps({"phase": "recorded", "keys": sorted(asked)}))
    print(json.dumps({"phase": "present", "keys": sorted(p.state["prs_present"])}))

elif scenario == "merged_rerequest":
    # The other emission a merged row must not produce. `review_rerequested` needs `returned` to
    # be true, which needs a COMMITTED `prs_present` without the key -- so two ticks, and the
    # ledger entry has to be ALIVE for that branch to be the one reached at all.
    def row(n, state):
        r = {"number": n, "title": f"PR {n}", "url": f"https://github.com/o/r/pull/{n}",
             "isDraft": False, "headRefOid": f"sha{n}", "createdAt": "2026-10-01T00:00:00Z",
             "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
        if state is not None:
            r["state"] = state
        return r
    page = {"nodes": [row(9601, "OPEN")]}
    live = {9602: "MERGED"}
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({"s9": {"last_known_status": "Idle"}}, set())
    def gh_rr(*args):
        if args[:2] == ("pr", "view"):
            return {"state": live.get(int(args[2]), "OPEN"), "latestReviews": [],
                    "isDraft": False, "reviewRequests": []}
        return {"data": {"search": {"issueCount": len(page["nodes"]), "nodes": page["nodes"]}}}
    m.gh = gh_rr
    m.Poller.record_request = lambda self, rd, key, *a, **k: (None, None)
    p = m.Poller()
    p.tick()
    print(json.dumps({"phase": "one", "keys": sorted(p.state["prs_present"])}))
    # 9602 arrives merged against a session that is mid-round, and 9606 arrives open against one
    # too -- the control, so "nothing was emitted" cannot pass because the branch was unreachable.
    page["nodes"] = [row(9601, "OPEN"), row(9602, "MERGED"), row(9606, "OPEN")]
    p.tick()
    print(json.dumps({"phase": "two", "keys": sorted(p.state["prs_present"])}))

elif scenario == "merged_clears":
    # A key a live session holds, carried over from a previous tick, LEAVES prs_present on the
    # tick the merge is seen -- so the clearance sweep names it with `why_cleared`'s own live
    # read, which is the event that gets the Dispatcher to offer the discard.
    def row(n, state):
        r = {"number": n, "title": f"PR {n}", "url": f"u{n}", "isDraft": False,
             "headRefOid": f"sha{n}", "createdAt": "2026-10-01T00:00:00Z",
             "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
        if state is not None:
            r["state"] = state
        return r
    page = {"nodes": [row(9621, None), row(9622, None)]}
    live = {}
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({"s1": {"last_known_status": "Idle"}}, set())
    def gh_mc(*args):
        if args[:2] == ("pr", "view"):
            return {"state": live.get(int(args[2]), "OPEN"), "latestReviews": [],
                    "isDraft": False, "reviewRequests": []}
        return {"data": {"search": {"issueCount": len(page["nodes"]), "nodes": page["nodes"]}}}
    m.gh = gh_mc
    m.Poller.record_request = lambda self, rd, key, *a, **k: (None, None)
    p = m.Poller()
    p.tick()
    print(json.dumps({"phase": "one", "keys": sorted(p.state["prs_present"])}))
    page["nodes"] = [row(9621, "MERGED"), row(9622, None)]
    live[9621] = "MERGED"
    p.tick()
    print(json.dumps({"phase": "two", "keys": sorted(p.state["prs_present"])}))
    # A third tick: the row is still returned by a search with no `is:open`, and must not
    # produce a second word about the same merge.
    p.tick()
    print(json.dumps({"phase": "three", "keys": sorted(p.state["prs_present"])}))

elif scenario == "status_sources":
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({}, set())
    m.gh = lambda *a: {"data": {"search": {"issueCount": 2, "nodes": PRS[:2]}}}
    m.Poller().tick()
    class A: all = False
    m.cmd_status(A())

elif scenario.startswith("redispatch"):
    # DEV-996 part 1. The fixtures all share one page shape and one `gh`, because what differs
    # between them is only which half of Patrick's definition of "new" is in play.
    #
    # 9999 is the control and it NEVER leaves the page. Without it the withdrawal tick would be an
    # empty search, `trust_empty` would refuse to believe it, and the key would never leave
    # `prs_present` -- so the scenario would pass while testing nothing it claims to.
    def row(n, state=None):
        r = {"number": n, "title": f"PR {n}", "url": f"https://github.com/o/r/pull/{n}",
             "isDraft": False, "headRefOid": f"sha{n}", "createdAt": "2026-10-01T00:00:00Z",
             "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
        if state:
            r["state"] = state
        return r
    mode = sys.argv[2] if len(sys.argv) > 2 else "returned"
    # One review-requested event per pull request, as GitHub's timeline carries them: the stamp
    # and who was asked. `tester` is this instance's `github.login`.
    EVENTS = {9801: ("2026-10-14T00:00:00Z", "tester"),      # after the ledger: a new request
              9802: ("2026-10-12T00:00:00Z", "tester"),      # before it: not new
              9803: ("2026-10-14T00:00:00Z", "somebody"),    # after it, but not of the principal
              9804: ("2026-10-14T00:00:00Z", None),          # after it, but of a TEAM
              # BEFORE the ledger stamp of the `returned` fixture, deliberately: that mode is
              # about the first test of "new", and an event after the ledger would hand it the
              # second one and prove nothing. A date is needed at all because Review Desk is
              # never told about a request this file cannot date.
              9404: ("2026-09-20T00:00:00Z", "tester"),
              9999: ("2026-09-20T00:00:00Z", "tester"),
              # Sixty seconds after the ledger write, which is the author pushing a fix and
              # asking again. A guard band on the comparison masked exactly this, and at a
              # 300-second poll no tick lands in the gap for the other test to see.
              9805: ("2026-10-13T00:01:00Z", "tester")}
    page = {"nodes": []}
    # What the live `gh pr view` says while a key is leaving the page. `why_cleared` reads it to
    # decide WHY, and since the red team of this branch that reason is what licenses a
    # re-dispatch: `reviewRequests: []` is a genuine withdrawal, a `login` in it is GitHub still
    # asking, and `isDraft` or a non-OPEN state is the row leaving for some other reason.
    view = {"state": "OPEN", "isDraft": False, "latestReviews": [], "reviewRequests": []}
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({"s1": {"last_known_status": "Idle"}}, set())
    def gh_rd(*args):
        if args[:2] == ("pr", "view"):
            return dict(view)
        if any("timelineItems" in a for a in args):
            if mode == "broken":
                raise RuntimeError("gh api graphql: boom")
            number = next((int(a.split("=", 1)[1]) for a in args if a.startswith("number=")), 0)
            stamp, who = EVENTS.get(number, (None, None))
            nodes = [] if not stamp else [{
                "createdAt": stamp,
                "requestedReviewer": {"login": who} if who else {"slug": "reviewers"}}]
            return {"data": {"repository": {"pullRequest": {"timelineItems": {"nodes": nodes}}}}}
        return {"data": {"search": {"issueCount": len(page["nodes"]), "nodes": page["nodes"]}}}
    m.gh = gh_rd
    p = m.Poller()
    if mode == "returned":
        # The #9404 shape: present, present, withdrawn, requested again, and again.
        page["nodes"] = [row(9404), row(9999)]
        p.tick(); print(json.dumps({"phase": "present_1"}))
        p.tick(); print(json.dumps({"phase": "present_2"}))
        page["nodes"] = [row(9999)]
        p.tick(); print(json.dumps({"phase": "gone", "present": sorted(p.state["prs_present"]),
                                    "marks": sorted(p.state["redispatched"]),
                                    "withdrawn": sorted(p.state["withdrawn"])}))
        page["nodes"] = [row(9404), row(9999)]
        p.tick(); print(json.dumps({"phase": "again", "marks": sorted(p.state["redispatched"])}))
        p.tick(); print(json.dumps({"phase": "still", "marks": sorted(p.state["redispatched"])}))
    elif mode in ("team", "spent"):
        # `team`: the request is held by a TEAM, so `still_requested` cannot attribute the list,
        # and the principal's own review IS the latest review -- which is what `done` means. The
        # answer must be "cannot tell", not "you submitted a review": the second is a withdrawal
        # and would both take a live request off the Reviews list and re-dispatch the review.
        #
        # `spent`: the request is genuinely withdrawn and made again, but the tick it comes back
        # on returns early on a moved head. The record must survive that tick unread.
        view["reviewRequests"] = [{"slug": "reviewers"}] if mode == "team" else []
        view["latestReviews"] = [{"author": {"login": "tester"}, "state": "APPROVED"}]
        if mode == "spent":
            m.round_started = lambda held, entry: True
            m.Poller.head_moved = lambda self, *a, **k: None
        page["nodes"] = [row(9404), row(9999)]
        p.tick()
        page["nodes"] = [row(9999)]
        p.tick()
        print(json.dumps({"phase": "left", "withdrawn": sorted(p.state["withdrawn"])}))
        page["nodes"] = [row(9404), row(9999)]
        if mode == "spent":
            # A push landed between the withdrawal and the re-request, so this tick wakes a
            # session and returns before the test for a new request is ever made.
            m.Poller.record_request = lambda self, *a, **k: ("head_moved", "shaold")
        p.tick()
        print(json.dumps({"phase": "back", "marks": sorted(p.state["redispatched"]),
                          "withdrawn": sorted(p.state["withdrawn"])}))
        if mode == "spent":
            m.Poller.record_request = lambda self, *a, **k: (None, None)
            p.tick()
            print(json.dumps({"phase": "later", "marks": sorted(p.state["redispatched"])}))
    elif mode in ("draft", "index", "reopen"):
        # THE BLOCKER, three ways. Each of these takes the row off the poller's page with the
        # request still live on GitHub, and `returned` alone read every one of them as a
        # withdrawal-and-remake — a second session on a review that is finished, which is #9404's
        # own harm inverted. The live reason is the discriminator, and each mode drives a
        # different one.
        page["nodes"] = [row(9404), row(9999)]
        p.tick(); p.tick()
        if mode == "draft":
            # The author converts to draft. `skip_drafts` filters the row before it can join
            # `present`, and the live read says so.
            view["isDraft"] = True
            page["nodes"] = [row(9999)]
        elif mode == "index":
            # GitHub's search index omits the row while `issueCount` agrees with what it
            # returned, so the tick is TRUSTED and `trust_empty` has nothing to disbelieve. The
            # live read says the principal is still being asked.
            view["reviewRequests"] = [{"login": "tester"}]
            page["nodes"] = [row(9999)]
        else:
            # Closed, then reopened. `request_closed` takes the row out of `present` before the
            # sweep, which the file documents as deliberate.
            view["state"] = "CLOSED"
            page["nodes"] = [row(9404, "CLOSED"), row(9999)]
        p.tick()
        print(json.dumps({"phase": "left", "present": sorted(p.state["prs_present"]),
                          "withdrawn": sorted(p.state["withdrawn"])}))
        view.update({"state": "OPEN", "isDraft": False, "reviewRequests": []})
        page["nodes"] = [row(9404), row(9999)]
        p.tick()
        print(json.dumps({"phase": "back", "marks": sorted(p.state["redispatched"])}))
    elif mode == "statuses":
        # One tick each side of a withdrawal, with every status a request can arrive against.
        page["nodes"] = [row(n) for n in (9811, 9812, 9813, 9814, 9815, 9999)]
        p.tick()
        page["nodes"] = [row(9999)]
        p.tick()
        page["nodes"] = [row(n) for n in (9811, 9812, 9813, 9814, 9815, 9999)]
        print(json.dumps({"phase": "back"}))
        p.tick()
    else:
        # The dated half, which needs no withdrawal at all: four requests present from the first
        # tick, so `returned` is false for every one of them and only the stamp can speak.
        page["nodes"] = [row(n) for n in (9801, 9802, 9803, 9804, 9805, 9999)]
        p.tick()
        print(json.dumps({"phase": "dated_1", "marks": sorted(p.state["redispatched"]),
                          "date_stopped": p.date_stopped}))
        # A SECOND tick with nothing changed, which is the only shape that can show what the
        # mark is for: the stamp still postdates the ledger, so this half of "new" goes on
        # saying yes for as long as the request is open. `returned` cannot say yes twice -- the
        # key is in `prs_present` after the first tick -- so the withdrawal scenario above
        # cannot reach this, and a control written against it passed for the wrong reason.
        p.tick()
        print(json.dumps({"phase": "dated", "marks": sorted(p.state["redispatched"]),
                          "date_stopped": p.date_stopped}))

elif scenario == "stale_withdrawal":
    # The withdrawal record is the first test's only evidence, and it is kept no longer than
    # `WITHDRAWN_KEEP_SECS`. A record older than that is dropped rather than licensing a
    # dispatch nobody can account for -- and an unreadable stamp is dropped too.
    offline()
    p = m.Poller()
    fresh = {"at": m.now_iso(), "why": "review request removed"}
    old = {"at": "2026-01-01T00:00:00+00:00", "why": "review request removed"}
    print(json.dumps({"fresh": m.Poller.withdrawal_fresh(fresh),
                      "old": m.Poller.withdrawal_fresh(old),
                      "garbage": m.Poller.withdrawal_fresh({"at": "not a date"}),
                      "missing": m.Poller.withdrawal_fresh({}),
                      "not_a_dict": m.Poller.withdrawal_fresh("x")}))

elif scenario == "spoken_for":
    # The fifth shape, driven directly. `done` is ALIVE, so shape 1's REDISPATCHABLE test cannot
    # see a re-dispatched key -- and the tick that re-dispatches one is the tick the Review Desk
    # source could offer the same review a second time.
    offline()
    p = m.Poller()
    item = {"kind": "review_requested", "ledger_id": "gh-r-9404", "repo": "o/r", "pr": 9404}
    done = {"status": "done", "session_id": "s1"}
    before = p.request_spoken_for("gh-r-9404", done, item)
    # The PERSISTED mark, which is what the pass writes and what the next tick still carries. A
    # tick-scoped set closed only the same-tick case: the red team measured the GitHub pass
    # offering the key on tick 3 and the Review Desk pass offering it on tick 4.
    p.state["redispatched"]["gh-r-9404"] = {"at": m.now_iso(), "why": "test"}
    after = p.request_spoken_for("gh-r-9404", done, item)
    # And the spelling the two sources disagree about, which is the whole reason `requested_key`
    # exists: GitHub hands back `nameWithOwner` as registered, Review Desk lower-cases it.
    p.state["redispatched"]["gh-Locus-86"] = {"at": m.now_iso(), "why": "test"}
    mixed = p.request_spoken_for("gh-locus-86", done, {"ledger_id": "gh-locus-86"})
    print(json.dumps({"before": before, "after": after, "mixed": mixed}))

elif scenario.startswith("tell"):
    # DEV-996 part 2: the call itself. The stand-in on PATH is what answers, so `review_desk_run`
    # -- the real one, with its real argv list and its real exit-code reading -- is under test.
    def row(n, state=None):
        r = {"number": n, "title": f"PR {n}", "url": f"https://github.com/o/r/pull/{n}",
             "isDraft": False, "headRefOid": f"sha{n}", "createdAt": "2026-10-01T00:00:00Z",
             "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
        if state:
            r["state"] = state
        return r
    mode = sys.argv[2] if len(sys.argv) > 2 else "told"
    rdwork = pathlib.Path(os.environ["RDWORK"])
    page = {"nodes": [row(9481), row(9464)]}
    # One review-requested event per pull request, as GitHub's timeline carries them. 9470 has
    # NONE, which is Review Desk's first rule: `--requested-at` is when GitHub made the request,
    # so a request this file cannot date is not recorded at all rather than stamped with the
    # sighting time. A second event appears on 9481 between two ticks in the `renew` mode.
    events = {9481: ["2026-10-14T00:00:00Z"], 9464: ["2026-10-13T00:00:00Z"], 9470: []}
    # How many times GitHub was asked for each pull request's request date. An undated request
    # has no record to stop the asking, so without a bound it is one GraphQL query per tick for
    # ever -- and the bound must NOT also rate-limit a key whose Review Desk call failed.
    asked = {}
    live = {}
    # Whether the live `gh pr view` answers at all. `why_cleared` needs it to say WHY a request
    # left, and a tick where it fails is the one the red team found: the sweep passes a key once,
    # so the record used to be pruned and the withdrawal lost for ever.
    boom = {"on": False, "dates": False}
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({}, set())
    def gh_tell(*args):
        if args[:2] == ("pr", "view"):
            if boom["on"]:
                raise RuntimeError("gh pr view: boom")
            return {"state": live.get(int(args[2]), "OPEN"), "isDraft": False,
                    "latestReviews": [], "reviewRequests": []}
        if any("timelineItems" in a for a in args):
            if boom["dates"]:
                raise RuntimeError("gh api graphql: boom")
            number = next((int(a.split("=", 1)[1]) for a in args if a.startswith("number=")), 0)
            asked[number] = asked.get(number, 0) + 1
            nodes = [{"createdAt": at, "requestedReviewer": {"login": "tester"}}
                     for at in events.get(number, [])]
            return {"data": {"repository": {"pullRequest": {"timelineItems": {"nodes": nodes}}}}}
        return {"data": {"search": {"issueCount": len(page["nodes"]), "nodes": page["nodes"]}}}
    m.gh = gh_tell
    # The record of a round is NOT what this half is about, and letting it through would put the
    # stand-in's `review open` calls in the same log as the ones under test.
    m.Poller.record_request = lambda self, rd, key, *a, **k: (None, None)
    m.Poller.record_if_never_reviewed = lambda self, rd, recording, key, *a, **k: None
    if mode == "told":
        # The third row is the undated one, added here so the other modes' pages are unchanged.
        page["nodes"] = [row(9481), row(9464), row(9470)]
    if mode == "date_flake":
        boom["dates"] = True
    if mode == "timeout":
        # What `review_desk_run` hands back when the binary does not answer, which is the one
        # answer a stand-in cannot produce in under 30 seconds. The DETECTION is that function's
        # and is pinned where it lives; what is under test here is this file's handling of it.
        m.review_desk_run = lambda rd, *a, **k: (
            "broken", None, "review-desk review requested did not answer in 30s")
    p = m.Poller()
    if mode != "renew":
        p.tick()
    at_9481 = (p.state["requests"].get("gh-r-9481") or {}).get("at")
    print(json.dumps({"phase": "first", "requests": sorted(p.state["requests"]),
                      # The stamp Review Desk is given is GitHub's own, and nothing else may
                      # stand in for it. Asserted as a comparison rather than as a literal,
                      # because a literal would pin the fixture's date in two files.
                      "dated_from_github": at_9481 == int(m.parse_iso("2026-10-14T00:00:00Z")),
                      "at_9481": at_9481}))
    if mode == "told":
        p.tick()
        print(json.dumps({"phase": "asked", "asked_9470": asked.get(9470),
                          "asked_9481": asked.get(9481)}))
    if mode in ("told", "timeout"):
        p.tick()
        print(json.dumps({"phase": "second", "requests": sorted(p.state["requests"])}))
    elif mode == "withdrawn":
        # 9481's request is withdrawn -- GitHub stops listing it, the pull request is still open.
        # 9464 MERGES, which GitHub goes on listing: it leaves `present` by this file's own merge
        # guard, and its request is not a withdrawal.
        page["nodes"] = [row(9464, "MERGED")]
        live[9464] = "MERGED"
        p.tick()
        print(json.dumps({"phase": "withdrawn", "requests": sorted(p.state["requests"])}))
    elif mode == "renew":
        # Review Desk's second rule: the verb is called on first sight AND when a new request
        # appears. A request made while the row never left the page is the second case, and the
        # record this poller holds still carries the first request's timestamp -- which their
        # store reads to decide whether a round satisfied it. The ledger's own stamp sits BETWEEN
        # the two events, so tick 1 records and dispatches nothing and tick 2 does both.
        p.tick()
        print(json.dumps({"phase": "renew_1", "requests": sorted(p.state["requests"]),
                          "at_9481": (p.state["requests"].get("gh-r-9481") or {}).get("at")}))
        events[9481].append("2026-10-16T00:00:00Z")
        p.tick()
        print(json.dumps({"phase": "renew_2",
                          "at_9481": (p.state["requests"].get("gh-r-9481") or {}).get("at"),
                          "marks": sorted(p.state["redispatched"])}))
    elif mode == "date_flake":
        # One `gh` failure takes the date for every key on the page, and the undated bound must
        # NOT be spent on it: the next healthy tick records, rather than a window later.
        print(json.dumps({"phase": "flaked", "requests": sorted(p.state["requests"]),
                          "undated": sorted(k for k in p.state["emitted"]
                                            if k.startswith("review_desk|undated|"))}))
        boom["dates"] = False
        p.tick()
        print(json.dumps({"phase": "recovered", "requests": sorted(p.state["requests"])}))
    elif mode == "stopped_withdraw":
        # Two requests clear on one tick against a broken store. The per-tick bound covers the
        # withdrawal path too, so the first one asks and the second takes the debt.
        page["nodes"] = [row(9470)]
        (rdwork / "rd.mode").write_text("broken")
        p.tick()
        print(json.dumps({"phase": "stopped",
                          "debts": sorted(k for k, v in p.state["requests"].items()
                                          if isinstance(v, dict) and v.get("withdraw"))}))
    elif mode == "unresolved":
        # The request is genuinely withdrawn on the tick `gh pr view` cannot be reached. The
        # reason is then `CANNOT_READ_PR`, which is NOT a withdrawal -- nothing may be written on
        # a call that did not answer -- so the record has to survive until something can ask
        # again. `settle_requests` is that something.
        page["nodes"] = [row(9464)]
        boom["on"] = True
        p.tick()
        held = p.state["requests"].get("gh-r-9481") or {}
        print(json.dumps({"phase": "unresolved", "unresolved": held.get("unresolved"),
                          "requests": sorted(p.state["requests"])}))
        boom["on"] = False
        p.tick()
        print(json.dumps({"phase": "settled", "requests": sorted(p.state["requests"]),
                          "withdrawn": sorted(p.state["withdrawn"])}))
    elif mode == "owed_back":
        # The debt, and then the request coming BACK before it could be collected. Withdrawing
        # then would be a lie this file would have to take back, so the request is told again
        # with its own timestamp and the debt is cleared instead.
        page["nodes"] = [row(9464)]
        (rdwork / "rd.mode").write_text("broken")
        p.tick()
        print(json.dumps({"phase": "owed",
                          "withdraw": (p.state["requests"].get("gh-r-9481") or {}).get("withdraw")}))
        (rdwork / "rd.mode").write_text("ok")
        page["nodes"] = [row(9481), row(9464)]
        p.tick()
        print(json.dumps({"phase": "back", "held": p.state["requests"].get("gh-r-9481")}))
    elif mode == "owed":
        # The withdrawal meets a broken store, and the next tick collects the debt. `prs_present`
        # is overwritten every trusted tick, so without the retry this withdrawal is lost for good.
        page["nodes"] = [row(9464)]
        (rdwork / "rd.mode").write_text("broken")
        p.tick()
        held = p.state["requests"].get("gh-r-9481") or {}
        print(json.dumps({"phase": "owed", "withdraw": held.get("withdraw"),
                          "requests": sorted(p.state["requests"])}))
        (rdwork / "rd.mode").write_text("ok")
        p.tick()
        print(json.dumps({"phase": "collected", "requests": sorted(p.state["requests"])}))

else:
    sys.exit("unknown scenario " + scenario)
EOF

# ---- Defect A: the start-up backlog, against a state file that already has `started` --------

printf '\nDefect A -- first_tick against a persisted `started`\n'

instance "2026-09-11T13:18:11+00:00"
ok "a 19-day-old persisted \`started\` still gives first_tick" "$(run "$disp" first_tick; :)$(says '"first_tick": true')" "0yes"

instance ""
ok "a fresh instance gives first_tick too"                     "$(run "$disp" first_tick; :)$(says '"first_tick": true')" "0yes"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" one_tick)
ok "the first tick emits poller_started"            "$(says '"event": "poller_started"')" "yes"
ok "all ten review requests surface"                "$(flagged true)"                     "10"
ok "none is silently flagged backlog false"         "$(flagged false)"                    "0"
ok "\`started\` is retained, not deleted"             "$(says '"started_on_disk": "2026-09-11T13:18:11+00:00"')" "yes"
ok "the tick exits clean"                           "$rc"                                 "0"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" two_ticks)
ok "a second tick of the same process re-emits none" "$(sed -n '/"tick": 2/,$p' "$work/out" | grep -c '"event": "review_request"' || true)" "0"
ok "only one poller_started per process"             "$(grep -c '"event": "poller_started"' "$work/out" || true)" "1"

# ---- the error path: a destination that does not need stdout to reach a reader ---------------

printf '\nThe error path -- a thrown section, off stdout\n'

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" section_throws)
ok "a thrown section writes a runtime record"        "$(says '"records": 1')"              "yes"
ok "the record names the section"                    "$(says '"section": "review_requests"')" "yes"
ok "the record carries a traceback"                  "$(says '"has_traceback": true')"     "yes"
ok "a thrown section also reaches stderr"            "$(onerr 'poller: review_requests failed')" "yes"
ok "the stdout \`error\` event still fires"            "$(grep -c '"event": "error"' "$work/out" || true)" "1"
ok "a thrown section does not kill the poller"       "$rc"                                 "0"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" durable_before_state_write)
ok "the record lands before the tick's state write"  "$(says '"log_exists": true')"        "yes"
ok "while \`state[errors]\` never reached disk"        "$(says '"errors_persisted": false')"  "yes"
ok "though it is set in memory, as before"           "$(says '"in_memory_errors": 1')"      "yes"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" bounded)
ok "1200 records stay under twice the cap"     "$(says '"under_cap": true')"         "yes"
ok "the log was actually trimmed"                    "$(says '"trimmed": true')"           "yes"
ok "every surviving record still parses"             "$(says '"all_parse": true')"         "yes"
ok "the bound keeps the newest, not the oldest"      "$(says '"newest_kept": true')"       "yes"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" status)
ok "\`status\` reports the last poller error"          "$(says 'last poller error: review_requests')" "yes"

# ---- DEV-799: an empty search is not an empty inbox ------------------------------------------
#
# Folded into this PR because it can silently undo the fix above: an unbelieved empty tick used to
# drop a start-up item's backlog flag, so the repair would survive exactly until the next one.

printf '\nDEV-799 -- an empty result is not an empty world\n'

instance "2026-09-11T13:18:11+00:00"
entry gh-r-9481 skipped
entry gh-r-9464 active s2
rc=$(run "$disp" empty_guard)
ok "a full tick records the backlog"                 "$(sed -n '/"phase": "after_full"/p' "$work/out" | grep -c "gh-r-9435" || true)" "1"
ok "an empty search leaves prs_present alone"        "$(sed -n '/after_empty_present/p' "$work/out" | grep -c "gh-r-9481" || true)" "1"
ok "an empty search keeps the backlog NON-empty"     "$(sed -n '/"phase": "after_empty"/p' "$work/out" | grep -c "gh-r-9435" || true)" "1"
ok "an empty search emits no review_cleared"         "$(grep -c '"event": "review_cleared"' "$work/out" || true)" "0"
ok "it says so with a source_empty event"            "$(says '"event": "source_empty"')"   "yes"
ok "the source_empty is not believed"                "$(says '"believed": false')"         "yes"
ok "the fault names matched vs returned"             "$(says 'matched 3 and returned 0')"  "yes"
ok "the zero streak is recorded"                     "$(says '"streak": 1')"              "yes"
ok "no skipped PR is resurrected as rerequested"     "$(grep -c '"rerequested": true' "$work/out" || true)" "0"
ok "no false review_rerequested on recovery"         "$(grep -c '"event": "review_rerequested"' "$work/out" || true)" "0"
ok "the start-up item keeps its backlog flag"        "$(sed -n '/after_recovery/p' "$work/out" | grep -c "gh-r-9435" || true)" "1"
ok "the guarded tick exits clean"                    "$rc"                                 "0"

# B1 (#63): an affirmative `issueCount: 0` used to be believed at once. It must not be --
# `issueCount` and `nodes` come from the same query against the same eventually-consistent index,
# so a stale index reports 0 for both, which is the very shape the guard exists to refuse.
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" genuine_empty)
ok "issueCount 0 is NOT believed on the first zero"  "$(says '"believed": false')"         "yes"
ok "it is refused as the index-lag shape"            "$(says 'returned 0 after a non-empty tick')" "yes"
ok "and a second zero does believe it"               "$(says '"believed_on_second": true')" "yes"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" two_zeroes)
ok "a first zero keeps the trigger markers"          "$(sed -n '/zero_1/p' "$work/out" | grep -c 'ZZ-1|trigger' || true)" "1"
ok "the second zero sweeps them"                     "$(sed -n '/zero_2/p' "$work/out" | grep -c 'ZZ-1|trigger' || true)" "0"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" status_sources)
ok "\`status\` reports per-source counts"             "$(says 'sources: github 2 items')"   "yes"

# S1 (#63): truncation is a third shape -- a NON-empty response that still loses keys.
instance "2026-09-11T13:18:11+00:00"
# 9400/9401 LEAVE the rotated page; 9450/9451 ARRIVE on it. Only an arriving key can reach the two
# ungated emits, so the entries go there -- the leaving pair is what made this fixture blind (S8).
entry gh-r-9400 active s2
entry gh-r-9450 skipped
entry gh-r-9451 active s2
rc=$(run "$disp" truncated)
ok "52 open behind first:50 is called out"           "$(says 'page one of')"               "yes"
ok "truncation clears nothing"                       "$(grep -c '"event": "review_cleared"' "$work/out" || true)" "0"
# B2 (#63): the frozen snapshot used to re-offer a skipped PR once per truncated tick, ungated.
ok "a skipped PR is re-offered at most once"         "$(grep -c '"rerequested": true' "$work/out" || true)" "1"
ok "one false review_rerequested at most"            "$(grep -c '"event": "review_rerequested"' "$work/out" || true)" "1"
ok "prs_present is committed, not frozen"            "$(says '"phase": "trunc2", "present": 52')" "yes"
ok "and stays stable across truncated ticks"         "$(says '"phase": "trunc4", "present": 52')" "yes"
ok "review_backlog does not grow per tick"           "$(says '"stable": true')"            "yes"
ok "and carries no duplicates"                       "$(says '"no_duplicates": true')"     "yes"
ok "the settled tick committed all 50"               "$(says '"phase": "settled", "present": 50')" "yes"
ok "the rotated-out key stays in prs_present"        "$(says '"9400_still_present": true')" "yes"
ok "the truncated tick exits clean"                  "$rc"                                 "0"

# A SEPARATE run, so it goes after every assertion that reads the previous one. `$work/out` is
# shared and `run` overwrites it, so an invocation inserted mid-block silently retargets the
# assertions below it -- which is how two of these briefly passed against the wrong output.
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" trunc_runs)
ok "nor across four truncated processes"             "$(says '"stable": true')"            "yes"
ok "the four-process run exits clean"                "$rc"                                 "0"

# S5 (#63): the caller can state the policy instead of inheriting it from the host's shape.
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" backlog_flag off)
ok "\`--no-backlog\` flags nothing as backlog"         "$(flagged true)"                     "0"
# It suppresses the POLICY, never the record that a process ran -- see S9. `poller_started` firing
# regardless is why this assertion is not "0".
ok "but still emits poller_started"                  "$(grep -c '"event": "poller_started"' "$work/out" || true)" "1"
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" backlog_flag on)
ok "\`--backlog\` announces it"                       "$(grep -c '"event": "poller_started"' "$work/out" || true)" "1"
# S7 (#63): the real CLI, not a stub -- a flipped argparse default must fail here.
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" cli)
ok "a plain \`poll --once\` announces the backlog"    "$(flagged true)"                     "10"
ok "and emits poller_started"                        "$(grep -c '"event": "poller_started"' "$work/out" || true)" "1"
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" cli --no-backlog)
ok "\`--no-backlog\` via the CLI suppresses it"        "$(flagged true)"                     "0"
ok "but still reports a process started"             "$(says '"backlog_suppressed": true')" "yes"

# S9 (#63): a first call carrying --no-backlog must not go unrecorded.
instance ""
rc=$(run "$disp" no_backlog_first_call)
ok "a suppressed first call still emits the start"   "$(grep -c '"event": "poller_started"' "$work/out" || true)" "1"
ok "it says the policy was suppressed"               "$(says '"backlog_suppressed": true')" "yes"
ok "and \`started\` is written anyway"                 "$(says '"started_written": true')"    "yes"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" no_backlog_keeps_state)
ok "\`--no-backlog\` keeps the undecided keys"         "$(says '"preserved": true')"         "yes"
ok "and does not rewrite \`started\`"                  "$(says '"started": "2026-09-11T13:18:11+00:00"')" "yes"

# S4 (#63): `status` must not raise on state written by another version of this file.
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" hostile_state)
ok "\`status\` survives a foreign sources bucket"     "$(says '"status_survived": true')"   "yes"
ok "a foreign bucket reads as unknown, not 3"        "$(says 'github ? items never')"      "yes"
ok "an unparseable stamp reads unreadable"           "$(says 'unreadable')"                "yes"
ok "and exits clean"                                 "$rc"                                 "0"

# ---- DEV-959: a merged or closed pull request gets nothing from the GitHub pass --------------
#
# `is:open` in `github.review_query` is not the guard it looks like. It is instance config, and
# GitHub's search index lags a merge, so the search goes on matching a pull request that merged
# while the last tick was running. The row's own `state` narrows; a LIVE `gh pr view` decides.

printf '\nDEV-959 -- a merged pull request is not a review request\n'

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" pr_state_rows)
# `record_request` is the OPEN path. A closed row must never take it: it re-asks on a moved head,
# which on a review that exists is the next ROUND -- a round spent on a shipped pull request.
ok "a MERGED row never takes the open path"          "$(sed -n '/"phase": "recorded"/p' "$work/out" | grep -c 'gh-r-9602' || true)" "0"
ok "a CLOSED row never takes it either"              "$(sed -n '/"phase": "recorded"/p' "$work/out" | grep -c 'gh-r-9603' || true)" "0"
ok "a lower-case \`merged\` is read the same way"     "$(sed -n '/"phase": "recorded"/p' "$work/out" | grep -c 'gh-r-9605' || true)" "0"
ok "an OPEN row still takes it"                      "$(sed -n '/"phase": "recorded"/p' "$work/out" | grep -c 'gh-r-9601' || true)" "1"
# But a closed pull request Review Desk has never held a review of IS recorded, exactly once, by
# the narrow path. Patrick amended the criterion for this: a request nobody got to, on a pull
# request that then merged unreviewed, is the row DEV-945 exists to produce.
ok "a never-reviewed MERGED row is still recorded"   "$(sed -n '/"phase": "opened"/p' "$work/out" | grep -c 'gh-r-9602' || true)" "1"
ok "  and a never-reviewed CLOSED one too"           "$(sed -n '/"phase": "opened"/p' "$work/out" | grep -c 'gh-r-9603' || true)" "1"
ok "  while an OPEN row does not take that path"     "$(sed -n '/"phase": "opened"/p' "$work/out" | grep -c 'gh-r-9601' || true)" "0"
ok "  and the event carries the review it wrote"     "$(grep -c '"event": "review_request_closed".*9602.*"review_desk_id": 77' "$work/out" || true)" "1"
# The row with no `state` at all. Every other fixture in this file is that shape, so reading it
# as closed would silently empty the rest of the harness -- which is the failure this pins.
ok "a row with no state reads as open"               "$(sed -n '/"phase": "recorded"/p' "$work/out" | grep -c 'gh-r-9604' || true)" "1"
# The search's `state` only NARROWS. Nothing establishes that GitHub resolves it from the live
# record rather than from the same index snapshot that produced the row, and `trust_empty` has a
# captured measurement saying the adjacent field is index-derived -- so a stale MERGED must not
# drop a live request.
ok "a stale MERGED is overruled by the live read"    "$(sed -n '/"phase": "recorded"/p' "$work/out" | grep -c 'gh-r-9607' || true)" "1"
ok "a MERGED row offers no review_request"           "$(grep -c '"event": "review_request",.*9602' "$work/out" || true)" "0"
ok "a CLOSED row offers no review_request"           "$(grep -c '"event": "review_request",.*9603' "$work/out" || true)" "0"
ok "an OPEN row still offers one"                    "$(grep -c '"event": "review_request",.*9601' "$work/out" || true)" "1"
ok "the stale-MERGED row is offered too"             "$(grep -c '"event": "review_request",.*9607' "$work/out" || true)" "1"
# It LEAVES prs_present, like a row that went draft. Keeping it would make the merge reportable
# only when the search index drops the row -- two ticks under the shipped query and never under
# one without `is:open`, which is the configuration this guard exists for.
ok "a merged row leaves prs_present"                 "$(sed -n '/"phase": "present"/p' "$work/out" | grep -c 'gh-r-9602' || true)" "0"
ok "an open row stays in it"                         "$(sed -n '/"phase": "present"/p' "$work/out" | grep -c 'gh-r-9601' || true)" "1"
# And the drop is not silent. Every other refusal to act in this poller says itself once with a
# reason; a request the Dispatcher can SEE on GitHub, dropped in silence, is DEV-934's lesson
# with a merge in front of it.
ok "the drop says itself once, with the state"       "$(grep -c '"event": "review_request_closed".*9602' "$work/out" || true)" "1"
ok "  naming the live state, not the search's"       "$(grep -c '"event": "review_request_closed".*9602.*"pr_state": "merged"' "$work/out" || true)" "1"
ok "  and a CLOSED one says closed"                  "$(grep -c '"event": "review_request_closed".*9603.*"pr_state": "closed"' "$work/out" || true)" "1"
ok "nothing was said about the open rows"            "$(grep -c '"event": "review_request_closed".*9601' "$work/out" || true)" "0"
ok "the tick exits clean"                            "$rc"                                 "0"

# `pr_state` answers None when GitHub cannot be asked, and this file refuses to read that as
# closed: an item the dispatcher cannot place is better dispatched and discarded by a human who
# can read the pull request than dropped silently.
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" closed_unreadable)
ok "an unreadable PR is not read as closed"          "$(sed -n '/"phase": "recorded"/p' "$work/out" | grep -c 'gh-r-9611' || true)" "1"
ok "  and takes the open path, not the narrow one"   "$(sed -n '/"phase": "opened"/p' "$work/out" | grep -c 'gh-r-9611' || true)" "0"
ok "  and stays in prs_present"                      "$(sed -n '/"phase": "present"/p' "$work/out" | grep -c 'gh-r-9611' || true)" "1"
ok "  and is offered for dispatch"                   "$(grep -c '"event": "review_request",.*9611' "$work/out" || true)" "1"
ok "  and says nothing about being closed"           "$(grep -c '"event": "review_request_closed"' "$work/out" || true)" "0"
ok "  and exits clean"                               "$rc"                                 "0"

instance "2026-09-11T13:18:11+00:00"
entry gh-r-9602 active s9
entry gh-r-9606 active s9
rc=$(run "$disp" merged_rerequest)
ok "a merged row sends no review_rerequested"        "$(grep -c '"event": "review_rerequested".*9602' "$work/out" || true)" "0"
# The control, in the same run: an open PR arriving against a mid-round session DOES re-request,
# so "nothing was emitted" cannot pass because the branch was never reached.
ok "an open row arriving does re-request"            "$(grep -c '"event": "review_rerequested".*9606' "$work/out" || true)" "1"
ok "and it exits clean"                              "$rc"                                 "0"

printf '\n  a review that already exists is never written to\n'
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" closed_held)
ok "a held review blocks the recording"              "$(sed -n '/"phase": "opened"/p' "$work/out" | grep -c 'gh-r-9631' || true)" "0"
ok "  on a closed pull request as well"              "$(sed -n '/"phase": "opened"/p' "$work/out" | grep -c 'gh-r-9632' || true)" "0"
ok "  and the drop is still said"                    "$(grep -c '"event": "review_request_closed".*9631' "$work/out" || true)" "1"
ok "  with no review id, because none was written"   "$(grep -c '"event": "review_request_closed".*9631.*"review_desk_id": null' "$work/out" || true)" "1"
ok "  and it exits clean"                            "$rc" "0"

printf '\n  and an install that could not be asked is never written to blindly\n'
# `find_request` answers None for an empty store AND for an install it could not use. Writing on
# the second is the blind write the look exists to prevent, so the flags it sets are what tells
# the two apart -- each driven here in turn.
for flag in record_stopped look_stopped refused; do
  instance "2026-09-11T13:18:11+00:00"
  rc=$(run "$disp" closed_unlookable "$flag")
  ok "'$flag': nothing is written"                   "$(sed -n '/"phase": "opened"/p' "$work/out" | grep -c 'gh-r-9641' || true)" "0"
  ok "  and the tick exits clean"                    "$rc" "0"
done

printf '\n  the merge reaches the Dispatcher on the tick it is seen\n'
instance "2026-09-11T13:18:11+00:00"
entry gh-r-9621 active s1
entry gh-r-9622 active s1
rc=$(run "$disp" merged_clears)
ok "tick 1 holds both keys"                          "$(sed -n '/"phase": "one"/p' "$work/out" | grep -c 'gh-r-9621' || true)" "1"
ok "the merged key leaves on tick 2"                 "$(sed -n '/"phase": "two"/p' "$work/out" | grep -c 'gh-r-9621' || true)" "0"
ok "  and the sweep names it for the session"        "$(grep -c '"event": "review_cleared".*gh-r-9621' "$work/out" || true)" "1"
ok "  with the live reason, not a guess"             "$(grep -c '"reason": "PR merged"' "$work/out" || true)" "1"
ok "  and names the session to discard"              "$(grep -c '"event": "review_cleared".*"session_id": "s1"' "$work/out" || true)" "1"
# The sweep is the better event for a live session -- it names the session -- so the blunter
# `review_request_closed` must stay out of its way rather than double up.
ok "  and does not also say request_closed"          "$(grep -c '"event": "review_request_closed".*9621' "$work/out" || true)" "0"
ok "a third tick repeats neither"                    "$(grep -c '"event": "review_cleared".*gh-r-9621' "$work/out" || true)" "1"
ok "the open key is untouched"                       "$(sed -n '/"phase": "three"/p' "$work/out" | grep -c 'gh-r-9622' || true)" "1"
ok "and it exits clean"                              "$rc"                                 "0"

printf '\n  the query itself must ask for the state\n'
# S6's guard, and the reason it is an assertion rather than a comment: every `gh` stand-in for
# the search in this repo returns rows with no `state`, and the fallback reads those as open --
# so dropping the field from REVIEWS_Q in a bad merge would revert DEV-959 with the whole suite
# still green. This file's own memory of that shape is at `pr_state`: "The harness missed it
# because the stand-in `gh` answered the shape I had assumed."
ok "REVIEWS_Q asks for each row's state"             "$(grep -c 'number title url isDraft state headRefOid' "$disp" || true)" "1"

# ---- DEV-996: a new request re-dispatches, and Review Desk hears about the request -----------
#
# #9404 on 15 October 2026: GitHub requested a review again, the ledger said "done, round 2", and
# nothing was dispatched and nothing said. Patrick's decision on the ticket is that a NEW request
# starts a new round, and his definition of new is two tests -- it went away and came back, or the
# request event postdates the ledger. A request that never went away is not new.

printf '\nDEV-996 -- a new request on a `done` entry\n'

# Review Desk OFF, and the stand-in reachable, so this half is proved to need neither: the
# re-dispatch is a decision about this instance's own ledger, and `mode: off` must make no call.
instance "2026-09-11T13:18:11+00:00"
desk off
done_entry gh-r-9404 "2026-10-01T00:00:00+00:00"
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" redispatch returned)
ok "the withdrawn-and-remade request is offered"     "$(grep -c '"event": "review_request",.*9404' "$work/out" || true)" "1"
ok "  flagged as a re-request, like a skipped one"   "$(grep -c '"rerequested": true.*"key": "gh-r-9404"' "$work/out" || true)" "1"
ok "  and as something that happened, not backlog"   "$(grep -c '"backlog": false, "rerequested": true.*"key": "gh-r-9404"' "$work/out" || true)" "1"
ok "  saying which half of \"new\" it was"             "$(says 'the request was withdrawn and made again')" "yes"
# The pre-fix behaviour, and the whole of #9404: `done` is ALIVE, so a returned request fell into
# `review_rerequested` -- a message to a session that posted its review and was then discarded.
ok "  and never as a message to a dead session"      "$(grep -c '"event": "review_rerequested".*9404' "$work/out" || true)" "0"
# Two ticks with the request present, before it was ever withdrawn. A request that never went
# away is not new, and dispatching one would put a second session on every finished review.
ok "a request that never went away is not new"       "$(sed -n '1,/"phase": "present_2"/p' "$work/out" | grep -c '"event": "review_request",.*9404' || true)" "0"
# The two ticks AFTER it came back. One `review_request`, not one per tick: the count above is
# over the whole run, so this is what says the second tick added none.
ok "the same request dispatches once, not per tick"  "$(sed -n '/"phase": "again"/,$p' "$work/out" | grep -c '"event": "review_request",.*9404' || true)" "0"
ok "the mark is kept while the request is open"      "$(sed -n '/"phase": "still"/p' "$work/out" | grep -c 'gh-r-9404' || true)" "1"
ok "  and dropped when the request goes away"        "$(sed -n '/"phase": "gone"/p' "$work/out" | grep -c '"marks": \[\]' || true)" "1"
# The control, in the same run: a request with no ledger entry at all is offered as it always was,
# so "nothing was emitted" cannot pass by the pass having died.
ok "an ordinary request is still offered"            "$(grep -c '"event": "review_request",.*9999' "$work/out" || true)" "1"
ok "\`mode: off\` makes no Review Desk call at all"    "$(calls 'review requested')" "0"
ok "and the run exits clean"                         "$rc" "0"

# The same scenario with Review Desk ON, so the assertion above cannot pass because the stand-in
# happened to be unreachable: identical PATH, identical helper, and a non-zero count. Without
# this pair, `mode: off` and a broken `runrd` are indistinguishable -- which is how an assertion
# reading 0 passes while testing nothing. It pins the independence in the other direction too:
# the re-dispatch is the same with Review Desk on as with it off.
instance "2026-09-11T13:18:11+00:00"
desk auto
done_entry gh-r-9404 "2026-10-01T00:00:00+00:00"
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" redispatch returned)
ok "  while \`auto\` on the same PATH does call it"    "$([ "$(calls 'review requested')" -gt 0 ] && echo yes || echo no)" "yes"
ok "  and the re-dispatch is unchanged by it"        "$(grep -c '"event": "review_request",.*9404' "$work/out" || true)" "1"
ok "  and that run exits clean"                      "$rc" "0"

ok "  and the withdrawal itself was recorded"        "$(sed -n '/"phase": "gone"/p' "$work/out" | grep -c '"withdrawn": \["gh-r-9404"\]' || true)" "1"

printf '\n  and a row leaving the page WITHOUT a withdrawal is not a new request\n'
# The blocker a red team of this branch found and executed. `returned` says the row left this
# poller's PAGE, and three things do that with the request still live on GitHub: a conversion to
# draft (filtered by `skip_drafts`), a stale search index on a tick `trust_empty` believes, and a
# close that is later reopened. Each one dispatched a second session onto a finished review --
# #9404's own harm inverted. The live reason read as the row leaves is the discriminator, and the
# reversal at the bottom of this file brings all three back.
for leaving in draft index reopen; do
  instance "2026-09-11T13:18:11+00:00"
  desk off
  done_entry gh-r-9404 "2026-10-01T00:00:00+00:00"
  rc=$(run "$disp" redispatch "$leaving")
  ok "'$leaving': the return is not a new request"   "$(grep -c '"event": "review_request",.*9404' "$work/out" || true)" "0"
  ok "  nothing was recorded as withdrawn"           "$(sed -n '/"phase": "left"/p' "$work/out" | grep -c '"withdrawn": \[\]' || true)" "1"
  ok "  and nothing is marked re-dispatched"         "$(sed -n '/"phase": "back"/p' "$work/out" | grep -c '"marks": \[\]' || true)" "1"
  ok "  while the ordinary request is still offered" "$(grep -c '"event": "review_request",.*9999' "$work/out" || true)" "1"
  ok "  and the run exits clean"                     "$rc" "0"
done

printf '\n  and a request it cannot attribute is never read as answered\n'
# A red team of this branch executed this one against the FIX: the request is held by a team, so
# `still_requested` cannot attribute the list -- and for a `done` key the principal's own review
# is the latest review by definition. With the submitted-review branch ahead of the cannot-tell
# one, every one of the three Nones fell through to "you submitted a review", which IS a
# withdrawal: a live request taken off the Reviews list, and the review re-dispatched.
instance "2026-09-11T13:18:11+00:00"
desk auto
done_entry gh-r-9404 "2026-10-01T00:00:00+00:00"
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" redispatch team)
ok "a team-held request is not read as answered"     "$(grep -c 'could not tell whether it still is' "$work/out" || true)" "1"
ok "  so nothing is recorded as withdrawn"           "$(sed -n '/"phase": "left"/p' "$work/out" | grep -c '"withdrawn": \[\]' || true)" "1"
ok "  the return is not a new request"               "$(grep -c '"event": "review_request",.*9404' "$work/out" || true)" "0"
ok "  and Review Desk is told of no withdrawal"      "$(calls '--withdrawn')" "0"
ok "  while the ordinary request is still offered"   "$(grep -c '"event": "review_request",.*9999' "$work/out" || true)" "1"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  and the evidence is spent when it is read, not when the row returns\n'
# The other half of the same red team's finding: the tick a withdrawn-and-remade request comes
# back on can return early on a moved head, before the test for a new request is made. Dropping
# the record because the key is present again discards it unread.
instance "2026-09-11T13:18:11+00:00"
desk auto
done_entry gh-r-9404 "2026-10-01T00:00:00+00:00"
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" redispatch spent)
ok "a wake does not dispatch"                        "$(sed -n '/"phase": "left"/,/"phase": "back"/p' "$work/out" | grep -c '"event": "review_request",.*9404' || true)" "0"
ok "  and the withdrawal survives that tick"         "$(sed -n '/"phase": "back"/p' "$work/out" | grep -c '"withdrawn": \["gh-r-9404"\]' || true)" "1"
ok "  so the next tick dispatches it"                "$(sed -n '/"phase": "later"/p' "$work/out" | grep -c '"marks": \["gh-r-9404"\]' || true)" "1"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  and every other status is left exactly as it was\n'
instance "2026-09-11T13:18:11+00:00"
desk off
entry gh-r-9811 active s1
entry gh-r-9812 stopped s1
entry gh-r-9813 deferred s1
entry gh-r-9814 merged s1
done_entry gh-r-9815 "2026-10-01T00:00:00+00:00"
rc=$(run "$disp" redispatch statuses)
# Everything below reads the tick AFTER the requests came back, which `"phase": "back"` precedes.
back () { sed -n '/"phase": "back"/,$p' "$work/out"; }
ok "a done entry is dispatched again"                "$(back | grep -c '"event": "review_request",.*9815' || true)" "1"
ok "an active one is told, not dispatched"           "$(back | grep -c '"event": "review_rerequested".*9811' || true)" "1"
ok "  and is not dispatched"                         "$(back | grep -c '"event": "review_request",.*9811' || true)" "0"
ok "a stopped one is told, not dispatched"           "$(back | grep -c '"event": "review_rerequested".*9812' || true)" "1"
ok "  and is not dispatched either"                  "$(back | grep -c '"event": "review_request",.*9812' || true)" "0"
# DECIDED: this file defines both as "never dispatched again", and a request arriving afterwards
# is not a second opinion about that.
ok "a deferred one gets nothing"                     "$(back | grep -c '9813' || true)" "0"
ok "a merged one gets nothing"                       "$(back | grep -c '9814' || true)" "0"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  the second half of "new": the request event postdates the ledger\n'
# No withdrawal at all here -- every request is present from the first tick, so `returned` is
# false for all four and only the stamp can speak. This is the case the first half cannot see: a
# request withdrawn and made again while the poller was down carries the key straight across.
instance "2026-09-11T13:18:11+00:00"
desk off
done_entry gh-r-9801 "2026-10-13T00:00:00+00:00"
done_entry gh-r-9802 "2026-10-13T00:00:00+00:00"
done_entry gh-r-9803 "2026-10-13T00:00:00+00:00"
done_entry gh-r-9804 "2026-10-13T00:00:00+00:00"
rc=$(run "$disp" redispatch dated)
ok "an event after the ledger's update is new"       "$(grep -c '"event": "review_request",.*9801' "$work/out" || true)" "1"
ok "  and the event says the date it read"           "$(says '"new_request": "requested at 2026-10-14')" "yes"
ok "an event before it is not"                       "$(grep -c '"event": "review_request",.*9802' "$work/out" || true)" "0"
# A minute after the ledger write, which is the author pushing a fix and asking again. A guard
# band on this comparison masked it, and at the shipped 300-second poll no tick lands in the gap
# for the other test to see -- so the band reintroduced #9404 about seven times in eight.
ok "an event a minute after the ledger IS new"       "$(grep -c '"event": "review_request",.*9805' "$work/out" || true)" "1"
ok "a review requested of somebody else is not"      "$(grep -c '"event": "review_request",.*9803' "$work/out" || true)" "0"
ok "a review requested of a team is not"             "$(grep -c '"event": "review_request",.*9804' "$work/out" || true)" "0"
ok "only the new one is marked"                      "$(sed -n '/"phase": "dated"/p' "$work/out" | grep -c '"marks": \["gh-r-9801"\]' || true)" "1"
# Two ticks, one dispatch. The stamp postdates the ledger on both of them, so this is the mark
# doing the work -- `returned` is already false by the second tick.
ok "and a second tick of the same request adds none" "$(sed -n '/"phase": "dated_1"/,$p' "$work/out" | grep -c '"event": "review_request",.*9801' || true)" "0"
ok "and the run exits clean"                         "$rc" "0"

# A `gh` that cannot answer must not re-dispatch. The expensive failure is a finished review
# dispatched again; the cheap one is a new request seen on the next withdrawal instead.
instance "2026-09-11T13:18:11+00:00"
desk off
done_entry gh-r-9801 "2026-10-13T00:00:00+00:00"
rc=$(run "$disp" redispatch broken)
ok "a gh that cannot be asked re-dispatches nothing" "$(grep -c '"event": "review_request",.*9801' "$work/out" || true)" "0"
ok "  and gives up asking for the rest of the tick"  "$(says '"date_stopped": true')"      "yes"
# ...and says so. A query that fails for a reason that PERSISTS -- a scope, an enterprise host, a
# sustained rate limit -- means no request is ever recorded in Review Desk again, and the only
# symptom would be the one this ticket was opened about.
ok "  and says it could not read the date"           "$(grep -c '"event": "review_request_undated"' "$work/out" || true)" "1"
ok "  naming what went wrong"                        "$(says '"detail": "RuntimeError')"    "yes"
ok "  and the tick exits clean"                      "$rc" "0"

printf '\n  and a withdrawal stops being evidence once it is stale\n'
instance ""
rc=$(run "$disp" stale_withdrawal)
ok "a withdrawal recorded just now is evidence"      "$(says '"fresh": true')"             "yes"
ok "  one from nine months ago is not"               "$(says '"old": false')"              "yes"
ok "  an unreadable stamp is not"                    "$(says '"garbage": false')"          "yes"
ok "  a missing one is not"                          "$(says '"missing": false')"          "yes"
ok "  and neither is a record of the wrong shape"    "$(says '"not_a_dict": false')"       "yes"
ok "and it exits clean"                              "$rc" "0"

printf '\n  and the Review Desk source does not offer the same review again\n'
# `done` is ALIVE, so `request_spoken_for`'s REDISPATCHABLE test cannot see a re-dispatched key.
# The one tick a finished review is re-offered on is the tick it could be offered TWICE.
instance ""
rc=$(run "$disp" spoken_for)
ok "a done key is not spoken for by default"         "$(says '"before": false')"           "yes"
ok "a re-dispatched key is"                          "$(says '"after": true')"             "yes"
ok "whichever case the two sources spell it in"      "$(says '"mixed": true')"             "yes"
ok "and it exits clean"                              "$rc" "0"

printf '\n  and what the Dispatcher is told about it\n'
# The prose is the contract: the poller emits the event and SKILL.md is the only thing that says
# what a Dispatcher does with it. A behaviour shipped without its line here reaches nobody.
skill="$root/skills/dispatcher/SKILL.md"
ok "SKILL.md says a done key can be asked again"     "$(grep -c 'even on a key your ledger says is .done.' "$skill")" "1"
ok "  and that it is dispatched like any other"      "$(grep -c 'a second round on' "$skill")" "1"
ok "  and names the field that says why"             "$(grep -c 'new_request. field' "$skill")" "1"
ok "  and that a request that stayed is not new"     "$(grep -c 'never went away is not new' "$skill")" "1"
ok "  and which statuses are left alone"             "$(grep -c 'this does not reopen' "$skill")" "1"
ok "  that the request itself is recorded"           "$(grep -c 'review requested --repo R --pr N' "$skill")" "1"
ok "  that a failure never stops a tick"             "$(grep -c 'A failure never stops a tick' "$skill")" "1"
ok "  that a withdrawal is written on evidence"      "$(grep -c 'written on evidence, never on a row' "$skill")" "1"
ok "  and that a merge is not one"                   "$(grep -c 'merged pull request is therefore not a withdrawal' "$skill")" "1"
ok "  and names the event for an unreadable date"    "$(grep -c 'review_request_undated' "$skill")" "1"

printf '\nDEV-996 -- Review Desk is told about the request itself\n'
# The stamp the fixture gives GitHub's timeline, computed once: pinning it as a literal in the
# assertions would put the fixture's date in two places.
stamp=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,10,14,tzinfo=d.timezone.utc).timestamp()))')

instance "2026-09-11T13:18:11+00:00"
desk auto
echo ok > "$work/rd.mode"
# A session is already working 9464, so "told about every open request whatever the ledger says"
# is exercised rather than asserted in a comment. GitHub asking is a fact about GitHub.
entry gh-r-9464 active s1
rc=$(runrd "$disp" tell told)
ok "a first sighting records the request"            "$(calls "review requested --repo o/r --pr 9481 --requested-at $stamp --json")" "1"
ok "  in unix seconds, off GitHub's own clock"       "$(says '"dated_from_github": true')"  "yes"
ok "  and so is one a session is already working"    "$(calls 'review requested --repo o/r --pr 9464')" "1"
# Review Desk's first rule, and the one this file got wrong until review-desk#63 pinned the
# field: the stamp is GitHub's or there is no row. Their store is last-write-wins on (repo, pr)
# and a later timestamp resets `satisfied_by_review_id`, so a sighting time standing in for a
# request made hours earlier would report a reviewed pull request as waiting again.
ok "  while a request GitHub will not date is not"   "$(calls 'review requested --repo o/r --pr 9470')" "0"
ok "  and is not recorded as told either"            "$(sed -n '/"phase": "first"/p' "$work/out" | grep -c 'gh-r-9470' || true)" "0"
# ...and the asking for it is bounded: three ticks, one query. The bound must not touch a key
# whose Review Desk call failed, which is what "asks once a tick, not once per request" below
# pins from the other side.
ok "  and GitHub is asked for its date once"         "$(sed -n '/"phase": "asked"/p' "$work/out" | grep -c '"asked_9470": 1' || true)" "1"
ok "  while a dated one is asked once and recorded"  "$(sed -n '/"phase": "asked"/p' "$work/out" | grep -c '"asked_9481": 1' || true)" "1"
# Two ticks, two requests, two calls: the second tick must not touch `last_activity_at` on a row
# nothing has happened to, which is what every repeat call in this file is careful about.
# Three ticks and two dated requests: one call each, and no call at all for the undated one or
# for either request on the ticks after the first.
ok "later ticks record nothing again"                "$(calls 'review requested')"          "2"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  and told when GitHub stops asking\n'
instance "2026-09-11T13:18:11+00:00"
desk auto
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" tell withdrawn)
ok "a withdrawn request is withdrawn in the record"  "$(calls "review requested --repo o/r --pr 9481 --requested-at $stamp --withdrawn --json")" "1"
# GitHub goes on listing a merged pull request's review request, so nothing was withdrawn. The
# finished state is `request_closed`'s and the harvest's.
ok "a merged pull request is not a withdrawal"       "$(calls '--pr 9464 --requested-at [0-9]* --withdrawn')" "0"
ok "  and the request's record is dropped"           "$(sed -n '/"phase": "withdrawn"/p' "$work/out" | grep -c '"requests": \[\]' || true)" "1"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  a withdrawal that could not be delivered is owed, not lost\n'
# `prs_present` is overwritten every trusted tick, so the clearance sweep passes a key exactly
# once: a Review Desk that was down for that single tick would leave the request drawn for ever.
# `reemit_after_secs` of 0 is what lets one run of the driver contain the retry.
instance "2026-09-11T13:18:11+00:00"
desk auto 0
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" tell owed)
ok "a failed withdrawal is remembered as owed"       "$(says '"withdraw": true')"           "yes"
ok "  and the next tick collects it"                 "$(calls '--pr 9481 --requested-at [0-9]* --withdrawn')" "2"
ok "  and the owed record is held until it is"       "$(sed -n '/"phase": "owed"/p' "$work/out" | grep -c 'gh-r-9481' || true)" "1"
ok "  then dropped once it is delivered"             "$(sed -n '/"phase": "collected"/p' "$work/out" | grep -c 'gh-r-9481' || true)" "0"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  and told again when a NEW request appears on a row that never left\n'
# Review Desk's second rule, from the session building the verb: call it on first sight and when
# a new request appears, never once a tick. A request made while the row stayed on the page is
# that second case, and their store is last-write-wins -- so the new request has to arrive with
# ITS own stamp or a round that predates it goes on satisfying it.
instance "2026-09-11T13:18:11+00:00"
desk auto
# The ledger stamp sits BETWEEN the two request events, so tick 1 is an ordinary sighting and
# tick 2 is a new request that never left GitHub's list.
done_entry gh-r-9481 "2026-10-15T00:00:00+00:00"
echo ok > "$work/rd.mode"
t1=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,10,14,tzinfo=d.timezone.utc).timestamp()))')
t2=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,10,16,tzinfo=d.timezone.utc).timestamp()))')
rc=$(runrd "$disp" tell renew)
ok "the first sighting carries the first stamp"      "$(calls "review requested --repo o/r --pr 9481 --requested-at $t1 --json")" "1"
ok "  and dispatches nothing"                        "$(sed -n '1,/"phase": "renew_1"/p' "$work/out" | grep -c '"event": "review_request",.*9481' || true)" "0"
ok "the new request is told with ITS own stamp"      "$(calls "review requested --repo o/r --pr 9481 --requested-at $t2 --json")" "1"
ok "  and is dispatched, once"                       "$(sed -n '/"phase": "renew_1"/,$p' "$work/out" | grep -c '"event": "review_request",.*9481' || true)" "1"
ok "  and the record carries the new stamp"          "$(sed -n '/"phase": "renew_2"/p' "$work/out" | grep -c "\"at_9481\": $t2" || true)" "1"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  and one flaky `gh` does not cost the page a window\n'
# The bound on asking GitHub for a date is for an UNDATABLE request, never for a call that
# failed: `date_stopped` makes the answer None for every remaining key on the page, so marking
# on that outcome took a whole page's first recording out for a full `reemit_after_secs` after
# `gh` had recovered. Found by a red team of this branch, against the fix.
instance "2026-09-11T13:18:11+00:00"
desk auto
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" tell date_flake)
ok "a failed date read records nothing"              "$(sed -n '/"phase": "flaked"/p' "$work/out" | grep -c '"requests": \[\]' || true)" "1"
ok "  and takes no undated bound with it"            "$(sed -n '/"phase": "flaked"/p' "$work/out" | grep -c '"undated": \[\]' || true)" "1"
ok "  and says so once"                              "$(grep -c '"event": "review_request_undated"' "$work/out" || true)" "1"
ok "the very next tick records them"                 "$(sed -n '/"phase": "recovered"/p' "$work/out" | grep -c 'gh-r-9481' || true)" "1"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  and one broken store is one call, on the withdrawal path too\n'
# `tell_requested` promises one attempt per tick for the whole page. The clearance sweep did not
# honour it, so a page of clearances against a hung install was one 30-second timeout each -- and
# each burned its own retry mark. Two keys clear here; the first asks, the second takes the debt.
instance "2026-09-11T13:18:11+00:00"
desk auto
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" tell stopped_withdraw)
ok "two clearances against a broken store ask once"  "$(calls '--withdrawn')" "1"
ok "  and the other is owed, not dropped"            "$(sed -n '/"phase": "stopped"/p' "$work/out" | grep -c '"debts": \["gh-r-9464", "gh-r-9481"\]' || true)" "1"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  and a reason that could not be read is asked again, not thrown away\n'
# The red team's finding 2: `prs_present` is overwritten every trusted tick, so the clearance
# sweep passes a key exactly once. A `gh pr view` that failed on that single tick dropped the
# record -- the only address a withdrawal could be sent to -- and three clean ticks later the
# request was still drawn on the Reviews list.
instance "2026-09-11T13:18:11+00:00"
desk auto 0
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" tell unresolved)
ok "an unreadable reason keeps the record"           "$(sed -n '/"phase": "unresolved"/p' "$work/out" | grep -c '"unresolved": true' || true)" "1"
# One withdrawal across both ticks, not two: nothing was written on the strength of a call that
# did not answer, and the settle delivered exactly one once it could.
ok "  withdraws exactly once, on the later tick"     "$(calls '--pr 9481 --requested-at [0-9]* --withdrawn')" "1"
ok "  and the record is gone afterwards"             "$(sed -n '/"phase": "settled"/p' "$work/out" | grep -c 'gh-r-9481' || true)" "0"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  and a request that comes back is told again, not withdrawn\n'
instance "2026-09-11T13:18:11+00:00"
desk auto 0
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" tell owed_back)
ok "the debt is taken when the store is broken"      "$(sed -n '/"phase": "owed"/p' "$work/out" | grep -c '"withdraw": true' || true)" "1"
ok "  and the return clears it rather than paying"   "$(sed -n '/"phase": "back"/p' "$work/out" | grep -c '"withdraw"' || true)" "0"
ok "  so no withdrawal is ever delivered"            "$(calls '--pr 9481 --requested-at [0-9]* --withdrawn')" "1"
# And no second write for it: GitHub's stamp has not moved, so this is the same request Review
# Desk already holds -- it is the DEBT that was wrong, not the row. A repeat write would move
# `last_activity_at` on a row nothing happened to, which is what every call in this file avoids.
ok "  and the unchanged request needs no new write"  "$(calls 'review requested --repo o/r --pr 9481 --requested-at [0-9]* --json')" "1"
ok "and the run exits clean"                         "$rc" "0"

printf '\n  and nothing it can answer stops the tick\n'
# `review requested` does not exist yet: DEV-996 ships Review Desk first, and until it does THIS
# is the ordinary answer on every install in the world.
instance "2026-09-11T13:18:11+00:00"
desk auto
echo unknown > "$work/rd.mode"
rc=$(runrd "$disp" tell told)
ok "a build without the verb says so, once"          "$(grep -c '"call": "review requested"' "$work/out" || true)" "1"
ok "  naming what is lost by it"                     "$(says 'stays invisible on the Reviews list')" "yes"
ok "  and asks once a tick, not once per request"    "$(calls 'review requested')"          "3"
ok "  and records nothing as told"                   "$(says '"requests": \[\]')"           "yes"
ok "  and the tick exits 0, never 2"                 "$rc" "0"

instance "2026-09-11T13:18:11+00:00"
desk auto
echo refused > "$work/rd.mode"
rc=$(runrd "$disp" tell told)
ok "a refusal about one request is said once"        "$(grep -c '"state": "refused".*"call": "review requested"' "$work/out" || true)" "1"
ok "  as one example, not the extent of it"          "$(grep -c '"example": true' "$work/out" || true)" "1"
ok "  and the tick exits 0, never 2"                 "$rc" "0"

instance "2026-09-11T13:18:11+00:00"
desk auto
echo broken > "$work/rd.mode"
rc=$(runrd "$disp" tell told)
ok "an install exiting 2 is loud in every mode"      "$(grep -c '"event": "review_desk_unavailable".*"state": "broken"' "$work/out" || true)" "1"
ok "  naming the call that met it"                   "$(grep -c '"call": "review requested"' "$work/out" || true)" "1"
ok "  and asks once a tick for the whole page"       "$(calls 'review requested')"          "3"
ok "  and the tick exits 0, never 2"                 "$rc" "0"

# The timeout, which no stand-in can produce in under 30 seconds. Its DETECTION is
# `review_desk_run`'s and is pinned where that lives; what is under test here is this file's
# handling of the answer it hands back.
instance "2026-09-11T13:18:11+00:00"
desk auto
echo ok > "$work/rd.mode"
rc=$(runrd "$disp" tell timeout)
ok "a timeout is loud"                               "$(says 'did not answer in 30s')"      "yes"
ok "  and the tick exits 0, never 2"                 "$rc" "0"

# An ABSENT install is the one answer that is silent under `auto` -- an instance without Review
# Desk is owed nothing extra -- and loud under `on`. That contract is this file's oldest, and
# DEV-996's call joins it rather than reopening it. `run` is the narrowed PATH: no review-desk.
instance "2026-09-11T13:18:11+00:00"
desk auto
rc=$(run "$disp" tell told)
ok "an absent install is silent under \`auto\`"        "$(grep -c '"event": "review_desk_unavailable"' "$work/out" || true)" "0"
ok "  and still records nothing as told"             "$(says '"requests": \[\]')"           "yes"
ok "  and the tick exits clean"                      "$rc" "0"
instance "2026-09-11T13:18:11+00:00"
desk on
rc=$(run "$disp" tell told)
ok "an absent install is loud under \`on\`"            "$(grep -c '"state": "absent".*"call": "review requested"' "$work/out" || true)" "1"
ok "  and the tick exits clean"                      "$rc" "0"

# ---- the negative control: reverse the fix, and require these tests to fail ------------------
#
# Without this, every assertion above could be passing for a reason unrelated to the bug. The
# substitution is verified rather than assumed: a sed that quietly matched nothing would turn
# this test into a second copy of the one above.

printf '\nNegative control -- the pre-fix source must fail\n'

# The guard's own control: neutralise the two early returns that skip the destructive commit,
# leaving `trust_empty` itself intact, and require the DEV-799 assertions to invert.
sed -e 's/^        if not trusted:$/        if False:  # GUARD REVERSED/' \
    -e 's/^        if not self\.trust_empty("linear", len(data\["issues"\]\["nodes"\])):$/        if False:  # GUARD REVERSED/' \
    "$disp" > "$work/noguard.py"
ok "the guard reversal changed both call sites"      "$(grep -c 'GUARD REVERSED' "$work/noguard.py" || true)" "2"

# B2's own control: keep the truncation guard but drop the union commit, which is exactly the state
# that shipped at 0e9e536, and require the repetition to come back.
sed 's/^            if matched and nodes:$/            if False:  # UNION REVERSED/' \
    "$disp" > "$work/nounion.py"
ok "the union reversal changed one line"             "$(grep -c 'UNION REVERSED' "$work/nounion.py" || true)" "1"
instance "2026-09-11T13:18:11+00:00"
entry gh-r-9400 active s2
entry gh-r-9450 skipped
entry gh-r-9451 active s2
rc=$(run "$work/nounion.py" truncated)
ok "no union: the skipped PR is re-offered thrice"   "$(grep -c '"rerequested": true' "$work/out" || true)" "3"
ok "no union: prs_present stays frozen at 50"        "$(says '"phase": "trunc4", "present": 50')" "yes"
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$work/nounion.py" trunc_runs)
ok "no union: the backlog grows a page per run"      "$(says '"stable": false')"           "yes"

instance "2026-09-11T13:18:11+00:00"
entry gh-r-9481 skipped
entry gh-r-9464 active s2
rc=$(run "$work/noguard.py" empty_guard)
ok "no guard: an empty search clears a live review"  "$(grep -c '"event": "review_cleared"' "$work/out" || true)" "1"
ok "no guard: prs_present is wiped"                  "$(sed -n '/after_empty/p' "$work/out" | grep -c 'gh-r-9481' || true)" "0"
ok "no guard: the skipped PR is resurrected"         "$(grep -c '"rerequested": true' "$work/out" || true)" "1"
ok "no guard: a false review_rerequested fires"      "$(grep -c '"event": "review_rerequested"' "$work/out" || true)" "1"
ok "no guard: the start-up item loses its flag"      "$(sed -n '/after_recovery/p' "$work/out" | grep -c 'gh-r-9435' || true)" "0"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$work/noguard.py" two_zeroes)
ok "no guard: one zero sweeps the trigger markers"   "$(sed -n '/zero_1/p' "$work/out" | grep -c 'ZZ-1|trigger' || true)" "0"

# DEV-959's own control: make `search_pr_closed` answer False for everything, leaving the rest of
# the pass intact, and require the merged row to be recorded and offered again.
sed 's/^    return isinstance(state, str) and state\.lower() in PR_CLOSED$/    return False  # STATE CHECK REVERSED/' \
    "$disp" > "$work/nostate.py"
ok "the state reversal changed one line"             "$(grep -c 'STATE CHECK REVERSED' "$work/nostate.py" || true)" "1"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$work/nostate.py" pr_state_rows)
ok "no state check: a merged row IS recorded"        "$(sed -n '/"phase": "recorded"/p' "$work/out" | grep -c 'gh-r-9602' || true)" "1"
ok "no state check: a merged row IS offered"         "$(grep -c '"event": "review_request".*9602' "$work/out" || true)" "1"

instance "2026-09-11T13:18:11+00:00"
entry gh-r-9602 active s9
entry gh-r-9606 active s9
rc=$(run "$work/nostate.py" merged_rerequest)
ok "no state check: a merged row IS re-requested"    "$(grep -c '"event": "review_rerequested".*9602' "$work/out" || true)" "1"

# The OTHER half of DEV-959's poller change, which `nostate.py` cannot isolate: keep the guard
# but put the merged key back in `present`, which is how the first version of this shipped. The
# clearance sweep then skips it, so the Dispatcher is told about the merge only when the search
# index drops the row -- never, under a `review_query` with no `is:open`.
python3 - "$disp" "$work/keptpresent.py" <<'PYREVERSAL'
import sys
src = open(sys.argv[1]).read()
old = """                                    ledger.get(key) or {}, every)
                continue"""
new = """                                    ledger.get(key) or {}, every)
                present[key] = {"repo": repo, "number": pr["number"]}  # PRESENT REVERSED
                continue"""
assert old in src, "reversal anchor missing from the source under test"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYREVERSAL
ok "the present reversal changed one line"           "$(grep -c '# PRESENT REVERSED' "$work/keptpresent.py" || true)" "1"

instance "2026-09-11T13:18:11+00:00"
entry gh-r-9621 active s1
entry gh-r-9622 active s1
rc=$(run "$work/keptpresent.py" merged_clears)
ok "kept in present: the merged key never leaves"    "$(sed -n '/"phase": "two"/p' "$work/out" | grep -c 'gh-r-9621' || true)" "1"
ok "kept in present: the sweep says nothing"         "$(grep -c '"event": "review_cleared"' "$work/out" || true)" "0"

# DEV-959's amendment has two halves and each needs its own control. First: delete the test that
# keeps the carve-out to a pull request Review Desk holds NOTHING for, and a held review is
# written to -- which on a review that exists is the next round, on a pull request that shipped.
python3 - "$disp" "$work/anyreview.py" <<'PYCARVE'
import sys
src = open(sys.argv[1]).read()
old = """        if found is None and not self.record_stopped and not self.look_stopped:"""
new = """        if True:  # CARVE-OUT REVERSED"""
assert old in src, "carve-out anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYCARVE
ok "the carve-out reversal changed one line"          "$(grep -c 'CARVE-OUT REVERSED' "$work/anyreview.py" || true)" "1"
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$work/anyreview.py" closed_held)
ok "no carve-out: a held review IS written to"       "$(sed -n '/"phase": "opened"/p' "$work/out" | grep -c 'gh-r-9631' || true)" "1"

# Second: delete the carve-out entirely, which is the commit before the amendment, and the row
# DEV-945 exists to produce goes missing.
python3 - "$disp" "$work/noreview.py" <<'PYNOREC'
import sys
src = open(sys.argv[1]).read()
old = """        rid = self.record_if_never_reviewed(rd, recording, key, repo, pr, every)"""
new = """        rid = None  # CARVE-OUT REMOVED"""
assert old in src, "recording call anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYNOREC
ok "the no-recording reversal changed one line"       "$(grep -c 'CARVE-OUT REMOVED' "$work/noreview.py" || true)" "1"
instance "2026-09-11T13:18:11+00:00"
rc=$(run "$work/noreview.py" pr_state_rows)
ok "no carve-out: the never-reviewed row is lost"     "$(sed -n '/"phase": "opened"/p' "$work/out" | grep -c 'gh-r-9602' || true)" "0"
ok "  and the event carries no review either"         "$(grep -c '"event": "review_request_closed".*9602.*"review_desk_id": null' "$work/out" || true)" "1"

# DEV-996's four controls. Each one is the state of this file before a specific line of the
# commit, and each must invert a specific assertion above -- not merely fail somewhere.

# 1. No test for a new request at all, which is #9404 exactly: `done` is ALIVE, so a returned
#    request falls into `review_rerequested` and is relayed to a session that no longer exists.
python3 - "$disp" "$work/nonew.py" <<'PYNONEW'
import sys
src = open(sys.argv[1]).read()
old = '            new = self.new_request(cfg, key, repo, pr["number"], entry)'
new = '            new = None  # NEW REQUEST REVERSED'
assert old in src, "new_request call anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYNONEW
ok "the new-request reversal changed one line"       "$(grep -c 'NEW REQUEST REVERSED' "$work/nonew.py" || true)" "1"
instance "2026-09-11T13:18:11+00:00"
desk off
done_entry gh-r-9404 "2026-10-01T00:00:00+00:00"
rc=$(run "$work/nonew.py" redispatch returned)
ok "no new-request test: the done entry is not dispatched" "$(grep -c '"event": "review_request",.*9404' "$work/out" || true)" "0"
ok "  and the re-request is relayed to a dead session"     "$(grep -c '"event": "review_rerequested".*9404' "$work/out" || true)" "1"

# 2. The test, without the mark that makes it fire once. The fifth tick re-offers the same
#    request, and nothing downstream can tell that from a second asking.
python3 - "$disp" "$work/nomark.py" <<'PYNOMARK'
import sys
src = open(sys.argv[1]).read()
old = '                self.state["redispatched"][key] = {"at": now_iso(), "why": new}'
new = '                pass  # MARK REVERSED'
assert old in src, "redispatch mark anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYNOMARK
ok "the mark reversal changed one line"              "$(grep -c 'MARK REVERSED' "$work/nomark.py" || true)" "1"
instance "2026-09-11T13:18:11+00:00"
desk off
# Driven on the DATED half, because that is the one that can repeat: a stamp that postdates the
# ledger goes on postdating it, where `returned` is false on the very next tick.
done_entry gh-r-9801 "2026-10-13T00:00:00+00:00"
rc=$(run "$work/nomark.py" redispatch dated)
ok "no mark: the same request dispatches twice"      "$(grep -c '"event": "review_request",.*9801' "$work/out" || true)" "2"

# 3. The withdrawal fired on the key leaving the list rather than on the live reason. A merged
#    pull request's request is still listed by GitHub, so this writes a withdrawal that did not
#    happen -- and `request_closed` and the harvest own that row.
python3 - "$disp" "$work/anyclear.py" <<'PYANY'
import sys
src = open(sys.argv[1]).read()
old = '''        if reason.startswith(WITHDRAWN_WHY):
            self.withdraw_request(rd, key, where, every)
            return'''
new = '''        if True:  # WITHDRAWN REASON REVERSED
            self.withdraw_request(rd, key, where, every)
            return'''
assert old in src, "withdrawal reason anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYANY
ok "the reason reversal changed one line"            "$(grep -c 'WITHDRAWN REASON REVERSED' "$work/anyclear.py" || true)" "1"
instance "2026-09-11T13:18:11+00:00"
desk auto
echo ok > "$work/rd.mode"
rc=$(runrd "$work/anyclear.py" tell withdrawn)
ok "any reason: the merged PR is withdrawn too"      "$(calls '--pr 9464 --requested-at [0-9]* --withdrawn')" "1"

# 4. THE BLOCKER's control: the first test of "new" reading the row's absence rather than the
#    recorded withdrawal, which is how this branch shipped to its first review. A draft toggle
#    then dispatches a second session onto a finished review.
# Reversed at the RECORDING rather than at the test, because that is the line the fix is: drop
# the reason check and every row that leaves the page records a withdrawal, which is what
# `returned` amounted to before it. The status condition stays, so only a `done` key is affected.
python3 - "$disp" "$work/anyreturn.py" <<'PYANYRET'
import sys
src = open(sys.argv[1]).read()
old = """                if reason.startswith(WITHDRAWN_WHY) \\
                        and entry.get("status") in REDISPATCH_ON_REQUEST:"""
new = """                if entry.get("status") in REDISPATCH_ON_REQUEST:  # REASON IGNORED"""
assert old in src, "withdrawal record anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYANYRET
ok "the withdrawal-record reversal changed one line" "$(grep -c '# REASON IGNORED' "$work/anyreturn.py" || true)" "1"
for leaving in draft index reopen; do
  instance "2026-09-11T13:18:11+00:00"
  desk off
  done_entry gh-r-9404 "2026-10-01T00:00:00+00:00"
  rc=$(run "$work/anyreturn.py" redispatch "$leaving")
  ok "no record: '$leaving' re-dispatches a finished review" "$(grep -c '"event": "review_request",.*9404' "$work/out" || true)" "1"
done

# 5. Without the fifth shape, the Review Desk source speaks for a key the GitHub pass has
#    dispatched -- two events for one request, which is two sessions on one review.
python3 - "$disp" "$work/noshape5.py" <<'PYNOSHAPE'
import sys
src = open(sys.argv[1]).read()
old = """        if self.redispatched_mark(key):
            return True"""
new = """        if False:  # SHAPE 5 REVERSED
            return True"""
assert old in src, "shape 5 anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYNOSHAPE
ok "the shape-5 reversal changed one line"           "$(grep -c 'SHAPE 5 REVERSED' "$work/noshape5.py" || true)" "1"
instance ""
rc=$(run "$work/noshape5.py" spoken_for)
ok "no shape 5: the re-dispatched key is offered again" "$(says '"after": false')"          "yes"

sed 's/^        self\.first_tick = True$/        self.first_tick = not self.state.get("started")/' \
    "$disp" > "$work/prefix.py"
ok "the reversal actually changed the source"        "$(grep -c 'self.first_tick = not self.state.get("started")' "$work/prefix.py" || true)" "1"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$work/prefix.py" first_tick)
ok "pre-fix: a persisted \`started\` kills first_tick"  "$(says '"first_tick": false')"      "yes"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$work/prefix.py" one_tick)
# Not "no poller_started": since S9 that event fires per process regardless of the backlog policy,
# so it is no longer evidence of this contract. The flags below are.
ok "pre-fix: the start reports backlog suppressed"   "$(says '"backlog_suppressed": true')" "yes"
ok "pre-fix: all ten arrive flagged backlog false"   "$(flagged false)"                    "10"
ok "pre-fix: not one is flagged backlog true"        "$(flagged true)"                     "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
