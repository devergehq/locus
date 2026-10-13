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
    """`--flag value` and `--flag=value`, because clap accepts both and DEV-945 sends the second
    for `--title`: a pull request may be called `-fix the thing`, and a separate value beginning
    with a hyphen is read by clap as a flag it has never heard of."""
    for i, arg in enumerate(argv):
        if arg == flag and len(argv) > i + 1:
            return argv[i + 1]
        if arg.startswith(flag + "="):
            return arg[len(flag) + 1:]
    return None


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
           "started": False, "out_of_play": None, "out_of_play_at": None,
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
                    "started": bool(held_open.get("started")),
                    "dismissed_at": held_open.get("dismissed_at"),
                    "dismissed_reason": held_open.get("dismissed_reason"),
                    "out_of_play": held_open.get("out_of_play"),
                    "out_of_play_at": held_open.get("out_of_play_at")})
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
    # `$RDWORK/rd.open.oldfor` narrows `oldledger` to the pull requests it names, which is the
    # only way to have ONE tick meet an old answer and a modern one: the mode file is read per
    # call, and a shell cannot change it between two calls inside one tick. What it is for is
    # the per-key question -- whether a fact measured about one request leaks onto the next.
    oldfor = (work / "rd.open.oldfor").read_text().split() \
        if (work / "rd.open.oldfor").exists() else None
    if oldfor is not None and (opt(argv, "--pr") or "") not in oldfor:
        mode = "ok" if mode == "oldledger" else mode
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
    session = opt(argv, "--session")
    unchanged_claim = "--diff-unchanged" in argv
    if unchanged_claim and not contract():
        # A build with no such flag: clap refuses the whole call, which is why the poller must
        # never pass it without probing first.
        refuse("usage", "error: unexpected argument '--diff-unchanged' found\n\nUsage: "
                        "review-desk review open --repo <OWNER/REPO> --pr <N> --head <SHA>")
    store = opened()
    slot = "%s#%s" % (repo, pr)
    held = store.get(slot)

    def fresh(number, inherit):
        """A new round of this pull request. Out-of-play is INHERITED, which is review-desk's own
        answer of 13 October 2026: round 1 posted, the pull request pulled back to draft, the
        author pushes -- and a round 2 that did not carry the reason would put the pull request
        back on the work list without anybody bringing it back."""
        return {"id": max([h["id"] for h in store.values()] + [0]) + 1, "head": head,
                "ledger": ledger, "round": number, "session": session,
                "started": bool(session), "posted": False,
                "out_of_play": inherit.get("out_of_play"),
                "out_of_play_at": inherit.get("out_of_play_at")}

    if held is None:
        held = fresh(1, {})
        created, moved, action = True, None, "created"
    elif held["head"] == head:
        # **The same commit back again comes first, and `--diff-unchanged` does not change it.**
        # review-desk, measured: the "this is already the commit it is of" answer wins, nothing
        # is written and no `base_only` note is recorded either.
        created, moved, action = False, None, "unchanged"
        if ledger is not None:
            held["ledger"] = ledger
        if session is not None:
            held["session"], held["started"] = session, True
    elif mode == "oldledger":
        # A build from before DEV-945: no `--ledger`, and no MOVE either -- the two landed in
        # review-desk 0e0bf1b together. Measured against the installed 0.1.0: a new head on an
        # unstarted request answers `created: true`, round 2, a second row for one request.
        held = fresh(held["round"] + 1, held)
        held["ledger"] = None
        created, moved, action = True, None, "created"
    elif unchanged_claim:
        # **The caller asserts the pull request's own diff has not changed**, so the commits only
        # brought the base in: no round, no head move, no sign-off withdrawn, and a `base_only`
        # note. Before the posted test, because the ticket's table says the same thing in both
        # columns -- base-only commits change nothing whether or not a round has posted.
        held["base_only"] = held.get("base_only", 0) + 1
        created, moved, action = False, None, "diff_unchanged"
    elif not contract() and held.get("started"):
        # A build before DEV-962: a STARTED round's new head is round N+1, which is the whole
        # harm the ticket is about. `started` rather than `session`, because review-desk has
        # always judged it on five facts and DEV-954 is what made the caller able to see it.
        held = fresh(held["round"] + 1, held)
        created, moved, action = True, None, "created"
    elif held.get("posted"):
        # **A round is a posted review.** Commits after a post are the next round, whatever the
        # build -- this is the one case DEV-962 leaves exactly as it was.
        held = fresh(held["round"] + 1, held)
        created, moved, action = True, None, "created"
    else:
        # Unposted: the head MOVES, whoever called and whether or not anybody has started.
        created, moved, action = False, held["head"], "head_moved"
        held["head"] = head
        if ledger is not None:
            held["ledger"] = ledger
        if session is not None:
            held["session"], held["started"] = session, True
    store[slot] = held
    (work / "rd.opens.json").write_text(json.dumps(store))
    review = {"id": held["id"], "repo": repo, "pr": int(pr), "head_sha": held["head"],
              "round": held["round"], "title": opt(argv, "--title"),
              "ticket_id": opt(argv, "--ticket"), "ledger_id": held["ledger"],
              "session_id": held.get("session"),
              # On every one of the three paths -- created, found and moved -- as review-desk
              # 5dae8f6 answers. A push on a dismissed request moves its head and leaves it
              # dismissed, because a push is not the developer changing their mind.
              "dismissed_at": held.get("dismissed_at"),
              "dismissed_reason": held.get("dismissed_reason"),
              "out_of_play": held.get("out_of_play"),
              "out_of_play_at": held.get("out_of_play_at")}
    answer = {"review": review, "created": created, "head_moved_from": moved,
              "carryable": None}
    if contract():
        # `action` and `started` are DEV-962's and DEV-954's; a build without the contract
        # answers exactly the document it answered before, which is what the poller's derive
        # path is written against.
        answer["action"] = action
        # `$RDWORK/rd.nostarted` takes `started` off BOTH answers, not just `review find`'s
        # rows: review-desk put it on the open's answer too (13 October 2026), so a stand-in
        # that withheld it from only one would leave the poller reading it from the other and
        # the fallback path untested.
        if not (work / "rd.nostarted").exists():
            review["started"] = bool(held.get("started"))
    print(json.dumps(answer))
    raise SystemExit(0)


def out_of_play(argv):
    """`review out-of-play`, as review-desk's author measured it on 13 October 2026.

      the same reason again      success, and `out_of_play_at` is LEFT WHERE IT WAS
      a different reason         success, and it takes its own time
      a pull request with no review  refused `not_found`
      a build without it         clap's own unrecognised-subcommand, code `usage`

    `$RDWORK/rd.oop.mode` is this one subcommand's health, so an older or refusing
    `out-of-play` can be driven while `review open` still answers.
    """
    mode = (work / "rd.oop.mode").read_text().strip() \
        if (work / "rd.oop.mode").exists() else "ok"
    if mode == "oldoop":
        refuse("usage", "error: unrecognized subcommand 'out-of-play'")
    if mode == "broken":
        refuse("cannot_open_database", "scripted broken out-of-play", 2)
    if mode == "refused":
        refuse("database_locked", "the database is locked by another writer")
    reason = opt(argv, "--reason")
    if reason not in ("draft", "withdrawn"):
        refuse("invalid_value", "out_of_play: expected one of draft, withdrawn")
    repo, pr = (opt(argv, "--repo") or "").strip().lower(), opt(argv, "--pr")
    store = opened()
    slot = "%s#%s" % (repo, pr)
    held = store.get(slot)
    if held is None:
        refuse("not_found", "no review of %s#%s" % (repo, pr))
    if held.get("out_of_play") != reason:
        held["out_of_play"] = reason
        # A stopped clock, so "the time only moves when the reason does" is assertable: the
        # counter in $RDWORK/rd.clock is bumped per write rather than read off the wall.
        clock = work / "rd.clock"
        nth = (int(clock.read_text()) if clock.exists() else 0) + 1
        clock.write_text(str(nth))
        held["out_of_play_at"] = 1791780000 + nth * 900
    store[slot] = held
    (work / "rd.opens.json").write_text(json.dumps(store))
    print(json.dumps({"review": {"id": held["id"], "repo": repo, "pr": int(pr),
                                 "round": held["round"], "head_sha": held["head"],
                                 "session_id": held.get("session"),
                                 "started": bool(held.get("started")),
                                 "dismissed_at": held.get("dismissed_at"),
                                 "dismissed_reason": held.get("dismissed_reason"),
                                 "out_of_play": held["out_of_play"],
                                 "out_of_play_at": held["out_of_play_at"]}}))
    raise SystemExit(0)


def in_play(argv):
    """`review in-play`: clears every round of the pull request. Success when already in play.

    `$RDWORK/rd.oop.mode` of `sticky` is a build that accepts the call, exits 0, and reports the
    pull request STILL out of play. Nothing in the real binary does that — review-desk's author
    measured in-play clearing every round — and it is modelled because the poller believes the
    answer rather than the request, which is `out_of_play`'s own rule in the other direction. Un-
    modelled, no test could reach the branch that decides what such a store costs.
    """
    mode = (work / "rd.oop.mode").read_text().strip() \
        if (work / "rd.oop.mode").exists() else "ok"
    if mode == "oldoop":
        refuse("usage", "error: unrecognized subcommand 'in-play'")
    if mode == "broken":
        refuse("cannot_open_database", "scripted broken in-play", 2)
    repo, pr = (opt(argv, "--repo") or "").strip().lower(), opt(argv, "--pr")
    store = opened()
    slot = "%s#%s" % (repo, pr)
    held = store.get(slot)
    if held is None:
        refuse("not_found", "no review of %s#%s" % (repo, pr))
    if mode != "sticky":
        held["out_of_play"], held["out_of_play_at"] = None, None
        store[slot] = held
        (work / "rd.opens.json").write_text(json.dumps(store))
    print(json.dumps({"review": {"id": held["id"], "repo": repo, "pr": int(pr),
                                 "round": held["round"], "head_sha": held["head"],
                                 "session_id": held.get("session"),
                                 "started": bool(held.get("started")),
                                 "dismissed_at": held.get("dismissed_at"),
                                 "dismissed_reason": held.get("dismissed_reason"),
                                 "out_of_play": held.get("out_of_play"),
                                 "out_of_play_at": held.get("out_of_play_at")}}))
    raise SystemExit(0)


def find_review(argv):
    """`review find`: a pull request's rounds, NEWEST FIRST, as review-desk 82c0a09 answers it.

    Dismissed rounds are included -- measured, not assumed -- which is what the caller wants:
    the newest round is the row `review open` would act on. This store keeps one row per pull
    request because a new round replaces the one before it, so "newest first" is a list of one
    or of none, and none is `reviews: []` with exit 0 rather than a refusal.
    """
    mode = (work / "rd.find.mode").read_text().strip() \
        if (work / "rd.find.mode").exists() else "ok"
    if mode == "broken":
        refuse("cannot_open_database", "scripted broken review find", 2)
    if mode == "refused":
        refuse("not_found", "no such repository")
    if mode == "oldfind":
        # A build with `review open` and no `review find`: clap's own refusal, which review-desk
        # answers as the `usage` document when `--json` is given -- measured at 82c0a09 for an
        # unrecognised subcommand as well as an unexpected argument.
        refuse("usage", "error: unrecognized subcommand 'find'")
    if mode == "notobject":
        print("[]")
        raise SystemExit(0)
    if mode == "badround":
        # A non-empty `reviews` whose newest entry is not an object. Modelled because DEV-959's
        # recording carve-out reads a clean `None` from this command as "the store holds no
        # review of this pull request" and WRITES one -- so a malformed round falling through to
        # `None` would be a `review open` against a pull request that already has a review.
        print(json.dumps({"pr": 0, "repo": "x", "reviews": ["not an object"]}))
        raise SystemExit(0)
    repo, pr = opt(argv, "--repo"), opt(argv, "--pr")
    held = opened().get("%s#%s" % (repo, pr))
    rounds = []
    if held is not None:
        row = {"id": held["id"], "repo": repo, "pr": int(pr), "head_sha": held["head"],
               "round": held["round"], "ledger_id": held.get("ledger"),
               "session_id": held.get("session"),
               "dismissed_at": held.get("dismissed_at"),
               "dismissed_reason": held.get("dismissed_reason"),
               "out_of_play": held.get("out_of_play"),
               "out_of_play_at": held.get("out_of_play_at")}
        if contract():
            # DEV-954's field, and it is on the ROW rather than inferred from `session_id`: a
            # round holding a brief and no link is started, and nothing else on this row says so.
            # `$RDWORK/rd.nostarted` takes it off a build that has `action` and not this, which is
            # a combination nobody expects and which the poller still has to survive.
            if not (work / "rd.nostarted").exists():
                row["started"] = bool(held.get("started"))
        rounds.append(row)
    print(json.dumps({"pr": int(pr), "repo": repo, "reviews": rounds}))
    raise SystemExit(0)


def contract():
    """Does this build carry DEV-962's contract? `$RDWORK/rd.contract` of `pre962` says no.

    Default YES, deliberately: the contract is what ships, so every assertion that does not say
    otherwise is written against it and a test has to opt INTO the old build. The reverse
    default would leave the new behaviour exercised only where somebody remembered to ask.
    """
    path = work / "rd.contract"
    return not (path.exists() and path.read_text().strip() == "pre962")


def open_help():
    """`review open --help`, which is clap's and is printed before the store is opened at all.

    **Answered BEFORE any `$RDWORK/rd.open.mode`, and that ordering is the model rather than a
    convenience.** A mode here stands for a store that is broken, refusing or answering
    nonsense, and none of those can stop clap printing its own help: the flag list is compiled
    in. A stand-in that let a write's health answer a read would have the poller read "this
    build has no `--diff-unchanged`" out of a locked database, which is a fact it must never
    infer from a failure.
    """
    flags = ["--repo <OWNER/REPO>", "--pr <N>", "--head <SHA>", "--title <TEXT>",
             "--ticket <ID>", "--ticket-url <URL>", "--changed-lines <N>",
             "--not-checked <TEXT>", "--ledger <ID>", "--session <ID>"]
    if contract():
        flags.append("--diff-unchanged")
    flags.append("--json")
    print("Usage: review-desk review open --repo <OWNER/REPO> --pr <N> --head <SHA>\n")
    print("Options:")
    for flag in flags:
        print("      %s" % flag)
    raise SystemExit(0)


argv = sys.argv[1:]
if argv[:2] == ["review", "open"] and "--help" in argv:
    open_help()
if argv[:2] == ["review", "open"]:
    open_review(argv)
if argv[:2] == ["review", "out-of-play"]:
    out_of_play(argv)
if argv[:2] == ["review", "in-play"]:
    in_play(argv)
if argv[:2] == ["review", "find"]:
    find_review(argv)

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
    # A review this store once held and holds no longer: the developer deleted one that never
    # started. Modelled by its absence rather than by a mode, so `review find` agrees with
    # `review show` about it -- a mode that made one refuse while the other still answered is
    # how the first version of this let a test pass for the wrong reason.
    gone = work / "rd.deleted"
    if gone.exists() and review.strip() in gone.read_text().split():
        refuse("not_found", "no review with id %s" % review)
    if show == "notobject":
        # Exit 0 with JSON that parses and is not a review. The write path has had a guard for
        # this shape since the third review pass; the read path had none until the fifth.
        print("[]")
        raise SystemExit(0)
    if show == "locked":
        # Understood and refused, and about neither the command nor the row: the record must be
        # left exactly where it was.
        refuse("database_locked", "the database is locked by another writer")
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
    #
    # **The query must ask for each row's state (DEV-959), and this refuses one that does not.**
    # Every stand-in for this search in this repo returns rows with NO `state` key, and the
    # poller reads a missing one as open -- so dropping the field from `REVIEWS_Q` in a bad merge
    # would revert DEV-959 with the whole suite still green. Taught to refuse rather than
    # asserted elsewhere, because that is what the `pr view` arm below had to learn the hard way:
    # "the stand-in `gh` answered the shape I had assumed; the real run is what caught it".
    case "$*" in
      *"query=\$q: String!"*|*PullRequest*)
        case "$*" in
          *"isDraft state headRefOid"*) : ;;
          *) echo 'stand-in gh: REVIEWS_Q does not ask for state (DEV-959)' >&2; exit 1 ;;
        esac ;;
    esac
    cat "$RDWORK/gh.search" 2>/dev/null || echo '{"data":{"search":{"issueCount":0,"nodes":[]}}}'
    exit 0 ;;
  "pr view "*)
    # Real `gh pr view` has NO `merged` field -- that one belongs to the REST API -- and it
    # exits 1 on an unknown one. The first version of this stand-in answered whatever it was
    # asked, so it confirmed a wrong field list instead of refusing it and a null `pr_state`
    # shipped. Refuse anything but the two field lists this file actually asks for.
    #
    # **`state,isDraft,latestReviews` is `why_cleared`'s, and `isDraft` in it is DEV-962's.** A
    # pull request converted to draft is still OPEN, so without that field the clearance reads
    # as "review request removed" -- a withdrawal that never happened, which the out-of-play
    # write would then record. Refused if the field goes missing, for the same reason the
    # graphql arm refuses a query with no `state`: a stand-in that answers a field list this
    # file does not send is a stand-in that confirms a bug.
    case "$*" in
      *"--json state") : ;;
      *"--json state,isDraft,latestReviews") : ;;
      *) echo 'Unknown JSON field: "'"${*##*--json }"'"' >&2; exit 1 ;;
    esac
    n=$3
    case "$*" in
      *latestReviews)
        cat "$RDWORK/cleared.$n.json" 2>/dev/null \
          || echo '{"state":"OPEN","isDraft":false,"latestReviews":[]}'
        exit 0 ;;
    esac
    cat "$RDWORK/pr.$n.json" 2>/dev/null || echo '{"state":"OPEN"}'
    exit 0 ;;
  *"/pulls/"*"/files?"*)
    # The pull request's OWN file list, which is what DEV-962's `--diff-unchanged` rests on.
    # One page: every fixture here is well under 100 files, so page 1 is the whole list and
    # page 2 is the empty page that ends the walk.
    #
    # **The default answers a file the walk CANNOT fingerprint**, and that default is chosen
    # rather than convenient. `[]` would be a legitimate empty diff with a stable digest, so
    # every test in this file that moves a head would start claiming the diff was unchanged --
    # `--diff-unchanged` would be passed where nobody wrote a fixture for it, which is the one
    # direction this feature must never fail in. A file with neither a `patch` nor a blob `sha`
    # is a file the walk refuses, so the flag stays off until a fixture says otherwise.
    # `$all` first, then strip. `${*#pattern}` strips from EVERY positional parameter and
    # rejoins them, so the pull request number came out as `api 412` and every fixture read as
    # the fallback -- which is a file the walk refuses, so `--diff-unchanged` was never passed
    # and four assertions passed for the wrong reason. Found by driving the digest alone.
    all="$*"; which=${all#*/pulls/}; which=${which%%/files*}
    case "$*" in
      *page=1) cat "$RDWORK/files.$which.json" 2>/dev/null \
                 || echo '[{"filename":"src/a.py","status":"modified"}]' ;;
      *) echo '[]' ;;
    esac
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
  rm -f "$work/rd.show.mode" "$work/rd.find.mode" "$work/rd.deleted" "$work/rd.open.oldfor"
  # DEV-962's: which contract the stand-in carries, the out-of-play subcommand's health, whether
  # `started` is offered at all, the stopped clock behind `out_of_play_at`, and the two GitHub
  # fixtures -- the pull request's own file list and what `why_cleared`'s live read answers.
  # Leaking any of these between scenarios is a test passing on the previous one's setup.
  rm -f "$work/rd.contract" "$work/rd.oop.mode" "$work/rd.nostarted" "$work/rd.clock"
  rm -f "$work/files."*.json "$work/cleared."*.json
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

