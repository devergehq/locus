#!/bin/sh
# Unit tests for the Review Desk half of skills/dispatcher/dispatcher.py (DEV-865).
#
# Three things are stood in for, and nothing else is:
#
#   review-desk  a shell script on PATH that answers from a recorded document and a mode file.
#                Since DEV-945 one of its commands is a small STORE rather than a recorded
#                answer -- `review open`, whose whole behaviour is what a second call does --
#                and the run at the bottom of this file drives the real binary instead.
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
# A temporary database, before anything in this file can run a review-desk command. The
# stand-in ignores it and the real binary at the bottom of this file needs it, and between
# those two there is one case this line exists for: a real `review-desk` that reaches PATH by
# some route $MINPATH did not anticipate would otherwise open the live store under
# `~/.review-desk` -- and since DEV-945 the poller WRITES to it, which is how review 13 got
# into Patrick's real database in the first place.
export REVIEW_DESK_DB="$work/test.db"
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
  # `review` keeps the nit ticket's state, because what is under test is a LOOP: the developer's
  # request is on the work list, the session reports what it filed, and the request leaves the
  # list. A recorded document cannot answer the second half of that.
  review) exec python3 "$RDWORK/rd_review.py" "$@" ;;
  # `harvest` and `draft show` answer from their own files, and from their own mode files, so a
  # harvest can fail while `work list` answers. A WHOLE install that is broken or absent is
  # $RDWORK/rd.mode above, and still governs both of these.
  harvest)
    case "$(cat "$RDWORK/rd.harvest.mode" 2>/dev/null || echo ok)" in
      broken) echo '{"error":{"code":"gh_unreachable","message":"scripted harvest failure"}}'
              exit 2 ;;
      refused) echo '{"error":{"code":"not_found","message":"no such repository"}}'; exit 1 ;;
      slow) sleep 3; echo '{"harvest":{"reviews":[]}}'; exit 0 ;;
    esac
    cat "$RDWORK/rd.harvest" 2>/dev/null || echo '{"harvest":{"reviews":[]}}'
    exit 0 ;;
  draft)
    case "$(cat "$RDWORK/rd.draft.mode" 2>/dev/null || echo ok)" in
      broken) echo '{"error":{"code":"cannot_open_database","message":"scripted"}}'; exit 2 ;;
      # The ordinary answer for most of a review's life: `draft show` before `draft put`.
      nodraft) echo '{"error":{"code":"not_found","message":"no draft for review 7"}}'; exit 1 ;;
    esac
    printf '{"draft":{"review_id":7,"status":"%s","event":"APPROVE","approved_at":1791520400,' \
      "$(cat "$RDWORK/rd.draft.status" 2>/dev/null || echo drafting)"
    printf '"body":"the approved body","lint":{}}}\n'
    exit 0 ;;
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
# A PART's own members, read off master's `BriefPart`, which carries `deny_unknown_fields`:
# `title`, `summary`, `fixes`, `files`. `one_line` is DEV-919's and is in flight, so both sides
# of it are kept here -- a worker has to write against an install either side, and the refusal
# for the field is itself the behaviour under test. `$RDWORK/rd.parts` holding `pre919` is an
# install from before the field; anything else, including the file's absence, is one with it.
#
# A LIST and not a set, in DECLARATION order, because serde names the members in the order the
# struct declares them and the order is the half of the message a worker reads past. Measured
# 11 October 2026 against a binary built from DEV-919 at cc85cf0, which prints
# `expected one of `title`, `summary`, `one_line`, `fixes`, `files``. A sorted stand-in would
# have pinned an order nothing ever prints.
PART_ACCEPTED = ["title", "summary", "fixes", "files"]
PART_WITH_ONE_LINE = ["title", "summary", "one_line", "fixes", "files"]
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

    pre919 = (work / "rd.parts").read_text().strip() == "pre919" \
        if (work / "rd.parts").exists() else False
    members = PART_ACCEPTED if pre919 else PART_WITH_ONE_LINE
    for part in doc.get("parts", []):
        unknown = [key for key in part if key not in members]
        if unknown:
            # The nested shape of the refusal: the object's OWN members named, in the order the
            # struct declares them, which is what `workers/review.md` tells a worker to read it
            # for.
            refuse("cannot use the JSON: unknown field `%s`, expected one of %s"
                   % (unknown[0], ", ".join("`%s`" % m for m in members)))
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

# ---- the stand-in's review -----------------------------------------------------------------
# The nit ticket, which is a LOOP rather than an answer: the developer's request is on the work
# list, the session reports the ticket it filed, and the request leaves the list. Review Desk is
# level-triggered and derives `nits_to_ticket` from `nit_ticket_status == requested`
# (`crates/store/src/entities/work.rs`), so reporting a filing has to remove the item here too —
# a stand-in whose list never cleared would let a dispatcher that re-dispatched for ever pass.
#
# Read off review-desk at 2656e54:
#
#   review nit-ticket --review N --ticket X   records a filing. `--ticket` is REQUIRED and there
#                                             is no form that asks for a ticket: clap refuses a
#                                             missing one, which Review Desk remaps to exit 1.
#                                             An empty one is `InvalidValue`, also exit 1.
#   review show --review N --json             the whole review, including the four nit-ticket
#                                             columns on `review` and `findings[].disposition`,
#                                             which is where the held-back findings are. There is
#                                             NO `finding list` subcommand in 0.1.0, which is why
#                                             `workers/review.md` must not name one.

cat > "$work/rd_review.py" <<'RDREVIEW'
import json, os, pathlib, sys

work = pathlib.Path(os.environ["RDWORK"])
nit = work / "rd.nit"


def refuse(code, message, status=1):
    print(json.dumps({"error": {"code": code, "message": message}}))
    sys.exit(status)


def opt(argv, flag):
    return argv[argv.index(flag) + 1] if flag in argv and len(argv) > argv.index(flag) + 1 else None


def state():
    if nit.exists():
        return json.loads(nit.read_text())
    return {"status": "none", "ticket_id": None}


def held_back():
    path = work / "rd.held"
    return json.loads(path.read_text()) if path.exists() else []


def document(review):
    held = held_back()
    current = state()
    doc = {"id": int(review), "repo": "acme/portal", "pr": 412, "head_sha": "3f9c2ab",
           "round": 1, "title": "Retry failed webhook deliveries", "ticket_id": "ABC-231",
           "dismissed_at": None, "dismissed_reason": None, "session_id": None,
           "nit_ticket_status": current["status"], "nit_ticket_id": current["ticket_id"]}
    # A review this stand-in has OPENED answers from that store instead, for the three fields a
    # reader of `review show` acts on: the commit it is of, and whether the developer dismissed
    # it. A hardcoded `head_sha` here would tell the poller its recorded commit had changed and
    # send it back to `review open` every tick. Reviews the opens store has never heard of keep
    # the fixed document above, which is what the nit-ticket assertions were written against.
    for slot, held_open in opened().items():
        if held_open["id"] != int(review):
            continue
        repo, pr = slot.split("#")
        doc.update({"repo": repo, "pr": int(pr), "head_sha": held_open["head"],
                    "round": held_open["round"], "session_id": held_open.get("session"),
                    "dismissed_at": held_open.get("dismissed_at"),
                    "dismissed_reason": held_open.get("dismissed_reason")})
    return {"review": doc, "findings": held}


def opened():
    path = work / "rd.opens.json"
    return json.loads(path.read_text()) if path.exists() else {}


def open_review(argv):
    """`review open`, as review-desk 0e0bf1b answers it. DEV-945.

    Every rule here was read off a binary built from that commit and run against a temporary
    database, not off its prose:

      the same head again      one review, `created` false, no round spent
      a new head, unstarted    the review MOVES, `head_moved_from` naming the commit before
      a new head, session on it a NEW ROUND: `created` true, round + 1, no `head_moved_from`
      `--ledger`               written on the review, and the SECOND call with it writes again

    The round rule was re-measured at review-desk 2180224, where a linked session is what makes
    a request "started": `review link --session` then `review open` on a new commit answers
    `created: true` and round 2, and `work list` offers that round as a request of its own. A
    brief or a finding makes a round started too, and this stand-in does not model those: the
    poller cannot write either one, so nothing here could exercise them, and the run against the
    real binary at the bottom of this file is what reads the store's own judgement.

    `$RDWORK/rd.open.mode` is this ONE command's health, so an older or refusing `review open`
    can be driven while `work list` still answers. A whole install that is absent or broken is
    `$RDWORK/rd.mode` and governs this command too, from the stand-in above.
    """
    # One argument per line, which is the only way an assertion can tell a title that arrived
    # whole from one the shell split in two. `rd.calls` holds `"$*"`, and `$*` cannot say.
    (work / "rd.open.argv").write_text("\n".join(argv) + "\n")
    mode = (work / "rd.open.mode").read_text().strip() \
        if (work / "rd.open.mode").exists() else "ok"
    ledger = opt(argv, "--ledger")
    if mode == "oldledger" and ledger is not None:
        # An older Review Desk: `review open` is there and `--ledger` is not. clap's own usage
        # error, which review-desk's `main.rs` remaps from 2 to 1 and gives the code `usage`.
        refuse("usage", "error: unexpected argument '--ledger' found\n\nUsage: review-desk "
                        "review open --repo <OWNER/REPO> --pr <N> --head <SHA>")
    if mode == "broken":
        refuse("cannot_open_database", "scripted broken review open", 2)
    if mode == "notobject":
        # Exit 0 with JSON that PARSES and is not an object: a wrapper script, or a build that
        # prints a list. `review_desk_run` hands back whatever parses, so this is the shape that
        # turns a `.get` into an AttributeError in the middle of a poll tick.
        print("[]")
        raise SystemExit(0)
    if mode == "refused":
        # A refusal that is NOT about an argument this build has never heard of, so nothing may
        # retry it. Its message names the pull request, as a real one would -- which is what
        # makes "one voice per repository" a testable claim rather than an accident of two
        # requests sharing a sentence.
        refuse("not_found", "no repository acme/portal for pull request %s"
               % (opt(argv, "--pr") or "?"))
    repo, pr, head = opt(argv, "--repo"), opt(argv, "--pr"), opt(argv, "--head")
    if not repo or not pr or not head:
        refuse("usage", "the following required arguments were not provided: --repo --pr --head")
    # NORMALISED, as the real store does: `normalise::head_sha` trims and lower-cases, and
    # `normalise::repo` does the same to the slug. It matters to the caller rather than to the
    # record -- a dispatcher that remembered this echo and compared it with GitHub's own
    # spelling would read any difference as "the commit moved", every tick, for ever.
    repo, head = repo.strip().lower(), head.strip().lower()
    store = opened()
    slot = "%s#%s" % (repo, pr)
    held = store.get(slot)
    if held is None:
        held = {"id": len(store) + 1, "head": head, "ledger": ledger, "round": 1}
        created, moved = True, None
    elif held["head"] == head:
        created, moved = False, None
        if ledger is not None:
            held["ledger"] = ledger
    elif held.get("session"):
        # Started: the next round, with an id of its own and no session on it.
        held = {"id": max(h["id"] for h in store.values()) + 1, "head": head, "ledger": ledger,
                "round": held["round"] + 1}
        created, moved = True, None
    else:
        created, moved = False, held["head"]
        held["head"] = head
        if ledger is not None:
            held["ledger"] = ledger
    store[slot] = held
    (work / "rd.opens.json").write_text(json.dumps(store))
    review = {"id": held["id"], "repo": repo, "pr": int(pr), "head_sha": head,
              "round": held["round"], "title": opt(argv, "--title"),
              "ticket_id": opt(argv, "--ticket"), "ledger_id": held["ledger"],
              "session_id": held.get("session"),
              # On every one of the three paths -- created, found and moved -- as review-desk
              # 5dae8f6 answers. A push on a dismissed request moves its head and leaves it
              # dismissed, because a push is not the developer changing their mind.
              "dismissed_at": held.get("dismissed_at"),
              "dismissed_reason": held.get("dismissed_reason")}
    print(json.dumps({"review": review, "created": created, "head_moved_from": moved,
                      "carryable": None}))
    raise SystemExit(0)


argv = sys.argv[1:]
if argv[:2] == ["review", "open"]:
    open_review(argv)

review = opt(argv, "--review")
if review is None:
    refuse("missing_argument", "--review is required")

if argv[:2] == ["review", "nit-ticket"]:
    ticket = opt(argv, "--ticket")
    if ticket is None:
        # clap's own missing-required-argument, which Review Desk's README remaps to 1.
        refuse("usage", "the following required arguments were not provided: --ticket")
    if not ticket.strip():
        refuse("invalid_value", "nit_ticket_id: expected the id of the ticket the nits were "
                                "filed as")
    nit.write_text(json.dumps({"status": "filed", "ticket_id": ticket.strip()}))
    # Level-triggered, as above: the request is gone from the list the moment it is answered.
    doc = work / "rd.work"
    if doc.exists():
        payload = json.loads(doc.read_text())
        payload["work"] = [i for i in payload.get("work", []) if i.get("kind") != "nits_to_ticket"]
        doc.write_text(json.dumps(payload))
    seqs = [f["seq"] for f in held_back()]
    print(json.dumps({"nit_ticket": {"review_id": int(review), "status": "filed",
                                     "ticket_id": ticket.strip(), "finding_seqs": seqs,
                                     "requested_at": 1791520400, "filed_at": 1791520500}}))
elif argv[:2] == ["review", "show"]:
    # Its own health, so a `review show` that refuses can be driven while `review open` still
    # answers. `refused` is a review that is GONE -- the developer deleted one that never
    # started, which is the only delete Review Desk allows.
    show = (work / "rd.show.mode").read_text().strip() \
        if (work / "rd.show.mode").exists() else "ok"
    if show == "broken":
        refuse("cannot_open_database", "scripted broken review show", 2)
    if show == "refused":
        refuse("not_found", "no review with id %s" % review)
    if show == "oldshow":
        # A build that has never heard of `review show`: clap's own refusal, code `usage`, which
        # is a different fact from a review that is gone.
        refuse("usage", "error: unrecognized subcommand 'show'")
    print(json.dumps(document(review)))
else:
    # Loud, not null: a call site this stand-in has never seen must not pass by being answered.
    print("stand-in review: unhandled call: %s" % " ".join(argv), file=sys.stderr)
    sys.exit(2)
RDREVIEW

# ---- the stand-in gh ------------------------------------------------------------------------
# One case per call dispatcher.py actually makes. An unrecognised call exits 1 loudly rather
# than echoing null, so a new call site cannot pass these tests by being silently answered.

cat > "$work/bin/gh" <<'GHSTANDIN'
#!/bin/sh
printf '%s\n' "$*" >> "$RDWORK/gh.calls"
case "$*" in
  *"api graphql"*)
    # A page of review requests, from a document when one has been written and an empty page
    # otherwise. Empty is the default on purpose: every assertion in this file that predates
    # DEV-945 was written against a dispatcher whose GitHub source said nothing, and a page of
    # rows appearing under them would change what they are testing.
    cat "$RDWORK/gh.search" 2>/dev/null || echo '{"data":{"search":{"issueCount":0,"nodes":[]}}}'
    exit 0 ;;
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

# $NOMAP=1 leaves `allele.repo_project_map` EMPTY, which with an empty ledger is the instance
# `review_desk_repos` answers nothing for -- the one where the reading pass probes nothing and
# so reports nothing. DEV-945's recording path still runs on it, which is why it has a test.
instance () {
  rm -rf "$inst"; mkdir -p "$inst/runtime/ledger" "$inst/runtime/watch"
  python3 - "$inst/config.json" "$work/allele.json" "${1:-}" "${2:-}" <<'PY'
import json, os, sys, pathlib
dest, state, block, review = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
cfg = {
  "linear": {"api_key_env": "TEST_NO_SUCH_TOKEN", "mcp_workspace": "ws", "team_key": "ZZ",
             "label_group_id": "g",
             "labels": {"todo": {"id": "L-todo", "name": "Agent - Todo"}},
             "modes": {"implement": {"trigger": "todo", "working": "todo"}}},
  "github": {"login": "devdeveloper", "review_query": "is:pr is:open", "skip_drafts": True},
  "allele": {"state_file": state, "default_project": "p",
             "repo_project_map": {} if os.environ.get("NOMAP") else {"acme/portal": "portal"}},
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
  rm -f "$work/rd.parts"
  rm -f "$work/rd.harvest" "$work/rd.harvest.mode" "$work/rd.draft.mode"
  rm -f "$work/rd.nit" "$work/rd.held"
  # DEV-945's three: the recorded reviews, how `review open` answers, and what GitHub shows.
  rm -f "$work/rd.opens.json" "$work/rd.open.mode" "$work/rd.open.argv" "$work/gh.search"
  rm -f "$work/rd.show.mode"
  unset NOMAP 2>/dev/null || true
  echo drafting > "$work/rd.draft.status"
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

# search_doc <repo> <pr> <head> [title] [draft]: the page of review requests GitHub answers
# with. One row, because what is under test is what the poller does with a request rather than
# how it pages. `title` of `-` is a row with no title at all, which `review open` must then not
# be given a `--title` for.
search_doc () {
  python3 - "$work/gh.search" "$@" <<'PY'
import json, sys, pathlib
dest = pathlib.Path(sys.argv[1])
repo, pr, head = sys.argv[2], int(sys.argv[3]), sys.argv[4]
title = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else "Retry failed webhook deliveries"
draft = len(sys.argv) > 6 and sys.argv[6] == "draft"
node = {"number": pr, "title": None if title == "-" else title,
        "url": "https://github.com/%s/pull/%d" % (repo, pr), "isDraft": draft,
        "headRefOid": head, "createdAt": "2026-10-01T00:00:00Z",
        "author": {"login": "someone"}, "repository": {"nameWithOwner": repo}}
dest.write_text(json.dumps({"data": {"search": {"issueCount": 1, "nodes": [node]}}}))
PY
}

# search_pair <repo> <pr1> <head1> <pr2> <head2>: two rows on one page, for the assertions
# about what ONE install answering badly costs the rest of the page.
search_pair () {
  python3 - "$work/gh.search" "$@" <<'PY'
import json, sys, pathlib
dest = pathlib.Path(sys.argv[1])
repo = sys.argv[2]
rows = [(int(sys.argv[3]), sys.argv[4]), (int(sys.argv[5]), sys.argv[6])]
nodes = [{"number": pr, "title": "Retry", "url": "https://github.com/%s/pull/%d" % (repo, pr),
          "isDraft": False, "headRefOid": head, "createdAt": "2026-10-01T00:00:00Z",
          "author": {"login": "someone"}, "repository": {"nameWithOwner": repo}}
         for pr, head in rows]
dest.write_text(json.dumps({"data": {"search": {"issueCount": len(nodes), "nodes": nodes}}}))
PY
}

# Every `review open` the stand-in was asked for, one per line, and the whole argv of the last
# one. `rd.calls` is the record; these two are how an assertion reads it.
opens () { grep -c '^review open ' "$work/rd.calls" 2>/dev/null || true; }
last_open () { grep '^review open ' "$work/rd.calls" | tail -1; }
shows () { grep -c '^review show ' "$work/rd.calls" 2>/dev/null || true; }

# dismiss <repo> <pr> <reason> / restore <repo> <pr>: the developer's act, which has no command
# line in Review Desk at all -- it is the dashboard's API -- so a test performs it on the
# stand-in's store directly. That absence IS the guarantee the dispatcher cannot do this.
dismiss () {
  python3 - "$work/rd.opens.json" "$@" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
store = json.loads(path.read_text())
held = store["%s#%s" % (sys.argv[2], sys.argv[3])]
held["dismissed_at"] = 1791780000
held["dismissed_reason"] = sys.argv[4] if len(sys.argv) > 4 else "the pull request was closed"
path.write_text(json.dumps(store))
PY
}
restore () {
  python3 - "$work/rd.opens.json" "$@" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
store = json.loads(path.read_text())
held = store["%s#%s" % (sys.argv[2], sys.argv[3])]
held["dismissed_at"] = None
held["dismissed_reason"] = None
path.write_text(json.dumps(store))
PY
}

# link <repo> <pr> <session>: what a review WORKER does when it starts -- `review link
# --session`. The dispatcher has no business calling it, which is the point: after it, a push
# makes the next round rather than moving the request, and the poller must stop writing.
link () {
  python3 - "$work/rd.opens.json" "$@" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
store = json.loads(path.read_text())
store["%s#%s" % (sys.argv[2], sys.argv[3])]["session"] = sys.argv[4]
path.write_text(json.dumps(store))
PY
}

# What the poller remembers about one request: the commit recorded, the review, and whether it
# is dismissed. `recorded.<key>.<field>`, or the empty string when there is nothing there.
remembered () {
  python3 - "$inst/runtime/poll-state.json" "$1" "$2" <<'PY'
import json, sys, pathlib
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
print((state.get("recorded") or {}).get(sys.argv[2], {}).get(sys.argv[3], ""))
PY
}
recorded_count () {
  python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("recorded") or {}))' \
    "$inst/runtime/poll-state.json"
}

