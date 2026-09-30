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
events () { grep -c "\"event\":" "$work/out" || true; }
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
ok "1200 records of ~470 bytes stay under the cap"     "$(says '"under_cap": true')"         "yes"
ok "the log was actually trimmed"                    "$(says '"trimmed": true')"           "yes"
ok "every surviving record still parses"             "$(says '"all_parse": true')"         "yes"
ok "the bound keeps the newest, not the oldest"      "$(says '"newest_kept": true')"       "yes"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$disp" status)
ok "\`status\` reports the last poller error"          "$(says 'last poller error: review_requests')" "yes"

# ---- the negative control: reverse the fix, and require these tests to fail ------------------
#
# Without this, every assertion above could be passing for a reason unrelated to the bug. The
# substitution is verified rather than assumed: a sed that quietly matched nothing would turn
# this test into a second copy of the one above.

printf '\nNegative control -- the pre-fix source must fail\n'

sed 's/^        self\.first_tick = True$/        self.first_tick = not self.state.get("started")/' \
    "$disp" > "$work/prefix.py"
ok "the reversal actually changed the source"        "$(grep -c 'self.first_tick = not self.state.get("started")' "$work/prefix.py" || true)" "1"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$work/prefix.py" first_tick)
ok "pre-fix: a persisted \`started\` kills first_tick"  "$(says '"first_tick": false')"      "yes"

instance "2026-09-11T13:18:11+00:00"
rc=$(run "$work/prefix.py" one_tick)
ok "pre-fix: no poller_started at all"               "$(grep -c '"event": "poller_started"' "$work/out" || true)" "0"
ok "pre-fix: all ten arrive flagged backlog false"   "$(flagged false)"                    "10"
ok "pre-fix: not one is flagged backlog true"        "$(flagged true)"                     "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