# search_page <repo> <nodes> <matched>: a FULL page, which is what truncation looks like --
# `issueCount` says there is more work than the query can see. The rows are real requests and
# the loop runs on them; what the poller must not do is commit "nothing is requested".
search_page () {
  python3 - "$work/gh.search" "$@" <<'PY'
import json, sys, pathlib
dest, repo, nodes, matched = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
rows = [{"number": 500 + n, "title": "Request %d" % n, "isDraft": False,
         "url": "https://github.com/%s/pull/%d" % (repo, 500 + n),
         "headRefOid": "sha%d" % (500 + n), "createdAt": "2026-10-01T00:00:00Z",
         "author": {"login": "someone"}, "repository": {"nameWithOwner": repo}}
        for n in range(nodes)]
dest.write_text(json.dumps({"data": {"search": {"issueCount": matched, "nodes": rows}}}))
PY
}

# Every `review open` the stand-in was asked for, one per line, and the whole argv of the last
# one. `rd.calls` is the record; these two are how an assertion reads it.
# Writes only. `review open --help` is the contract probe DEV-962 added -- a READ, which opens
# nothing and spends no round -- and counting it here would make every "how many times was this
# request written to" assertion in this file read one or two higher for a call that writes
# nothing. `probes` counts it separately so "once a tick, not once a request" is assertable.
opens () { grep '^review open ' "$work/rd.calls" 2>/dev/null | grep -vc -- ' --help' || true; }
last_open () { grep '^review open ' "$work/rd.calls" | grep -v -- ' --help' | tail -1; }
probes () { grep -c -- '^review open --help' "$work/rd.calls" 2>/dev/null || true; }
last_oop () { grep '^review out-of-play ' "$work/rd.calls" | tail -1; }
# forget_calls: start the call log again WITHOUT resetting the instance. `instance` truncates it,
# so every count in this file is cumulative over the scenario -- which is what most assertions
# here want. A few need "and nothing more was asked on the NEXT tick", and resetting the whole
# instance would throw away the poll state those ticks are about.
forget_calls () { : > "$work/rd.calls"; }
# marks <prefix>: how many `emitted` markers the poll state holds with that prefix. `emitted` is
# PERSISTED, so a mark nothing prunes is a file that only grows -- which is what this counts.
marks () {
  python3 - "$inst/runtime/poll-state.json" "$1" <<'MARKS'
import json, sys, pathlib
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(sum(1 for m in (state.get("emitted") or {}) if m.startswith(sys.argv[2])))
MARKS
}
oops () { grep -c '^review out-of-play ' "$work/rd.calls" 2>/dev/null || true; }
inplays () { grep -c '^review in-play ' "$work/rd.calls" 2>/dev/null || true; }
shows () { grep -c '^review show ' "$work/rd.calls" 2>/dev/null || true; }
finds () { grep -c '^review find ' "$work/rd.calls" 2>/dev/null || true; }

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
# preopen <repo> <pr> <head> <id> [session]: a review THIS POLLER never recorded -- one opened
# from the dashboard, or by another instance -- which is the state its first sight of a request
# has to cope with. Written into the store directly because no command of the dispatcher's
# creates one.
preopen () {
  # preopen <repo> <pr> <head> <id> [session] [round] [posted|started]
  python3 - "$work/rd.opens.json" "$@" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
store = json.loads(path.read_text()) if path.exists() else {}
session = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else None
state = sys.argv[8] if len(sys.argv) > 8 else ""
store["%s#%s" % (sys.argv[2], sys.argv[3])] = {
    "id": int(sys.argv[5]), "head": sys.argv[4], "ledger": None,
    "round": int(sys.argv[7]) if len(sys.argv) > 7 and sys.argv[7] else 1,
    "session": session,
    # `started` is WIDER than a session being linked, which is the whole of DEV-954 -- a round
    # holding a brief and no link is started. `started` as the state argument drives that case:
    # no session, and the store still says somebody has begun.
    "started": bool(session) or state == "started",
    "posted": state == "posted"}
path.write_text(json.dumps(store))
PY
}
# post_round <repo> <pr>: the round has been POSTED, which is what makes the next push a round.
post_round () {
  python3 - "$work/rd.opens.json" "$@" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
store = json.loads(path.read_text())
held = store["%s#%s" % (sys.argv[2], sys.argv[3])]
held["posted"], held["started"] = True, True
path.write_text(json.dumps(store))
PY
}
# files_doc <pr> <json-array>: the pull request's own file list, which is what the digest behind
# `--diff-unchanged` is taken over. Writing the SAME array twice is the base-merge shape: the
# commits moved and the pull request's own diff against its base did not.
files_doc () { printf '%s\n' "$2" > "$work/files.$1.json"; }
# contract [pre962]: whether the stand-in review-desk carries DEV-962's contract. No argument
# restores the modern one, which is the default.
contract () {
  if [ "${1:-}" = "pre962" ]; then echo pre962 > "$work/rd.contract"
  else rm -f "$work/rd.contract"; fi
}
# oop_state <repo> <pr>: what the stand-in store holds for out-of-play, as `reason@time`.
oop_state () {
  python3 - "$work/rd.opens.json" "$@" <<'PY'
import json, sys, pathlib
store = json.loads(pathlib.Path(sys.argv[1]).read_text())
held = store.get("%s#%s" % (sys.argv[2], sys.argv[3])) or {}
print("%s@%s" % (held.get("out_of_play"), held.get("out_of_play_at")))
PY
}
# cleared_doc <pr> <state> <draft|ready> [reviewer]: what `gh pr view --json state,isDraft,
# latestReviews` answers for `why_cleared`, the one live read out-of-play rests on.
cleared_doc () {
  python3 - "$work/cleared.$1.json" "$@" <<'PY'
import json, sys, pathlib
dest = pathlib.Path(sys.argv[1])
reviews = [{"author": {"login": sys.argv[5]}, "state": "CHANGES_REQUESTED"}] \
    if len(sys.argv) > 5 and sys.argv[5] else []
dest.write_text(json.dumps({"state": sys.argv[3], "isDraft": sys.argv[4] == "draft",
                            "latestReviews": reviews}))
PY
}
# store_round <repo> <pr>: how many rows the stand-in store holds, which round this pull
# request is on, and the head it holds -- the three facts "no round was spent" is made of.
store_round () {
  python3 - "$work/rd.opens.json" "$@" <<'PY'
import json, sys, pathlib
store = json.loads(pathlib.Path(sys.argv[1]).read_text())
held = store.get("%s#%s" % (sys.argv[2], sys.argv[3])) or {}
print("%s %s %s" % (len(store), held.get("round"), held.get("head")))
PY
}

# delete <repo> <pr>: the developer deleting a review that never started, which is the only
# delete Review Desk allows and is also the dashboard's API with no command line.
delete () {
  python3 - "$work/rd.opens.json" "$@" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
store = json.loads(path.read_text())
held = store.pop("%s#%s" % (sys.argv[2], sys.argv[3]))
path.write_text(json.dumps(store))
# A tombstone, so `review show` refuses the id it refuses in life. An emptied store would
# otherwise be indistinguishable from one nothing has ever opened.
gone = path.with_name("rd.deleted")
gone.write_text((gone.read_text() if gone.exists() else "") + "%d\n" % held["id"])
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
held = store["%s#%s" % (sys.argv[2], sys.argv[3])]
held["session"] = sys.argv[4]
# STARTED, because linking a session is one of the five facts Review Desk judges it on. The
# stand-in set only `session` until DEV-962 gave `started` a reader, and a linked round that
# reported itself unstarted had every push routed as work to offer rather than a session to wake.
held["started"] = True
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
printf '\n  DEV-959: a watcher shut by the merge under a MID-ROUND worker\n'
# The hole DEV-959's own fix opens, and it is DEV-934's bug reached through the fix's door.
# `watch_stop_reason` now ends a review watcher on a merge at ANY status, so an `active` worker
# mid-round has shut eyes too -- and `cannot_be_told`'s guard tested for `done`, which was the
# only status the old stop rule could produce. The cursor saying closed is unambiguous evidence:
# only `watch_stop_reason` can have left it, and nothing will write that file again.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=active repo=acme/portal number=418 session_id=live-9 --by test
no_sessions
session live-9
echo '{"pr_status":"merged","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "an active key whose PR merged is not listening" "$(count '"event": "review_desk_resume"')" 1
ok "  and the event still names the session"        "$(says '"session_id": "live-9"')" yes
ok "  with the status it actually holds"            "$(says '"ledger_status": "active"')" yes
ok "  and the tick exits clean"                     "$rc" 0
no_sessions
# `needs-input` too -- a worker parked on a question has armed, and a merge shuts its eyes the
# same way. The statuses that may be in this position are exactly ALIVE minus `claimed`.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=needs-input repo=acme/portal number=418 session_id=live-9 --by test
no_sessions
session live-9
echo '{"pr_status":"merged","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "needs-input with a merged PR is not listening"  "$(count '"event": "review_desk_resume"')" 1
no_sessions
# An ABSENT cursor stays scoped to `done`, and widening it was a blocker this harness caught.
# `_common.md` step 2 writes `active` and step 3 arms the watcher, so for those few seconds an
# absent cursor is a watcher that has YET TO START -- and reading it as gone dispatches a
# replacement beside a session about to listen. `done` has no such gap: a worker reports it only
# after a full pass.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=active repo=acme/portal number=418 session_id=live-9 --by test
no_sessions
session live-9
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "an active key with NO cursor keeps the item"    "$(count review_desk)" 0
no_sessions
# And a `claimed` key is never read as deaf whatever its cursor says: the Dispatcher writes that
# status before `allele_sessions_create`, so there is no session and nothing has armed.
instance '{"mode":"auto"}'
work_doc nits_to_ticket 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=claimed repo=acme/portal number=418 session_id=live-9 --by test
no_sessions
session live-9
echo '{"pr_status":"merged","pr":{"repo":"acme/portal","number":418}}' \
  > "$inst/runtime/watch/gh-portal-418.json"
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "a claimed key is never read as deaf"            "$(count review_desk)" 0
no_sessions

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
# Counted by name rather than by the prefix `exactly as **`. The prefix is good practice
# anywhere -- DEV-929 added a third use of it, pointing at **The draft, and then wait** from the
# posting steps -- so counting it made a correct cross-reference look like a regression here.
# What this assertion is for is that each of the two event rows names its section.
ok "  the approved row names its section"            "$(grep -c 'exactly as \*\*Posting exactly once\*\*' "$worker_md")" 1
ok "  and the nits row names its own"                "$(grep -c 'exactly as \*\*Filing the held-back' "$worker_md")" 1
ok "  and a null ticket blocks the filing, not the session" "$(grep -c 'file nothing until they answer' "$worker_md")" 1
ok "  a merged pull request does not cancel the ticket"  "$(grep -c 'merged pull request does not cancel' "$worker_md")" 1
ok "SKILL.md names the fifth kind"                     "$(grep -c 'fifth kind is .nits_to_ticket' "$skill_md")" 1

printf '\n  DEV-959: what the briefs tell a worker whose pull request has gone\n'
# Prose, and asserted here for the reason every other prose check in this file is: a behaviour
# the code gets right and the brief contradicts is a behaviour no worker performs. The reader is
# an agent, and the brief is the interface.
common_md="$root/skills/dispatcher/workers/_common.md"
ok "review.md has a section for the merge"             "$(grep -c '^## When the pull request merges or closes$' "$worker_md")" 1
ok "  and the pr_state row sends the worker to it"     "$(grep -c 'your work is over. Say one line and end' "$worker_md")" 1
# TWICE, since DEV-962: the merge section and the draft-or-withdrawn section ask for the same
# three things, because a reader of either line needs the same three. Pinned at two rather than
# loosened, so a deletion from either section is still a failure.
ok "  it names the round in the line it asks for"       "$(grep -c 'the round you were on' "$worker_md")" 2
ok "  and whether the draft was posted"                "$(grep -c 'whether your draft was posted' "$worker_md")" 2
ok "  it gives a worked example of that line"          "$(grep -c 'PR merged — round 2 draft was waiting' "$worker_md")" 1
ok "  it forbids advancing the review, not writing"    "$(grep -c 'Write nothing more to Review Desk that would advance' "$worker_md")" 1
ok "  and still requires the posting to be recorded"   "$(grep -c 'draft posted --github-review <id>' "$worker_md")" 1
ok "  merged writes the terminal ledger status"        "$(grep -c 'status=merged --by worker' "$worker_md")" 1
ok "  a close does NOT, being reversible"              "$(grep -c 'the reason is that a close is reversible' "$worker_md")" 1
ok "  end means stop working, not self-discard"        "$(grep -c 'which means stop working, not remove yourself' "$worker_md")" 1
ok "  and the nits ticket still wins over ending"      "$(grep -c '\*\*The ticket$' "$worker_md")" 1
# And wins over step 2 specifically. `merged` is what makes the poller offer the request to a
# replacement, so writing it before filing is two sessions on one ticket.
ok "  and is filed before the terminal status"         "$(grep -c 'before you write .merged.' "$worker_md")" 1
ok "the posting step refuses a merged pull request"    "$(grep -c 'an approved draft on a merged or closed pull request is not posted' "$worker_md")" 1
ok "  and says which of the two orderings it was"      "$(grep -c 'approved after the merge, not posted' "$worker_md")" 1
ok "_common.md routes the pull_request stop reason"    "$(grep -c '\*\*.pull_request. means the pull request merged or closed\*\*' "$common_md")" 1
ok "  and no longer calls a merge nothing to do"       "$(grep -c 'expected after .discarded., .failed. or a merged PR' "$common_md")" 0
ok "  its pr_state row separates review from the rest" "$(grep -c 'On a review, your work is over' "$common_md")" 1
ok "  and the arming step says a review stops early"   "$(grep -c 'On a review it stops as soon as the PR merges or closes' "$common_md")" 1
ok "  in the same pass that read the merge"            "$(grep -c 'it stops in the .same. pass that read the merge' "$common_md")" 1
ok "  and no stale claim that it waits a pass"         "$(grep -c 'on the pass .after. the one that read' "$common_md")" 0
ok "SKILL.md handles the worker's merge report"        "$(grep -c 'A review worker saying its pull request merged or closed' "$skill_md")" 1
ok "  and has a row for the poller's own drop"         "$(grep -c '| .review_request_closed. |' "$skill_md")" 1
ok "  saying the state was read live from GitHub"      "$(grep -c 'read live from GitHub, not from the' "$skill_md")" 1
ok "  and that no review_request reaches it for one"   "$(grep -c 'never reaches you as a .review_request.' "$skill_md")" 1
ok "  and names the one thing still written"           "$(grep -c 'never held a review of \*\*at all\*\*' "$skill_md")" 1
ok "  saying a reviewed one is left alone"             "$(grep -c 'never written to again' "$skill_md")" 1
ok "  and that neither case is dispatched"             "$(grep -c 'Nothing is dispatched$' "$skill_md")" 1
ok "  and that the recorded row stays out of dispatch" "$(grep -c 'held out of dispatch for good' "$skill_md")" 1
ok "  the event row reads review_desk_id both ways"    "$(grep -c 'says whether the request made it onto' "$skill_md")" 1
ok "CHANGELOG records the narrowed criterion"          "$(grep -c 'never held a review of at all' "$root/CHANGELOG.md")" 1

printf '\n  DEV-959: a closed pull request Review Desk has never reviewed is still recorded\n'
# Patrick amended the criterion after the review of the first commit objected to it: "record no
# request for a merged pull request" deletes the one row DEV-945 exists to produce -- a request
# nobody got to, on a pull request that then merged unreviewed, which IS the review that did not
# happen. So the narrowed rule: record only where the store holds no review of that pull request
# at all, never open a round, never dispatch. Driven through the real argv path and the stand-in's
# own store, so "a round was not spent" is an assertion about `review open`'s answer and not about
# a mock of it.

# merged_doc <repo> <pr> <head> <state>: a search page of one row, carrying a PullRequest state.
merged_doc () {
  search_doc "$1" "$2" "$3"
  python3 - "$work/gh.search" "$4" <<'PYSTATE'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1]); doc = json.loads(d.read_text())
doc["data"]["search"]["nodes"][0]["state"] = sys.argv[2]
d.write_text(json.dumps(doc))
PYSTATE
}

for state in MERGED CLOSED; do
  instance '{"mode":"auto"}'
  merged_doc acme/portal 414 sha414 "$state"
  echo '{"state":"'"$state"'"}' > "$work/pr.414.json"
  no_sessions
  rc=$(run "$disp" poll 1)
  ok "a $state pull request with no review is looked up" "$(finds)" 1
  ok "  and recorded, once"                              "$(opens)" 1
  # Round 1, read off the stand-in's own store rather than off the call: "no round was spent" is
  # a statement about what `review open` DID, and the stand-in models the round rule measured at
  # review-desk 2180224. A first review cannot be a second round, which is the whole carve-out.
  ok "  as a FIRST review, so no round is spent"         "$(python3 -c "
import json
print(json.load(open('$work/rd.opens.json'))['acme/portal#414']['round'])")" 1
  ok "  and the drop is said, with the review it wrote"  "$(count '"event": "review_request_closed"')" 1
  ok "  carrying a review id rather than null"           "$(grep -c '"review_request_closed".*"review_desk_id": [0-9]' "$work/out" || true)" 1
  ok "  and its dashboard page"                          "$(says '/reviews/')" yes
  ok "  while nothing is dispatched for it"              "$(count '"event": "review_request"')" 0
  ok "  and no replacement either"                       "$(count '"event": "review_desk_resume"')" 0
  ok "  nor anything said about the install"             "$(count review_desk_unavailable)" 0
  ok "  and the tick exits clean"                        "$rc" 0
  # A second tick inside `reemit_after_secs`: the look and the write are both behind the same
  # gate, so neither repeats. Without the gate this is one `review find` per tick for ever.
  rc=$(run "$disp" poll 1)
  ok "  a second tick looks no further"                  "$(finds)" 1
  ok "  and writes nothing more"                         "$(opens)" 1
done