# work_doc <kind> <review_id> <repo> <pr> [entered_at] [ledger_id] [note]
work_doc () {
  python3 - "$work/rd.work" "$@" <<'PY'
import json, sys, pathlib
dest = pathlib.Path(sys.argv[1])
kind, rid, repo, pr = sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
entered = int(sys.argv[6]) if len(sys.argv) > 6 and sys.argv[6] else 1791520282
ledger = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else None
note = sys.argv[8] if len(sys.argv) > 8 and sys.argv[8] else None
# The last two are the nit ticket's, and they are on every item rather than on the one kind that
# is about them: `work list`'s own `document()` puts them on all thirteen fields' worth, because
# an approved draft can carry a request for a ticket nobody has filed.
dest.write_text(json.dumps({"work": [{
    "kind": kind, "review_id": rid, "repo": repo, "pr": pr, "head_sha": "3f9c2ab", "round": 1,
    "sign_off": None if kind == "review_requested" else "developer",
    "session_id": None, "ledger_id": ledger, "entered_at": entered, "note": note,
    "nit_ticket_status": "requested" if kind == "nits_to_ticket" else "none",
    "nit_ticket_requested_at": entered if kind == "nits_to_ticket" else None}]}))
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

elif scenario == "poll_order":
    # One tick with every emission APPENDED TO THE SAME FILE the stand-in logs its calls to, so
    # "recorded before the request was emitted" is an assertion about one ordered record rather
    # than about two files nobody can interleave. The events still go to stdout, so the usual
    # `says` and `count` assertions work on this scenario too.
    import pathlib
    calls = pathlib.Path(os.environ["RDWORK"]) / "rd.calls"
    spoke = m.emit

    def tee(event, **fields):
        with calls.open("a") as handle:
            handle.write("emit %s\n" % event)
        spoke(event, **fields)

    m.emit = tee
    m.Poller().tick()

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

elif scenario == "watch_interval":
    # The real instance config, with `limits` overridden by the second argument when given, so
    # the default path and a configured one are the same call.
    cfg = m.load_config()
    if len(rest) > 1 and rest[1]:
        cfg["limits"].update(json.loads(rest[1]))
    print(m.watch_interval(cfg, {"draft_status": rest[0]} if rest[0] else {}))

elif scenario == "full_due":
    # `last_full` as a number of seconds ago, so "a pass is due again" is testable without one.
    import time as clock
    print(json.dumps(m.full_pass_due(clock.time() - float(rest[0]), m.load_config())))

elif scenario == "watch_sleep":
    # One real tick, then the interval `cmd_watch` would sleep after it: the two halves joined.
    w = m.Watcher(rest[0], None, None)
    w.tick(full=(rest[1] != "fast") if len(rest) > 1 else True)
    print(json.dumps({"draft_status": w.state.get("draft_status"),
                      "interval": m.watch_interval(m.load_config(), w.state)}))

elif scenario == "rd_run":
    # `review_desk_run`'s new `timeout`, against the stand-in's `slow` harvest.
    state, _, detail = m.review_desk_run(m.review_desk_cfg(m.load_config()), *rest[1:],
                                         timeout=int(rest[0]))
    print(json.dumps({"state": state, "detail": detail}))

elif scenario == "kinds":
    # The three tuples, so the crossing below is against the source rather than against a grep.
    print(json.dumps({"kinds": list(m.REVIEW_DESK_KINDS),
                      "ignored": list(m.REVIEW_DESK_IGNORED_KINDS),
                      "watch": list(m.REVIEW_DESK_WATCH_KINDS)}))

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
printf '\nThis file runs every assertion it contains\n'
# **First, because the failure it guards can swallow whatever follows it.** A `printf` heading
# that loses its closing quote is still valid shell -- `sh -n` passes -- and the lines after it
# are taken as string content and PRINTED rather than run. It has happened three times in this
# file's history: once hiding 2 assertions and once about 37, including the end-to-end filing
# loop, while the suite went on reporting "0 failed". Running first does not make the guard
# unloseable -- several hundred lines of quote-bearing shell still precede it -- but it does put
# it ahead of every assertion it is guarding.
#
# **What it catches is one shape**: a `printf` whose opening quote is there and whose closing
# one is not, single- or double-quoted, indented or not. A lost OPENING quote swallows just as
# well and is not caught; neither is an unbalanced quote in any other command. The shape checked
# is the shape that has actually occurred here, three times.
ok "no heading in this harness is missing its quote"   "$(grep -c "^[[:space:]]*printf '[^']*$" "$0")" 0
ok "  nor a double-quoted one"                         "$(grep -c "^[[:space:]]*printf \"[^\"]*$" "$0")" 0
sed "s/^printf '\\\\nSilence -- no review_desk block, no review-desk on PATH\\\\n'\$/printf '\\\\nSilence -- no review_desk block, no review-desk on PATH\\\\n/" \
    "$0" > "$work/noquote.sh"
ok "  and the reversal of one is caught"               "$(grep -c "^[[:space:]]*printf '[^']*$" "$work/noquote.sh")" 1
# Indented, which the anchor this replaced could not see and which this file has five live
# instances of. The first version of THIS control named a line the file does not contain, so it
# matched nothing and counted 0 either way -- the third no-information check found in this
# change, and the one that was written while fixing the other two.
cp "$0" "$work/noquote2.sh"
printf '  printf "\\nbroken\\n\n' >> "$work/noquote2.sh"
printf '  printf %s\\nalso broken\\n\n' "'" >> "$work/noquote2.sh"
ok "the indented reversal added two headings"          "$(diff "$0" "$work/noquote2.sh" | grep -c '^>')" 2
ok "  and both are caught, either quote"               "$(( $(grep -c "^[[:space:]]*printf '[^']*$" "$work/noquote2.sh") + $(grep -c "^[[:space:]]*printf \"[^\"]*$" "$work/noquote2.sh") ))" 2

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
ok "  and it asked per repository served"              "$(grep -c '^work list .*--repo acme/portal' "$work/rd.calls")" 1
ok "  and nothing else"                                "$(grep -c '^work list .*--repo' "$work/rd.calls")" 1
ok "  the tick exits clean"                            "$rc" 0

# Two repositories: the config's map and one learned from a ledger entry.
instance '{"mode":"auto"}'
put gh-billing-77 mode=review status=lost repo=acme/billing number=77 --by test
work_doc review_requested 1 acme/portal 412
rc=$(run "$disp" poll 1)
ok "a repo from the ledger is polled too"              "$(grep -c '^work list .*--repo acme/billing' "$work/rd.calls")" 1
ok "  alongside the one from the config"               "$(grep -c '^work list .*--repo acme/portal' "$work/rd.calls")" 1

instance '{"mode":"auto"}'
python3 - "$inst/config.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); c = json.loads(p.read_text())
c["allele"]["repo_project_map"] = {"OWNER/REPO": "your-project"}
p.write_text(json.dumps(c, indent=2))
PY
rc=$(run "$disp" poll 1)
ok "the template's OWNER/REPO placeholder is not asked" "$(grep -c -- '--repo' "$work/rd.calls")" 0
# Both calls that take one, named: `work list` and the harvest below ask per repository, and
# the placeholder must reach neither.
ok "  so an unedited instance says nothing"            "$(count review_desk)" 0

printf '\n  the four kinds that resume, and the one that does not\n'
for kind in brief_settled draft_sent_back draft_approved nits_to_ticket; do
  instance '{"mode":"auto"}'
  work_doc "$kind" 3 acme/portal 414 1791520339 "" "F2 is the same point as F1"
  rc=$(run "$disp" poll 1)
  ok "$kind with no session resumes"                   "$(count '"event": "review_desk_resume"')" 1
  ok "  naming the kind"                               "$(says "\"kind\": \"$kind\"")" yes
  ok "  with the draft link"                           "$(says 'reviews/3/draft')" yes
done
# Driven on the kind it is about, rather than read off whatever the loop happened to end on:
# `work_doc` writes a note for every kind, so these two passed against any of the four.
instance '{"mode":"auto"}'
work_doc draft_sent_back 3 acme/portal 414 1791520339 "" "F2 is the same point as F1"
rc=$(run "$disp" poll 1)
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
printf '\nThe harvest -- the poller runs it, per repository served (DEV-931)\n'
# `review-desk harvest` reads a posted review's replies, resolved threads and changed lines back
# from GitHub. It existed and nothing called it. Nothing here runs a real harvest: the stand-in
# answers from $RDWORK/rd.harvest, and the real call would reach GitHub and the live store.

# harvested <replies> <resolved> <code_changed>: what the stand-in's harvest reports recording.
harvested () {
  printf '{"harvest":{"reviews":[{"review_id":7,"repo":"acme/portal","pr":412,"round":1,' >  "$work/rd.harvest"
  printf '"replies_recorded":%s,"threads_resolved_recorded":%s,"code_changed_recorded":%s,' \
    "$1" "$2" "$3"                                                                         >> "$work/rd.harvest"
  printf '"already_recorded":0}]}}\n'                                                      >> "$work/rd.harvest"
}
# age_marker <mark> [secs]: push one `due()` marker that far into the past, 100000s by default.
# The clock, rather than a sleep: an interval is a number this test should not have to wait out.
# The seconds matter for the rotation case below, where two marks must differ in age.
age_marker () {
  # A marker that is not there is counted as a FAILURE rather than raised. It used to raise a
  # KeyError, which under `set -e` took the whole harness down -- including its tally -- so a
  # mistyped or not-yet-set mark read as "the suite stopped" rather than as one bad assertion.
  python3 -c "
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = json.loads(p.read_text())
if sys.argv[2] not in s['emitted']:
    sys.exit('no such marker')
s['emitted'][sys.argv[2]] -= int(sys.argv[3])
p.write_text(json.dumps(s))" "$inst/runtime/poll-state.json" "$1" "${2:-100000}" 2>/dev/null \
    || { fail=$((fail + 1)); printf '  FAIL  %-60s %s\n' "age_marker found no such marker" "$1"; }
}
harvests () { grep -c "^harvest --repo $1 --json" "$work/rd.calls" 2>/dev/null || true; }

instance '{"mode":"auto"}'
work_doc review_requested 1 acme/portal 412
rc=$(run "$disp" poll 1)
ok "the poll harvests the repository it serves"        "$(harvests acme/portal)" 1
ok "  and exits clean"                                 "$rc" 0
ok "  and says nothing, having recorded nothing"       "$(count harvest)" 0
rc=$(run "$disp" poll 2)
ok "two more ticks inside the interval harvest nothing" "$(harvests acme/portal)" 1
age_marker 'harvest|acme/portal'
rc=$(run "$disp" poll 1)
ok "a tick after the interval harvests again"          "$(harvests acme/portal)" 2

printf '\n  the turn goes to whichever repository has waited longest\n'
# Not the first one that is due in sorted order. `due()` stamps absolute time, so that version
# gave the one slot a tick has to the same early names for ever: five repositories at the
# shipped 300s poll and 900s interval harvested the first three 66-68 times over sixteen hours
# and the last two NOT ONCE. Three repositories, three ticks, each exactly once.
instance '{"mode":"auto"}'
put gh-billing-77 mode=review status=lost repo=acme/billing number=77 --by test
put gh-store-5 mode=review status=lost repo=acme/store number=5 --by test
rc=$(run "$disp" poll 3)
ok "three ticks harvest acme/billing once"             "$(harvests acme/billing)" 1
ok "  acme/portal once"                                "$(harvests acme/portal)" 1
ok "  and acme/store once"                             "$(harvests acme/store)" 1
rc=$(run "$disp" poll 2)
ok "two more ticks harvest none of them again"          "$(grep -c '^harvest' "$work/rd.calls")" 3
# TWO due at once, with different ages, which is what discriminates. Three repositories over
# three back-to-back ticks pass on the starving sweep too -- inside one interval it also skipped
# a repository it had already marked -- and so does aging the only repository that is due, since
# "first in the sort" and "oldest mark" then name the same one. `acme/store` sorts LAST and has
# waited longest; the sweep this replaced would have taken `acme/billing`.
age_marker 'harvest|acme/billing' 1000
age_marker 'harvest|acme/store' 100000
rc=$(run "$disp" poll 1)
ok "the oldest mark takes the tick, not the first due"  "$(harvests acme/store)" 2
ok "  and the other due one waits its turn"             "$(harvests acme/billing)" 1
ok "  and the one that is not due is untouched"         "$(harvests acme/portal)" 1
rc=$(run "$disp" poll 1)
ok "which it gets on the tick after"                    "$(harvests acme/billing)" 2

# One ATTEMPT per tick, so two repositories take two ticks. Oldest first, so billing goes first.
instance '{"mode":"auto"}'
put gh-billing-77 mode=review status=lost repo=acme/billing number=77 --by test
rc=$(run "$disp" poll 1)
ok "one tick harvests one repository"                  "$(harvests acme/billing)" 1
ok "  and leaves the other for the next tick"          "$(harvests acme/portal)" 0
rc=$(run "$disp" poll 1)
ok "the next tick harvests the other"                  "$(harvests acme/portal)" 1
ok "  and not the first again"                         "$(harvests acme/billing)" 1

instance '{"mode":"auto"}'
python3 -c "
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); c = json.loads(p.read_text())
c['allele']['repo_project_map'] = {'OWNER/REPO': 'your-project'}
p.write_text(json.dumps(c, indent=2))" "$inst/config.json"
rc=$(run "$disp" poll 1)
ok "the template's placeholder repo is not harvested"  "$(grep -c '^harvest' "$work/rd.calls")" 0

instance '{"mode":"off"}'
rc=$(run "$disp" poll 2)
ok "mode off runs no harvest"                          "$(grep -c '^harvest' "$work/rd.calls")" 0
ok "  and says nothing about one"                      "$(count harvest)" 0

instance '{"mode":"auto"}'
hide
rc=$(run "$disp" poll 2)
ok "no binary under auto is silent about the harvest"  "$(count harvest_failed)" 0
ok "  and still exits clean"                           "$rc" 0
show
instance '{"mode":"on"}'
hide
rc=$(run "$disp" poll 3)
ok "no binary under on is loud once per interval"      "$(count '"event": "harvest_failed"')" 1
ok "  naming the state absent"                         "$(says '"state": "absent"')" yes
ok "  and still exits clean"                           "$rc" 0
show

printf '\n  a harvest that fails is reported once and stops nothing\n'
instance '{"mode":"auto"}'
work_doc review_requested 1 acme/portal 412
echo broken > "$work/rd.harvest.mode"
rc=$(run "$disp" poll 1)
ok "a broken harvest emits one harvest_failed"         "$(count '"event": "harvest_failed"')" 1
ok "  naming the state"                                "$(says '"state": "broken"')" yes
ok "  and quoting Review Desk's own reason"            "$(says gh_unreachable)" yes
ok "  and the repository it was asked about"           "$(says '"repo": "acme/portal"')" yes
ok "  the tick exits clean"                            "$rc" 0
ok "  the work the same tick found is still emitted"   "$(count '"event": "review_desk_requested"')" 1
ok "  and the tick still completed"                    "$([ -f "$inst/runtime/poller-heartbeat" ] && echo yes || echo no)" yes
rc=$(run "$disp" poll 2)
ok "two more ticks do not repeat it"                   "$(count '"event": "harvest_failed"')" 0
age_marker 'harvest|acme/portal'
echo refused > "$work/rd.harvest.mode"
rc=$(run "$disp" poll 1)
ok "a refused harvest is reported too"                 "$(count '"event": "harvest_failed"')" 1
ok "  as refused, not broken"                          "$(says '"state": "refused"')" yes

printf '\n  what a harvest recorded is said once, and only when there is something\n'
instance '{"mode":"auto"}'
harvested 0 0 0
rc=$(run "$disp" poll 1)
ok "a harvest that recorded nothing says nothing"      "$(count harvest_recorded)" 0
instance '{"mode":"auto"}'
harvested 2 1 3
rc=$(run "$disp" poll 1)
ok "a harvest that recorded something says so"         "$(count '"event": "harvest_recorded"')" 1
ok "  with the replies recorded"                       "$(says '"replies_recorded": 2')" yes
ok "  the threads resolved"                            "$(says '"threads_resolved_recorded": 1')" yes
ok "  the lines changed since"                         "$(says '"code_changed_recorded": 3')" yes
ok "  and how many reviews it read"                    "$(says '"reviews": 1')" yes

printf '\n  the harvest has its own timeout, because it is the one call that is not local\n'
instance '{"mode":"auto"}'
echo slow > "$work/rd.harvest.mode"
rc=$(run "$disp" rd_run 1 harvest --repo acme/portal --json)
ok "a harvest that outlasts its timeout is broken"     "$(says '"state": "broken"')" yes
ok "  and says it did not answer in time"              "$(says 'did not answer in 1s')" yes
ok "the constant is longer than the local one"         "$(python3 -c "
import re
src = open('$disp').read()
print(int(re.search(r'^HARVEST_TIMEOUT = (\d+)', src, re.M).group(1))
      > int(re.search(r'^REVIEW_DESK_TIMEOUT = (\d+)', src, re.M).group(1)))")" True

