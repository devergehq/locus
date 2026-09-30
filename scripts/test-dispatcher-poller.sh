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
# What is pinned: that `first_tick` survives a persisted `started`, that the 30 Sep conditions
# surface all ten review requests as backlog, that the flag drops on a later tick of the same
# process, that `started` is not deleted, that a thrown section reaches stderr and a runtime
# file rather than only stdout, that the file is bounded, and that `status` reports it.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
disp="$root/skills/dispatcher/dispatcher.py"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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

cat > "$work/driver.py" <<'EOF'
"""Exercise one Poller scenario against the dispatcher source named in $DISP."""
import importlib.util, json, os, sys, time

spec = importlib.util.spec_from_file_location("disp_under_test", os.environ["DISP"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
os.environ["DISPATCHER_INSTANCE"] = os.environ["INST"]

# Ten open review requests: the 30 Sep conditions, by number.
PRS = [{"number": n, "title": f"PR {n}", "url": f"https://github.com/o/r/pull/{n}",
        "isDraft": False, "headRefOid": f"sha{n}", "createdAt": "2026-09-24T00:00:00Z",
        "author": {"login": "someone"}, "repository": {"nameWithOwner": "o/r"}}
       for n in (9481, 9464, 9435, 9432, 9431, 9430, 9429, 9428, 9426, 9394)]

def offline(review_nodes=PRS, gh_raises=None):
    """No network: `linear` and `gh` are module globals, so replacing them is enough."""
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({}, set())
    def fake_gh(*args):
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
            return {"state": "OPEN", "latestReviews": []}
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

elif scenario == "status_sources":
    m.linear = lambda cfg, q, v=None: {"issues": {"nodes": []}}
    m.allele_state = lambda cfg: ({}, set())
    m.gh = lambda *a: {"data": {"search": {"issueCount": 2, "nodes": PRS[:2]}}}
    m.Poller().tick()
    class A: all = False
    m.cmd_status(A())

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