printf '\n  but a pull request it HAS reviewed is never written to again\n'
# The harm the whole ticket is about: `review open` on a moved head, against a review a session
# is linked to, is the NEXT ROUND -- measured at review-desk 2180224 and modelled by the
# stand-in. Opened at sha414 and then merged at a different head, which is the real shape: the
# author pushes, the round opens, the pull request merges.
# Seeded rather than recorded by a first tick, and the reason is the rate limit above: the look
# and the write sit behind one `due` mark, so a second tick inside `reemit_after_secs` does
# nothing at all -- which the two assertions above prove and which makes it the wrong vehicle for
# this case. The store is handed a review of 417 at sha417 directly, and the search then shows
# the row merged at a head the author pushed since, which is the real shape: a review exists, the
# author pushes, the pull request merges. `review open` on that is the NEXT ROUND, measured at
# review-desk 2180224, and it is the harm the whole ticket is about.
instance '{"mode":"auto"}'
python3 - "$work/rd.opens.json" <<'PYSEED'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps(
    {"acme/portal#417": {"id": 3, "head": "sha417", "ledger": None, "round": 1}}))
PYSEED
merged_doc acme/portal 417 sha999 MERGED
echo '{"state":"MERGED"}' > "$work/pr.417.json"
no_sessions
rc=$(run "$disp" poll 1)
ok "a reviewed pull request is looked up"              "$(finds)" 1
ok "  and never written to"                            "$(opens)" 0
ok "  so the store still holds round 1"                "$(python3 -c "
import json
print(json.load(open('$work/rd.opens.json'))['acme/portal#417']['round'])")" 1
ok "  and still holds the head it was opened at"       "$(python3 -c "
import json
print(json.load(open('$work/rd.opens.json'))['acme/portal#417']['head'])")" sha417
ok "  the drop is still said"                          "$(count '"event": "review_request_closed"')" 1
ok "  with no review id, because none was written"     "$(says '"review_desk_id": null')" yes
ok "  and nothing is dispatched"                       "$(count '"event": "review_request"')" 0
ok "  and the tick exits clean"                        "$rc" 0

printf '\n  and an install that cannot be asked is never written to blindly\n'
# `review find` answers None for an empty store and for an install it could not use, and writing
# on the second is the blind write the look exists to prevent. Each refusal mode in turn.
for mode in broken refused oldfind notobject; do
  instance '{"mode":"auto"}'
  merged_doc acme/portal 415 sha415 MERGED
  echo '{"state":"MERGED"}' > "$work/pr.415.json"
  echo "$mode" > "$work/rd.find.mode"
  no_sessions
  rc=$(run "$disp" poll 1)
  ok "find '$mode': nothing is written"                "$(opens)" 0
  ok "  and nothing is dispatched"                     "$(count '"event": "review_request"')" 0
  ok "  and the tick exits clean"                      "$rc" 0
done

printf '\n  and Review Desk off records nothing and asks nothing\n'
instance '{"mode":"off"}'
merged_doc acme/portal 416 sha416 MERGED
echo '{"state":"MERGED"}' > "$work/pr.416.json"
no_sessions
rc=$(run "$disp" poll 1)
ok "off: the store is not even looked at"              "$(finds)" 0
ok "  and nothing is written"                          "$(opens)" 0
ok "  but the drop is still said"                      "$(count '"event": "review_request_closed"')" 1
ok "  with no review id"                               "$(says '"review_desk_id": null')" yes
ok "  and the tick exits clean"                        "$rc" 0

printf '\n  DEV-959: what the independent review of the carve-out found\n'
# Six findings from one `/code-review` pass over 8b3d373, every one of them about a premise rather
# than a typo. Each gets its own assertion here, because each was invisible to the suite as it
# stood -- which is the whole reason the pass was run by something other than its author.

# 1 (medium). The `due` mark was taken BEFORE the write was attempted, so one broken tick lost the
# row for good: the mark blocked a retry for `reemit_after_secs`, and under the shipped `is:open`
# query the row leaves the search long before that. Cleared now when the install was there and
# failing -- and NOT when it is absent, which has answered.
instance '{"mode":"auto"}'
merged_doc acme/portal 418 sha418 MERGED
echo '{"state":"MERGED"}' > "$work/pr.418.json"
echo broken > "$work/rd.find.mode"
no_sessions
rc=$(run "$disp" poll 1)
ok "a broken install writes nothing"                   "$(opens)" 0
rm -f "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "  and the very next tick records it"               "$(opens)" 1
ok "  so the never-happened review is not lost"        "$(says '"review_desk_id": 1')" yes
# An ABSENT install has answered, and clearing the mark there would turn one line into one a
# tick for ever on every instance that has no Review Desk.
instance '{"mode":"auto"}'
merged_doc acme/portal 418 sha418 MERGED
echo '{"state":"MERGED"}' > "$work/pr.418.json"
no_sessions
hide
rc=$(run "$disp" poll 1)
ok "an absent install says the drop once"              "$(count '"event": "review_request_closed"')" 1
rc=$(run "$disp" poll 1)
ok "  and not again on the next tick"                  "$(count '"event": "review_request_closed"')" 0
show

# 2 (low). The live-session gate skipped the recording on "that session opened the review on its
# way in" -- false for `claimed`, which the Dispatcher writes BEFORE the session exists. The
# status is not consulted at all now; Review Desk's own answer decides.
instance '{"mode":"auto"}'
merged_doc acme/portal 419 sha419 MERGED
echo '{"state":"MERGED"}' > "$work/pr.419.json"
put gh-portal-419 mode=review status=claimed repo=acme/portal number=419 session_id=dead-1 --by test
no_sessions
rc=$(run "$disp" poll 1)
ok "a claimed key whose session never ran is recorded" "$(opens)" 1
ok "  and still nothing is dispatched for it"          "$(count '"event": "review_request"')" 0

# 5 (low). A non-empty `reviews` whose newest round is not an object used to answer a clean
# `None`, which the carve-out reads as "no review at all" -- so it would have written to a pull
# request the store DOES hold a review of.
instance '{"mode":"auto"}'
merged_doc acme/portal 420 sha420 MERGED
echo '{"state":"MERGED"}' > "$work/pr.420.json"
echo badround > "$work/rd.find.mode"
no_sessions
rc=$(run "$disp" poll 1)
ok "an unreadable round is broken, not 'none'"         "$(opens)" 0
ok "  and is said as a broken install"                 "$(says 'review find exited 0 with a round')" yes
ok "  and the tick exits clean"                        "$rc" 0

# 6 (low). The recorded row lives on the work list for ever, so `review_desk_item` re-rolls its
# `pr_state` check every interval -- and `pr_state` answers None on any `gh pr view` failure,
# which this file does not read as closed. One flaky call would eventually dispatch a worker onto
# a merged pull request: DEV-959's harm through the row DEV-959 adds. The `closed` flag on the
# record is `request_spoken_for`'s fourth shape.
instance '{"mode":"auto"}'
merged_doc acme/portal 421 sha421 MERGED
echo '{"state":"MERGED"}' > "$work/pr.421.json"
no_sessions
rc=$(run "$disp" poll 1)
ok "the closed recording is made"                      "$(opens)" 1
# Now GitHub stops showing the request AND `gh pr view` fails, which is the state that used to
# dispatch. Review Desk still has the row, and offers it as `review_requested`.
rm -f "$work/gh.search"
work_doc review_requested 1 acme/portal 421 1791520400
printf 'not json at all' > "$work/pr.421.json"
rc=$(run "$disp" poll 1)
ok "  and the row is never offered for dispatch"       "$(count '"event": "review_desk_requested"')" 0
ok "  nor as a resume"                                 "$(count '"event": "review_desk_resume"')" 0
ok "  and the tick exits clean"                        "$rc" 0
# The control: without the flag, that same state dispatches.
python3 - "$disp" "$work/noclosedflag.py" <<'PYFLAG'
import sys
src = open(sys.argv[1]).read()
old = """        if self.recorded_closed(key):
            return True"""
new = """        if False:  # CLOSED SHAPE REVERSED
            return True"""
assert old in src, "fourth shape anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYFLAG
ok "the fourth-shape reversal changed one line"        "$(grep -c 'CLOSED SHAPE REVERSED' "$work/noclosedflag.py")" 1
rc=$(run "$work/noclosedflag.py" poll 1)
ok "no fourth shape: it IS offered for dispatch"       "$(count '"event": "review_desk_requested"')" 1

printf '\n  DEV-959: what the SECOND independent review found in the first six fixes\n'
# One `/code-review` pass over 4a46530, three behavioural findings and one paragraph that had
# started lying. Each assertion below is the shape that pass reproduced.

# 1 (medium). `record_broken` is reset per TICK, not per key, so the retry clear fired on another
# row's failure: a `review show` that broke while recording an OPEN pull request cleared the
# window of a merged one three rows later, whose own look had answered cleanly -- and re-said its
# merge every tick afterwards. Only the two calls this attempt makes can speak for it now.
instance '{"mode":"auto"}'
search_pair acme/portal 422 sha422 423 sha423
python3 - "$work/gh.search" <<'PYONEMERGED'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1]); doc = json.loads(d.read_text())
# 422 open, 423 merged: one row takes the open path, the other the carve-out.
doc["data"]["search"]["nodes"][1]["state"] = "MERGED"
d.write_text(json.dumps(doc))
PYONEMERGED
echo '{"state":"OPEN"}' > "$work/pr.422.json"
echo '{"state":"MERGED"}' > "$work/pr.423.json"
no_sessions
rc=$(run "$disp" poll 1)
ok "the merged row of a mixed page is recorded"        "$(count '"event": "review_request_closed"')" 1
# Now break `review show`, which is the OPEN row's dismissal read and nothing to do with 423.
echo broken > "$work/rd.show.mode"
rc=$(run "$disp" poll 1)
ok "another row's broken read does not re-say it"      "$(count '"event": "review_request_closed"')" 0
rc=$(run "$disp" poll 1)
ok "  nor on the tick after that"                      "$(count '"event": "review_request_closed"')" 0
rm -f "$work/rd.show.mode"

# 2 (medium). One mark did both jobs, so every retry re-said the merge: a `review find` broken on
# four consecutive ticks emitted four lines, which is the "one line per tick for ever" the absent
# case was narrowed out to avoid, arriving through the broken case instead. Two marks now.
instance '{"mode":"auto"}'
merged_doc acme/portal 424 sha424 MERGED
echo '{"state":"MERGED"}' > "$work/pr.424.json"
echo broken > "$work/rd.find.mode"
no_sessions
said=0
for tick in 1 2 3 4; do
  rc=$(run "$disp" poll 1)
  said=$((said + $(count '"event": "review_request_closed"')))
done
ok "four broken ticks say the merge once"              "$said" 1
ok "  and nothing was written"                         "$(opens)" 0
# And the retry still works: the recording lands on the tick the install comes back, and THAT is
# said -- one more line, because "the row reached the list" is news the first line could not carry.
rm -f "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "the fixed install records on the next tick"        "$(opens)" 1
ok "  and says so once, with the review id"            "$(count '"event": "review_request_closed"')" 1
ok "  carrying a number rather than null"              "$(grep -c '"review_request_closed".*"review_desk_id": [0-9]' "$work/out" || true)" 1
rc=$(run "$disp" poll 1)
ok "  and never again after that"                      "$(count '"event": "review_request_closed"')" 0

# 3 (medium). The fourth shape looked `recorded` up by a differently-cased key: `recorded` is
# keyed from GitHub's `nameWithOwner`, and the work-list row with no `ledger_id` is keyed by
# `review_desk_item`'s lower-cased fallback. A build too old for `--ledger` is what produces a
# row with no `ledger_id` -- so on exactly that install, a recorded merged pull request went back
# to being offered for dispatch. Capitalised repository, `oldledger`, then GitHub goes quiet and
# `gh pr view` returns junk, which is the state that used to dispatch.
instance '{"mode":"auto"}'
merged_doc Acme/Portal 425 sha425 MERGED
echo '{"state":"MERGED"}' > "$work/pr.425.json"
echo oldledger > "$work/rd.open.mode"
no_sessions
rc=$(run "$disp" poll 1)
# TWO `review open` calls for one recording, not one: `oldledger` is a build that refuses
# `--ledger`, and `open_request` retries without the flag. That retry is what makes a row carry
# no `ledger_id`, which is what makes `review_desk_item` fall back to a lower-cased key -- so the
# count is not incidental to this case, it IS the case.
ok "a capitalised repo's merged row is recorded"       "$(opens)" 2
rm -f "$work/gh.search" "$work/rd.open.mode"
work_doc review_requested 1 acme/portal 425 1791520400
printf 'not json at all' > "$work/pr.425.json"
rc=$(run "$disp" poll 1)
ok "  and is never offered despite the casing"         "$(count '"event": "review_desk_requested"')" 0
ok "  and the tick exits clean"                        "$rc" 0
# The control: the direct `.get` the first version used, which misses the capital.
python3 - "$disp" "$work/nocasefold.py" <<'PYCASE'
import sys
src = open(sys.argv[1]).read()
old = """        return any(v.get("closed") for k, v in self.state["recorded"].items()
                   if isinstance(v, dict) and requested_key(k) == want)"""
new = """        return bool((self.state["recorded"].get(key) or {}).get("closed"))  # CASE FOLD REVERSED"""
assert old in src, "case fold anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYCASE
ok "the case-fold reversal changed one line"           "$(grep -c 'CASE FOLD REVERSED' "$work/nocasefold.py")" 1
rc=$(run "$work/nocasefold.py" poll 1)
ok "no case fold: the capitalised row IS offered"      "$(count '"event": "review_desk_requested"')" 1

# 4 (low). The paragraph that had started lying, and the reason it is worth an assertion: the
# kept `recorded` entry is what shape 4 reads, so a future editor trusting the old sentence would
# restore the prune and re-open finding 3's harm for every closed row.
ok "the docstring says the entry is KEPT"              "$(grep -c 'The .recorded. entry this leaves is KEPT' "$disp")" 1
ok "  and names the sentence it replaced"              "$(grep -c 'an earlier version of this paragraph' "$disp")" 1
# The clause moved onto a line of its own when DEV-962 added `out_of_play` to it, so this now
# pins the pair without the closing brace. Still exactly one place, which is the claim.
ok "  while the prune still keeps it"                  "$(grep -c 'v.get("dismissed") or v.get("closed")' "$disp")" 1

printf '\n  DEV-959: two closed rows on one broken tick, and neither is lost\n'
# The review of `bb9f886` read `broken_since` (then `broken_calls`, a SET of names) and argued
# that a second closed row whose own attempt broke the SAME call would see no change, hold its
# window, and be lost when the row left the search. **Measured, that does not happen**, and the
# numbers below are why: `finds` is 1 on the broken tick, not 2 -- every path that marks these
# two calls broken also sets `record_stopped`, and the guard on it precedes the window, so the
# second row never takes a window to hold. Both rows record on the tick the install comes back.
#
# The count replaced the set anyway. The set was correct only because of an invariant two
# functions away, which is the shape of premise this branch has been caught by four times; a
# count is right whether or not it holds. This test is what says which it is.
instance '{"mode":"auto"}'
search_pair acme/portal 426 sha426 427 sha427
python3 - "$work/gh.search" <<'PYBOTHMERGED'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1]); doc = json.loads(d.read_text())
for node in doc["data"]["search"]["nodes"]:
    node["state"] = "MERGED"
d.write_text(json.dumps(doc))
PYBOTHMERGED
echo '{"state":"MERGED"}' > "$work/pr.426.json"
echo '{"state":"MERGED"}' > "$work/pr.427.json"
echo broken > "$work/rd.find.mode"
no_sessions
rc=$(run "$disp" poll 1)
ok "a broken tick writes neither row"                  "$(opens)" 0
ok "  asking once for the page, not once per row"      "$(finds)" 1
ok "  and says each merge once"                        "$(count '"event": "review_request_closed"')" 2
# The window marks are the finding's own subject: NEITHER is held after the broken tick. The
# first row's was taken and cleared; the second row's was never taken.
ok "  and holds no recording window for either"        "$(python3 -c "
import json
s = json.load(open('$inst/runtime/poll-state.json'))
print(sum(1 for k in s.get('emitted', {}) if k.endswith('|review_request_record')))")" 0
rm -f "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "the fixed install records BOTH rows next tick"     "$(opens)" 2
ok "  and the store holds both reviews"                "$(python3 -c "
import json
print(len(json.load(open('$work/rd.opens.json'))))")" 2
ok "  neither row was lost"                            "$(python3 -c "
import json
held = json.load(open('$work/rd.opens.json'))
print(sorted(k.rsplit('#', 1)[1] for k in held))")" "['426', '427']"
ok "  and the tick exits clean"                        "$rc" 0

# The counter itself, directly: two broken answers from one call must read as two, where the set
# it replaced read as one. This is the assertion that would fail on the set version.
instance '{"mode":"auto"}'
ok "a repeated broken call counts twice"               "$(python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('d', '$disp')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p = m.Poller.__new__(m.Poller)
p.record_broken, p.broken_seq = {}, {}
first = p.broken_since()
p.note_broken('review find', 'broken', 'd', 'r')
one = p.broken_since()
p.note_broken('review find', 'broken', 'd', 'r')
print(first, one, p.broken_since())")" "(0, 0) (1, 0) (2, 0)"
ok "  and an absent answer counts none"                "$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('d', '$disp')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p = m.Poller.__new__(m.Poller)
p.record_broken, p.broken_seq = {}, {}
p.note_broken('review find', 'absent', 'd', 'r')
print(p.broken_since(), p.record_broken['review find'][0])")" "(0, 0) absent"

printf '\n  DEV-959: the merged row still speaks for itself through the other source\n'
# The ordering the GitHub pass depends on, and it is not obvious from either side. A merged row
# is dropped before it is recorded or offered -- but `self.requested.add` happens BEFORE that
# drop, because `review_desk_item` reads `pr_state` LIVE and that call can fail: `pr_state`
# returns None, this file refuses to read None as closed, and `review_desk_requested` would be
# emitted for the very pull request the GitHub pass had just silenced. `request_spoken_for`'s
# first shape -- "GitHub showed the Dispatcher this request" -- is then the only guard, and it is
# fed from that line. Driven with a `gh pr view` that returns unparseable output, which is what
# `gh()` turns into the exception `pr_state` swallows.
instance '{"mode":"auto"}'
search_doc acme/portal 418 abc123
python3 - "$work/gh.search" <<'PYMERGE'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1]); doc = json.loads(d.read_text())
doc["data"]["search"]["nodes"][0]["state"] = "MERGED"
d.write_text(json.dumps(doc))
PYMERGE
work_doc review_requested 9 acme/portal 418 1791520400
printf 'not json at all' > "$work/pr.418.json"
no_sessions
rc=$(run "$disp" poll 1)
# The property is ONE offer, not none. `pr_state` returning None is GitHub not answering, and
# this file refuses to read that as closed -- "an item the dispatcher cannot place is better
# dispatched and discarded by a human who can read the pull request than dropped silently" -- so
# the GitHub pass offers the row, which is the right half of the pair to keep. What must NOT
# happen is the Review Desk source offering it as well, which is two sessions on one review, and
# shape 1 of `request_spoken_for` is the only thing stopping it in this exact state.
ok "an unreadable pr_state still offers the row once"  "$(count '"event": "review_request"')" 1
ok "  and the Review Desk source stays quiet"          "$(count '"event": "review_desk_requested"')" 0
ok "  so one request reaches the Dispatcher, not two"  "$(count '"event": "review_desk_resume"')" 0
ok "  and the tick exits clean"                        "$rc" 0
# The control that makes the quiet half mean something: delete the merged row's membership of
# `self.requested` and the Review Desk source speaks for the same pull request.
python3 - "$disp" "$work/noshape1.py" <<'PYSHAPE'
import sys
src = open(sys.argv[1]).read()
old = """        if requested_key(key) in self.requested and entry.get("status") in REDISPATCHABLE:
            return True"""