# =============================================================================================
printf '\nThe watcher -- the developer'"'"'s dashboard acts, relayed to the session waiting\n'

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active --by test
work_doc draft_approved 7 acme/portal 412
rc=$(run "$disp" watch gh-portal-412 1)
ok "an entry with no review id polls nothing"          "$(grep -c 'work list' "$work/rd.calls")" 0
ok "  and emits nothing"                               "$(count draft_approved)" 0

put gh-portal-412 review_desk_id=7 --by test
rc=$(run "$disp" watch gh-portal-412 1)
ok "an entry with a review id polls its own review"    "$(grep -c '^work list .*--review 7' "$work/rd.calls")" 1
ok "  and emits draft_approved"                        "$(count '"event": "draft_approved"')" 1
ok "  on the first tick, not the second"               "$(says '"tick": 1')" yes
ok "  with the draft link to approve at"               "$(says 'reviews/7/draft')" yes

for kind in brief_settled draft_sent_back draft_approved nits_to_ticket; do
  instance '{"mode":"auto"}'
  put gh-portal-412 mode=review status=active review_desk_id=7 --by test
  work_doc "$kind" 7 acme/portal 412 1791520339 "" "cut one of them"
  rc=$(run "$disp" watch gh-portal-412 3)
  ok "$kind is emitted once over three ticks"          "$(count "\"event\": \"$kind\"")" 1
  ok "  identified by kind, review and time"           "$(says "$kind|7|1791520339")" yes
done
# Driven on the kind it is about, for the reason the poller's pair above is.
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
work_doc draft_sent_back 7 acme/portal 412 1791520339 "" "cut one of them"
rc=$(run "$disp" watch gh-portal-412 1)
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
printf '\nThe fifth kind -- one ticket for the findings held back (DEV-934)\n'
# `work list` answers with FIVE kinds and this file knew four, so the developer's "File as one
# ticket for an agent" reached no session and said nothing about itself. Three things are under
# test: the item reaches somebody, the command `workers/review.md` tells that somebody to run
# clears it, and a SIXTH kind is named rather than dropped in the same silence.

worker_md="$root/skills/dispatcher/workers/review.md"
skill_md="$root/skills/dispatcher/SKILL.md"
# desk_rc: one stand-in call, for its exit code. `rc` further down is the same thing; this
# section runs before that definition.
desk_rc () { set +e; review-desk "$@" > "$work/out" 2>"$work/err"; echo $?; set -e; }
# held: the findings the developer kept out of the draft, as `review show` reports them.
held () {
  python3 - "$work/rd.held" <<'HELD'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps([
    {"seq": 4, "key": "F4", "severity": "nit", "file": "app/Jobs/Deliver.php", "line": 58,
     "claim": "The retry count is read twice", "disposition": "held_back",
     "disposition_reason": "not worth a round trip"},
    {"seq": 5, "key": "F5", "severity": "nit", "file": "app/Jobs/Deliver.php", "line": 71,
     "claim": "The log line names the old field", "disposition": "held_back",
     "disposition_reason": None},
    # NOT held back, and that is what gives the count below something to be wrong about: the
    # ticket covers the held-back findings and not the review's findings.
    {"seq": 1, "key": "F1", "severity": "blocker", "file": "app/Jobs/Deliver.php", "line": 58,
     "claim": "A retried delivery carries no idempotency key", "disposition": "in_draft",
     "disposition_reason": None}]))
HELD
}
# button <review>: the text the draft page puts on its one held-back button. The three-way
# expression is copied from review-desk's web/app/pages/reviews/[id]/draft.vue at 2656e54; the
# status it reads comes back through the command line, which is the surface Locus has. The
# dashboard reads the same two columns over HTTP.
button () {
  review-desk review show --review "$1" --json > "$work/show.json" 2>/dev/null
  python3 - "$work/show.json" <<'BUTTON'
import json, pathlib, sys
r = json.loads(pathlib.Path(sys.argv[1]).read_text())["review"]
status, ticket = r["nit_ticket_status"], r["nit_ticket_id"]
print("File as one ticket for an agent" if status == "none"
      else "Queued as one ticket" if status == "requested"
      else "Filed as %s" % ticket)
BUTTON
}

printf '\n  the item reaches the session that owns the review\n'
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
work_doc nits_to_ticket 7 acme/portal 412 1791520400
rc=$(run "$disp" watch gh-portal-412 1)
ok "the watcher relays nits_to_ticket"                 "$(count '"event": "nits_to_ticket"')" 1
ok "  carrying the ticket's status"                    "$(says '"nit_ticket_status": "requested"')" yes
ok "  and the page it was asked on"                    "$(says 'reviews/7/draft')" yes
ok "  and the tick exits clean"                        "$rc" 0

printf '\n  an approved draft carries a ticket asked for in the same click\n'
# "Ticket what is left, and approve" is ONE button: the draft is approved and a ticket is
# requested, and Review Desk reports the approval first -- the ticket becomes an item of its own
# only once the posting is reported. So `draft_approved` has to carry the request or the session
# cannot know there is one.
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
work_doc draft_approved 7 acme/portal 412 1791520400
python3 - "$work/rd.work" <<'REQUESTED'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d["work"][0]["nit_ticket_status"] = "requested"
p.write_text(json.dumps(d))
REQUESTED
rc=$(run "$disp" watch gh-portal-412 1)
ok "draft_approved says a ticket is queued too"        "$(count '"event": "draft_approved"')" 1
ok "  by carrying the request's status"                "$(says '"nit_ticket_status": "requested"')" yes

printf '\n  the poller sends a replacement when the session is gone\n'
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=dead-1 --by test
rc=$(run "$disp" poll 1)
ok "a nits_to_ticket with no live session resumes"     "$(count '"event": "review_desk_resume"')" 1
ok "  naming the kind"                                 "$(says '"kind": "nits_to_ticket"')" yes
ok "  and the status of the ticket asked for"          "$(says '"nit_ticket_status": "requested"')" yes
ok "  on the key Review Desk was linked to"            "$(says '"key": "gh-portal-418"')" yes

# A FRESH instance, and that is the whole of this assertion. Run against the one above, the
# item's own `due` marker has already been stamped, so it emits nothing whatever liveness says --
# a check that passes with `review_desk_live` hard-coded to False, which is no check at all.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=active repo=acme/portal number=418 session_id=live-8 --by test
no_sessions
session live-8
rc=$(run "$disp" poll 1)
ok "a live session owns its own nits_to_ticket"        "$(count review_desk)" 0
no_sessions

printf '\n  and it is sent even when the pull request has merged\n'
# The one kind that outlives the merge. The request becomes an item only once the draft is
# reported posted, and a merge usually follows a posting -- so a request on a merged pull request
# is the likely shape of this kind, not an edge of it. Skipping it would leave the developer's
# click unanswered for ever, which is this ticket's own bug in a narrower case.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "a nits_to_ticket on a MERGED pull request resumes" "$(count '"event": "review_desk_resume"')" 1
ok "  saying the pull request is merged"               "$(says '"pr_state": "merged"')" yes
instance '{"mode":"auto"}'
work_doc draft_approved 9 acme/portal 418 1791520400 gh-portal-418
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "  and no other kind gained that exemption"         "$(count review_desk)" 0

printf '\n  a live session whose watcher has stopped is not told, so somebody else is\n'
# The combination the two assertions above never made. A review worker reports `done` and stays
# up to hear the approval; after the merge `watch_stop_reason` ends its watcher, and nothing
# writes a terminal ledger status -- so `done` is in ALIVE, allele still lists the session, and
# `review_desk_live` says a session owns a review nobody is listening to. The watcher's own
# cursor is what settles it, which is where `watch_stop_reason` reads it too.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"pr_status":"merged","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "a done key whose PR merged no longer owns the ticket" "$(count '"event": "review_desk_resume"')" 1
ok "  and the event names the session to message"      "$(says '"session_id": "live-7"')" yes
ok "  with the status that says its watcher is shut"   "$(says '"ledger_status": "done"')" yes
# **An absent cursor is a watcher that has been and gone, not one that has yet to start**, and
# the first version of this section asserted the opposite. `cmd_watch` DELETES the cursor on
# three of `watch_stop_reason`'s four stop paths — a `WATCH_DEAD` status, `--exit-on-done` which
# SKILL.md tells the Dispatcher to offer the principal, and a `done` key with no pull request —
# and only `Watcher.tick` ever writes one, so the absence is permanent. Read as "not yet", the
# request reached nobody for ever on a documented path, and this assertion pinned it as correct.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "a deleted cursor is a watcher that has gone"       "$(count '"event": "review_desk_resume"')" 1
ok "  and the tick exits clean"                        "$rc" 0
# What still keeps the item with its session: a cursor that EXISTS and has not concluded. One
# with an open pull request is a watcher reading; `ceiling` and `max_ticks` leave exactly this,
# and `_common.md` tells the worker to re-arm after them.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"pr_status":"open","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
rc=$(run "$disp" poll 1)
ok "  an open pull request keeps it with its session"  "$(count review_desk)" 0
# One armed and not yet past `pull_request`, which is also a watcher that is listening.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"pr":{"repo":"acme/portal","number":418}}' > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "  a cursor with no pr_status keeps it too"         "$(count review_desk)" 0
# A cursor another process was half-way through writing. Asserted on the ERROR event and not on
# `count review_desk`, which matches `"section": "review_desk"` inside the error this would
# raise -- so the loose count flipped for the wrong reason and `rc` was 0 either way.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '[]' > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "a cursor that is not an object raises nothing"     "$(count '"event": "error"')" 0
ok "  and is read as a watcher nobody is using"        "$(count '"event": "review_desk_resume"')" 1
ok "  and the tick exits clean"                        "$rc" 0
# **And no other kind gets the bypass — on an OPEN pull request, which is the whole point of
# this fixture.** The first version of this pair said MERGED, where a `draft_approved` that took
# the bypass is dropped a few lines later by the merge exemption anyway: the assertion read 0
# off a different guard and passed with the kind half of the gate deleted. Contrived on purpose
# — a cursor saying merged while GitHub says open — because that is the only state in which the
# kind half is the only thing deciding.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"pr_status":"merged","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"OPEN"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "the bypass is the cursor's doing, not the merge's" "$(count '"event": "review_desk_resume"')" 1
instance '{"mode":"auto"}'
work_doc draft_approved 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"pr_status":"merged","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"OPEN"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "  and no other kind gained it"                     "$(count review_desk)" 0
no_sessions

printf '\n  the request leaves the list once the ticket is reported\n'
# The loop end to end, through the stand-in: the button says queued, the command review.md names
# is accepted, the button says filed, and `work list` stops reporting the request. A dispatcher
# that re-dispatched for ever would pass every assertion above and fail the last one.
instance '{"mode":"auto"}'
held
echo '{"status":"requested","ticket_id":null}' > "$work/rd.nit"
work_doc nits_to_ticket 7 acme/portal 412 1791520400
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
ok "the draft page's button reads"                     "$(button 7)" "Queued as one ticket"
# This crosses the FIXTURE against itself -- the stand-in returns `rd.held` verbatim -- so it
# checks that the number review.md sends a worker for is the held-back ones and not the
# review's. No Locus code can make it fail; `review show`'s own filtering is Review Desk's.
ok "  over the two held back out of three"             "$(python3 -c "
import json
d = json.load(open('$work/show.json'))['findings']
print('%d of %d' % (len([f for f in d if f['disposition'] == 'held_back']), len(d)))")" "2 of 3"
ok "the command review.md names is accepted"           "$(desk_rc review nit-ticket --review 7 --ticket ABC-246 --json)" 0
ok "  it reports the filing back"                      "$(grep -c '"status": "filed"' "$work/out")" 1
ok "  the button then reads"                           "$(button 7)" "Filed as ABC-246"
rc=$(run "$disp" watch gh-portal-412 1)
ok "  and the request has left the work list"          "$(count '"event": "nits_to_ticket"')" 0
ok "  so nothing is relayed twice"                     "$rc" 0
ok "a report with no --ticket is refused"              "$(desk_rc review nit-ticket --review 7)" 1
ok "  and an empty one is refused too"                 "$(desk_rc review nit-ticket --review 7 --ticket '')" 1

printf '\n  what the worker file says to write, where, and how to report it\n'
ok "review.md has the event"                           "$(grep -c '| .nits_to_ticket. |' "$worker_md")" 1
ok "  and a section of its own"                        "$(grep -c '^### Filing the held-back findings as one ticket$' "$worker_md")" 1
ok "  it says the findings are at held_back"           "$(grep -c '"disposition": "held_back"' "$worker_md")" 1
ok "  read through review show"                        "$(grep -c '^1\. \*\*Check it is not already filed\.\*\* .review-desk review show' "$worker_md")" 1
# Review Desk's own `work list` help names `finding list` and 0.1.0 has no such subcommand, so a
# worker that followed the help would exit 1 holding nothing. The file has to say so.
ok "  and warns off the command that does not exist"   "$(grep -c 'Not .finding list' "$worker_md")" 1
ok "  it never tells a worker to run one"              "$(grep -c 'review-desk finding list' "$worker_md")" 0
ok "  it names the command that reports the id"        "$(grep -c 'review nit-ticket --review <id> --ticket <NEW-ID>' "$worker_md")" 1
ok "  and the style the ticket is written in"          "$(grep -c 'issue-craft. skill' "$worker_md")" 1
ok "  with the linter's installed path, not a bare name" "$(grep -c 'python3 ~/.locus/skills/issue-craft/issue_lint.py --key' "$worker_md")" 1
ok "  one ticket, not one per finding"                 "$(grep -c 'never one per finding' "$worker_md")" 1
ok "  the team comes from the review's own ticket"     "$(grep -c 'ticket_id. is null, ask the' "$worker_md")" 1
ok "  and it checks for a filing before filing"        "$(grep -c 'review.nit_ticket_status' "$worker_md")" 1
# The one thing here that must not be got wrong: a session reading any dashboard click as
# permission to post. Said in the row and again in the section.
ok "  filing is not a sign-off, said twice"            "$(grep -c 'not a sign-off' "$worker_md")" 2
ok "  and the button text the report moves"            "$(grep -c 'Queued as one ticket' "$worker_md")" 1
ok "  each event row names its section, not its distance" "$(grep -c 'exactly as \*\*' "$worker_md")" 2
ok "  and a null ticket blocks the filing, not the session" "$(grep -c 'file nothing until they answer' "$worker_md")" 1
ok "  a merged pull request does not cancel the ticket"  "$(grep -c 'merged pull request does not cancel' "$worker_md")" 1
ok "SKILL.md names the fifth kind"                     "$(grep -c 'fifth kind is .nits_to_ticket' "$skill_md")" 1
ok "  and the unknown-kind event, in prose and as a row" "$(grep -c 'review_desk_unknown_kind' "$skill_md")" 2

printf '\n  a kind this file cannot place is named, once per interval\n'
instance '{"mode":"auto"}'
work_doc rubric_settled 11 acme/portal 420
rc=$(run "$disp" poll 3)
ok "an unknown kind is one loud event over three ticks" "$(count '"event": "review_desk_unknown_kind"')" 1
ok "  naming it"                                       "$(says '"kind": "rubric_settled"')" yes
ok "  and the five it does know"                       "$(says '"nits_to_ticket"')" yes
ok "  it dispatches nothing"                           "$(count '"event": "review_desk_resume"')" 0
ok "  nor as a fresh review"                           "$(count '"event": "review_desk_requested"')" 0
ok "  and the tick exits clean -- loud never blocks"   "$rc" 0
ok "  it never read the pull request for it"           "$(grep -c 'pr view' "$work/gh.calls")" 0

# The claim that lets the watcher stay silent: the poller tests the kind BEFORE it tests
# liveness, so an unknown kind is named even for a review somebody is working.
instance '{"mode":"auto"}'
work_doc rubric_settled 11 acme/portal 420 1791520282 gh-portal-420
put gh-portal-420 mode=review status=active repo=acme/portal number=420 session_id=live-9 --by test
session live-9
rc=$(run "$disp" poll 1)
ok "it is named even when a session owns that review"  "$(count '"event": "review_desk_unknown_kind"')" 1
no_sessions

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
work_doc rubric_settled 7 acme/portal 412
rc=$(run "$disp" watch gh-portal-412 3)
ok "the watcher relays an unknown kind to nobody"      "$(count rubric_settled)" 0
ok "  and says nothing, because the poller does"       "$(count unknown_kind)" 0
ok "  and keeps ticking"                               "$rc" 0

instance '{"mode":"auto"}'
echo '{"work":[{"review_id":12,"repo":"acme/portal","pr":421}]}' > "$work/rd.work"
rc=$(run "$disp" poll 1)
ok "an item with no kind at all says nothing"          "$(count review_desk)" 0
ok "  and is not an error"                             "$rc" 0

printf '\n  the contract and this file name the same five kinds\n'
# Every `WorkKind` Review Desk 0.1.0 publishes, read off `crates/store/src/model.rs` at 2656e54
# and agreeing with `crates/cli/src/commands/work.rs`'s own help. **When Review Desk adds a
# sixth, add it to this line first.** The assertion then fails until `dispatcher.py` either
# handles it in `REVIEW_DESK_KINDS` or names it in `REVIEW_DESK_IGNORED_KINDS` -- which is the
# only way a kind gets left alone on purpose rather than by nobody noticing, and the gap this
# whole section is about went five weeks with no line anywhere to grep for.
CONTRACT_KINDS='["brief_settled", "draft_approved", "draft_sent_back", "nits_to_ticket", "review_requested"]'
# placed <expr> [source]: one question about the three tuples, as the source under test holds them.
placed () { run "${2:-$disp}" kinds > /dev/null; python3 -c "
import json
d = json.load(open('$work/out'))
print($1)"; }
ok "every kind the contract lists is handled or ignored" "$(placed "json.dumps(sorted(d['kinds'] + d['ignored']))")" "$CONTRACT_KINDS"
ok "  and nothing is handled the contract does not list" "$(placed "set(d['kinds']) <= set($CONTRACT_KINDS)")" True
# A SUBSET, deliberately, where the line above is an equality. Both as an equality would force
# `REVIEW_DESK_IGNORED_KINDS` to stay empty for ever -- naming a sixth kind as ignored, which is
# exactly what the comment above instructs, would fail this -- and the escape hatch would be
# unusable without editing the test that exists to police it.
ok "  the watcher relays only kinds this file places"  "$(placed "set(d['watch']) <= set(d['kinds'])")" True
ok "  and relays all but the one it must not"          "$(placed "json.dumps(sorted(set(d['kinds']) - set(d['watch'])))")" '["review_requested"]'

# =============================================================================================
printf '\nA draft waiting on the developer is read every 20 seconds (DEV-931)\n'
# The sign-off that posted 4m28s late was behind one `time.sleep(watch_interval_secs)`. What is
# under test is which interval the watcher sleeps, and -- just as much -- what a fast pass is
# allowed to ask: a shorter interval that also shortened `pull_request` would be 720 GitHub
# calls an hour for every watcher holding a draft.

# draft <status>: the status the stand-in's `draft show` answers with.
draft () { echo "$1" > "$work/rd.draft.status"; }
# limits <json>: merge keys into the throwaway instance's `limits` block.
limits () {
  python3 -c "
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); c = json.loads(p.read_text())
c['limits'].update(json.loads(sys.argv[2]))
p.write_text(json.dumps(c, indent=2))" "$inst/config.json" "$1"
}
# interval <draft_status> [limits-override]: what cmd_watch would sleep, in seconds.
interval () { run "$disp" watch_interval "$1" "${2:-}" >/dev/null; cat "$work/out"; }
# sleeps <key> [fast]: one real tick, then the interval it decided on. The LAST line, because
# a tick emits its own events first -- and `watch_sleep` prints its answer last for that reason.
sleeps () {
  run "$disp" watch_sleep "$1" "${2:-full}" >/dev/null
  tail -1 "$work/out" | python3 -c "
import json, sys
print(json.load(sys.stdin)['interval'])"
}
# drafted <key> [fast]: the draft status that tick put in the cursor.
drafted () {
  run "$disp" watch_sleep "$1" "${2:-full}" >/dev/null
  tail -1 "$work/out" | python3 -c "
import json, sys
print(json.load(sys.stdin)['draft_status'])"
}
drafts_asked () { grep -c '^draft show --review 7 --json' "$work/rd.calls" 2>/dev/null || true; }

instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active repo=acme/portal number=412 review_desk_id=7 --by test
draft ready
ok "a draft waiting on the developer is asked about"   "$(sleeps gh-portal-412 >/dev/null; drafts_asked)" 1
ok "  and the status it answered is in the cursor"     "$(drafted gh-portal-412)" ready
ok "  so the next pass is 20 seconds away"             "$(sleeps gh-portal-412)" 20
ok "  and 20 is what the code defaults it to"          "$(grep -c '^DRAFT_WATCH_INTERVAL_SECS = 20$' "$disp")" 1

for status in drafting approved sent_back posted; do
  draft "$status"
  ok "a draft that is $status waits the usual interval" "$(sleeps gh-portal-412)" 300
done

draft ready
ok "the shorter interval is a setting"                 "$(interval ready '{"draft_watch_interval_secs": 5}')" 5
# A shorter interval that is longer than the one it replaces would be a setting that lies -- and
# an instance that lengthened watch_interval_secs to spare an API budget must keep that.
ok "  never longer than watch_interval_secs"           "$(interval ready '{"draft_watch_interval_secs": 600}')" 300
ok "  a typo in it falls back to the default"          "$(interval ready '{"draft_watch_interval_secs": "soon"}')" 20
ok "  and so does a zero, which would be a hot loop"   "$(interval ready '{"draft_watch_interval_secs": 0}')" 20
ok "no draft status at all waits the usual interval"   "$(interval '')" 300

printf '\n  what the fast pass may ask, which is Review Desk and nothing else\n'
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active repo=acme/portal number=412 review_desk_id=7 --by test
draft ready
: > "$work/gh.calls"
rc=$(run "$disp" watch_sleep gh-portal-412 fast)
ok "a fast pass asks GitHub nothing"                   "$(wc -l < "$work/gh.calls" | tr -d ' ')" 0
ok "  and still reads Review Desk"                     "$(drafts_asked)" 1
ok "  and the pull request too"                        "$(grep -c '^work list .*--review 7' "$work/rd.calls")" 1
: > "$work/gh.calls"
rc=$(run "$disp" watch_sleep gh-portal-412 full)
ok "a full pass is the one that asks GitHub"           "$(grep -c 'api repos/acme/portal/pulls/412' "$work/gh.calls")" 1
ok "a full pass is due when nothing has run"           "$(run "$disp" full_due 999999 >/dev/null; cat "$work/out")" true
ok "  and not again until watch_interval_secs"         "$(run "$disp" full_due 0 >/dev/null; cat "$work/out")" false
ok "  measured against that setting, not the short one" "$(run "$disp" full_due 301 >/dev/null; cat "$work/out")" true

printf '\n  a watcher with nothing recorded, or Review Desk off, asks nothing\n'
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active repo=acme/portal number=412 --by test
draft ready
ok "an entry with no review id is not asked about"     "$(sleeps gh-portal-412 >/dev/null; drafts_asked)" 0
ok "  and waits the usual interval"                    "$(sleeps gh-portal-412)" 300
instance '{"mode":"off"}'
put gh-portal-412 mode=review status=active repo=acme/portal number=412 review_desk_id=7 --by test
draft ready
ok "mode off asks nothing"                             "$(sleeps gh-portal-412 >/dev/null; drafts_asked)" 0
ok "  and waits the usual interval"                    "$(sleeps gh-portal-412)" 300

printf '\n  the probe is silent: the call beside it is the one that is loud\n'
# A review has no draft for most of its life, so `draft show` refusing is the ordinary answer
# rather than news -- and a broken install is already a watch_error from `work list`, every tick.
for mode in nodraft broken; do
  instance '{"mode":"auto"}'
  put gh-portal-412 mode=review status=active repo=acme/portal number=412 review_desk_id=7 --by test
  echo "$mode" > "$work/rd.draft.mode"
  rc=$(run "$disp" watch gh-portal-412 1)
  ok "a $mode draft says nothing"                      "$(count '"section": "draft_wait"')" 0
  ok "  and is no watch_error of its own"              "$(count '"event": "watch_error"')" 0
  ok "  and waits the usual interval"                  "$(run "$disp" watch_interval '' >/dev/null; cat "$work/out")" 300
done

printf '\n  end to end: a real watch process sleeps the short interval\n'
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active repo=acme/portal number=412 review_desk_id=7 --by test
draft ready
limits '{"draft_watch_interval_secs": 1, "watch_interval_secs": 300}'
: > "$work/gh.calls"
started=$(date +%s)
set +e; D watch gh-portal-412 --max-ticks 3 > "$work/out" 2>"$work/err"; rc=$?; set -e
elapsed=$(( $(date +%s) - started ))
ok "three passes at a 1s draft interval exit clean"    "$rc" 0
ok "  and took under 20 seconds, not 600"              "$([ "$elapsed" -lt 20 ] && echo yes || echo no)" yes
ok "  reporting three ticks"                           "$(says '"ticks": 3')" yes
# One, from the first pass. The two fast ones asked GitHub nothing -- which is the whole
# difference between this and a 720-call-an-hour watcher.
ok "  with one GitHub call between them"               "$(wc -l < "$work/gh.calls" | tr -d ' ')" 1

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

printf '\n  doctor says what the two intervals are, and names one that is being ignored\n'
# `positive_secs` has to be silent inside the loops -- a value that threw would respawn and run
# with no sleep at all -- so `doctor` is where an operator learns their edit did nothing.
intervals () { set +e; D doctor > "$work/out" 2>&1; set -e; grep '^. intervals' "$work/out" || true; }
# limits_raw <json>: REPLACE the limits block, so a shape that is not an object can be tried.
limits_raw () {
  python3 -c "
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); c = json.loads(p.read_text())
c['limits'] = json.loads(sys.argv[2])
p.write_text(json.dumps(c, indent=2))" "$inst/config.json" "$1"
}
instance '{"mode":"auto"}'
ok "doctor reports both intervals and their source"   "$(intervals | grep -c 'draft_watch_interval_secs 20s (default)')" 1
ok "  and the harvest interval too"                   "$(intervals | grep -c 'harvest_interval_secs 900s (default)')" 1
ok "  and passes"                                     "$(intervals | grep -c '^✓')" 1
limits '{"harvest_interval_secs": 60}'
ok "a configured interval is named as configured"     "$(intervals | grep -c 'harvest_interval_secs 60s (config)')" 1
limits '{"harvest_interval_secs": "quarter-hourly"}'
# Reported and NOT failed. SKILL.md's start-up step stops the Dispatcher on any cross, and a
# typo in an interval whose default is already in force is not worth a dispatcher that will not
# start -- nothing is misbehaving, a number is being ignored.
ok "a value that is not seconds is named"             "$(intervals | grep -c 'IGNORED, and 900s used')" 1
ok "  and does not fail doctor"                       "$(intervals | grep -c '^✓')" 1
limits '{"harvest_interval_secs": 900, "draft_watch_interval_secs": 0}'
ok "a zero is named too, being a hot loop"            "$(intervals | grep -c 'IGNORED, and 20s used')" 1
limits '{"draft_watch_interval_secs": true}'
ok "and a true, which Python reads as 1 second"       "$(intervals | grep -c 'IGNORED, and 20s used')" 1
limits '{"draft_watch_interval_secs": "5"}'
# One predicate, read by `doctor` and by the loops alike. An earlier version parsed a numeric
# string in `positive_secs` and USED it while `doctor` called it ignored, so the operator was
# told the opposite of what was happening by the command whose job is to tell them.
#
# `"5"` rather than `"20"`, and that is the assertion rather than a detail of it: quoted-20 and
# the default-20 are the same number, so the version that parsed the string passed this too.
ok "a quoted number is ignored, and said to be"       "$(intervals | grep -c 'IGNORED, and 20s used')" 1
ok "  and the loop ignores it as well"                "$(interval ready '{"draft_watch_interval_secs": "5"}')" 20
ok "  where a real 5 is slept"                        "$(interval ready '{"draft_watch_interval_secs": 5}')" 5
limits '{"draft_watch_interval_secs": 600}'
ok "a draft interval over the usual one is reported"  "$(intervals | grep -c 'capped at watch_interval_secs 300s')" 1
ok "  and is not a failure, the behaviour being defined" "$(intervals | grep -c '^✓')" 1
# The cap line has to read `watch_interval_secs` the way the LOOP reads it. Gated on
# `usable_secs`, a quoted "10" printed no cap at all while the watcher slept 10s.
limits '{"draft_watch_interval_secs": 20, "watch_interval_secs": "10"}'
ok "a quoted watch interval still reports the cap"    "$(intervals | grep -c 'capped at watch_interval_secs 10s')" 1
ok "  which is the interval the watcher really sleeps" "$(interval ready)" 10
limits '{"watch_interval_secs": 300}'
# A `limits` that is not an object at all breaks `poll` and `status` too, so a cross is
# defensible -- but it must not be charged to the one check that promises never to raise.
limits_raw '5'
ok "a limits block that is not an object does not cross" "$(intervals | grep -c '^✓')" 1
ok "  and still names both intervals"                 "$(intervals | grep -c 'harvest_interval_secs 900s (default)')" 1

printf '\n  and `limits`, which is the block an instance is most likely to have tuned\n'
# DEV-931 adds two keys to it. `fill_absent` adds only what a config has never heard of, which
# is what makes it safe over a block holding `tc-portal`'s 300 against the template's 90.
rc=$(run "$disp" fill_absent '{"watch_interval_secs": 300}' limits)
ok "an older limits block learns the draft interval"   "$(says 'limits.draft_watch_interval_secs')" yes
ok "  and the harvest interval"                        "$(says 'limits.harvest_interval_secs')" yes
ok "  while a tuned interval is left alone"            "$(says '"watch_interval_secs": 300')" yes
ok "  and the shipped default is not written over it"  "$(says '"watch_interval_secs": 90')" no
ok "the template's defaults are the code's"            "$(python3 -c "
import json, sys
sys.path.insert(0, '$root/skills/dispatcher')
import dispatcher as d
limits = json.loads((d.CODE_DIR / 'config.example.json').read_text())['limits']
print(limits['draft_watch_interval_secs'] == d.DRAFT_WATCH_INTERVAL_SECS
      and limits['harvest_interval_secs'] == d.HARVEST_INTERVAL_SECS)")" True

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
    ".pick_key", ".pick_why", ".questions", ".looked_up", "parts[]", ".one_line", ".in_diff",
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
    # The other direction. The read serves five fields for the blind brief to be poured from;
    # one it serves and no template section carries is a field written at write 1 for a reader
    # who never sees it. `problem` and `flow_before_caption` were both in that state.
    "pour_unpoured": sorted(SERVED - set(pour_roots)),
    "pour_sections": [section for section, _ in poured],
}, sort_keys=True))
TABLE

# The top-level keys of a JSON document, optionally dropping a prefix. A helper rather than an
# inline python because its one-liner would need a set literal. See the brace note above.
cat > "$work/partkeys.py" <<'PARTKEYS'
import json, sys
print(sorted(json.load(open(sys.argv[1]))["parts"][0]))
PARTKEYS

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

cat > "$work/limitslots.py" <<'LIMITS'
"""Every quotation `brief_lint.py --limits` attributes to `understand.md`, checked against it.

`--limits` is the one place a limit says where it came from, so a citation quoting text that is
not there is worse than no table at all. A provenance line reads
`understand.md, Understand: 'Supporting table ... 3-4 rows'`; the ellipsis joins a slot name to
the words that carry the number, and **both halves have to occur in the file**.

Checking the whole quotation rather than the slot name is deliberate, and stronger in two ways
a name check is not: it catches a slot that was renamed (the drift this is named after -- DEV-883
renamed "How it works today" and `--limits` went on citing it) AND a quotation that was reworded
where the slot stayed, which is how `'a title under 12 words'` survived DEV-884 changing that
slot to "at most" in the same commit that wrote the citation. It also needs no slot table, so it
judges the citations that quote a paragraph rather than a slot.

Prints the count examined and then any fragment that is missing, because an empty result has to
be distinguishable from a parse that found nothing to examine.
"""
import re, subprocess, sys

limits = subprocess.run([sys.executable, sys.argv[1], "--limits"],
                        capture_output=True, text=True, check=True).stdout
doc = open(sys.argv[2]).read()

# `[^'\n]` and not `[^']`: a provenance line that quotes nothing -- the semicolons limit cites
# "understand.md, rule 3" in prose -- otherwise runs the character class forward off the end of
# its line into the NEXT limit's display name, where the apostrophe in "An option's title"
# closes the quote. That match then consumes the real opening quote after it, and because
# `findall` is non-overlapping the Options citation is never examined at all. Measured: 7
# captures either way, but 5 usable names instead of 6, with `Options` the one lost -- the exact
# rename this check exists to catch.
slots = set()
lines = doc.split("\n")
for index, line in enumerate(lines):
    if line.startswith("| Slot | What goes in it"):
        for row in lines[index + 2:]:
            if not row.startswith("|"):
                break
            match = re.match(r"\| \*\*([^*]+)\*\*", row)
            if match:
                slots.add(match.group(1).strip())

# A citation naming a SECTION quotes a slot, and its name is held to the slot table. One saying
# "the paragraph" quotes prose and is held to the text. The two need telling apart because a
# retired slot name can go on occurring in the file as something else: "How it works today" is
# still the blind brief template's heading for the Before flow, two hundred lines below the slot
# table it was removed from, so a substring check would have called the rename clean.
SLOT = re.compile(r"understand\.md, (?:Understand|Alternatives|Solution): '([^'\n]*?) \.\.\. ([^'\n]*)'")
# `[^'\n]` and not `[^']`: a provenance line that quotes nothing -- the semicolons limit cites
# "understand.md, rule 3" in prose -- otherwise runs the character class forward off the end of
# its line into the NEXT limit's display name, where the apostrophe in "An option's title"
# closes the quote. That match then consumes the real opening quote after it, and because
# `findall` is non-overlapping the Options citation is never examined at all. Measured: 7
# captures either way, but 5 usable names instead of 6, with `Options` the one lost -- the exact
# rename this check exists to catch.
ANY = re.compile(r"understand\.md,[^'\n]*'([^'\n]*)'")

missing, checked, as_slot = [], 0, set()
for name, tail in SLOT.findall(limits):
    checked += 1
    as_slot.add("%s ... %s" % (name, tail))
    if name not in slots:
        missing.append("%s (not a slot)" % name)
    if tail.strip() not in doc:
        missing.append(tail.strip())
# Whatever SLOT did not claim, checked as text. Skipping by what SLOT ACTUALLY captured, not by
# re-testing the fragment's shape: the paragraph citation also carries an ellipsis, so a shape
# test skipped it as a slot citation and left it the one quotation nothing examined.
for fragment in ANY.findall(limits):
    if fragment in as_slot:
        continue
    checked += 1
    for half in fragment.split(" ... "):
        if half.strip() and half.strip() not in doc:
            missing.append(half.strip())

print("%d checked; %s" % (checked, " | ".join(missing) or "none missing"))
LIMITS

cat > "$work/layertable.py" <<'LAYERS'
"""Read `workers/review.md`'s layer table and measure its own example against its own rule.

The rule is prose a worker obeys, so a grep for the sentence proves only that the sentence is
there. This measures the TABLE: every `--detail` example in it, and every fact's label and value,
against the numbers the prose states. An example that breaks the rule it illustrates is the way
this file has gone wrong before -- a brief that asks for four words and shows nine teaches nine.

A fact is written `Label · `value``, facts separated by ` / `. Rows 2 and 7 carry no fact pairs
on purpose: the store settles layer 2 and nothing writes layer 7, and the cells say so.
"""
import json, pathlib, re, sys

lines = pathlib.Path(sys.argv[1]).read_text().split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("| Layer | Which of your steps |"))
rows = []
for line in lines[start + 2:]:
    if not line.startswith("|"):
        break
    rows.append([c.strip() for c in line.strip().strip("|").split("|")])

details, facts, empty_facts = [], [], []
for row in rows:
    details += [t for t in re.findall(r"`([^`]+)`", row[2])]
    pairs = [p for p in row[3].split(" / ") if " · " in p]
    if not pairs:
        empty_facts.append(row[0])
    facts.append([(p.split(" · ")[0].strip(),
                   p.split(" · ")[1].strip().strip("`")) for p in pairs])

print(json.dumps({
    "rows": len(rows),
    "columns": sorted({len(r) for r in rows}),
    "cells_filled": len([r for r in rows if r[2] and r[3]]),
    "detail_examples": len(details),
    "longest_detail": max([len(d.split()) for d in details] or [0]),
    "over_four": [d for d in details if len(d.split()) > 4],
    "rows_with_facts": len([f for f in facts if f]),
    "rows_without_facts": empty_facts,
    "most_facts_on_one_step": max([len(f) for f in facts] or [0]),
    "longest_fact_label": max([len(l.split()) for f in facts for l, _ in f] or [0]),
    "longest_fact_value": max([len(v.split()) for f in facts for _, v in f] or [0]),
}, sort_keys=True))
LAYERS

cat > "$work/workedexample.py" <<'WORKED'
"""Measure `understand.md`'s worked example against `brief_lint.py`'s own limits.

The example is markdown, so no linter reads it -- and an example that breaks the rule it sits
beside teaches the breach. This reads the two tables the new rules touch (the problems' labels,
and the Solution parts' summaries) and measures them with the linter's own `words` and
`code_names`, so the numbers cannot drift apart from the ones it enforces.
"""
import importlib.util, json, pathlib, sys

spec = importlib.util.spec_from_file_location("brief_lint", sys.argv[2])
bl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bl)