new = """        if False:  # SHAPE 1 REVERSED
            return True"""
assert old in src, "shape 1 anchor missing"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYSHAPE
ok "the shape 1 reversal changed one line"             "$(grep -c 'SHAPE 1 REVERSED' "$work/noshape1.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 418 abc123
python3 - "$work/gh.search" <<'PYMERGE2'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1]); doc = json.loads(d.read_text())
doc["data"]["search"]["nodes"][0]["state"] = "MERGED"
d.write_text(json.dumps(doc))
PYMERGE2
work_doc review_requested 9 acme/portal 418 1791520400
printf 'not json at all' > "$work/pr.418.json"
no_sessions
rc=$(run "$work/noshape1.py" poll 1)
ok "no shape 1: the merged PR is offered twice"        "$(count '"event": "review_desk_requested"')" 1

printf '\n  DEV-959: the one discard the Dispatcher makes without asking\n'
# Patrick decided this on the ticket ("yes, let it discard merged sessions itself"), as a narrow
# exception to `## Never`'s standing rule. It is the Dispatcher's act, through the allele MCP
# tool, so there is no Locus code path to drive -- which is itself the thing worth pinning, and
# the stand-in below is how. A `allele` on PATH that records every call, and zero calls after a
# full poll tick and a watch tick: nothing in this repo can discard a session, so every discard
# that ever happens is one a Dispatcher session chose, from prose a human can read and audit.
cat > "$work/bin/allele" <<'ALLELESTANDIN'
#!/bin/sh
printf '%s\n' "$*" >> "$RDWORK/allele.calls"
exit 0
ALLELESTANDIN
chmod +x "$work/bin/allele"
rm -f "$work/allele.calls"
instance '{"mode":"auto"}'
work_doc draft_approved 9 acme/portal 418 1791520400 gh-portal-418
put gh-portal-418 mode=review status=active repo=acme/portal number=418 session_id=live-9 --by test
echo '{"state":"MERGED"}' > "$work/pr.418.json"
rc=$(run "$disp" poll 1)
ok "a poll tick over a merged PR discards nothing"     "$([ -f "$work/allele.calls" ] && echo some || echo none)" none
rc=$(run "$disp" watch gh-portal-418 --once)
ok "  and neither does a watch tick"                   "$([ -f "$work/allele.calls" ] && echo some || echo none)" none
ok "  no code in the skill calls a discard at all"     "$(grep -c 'sessions_discard(' "$disp")" 0
# What a Dispatcher writes AFTER its own discard, which is code and is driven for real.
put gh-portal-418 status=discarded --by dispatcher --note "PR merged"
ok "the ledger records the discard and who made it"    "$(python3 -c "
import json, sys
e = json.load(open('$inst/runtime/ledger/gh-portal-418.json'))
print(e['status'], e['history'][-1]['by'], e['history'][-1].get('note'))")" "discarded dispatcher PR merged"

printf '\n  and what ## Never says about it, in place beside the rule\n'
# AC 4 is literally about where this is written: the rule and its exception have to be read
# together, or the next reader of `## Never` learns a rule that is no longer true.
never () { sed -n '/^## Never$/,$p' "$skill_md"; }
ok "the standing rule is still stated"                 "$(never | grep -c 'Discard without your principal.s explicit yes')" 1
ok "  and the exception is stated beside it"           "$(never | grep -c 'these three$')" 1
ok "  condition 1: only a review worker"               "$(never | grep -c 'a \*\*review\*\* worker, no other mode')" 1
ok "  condition 2: GitHub says merged or closed"       "$(never | grep -c 'GitHub reports .merged. or .closed.')" 1
ok "  and not Review Desk saying so"                   "$(never | grep -c 'Not Review Desk$')" 1
ok "  condition 3: only once it has stopped"           "$(never | grep -c 'A worker mid-turn is not$')" 1
ok "  checked with allele_sessions_status"             "$(never | grep -c 'allele_sessions_status(session_id). first')" 1
ok "  it reports after the fact, not before"           "$(never | grep -c 'say so once, after the fact')" 1
ok "  and never silently"                              "$(never | grep -c 'indistinguishable from one that crashed')" 1
ok "  everything else still needs the yes"             "$(never | grep -c 'Everything else still needs the yes')" 1
ok "  naming an open PR as still needing it"           "$(never | grep -c 'whose pull request is still$')" 1
ok "the review_cleared row carries the exception too"  "$(grep -c 'where you discard without asking' "$skill_md")" 1
ok "  and still asks on every other reason"            "$(grep -c 'Every other reason still asks' "$skill_md")" 1
ok "the worker-report row discards without asking"     "$(grep -c 'discard it yourself, without asking' "$skill_md")" 1
ok "start-up reconciles a merged key the same way"     "$(grep -c 'whose entry says .merged.: that worker finished' "$skill_md")" 1
# The worker's side has to agree with it. Written before Patrick's decision, review.md said
# "The Dispatcher reports your line and offers the discard; only your principal answers that" --
# which the decision made flatly false, and a worker reading it would have expected a session
# that no longer exists. The two files are each other's only check here.
ok "review.md says the discard is not asked about"     "$(grep -c 'this is the one discard nobody is asked about' "$worker_md")" 1
ok "  and that its line is the last it will say"       "$(grep -c 'the last thing you will ever' "$worker_md")" 1
ok "  while still forbidding a self-discard"           "$(grep -c 'It is still not yours to do' "$worker_md")" 1
ok "  and no stale promise that the session persists"  "$(grep -c 'offers the$' "$worker_md")" 0
ok "_common.md names the exception beside its Never"   "$(grep -c 'the only discard not put to' "$common_md")" 1
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
# is what makes it safe over a block holding one live instance's 300 against the template's 90.
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
# The store the stand-in writes lives under $work, like everything else here, and since DEV-945
# `REVIEW_DESK_DB` is exported at the top of this file as a temporary path as well -- so a real
# binary reaching PATH by some route would open that file rather than `~/.review-desk`. The
# sentence this replaces said the variable was never set, which was true until the poller began
# to write.
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
  "review open --repo acme/portal --pr 412 --head sha412 --title=Retry --ledger gh-portal-412 --json"
ok "  the ledger id is this instance's own key"        "$(grep -c '^gh-portal-412$' "$work/rd.open.argv")" 1
ok "  and no ticket is invented for it"                "$(grep -c '^--ticket$' "$work/rd.open.argv")" 0

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 "Retry failed webhook deliveries"
rc=$(run "$disp" poll 1)
ok "a title with spaces is ONE argument"               "$(grep -c '^--title=Retry failed webhook deliveries$' "$work/rd.open.argv")" 1

instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 -
rc=$(run "$disp" poll 1)
ok "a row with no title is still recorded"             "$(opens)" 1
ok "  and --title is not passed empty"                 "$(grep -c '^--title' "$work/rd.open.argv")" 0

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
# **DEV-962 reverses this, deliberately.** It used to read "a request a live session holds is
# NOT recorded", because `review open` on a started review's new head opened round N+1 -- so the
# poller stayed away and the worker spent the round when it next looked. A round is now a posted
# review, so an unposted one MOVES and the poller is the right caller: it is the one that sees
# the push every tick and the only one that can tell the Dispatcher not to dispatch.
ok "a request a live session holds IS recorded now"    "$(opens)" 1
ok "  and no round is spent on it"                     "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 1
ok "  and nothing is offered for it"                   "$(count '"event": "review_request"')" 0
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
# Two writes for two ticks, and the second one MOVES rather than opening a round -- which is the
# whole of DEV-962 item 5. The claim this test was written to make is unchanged and is the third
# assertion: the review stays on its round.
ok "a push on a dispatched request moves its head"     "$(opens)" 2
ok "  and dispatches nothing"                          "$(count '"event": "review_request"')" 0
ok "  the review stays on its round"                   "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 1
ok "  and the session holding it is woken instead"     "$(count '"event": "review_head_moved"')" 1
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
ok "a push on a lost session's review spends no round" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 1
# It is written to now -- the head moves -- and the ROUND is what the claim was always about.
# And it is a wake rather than an offer, because the review itself says somebody began it: the
# Dispatcher reads `session_live` and dispatches ONE replacement, linked to the same review.
ok "  being written to, which moves it"                "$(opens)" 2
ok "  and the move is a wake, not an offer"            "$(count '"event": "review_head_moved"')" 1
ok "  saying the session that began it is gone"        "$(says '"session_live": false')" yes

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
  "review open --repo acme/portal --pr 412 --head sha999 --title=Retry --ledger gh-portal-412 --json"
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

# And the case the comparison exists for: a record seeded by the LOOK, which carries Review
# Desk's normalised spelling, against the commit GitHub is showing. Nothing has moved, so
# nothing is written -- and the two sides are spelled differently.
instance '{"mode":"auto"}'
preopen acme/portal 412 sha412upper 7
search_doc acme/portal 412 SHA412UPPER Retry
rc=$(run "$disp" poll 3)
ok "a looked-up commit in another case is the same commit" "$(opens)" 0
ok "  looked up once, not once a tick"                 "$(finds)" 1

# **Nothing is written to a review this poller has not looked at.** The first call on a key
# used to be the write, and a review somebody else opened -- the dashboard, another instance --
# may already have a session on it, which makes a push the next ROUND. So the first sight of a
# request LOOKS, and the look is a read.
instance '{"mode":"auto"}'
preopen acme/portal 412 oldhead 7 sess-dash
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "the first sight of a request looks first"          "$(finds)" 1
# The look's job changed with DEV-962 and is still the reason it happens first. It used to decide
# whether to WRITE; the write is now safe either way, and what the look supplies is whose review
# this is -- the `session_id` and `started` that decide whether the move is relayed to the session
# holding it or offered as work. A review opened from the dashboard has neither on this
# instance's ledger, which is the case the look exists for.
ok "  and the linked review is moved, not spent"       "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 1
ok "  while remembering what it found"                 "$(remembered gh-portal-412 review)" 7
ok "  including the session on it"                     "$(remembered gh-portal-412 session)" sess-dash
ok "  which makes the move a wake for that session"    "$(count '"event": "review_head_moved"')" 1
ok "  and offers the request to nobody else"           "$(count '"event": "review_request"')" 0

# The same look on a review nobody has started: the head moves, as it always did.
instance '{"mode":"auto"}'
preopen acme/portal 412 oldhead 7
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "an unstarted review it never opened is moved"      "$(opens)" 1
ok "  to the commit GitHub showed"                     "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["head"])' "$work/rd.opens.json")" sha412

# A pull request with no review at all: the look answers `reviews: []`, exit 0, and the write
# creates it. That is the ordinary case and it must not read as a failure.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "a pull request with no review is looked up"        "$(finds)" 1
ok "  and then created"                                "$(opens)" 1
ok "  with nothing said about it"                      "$(count review_desk_unavailable)" 0
rc=$(run "$disp" poll 1)
ok "  and not looked up again once recorded"           "$(finds)" 1

# **A build with no `review find` records without looking**, which is the behaviour that
# preceded the look. Looking guards against spending a round on a review somebody else opened;
# recording at all is the ticket, so the look is what degrades, loudly and once -- and the
# `--ledger` retry for old builds stays reachable, which it was not when this stopped recording.
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo oldfind > "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "a build with no \`review find\` still records"      "$(opens)" 2
ok "  looking once, not once per request"              "$(finds)" 1
ok "  and says the look is unavailable, once"          "$(count '"event": "review_desk_unavailable"')" 1
ok "  naming the call"                                 "$(says '"call": "review find"')" yes
ok "  and both requests are dispatched"                "$(count '"event": "review_request"')" 2

# A look REFUSED for this pull request is a different fact: the look is available and this
# request could not be looked at, so nothing is written to it and the page carries on.
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo refused > "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "a refused look writes nothing"                     "$(opens)" 0
ok "  is reported once for the repository"             "$(count '"event": "review_desk_unavailable"')" 1
ok "  as a refusal, with one request as its example"   "$(says '"example": true')" yes
ok "  and both requests are still dispatched"          "$(count '"event": "review_request"')" 2

# A look that cannot be made stops the recording: a write nobody could look at first is the
# thing the look exists to prevent.
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo broken > "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "a broken look writes nothing"                      "$(opens)" 0
ok "  is asked once a tick"                            "$(finds)" 1
ok "  and is said, naming the call"                    "$(says '"call": "review find"')" yes

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
  "review open --repo acme/portal --pr 412 --head sha412 --title=Retry --json"
ok "  the request is recorded all the same"            "$(remembered gh-portal-412 head)" sha412
ok "  and nothing extra is said about it"              "$(count review_desk_unavailable)" 0

# **A build with no `--ledger` has no MOVE either**, so the head is not followed on it: one
# `review open` on a new commit would be a second unstarted review for one request, which is
# the thing DEV-945's other half exists to prevent. Recorded once, then left alone -- the
# behaviour that preceded this branch, which is where every degradation here lands.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo oldledger > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "an older build records the request once"           "$(opens)" 2
ok "  and is remembered as old"                        "$(remembered gh-portal-412 old)" True
search_doc acme/portal 412 sha999 Retry
age_marker 'gh-portal-412|review_request'
rc=$(run "$disp" poll 1)
# The ROUND, not the number of rows: this store keeps one row per pull request because a new
# round replaces the one before it, so a second review shows as round 2. The first draft of
# this counted rows and would have passed without the guard.
ok "  a push on it opens no second review"             "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 1
ok "  and the request is still dispatched"             "$(count '"event": "review_request"')" 1

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
# **A truncated page is where this matters most, and is where it was missing.** A page at the
# query's limit is FULL, so the loop runs and the recordings are attempted -- but the tick
# returns before committing anything, and the notice used to be on the far side of that return.
NOMAP=1 instance '{"mode":"on"}'
search_page acme/portal 50 60
echo broken > "$work/rd.mode"
rc=$(run "$disp" poll 1)
ok "a truncated page still reports a broken install"   "$(count '"event": "review_desk_unavailable"')" 1
ok "  and still says the page was truncated"           "$(count '"event": "source_empty"')" 1
ok "  and still emits the requests it did see"         "$(count '"event": "review_request"')" 50

# **One subcommand can fail while the other answers.** `work list` is a read and `review open`
# is a write, so write contention with the dashboard breaks one and not the other -- and the
# reading pass has nothing to say about a write it never makes. The recording path says it.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo broken > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "a broken \`review open\` is reported on its own"    "$(count '"event": "review_desk_unavailable"')" 1
ok "  as broken"                                       "$(says '"state": "broken"')" yes
ok "  naming the repository it was met on"             "$(says '"repo": "acme/portal"')" yes
ok "  and the call that failed"                        "$(says '"call": "review open"')" yes
ok "  while the work list is still read"               "$(grep -c '^work list' "$work/rd.calls")" 1

# With a repository to ask about, BOTH paths meet the same broken install and it is still one
# line: they share the event, the mode rule and the rate-limit mark.
instance '{"mode":"on"}'
search_doc acme/portal 412 sha412 Retry
echo broken > "$work/rd.mode"
rc=$(run "$disp" poll 1)
ok "with repositories it is still one notice"          "$(count '"event": "review_desk_unavailable"')" 1

# **A dismissed review whose worker died.** The dismissal must be read and honoured for every
# request that could be DISPATCHED, which is a wider set than the requests that are written to:
# this entry carries a `session_id`, so nothing may write to its review, and it is `lost`, so a
# replacement is exactly what the poller would otherwise ask for.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
dismiss acme/portal 412 "the pull request was closed unmerged"
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 session_id=dead-9 --by test
age_marker 'gh-portal-412|review_request'
rc=$(run "$disp" poll 1)
ok "a dismissed review with a dead session is read"    "$(shows)" 1
ok "  and is not dispatched"                           "$(count '"event": "review_request"')" 0
ok "  and the dismissal is said"                       "$(count '"event": "review_dismissed"')" 1
ok "  with nothing written to it"                      "$(opens)" 1

# And the id can come from the LEDGER, which is the only source for a review this poller never
# recorded: a worker writes `review_desk_id` on its entry before anything else.
# **Reached through a REFUSED look, which is the one shape that leaves no review id anywhere
# but the ledger.** Before DEV-962 this test drove it through a linked session, because `linked`
# took the write away and left the read; the write is now safe on a linked review, so the only
# thing that still takes it away is a look that did not happen -- and `looked` is exactly that
# flag. The ledger is then the sole source of the id, which is what this asserts.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 session_id=dead-9 review_desk_id=11 --by worker
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
echo refused > "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "a review only the ledger knows the id of is read"  "$(shows)" 1
ok "  and nothing was written to it"                   "$(opens)" 0

# An exit-0 answer this file cannot read is BROKEN, said, and stopped -- because nothing lands
# in the record, so the commit never matches, so the next tick would write again, and the next.
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo notobject > "$work/rd.open.mode"
rc=$(run "$disp" poll 2)
ok "an unreadable answer is asked once a tick"         "$(opens)" 2
ok "  and said once"                                   "$(count '"event": "review_desk_unavailable"')" 1
ok "  as too old to use"                               "$(says 'too old to use')" yes

# A title beginning with a hyphen. clap reads a separate value starting with `-` as a flag it
# has never heard of, which this file would read as "no `--ledger` on this build", retry, fail
# the same way, and report a refusal -- for every tick that pull request stayed open.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 "-fix the thing"
rc=$(run "$disp" poll 1)
ok "a title beginning with a hyphen is recorded"       "$(remembered gh-portal-412 head)" sha412
ok "  as one argument carrying its own flag"           "$(grep -c '^--title=-fix the thing$' "$work/rd.open.argv")" 1
ok "  with no refusal reported"                        "$(count review_desk_unavailable)" 0

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

# A `work list` item whose `ledger_id` is not a string. Nothing here type-checks it, and the
# key-case comparison would otherwise raise out of the per-repository loop and lose the whole
# Review Desk pass for that tick.
instance '{"mode":"auto"}'
python3 -c "
import json, pathlib, sys
doc = {'work': [{'kind': 'review_requested', 'review_id': 11, 'repo': 'acme/portal', 'pr': 412,
                 'head_sha': 'sha412', 'round': 1, 'sign_off': None, 'session_id': None,
                 'ledger_id': 412, 'entered_at': 1791520282, 'note': None,
                 'nit_ticket_status': 'none', 'nit_ticket_requested_at': None}]}
pathlib.Path(sys.argv[1]).write_text(json.dumps(doc))" "$work/rd.work"
rc=$(run "$disp" poll 1)
ok "a non-string ledger id does not throw"             "$(count '"event": "error"')" 0
ok "  and exits clean"                                 "$rc" 0

# **The look, on a repository GitHub spells with capitals.** `review find` is the one `--repo`
# Review Desk does not normalise, and it echoes the query back, so a mismatch answers "no review
# here" and looks like an answer. The stand-in is case-sensitive in the same way the real binary
# is -- measured -- which is what makes this assertion mean anything.
instance '{"mode":"auto"}'
preopen acme/portal 412 oldhead 7 sess-dash
search_doc Acme/Portal 412 Retry
rc=$(run "$disp" poll 1)
ok "the look finds a review on a mixed-case slug"      "$(remembered gh-Portal-412 review)" 7
ok "  so the session on it is found too"               "$(remembered gh-Portal-412 session)" sess-dash
ok "  and no round is spent"                           "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 1
ok "  and the move is relayed to that session"         "$(count '"event": "review_head_moved"')" 1

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

# **A key somebody has already decided about is offered to nobody**, and `skipped` is only one
# of the three. `deferred` is the status this file itself defines as "never dispatched again",
# and recording on sight is what gave it a `review_requested` item to be offered through. GitHub
# is silent in these, which is the tick where the first guard cannot help.
for decided in skipped deferred merged; do
  instance '{"mode":"auto"}'
  work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
  put gh-portal-412 mode=review status=$decided repo=acme/portal number=412 --by test
  rc=$(run "$disp" poll 1)
  ok "a $decided key is not offered for dispatch"      "$(count '"event": "review_desk_requested"')" 0
done

# **A status the GitHub pass says nothing about is not suppressed.** `done`, `stopped` and
# `blocked` are ALIVE, so the GitHub pass emits nothing for them and the recording never runs;
# if the Review Desk pass went quiet too, a review whose worker stopped before writing a brief
# would stall with no source speaking for it. SKILL.md names that fifteen-minute re-offer as
# the net under a session that keeps dying.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
put gh-portal-412 mode=review status=stopped repo=acme/portal number=412 session_id=gone-1 --by test
no_sessions
rc=$(run "$disp" poll 1)
ok "a stopped review GitHub still requests is offered" "$(count '"event": "review_desk_requested"')" 1
ok "  and the GitHub pass said nothing for it"         "$(count '"event": "review_request"')" 0

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
delete acme/portal 412
rc=$(run "$disp" poll 1)
ok "a deleted review is forgotten"                     "$(recorded_count)" 0
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
ok "  and it is said, once, naming the call"           "$(count '"event": "review_desk_unavailable"')" 1
ok "  with what it costs: a dismissal cannot be read" "$(says 'a dismissal')" yes
ok "  so nothing is recorded again"                    "$(opens)" 1
ok "  and the request is still dispatched"             "$(remembered gh-portal-412 dismissed)" False

# An exit-0 `review show` whose answer carries no review is BROKEN, said once, and asked no
# more that tick -- the same rule the write path has. Without it the window was cleared on
# every tick and the dismissal guard was silently dead on such a build.
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
rc=$(run "$disp" poll 1)
echo notobject > "$work/rd.show.mode"
rc=$(run "$disp" poll 1)
ok "an unreadable \`review show\` is asked once a tick"  "$(shows)" 1
ok "  and said once"                                   "$(count '"event": "review_desk_unavailable"')" 1
ok "  naming the call that failed"                     "$(says '"call": "review show"')" yes
rc=$(run "$disp" poll 1)
ok "  and not asked twice per request after that"      "$(shows)" 2

# A refusal that is about neither the command nor the row -- a locked database -- leaves the
# record exactly where it was. Only `not_found` means a review that is gone, which is what
# `review_desk_run` says in as many words.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
echo locked > "$work/rd.show.mode"
rc=$(run "$disp" poll 1)
ok "a locked database forgets nothing"                 "$(remembered gh-portal-412 head)" sha412
ok "  and writes nothing again"                        "$(opens)" 1

# **A broken read stops reading and nothing else.** One recorded key whose `review show` times
# out must not leave every new request on the page unrecorded -- that is the gap DEV-945 exists
# to close, and one flag for both calls is how it opened.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
echo broken > "$work/rd.show.mode"
search_pair acme/portal 412 sha412 413 sha413
rc=$(run "$disp" poll 1)
ok "a broken read still records a new request"         "$(remembered gh-portal-413 head)" sha413
ok "  and says so against the call that failed"        "$(says '"call": "review show"')" yes
ok "  naming the repository, not just its name"        "$(says '"repo": "acme/portal"')" yes

# A request dismissed on the first tick still counts as backlog, so a restore later in the same
# process asks before dispatching like everything else that was waiting when the poller started.
instance '{"mode":"auto"}'
preopen acme/portal 412 sha412 7
dismiss acme/portal 412 "closed unmerged"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "a request dismissed at start-up is not dispatched" "$(count '"event": "review_request"')" 0
ok "  but is remembered as backlog"                    "$(python3 -c 'import json,sys;print("gh-portal-412" in json.load(open(sys.argv[1]))["review_backlog"])' "$inst/runtime/poll-state.json")" True
restore acme/portal 412
age_marker 'review_desk|dismissal|gh-portal-412'
rc=$(run "$disp" poll 1)
ok "  so a restore asks before dispatching"            "$(says '"backlog": true')" yes

# **A strange `review find` on one NEW request must not cancel the dismissal read for the keys
# already recorded.** `find_request` runs only for a key with no record, so the requests it can
# poison are precisely the ones that never needed it -- and the shape is not transient: it
# recurs every tick, so the dismissal guard would be dead for the life of the install.
instance '{"mode":"auto"}'
search_doc acme/portal 413 sha413 Retry
rc=$(run "$disp" poll 1)
dismiss acme/portal 413 "closed unmerged"
search_pair acme/portal 412 sha412 413 sha413
echo notobject > "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "a strange look still leaves the read running"      "$(shows)" 1
ok "  so the dismissal is still learned"               "$(remembered gh-portal-413 dismissed)" True
ok "  and nothing was written for the new request"     "$(opens)" 1
ok "  with the look reported once"                     "$(count '"event": "review_desk_unavailable"')" 1

# And the old-build fact belongs to the key that measured it, not to the tick: as a tick-wide
# flag it stamped every key recorded after it, and a key marked old never has its head followed
# again.
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo oldledger > "$work/rd.open.mode"
rc=$(run "$disp" poll 1)
ok "an old build marks both keys it measured"          "$(remembered gh-portal-413 old)" True
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo oldledger > "$work/rd.open.mode"
echo 412 > "$work/rd.open.oldfor"
rc=$(run "$disp" poll 1)
ok "the key that met the old answer is marked old"     "$(remembered gh-portal-412 old)" True
ok "  and the one after it is not"                     "$(remembered gh-portal-413 old)" False

# **The key whose own look failed is still read.** The ledger may hold the review id, and a
# dismissal readable from it must not be lost because the look for that same key came back
# unreadable -- which would also make the key record-less again next tick, for ever.
instance '{"mode":"auto"}'
preopen acme/portal 412 sha412 7
dismiss acme/portal 412 "closed unmerged"
search_doc acme/portal 412 sha999 Retry
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 review_desk_id=7 --by worker
echo notobject > "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "a failed look still reads the dismissal"           "$(shows)" 1
ok "  which is honoured"                               "$(remembered gh-portal-412 dismissed)" True
ok "  nothing is written to it"                        "$(opens)" 0
ok "  and nothing is dispatched for it"                "$(count '"event": "review_request"')" 0

# And a read with no record of its own stores the commit REVIEW DESK holds, not GitHub's: the
# record is compared against GitHub next tick, so a commit the store was never given would read
# as "already recorded" and the request would never be written again.
instance '{"mode":"auto"}'
preopen acme/portal 412 sha412 7
search_doc acme/portal 412 sha999 Retry
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 review_desk_id=7 --by worker
echo notobject > "$work/rd.find.mode"
rc=$(run "$disp" poll 1)
ok "a read with no record keeps Review Desk's commit"  "$(remembered gh-portal-412 head)" sha412
echo ok > "$work/rd.find.mode"
age_marker 'gh-portal-412|review_request'
rc=$(run "$disp" poll 1)
ok "  so the next healthy tick moves the head"         "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["head"])' "$work/rd.opens.json")" sha999

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
ok "  that a refusal is a state, with its example"    "$(grep -c 'name \*\*one example\*\* rather than the extent' "$skill_md")" 1
ok "  and that a hung install may say one line per call" "$(grep -c 'may say one line per call' "$skill_md")" 1
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
ok "  or \`find\`, which is also a read"                "$(grep -c '"review", "find", "--repo"' "$disp")" 1

# =============================================================================================
printf '\nDEV-962 -- a round is a posted review\n'
# Review Desk and this poller opened a new round whenever commits arrived on a started review,
# posted or not: Patrick's queue showed one pull request twice, round 1 and round 2 "changes
# since your last review", though he had never posted round 1 -- and the only new commits were
# the author merging the base branch in. Another reached round 4 unposted before it merged.
#
# The model, as he decided it: **a round is a POSTED review.** Before a post, new commits move
# the same round's head and the session already on it updates its draft in place. Commits that
# only bring the base branch in change nothing at all.
#
# Everything below is driven through the stand-in, whose `review open` now models the contract
# review-desk's own author measured on 13 October 2026: `action`, `--diff-unchanged`, `started`
# on the open's own answer, and an out-of-play that a created round INHERITS. The real binary at
# the bottom of this file skips these loudly until a build carrying the contract is installed.

# The pull request's own diff, as `gh api .../pulls/N/files` serves it -- the THREE-dot diff
# against the merge base, which is why merging the base in leaves it identical. Two different
# ones, so "the diff changed" and "the diff did not" are both drivable.
DIFF_ONE='[{"filename":"src/retry.py","status":"modified","patch":"@@ -1,2 +1,2 @@\n-was\n+is\n"}]'
DIFF_TWO='[{"filename":"src/retry.py","status":"modified","patch":"@@ -1,3 +1,3 @@\n-was\n+other\n"},{"filename":"src/queue.py","status":"added","patch":"@@ -0,0 +1 @@\n+new\n"}]'

printf '\n  shape A: round 1 unposted, and then the base branch arrives\n'
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 "Retry failed webhook deliveries"
rc=$(run "$disp" poll 1)
ok "the request is recorded as round 1"                "$(store_round acme/portal 412)" "1 1 sha412"
ok "  and is offered for dispatch"                     "$(count '"event": "review_request"')" 1
ok "  nothing is woken, there being nobody on it"      "$(count review_head_moved)" 0
ok "  and the contract was probed once, as a read"     "$(probes)" 1
ok "  which is not counted as a write"                 "$(opens)" 1

# A session picks it up and begins. From here the round is STARTED, which is what makes the
# next push a wake rather than an offer.
put gh-portal-412 mode=review status=active repo=acme/portal number=412 \
  session_id=sess-a session_name="Review #412" review_desk_id=1 --by dispatcher
session sess-a
"$work/bin/review-desk" review link --review 1 --session sess-a --json > /dev/null 2>&1 || true
python3 - "$work/rd.opens.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = json.loads(p.read_text())
s["acme/portal#412"].update({"session": "sess-a", "started": True})
p.write_text(json.dumps(s))
PY

# The author pushes a real change. ONE row, still round 1, the head moved, and the session that
# holds it is woken -- the whole of item 5.
files_doc 412 "$DIFF_TWO"
search_doc acme/portal 412 sha777 "Retry failed webhook deliveries"
rc=$(run "$disp" poll 1)
ok "a push before a post moves the head"               "$(store_round acme/portal 412)" "1 1 sha777"
ok "  so no round is spent"                            "$(count '"event": "review_request"')" 0
ok "  and the session on it is woken once"             "$(count '"event": "review_head_moved"')" 1
ok "  naming the commit it moved from"                 "$(says '"previous": "sha412"')" yes
ok "  and the one it moved to"                         "$(says '"current": "sha777"')" yes
ok "  and the round, which did not change"             "$(says '"round": 1')" yes
ok "  and the review, which is the same review"        "$(says '"review_desk_id": 1')" yes
ok "  and that the session is there to be woken"       "$(says '"session_live": true')" yes
ok "  naming it, so the Dispatcher can message it"     "$(says '"session_id": "sess-a"')" yes
ok "  and no --diff-unchanged was claimed"             "$(last_open | grep -c -- --diff-unchanged || true)" 0

# Said once per move, not once per tick. A wake repeated every fifteen minutes is a worker
# re-reading the same delta every fifteen minutes.
forget_calls
rc=$(run "$disp" poll 2)
ok "the same push is not said again"                   "$(count '"event": "review_head_moved"')" 0
ok "  and nothing is written for it"                   "$(opens)" 0

# **And now the base branch arrives.** The commits moved; the pull request's own diff against
# its base did not -- the file list is byte-identical. Item 6: nothing in Review Desk changes
# and nobody is woken.
search_doc acme/portal 412 sha888 "Retry failed webhook deliveries"
rc=$(run "$disp" poll 1)
ok "a base-branch merge claims the diff is unchanged"  "$(last_open | grep -c -- --diff-unchanged)" 1
ok "  so the head does not move"                       "$(store_round acme/portal 412)" "1 1 sha777"
ok "  and nobody is woken"                             "$(count review_head_moved)" 0
ok "  and nothing is offered"                          "$(count '"event": "review_request"')" 0
ok "  and the store records it as base-only"           "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"].get("base_only"))' "$work/rd.opens.json")" 1

# A second base merge on top of it is the same answer, and still one row.
search_doc acme/portal 412 sha999 "Retry failed webhook deliveries"
rc=$(run "$disp" poll 1)
ok "a second base merge changes nothing either"        "$(store_round acme/portal 412)" "1 1 sha777"
ok "  and still wakes nobody"                          "$(count review_head_moved)" 0

printf '\n  shape B: four pushes before a post are one round, not four\n'
# The shape that reached round 4 unposted before its pull request merged. Four real pushes --
# the diff changes every time, so nothing here is the base-merge case -- and the answer is one
# review on round 1 with four moves, where it used to be four rows.
instance '{"mode":"auto"}'
put gh-portal-568 mode=review status=active repo=acme/portal number=568 \
  session_id=sess-b session_name="Review #568" --by dispatcher
session sess-b
files_doc 568 "$DIFF_ONE"
search_doc acme/portal 568 head1 "A scheduled export keeps its context"
rc=$(run "$disp" poll 1)
python3 - "$work/rd.opens.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = json.loads(p.read_text())
s["acme/portal#568"].update({"session": "sess-b", "started": True})
p.write_text(json.dumps(s))
PY
moves=0
for h in head2 head3 head4; do
  files_doc 568 "$(printf '[{"filename":"src/export.py","status":"modified","patch":"%s"}]' "$h")"
  search_doc acme/portal 568 "$h" "A scheduled export keeps its context"
  rc=$(run "$disp" poll 1)
  moves=$((moves + $(count '"event": "review_head_moved"')))
done
ok "four pushes leave ONE review"                      "$(store_round acme/portal 568)" "1 1 head4"
ok "  on round 1, not round 4"                         "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#568"]["round"])' "$work/rd.opens.json")" 1
ok "  with one wake per push"                          "$moves" 3
ok "  and no round offered for any of them"            "$(count '"event": "review_request"')" 0

printf '\n  after a post, the next push IS the next round\n'
# The one case DEV-962 leaves exactly as it was. A round is a posted review, so commits after a
# post are a new round and reach the Dispatcher as work.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
preopen acme/portal 412 sha412 1 "" 1 posted
search_doc acme/portal 412 sha777 "Retry failed webhook deliveries"
rc=$(run "$disp" poll 1)
ok "a push after a post opens round 2"                 "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 2
ok "  and is offered for dispatch, not woken"          "$(count '"event": "review_request"')" 1
ok "  with nothing woken"                              "$(count review_head_moved)" 0
# And a base-only push after a post is still nothing, which is what the ticket's table says in
# both of its columns.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
preopen acme/portal 412 sha412 1 "" 1 posted
search_doc acme/portal 412 sha412 "Retry failed webhook deliveries"
rc=$(run "$disp" poll 1)
search_doc acme/portal 412 sha888 "Retry failed webhook deliveries"
rc=$(run "$disp" poll 1)
ok "a base-only push after a post opens no round"      "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 1

printf '\n  a round nobody has begun is still work, however its head moves\n'
# **The regression this branch caused itself and this is the control for it.** An unclaimed
# request moves its head too -- that is what every request has done since DEV-945 -- and
# suppressing its `review_request` would take a review nobody has started off the Dispatcher's
# list the moment its author pushed. Only a round somebody is ON has a session to wake.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
files_doc 412 "$DIFF_TWO"
search_doc acme/portal 412 sha777 Retry
age_marker 'gh-portal-412|review_request'
rc=$(run "$disp" poll 1)
ok "an unstarted round's head moves"                   "$(store_round acme/portal 412)" "1 1 sha777"
ok "  and the request is STILL offered"                "$(count '"event": "review_request"')" 1
ok "  and nobody is woken for it"                      "$(count review_head_moved)" 0
# The same for a base-only push on an unclaimed request: nothing changed in the record, and the
# request is still unclaimed work.
search_doc acme/portal 412 sha888 Retry
age_marker 'gh-portal-412|review_request'
rc=$(run "$disp" poll 1)
ok "a base-only push on an unclaimed request"          "$(store_round acme/portal 412)" "1 1 sha777"
ok "  still offers the request"                        "$(count '"event": "review_request"')" 1

printf '\n  whose session is gone, and whose liveness is unknown\n'
# The fallback: ONE replacement, on the same review and the same round. Never two workers on one
# review, which is item 5's own wording.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
preopen acme/portal 412 sha412 7 dead-9
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 \
  session_id=dead-9 review_desk_id=7 --by worker
search_doc acme/portal 412 sha777 Retry
rc=$(run "$disp" poll 1)
ok "a moved head whose session is gone is still a move" "$(count '"event": "review_head_moved"')" 1
ok "  and says the session is not there"                "$(says '"session_live": false')" yes
ok "  naming the review to link the replacement to"     "$(says '"review_desk_id": 7')" yes
ok "  and offering no round for it"                     "$(count '"event": "review_request"')" 0
# allele's state file unreadable: `null`, not a guess. `false` would offer a replacement for a
# session that is sitting there -- two workers on one review -- and `true` would leave a moved
# head with nobody reading it.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
preopen acme/portal 412 sha412 7 sess-c
put gh-portal-412 mode=review status=active repo=acme/portal number=412 \
  session_id=sess-c review_desk_id=7 --by dispatcher
printf 'not json at all' > "$work/allele.json"
search_doc acme/portal 412 sha777 Retry
rc=$(run "$disp" poll 1)
ok "an unreadable allele state says unknown"           "$(says '"session_live": null')" yes
ok "  and still exits clean"                           "$rc" 0
echo '{"sessions":[],"archived_sessions":[]}' > "$work/allele.json"

printf '\n  DEV-954: `started` is the store'"'"'s judgement, not a guess from session_id\n'
# **A round holding a brief and no link is STARTED, and `session_id` cannot see it.** That is
# DEV-954's whole gap, and under DEV-962 it decides a different question from the one it was
# filed about: a moved head on a started round is a WAKE, and on an unstarted one it is work
# nobody has picked up. Read through `session_id` alone, a session that had written its brief
# and not yet linked itself would have its push offered to somebody else -- a second worker on
# a review that already has one, which is the one thing item 5 forbids.
#
# `started` and `action` are the same Review Desk commit (849abe4, confirmed by its author), so
# there is no build where this field protects an older round rule. What it protects is the
# routing, and that is what these three assert.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
preopen acme/portal 412 sha412 7 "" 1 started
search_doc acme/portal 412 sha777 Retry
rc=$(run "$disp" poll 1)
ok "a started round with no session is still a wake"   "$(count '"event": "review_head_moved"')" 1
ok "  and is offered to nobody"                        "$(count '"event": "review_request"')" 0
ok "  while its head moves, no round being spent"      "$(store_round acme/portal 412)" "1 1 sha777"
# And the control: take `started` off the answer and the same shape is OFFERED, because
# `session_id` is all that is left to read and it says nobody is on it. That is the behaviour
# that preceded DEV-954, kept as the fallback for a build that has `action` and not `started` --
# a combination nobody expects and which this poller still has to survive.
instance '{"mode":"auto"}'
touch "$work/rd.nostarted"
files_doc 412 "$DIFF_ONE"
preopen acme/portal 412 sha412 7 "" 1 started
search_doc acme/portal 412 sha777 Retry
rc=$(run "$disp" poll 1)
ok "without the field it falls back to session_id"     "$(count '"event": "review_request"')" 1
ok "  so the brief-and-no-link window is offered"      "$(count review_head_moved)" 0
ok "  and the head still moves, spending no round"     "$(store_round acme/portal 412)" "1 1 sha777"
rm -f "$work/rd.nostarted"

printf '\n  a Review Desk older than the contract, which falls back and says so\n'
# The probe is `review open --help`, a READ: it opens nothing and spends no round. A build
# without `--diff-unchanged` has no `action`, no move on a started round and no out-of-play, so
# it gets exactly the behaviour this file had before DEV-962 and one loud line.
instance '{"mode":"auto"}'
contract pre962
files_doc 412 "$DIFF_ONE"
preopen acme/portal 412 sha412 7 sess-d
put gh-portal-412 mode=review status=active repo=acme/portal number=412 \
  session_id=sess-d review_desk_id=7 --by dispatcher
search_doc acme/portal 412 sha777 Retry
rc=$(run "$disp" poll 1)
ok "an older build is not written to at all"           "$(opens)" 0
ok "  so no round is spent"                            "$(store_round acme/portal 412)" "1 1 sha412"
ok "  and it is said, once, as broken"                 "$(count '"event": "review_desk_unavailable"')" 1
ok "  naming the flag that is missing"                  "$(says 'has no .--diff-unchanged.')" yes
ok "  and that it predates DEV-962"                    "$(says 'predates DEV-962')" yes
ok "  and that nothing is blocked"                     "$(says 'Nothing is blocked')" yes
ok "  and the poller exits clean"                      "$rc" 0
rc=$(run "$disp" poll 2)
ok "  and is not said again inside the window"         "$(count review_desk_unavailable)" 0
# **Never the flag on a build that would refuse it.** clap rejects an unknown argument and takes
# the whole call with it, so a `--diff-unchanged` sent to an older build would record nothing at
# all -- and the `--ledger` retry beside it would drop the wrong flag and refuse again.
instance '{"mode":"auto"}'
contract pre962
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
search_doc acme/portal 412 sha888 Retry
rc=$(run "$disp" poll 1)
ok "an older build is never sent the flag"             "$(grep -c -- '--diff-unchanged' "$work/rd.calls")" 0
ok "  and its recording still lands"                   "$(opens)" 2
contract

printf '\n  the diff fingerprint refuses to guess\n'
# Every uncertainty omits the flag, and an omitted flag MOVES the head: it wakes a session that
# need not have woken, where a wrongly-asserted one hides a real change of Patrick's from him.
# Four uncertainties, one assertion each.
oneshot () {
  # oneshot <files-json>: record at sha412, then push to sha888 with that file list unchanged,
  # so the ONLY reason the flag could be withheld is the list itself.
  instance '{"mode":"auto"}'
  printf '%s\n' "$1" > "$work/files.412.json"
  search_doc acme/portal 412 sha412 Retry
  rc=$(run "$disp" poll 1)
  search_doc acme/portal 412 sha888 Retry
  rc=$(run "$disp" poll 1)
  last_open | grep -c -- --diff-unchanged || true
}
ok "an identical patch list claims unchanged"          "$(oneshot "$DIFF_ONE")" 1
ok "a file with no patch and no blob sha does not"      "$(oneshot '[{"filename":"a.bin","status":"modified"}]')" 0
ok "a binary file with a blob sha does"                 "$(oneshot '[{"filename":"a.bin","status":"modified","sha":"abc123"}]')" 1
ok "a page that is not a list does not"                 "$(oneshot '{"files": []}')" 0
# A `gh` that fails: no flag, and nothing raised. The fingerprint is an optimisation whose
# failure costs a wake, so the recording on the page must carry on.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
rm -f "$work/files.412.json"
printf '[{"filename":"x","status":"modified","patch":"p"}]' > "$work/files.412.json"
search_doc acme/portal 412 sha888 Retry
rc=$(run "$disp" poll 1)
ok "a diff that changed claims nothing"                "$(last_open | grep -c -- --diff-unchanged || true)" 0
ok "  and the push is still recorded"                  "$(store_round acme/portal 412)" "1 1 sha888"
# And a key with NO stored fingerprint -- the first recording, or a poll state that was lost --
# claims nothing either. The flag is moot on a first open by the contract's own wording.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "a first recording claims nothing"                  "$(last_open | grep -c -- --diff-unchanged || true)" 0
ok "  and the fingerprint is kept for the next push"   "$(python3 -c '
import json,sys
state = json.load(open(sys.argv[1]))
print(bool((state["recorded"]["gh-portal-412"].get("diff") or {}).get("digest")))' "$inst/runtime/poll-state.json")" True

printf '\n  item 7: draft and withdrawn leave play, and come back\n'
# Both reversible, which is what makes this different from DEV-957's finished state: the rounds,
# the drafts and any sign-off are KEPT, and the review returns on the round it was on.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
# The author converts it to a draft. With `skip_drafts` on -- the shipped default -- the row
# simply stops arriving, so the clearance is what sees it, and `isDraft` on the live read is
# what tells a conversion from a withdrawal.
cleared_doc 412 OPEN draft
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
ok "a draft pull request leaves play as a draft"       "$(oops)" 1
ok "  with the reason the live read gave"              "$(last_oop | grep -c 'reason draft')" 1
ok "  and the store holds it"                          "$(oop_state acme/portal 412 | cut -d@ -f1)" draft
ok "  and it is said once, nobody having held it"      "$(count '"event": "review_out_of_play"')" 1
ok "  naming which of the two it was"                  "$(says '"out_of_play": "draft"')" yes
ok "  and the sentence the live read gave"             "$(says 'PR converted to draft')" yes
ok "  and no round was spent on it"                    "$(store_round acme/portal 412 | cut -d' ' -f2)" 1
# Said once, not once a tick. Two things keep it so and both are asserted: the `once` mark on
# the event, and -- once the key has left `prs_present` -- the clearance sweep not reaching it
# again at all.
forget_calls
rc=$(run "$disp" poll 2)
ok "  and not again while it stays out of play"        "$(count review_out_of_play)" 0
ok "  and not written again either"                    "$(oops)" 0
# Ready again: `review in-play`, and the request comes back round on the round it was on.
cleared_doc 412 OPEN ready
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "a pull request marked ready comes back in play"    "$(inplays)" 1
ok "  and the store says it is in play"                "$(oop_state acme/portal 412)" "None@None"
ok "  which is said once"                              "$(count '"event": "review_in_play"')" 1
ok "  and the round it returns on is the one it left"  "$(store_round acme/portal 412 | cut -d' ' -f2)" 1

printf '\n  a withdrawn request, which is the other reason\n'
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
cleared_doc 412 OPEN ready
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
ok "a withdrawn request leaves play as withdrawn"      "$(oop_state acme/portal 412 | cut -d@ -f1)" withdrawn
ok "  and is said with that reason"                    "$(says '"out_of_play": "withdrawn"')" yes
ok "  and the sentence the live read gave"             "$(says 'review request removed')" yes

printf '\n  and the reasons that are NOT out of play\n'
# Merged and closed are DEV-957's finished state and never come back the way these two do, so
# the record must not say "out of play" about them. A review of the principal's being submitted
# is the request answered, not withdrawn. And a `gh pr view` that failed is not a withdrawal:
# nothing may be written on the strength of a call that did not answer.
for pair in "MERGED ready" "CLOSED ready"; do
  set -- $pair
  instance '{"mode":"auto"}'
  files_doc 412 "$DIFF_ONE"
  search_doc acme/portal 412 sha412 Retry
  rc=$(run "$disp" poll 1)
  cleared_doc 412 "$1" "$2"
  printf '{"state":"%s"}' "$1" > "$work/pr.412.json"
  search_doc acme/portal 999 shaother Retry
  rc=$(run "$disp" poll 1)
  ok "a $1 pull request is not taken out of play"      "$(oops)" 0
  rm -f "$work/pr.412.json"
done
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
cleared_doc 412 OPEN ready devdeveloper
# A session on the ledger, or there is nobody for the clearance to be reported TO:
# `review_cleared` names a session and is emitted only for a key one is working.
put gh-portal-412 mode=review status=active repo=acme/portal number=412 session_id=sess-g --by test
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
ok "a review you submitted is not a withdrawal"        "$(oops)" 0
ok "  and it is still reported as cleared"             "$(says 'you submitted a review')" yes

printf '\n  the reason is written once, and a change of reason cannot be seen\n'
# **A stated limit rather than a hole, and the reason it is a limit is that there is no signal.**
# A pull request that goes draft and then has its review request withdrawn leaves GitHub showing
# neither: the row is filtered as a draft and the request is gone, so no tick can tell the two
# apart -- the clearance sweep only reaches a key that LEFT the list this tick, and it left once.
# The first reason recorded therefore stands, and `draft` is the more informative of the two.
#
# `review out-of-play` is idempotent and accepts a reason change, measured by review-desk's own
# author on 13 October 2026 -- so if a signal ever appears, nothing here has to be unpicked.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
cleared_doc 412 OPEN draft
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
was_at=$(oop_state acme/portal 412 | cut -d@ -f2)
ok "the reason is written once"                        "$(oops)" 1
# Two more ticks with the pull request still a draft and still off the list: nothing is asked,
# because the key is in neither `present` nor `previous` -- so "out of play since" cannot drift.
forget_calls
cleared_doc 412 OPEN ready
rc=$(run "$disp" poll 2)
ok "  and never again while it stays off the list"     "$(oops)" 0
ok "  so the time it left play cannot drift"           "$(oop_state acme/portal 412 | cut -d@ -f2)" "$was_at"
ok "  and the reason it holds is the first one seen"   "$(oop_state acme/portal 412 | cut -d@ -f1)" draft

printf '\n  out of play is never written on a tick nobody believes\n'
# **The one thing that could take a LIVE review out of play is GitHub'"'"'s list looking empty
# when it is not**, and the guard is where this sweep sits: inside the trusted block, past the
# return a disbelieved or truncated tick takes. `source_empty` is what that tick says instead.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
cleared_doc 412 OPEN draft
echo '{"data":{"search":{"issueCount":4,"nodes":[]}}}' > "$work/gh.search"
rc=$(run "$disp" poll 1)
ok "a disbelieved page writes no out-of-play"          "$(oops)" 0
ok "  and says why it believed nothing"                "$(count '"event": "source_empty"')" 1
# A truncated page is FULL, so the loop runs and the recordings are attempted -- and the tick
# still returns before the sweep. The out-of-play write must be on the far side of that return.
instance '{"mode":"auto"}'
search_page acme/portal 50 60
rc=$(run "$disp" poll 1)
cleared_doc 1 OPEN draft
rc=$(run "$disp" poll 1)
ok "a truncated page writes no out-of-play either"     "$(oops)" 0

printf '\n  the three things a review of this branch found\n'
# **An out-of-play recording survives the prune**, like a dismissal and a closed one. A key taken
# out of play has by definition just left `present`, so without this the field is discarded on
# the same tick it is written -- and bringing the review back then depends on `find_request`
# re-reading it when the pull request returns. That read is skipped whenever `look_stopped` or
# `record_stopped` is set, so one transient broken `review find` on the return tick left the
# review out of play in Review Desk while the poller went on offering the key.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
cleared_doc 412 OPEN draft
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
ok "an out-of-play recording survives the prune"       "$(remembered gh-portal-412 out_of_play)" draft
# And that is what makes the return work even on a tick whose look cannot be made.
cleared_doc 412 OPEN ready
search_doc acme/portal 412 sha412 Retry
echo broken > "$work/rd.find.mode"
forget_calls
rc=$(run "$disp" poll 1)
ok "  so a broken look still brings it back in play"   "$(inplays)" 1
ok "  and the record says it is in play again"         "$(remembered gh-portal-412 out_of_play)" None
rm -f "$work/rd.find.mode"

# **The wake marks are pruned with the record they are about.** `emitted` is persisted and
# nothing pruned it but the Linear trigger marks, so `review_desk|head_moved|<key>|<from>|<to>`
# -- keyed on both commits, which is what makes a second push speak and the same push not --
# was one permanent entry per push per reviewed pull request for the life of the instance.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
preopen acme/portal 412 sha412 7 sess-h
search_doc acme/portal 412 sha777 Retry
rc=$(run "$disp" poll 1)
ok "a wake leaves a mark behind it"                    "$(marks 'review_desk|head_moved|')" 1
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
ok "  which is pruned once the request is gone"        "$(marks 'review_desk|head_moved|')" 0

# **`why_cleared`'s live read is made only when something will read its answer.** It was computed
# for every key that left the list, and on an instance with Review Desk off a cleared key with no
# live session discards it at once -- one `gh pr view` per key for a value nobody looks at, on a
# tick where a page's worth of requests clears together.
instance '{"mode":"off"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
search_doc acme/portal 999 shaother Retry
: > "$work/gh.calls"
rc=$(run "$disp" poll 1)
ok "a clearance nobody reads costs no live read"       "$(grep -c '^pr view ' "$work/gh.calls" || true)" 0
# Both readers still get it: a live session, through `review_cleared`...
instance '{"mode":"off"}'
search_doc acme/portal 412 sha412 Retry
put gh-portal-412 mode=review status=active repo=acme/portal number=412 session_id=sess-i --by test
rc=$(run "$disp" poll 1)
search_doc acme/portal 999 shaother Retry
: > "$work/gh.calls"
rc=$(run "$disp" poll 1)
ok "  but a live session's clearance still reads it"   "$(grep -c '^pr view ' "$work/gh.calls" || true)" 1
ok "  and is told the reason"                          "$(count '"event": "review_cleared"')" 1
# ...and the out-of-play write, through `recording`.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
cleared_doc 412 OPEN draft
search_doc acme/portal 999 shaother Retry
: > "$work/gh.calls"
rc=$(run "$disp" poll 1)
ok "  and a recording instance reads it with no session" "$(grep -c '^pr view ' "$work/gh.calls" || true)" 1
ok "  and takes the pull request out of play"          "$(oops)" 1

# **A store that accepts `review in-play` and does not clear it.** The poller believes the
# ANSWER, not the request -- `out_of_play`'s own rule in the other direction, because believing
# the request would send the next tick looking for a change that had not happened. That leaves
# one problem and these four assertions are it: the gate re-reads the field, so without a bound
# this is one subprocess per tick for as long as the key is present, which is the
# `last_activity_at` churn this whole path is arranged to avoid.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
cleared_doc 412 OPEN draft
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
echo sticky > "$work/rd.oop.mode"
cleared_doc 412 OPEN ready
search_doc acme/portal 412 sha412 Retry
forget_calls
# The request's own re-emission clock, or "the request is still dispatched" below passes or fails
# on the fifteen-minute window rather than on anything this test is about.
age_marker 'gh-portal-412|review_request'
rc=$(run "$disp" poll 1)
ok "a store that will not clear it is asked once"      "$(inplays)" 1
ok "  and the record keeps what the ANSWER said"       "$(remembered gh-portal-412 out_of_play)" draft
ok "  and it is said, loudly, as a broken install"     "$(count '"event": "review_desk_unavailable"')" 1
ok "  naming the call and what it costs"               "$(says 'review in-play exited 0 and the review is still out of play')" yes
ok "  and saying nothing is blocked"                   "$(says 'Nothing is blocked')" yes
ok "  while the request is still dispatched"           "$(count '"event": "review_request"')" 1
# **Not once per tick**, which is the whole of the bound: three more ticks, no more calls and no
# more notices, and the request goes on being offered.
forget_calls
rc=$(run "$disp" poll 3)
ok "  and not asked again inside the window"           "$(inplays)" 0
ok "  nor said again"                                  "$(count review_desk_unavailable)" 0
# Once the window is out it tries again -- and says nothing, because the reason has not changed.
age_marker 'review_desk|in_play|gh-portal-412'
forget_calls
rc=$(run "$disp" poll 1)
ok "  and is retried when the window is out"           "$(inplays)" 1
ok "  without saying it twice"                         "$(count review_desk_unavailable)" 0
# And when the store is fixed, it comes back and says so.
rm -f "$work/rd.oop.mode"
age_marker 'review_desk|in_play|gh-portal-412'
forget_calls
rc=$(run "$disp" poll 1)
ok "a store that is fixed brings it back"              "$(oop_state acme/portal 412)" "None@None"
ok "  and the return is said"                          "$(count '"event": "review_in_play"')" 1

printf '\n  a Review Desk with no out-of-play at all\n'
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
echo oldoop > "$work/rd.oop.mode"
cleared_doc 412 OPEN draft
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
ok "a build with no \`out-of-play\` says so once"       "$(count '"event": "review_desk_unavailable"')" 1
ok "  naming the subcommand"                            "$(says '"call": "review out-of-play"')" yes
ok "  and what is lost by it"                           "$(says 'stays on the Reviews list')" yes
ok "  and nothing is blocked"                           "$rc" 0
ok "  and it is not remembered as out of play"          "$(remembered gh-portal-412 out_of_play)" ""
rm -f "$work/rd.oop.mode"
# A pull request Review Desk holds no review of: `not_found`, which is not a failure. There is
# nothing to take out of play and a line about a review that does not exist is noise.
#
# **Driven by deleting the STORE and not by a fresh instance**, which is the shape of a developer
# deleting a review that never started. A fresh `instance` wipes the poll state too, so
# `prs_present` is None and the clearance sweep does not run at all -- a test written that way
# would assert nothing and pass.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
put gh-portal-412 mode=review status=active repo=acme/portal number=412 session_id=s1 --by test
rc=$(run "$disp" poll 1)
echo '{}' > "$work/rd.opens.json"
cleared_doc 412 OPEN draft
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
ok "a pull request with no review says nothing"        "$(count review_desk_unavailable)" 0
ok "  and still reports the clearance to its session"  "$(count '"event": "review_cleared"')" 1
ok "  carrying no out-of-play, there being none"       "$(says '"out_of_play": null')" yes

printf '\n  what a session that HELD it is told\n'
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
put gh-portal-412 mode=review status=active repo=acme/portal number=412 \
  session_id=sess-e session_name="Review #412" --by dispatcher
cleared_doc 412 OPEN draft
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
ok "a cleared review carries what the record did"      "$(says '"out_of_play": "draft"')" yes
ok "  as a review_cleared, which names the session"    "$(count '"event": "review_cleared"')" 1
ok "  and not as a review_out_of_play as well"         "$(count review_out_of_play)" 0
# And the other direction: a clearance that moved no record carries null, which is every reason
# but those two.
instance '{"mode":"auto"}'
files_doc 412 "$DIFF_ONE"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
put gh-portal-412 mode=review status=active repo=acme/portal number=412 session_id=sess-f --by test
cleared_doc 412 MERGED ready
printf '{"state":"MERGED"}' > "$work/pr.412.json"
search_doc acme/portal 999 shaother Retry
rc=$(run "$disp" poll 1)
ok "a merge carries no out-of-play"                    "$(says '"out_of_play": null')" yes
rm -f "$work/pr.412.json"

printf '\n  the brief a replacement reads\n'
# The Dispatcher writes `head_moved_from` on the claim when it replaces a session that is gone
# on a review whose head moved. `D brief` is what turns that into a line, and without the line
# the replacement reads the resume line, opens on the new head, and has already decided it is
# starting a round by the time Review Desk tells it otherwise.
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 \
  title=Retry url=u review_desk_id=7 round=1 head_sha=sha777 head_moved_from=sha412 --by dispatcher
set +e; D brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "the brief says the head moved and the round did not" "$(says 'The head moved and the round did not')" yes
ok "  naming the commit it moved from"                 "$(says 'already open on .sha412')" yes
ok "  and the one it is on now"                        "$(says 'to .sha777')" yes
ok "  and the round it is still on"                    "$(says 'still round 1')" yes
ok "  and that it is not to open one"                  "$(says 'do not open a round')" yes
ok "  and it still says it is resuming the review"     "$(says 'You are resuming Review Desk review 7')" yes
# No `head_moved_from`: no line. A replacement for a session that simply died is resuming a
# round, not updating one for a push.
instance '{"mode":"auto"}'
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 \
  title=Retry url=u review_desk_id=7 --by dispatcher
set +e; D brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "without it the brief says nothing about a move"    "$(says 'The head moved')" no
ok "  and still resumes"                               "$(says 'You are resuming Review Desk review 7')" yes

printf '\n  what the Dispatcher and the worker are told about DEV-962\n'
ok "SKILL.md routes a moved head"                      "$(grep -c 'review_head_moved' "$skill_md")" 2
ok "  telling it to dispatch nobody"                   "$(grep -c 'Dispatch nobody' "$skill_md")" 1
ok "  and never two workers on one review"             "$(grep -c 'Never two workers on one review' "$skill_md")" 1
ok "  and what to do when the session is gone"         "$(grep -c 'head_moved_from=<previous>' "$skill_md")" 1
ok "  and when its liveness is unknown"                "$(grep -c 'session_live: null' "$skill_md")" 1
ok "  it routes out of play, and back"                 "$(grep -c 'review_out_of_play' "$skill_md")" 2
ok "  and review_in_play"                              "$(grep -c 'review_in_play' "$skill_md")" 2
ok "  it says a push before a post moves the round"    "$(grep -c 'A push before a post moves the round' "$skill_md")" 1
ok "  and that an older build falls back, loudly"      "$(grep -c 'older than DEV-962 it falls back' "$skill_md")" 1
ok "  and review_cleared carries whether it moved"     "$(grep -c 'out_of_play. says whether the record moved' "$skill_md")" 1
ok "review.md passes --session on the first open"      "$(grep -c 'review open --repo OWNER/REPO --pr <n> --head <sha> --session' "$worker_md")" 1
ok "  saying that is the whole point of it"            "$(grep -c 'FIRST .review open. and that is the whole point' "$worker_md")" 1
ok "  and what an older build does with it"            "$(grep -c 'drop only .--session.' "$worker_md")" 1
ok "  it reads action, not created"                    "$(grep -c 'created: false. no longer tells you which' "$worker_md")" 1
ok "  and carries a row for each of the four"          "$(grep -cE '^   \| .(created|head_moved|unchanged|diff_unchanged). \|' "$worker_md")" 4
ok "  telling it to update in place on a move"         "$(grep -c 'update in place' "$worker_md")" 1
ok "  and not to start a round"                        "$(grep -c 'Do not start a round' "$worker_md")" 1
ok "  it has a section for draft and withdrawn"        "$(grep -c '^## When it goes to draft, or the request is withdrawn' "$worker_md")" 1
ok "  saying both are reversible"                      "$(grep -c 'Both are reversible' "$worker_md")" 1
ok "  and that done, never merged, is the status"      "$(grep -c 'never .merged.' "$worker_md")" 1
ok "  and that the poller writes the out-of-play"      "$(grep -c 'The poller writes the out-of-play itself' "$worker_md")" 1
ok "  and that a replacement continues the round"      "$(grep -c 'it reads the record, finds your round' "$worker_md")" 1
# THREE: the two rows under `## After that`, and the row in the draft section's own table
# that says which of the two events tells a worker it was converted. Pinned at three rather
# than loosened to "at least one", because a count that cannot go down cannot notice a deletion.
ok "  and it routes pr_draft both ways"                "$(grep -c 'pr_draft. with' "$worker_md")" 3