lines = pathlib.Path(sys.argv[1]).read_text().split("\n")


def table(header, column):
    start = next((i for i, l in enumerate(lines) if l.startswith(header)), None)
    if start is None:
        return None
    out = []
    for line in lines[start + 2:]:
        if not line.startswith("|"):
            break
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) > column:
            out.append(cells[column])
    return out


labels = table("| | Label | Marked on |", 1)
# The Solution table draws a part as its title, the one line the row shows, and the summary
# behind it -- so the one line is column 1 and the summary column 2. Both are measured: an
# example whose two columns say the same thing teaches that one of them is spare.
one_lines = table("| Part | One line | Summary | Fixes | Files |", 1)
summaries = table("| Part | One line | Summary | Fixes | Files |", 2)
print(json.dumps({
    "labels": labels,
    "labels_over_3": [l for l in labels or [] if bl.words(l) > bl.LIMIT["problem.label.words"]],
    "parts": len(summaries or []),
    "summaries_over_30": [t for t in summaries or []
                          if bl.words(t) > bl.LIMIT["part.summary.words"]],
    "summaries_with_names": [t for t in summaries or [] if bl.code_names(t)],
    "one_lines": len(one_lines or []),
    "one_lines_over_12": [t for t in one_lines or []
                          if bl.words(t) > bl.LIMIT["part.one_line.words"]],
    "one_lines_with_names": [t for t in one_lines or [] if bl.code_names(t)],
    # A one line that is the summary's own opening clause has cost the reader the second half.
    "one_lines_repeating_summary": [o for o, s in zip(one_lines or [], summaries or [])
                                    if bl.flat(o).strip() in bl.flat(s)],
}, sort_keys=True))
WORKED

brief_md="$root/skills/dispatcher/workers/review.md"
understand_md="$root/skills/review-craft/understand.md"
house_md="$root/skills/review-craft/house-style.md"
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

# `layers <expr> [file]` answers one question about the layer table's own example.
layers () { python3 "$work/layertable.py" "${2:-$brief_md}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)"; }

printf '\n  a step is a line of a map: four words, and the rest on its card\n'
ok "the detail rule states four words"              "$(grep -c '`--detail` is at most 4 words and states the outcome' "$brief_md")" 1
ok "  and nothing anywhere still says eight"        "$(grep -rc 'at most 8 words' "$root/skills" | grep -cv ':0$')" 0
ok "  with a wrong and a right example beside it"   "$(grep -c '| ✓ | `9 options, C built` |' "$brief_md")" 1
ok "  and says why the page cannot take more"       "$(grep -c 'a single line that never wraps' "$brief_md")" 1
ok "the facts rule states all three numbers"        "$(grep -c 'at most 5 of them, each a label of' "$brief_md")" 1
ok "  and says the store enforces neither"          "$(grep -c 'store enforces no length on either' "$brief_md")" 1
ok "  and divides them by kind, not by what fits"   "$(grep -c 'The division is by \*kind\*' "$brief_md")" 1

printf '\n  the layer table obeys the rule it teaches\n'
# The prose above is a sentence; this measures the EXAMPLE. A brief that asks for four words and
# shows nine teaches nine, and nothing but arithmetic over the table catches that.
ok "the table has a row for each of the seven steps" "$(layers "d['rows']")" 7
ok "  every row carrying a detail and its facts"     "$(layers "d['cells_filled']")" 7
ok "  in four columns, all of them"                  "$(layers "d['columns']")" "[4]"
ok "every detail example is four words or fewer"     "$(layers "d['over_four']")" "[]"
ok "  measured, not asserted"                        "$(layers "d['longest_detail'] <= 4 and d['detail_examples'] >= 8")" True
ok "five steps carry facts"                          "$(layers "d['rows_with_facts']")" 5
ok "  and the two that do not are the two nobody writes" "$(layers "d['rows_without_facts']")" "['2 understand', '7 harvest']"
ok "no step carries more than five facts"            "$(layers "d['most_facts_on_one_step'] <= 5")" True
ok "every fact label is three words or fewer"        "$(layers "d['longest_fact_label'] <= 3")" True
ok "every fact value is six words or fewer"          "$(layers "d['longest_fact_value'] <= 6")" True
ok "  and the table says every example is invented"  "$(grep -c 'Every example in that table is invented' "$brief_md")" 1

printf '\n  a step\x27s facts replace, so they are written once\n'
ok "the brief says the option replaces the list"    "$(grep -c 'the option replaces the whole list' "$brief_md")" 1
ok "  naming the one rule it breaks"                "$(grep -c 'stops being true' "$brief_md")" 1
ok "  with the measurement, five against one"       "$(grep -c 'left that step with one fact' "$brief_md")" 1
ok "  and a row per thing a call can say"           "$(grep -c '^| no fact option at all | the facts it already had' "$brief_md")" 1
ok "  including the one that empties it"            "$(grep -c '^| the clear option | none |' "$brief_md")" 1
ok "  so the facts go in the call that finishes"    "$(grep -c 'once the step is done and you know all of them' "$brief_md")" 1
ok "  and progress loses nothing"                   "$(grep -c 'and loses nothing' "$brief_md")" 1

printf '\n  a field DEV-917 adds is sent only where it is taken\n'
ok "the brief probes the command, not the version"  "$(grep -c 'Probe the command, never the version number' "$brief_md")" 1
ok "  with the command that answers it"             "$(grep -c 'review-desk layer set --help' "$brief_md")" 1
ok "  reading the option name off that help"        "$(grep -c "Read the option's own name off that help" "$brief_md")" 1
ok "  and carries on without it, silently"          "$(grep -c 'say nothing about it to anyone' "$brief_md")" 1
ok "  because a review must still be prepared"      "$(grep -c 'never fail to be prepared because a field is' "$brief_md")" 1
ok "  and the version string cannot answer it"      "$(grep -c 'The version number cannot answer this' "$brief_md")" 1
ok "  measured: both builds print the same version" "$(grep -c 'both print' "$brief_md")" 1
ok "a source document refused for the two fields is retried" "$(grep -c 'drop those two' "$brief_md")" 1

printf '\n  write 1 says why in one clause\n'
ok "the reason is one short clause"                 "$(grep -c 'It is one short clause' "$brief_md")" 1
ok "  and the whole of it is given"                 "$(grep -c '| ✓ | `problem half only — the full brief follows at step 5` |' "$brief_md")" 1
ok "  with the long version as the wrong example"   "$(grep -c 'A 52-word reason restating' "$brief_md")" 1

printf '\n  a source is a reference, a state and a line\n'
ok "the brief has one section for them"             "$(grep -c '^### Where the understanding came from$' "$brief_md")" 1
ok "  naming the command that writes them"          "$(grep -c 'provenance sources --review <id> --file' "$brief_md")" 1
ok "  the label is the reference alone"             "$(grep -c '\*\*the reference alone\*\*' "$brief_md")" 1
ok "  the note is at most 12 words"                 "$(grep -c '| `note` | what it tells us | at most 12 words |' "$brief_md")" 1
ok "  the ticket's state goes in status"            "$(grep -c "the ticket's state as you read it" "$brief_md")" 1
ok "  and the code is not a source at all"          "$(grep -c 'The code is not a source, and there is no kind for it' "$brief_md")" 1
ok "  which is where the commit went instead"       "$(grep -c 'the code at `a1b2c3d`' "$brief_md")" 1
ok "and step 2 names the command"                   "$(grep -c 'for what you read it \*from\*' "$brief_md")" 1

printf '\n  the three writing rules understand.md owns\n'
ok "the Problems slot says in flow order"           "$(grep -c '^| \*\*Problems\*\* | What is wrong, numbered \*\*in the order the before flow meets them\*\*' "$understand_md")" 1
ok "  and Label is a slot of its own"               "$(grep -c '^| \*\*Label\*\* |' "$understand_md")" 1
ok "  with its number in the slot"                  "$(grep -c 'At most 3 words' "$understand_md")" 1
ok "the Parts slot carries the summary's cap"       "$(grep -c 'at most 30 words carrying no class name, path or `::`' "$understand_md")" 1
ok "  and the one-line form's, beside it"           "$(grep -c 'a `one_line` of at most 12 plain words' "$understand_md")" 1
ok "rule 5 is the numbering and the label"          "$(grep -c '^\*\*5 · A problem is numbered where the before flow first meets it' "$understand_md")" 1
ok "  and says flow order is not sufficient"        "$(grep -c 'Flow order is necessary and is not sufficient' "$understand_md")" 1
ok "rule 6 is the part's summary"                   "$(grep -c "^\*\*6 · A part's summary is one plain line" "$understand_md")" 1
ok "rule 7 is the part's one-line form"             "$(grep -c '^\*\*7 · Every part also carries a one-line form' "$understand_md")" 1
ok "  saying it is not the summary shortened"       "$(grep -c 'It is not the summary shortened' "$understand_md")" 1
ok "  and sending the names where rule 6 does"      "$(grep -c 'the names go where rule 6 already' "$understand_md")" 1
ok "the worked example labels every problem"        "$(grep -c '^| 1 | One transaction | the second row |' "$understand_md")" 1
ok "  and gives every part both its lines"          "$(grep -c '^| Part | One line | Summary | Fixes | Files |' "$understand_md")" 1
# Measured against the linter's own limits, not grepped. An example that breaks the rule it sits
# beside teaches the breach, and nothing reads the example because it is markdown.
worked () { python3 "$work/workedexample.py" "${2:-$understand_md}" \
    "$root/skills/review-craft/brief_lint.py" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)"; }
ok "  three labels, every one inside its limit"     "$(worked "[len(d['labels']), d['labels_over_3']]")" "[3, []]"
ok "  seven part summaries, every one inside its"   "$(worked "[d['parts'], d['summaries_over_30']]")" "[7, []]"
ok "  and not one of them naming code"              "$(worked "d['summaries_with_names']")" "[]"
ok "  seven one-line forms, every one inside its"   "$(worked "[d['one_lines'], d['one_lines_over_12']]")" "[7, []]"
ok "  and not one of those naming code either"      "$(worked "d['one_lines_with_names']")" "[]"
ok "  nor repeating the summary beside it"          "$(worked "d['one_lines_repeating_summary']")" "[]"