printf '\n  only the developer signs off, still\n'
# The new commands are both WRITES about whether a pull request is in play, which is a fact
# about GitHub rather than a decision of the developer's -- so the list of Review Desk commands
# this file may run grows by exactly two and by nothing else. Dismissing, restoring, deleting
# and approving are still nowhere in it.
ok "the only \`review\` writes are open, out-of-play and in-play" \
   "$(grep -oE '"review", "(open|find|show|out-of-play|in-play)"' "$disp" | sort -u | tr '\n' ' ')" \
   '"review", "find" "review", "in-play" "review", "open" "review", "out-of-play" "review", "show" '
ok "  and nothing dismisses, deletes, restores or approves" \
   "$(grep -cE '"(dismiss|delete|restore|approve)"' "$disp")" 0

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

sed 's/^        if kind != "nits_to_ticket" or entry\.get("status") not in WORKER_ARMED:$/        if True:  # DEAF SESSION REVERSED/' \
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
sed 's/^        if kind != "nits_to_ticket" or entry\.get("status") not in WORKER_ARMED:$/        if entry.get("status") not in WORKER_ARMED:  # KIND HALF REMOVED/' \
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

sed 's/^        if requested_key(key) in self\.requested and entry\.get("status") in REDISPATCHABLE:$/        if False:  # TICK TEST REVERSED/' \
    "$disp" > "$work/notick.py"
ok "the this-tick reversal changed one line"           "$(grep -c 'TICK TEST REVERSED' "$work/notick.py")" 1
# With a ledger entry, so the no-such-entry guard cannot pass this one for it.
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
work_doc review_requested 11 acme/portal 412 1791520282 gh-portal-412
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 --by test
rc=$(run "$work/notick.py" poll 1)
ok "  without it Review Desk offers it again"          "$(count '"event": "review_desk_requested"')" 1

sed 's/^        if entry\.get("status") in DECIDED:$/        if False:  # SKIP TEST REVERSED/' \
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

sed 's/^                   and not same_commit(held\.get("head"), head))$/                   and True)  # MARK REVERSED/' \
    "$disp" > "$work/nomark.py"
ok "the mark reversal changed one line"                "$(grep -c 'MARK REVERSED' "$work/nomark.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nomark.py" poll 3)
ok "no mark: three ticks record the same request thrice" "$(opens)" 3

# **The gate this used to reverse is gone, and DEV-962 removed it deliberately.** It was
# `if recording and status not in ALIVE:` -- the poller stayed out of a live session's review
# entirely -- and a push to a live, unposted review is now exactly what the poller has to tell
# Review Desk about. What remains of the rule is narrower and still load-bearing: the DISMISSAL
# READ stays out of a live session's review, because a dismissal is a reason not to dispatch and
# a key a live session holds is not a candidate for dispatch whatever the developer did. That is
# the `not alive` in the read branch, and this is its control.
sed 's/^        elif rid is not None and not alive and not self\.read_stopped and self\.due(asked, every):$/        elif rid is not None and not self.read_stopped and self.due(asked, every):  # ALIVE READ REVERSED/' \
    "$disp" > "$work/noalive.py"
ok "the live-session read reversal changed one line"   "$(grep -c 'ALIVE READ REVERSED' "$work/noalive.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
put gh-portal-412 mode=review status=active repo=acme/portal number=412 session_id=live-9 review_desk_id=7 --by test
session live-9
rc=$(run "$disp" poll 1)
ok "a live session's review is not read for a dismissal" "$(shows)" 0
rc=$(run "$work/noalive.py" poll 1)
ok "  without the gate it is read behind the session"  "$(shows)" 1
no_sessions

sed 's/^            self\.record_stopped = True$/            pass  # STOP REVERSED/' \
    "$disp" > "$work/nostop.py"
ok "the stop-once reversal changed every line of it"  "$(grep -c 'STOP REVERSED' "$work/nostop.py")" 5
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

sed 's/^                if status not in ALIVE and self\.dismissed_request(rd, key, repo, pr):$/                if False:  # DISMISSAL IGNORED/' \
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

sed 's/^        elif rid is not None and not alive and not self\.read_stopped and self\.due(asked, every):$/        elif False:  # DISMISSAL NEVER READ/' \
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
elif ! "${REVIEW_DESK_BIN}" review open --help 2>/dev/null | grep -q -- '--ledger'; then
  # **The section asserts DEV-945's own half, so it needs a Review Desk that has it.** `--ledger`
  # is the probe because it landed with the rest of it -- the move, the dismissal field -- in
  # review-desk 0e0bf1b, so a build without the flag fails four of these assertions by being
  # older rather than by anything being wrong. Said once, rather than four confusing failures:
  # a developer pointing this at the binary on their PATH is the likeliest way to meet it, and
  # that binary is usually whatever was last built next door.
  printf '  skipped -- %s predates DEV-945 (no `--ledger` on `review open`)\n' "$REVIEW_DESK_BIN"
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
  # Guarded, because a review-desk without migration 16 has no such column and `set -eu` would
  # take the remaining assertions and the summary line down with the statement -- a developer
  # who set REVIEW_DESK_BIN would get a truncated report rather than the failures this section
  # promises. Skipped loudly instead.
  has_dismissal=$(sqlite3 "$REVIEW_DESK_DB" "PRAGMA table_info(reviews);" | grep -c dismissed_at || true)
  if [ "$has_dismissal" -eq 0 ]; then
    printf '  skipped -- this review-desk has no dismissal column (migration 16)\n'
  else
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
  fi

  # ---- DEV-962, against the real binary ----------------------------------------------------
  # **The contract probe, read off a real `review open --help`.** Everything in the DEV-962
  # section above is driven through the stand-in, so this is the one place that can say the
  # stand-in's two builds are both real shapes rather than two of my assumptions.
  if "$REVIEW_DESK_BIN" review open --help 2>/dev/null | grep -q -- '--diff-unchanged'; then
    instance "$real"
    export REVIEW_DESK_DB="$work/real962.db"
    rm -f "$REVIEW_DESK_DB"
    files_doc 412 "$DIFF_ONE"
    search_doc acme/portal 412 sha412 "Retry failed webhook deliveries"
    rc=$(run "$disp" poll 1)
    rid=$(remembered gh-portal-412 review)
    "$REVIEW_DESK_BIN" review link --review "$rid" --session sess-real962 --json > /dev/null
    files_doc 412 "$DIFF_TWO"
    search_doc acme/portal 412 sha777 "Retry failed webhook deliveries"
    rc=$(run "$disp" poll 1)
    real_find () { "$REVIEW_DESK_BIN" review find --repo acme/portal --pr 412 --json; }
    ok "a real Review Desk moves an unposted round"      "$(real_find | python3 -c 'import json,sys;r=json.load(sys.stdin)["reviews"];print("%d %s %s" % (len(r), r[0]["round"], r[0]["head_sha"]))')" "1 1 sha777"
    ok "  and the poller wakes the session on it"        "$(count '"event": "review_head_moved"')" 1
    ok "  offering a round to nobody"                    "$(count '"event": "review_request"')" 0
    # The base branch arriving, against the real store: the file list is unchanged, so the
    # poller asserts it and the real binary leaves the head where it was.
    search_doc acme/portal 412 sha888 "Retry failed webhook deliveries"
    rc=$(run "$disp" poll 1)
    ok "a real base-only push leaves the head alone"     "$(real_find | python3 -c 'import json,sys;print(json.load(sys.stdin)["reviews"][0]["head_sha"])')" sha777
    ok "  and wakes nobody"                              "$(count review_head_moved)" 0
    # Out of play, against the real store, and back again.
    cleared_doc 412 OPEN draft
    search_doc acme/portal 999 shaother "Something else"
    rc=$(run "$disp" poll 1)
    ok "a real review goes out of play as a draft"       "$(real_find | python3 -c 'import json,sys;print(json.load(sys.stdin)["reviews"][0]["out_of_play"])')" draft
    ok "  and leaves the real work list"                 "$("$REVIEW_DESK_BIN" work list --repo acme/portal --json | python3 -c 'import json,sys;print(len([w for w in json.load(sys.stdin)["work"] if w["pr"] == 412]))')" 0
    cleared_doc 412 OPEN ready
    search_doc acme/portal 412 sha888 "Retry failed webhook deliveries"
    rc=$(run "$disp" poll 1)
    ok "a real review comes back in play"                "$(real_find | python3 -c 'import json,sys;print(json.load(sys.stdin)["reviews"][0]["out_of_play"])')" None
    ok "  on the round it was on"                        "$(real_find | python3 -c 'import json,sys;print(json.load(sys.stdin)["reviews"][0]["round"])')" 1
    export REVIEW_DESK_DB="$work/real.db"
  else
    # **Loud, and it asserts the FALLBACK rather than skipping in silence.** A build without the
    # flag is the legacy path, and the whole house rule about it is that it degrades to today's
    # behaviour and says so once -- so a real one is the best possible witness for exactly that.
    printf '  skipped -- %s predates DEV-962 (no `--diff-unchanged` on `review open`);\n' \
      "$REVIEW_DESK_BIN"
    printf '             asserting the FALLBACK against it instead\n'
    # The LEDGER carries the session, which is what the Dispatcher writes at claim time -- and
    # on a build with no `started` it is the only witness the poller has. With it, the legacy
    # guard holds and nothing is written.
    instance "$real"
    export REVIEW_DESK_DB="$work/real962.db"
    rm -f "$REVIEW_DESK_DB"
    search_doc acme/portal 412 sha412 "Retry failed webhook deliveries"
    rc=$(run "$disp" poll 1)
    # **Said on the FIRST tick that probes**, which is the tick that first has something to
    # write -- not on the tick the guard then stops. Asserted here rather than after the push,
    # because the rate limit is doing its job by then and `count` reads one run's output.
    ok "the real older build is reported, as broken"     "$(count 'predates DEV-962')" 1
    ok "  naming the flag that is missing"               "$(says 'has no .--diff-unchanged.')" yes
    ok "  and saying nothing is blocked"                 "$(says 'Nothing is blocked')" yes
    rid=$(remembered gh-portal-412 review)
    "$REVIEW_DESK_BIN" review link --review "$rid" --session sess-real962 --json > /dev/null
    put gh-portal-412 mode=review status=active repo=acme/portal number=412 \
      session_id=sess-real962 --by dispatcher
    search_doc acme/portal 412 sha777 "Retry failed webhook deliveries"
    age_marker 'gh-portal-412|review_request'
    rc=$(run "$disp" poll 1)
    ok "a real older build is not written to on a push"  "$("$REVIEW_DESK_BIN" review find --repo acme/portal --pr 412 --json | python3 -c 'import json,sys;r=json.load(sys.stdin)["reviews"];print("%d %s" % (len(r), r[0]["round"]))')" "1 1"
    ok "  and the fallback is not said twice"            "$(count 'predates DEV-962')" 0
    ok "  and nothing is blocked by it"                  "$rc" 0
    # **One gap stays open on such a build, and it is DEV-954's own.** A review linked by a
    # session this instance has no ledger entry for -- one started from the dashboard -- is
    # started, and a build with no `started` has nothing on its row that says so. The poller
    # learns the session from its 15-minute `review show`, so the window is one re-read wide,
    # and closing it needs the field. Measured here rather than claimed: drop the ledger entry
    # and the same push DOES reach the store.
    instance "$real"
    rm -f "$REVIEW_DESK_DB"
    search_doc acme/portal 611 head611 "A scheduled export keeps its context"
    rc=$(run "$disp" poll 1)
    rid=$(remembered gh-portal-611 review)
    "$REVIEW_DESK_BIN" review link --review "$rid" --session sess-dash962 --json > /dev/null
    search_doc acme/portal 611 head777 "A scheduled export keeps its context"
    age_marker 'gh-portal-611|review_request'
    rc=$(run "$disp" poll 1)
    ok "  a dashboard-linked one on an old build is not" "$("$REVIEW_DESK_BIN" review find --repo acme/portal --pr 611 --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["reviews"][0]["round"])')" 2
    # **DEV-954 against the real binary**, which the installed 0.1.0 CAN answer: `--session`
    # landed in review-desk #44, before DEV-962, so the first open links the session in one call.
    # `-gt 0` rather than a count: clap prints a flag in its usage line as well as its options
    # list on some builds, and the claim is that the flag exists.
    instance "$real"
    rm -f "$REVIEW_DESK_DB"
    ok "the real binary takes --session on review open"  "$([ "$("$REVIEW_DESK_BIN" review open --help | grep -c -- '--session')" -gt 0 ] && echo yes || echo no)" yes
    ok "  and sets session_id from that one call"        "$("$REVIEW_DESK_BIN" review open --repo acme/portal --pr 412 --head sha412 --session sess-first --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["review"]["session_id"])')" sess-first
    export REVIEW_DESK_DB="$work/real.db"
  fi

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

sed 's|^    return (a or "")\.strip()\.lower() == (b or "")\.strip()\.lower()$|    return a == b  # COMMIT COMPARED RAW|' \
    "$disp" > "$work/noheadq.py"
ok "the commit-comparison reversal changed one line"   "$(grep -c 'COMMIT COMPARED RAW' "$work/noheadq.py")" 1
instance '{"mode":"auto"}'
preopen acme/portal 412 sha412upper 7
search_doc acme/portal 412 SHA412UPPER Retry
rc=$(run "$work/noheadq.py" poll 3)
# ONE write, not one per tick, and the difference is worth the sentence: the record holds
# GitHub's spelling after a write, so the raw comparison agrees from the second tick on. The
# review that raised this expected a write per tick for ever; measured, it is a single spurious
# write per request whose looked-up commit is spelled differently. Still a write nobody asked
# for, on a row this path works hard not to touch.
ok "  without it a spelling difference buys one write" "$(opens)" 1