printf '\n  the two rules house-style.md owns\n'
ok "a finding's title is at most 12 words"          "$(grep -c '\*\*A title is at most 12 words, and it is not the claim' "$house_md")" 1
ok "  and DEV-891's own title still fits it"        "$(python3 -c "
import re
t = 'a correction that throws after the reopen strands the invoice OPEN'
doc = open('$house_md').read()
print(len(t.split()) <= 12 and doc.count(t) == 3)")" True
ok "backticks hold in every prose field"            "$(grep -c 'This holds in every prose field a session writes' "$house_md")" 1
ok "  and the fields that carry no name are named"  "$(grep -c "a brief's top layer, and a part's two lines" "$house_md")" 1

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
ok "  and every served field is poured somewhere"   "$(ask "d['pour_unpoured']")" "[]"
ok "  over five rows, one per served field"         "$(ask "len(d['pour_sections'])")" 5
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
  "problems": [{"number": 1, "label": "A second delivery",
                "was_wrong": "A retry arrives as a second delivery."},
               {"number": 2, "label": "No record",
                "was_wrong": "Nothing records that it was a retry."}],
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
    "parts": [{"title": "The key, stored per event",
               "one_line": "A retry reuses the key the first delivery carried.",
               "summary": "The event gets a key when it is first posted, and every retry of it "
                          "carries the same one, so the receiver can tell a repeat from a new "
                          "order.",
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
ok "  and the brief reads that as a Review Desk too old" "$(grep -c 'older than the field\*\*, not a broken' "$brief_md")" 1
ok "  reading how much older out of the refusal"    "$(grep -c 'how much older is in the refusal' "$brief_md")" 1
ok "  one field behind: drop it and write again"    "$(grep -c 'drop that one field and write again' "$brief_md")" 1
ok "  older than the brief: the five old fields"    "$(grep -c 'older than the structured brief itself' "$brief_md")" 1
ok "  and the cases are not to be confused"        "$(grep -c 'Do not read one of the first two as the third' "$brief_md")" 1
ok "  with the list read for the field's own level" "$(grep -c 'the list for the level the field sits at' "$brief_md")" 1
ok "  both refusal shapes quoted, nested and top"  "$(grep -c 'unknown field .blind_pass_state., expected one of' "$brief_md")" 1
ok "  with the measured example that forced it"     "$(grep -c 'dropping .label. from the' "$brief_md")" 1

# `parts[].one_line` is the live example of that table's FIRST row, and the one a worker now
# meets at step 5 rather than at write 1. The stand-in's part member list is master's, so
# `pre919` is a Review Desk from before DEV-919 and the default is one with it. This is not a
# second reading of the refusal: it is the same reading, driven over a part.
echo '{"lens":"l","severity":"should","claim":"c"}' \
  | review-desk finding add --review 6 --file - > /dev/null
echo pre919 > "$work/rd.parts"
ok "a part field an older install lacks is refused"  "$(rc brief put --review 6 --file "$work/full.json")" 1
ok "  naming the part's own members and no others"   "$(grep -c "unknown field .one_line., expected one of .title., .summary., .fixes., .files." "$work/err")" 1
ok "  so it is not read as the brief being older"    "$(grep -c 'flow_before' "$work/err")" 0
python3 - "$work/full.json" "$work/nooneline.json" <<'DROP'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
for part in doc["parts"]:
    part.pop("one_line")
pathlib.Path(sys.argv[2]).write_text(json.dumps(doc))
DROP
ok "  and the same document without it is accepted"  "$(rc brief put --review 6 --file "$work/nooneline.json")" 0
ok "  with every other field of the part kept"       "$(python3 "$work/partkeys.py" "$work/rd.brief.6.json")" "['files', 'fixes', 'summary', 'title']"
ok "  which is what the brief says to do"            "$(grep -c 'drop .one_line. from every part and' "$brief_md")" 1
ok "  and it says to keep writing the field"         "$(grep -c 'Write the field$' "$brief_md")" 1
rm -f "$work/rd.parts"
ok "an install that has the field stores it whole"   "$(rc brief put --review 6 --file "$work/full.json")" 0
ok "  one line on the part, beside its summary"      "$(python3 "$work/partkeys.py" "$work/rd.brief.6.json")" "['files', 'fixes', 'one_line', 'summary', 'title']"
ok "  and the brief names the field in its table"    "$(grep -c '| \*\*Parts\*\* | `parts\[\].title`, `.one_line`, `.summary`' "$brief_md")" 1

printf '\n  the brief is linted before it is sent, and never before that\n'
# The first two assertions RUN the linter over the two documents this harness built, which is
# the whole point: review.md tells a worker to write a brief that passes it, and the document
# the brief's own tables prescribe is the one being measured. The rest assert what review.md
# tells a worker to run and when.
lint () { set +e; python3 "$root/skills/review-craft/brief_lint.py" "$@" > "$work/lint" 2>&1
          echo $?; set -e; }
ok "the whole brief this harness built passes the linter" "$(lint "$work/full.json")" 0
ok "  on every one of its rules"                    "$(sed -n 's|^\([0-9]*\)/\1 checks passed$|all|p' "$work/lint")" all
ok "the problem half does NOT pass it"              "$(lint "$work/half.json")" 1
# `^FAIL  [a-z]` is the rule rows; the linter's closing verdict line is `FAIL — ...` and
# counting it made four failures read as five.
ok "  failing the four the brief names, and no more" "$(grep -c '^FAIL  [a-z]' "$work/lint")" 4
ok "  which are the change half, every one"         "$(grep '^FAIL  [a-z]' "$work/lint" | awk '{print $2}' | sort | tr '\n' ' ')" "headline.present picture.after problems.marked_after problems.now_line "
ok "every quotation --limits makes of understand.md is in it" "$(python3 "$work/limitslots.py" \
    "$root/skills/review-craft/brief_lint.py" "$understand_md")" "11 checked; none missing"
ok "the linter is named for write 2"                "$(grep -c 'Write 2 is linted before it is sent' "$brief_md")" 1
ok "  with the command a worker can run"            "$(grep -c 'brief_lint.py' "$brief_md")" 4
ok "  and step 6 checks before it shows"            "$(grep -c 'Check it, then show your principal' "$brief_md")" 1
ok "write 1 is explicitly NOT linted"               "$(grep -c 'Do not lint write 1' "$brief_md")" 1
# The number in the prose, crossed against the run three assertions above. The first version
# pinned 6, a count off a malformed fixture that the sentence's own list contradicted; it is 4,
# and now a document that drifts fails the run rather than only the grep.
ok "  with the count it would fail by"              "$(grep -c '4 of its 24 checks fail' "$brief_md")" 1
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
printf '\nDEV-945 -- the request is recorded the moment the poller sees it\n'
# Review Desk heard nothing about a review request until a session ran `review open`, so it
# could not say how many requests came in or which were never started. These assertions are
# about the GitHub source, which is why they are the first in this file to put a row in the
# search page: `$RDWORK/gh.search`, through the real `gh()` wrapper.

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "a request GitHub shows exits clean"                "$rc" 0
ok "  and is emitted as a review_request"              "$(count '"event": "review_request"')" 1
ok "  and is recorded in Review Desk"                  "$(opens)" 1
ok "  with the repository, pull request, head and ledger" "$(last_open)" \
  "review open --repo acme/portal --pr 412 --head sha412 --title Retry --ledger gh-portal-412 --json"
ok "  the ledger id is this instance's own key"        "$(grep -c '^gh-portal-412$' "$work/rd.open.argv")" 1
ok "  and no ticket is invented for it"                "$(grep -c '^--ticket$' "$work/rd.open.argv")" 0

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 "Retry failed webhook deliveries"
rc=$(run "$disp" poll 1)
ok "a title with spaces is ONE argument"               "$(grep -c '^Retry failed webhook deliveries$' "$work/rd.open.argv")" 1

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 -
rc=$(run "$disp" poll 1)
ok "a row with no title is still recorded"             "$(opens)" 1
ok "  and --title is not passed empty"                 "$(grep -c '^--title$' "$work/rd.open.argv")" 0

# The ordering the ticket is actually about: the record exists before anybody could have been
# dispatched. One file, so this is a comparison of line numbers rather than of two logs.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll_order)
first_open=$(grep -n '^review open ' "$work/rd.calls" | head -1 | cut -d: -f1)
first_said=$(grep -n '^emit review_request$' "$work/rd.calls" | head -1 | cut -d: -f1)
ok "the recording happens BEFORE the request is emitted" "$([ -n "$first_open" ] && [ -n "$first_said" ] && [ "$first_open" -lt "$first_said" ] && echo yes || echo no)" yes

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
put gh-portal-412 mode=review status=active repo=acme/portal number=412 session_id=live-9 --by test
session live-9
rc=$(run "$disp" poll 1)
ok "a request a live session holds is NOT recorded"    "$(opens)" 0
no_sessions

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 --by test
rc=$(run "$disp" poll 1)
ok "a request whose session was lost IS recorded"      "$(opens)" 1

# **Recorded, dispatched, then the author pushes.** The sequence DEV-945's other half asked for:
# once a session is linked, `review open` on a new commit starts a round rather than moving the
# request, so a poller that went on recording would spend a round nobody asked for -- and
# `work list` would offer that round as a request of its own.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
put gh-portal-412 mode=review status=active repo=acme/portal number=412 session_id=live-2 --by dispatcher
link acme/portal 412 live-2
session live-2
search_doc acme/portal 412 sha999 Retry
rc=$(run "$disp" poll 1)
ok "a push on a dispatched request records nothing"    "$(opens)" 1
ok "  and dispatches nothing"                          "$(count '"event": "review_request"')" 0
ok "  the review stays on its round"                   "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 1
no_sessions

# And the same when the LEDGER cannot say it: this entry carries no `session_id` -- a hand-written
# `lost` with none, which is also what a dashboard-started review looks like here -- so the guard
# doing the work is the session Review Desk itself reports on the review. The two together are
# why there are two tests: the ledger is immediate, and this one covers what it does not know.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
link acme/portal 412 dead-1
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 --by test
rc=$(run "$disp" poll 1)
ok "the session on the review is remembered"           "$(remembered gh-portal-412 session)" dead-1
search_doc acme/portal 412 sha999 Retry
age_marker 'gh-portal-412|review_request'
rc=$(run "$disp" poll 1)
ok "a push on a lost session's review spends no round" "$(opens)" 1
ok "  and the request is still offered for dispatch"   "$(count '"event": "review_request"')" 1

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 3)
ok "three ticks on one commit record once"             "$(opens)" 1
ok "  and the state remembers the commit"              "$(remembered gh-portal-412 head)" sha412
ok "  and the review it recorded"                      "$(remembered gh-portal-412 review)" 1
ok "  which it does not think dismissed"               "$(remembered gh-portal-412 dismissed)" False

# A new commit on a request nobody started MOVES it in Review Desk, which is why the mark is
# the pair and not the key: a dispatcher that recorded once per key would leave the record
# pointing at a commit the author has replaced.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
search_doc acme/portal 412 sha999 Retry
rc=$(run "$disp" poll 1)
ok "a new head commit is recorded again"               "$(opens)" 2
ok "  on the new commit"                               "$(last_open)" \
  "review open --repo acme/portal --pr 412 --head sha999 --title Retry --ledger gh-portal-412 --json"
ok "  and the review did not move round"               "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 1

# The commit is remembered as GITHUB spelled it, which is the side the next tick compares. A
# head GitHub gave in upper case is still one recording: Review Desk lower-cases what it stores,
# so a dispatcher that remembered the answer rather than the question would see its own record
# disagree with the search on every tick and write to the store on every tick.
instance '{"mode":"auto"}'
search_doc acme/portal 412 SHA412UPPER Retry
rc=$(run "$disp" poll 3)
ok "a head GitHub spells in upper case records once"   "$(opens)" 1
ok "  remembered as GitHub spelled it"                 "$(remembered gh-portal-412 head)" SHA412UPPER
ok "  and Review Desk stored its own form"             "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["head"])' "$work/rd.opens.json")" sha412upper

printf '\n  a Review Desk that is off, absent, broken or older\n'

instance '{"mode":"off"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "off records nothing"                               "$(opens)" 0
ok "  and says nothing about review_desk"              "$(count review_desk)" 0
ok "  and still emits the request"                     "$(count '"event": "review_request"')" 1

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
hide
rc=$(run "$disp" poll 1)
ok "an absent Review Desk exits clean"                 "$rc" 0
ok "  records nothing"                                 "$(opens)" 0
ok "  adds no notice under auto"                       "$(count review_desk_unavailable)" 0
ok "  and still emits the request"                     "$(count '"event": "review_request"')" 1
show

instance '{"mode":"on"}'
search_doc acme/portal 412 sha412 Retry
hide
rc=$(run "$disp" poll 1)
ok "under \`on\` an absent one is loud exactly once"     "$(count '"event": "review_desk_unavailable"')" 1
ok "  which is the notice this file already had"       "$(says '"state": "absent"')" yes
show

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo broken > "$work/rd.mode"
rc=$(run "$disp" poll 1)
ok "a broken Review Desk exits clean"                  "$rc" 0
ok "  nothing is recorded"                             "$(recorded_count)" 0
ok "  and the notice is still one notice"              "$(count '"event": "review_desk_unavailable"')" 1

# Broken on one tick, mended on the next. The mark is written only when the call succeeded, so
# an install that is fixed is used on the very next poll -- the rule the rest of this file keeps
# for READING Review Desk, kept here for writing to it.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo broken > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "a \`review open\` that fails records nothing"        "$(recorded_count)" 0
echo ok > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "  and is tried again on the next tick"             "$(opens)" 2
ok "  which records it"                                "$(remembered gh-portal-412 head)" sha412

# One install answers for every request, so an absent or broken one is asked ONCE a tick. At a
# 30s timeout the alternative is one stalled tick per page of requests.
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo broken > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "two requests and a broken \`review open\`: asked once" "$(opens)" 1
echo ok > "$work/rd.open.mode"
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
rc=$(run "$disp" poll 1)
ok "  where a working one records both"                "$(opens)" 2

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo oldledger > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "an older Review Desk refusing --ledger exits clean" "$rc" 0
ok "  is retried once, without the flag"               "$(opens)" 2
ok "  and the second call carries no ledger id"        "$(last_open)" \
  "review open --repo acme/portal --pr 412 --head sha412 --title Retry --json"
ok "  the request is recorded all the same"            "$(remembered gh-portal-412 head)" sha412
ok "  and nothing extra is said about it"              "$(count review_desk_unavailable)" 0

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo refused > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "a refusal that is not about the flag is not retried" "$(opens)" 1
ok "  records nothing"                                 "$(recorded_count)" 0
# Said, and said once: no other voice covers a refusal of ONE recording, and a refusal that
# repeats would otherwise leave the Reviews page reading "no requests came in".
ok "  is reported once"                                "$(count '"event": "review_desk_unavailable"')" 1
ok "  as a refusal"                                    "$(says '"state": "refused"')" yes
ok "  naming the pull request"                         "$(says '"number": 412')" yes
ok "  and Review Desk's own words"                     "$(says 'no repository acme/portal')" yes
rc=$(run "$disp" poll 2)
ok "  and not again inside the window"                 "$(count '"event": "review_desk_unavailable"')" 0
ok "  though the recording is tried each tick"         "$(opens)" 3

# A refusal is almost never about one request: a store that does not know the repository refuses
# every request in it. One voice per repository, naming one of them as an example.
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo refused > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "two refusals in one repository are one notice"     "$(count '"event": "review_desk_unavailable"')" 1
ok "  which says the request it names is an example"   "$(says '"example": true')" yes
ok "  and both were still attempted"                   "$(opens)" 2

# A build with no `review show`: the answer is about the BUILD, so it is asked once a tick rather
# than once per recorded request, and recording itself carries on.
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
rc=$(run "$disp" poll 1)
echo oldshow > "$work/rd.show.mode"
rc=$(run "$disp" poll 1)
ok "a build with no \`review show\` is asked once a tick" "$(shows)" 1
rc=$(run "$disp" poll 1)
ok "  and once on the next tick, not once per request" "$(shows)" 2

# JSON that parses and is not an object. Every other strange answer here is called broken, said
# once and dispatched around; this one used to be an AttributeError in the middle of the tick,
# which would have emitted no review request at all.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo notobject > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "an answer that is not an object exits clean"       "$rc" 0
ok "  throws nothing"                                  "$(count '"event": "error"')" 0
ok "  records nothing"                                 "$(recorded_count)" 0
ok "  and the request is still emitted"                "$(count '"event": "review_request"')" 1

printf '\n  an instance the reading pass asks nothing for\n'
# `review_desk_repos` answers nothing for an instance whose map is unedited and whose ledger is
# empty, so the `review_desk` pass returns before probing anything -- and "broken is loud in
# every mode but off" had nothing to be loud about. The recording path now runs on that
# instance, so the fact exists, and exactly one voice says it.
NOMAP=1 instance '{"mode":"on"}'
search_doc acme/portal 412 sha412 Retry
echo broken > "$work/rd.mode"
rc=$(run "$disp" poll 1)
ok "a broken install is loud with no repositories"     "$(count '"event": "review_desk_unavailable"')" 1
ok "  naming it broken"                                "$(says '"state": "broken"')" yes
ok "  and exits clean"                                 "$rc" 0
NOMAP=1 instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
hide
rc=$(run "$disp" poll 1)
ok "an absent one stays silent under auto"             "$(count review_desk_unavailable)" 0
show
NOMAP=1 instance '{"mode":"on"}'
search_doc acme/portal 412 sha412 Retry
hide
rc=$(run "$disp" poll 1)
ok "  and is loud under \`on\`, once"                   "$(count '"event": "review_desk_unavailable"')" 1
show
# With a repository to ask about, BOTH paths meet the same broken install and it is still one
# line: they share the event, the mode rule and the rate-limit mark.
instance '{"mode":"on"}'
search_doc acme/portal 412 sha412 Retry
echo broken > "$work/rd.mode"
rc=$(run "$disp" poll 1)
ok "with repositories it is still one notice"          "$(count '"event": "review_desk_unavailable"')" 1

printf '\n  one request reaches the Dispatcher once\n'
# A recorded request IS `review_requested` on `work list`, so without these three guards the
# same request arrives as `review_request` from GitHub and `review_desk_requested` from Review
# Desk in one tick, and two sessions could land on one review.

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
rc=$(run "$disp" poll 1)
ok "a request GitHub showed is emitted once"           "$(count '"event": "review_request"')" 1
ok "  and not a second time by Review Desk"            "$(count '"event": "review_desk_requested"')" 0

# The same, with a ledger entry on the key, which is what tells THIS guard apart from the
# no-such-entry one below: a review whose session was lost is work either source may name, and
# the only thing stopping it being named twice is that GitHub named it first.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 --by test
rc=$(run "$disp" poll 1)
ok "a lost review GitHub still requests is emitted once" "$(count '"event": "review_request"')" 1
ok "  and not a second time by Review Desk"            "$(count '"event": "review_desk_requested"')" 0

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
put gh-portal-412 mode=review status=skipped repo=acme/portal number=412 --by principal
rc=$(run "$disp" poll 1)
ok "a skipped request is recorded"                     "$(opens)" 1
ok "  and offered to nobody"                           "$(count '"event": "review_desk_requested"')" 0
ok "  nor emitted as a request"                        "$(count '"event": "review_request"')" 0

# The same skip with GitHub silent, which is the shape that outlives the request: the poller's
# own row stays on the work list for ever until the developer dismisses it.
instance '{"mode":"auto"}'
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
put gh-portal-412 mode=review status=skipped repo=acme/portal number=412 --by principal
rc=$(run "$disp" poll 1)
ok "a skipped request GitHub no longer shows stays quiet" "$(count '"event": "review_desk_requested"')" 0

instance '{"mode":"auto"}'
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
rc=$(run "$disp" poll 1)
ok "a recorded request with no ledger entry is not offered" "$(count '"event": "review_desk_requested"')" 0
# The control, and without it the assertion above would pass for a dispatcher that had simply
# stopped dispatching from Review Desk: a review the DASHBOARD opened carries no ledger id, and
# it must still reach a session.
instance '{"mode":"auto"}'
work_doc review_requested 11 acme/portal 412
rc=$(run "$disp" poll 1)
ok "  where a dashboard review still is"               "$(count '"event": "review_desk_requested"')" 1

# **A repository GitHub spells with capitals.** The two sources key the same pull request
# differently — GitHub's `nameWithOwner` as registered, Review Desk's `repo` lower-cased — so
# this is the case where comparing the keys as strings misses and both sources speak. No ledger
# id on the item, because that is the shape where `review_desk_item` has to derive the key.
instance '{"mode":"auto"}'
search_doc Acme/Portal 412 sha412 Retry
work_doc review_requested 11 acme/portal 412
rc=$(run "$disp" poll 1)
ok "a mixed-case repository is recorded once"          "$(opens)" 1
ok "  the request is emitted once"                     "$(count '"event": "review_request"')" 1
ok "  and Review Desk does not offer it again"         "$(count '"event": "review_desk_requested"')" 0

# A lost session's review, which carries a ledger id AND an entry: still work, and the one case
# that tells the ledger-entry test apart from a test on the ledger id alone.
instance '{"mode":"auto"}'
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 --by test
rc=$(run "$disp" poll 1)
ok "  and so is one whose session was lost"            "$(count '"event": "review_desk_requested"')" 1

# The other four kinds are about a review in progress, and GitHub goes on showing the request
# for the whole of it. None of the three guards may touch them.
for kind in brief_settled draft_sent_back draft_approved nits_to_ticket; do
  instance '{"mode":"auto"}'
  search_doc acme/portal 412 sha412 Retry
  work_doc "$kind" 11 acme/portal 412 1791520282 gh-portal-412
  echo '{"state":"OPEN"}' > "$work/pr.412.json"
  rc=$(run "$disp" poll 1)
  ok "a requested PR still relays $kind"               "$(count '"event": "review_desk_resume"')" 1
done

printf '\n  a review the developer dismissed is not dispatched\n'
# review-desk 5dae8f6. A dismissal is the dashboard's API and has no command line at all, which
# is why `dismiss` above edits the stand-in's store directly: there is no command for this file
# to call even if it wanted one. Review Desk's own `work list` already leaves a dismissed review
# out, so this is the GITHUB source being told -- GitHub goes on requesting the review, because
# dismissing is not withdrawing.

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "an undismissed request is dispatched as before"    "$(count '"event": "review_request"')" 1
dismiss acme/portal 412 "the pull request was closed unmerged"
rc=$(run "$disp" poll 2)
ok "once dismissed, the request is read not opened"    "$(shows)" 1
ok "  and no request is emitted for it"                "$(count '"event": "review_request"')" 0
ok "  the dismissal is said once"                      "$(count '"event": "review_dismissed"')" 1
ok "  naming the review"                               "$(says '"review_desk_id": 1')" yes
ok "  and the developer's reason"                      "$(says 'the pull request was closed unmerged')" yes
ok "  with the page it is on"                          "$(says 'reviews/1')" yes
ok "  and the state remembers it"                      "$(remembered gh-portal-412 dismissed)" True
rc=$(run "$disp" poll 1)
ok "a later tick says nothing and dispatches nothing"  "$(( $(count '"event": "review_dismissed"') + $(count '"event": "review_request"') ))" 0

# The other way the dismissal arrives: the author pushes BEFORE anything here knows about the
# dismissal, so the request is recorded again and `review open`'s own answer carries it.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
dismiss acme/portal 412 "a duplicate of 411"
search_doc acme/portal 412 sha999 Retry
rc=$(run "$disp" poll 1)
ok "a push before it is known records again"           "$(opens)" 2
ok "  on the new commit"                               "$(remembered gh-portal-412 head)" sha999
ok "  it is still dismissed"                           "$(remembered gh-portal-412 dismissed)" True
ok "  said once, with that reason"                     "$(count 'a duplicate of 411')" 1
ok "  and nothing is dispatched"                       "$(count '"event": "review_request"')" 0
ok "  without reading the review as well"              "$(shows)" 0

# And once it IS known, a push does not reach it at all. `review open` would move a dismissed
# review's head -- Review Desk allows it -- but it writes, on a row the developer took out of
# play, which is the `last_activity_at` harm this file keeps arranging itself to avoid.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$disp" poll 1)
ok "the dismissal is known"                            "$(remembered gh-portal-412 dismissed)" True
search_doc acme/portal 412 sha999 Retry
rc=$(run "$disp" poll 1)
ok "a push on a known dismissal writes nothing"        "$(opens)" 1
ok "  the record still names the commit it was told"   "$(remembered gh-portal-412 head)" sha412
ok "  and still dispatches nothing"                    "$(count '"event": "review_request"')" 0
# Restored, with the author's commit still ahead of the record: the two are out of step, and the
# very next tick is where moving it belongs.
restore acme/portal 412
age_marker 'review_desk|dismissal|gh-portal-412'
age_marker 'gh-portal-412|review_request'
# TWO ticks, and the order is the behaviour: the first learns the restore and dispatches the
# request, the second sees the record and the search disagree about the commit and moves it.
rc=$(run "$disp" poll 2)
ok "a restore dispatches the request again"            "$(count '"event": "review_request"')" 1
ok "  and the next tick moves it to the new commit"    "$(remembered gh-portal-412 head)" sha999
ok "  which is one write, now that it is wanted"       "$(opens)" 2

# Restored. The read is on `reemit_after_secs`, which is the cadence everything else in this
# file re-asks on, so the clock is moved rather than waited out.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$disp" poll 1)
ok "a dismissed request stops the dispatch"            "$(count '"event": "review_request"')" 0
restore acme/portal 412
rc=$(run "$disp" poll 1)
ok "  and a restore is not seen before it is asked for" "$(count '"event": "review_request"')" 0
age_marker 'review_desk|dismissal|gh-portal-412'
# And the re-emission clock, which is a different one: the request was emitted before it was
# dismissed, and `reemit_after_secs` governs saying it again whatever happened in between.
age_marker 'gh-portal-412|review_request'
rc=$(run "$disp" poll 1)
ok "a restored request is dispatched again"            "$(count '"event": "review_request"')" 1
ok "  and the state no longer calls it dismissed"      "$(remembered gh-portal-412 dismissed)" False
# Dismissed a second time: a new decision about the same request, so it is said again.
dismiss acme/portal 412 "closed again"
age_marker 'review_desk|dismissal|gh-portal-412'
rc=$(run "$disp" poll 1)
ok "a second dismissal is said again"                  "$(count '"event": "review_dismissed"')" 1
ok "  with the second reason"                          "$(says 'closed again')" yes

# A Review Desk older than the dismissal field answers without the two keys, which reads as not
# dismissed -- which is exactly how this behaved before dismissal existed.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "no dismissal field at all is not a dismissal"      "$(remembered gh-portal-412 dismissed)" False
ok "  and the request is dispatched"                   "$(count '"event": "review_request"')" 1

# A review that is GONE: the developer deleted one that never started. Forgotten rather than
# remembered as missing, so the next tick records the request again from GitHub.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
echo refused > "$work/rd.show.mode"
rc=$(run "$disp" poll 1)
ok "a deleted review is forgotten"                     "$(recorded_count)" 0
echo ok > "$work/rd.show.mode"
age_marker 'gh-portal-412|review_request'
rc=$(run "$disp" poll 1)
ok "  and the request is recorded again"               "$(opens)" 2
ok "  and still dispatched"                            "$(count '"event": "review_request"')" 1

# A build with no `review show` at all refuses it as a usage error, which must not be read as a
# review that is gone: forgetting the record would send every tick back to `review open`, and
# that writes.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
echo oldshow > "$work/rd.show.mode"
rc=$(run "$disp" poll 2)
ok "a build with no \`review show\` is not a deleted review" "$(remembered gh-portal-412 head)" sha412
ok "  so nothing is recorded again"                    "$(opens)" 1
ok "  and the request is still dispatched"             "$(remembered gh-portal-412 dismissed)" False

# A read that failed does not spend the window: `due` writes its marker when it is evaluated,
# so without clearing it a Review Desk broken for one tick would put the next read fifteen
# minutes away -- and a dismissal made in between would be dispatched for all of it.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
echo broken > "$work/rd.show.mode"
rc=$(run "$disp" poll 1)
ok "a read that failed is asked again next tick"       "$(shows)" 1
echo ok > "$work/rd.show.mode"
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$disp" poll 1)
ok "  without waiting out the interval"                "$(shows)" 2
ok "  and the dismissal is then honoured"              "$(remembered gh-portal-412 dismissed)" True

# A dismissal is held nowhere else, so the prune that follows a tick GitHub answered empty must
# not take it: the next tick that saw the request would go back to `review open`, which WRITES,
# on a record the developer took out of play.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$disp" poll 1)
rm -f "$work/gh.search"
# TWO ticks, because one zero is not believed: `trust_empty` commits an empty result only on the
# second consecutive one, so a single empty tick never reaches the prune and this assertion
# would pass without the prune keeping anything. It did, in the first draft of it.
rc=$(run "$disp" poll 2)
ok "two empty ticks prune, and keep the dismissal"     "$(remembered gh-portal-412 dismissed)" True
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "  so the request is not written again"             "$(opens)" 1
ok "  and is still not dispatched"                     "$(count '"event": "review_request"')" 0

# A read that cannot be made leaves the dismissal where it was. Not knowing is not a restore.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$disp" poll 1)
echo broken > "$work/rd.show.mode"
age_marker 'review_desk|dismissal|gh-portal-412'
rc=$(run "$disp" poll 1)
ok "a broken read leaves the dismissal standing"       "$(remembered gh-portal-412 dismissed)" True
ok "  and still dispatches nothing"                    "$(count '"event": "review_request"')" 0
ok "  and exits clean"                                 "$rc" 0

printf '\n  what the Dispatcher is told about all this\n'
ok "SKILL.md says a request is recorded on sight"      "$(grep -c 'recorded the moment your poller sees it' "$skill_md")" 1
ok "  that dispatching is unchanged"                   "$(grep -c 'Nothing changes about dispatching' "$skill_md")" 1
ok "  that one request still reaches it once"          "$(grep -c 'One request still reaches you once' "$skill_md")" 1
ok "  that a dismissed review is not dispatched"       "$(grep -c 'dismissed is not dispatched' "$skill_md")" 1
ok "  and that a linked session stops the recording"   "$(grep -c 'any session has been linked to is left alone' "$skill_md")" 1
ok "  and names the event, in prose and as a row"      "$(grep -c 'review_dismissed' "$skill_md")" 2
ok "  that dismiss, restore and delete are the developer's" "$(grep -c "are your principal.s, from the page" "$skill_md")" 1
ok "  with no command line for any of them"            "$(grep -c 'no command line for any of them' "$skill_md")" 1
ok "  and it tells nobody to dispatch a dismissed one" "$(grep -c 'do not offer to dispatch it' "$skill_md")" 1

printf '\n  only the developer signs off\n'
ok "nothing in the dispatcher dismisses, deletes, restores or approves" \
   "$(grep -cE '"(dismiss|delete|restore|approve)"' "$disp")" 0
ok "  and the only commands it runs of Review Desk are these" \
   "$(grep -o 'review_desk_run(rd, [^,)]*' "$disp" | sed 's/.*run(rd, //' | sort -u | tr '\n' ' ')" \
   '"--version" "db" "draft" "harvest" "review" "work" *facts '
ok "  where \`facts\` is \`review open\` and nothing else"  "$(grep -c '"review", "open", "--repo"' "$disp")" 1
ok "  and the only \`review\` it reads with is \`show\`"    "$(grep -c '"review", "show", "--review"' "$disp")" 1

# =============================================================================================
printf '\nNegative controls -- reverse each guard and require these tests to fail\n'
# Without these, every assertion above could be passing for a reason unrelated to the behaviour.
# Each substitution is counted rather than assumed: a sed that matched nothing would turn a
# control into a second copy of the test it is controlling.

sed 's/^        if review_desk_live(live, entry) and not self\.cannot_be_told(kind, key, entry):$/        if False:  # LIVENESS REVERSED/' \
    "$disp" > "$work/nolive.py"
ok "the liveness reversal changed one line"            "$(grep -c 'LIVENESS REVERSED' "$work/nolive.py")" 1
instance '{"mode":"auto"}'
work_doc draft_approved 5 acme/portal 416 1791520400 gh-portal-416
put gh-portal-416 mode=review status=active repo=acme/portal number=416 session_id=live-1 --by test
session live-1
rc=$(run "$work/nolive.py" poll 1)
ok "no liveness: a live session gets a second one"     "$(count '"event": "review_desk_resume"')" 1
no_sessions
# The fifth kind through the same reversal. Its own assertion passed on a reused instance
# whatever liveness said, which is why this one is here and not only the `draft_approved` above.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=active repo=acme/portal number=418 session_id=live-8 --by test
session live-8
rc=$(run "$work/nolive.py" poll 1)
ok "  and so does a live session holding a nits_to_ticket" "$(count '"event": "review_desk_resume"')" 1
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

# The two controls for the layer table's arithmetic. Each breaks the EXAMPLE, not the prose, which
# is the half a grep for the rule cannot see.
sed 's/| `9 options, C built` |/| `9 options, 4 of them not on the ticket, C built` |/' \
    "$brief_md" > "$work/baddetail.md"
ok "the detail-length reversal changed one line"       "$(grep -c '9 options, 4 of them not on the ticket, C built' "$work/baddetail.md")" 2
ok "a detail example over four words is NOT reported ok" "$(layers "d['over_four'] == []" "$work/baddetail.md")" False
ok "  and it is named, so the fix is findable"         "$(layers "len(d['over_four'])" "$work/baddetail.md")" 1

sed 's/^| 4 solution map | step 5 | `right shape, one departure` | Parts · .*$/| 4 solution map | step 5 | `right shape, one departure` | |/' \
    "$brief_md" > "$work/badfacts.md"
ok "the facts reversal emptied one cell"               "$(grep -c '^| 4 solution map | step 5 | .right shape, one departure. | |$' "$work/badfacts.md")" 1
ok "a step with no facts cell is caught"               "$(layers "d['cells_filled']" "$work/badfacts.md")" 6
ok "  and it drops out of the five that carry them"    "$(layers "d['rows_with_facts']" "$work/badfacts.md")" 4

sed 's/^| \*\*What the pass was given\*\* | `blind_pass\.given` |/| **What the pass was given** | `blind_pass.handed` |/' \
    "$brief_md" > "$work/badfield.md"
ok "the member reversal changed one line"              "$(grep -c 'blind_pass.handed' "$work/badfield.md")" 1
ok "  and it is the root check that does NOT catch it" "$(ask "d['unknown_roots']" "$work/badfield.md")" "[]"
ok "a renamed member is caught by the page coverage"   "$(ask "d['missing_contract']" "$work/badfield.md")" "['blind_pass.given']"

# The control for the limits crossing, and the drift it is named after: DEV-883 renamed
# "How it works today" and `--limits` went on citing it, in the same repository, with nothing
# crossing the two. Put the old name back and the crossing must say so.
sed "s/'Supporting table /'How it works today /" \
    "$root/skills/review-craft/brief_lint.py" > "$work/badlimits.py"
ok "the citation reversal changed one line"            "$(grep -c "How it works today \.\.\. 3" "$work/badlimits.py")" 1
# And the second half of the quotation, which a name-only check could not have judged.
sed "s/'Options \.\.\. a title of at most 12 words'/'Options ... a title under 12 words'/" \
    "$root/skills/review-craft/brief_lint.py" > "$work/badquote.py"
ok "the reworded-quotation reversal changed one line"  "$(grep -c "a title under 12 words" "$work/badquote.py")" 1
ok "a citation reworded where the slot stayed is caught" "$(python3 "$work/limitslots.py" \
    "$work/badquote.py" "$understand_md")" "11 checked; a title under 12 words"
ok "a limit citing a slot that is gone is caught"      "$(python3 "$work/limitslots.py" \
    "$work/badlimits.py" "$understand_md")" "11 checked; How it works today (not a slot)"

# The control for the worked example's one-line column. The example is markdown, nothing but
# this arithmetic reads it, and an example that breaks the rule it sits beside teaches the
# breach -- so the arithmetic has to be shown catching one.
sed 's/| Each file is carried and retried on its own. |/| Each file is carried on its own and retried on its own, three times over. |/' \
    "$understand_md" > "$work/badexample.md"
ok "the one-line reversal changed one line"            "$(grep -c 'three times over' "$work/badexample.md")" 1
ok "a one-line form over twelve words is caught"       "$(worked "len(d['one_lines_over_12'])" "$work/badexample.md")" 1
ok "  and it is named, so the fix is findable"         "$(worked "d['one_lines_over_12'][0][:20]" "$work/badexample.md")" "Each file is carried"

sed 's/^| \*\*The system\*\* | `how_it_works_today` | \*\*1\*\* |/| **The sytsem** | `how_it_works_today` | **1** |/' \
    "$brief_md" > "$work/badslot.md"
ok "the slot-name reversal changed one line"           "$(grep -c 'The sytsem' "$work/badslot.md")" 1
ok "a slot understand.md does not define is caught"    "$(ask "d['slots_improvised']" "$work/badslot.md")" "['The sytsem']"
ok "  and the slot it left behind is caught too"       "$(ask "d['slots_unsaved']" "$work/badslot.md")" "['The system']"

sed '/^| `## What is wrong`, its opening line | `problem` |$/d' "$brief_md" > "$work/badpour2.md"
ok "the unpoured reversal removed one line"            "$(grep -c 'its opening line' "$work/badpour2.md")" 0
ok "a served field poured nowhere is caught"           "$(ask "d['pour_unpoured']" "$work/badpour2.md")" "['problem']"

sed 's/| `## The system` | `how_it_works_today` |/| `## The system` | `headline` |/' \
    "$brief_md" > "$work/badpour.md"
ok "the pour reversal changed one line"                "$(grep -c '| `## The system` | `headline` |' "$work/badpour.md")" 1
ok "pouring from a field the read withholds is caught" "$(ask "d['pour_unserved']" "$work/badpour.md")" "['headline']"

sed 's/^| \*\*Before\*\* | `flow_before\[\]\[\]`, with `flow_before_caption` | \*\*1\*\* |/| **Before** | `flow_before[][]`, with `flow_before_caption` | 2 |/' \
    "$brief_md" > "$work/badwrite.md"
ok "the write-column reversal changed one line"        "$(grep -c '^| \*\*Before\*\* | .flow_before\[\]\[\]., with .flow_before_caption. | 2 |' "$work/badwrite.md")" 1
ok "a problem-half field moved to write 2 is caught"   "$(ask "d['write1'] == d['served_expected']" "$work/badwrite.md")" False

# The four controls for DEV-934. The gap this ticket closes was a tuple with four names in it,
# which is the cheapest possible thing to get wrong and the cheapest possible thing to assert
# without actually asserting -- so each half of the fix is shown failing.

sed 's/^        if kind not in REVIEW_DESK_KINDS:$/        if False:  # KIND GUARD REVERSED/' \
    "$disp" > "$work/nokind.py"
ok "the kind-guard reversal changed one line"          "$(grep -c 'KIND GUARD REVERSED' "$work/nokind.py")" 1
instance '{"mode":"auto"}'
work_doc rubric_settled 11 acme/portal 420
rc=$(run "$work/nokind.py" poll 1)
ok "no kind guard: an unknown kind is dispatched"      "$(count '"event": "review_desk_resume"')" 1
ok "  as work nobody knows what to do with"            "$(says '"kind": "rubric_settled"')" yes

sed 's/^        if not self\.due(f"review_desk|unknown_kind|{kind}", every):$/        if False:  # UNKNOWN RATE LIMIT REVERSED/' \
    "$disp" > "$work/noloud.py"
ok "the unknown rate-limit reversal changed one line"  "$(grep -c 'UNKNOWN RATE LIMIT REVERSED' "$work/noloud.py")" 1
instance '{"mode":"auto"}'
work_doc rubric_settled 11 acme/portal 420
rc=$(run "$work/noloud.py" poll 3)
ok "no rate limit: three ticks say it three times"     "$(count '"event": "review_desk_unknown_kind"')" 3

# The crossing's own teeth. Take the fifth kind back out and the contract assertion must say so
# -- otherwise it is a list compared against itself, which is the shape CLAUDE.md names: a check
# whose passing carries no information.
sed 's/^                     "nits_to_ticket")$/                     )  # FIFTH KIND REMOVED/' \
    "$disp" > "$work/nofifth.py"
ok "the fifth-kind reversal changed one line"          "$(grep -c 'FIFTH KIND REMOVED' "$work/nofifth.py")" 1
ok "a kind the contract lists and this file drops is caught" \
   "$(placed "json.dumps(sorted(d['kinds'] + d['ignored']))" "$work/nofifth.py")" \
   '["brief_settled", "draft_approved", "draft_sent_back", "review_requested"]'
# And the half the crossing cannot see, which is what the relay tests are for: a kind in
# REVIEW_DESK_KINDS and not in REVIEW_DESK_WATCH_KINDS is placed and reaches no session.
sed 's/^REVIEW_DESK_WATCH_KINDS = ("brief_settled", "draft_sent_back", "draft_approved",$/REVIEW_DESK_WATCH_KINDS = ("brief_settled", "draft_sent_back", "draft_approved",  # RELAY REVERSED/' \
    "$disp" > "$work/nowatch.py"
sed -i.bak 's/^                           "nits_to_ticket")$/                           )/' "$work/nowatch.py"
rm -f "$work/nowatch.py.bak"
ok "the relay reversal changed one line"               "$(grep -c 'RELAY REVERSED' "$work/nowatch.py")" 1
ok "  and dropped the fifth from the relay list"       "$(placed "json.dumps(sorted(set(d['kinds']) - set(d['watch'])))" "$work/nowatch.py")" \
   '["nits_to_ticket", "review_requested"]'
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=active review_desk_id=7 --by test
work_doc nits_to_ticket 7 acme/portal 412 1791520400
rc=$(run "$work/nowatch.py" watch gh-portal-412 1)
ok "no relay: the session that owns the review is told nothing" "$(count '"event": "nits_to_ticket"')" 0

sed 's/^        if state in PR_CLOSED and kind != "nits_to_ticket":$/        if state in PR_CLOSED:  # MERGE EXEMPTION REVERSED/' \
    "$disp" > "$work/nomerged.py"
ok "the merge-exemption reversal changed one line"     "$(grep -c 'MERGE EXEMPTION REVERSED' "$work/nomerged.py")" 1
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$work/nomerged.py" poll 1)
ok "no exemption: a merged pull request loses the ticket" "$(count review_desk)" 0

sed 's/^        if kind != "nits_to_ticket" or entry\.get("status") != "done":$/        if True:  # DEAF SESSION REVERSED/' \
    "$disp" > "$work/nodeaf.py"
ok "the deaf-session reversal changed one line"        "$(grep -c 'DEAF SESSION REVERSED' "$work/nodeaf.py")" 1
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"pr_status":"merged","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$work/nodeaf.py" poll 1)
ok "no bypass: a shut watcher still owns the ticket"   "$(count review_desk)" 0
no_sessions

# The ABSENT-CURSOR half on its own. The reversal above turns the whole condition off, so it
# says nothing about which way a missing cursor is read -- and reading it the wrong way is the
# defect this commit exists to fix.
sed 's/^        if not isinstance(cursor, dict) or not cursor:$/        if False:  # ABSENT CURSOR REVERSED/' \
    "$disp" > "$work/nocursor2.py"
ok "the absent-cursor reversal changed one line"       "$(grep -c 'ABSENT CURSOR REVERSED' "$work/nocursor2.py")" 1
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$work/nocursor2.py" poll 1)
ok "read as 'not yet': a deleted cursor loses the ticket" "$(count review_desk)" 0
# And the same reversal on a cursor that is not an object, which is where it raises.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '[]' > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$work/nocursor2.py" poll 1)
ok "  and a half-written one raises inside the tick"   "$(count '"event": "error"')" 1
no_sessions

# The last line of the gate, which nothing above reverses: a cursor that EXISTS and has not
# concluded must keep the item, and an unconditional yes would hand every one of them away.
sed 's/^        return cursor\.get("pr_status") in PR_CLOSED$/        return True  # CURSOR TEST REVERSED/' \
    "$disp" > "$work/nocursortest.py"
ok "the cursor-test reversal changed one line"         "$(grep -c 'CURSOR TEST REVERSED' "$work/nocursortest.py")" 1
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"pr_status":"open","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
rc=$(run "$work/nocursortest.py" poll 1)
ok "no cursor test: a listening watcher loses the item" "$(count '"event": "review_desk_resume"')" 1
no_sessions

# The KIND half on its own, which the reversal above cannot isolate: it turns the whole
# condition off, where this deletes only the test that keeps the bypass to one kind.
sed 's/^        if kind != "nits_to_ticket" or entry\.get("status") != "done":$/        if entry.get("status") != "done":  # KIND HALF REMOVED/' \
    "$disp" > "$work/nokindhalf.py"
ok "the kind-half reversal changed one line"           "$(grep -c 'KIND HALF REMOVED' "$work/nokindhalf.py")" 1
instance '{"mode":"auto"}'
work_doc draft_approved 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=done repo=acme/portal number=418 session_id=live-7 --by test
no_sessions
session live-7
echo '{"pr_status":"merged","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"OPEN"}' > "$work/pr.418.json"
rc=$(run "$work/nokindhalf.py" poll 1)
ok "no kind half: draft_approved takes the bypass too" "$(count '"event": "review_desk_resume"')" 1
no_sessions

printf '\n  DEV-945: recording on sight, and the three guards it needs\n'

sed 's/^        if kind == "review_requested" and self\.request_spoken_for(key, entry, item):$/        if False:  # SPOKEN FOR REVERSED/' \
    "$disp" > "$work/nospoken.py"
ok "the whole-guard reversal changed one line"         "$(grep -c 'SPOKEN FOR REVERSED' "$work/nospoken.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
rc=$(run "$work/nospoken.py" poll 1)
ok "no guard: one request reaches the Dispatcher twice" "$(( $(count '"event": "review_request"') + $(count '"event": "review_desk_requested"') ))" 2

sed 's/^        if requested_key(key) in self\.requested:$/        if False:  # TICK TEST REVERSED/' \
    "$disp" > "$work/notick.py"
ok "the this-tick reversal changed one line"           "$(grep -c 'TICK TEST REVERSED' "$work/notick.py")" 1
# With a ledger entry, so the no-such-entry guard cannot pass this one for it.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 --by test
rc=$(run "$work/notick.py" poll 1)
ok "  without it Review Desk offers it again"          "$(count '"event": "review_desk_requested"')" 1