# The test moved into `review_desk_missing` when DEV-962 gave it a third caller, so the
# reversal is one line in one place rather than three inline `startswith`es -- which makes this
# control stronger than it was: it now reverses the question for `out-of-play` and `in-play` as
# well, where reading any refusal as "gone" would stop them saying anything at all.
sed 's/^    return (detail or "")\.startswith(REVIEW_DESK_MISSING_REFUSAL)$/    return True  # ANY REFUSAL FORGETS/' \
    "$disp" > "$work/nomissinggate.py"
ok "the gone-review reversal changed one line"         "$(grep -c 'ANY REFUSAL FORGETS' "$work/nomissinggate.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nomissinggate.py" poll 1)
echo locked > "$work/rd.show.mode"
rc=$(run "$work/nomissinggate.py" poll 2)
ok "  without it any refusal forgets the record"       "$(finds)" 2

sed 's/^    return str(key)\.lower()$/    return str(key)  # CASE KEPT/' "$disp" > "$work/nocase.py"
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

sed -e 's/^                                  if k in present or v\.get("dismissed") or v\.get("closed")$/                                  if k in present}  # DISMISSAL PRUNED/' \
    -e 's/^                                  or v\.get("out_of_play")}$//' \
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
ok "  without it a dismissed review is looked up again" "$(finds)" 2

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
ok "the ask-once-a-tick reversal changed its lines"    "$(grep -c 'READ STOP REMOVED' "$work/noreadstop.py")" 5
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
rc=$(run "$work/noreadstop.py" poll 1)
echo oldshow > "$work/rd.show.mode"
rc=$(run "$work/noreadstop.py" poll 1)
ok "  without it a build is asked once per request"    "$(shows)" 2

sed 's/^    return bool(entry\.get("session_id")) or bool(held\.get("session"))$/    return bool(held.get("session"))  # LEDGER SESSION IGNORED/' \
    "$disp" > "$work/noledgersession.py"
ok "the ledger-session reversal changed one line"      "$(grep -c 'LEDGER SESSION IGNORED' "$work/noledgersession.py")" 1
# **Its harm changed with DEV-962 and the control changed with it.** A push to an unposted
# round no longer spends one whatever this reads, so "it opens round 2" is no longer the thing
# at stake. What is at stake is the ROUTING: a session the Dispatcher has claimed but that has
# not yet run `review link --session` leaves `session_id` on this instance's ledger and nothing
# on the review, so a build offering no `started` has the ledger as its only witness. Read
# without it, the move is OFFERED -- a second worker for a review that already has one, which is
# the one thing item 5 forbids.
# `lost`, not `active`: the status has to be one the emission speaks for, or the control measures
# silence instead of the offer. `lost` is REDISPATCHABLE and still carries the `session_id` the
# Dispatcher wrote at claim time, which is exactly the fact under test.
instance '{"mode":"auto"}'
touch "$work/rd.nostarted"
preopen acme/portal 412 sha412 7
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 session_id=live-7 \
  review_desk_id=7 --by dispatcher
search_doc acme/portal 412 sha999 Retry
rc=$(run "$disp" poll 1)
ok "the ledger's own session makes the move a wake"    "$(count '"event": "review_head_moved"')" 1
ok "  and offers it to nobody"                         "$(count '"event": "review_request"')" 0
instance '{"mode":"auto"}'
touch "$work/rd.nostarted"
preopen acme/portal 412 sha412 7
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 session_id=live-7 \
  review_desk_id=7 --by dispatcher
search_doc acme/portal 412 sha999 Retry
rc=$(run "$work/noledgersession.py" poll 1)
ok "  without it the move is offered to a second worker" "$(count '"event": "review_request"')" 1
ok "  and nobody is woken for it"                      "$(count review_head_moved)" 0
rm -f "$work/rd.nostarted"

sed 's/^        writing = (looked and not self\.record_stopped and not held\.get("dismissed")$/        writing = (looked and not self.record_stopped  # DISMISSAL WRITTEN TO/' \
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

sed 's/^        for call, (state, detail, repo) in sorted(self\.record_broken\.items()):$/        for call, (state, detail, repo) in []:  # NO VOICE AT ALL/' \
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

sed 's/^    return bool(entry\.get("session_id")) or bool(held\.get("session"))$/    return bool(entry.get("session_id"))  # SESSION IGNORED/' \
    "$disp" > "$work/nosession.py"
ok "the linked-session reversal changed one line"      "$(grep -c 'SESSION IGNORED' "$work/nosession.py")" 1
# **Its harm changed with DEV-962.** A push no longer spends a round whatever this reads, so
# what is at stake is the ROUTING: the session Review Desk reports on the review is the only
# witness for a review opened from the dashboard, or one a session linked itself to without this
# dispatcher claiming it. Read without it, the move is offered as work rather than relayed --
# a second worker on a review that already has one.
instance '{"mode":"auto"}'
touch "$work/rd.nostarted"
preopen acme/portal 412 sha412 7 dead-1
search_doc acme/portal 412 sha999 Retry
rc=$(run "$disp" poll 1)
ok "the review's own session makes the move a wake"    "$(count '"event": "review_head_moved"')" 1
instance '{"mode":"auto"}'
touch "$work/rd.nostarted"
preopen acme/portal 412 sha412 7 dead-1
search_doc acme/portal 412 sha999 Retry
rc=$(run "$work/nosession.py" poll 1)
ok "  without it the move is offered to a second worker" "$(count '"event": "review_request"')" 1
rm -f "$work/rd.nostarted"

sed 's/^        self\.record_unreachable(rd, every)$/        pass  # NOTICE AFTER THE RETURN/' \
    "$disp" > "$work/nountrusted.py"
ok "the truncation reversal changed one line"          "$(grep -c 'NOTICE AFTER THE RETURN' "$work/nountrusted.py")" 1
NOMAP=1 instance '{"mode":"on"}'
search_page acme/portal 50 60
echo broken > "$work/rd.mode"
rc=$(run "$work/nountrusted.py" poll 1)
ok "  without it a truncated page reports nothing"     "$(count review_desk_unavailable)" 0

sed 's/^        for call, (state, detail, repo) in sorted(self\.record_broken\.items()):$/        for call, (state, detail, repo) in ([] if review_desk_repos(cfg, ledger) else sorted(self.record_broken.items())):  # DEFERRED TO THE READER/' \
    "$disp" > "$work/nosplit.py"
ok "the split-health reversal changed one line"        "$(grep -c 'DEFERRED TO THE READER' "$work/nosplit.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo broken > "$work/rd.open.mode"
rc=$(run "$work/nosplit.py" poll 1)
ok "  without it a broken write is never reported"     "$(count review_desk_unavailable)" 0

sed 's/^        rid = review_id(held\.get("review")) or review_id(entry\.get("review_desk_id"))$/        rid = review_id(held.get("review"))  # LEDGER ID IGNORED/' \
    "$disp" > "$work/noledgerid.py"
ok "the ledger-id reversal changed one line"           "$(grep -c 'LEDGER ID IGNORED' "$work/noledgerid.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 session_id=dead-9 review_desk_id=11 --by worker
rc=$(run "$work/noledgerid.py" poll 1)
ok "  without it such a review is never read"          "$(shows)" 0

sed 's/^            self\.record_stopped = True$/            pass  # UNREADABLE NOT STOPPED/' \
    "$disp" > "$work/nounreadablestop.py"
ok "the unreadable-answer reversal changed its lines"  "$(grep -c 'UNREADABLE NOT STOPPED' "$work/nounreadablestop.py")" 5
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo notobject > "$work/rd.open.mode"
rc=$(run "$work/nounreadablestop.py" poll 1)
ok "  without it one tick writes once per request"     "$(opens)" 2

sed 's/^            self\.read_stopped = True$/            pass  # READ UNREADABLE NOT STOPPED/' \
    "$disp" > "$work/noreadbroken.py"
ok "the unreadable-read reversal changed its lines"    "$(grep -c 'READ UNREADABLE NOT STOPPED' "$work/noreadbroken.py")" 2
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
rc=$(run "$work/noreadbroken.py" poll 1)
echo notobject > "$work/rd.show.mode"
rc=$(run "$work/noreadbroken.py" poll 1)
ok "  without it one tick reads once per request"      "$(shows)" 2

sed 's/^        if not held and not self\.look_stopped and not self\.record_stopped:$/        if False:  # LOOK SKIPPED/' "$disp" > "$work/nolook.py"
ok "the look-first reversal changed one line"          "$(grep -c 'LOOK SKIPPED' "$work/nolook.py")" 1
# **What a blind first write costs changed with DEV-962, and the look is narrower for it.** It
# used to spend a round; an unposted round now moves instead, and `review open`'s own answer
# carries `session_id` and `started` -- so the ROUTING no longer needs the look either. What is
# left is the one thing a write cannot undo: a review the developer has DISMISSED. The look is
# what reads the dismissal before the first write, and a write moves `last_activity_at` on a row
# somebody deliberately took out of play, which is the harm this file keeps arranging to avoid.
instance '{"mode":"auto"}'
preopen acme/portal 412 oldhead 7
dismiss acme/portal 412 "closed unmerged"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$disp" poll 1)
ok "the look keeps the first write off a dismissed row" "$(opens)" 0
ok "  and says why nothing was dispatched"             "$(count '"event": "review_dismissed"')" 1
instance '{"mode":"auto"}'
preopen acme/portal 412 oldhead 7
dismiss acme/portal 412 "closed unmerged"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nolook.py" poll 1)
ok "  without it the first sight of one writes to it"  "$(opens)" 1

sed 's/^            self\.read_stopped = True$/            self.read_stopped = True; self.record_stopped = True  # READ STOPS WRITES/' \
    "$disp" > "$work/noreadsplit.py"
ok "the read-stops-writes reversal changed its lines"  "$(grep -c 'READ STOPS WRITES' "$work/noreadsplit.py")" 2
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/noreadsplit.py" poll 1)
echo broken > "$work/rd.show.mode"
search_pair acme/portal 412 sha412 413 sha413
rc=$(run "$work/noreadsplit.py" poll 1)
ok "  without it a broken read loses a new request"    "$(remembered gh-portal-413 head)" ""

sed 's/^            self\.look_stopped = True$/            self.record_stopped = True  # LOOK FAILURE STOPS EVERYTHING/' \
    "$disp" > "$work/nolookdegrade.py"
ok "the degrade-the-look reversal changed one line"    "$(grep -c 'LOOK FAILURE STOPS EVERYTHING' "$work/nolookdegrade.py")" 1
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo oldfind > "$work/rd.find.mode"
rc=$(run "$work/nolookdegrade.py" poll 1)
ok "  without it such a build records nothing at all"  "$(opens)" 0

sed 's/^                if self\.due("review_desk|read_unsupported", every):$/                if False:  # READ UNSUPPORTED UNSAID/' \
    "$disp" > "$work/nosayread.py"
ok "the say-it reversal changed one line"              "$(grep -c 'READ UNSUPPORTED UNSAID' "$work/nosayread.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nosayread.py" poll 1)
echo oldshow > "$work/rd.show.mode"
rc=$(run "$work/nosayread.py" poll 1)
ok "  without it a build that cannot read is silent"   "$(count review_desk_unavailable)" 0

sed 's|^    return (repo or "")\.strip()\.lower()$|    return repo  # REPO AS HANDED|' \
    "$disp" > "$work/norepocase.py"
ok "the canonical-repository reversal changed one line" "$(grep -c 'REPO AS HANDED' "$work/norepocase.py")" 1
instance '{"mode":"auto"}'
preopen acme/portal 412 oldhead 7 sess-dash
dismiss acme/portal 412 "closed unmerged"
search_doc Acme/Portal 412 Retry
rc=$(run "$work/norepocase.py" poll 1)
ok "  without it the look answers nothing and writes"  "$(opens)" 1
# And the write is blind in the way the control above describes: a mixed-case slug makes the
# look answer "no review here" about a row the store does hold.
#
# **The dismissal is still SAID, and that is the measurement rather than a hole in the control.**
# `review open`'s own answer carries `dismissed_at`, so the poller learns the dismissal from the
# write it should not have made -- one write too late. The write is therefore the whole of the
# harm and `opens` above is the whole of the assertion; a second one about the notice would be
# asserting something that is true either way.
ok "  and says so only after writing to it"           "$(count '"event": "review_dismissed"')" 1

sed 's/^                self.state\["review_backlog"\]\.append(key)$/                pass  # BACKLOG AFTER THE DISMISSAL/' \
    "$disp" > "$work/nobacklog.py"
# ONE line. `linear_triggers` appends to the same list, but from inside an `if backlog:` whose
# body is indented differently, so this pattern reaches only the review path -- which is the
# one under test. Pinning the count is what stops the sed quietly matching neither.
ok "the backlog-order reversal changed one line"      "$(grep -c 'BACKLOG AFTER THE DISMISSAL' "$work/nobacklog.py")" 1
instance '{"mode":"auto"}'
preopen acme/portal 412 sha412 7
dismiss acme/portal 412 "closed unmerged"
search_doc acme/portal 412 sha412 Retry
rc=$(run "$work/nobacklog.py" poll 1)
restore acme/portal 412
age_marker 'review_desk|dismissal|gh-portal-412'
rc=$(run "$work/nobacklog.py" poll 1)
ok "  without it a restored request auto-dispatches"   "$(says '"backlog": false')" yes
# A citation's hash is a commit on a Review Desk branch, and a rebase rewrites it. On 12 October
# 2026 all four this brief cited had stopped resolving at once, so a reader following any of them
# found nothing and could not tell whether the claim had ever been true. These two assertions are
# the guard: the brief says what a hash is and what to do when it has gone, and no citation points
# at one of the four known-dead ones. Short single-line substrings, because the prose rewraps.
ok "the brief says what its hashes are"             "$(grep -c 'hashes in this file are where a claim was measured' "$brief_md")" 1
ok "  and that a rebase deletes them"               "$(grep -c 'a rebase rewrites them' "$brief_md")" 1
# Matched as `review-desk <hash>`, the form a citation takes, NOT as a bare hash: the note names
# f762e61 on purpose as the case that died within hours of being written, and an assertion that
# forbade the mention would delete the evidence for the rule it is guarding.
ok "  offers none of the five dead ones as evidence" "$(grep -cE 'review-desk `(a64f8a9|13a78ee|bae4f5e|c17d335|f762e61)`' "$brief_md" || true)" 0
# f762e61 joined that list the day it was written: it replaced one of the four on 12 October 2026
# and its pull request rebased again before merging, so it died within hours. The citations now
# name master, where a merge commit is not rewritten, and this asserts the brief got there.
ok "  and cites master instead"                     "$([ "$(grep -c '41bbc10' "$brief_md")" -gt 0 ] && echo yes || echo no)" yes

sed 's/^                   and not (held\.get("old") and held\.get("head"))$/                   and True  # OLD BUILD FOLLOWS THE HEAD/' \
    "$disp" > "$work/noold.py"
ok "the old-build reversal changed one line"           "$(grep -c 'OLD BUILD FOLLOWS THE HEAD' "$work/noold.py")" 1
instance '{"mode":"auto"}'
search_doc acme/portal 412 sha412 Retry
echo oldledger > "$work/rd.open.mode"
rc=$(run "$work/noold.py" poll 1)
search_doc acme/portal 412 sha999 Retry
rc=$(run "$work/noold.py" poll 1)
ok "  without it a push opens a second review"         "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["acme/portal#412"]["round"])' "$work/rd.opens.json")" 2

sed 's/^        if not head:$/        if self.record_stopped or not head:  # WRITE FAILURE STOPS THE READ/' \
    "$disp" > "$work/nosplitread.py"
ok "the stop-the-read reversal changed one line"       "$(grep -c 'WRITE FAILURE STOPS THE READ' "$work/nosplitread.py")" 1
# The recorded key comes SECOND on the page, which is the ordering that shows it: the flag is
# set by the new request's look, and everything after it in the loop is what gets cancelled.
instance '{"mode":"auto"}'
search_doc acme/portal 413 sha413 Retry
rc=$(run "$work/nosplitread.py" poll 1)
dismiss acme/portal 413 "closed unmerged"
search_pair acme/portal 412 sha412 413 sha413
echo notobject > "$work/rd.find.mode"
rc=$(run "$work/nosplitread.py" poll 1)
ok "  without it one new request kills every read"     "$(shows)" 0

sed 's/^        self\.record_old = False  # per key, and the comment above says why$/        pass  # OLD LEAKS ACROSS KEYS/' \
    "$disp" > "$work/noperkeyold.py"
ok "the per-key reversal changed one line"             "$(grep -c 'OLD LEAKS ACROSS KEYS' "$work/noperkeyold.py")" 1
instance '{"mode":"auto"}'
search_pair acme/portal 412 sha412 413 sha413
echo oldledger > "$work/rd.open.mode"
echo 412 > "$work/rd.open.oldfor"
rc=$(run "$work/noperkeyold.py" poll 1)
ok "  without it the flag leaks onto another key"      "$(remembered gh-portal-413 old)" True

# `return None, None`, not a bare `return`: `record_request` hands back `(action, previous)`
# since DEV-962, so a bare one would make the caller's unpacking a TypeError and this control
# would measure a crash rather than the degradation it is about.
sed 's/^                looked = False$/                return None, None  # LOOK FAILURE RETURNS/' \
    "$disp" > "$work/nolooked.py"
ok "the look-failed reversal changed one line"         "$(grep -c 'LOOK FAILURE RETURNS' "$work/nolooked.py")" 1
instance '{"mode":"auto"}'
preopen acme/portal 412 sha412 7
dismiss acme/portal 412 "closed unmerged"
search_doc acme/portal 412 sha999 Retry
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 review_desk_id=7 --by worker
echo notobject > "$work/rd.find.mode"
rc=$(run "$work/nolooked.py" poll 1)
ok "  without it that key's dismissal is never read"   "$(shows)" 0
ok "  and a dismissed review is dispatched"            "$(count '"event": "review_request"')" 1

sed 's|^                      head if writing else (held\.get("head") or review\.get("head_sha") or head),$|                      head if writing else (held.get("head") or head),  # GITHUB HEAD ON A READ|' \
    "$disp" > "$work/noreadhead.py"
ok "the read-commit reversal changed one line"         "$(grep -c 'GITHUB HEAD ON A READ' "$work/noreadhead.py")" 1
instance '{"mode":"auto"}'
preopen acme/portal 412 sha412 7
search_doc acme/portal 412 sha999 Retry
put gh-portal-412 mode=review status=lost repo=acme/portal number=412 review_desk_id=7 --by worker
echo notobject > "$work/rd.find.mode"
rc=$(run "$work/noreadhead.py" poll 1)
ok "  without it the record claims GitHub's commit"    "$(remembered gh-portal-412 head)" sha999

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