sed 's/^        if entry\.get("status") == "skipped":$/        if False:  # SKIP TEST REVERSED/' \
    "$disp" > "$work/noskip.py"
ok "the skip reversal changed one line"                "$(grep -c 'SKIP TEST REVERSED' "$work/noskip.py")" 1
# GitHub silent, so the this-tick guard cannot pass this one for it.
instance '{"mode":"auto"}'
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
put gh-portal-412 mode=review status=skipped repo=acme/portal number=412 --by principal
rc=$(run "$work/noskip.py" poll 1)
ok "  without it a human skip is overridden"           "$(count '"event": "review_desk_requested"')" 1

sed 's/^        return bool(item\.get("ledger_id")) and not entry$/        return False  # ORPHAN TEST REVERSED/' \
    "$disp" > "$work/noorphan.py"
ok "the no-such-entry reversal changed one line"       "$(grep -c 'ORPHAN TEST REVERSED' "$work/noorphan.py")" 1
instance '{"mode":"auto"}'
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
rc=$(run "$work/noorphan.py" poll 1)
ok "  without it a withdrawn request is dispatched"    "$(count '"event": "review_desk_requested"')" 1

sed 's/^                   and held\.get("head") != head)$/                   and True)  # MARK REVERSED/' \
    "$disp" > "$work/nomark.py"
ok "the mark reversal changed one line"                "$(grep -c 'MARK REVERSED' "$work/nomark.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nomark.py" poll 3)
ok "no mark: three ticks record the same request thrice" "$(opens)" 3

sed 's/^            if recording and status not in ALIVE and not entry\.get("session_id"):$/            if recording:  # ALIVE TEST REVERSED/' \
    "$disp" > "$work/noalive.py"
ok "the live-session reversal changed one line"        "$(grep -c 'ALIVE TEST REVERSED' "$work/noalive.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
put gh-portal-412 mode=review status=active repo=acme/portal number=412 session_id=live-9 --by test
session live-9
rc=$(run "$work/noalive.py" poll 1)
ok "  without it a live session's review is written to" "$(opens)" 1
no_sessions

sed 's/^            self\.record_stopped = True$/            pass  # STOP REVERSED/' \
    "$disp" > "$work/nostop.py"
ok "the stop-once reversal changed both its lines"     "$(grep -c 'STOP REVERSED' "$work/nostop.py")" 2
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo broken > "$work/rd.open.mode"
rc=$(run "$work/nostop.py" poll 1)
ok "  without it a broken install is asked per request" "$(opens)" 2

sed 's/^            state, payload, detail = review_desk_run(rd, \*facts, "--json")$/            pass  # RETRY REMOVED/' \
    "$disp" > "$work/noretry.py"
ok "the retry reversal changed one line"               "$(grep -c 'RETRY REMOVED' "$work/noretry.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo oldledger > "$work/rd.open.mode"
rc=$(run "$work/noretry.py" poll 1)
ok "  without it an older Review Desk records nothing" "$(recorded_count)" 0

printf '\n  DEV-945: and the dismissal that stops a dispatch\n'

sed 's/^                if self\.dismissed_request(rd, key, repo, pr):$/                if False:  # DISMISSAL IGNORED/' \
    "$disp" > "$work/nodismiss.py"
ok "the dismissal reversal changed one line"           "$(grep -c 'DISMISSAL IGNORED' "$work/nodismiss.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
dismiss acme/portal 412 "closed unmerged"
# The re-emission clock as well, or this control would pass for the wrong reason: the request
# was emitted on the tick above, and that alone keeps it quiet for fifteen minutes.
age_marker 'gh-portal-412|review_request'
rc=$(run "$work/nodismiss.py" poll 1)
ok "  without it a dismissed review is dispatched"     "$(count '"event": "review_request"')" 1
ok "  and nothing says why it should not have been"    "$(count '"event": "review_dismissed"')" 0

sed 's/^        elif not self\.read_stopped and self\.due(asked, every):$/        elif False:  # DISMISSAL NEVER READ/' \
    "$disp" > "$work/noread.py"
ok "the re-read reversal changed one line"             "$(grep -c 'DISMISSAL NEVER READ' "$work/noread.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/noread.py" poll 1)
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$work/noread.py" poll 1)
ok "  without it a dismissal on the same commit is missed" "$(count '"event": "review_dismissed"')" 0

sed 's/^            self\.state\["once"\]\.pop(mark, None)$/            pass  # MARK KEPT/' \
    "$disp" > "$work/nounmark.py"
ok "the clear-on-restore reversal changed one line"    "$(grep -c 'MARK KEPT' "$work/nounmark.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nounmark.py" poll 1)
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$work/nounmark.py" poll 1)
restore acme/portal 412
age_marker 'review_desk|dismissal|gh-portal-412'
rc=$(run "$work/nounmark.py" poll 1)
dismiss acme/portal 412 "closed again"
age_marker 'review_desk|dismissal|gh-portal-412'
rc=$(run "$work/nounmark.py" poll 1)
ok "  without it a second dismissal is never said"     "$(count '"event": "review_dismissed"')" 0

# =============================================================================================
printf '\nAgainst the real Review Desk, when one is given\n'
# `REVIEW_DESK_BIN=/path/to/review-desk sh scripts/test-dispatcher-review-desk.sh` runs the
# poller against the real binary on its own temporary database. It is the only thing in this
# file that can say the stand-in above tells the truth, and it is OPT-IN for the reason the
# header gives: nothing here may need a built binary, or this harness stops running in CI.
#
# What it does NOT do: touch `~/.review-desk`, serve anything on a port, or ask GitHub for
# anything. `REVIEW_DESK_DB` is a file under $work, and the dismissal is written with `sqlite3`
# because a dismissal has no command line at all -- it is the dashboard's API, which is the
# whole of why no session can perform one.
#
# One noise to expect and not to read as a failure: `harvest` is real here too, and the real
# harvest asks GitHub through `gh`, which is a stand-in that answers its calls with nothing it
# understands. The assertions below are about the recording, the guard and the dismissal, and
# the harvest's own notice is counted separately so it is named rather than ignored.

if [ -z "${REVIEW_DESK_BIN:-}" ]; then
  printf '  skipped -- set REVIEW_DESK_BIN=/path/to/review-desk to run this section\n'
elif [ ! -x "${REVIEW_DESK_BIN}" ]; then
  fail=$((fail + 1)); printf '  FAIL  REVIEW_DESK_BIN is not executable: %s\n' "$REVIEW_DESK_BIN"
else
  real=$(python3 -c 'import json,sys;print(json.dumps({"mode":"auto","command":sys.argv[1]}))' \
    "$REVIEW_DESK_BIN")
  printf '  %s\n' "$("$REVIEW_DESK_BIN" --version)"
  export REVIEW_DESK_DB="$work/real.db"
  rm -f "$REVIEW_DESK_DB"

  instance "$real"
  search_doc acme/portal 412 sha412 "Retry failed webhook deliveries"
  rc=$(run "$disp" poll 1)
  ok "a real Review Desk records the request"            "$rc" 0
  ok "  the review it opened is remembered"              "$(remembered gh-portal-412 review)" 1
  ok "  on the commit GitHub showed"                     "$(remembered gh-portal-412 head)" sha412
  ok "  and it is not dismissed"                          "$(remembered gh-portal-412 dismissed)" False
  ok "  the request is emitted once"                      "$(count '"event": "review_request"')" 1
  real_work () { "$REVIEW_DESK_BIN" work list --repo acme/portal --json; }
  ok "  the real work list calls it review_requested"     "$(real_work | python3 -c 'import json,sys;w=json.load(sys.stdin)["work"];print(len(w) and w[0]["kind"])')" review_requested
  ok "  carrying the ledger entry it was given"           "$(real_work | python3 -c 'import json,sys;print(json.load(sys.stdin)["work"][0]["ledger_id"])')" gh-portal-412
  ok "  and the Review Desk pass does not offer it again" "$(count '"event": "review_desk_requested"')" 0

  # The same request on a new commit: ONE review, moved, and still one item on the real list.
  search_doc acme/portal 412 sha999 "Retry failed webhook deliveries"
  rc=$(run "$disp" poll 1)
  ok "a push moves the real review"                       "$(real_work | python3 -c 'import json,sys;w=json.load(sys.stdin)["work"];print("%d %s %s" % (len(w), w[0]["head_sha"], w[0]["round"]))')" "1 sha999 1"
  ok "  which the poller remembers"                       "$(remembered gh-portal-412 head)" sha999

  # **The round rule, against the real store.** `review link --session` is the worker's own
  # command and the thing that makes a request "started"; after it, `review open` on a new commit
  # is the next ROUND, which `work list` would offer as a request of its own. So the poller must
  # stop writing, and this is the sequence that proves it does.
  put gh-portal-412 mode=review status=active repo=acme/portal number=412 session_id=sess-real
  "$REVIEW_DESK_BIN" review link --review 1 --session sess-real --json > /dev/null
  search_doc acme/portal 412 sha777 "Retry failed webhook deliveries"
  age_marker 'gh-portal-412|review_request'
  rc=$(run "$disp" poll 1)
  ok "a push after a session is linked opens no round"   "$(real_work | python3 -c 'import json,sys;w=json.load(sys.stdin)["work"];print("%d %s %s" % (len(w), w[0]["round"], w[0]["head_sha"]))')" "1 1 sha999"
  ok "  and the review it dispatched for is the one kept" "$(remembered gh-portal-412 review)" 1

  # **Dismissed, in the only way there is: the record, not a command.** On its own pull request
  # and its own instance, so none of the state above can answer for it. The review's id is read
  # back from what the poller remembered rather than assumed, because the round rule above means
  # ids are not positions.
  instance "$real"
  search_doc acme/portal 611 head611 "A scheduled export keeps its context"
  rc=$(run "$disp" poll 1)
  ok "a second request is recorded on its own review"     "$(count '"event": "review_request"')" 1
  dismissed_id=$(remembered gh-portal-611 review)
  sqlite3 "$REVIEW_DESK_DB" "UPDATE reviews SET dismissed_at = 1791780000, dismissed_reason = 'the pull request was closed unmerged' WHERE id = $dismissed_id;"
  ok "  a dismissed review leaves the real work list"     "$("$REVIEW_DESK_BIN" work list --repo acme/portal --json | python3 -c 'import json,sys;print(len([w for w in json.load(sys.stdin)["work"] if w["pr"] == 611]))')" 0
  age_marker 'gh-portal-611|review_request'
  rc=$(run "$disp" poll 1)
  ok "  the poller reads the dismissal"                   "$(remembered gh-portal-611 dismissed)" True
  ok "  dispatches nothing"                               "$(count '"event": "review_request"')" 0
  ok "  and says so once, with the reason"                "$(count 'the pull request was closed unmerged')" 1

  # Restored, the same way. A dismissal is a decision and so is taking it back.
  sqlite3 "$REVIEW_DESK_DB" "UPDATE reviews SET dismissed_at = NULL, dismissed_reason = NULL WHERE id = $dismissed_id;"
  age_marker 'review_desk|dismissal|gh-portal-611'
  age_marker 'gh-portal-611|review_request'
  rc=$(run "$disp" poll 1)
  ok "a restored review is dispatched again"              "$(count '"event": "review_request"')" 1
  ok "  and is no longer remembered as dismissed"         "$(remembered gh-portal-611 dismissed)" False

  # Nothing this harness ran could have dismissed, restored or deleted anything: the binary has
  # no such command. Asserted against the real one's own help rather than claimed.
  set +e
  "$REVIEW_DESK_BIN" review dismiss --review 1 > "$work/noway" 2>&1; code=$?
  set -e
  # Exit 1: review-desk remaps clap's usage exit to its own "understood and refused", which
  # is the same door a `--ledger` an older build has never heard of comes back through.
  ok "the real binary has no \`review dismiss\`"            "$code" 1
  ok "  and says so as a usage error"                     "$(grep -c 'unrecognized subcommand' "$work/noway")" 1

  export REVIEW_DESK_DB="$work/test.db"
fi

sed 's/^            "head": head if writing else (held\.get("head") or head),$/            "head": review.get("head_sha") or head,  # HEAD ECHOED/' \
    "$disp" > "$work/noheadq.py"
ok "the remembered-commit reversal changed one line"   "$(grep -c 'HEAD ECHOED' "$work/noheadq.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 SHA412UPPER Retry
rc=$(run "$work/noheadq.py" poll 3)
ok "  without it one request is written three times"   "$(opens)" 3

sed 's/^            if detail\.startswith(REVIEW_DESK_USAGE_REFUSAL):$/            if False:  # SHOW USAGE REVERSED/' \
    "$disp" > "$work/noshowusage.py"
ok "the no-such-command reversal changed one line"     "$(grep -c 'SHOW USAGE REVERSED' "$work/noshowusage.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/noshowusage.py" poll 1)
echo oldshow > "$work/rd.show.mode"
rc=$(run "$work/noshowusage.py" poll 2)
ok "  without it an older build is written to again"   "$(opens)" 2

sed 's/^    return key\.lower()$/    return key  # CASE KEPT/' "$disp" > "$work/nocase.py"
ok "the key-case reversal changed one line"            "$(grep -c 'CASE KEPT' "$work/nocase.py")" 1
instance '{"mode":"auto"}'
search_doc Acme/Portal 412 sha412 Retry
work_doc review_requested 11 acme/portal 412
rc=$(run "$work/nocase.py" poll 1)
ok "  without it a capital letter buys a second event" "$(count '"event": "review_desk_requested"')" 1

sed 's/^                self\.state\["emitted"\]\.pop(asked, None)$/                pass  # WINDOW SPENT/' \
    "$disp" > "$work/nowindow.py"
ok "the spent-window reversal changed one line"        "$(grep -c 'WINDOW SPENT' "$work/nowindow.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nowindow.py" poll 1)
echo broken > "$work/rd.show.mode"
rc=$(run "$work/nowindow.py" poll 1)
echo ok > "$work/rd.show.mode"
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$work/nowindow.py" poll 1)
ok "  without it the dismissal waits out the interval" "$(remembered gh-portal-412 dismissed)" False

sed 's/^                                  if k in present or v\.get("dismissed")}$/                                  if k in present}  # DISMISSAL PRUNED/' \
    "$disp" > "$work/noprunekeep.py"
ok "the keep-a-dismissal reversal changed one line"    "$(grep -c 'DISMISSAL PRUNED' "$work/noprunekeep.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/noprunekeep.py" poll 1)
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$work/noprunekeep.py" poll 1)
rm -f "$work/gh.search"
rc=$(run "$work/noprunekeep.py" poll 2)
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/noprunekeep.py" poll 1)
ok "  without it a dismissed review is written to again" "$(opens)" 2

sed 's/^            if self\.due(f"review_desk|record_refused|{repo}", every):$/            if self.due(f"review_desk|record_refused|{detail[:60]}", every):  # PER REQUEST/' \
    "$disp" > "$work/noperrepo.py"
ok "the per-repository reversal changed one line"      "$(grep -c 'PER REQUEST' "$work/noperrepo.py")" 1
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo refused > "$work/rd.open.mode"
rc=$(run "$work/noperrepo.py" poll 1)
ok "  without it one cause is reported per request"    "$(count '"event": "review_desk_unavailable"')" 2

sed 's/^                self\.read_stopped = True$/                pass  # READ STOP REMOVED/' \
    "$disp" > "$work/noreadstop.py"
ok "the ask-once-a-tick reversal changed one line"     "$(grep -c 'READ STOP REMOVED' "$work/noreadstop.py")" 1
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
rc=$(run "$work/noreadstop.py" poll 1)
echo oldshow > "$work/rd.show.mode"
rc=$(run "$work/noreadstop.py" poll 1)
ok "  without it a build is asked once per request"    "$(shows)" 2

sed 's/^            if recording and status not in ALIVE and not entry\.get("session_id"):$/            if recording and status not in ALIVE:  # LEDGER SESSION IGNORED/' \
    "$disp" > "$work/noledgersession.py"
ok "the ledger-session reversal changed one line"      "$(grep -c 'LEDGER SESSION IGNORED' "$work/noledgersession.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/noledgersession.py" poll 1)
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 session_id=dead-2 --by test
link acme/portal 412 dead-2
search_doc acme/portal 412 sha999 Retry
age_marker 'gh-portal-412|review_request'
rc=$(run "$work/noledgersession.py" poll 1)
ok "  without it a push spends a round immediately"    "$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(max(h["round"] for h in s.values()))' "$work/rd.opens.json")" 2

sed 's/^        writing = (not held\.get("dismissed") and not held\.get("session")$/        writing = (not held.get("session")  # DISMISSAL WRITTEN TO/' \
    "$disp" > "$work/nodismisswrite.py"
ok "the leave-a-dismissal-alone reversal changed one line" "$(grep -c 'DISMISSAL WRITTEN TO' "$work/nodismisswrite.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nodismisswrite.py" poll 1)
dismiss acme/portal 412 "closed unmerged"
rc=$(run "$work/nodismisswrite.py" poll 1)
search_doc acme/portal 412 sha999 Retry
rc=$(run "$work/nodismisswrite.py" poll 1)
ok "  without it every push writes to a dismissed row" "$(opens)" 2

sed 's/^        if self\.record_broken is None or review_desk_repos(cfg, ledger):$/        if True:  # NO VOICE AT ALL/' \
    "$disp" > "$work/novoice.py"
ok "the one-voice reversal changed one line"           "$(grep -c 'NO VOICE AT ALL' "$work/novoice.py")" 1
NOMAP=1 instance '{"mode":"on"}'
search_doc acme/portal 412 sha412 Retry
echo broken > "$work/rd.mode"
rc=$(run "$work/novoice.py" poll 1)
ok "  without it a broken install says nothing at all" "$(count review_desk_unavailable)" 0

sed 's/^    if not isinstance(payload, dict):$/    if False:  # TYPE CHECK REMOVED/' \
    "$disp" > "$work/notype.py"
ok "the type-check reversal changed one line"          "$(grep -c 'TYPE CHECK REMOVED' "$work/notype.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo notobject > "$work/rd.open.mode"
rc=$(run "$work/notype.py" poll 1)
ok "  without it the whole GitHub pass throws"         "$(count '"event": "error"')" 1
ok "  and no review request is emitted at all"         "$(count '"event": "review_request"')" 0

sed 's/^        writing = (not held\.get("dismissed") and not held\.get("session")$/        writing = (not held.get("dismissed")  # SESSION IGNORED/' \
    "$disp" > "$work/nosession.py"
ok "the linked-session reversal changed one line"      "$(grep -c 'SESSION IGNORED' "$work/nosession.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nosession.py" poll 1)
link acme/portal 412 dead-1
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 --by test
rc=$(run "$work/nosession.py" poll 1)
search_doc acme/portal 412 sha999 Retry
rc=$(run "$work/nosession.py" poll 1)
ok "  without it a push spends a round"                "$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(max(h["round"] for h in s.values()))' "$work/rd.opens.json")" 2

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
