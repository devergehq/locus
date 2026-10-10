#!/bin/sh
# Unit tests for the two things DEV-891 adds to skills/dispatcher/workers/review.md: the code a
# finding is about, and the draft written in parts.
#
# What is under test is a BRIEF -- prose a worker obeys -- so nothing here greps it and stops.
# Three readers pull the recipe out of review.md and then run it:
#
#   hunkspec.py  reads the brief's `git diff` line and its marker table, and reports the context
#                count, the marker for each diff prefix and which markers carry a number.
#   hunk.py      builds a finding's hunk from a real `git diff`, driven by what hunkspec.py read.
#                Change the brief's table and this builder changes with it.
#   compose.py   composes a body from blocks by the rule the brief states, so the composition can
#                be checked -- and byte-compared against the real binary's -- without one.
#
# Sections A to C need no binary and always run. Section D needs a `review-desk` on PATH that
# takes `draft put --sections`, and SKIPS loudly when there is none: ci.yml's shell-harness step
# states that none of these needs a built binary, and that sentence stays true.
#
# NOTHING HERE TOUCHES ~/.review-desk. $REVIEW_DESK_DB is exported to a path under mktemp before
# the first call and asserted to be where the binary actually reads, because the developer who
# runs this harness is the one most likely to have a live store there. Nothing touches
# ~/.locus/data/dispatcher either: no dispatcher instance is created and dispatcher.py is not run.
# No test makes a network call off this machine -- `serve` binds 127.0.0.1 and has no flag that
# could widen it -- and no test posts anything anywhere.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
brief="$root/skills/dispatcher/workers/review.md"
style="$root/skills/review-craft/house-style.md"
lint="$root/skills/review-craft/review_lint.py"

work=$(mktemp -d)
server=
cleanup () {
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/bin"

REVIEW_DESK_DB="$work/rd.db"
export REVIEW_DESK_DB

pass=0
fail=0
skip=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-58s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-58s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}
skipped () { skip=$((skip + 1)); printf '  SKIP  %s\n' "$1"; }

# ---- the readers ----------------------------------------------------------------------------

cat > "$work/hunkspec.py" <<'SPEC'
"""The hunk recipe, read out of workers/review.md rather than restated here.

Three things the brief states and a builder needs: how many lines of context to ask git for, the
marker each diff prefix becomes, and which markers carry a line number. Reading them means a
builder that disagrees with the brief cannot pass -- which is the only way prose a worker obeys
is under test at all.
"""
import json, pathlib, re, sys

doc = pathlib.Path(sys.argv[1]).read_text()

context = re.search(r"git diff -U(\d+) <base> <head> -- <path>", doc)

# The marker table: `| In the diff | hunk.lines[] | Numbered |`. A row names the diff prefix in
# prose ("a line beginning with `+`") and the marker as a JSON fragment, so both are read from
# the cells rather than assumed from their order.
start = next(i for i, line in enumerate(doc.split("\n"))
             if line.startswith("| In the diff |"))
markers, numbered, rows = {}, {}, 0
for line in doc.split("\n")[start + 2:]:
    if not line.startswith("|"):
        break
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    rows += 1
    prefix = re.search(r"beginning with (?:a space|`(.)`)", cells[0])
    marker = re.search(r'"marker": "(\w+)"', cells[1])
    if not (prefix and marker):
        continue
    key = prefix.group(1) or " "
    markers[key] = marker.group(1)
    numbered[marker.group(1)] = cells[2].strip("*") == "yes"

print(json.dumps({
    "context": int(context.group(1)) if context else None,
    "markers": markers,
    "numbered": numbered,
    "rows": rows,
    # `start_line` is the `@@` header's new-side start, and the brief says which number that is.
    "start_line_is_first_kept":
        "number the **first added or unchanged**\nline carries" in doc,
    # The heading the store composes, which `compose.py` needs and must not invent.
    "heading": (re.search(r"`### \{Severity\} · F\{seq\} · \{title\}`", doc) is not None),
}, sort_keys=True))
SPEC

cat > "$work/hunk.py" <<'HUNK'
"""One finding's hunk, built from a real `git diff` by the brief's own marker table.

    git diff -U<context> <base> <head> -- <path> | hunk.py <spec.json> <path> <line>

Prints the hunk `finding add` takes, or exits 1 when no hunk in that diff draws the line -- which
is the brief's "a finding with no hunk is a fact about the finding". The answer to "is this
finding in the change" is this exit code and nothing else: a test that took the answer from its
own fixture would be asserting what it wrote down.
"""
import json, pathlib, re, sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
path, line = sys.argv[2], int(sys.argv[3])
MARKER, NUMBERED = spec["markers"], spec["numbered"]

hunks, cur = [], None
for raw in sys.stdin.read().split("\n"):
    head = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", raw)
    if head:
        cur = {"file": path, "start_line": int(head.group(1)), "lines": []}
        hunks.append(cur)
        continue
    if cur is None or not raw or raw.startswith("\\"):
        continue                      # the diff's preamble, and "\ No newline at end of file"
    if raw[0] not in MARKER:
        cur = None                    # the next file's preamble; this hunk is finished
        continue
    cur["lines"].append({"marker": MARKER[raw[0]], "text": raw[1:]})


def numbers(hunk):
    """The number each entry carries: upward from start_line, an unnumbered marker taking none."""
    at, out = hunk["start_line"], []
    for entry in hunk["lines"]:
        if NUMBERED[entry["marker"]]:
            out.append(at); at += 1
        else:
            out.append(None)
    return out


for hunk in hunks:
    if line in numbers(hunk):
        print(json.dumps(hunk, sort_keys=True))
        break
else:
    sys.exit("no hunk in that diff draws %s:%d" % (path, line))
HUNK

cat > "$work/numbers.py" <<'NUMBERS'
"""What a hunk's rows are numbered, and what text each number carries.

Prints `<number> <text>` a row at a time, blank for a removal. The point of it is the one
assertion that cannot be faked from the diff alone: the text against the flagged number has to
be the line that number holds in the checkout.
"""
import json, pathlib, sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
hunk = json.loads(pathlib.Path(sys.argv[2]).read_text())
at = hunk["start_line"]
for entry in hunk["lines"]:
    if spec["numbered"][entry["marker"]]:
        print("%d %s" % (at, entry["text"])); at += 1
    else:
        print(" %s" % entry["text"])
NUMBERS

cat > "$work/compose.py" <<'COMPOSE'
"""A body composed from blocks, by the rule the brief states.

    compose.py <blocks.json> <severities.json>

A prose block is its text. A finding block is `### {Severity} · F{seq} · {title}`, a blank line,
then its text -- the severity being the finding's LIVE one, which is why it is passed in rather
than carried on the block. Blocks are joined by a blank line and the body ends in one newline.

This exists so sections A to C can check a composition without a binary, and so section D can
byte-compare the real one against it. Where the two disagree, this file is what is wrong.
"""
import json, pathlib, sys

blocks = json.loads(pathlib.Path(sys.argv[1]).read_text())
severity = {int(k): v for k, v in json.loads(pathlib.Path(sys.argv[2]).read_text()).items()}

out = []
for block in blocks:
    if block["kind"] == "prose":
        out.append(block["text"])
    else:
        seq = block["finding_seq"]
        out.append("### %s · F%d · %s\n\n%s"
                   % (severity[seq], seq, block["title"], block["text"]))
sys.stdout.write("\n\n".join(out) + "\n")
COMPOSE

cat > "$work/post.py" <<'POST'
"""One POST, and its status code. The decision endpoint has no CLI, deliberately.

    post.py <url> <json-body> <response-file>   ->  prints the HTTP status

urllib rather than curl: every other harness here needs nothing but sh, python3 and git, and the
one call this makes is to 127.0.0.1.
"""
import pathlib, sys, urllib.error, urllib.request

url, body, out = sys.argv[1], sys.argv[2], sys.argv[3]
request = urllib.request.Request(url, data=body.encode(), method="POST",
                                 headers={"content-type": "application/json"})
try:
    with urllib.request.urlopen(request, timeout=20) as answer:
        pathlib.Path(out).write_bytes(answer.read())
        print(answer.status)
except urllib.error.HTTPError as refused:
    pathlib.Path(out).write_bytes(refused.read())
    print(refused.code)
POST

cat > "$work/against.py" <<'AGAINST'
"""Every number a hunk draws, against the file at the head commit.

    against.py <numbered.txt> <file-at-head>   ->  the numbers whose text disagrees, or "none"

The one assertion in this harness that cannot agree with itself: the hunk's numbering comes from
the diff, and this is the checkout. An off-by-one in `start_line` is invisible to everything else
and shows up here as every number after the first change.
"""
import pathlib, sys

held = pathlib.Path(sys.argv[2]).read_text().split("\n")
wrong = []
for row in pathlib.Path(sys.argv[1]).read_text().split("\n"):
    if not row or row.startswith(" "):
        continue                                  # a removal: it carries no number
    number, _, text = row.partition(" ")
    if held[int(number) - 1] != text:
        wrong.append(number)
print(",".join(wrong) or "none")
AGAINST

spec () { python3 "$work/hunkspec.py" "${1:-$brief}"; }
ask () { spec "${2:-$brief}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)"; }

# =============================================================================================
printf '\nA. the recipe, read out of the brief\n'

spec > "$work/spec.json"
ok "the brief names the context to take"            "$(ask "d['context']")" 3
ok "  and a marker for each of the three prefixes"  "$(ask "sorted(d['markers'])")" "[' ', '+', '-']"
ok "  mapping a space to unchanged"                 "$(ask "d['markers'][' ']")" unchanged
ok "  a plus to added"                              "$(ask "d['markers']['+']")" added
ok "  a minus to removed"                           "$(ask "d['markers']['-']")" removed
ok "  numbering the added and the unchanged"        "$(ask "[d['numbered']['added'], d['numbered']['unchanged']]")" "[True, True]"
ok "  and never the removed"                        "$(ask "d['numbered']['removed']")" False
ok "  over five rows: the two non-lines too"        "$(ask "d['rows']")" 5
ok "  and says which number start_line is"          "$(ask "d['start_line_is_first_kept']")" True
ok "the composed heading's format is stated"        "$(ask "d['heading']")" True

printf '\n  the rules the store enforces, named before a write is refused\n'
ok "the hunk is read from the checkout"             "$(grep -c 'Read the hunk from the checkout' "$brief")" 1
ok "  and never retyped"                            "$(grep -c 'Never retype it, and never reformat it' "$brief")" 1
ok "a removed line can never be flagged"            "$(grep -c 'can never be flagged' "$brief")" 1
ok "one file line per entry"                        "$(grep -c 'One file line per entry' "$brief")" 1
ok "a long hunk is trimmed from its ends"           "$(grep -c 'trimmed from its ends, never from its middle' "$brief")" 1
ok "  with what that does to start_line"            "$(grep -c 'add one to' "$brief")" 1
ok "the three fields are a rule, not a nudge"       "$(grep -c 'this is a rule' "$brief")" 1
ok "  naming all three"                             "$(grep -c '`hunk`, `flagged_line` and `inline_comment`' "$brief")" 1
ok "a finding with no hunk is a fact about it"      "$(grep -c 'not an omission, and there are three kinds' "$brief")" 1
ok "  and the three kinds are enumerated"           "$(grep -c 'A finding on a file the change never touches' "$brief")" 1
ok "the JSON is given, not described"               "$(grep -c '"flagged_line": 16,' "$brief")" 1
ok "  with the hunk inside it"                      "$(grep -c '"marker": "removed",' "$brief")" 1

printf '\n  the draft, in parts\n'
ok "the draft is written with --sections"            "$(grep -c 'draft put --review <id> --sections draft.json' "$brief")" 1
ok "  and why one block refuses every decision"      "$(grep -c 'written as one block of markdown rather than in parts' "$brief")" 1
ok "  each posted finding gets one block"            "$(grep -c 'One block per finding, and only for a finding that posts' "$brief")" 1
ok "  a nit gets its own block"                      "$(grep -c 'A nit gets its own block' "$brief")" 1
ok "  the title is written and the heading is not"   "$(grep -c 'Write only the title; the heading is not yours' "$brief")" 1
ok "  the status line is the block's first line"     "$(grep -c "block's first line" "$brief")" 1
ok "  and the composed body is what gets linted"     "$(grep -c 'Lint the composed body, not your draft' "$brief")" 1
ok "without Review Desk it is one markdown draft"    "$(grep -c "Without Review Desk, step 12's single markdown draft" "$brief")" 1
ok "the house style carries the section's shape"     "$(grep -c 'A section heading is `### {Severity} · {id} · {title}`' "$style")" 1
ok "  and where the status line goes"                "$(grep -c 'go on the section.s first line' "$style")" 1
ok "  and that a nit there is not grouped"           "$(grep -c 'each Nit raised gets its own section' "$style")" 1
# The other rule the composition overrides, and the one that would have been left contradicting
# itself: "at most three findings raised in the body" is about a body an agent writes whole, and
# a finding with no block cannot be decided on at all.
ok "  and that the three-in-the-body cap moves"      "$(grep -c 'the cap moves to the findings' "$style")" 1
ok "  with the brief saying so where blocks are written" "$(grep -c 'Every posted finding gets a block, past three' "$brief")" 1
ok "  and nothing relaxed for a body you write"      "$(grep -c 'three is still three' "$style")" 1

# =============================================================================================
printf '\nB. the hunk, built from a fixture repository\n'
# A real repository with a real commit, because the recipe's input is `git diff` and a recorded
# diff would let an off-by-one in the numbering agree with itself.

fix="$work/fix"
mkdir -p "$fix/jobs" "$fix/docs"
git -c init.defaultBranch=main init -q "$fix"
cat > "$fix/jobs/DeliverWebhook.php" <<'PHP'
<?php

class DeliverWebhook
{
    private $client;
    private $url;

    public function __construct($client, $url)
    {
        $this->client = $client;
        $this->url = $url;
    }

    public function handle($payload)
    {
        $this->client->post($this->url, $payload);
    }

    public function retry($payload)
    {
        $this->handle($payload);
    }
}
PHP
cat > "$fix/docs/webhooks.md" <<'DOC'
# Webhooks

The portal posts a webhook when an order changes.

A delivery that times out is retried by the queue.

The receiver is expected to be idempotent, which this document
has claimed since before anything made it true.

There is no idempotency key.
DOC
git -C "$fix" add -A
git -C "$fix" -c user.email=t@example.invalid -c user.name=T commit -qm base
base=$(git -C "$fix" rev-parse HEAD)
# The change: `handle` keeps the response and returns it. One removal, three additions.
python3 - "$fix/jobs/DeliverWebhook.php" <<'EDIT'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "        $this->client->post($this->url, $payload);\n",
    "        $response = $this->client->post($this->url, $payload);\n"
    "\n"
    "        return $response;\n"))
EDIT
git -C "$fix" add -A
git -C "$fix" -c user.email=t@example.invalid -c user.name=T commit -qm change
head=$(git -C "$fix" rev-parse HEAD)

# build <path> <line> -> exit code; the hunk in $work/hunk.json when there is one
build () {
  set +e
  git -C "$fix" diff "-U$(ask "d['context']")" "$base" "$head" -- "$1" \
    | python3 "$work/hunk.py" "$work/spec.json" "$1" "$2" > "$work/hunk.json" 2>"$work/hunk.err"
  c=$?
  set -e
  echo $c
}
field () { python3 -c "
import json
hunk = json.load(open('$work/hunk.json'))
print($1)"; }

ok "a hunk is built for the flagged line"            "$(build jobs/DeliverWebhook.php 16)" 0
ok "  naming the file it came from"                  "$(field "hunk['file']")" jobs/DeliverWebhook.php
ok "  starting at the @@ header's new side"          "$(field "hunk['start_line']")" 13
ok "  with the three lines of context above"         "$(field "hunk['lines'][1]['text']")" "    public function handle(\$payload)"
ok "  the removal, carried with its text"            "$(field "hunk['lines'][3]['marker']")" removed
ok "  and the additions after it"                    "$(field "hunk['lines'][4]['marker']")" added
ok "  over ten rows at -U3"                          "$(field "len(hunk['lines'])")" 10

printf '\n  the flagged line is the line it names\n'
# The assertion that cannot agree with itself: the text the hunk draws against 16 against the
# text line 16 actually holds in the checkout. An off-by-one in start_line fails here and
# nowhere else.
python3 "$work/numbers.py" "$work/spec.json" "$work/hunk.json" > "$work/numbered.txt"
ok "the hunk draws the flagged number"               "$(grep -c '^16 ' "$work/numbered.txt")" 1
ok "  and its text is line 16 of the checkout"       "$(sed -n 's/^16 //p' "$work/numbered.txt")" "$(git -C "$fix" show "$head:jobs/DeliverWebhook.php" | sed -n '16p')"
git -C "$fix" show "$head:jobs/DeliverWebhook.php" > "$work/at-head.txt"
ok "  as is every other number it draws"             "$(python3 "$work/against.py" \
    "$work/numbered.txt" "$work/at-head.txt")" none
ok "  the removal is drawn with no number"           "$(grep -c '^ ' "$work/numbered.txt")" 1
ok "a removed line cannot be flagged: 17 is kept"    "$(sed -n 's/^17 //p' "$work/numbered.txt")" ""

printf '\n  every finding whose file and line are in the change carries all three\n'
# The rule, over a fixture set that deliberately holds both kinds. `in_change` is NOT read from
# the fixture: it is the builder's exit code, so the finding set cannot assert its own answer.
cat > "$work/findings.json" <<'FINDINGS'
[
 {"lens": "error handling", "severity": "should",
  "claim": "the response is returned without checking its status",
  "file": "jobs/DeliverWebhook.php", "line": 16,
  "inline_comment": "`post` can answer 500 and this returns it as a success.",
  "why_it_matters": "A failed delivery is recorded as delivered, and the retry never runs.",
  "suggested_fix": "Throw on a non-2xx response before returning it.",
  "verification": "read_not_run"},
 {"lens": "naming", "severity": "nit",
  "claim": "`$response` says its type, not its role",
  "file": "jobs/DeliverWebhook.php", "line": 16,
  "inline_comment": "`$delivery` reads better at the call site."},
 {"lens": "sibling diff", "severity": "should",
  "claim": "the constructor takes a client it never checks",
  "file": "jobs/DeliverWebhook.php", "line": 5,
  "why_it_matters": "A null client fails at delivery time rather than at construction."},
 {"lens": "documentation", "severity": "nit",
  "claim": "the document still says there is no idempotency key",
  "file": "docs/webhooks.md", "line": 10,
  "why_it_matters": "The next reader believes the key does not exist."},
 {"lens": "correction", "severity": "should",
  "claim": "the description says the retry is dropped after a day; nothing drops it",
  "why_it_matters": "A reviewer takes a bound on the blast radius that is not there."}
]
FINDINGS

# Fill each finding in or out, by what git says, and report what the set looks like.
cat > "$work/apply.py" <<'APPLY'
"""Every finding, with a hunk where the change reaches its line and none where it does not.

Prints one line per finding -- `<n> in|out <fields>` -- and writes the documents `finding add`
would be given. Whether a finding is in the change is the builder's answer, never the fixture's.
"""
import json, pathlib, subprocess, sys

spec, findings, fix, base, head, out = sys.argv[1:7]
context = json.loads(pathlib.Path(spec).read_text())["context"]
findings = json.loads(pathlib.Path(findings).read_text())

for index, finding in enumerate(findings, 1):
    hunk = None
    if finding.get("file") and finding.get("line"):
        diff = subprocess.run(
            ["git", "-C", fix, "diff", "-U%d" % context, base, head, "--", finding["file"]],
            capture_output=True, text=True, check=True).stdout
        built = subprocess.run(
            [sys.executable, pathlib.Path(spec).with_name("hunk.py"), spec,
             finding["file"], str(finding["line"])],
            input=diff, capture_output=True, text=True)
        if built.returncode == 0:
            hunk = json.loads(built.stdout)
    if hunk:
        finding["hunk"] = hunk
        finding["flagged_line"] = finding["line"]
    pathlib.Path("%s/f%d.json" % (out, index)).write_text(json.dumps(finding, sort_keys=True))
    print("%d %s %s" % (index, "in" if hunk else "out",
                        ",".join(k for k in ("hunk", "flagged_line", "inline_comment")
                                 if finding.get(k))))
APPLY

mkdir -p "$work/add"
python3 "$work/apply.py" "$work/spec.json" "$work/findings.json" "$fix" "$base" "$head" \
    "$work/add" > "$work/applied.txt"
# The rule, as one expression: of the findings git says are in the change, how many are missing
# a field. Named here so section E's control can run the identical expression over a set that
# has had its hunks stripped, rather than re-implementing the rule it is meant to reverse.
incomplete () { grep ' in ' "$1" | grep -vc 'hunk,flagged_line,inline_comment' || true; }
ok "two of the five findings are in the change"      "$(grep -c ' in ' "$work/applied.txt")" 2
ok "  and three are not"                             "$(grep -c ' out ' "$work/applied.txt")" 3
ok "every in-change finding carries all three"       "$(incomplete "$work/applied.txt")" 0
ok "  which is the rule, not the fixture"            "$(grep -c 'hunk,flagged_line,inline_comment' "$work/applied.txt")" 2
ok "no out-of-change finding carries a hunk"         "$(grep ' out ' "$work/applied.txt" \
    | grep -c hunk)" 0
ok "a line the diff does not reach is out"           "$(sed -n 's/^3 \([a-z]*\).*/\1/p' "$work/applied.txt")" out
ok "a file the change never touches is out"          "$(sed -n 's/^4 \([a-z]*\).*/\1/p' "$work/applied.txt")" out
ok "and a correction to the description is out"      "$(sed -n 's/^5 \([a-z]*\).*/\1/p' "$work/applied.txt")" out

# =============================================================================================
printf '\nC. the blocks, and the body they compose to\n'

cat > "$work/blocks.json" <<'BLOCKS'
[
 {"kind": "prose", "text": "**1 Should · 1 Nit — 2 open.** `handle` now returns the HTTP response without looking at its status, so a 500 is recorded as a delivery.\n\n**Method** · read `DeliverWebhook` and its two callers · ran the job's unit tests · **0 suppressed** · **1 not verified** · **1 area not reviewed** (the queue configuration) — detail at the end"},
 {"kind": "prose", "text": "### Problem fit\nA retried delivery was indistinguishable from a first one, and keeping the response is the first half of fixing that. The shape is right: the caller needs the response to decide whether to retry."},
 {"kind": "finding", "finding_seq": 1, "title": "the response is returned without checking its status",
  "text": "**in diff** · `Open — needs a decision`\n\n**What** · `handle` returns whatever `post` answered, in [`DeliverWebhook.php:16`](https://github.com/o/r/pull/1/files#diff-1R16). A 500 is a response, so it returns as a success.\n**Why it matters** · A failed delivery is recorded as delivered and the retry never runs.\n**What I'd do** · Throw on a non-2xx before returning.\n\n<details><summary>Proof</summary>\n\njobs/DeliverWebhook.php:16, read at the head commit\n</details>"},
 {"kind": "finding", "finding_seq": 2, "title": "`$response` says its type, not its role",
  "text": "`DeliverWebhook.php:16` · `Open`\n`$delivery` reads better at the call site, and the two callers both name it that."},
 {"kind": "prose", "text": "<details><summary>How this review was made — scope, suppressed findings, what I could not verify</summary>\n\nRead `DeliverWebhook` and both callers at the head commit. Suppressed: none. Not verified: whether the queue retries on a thrown exception. Not reviewed: the queue configuration.\n</details>"}
]
BLOCKS
echo '{"1": "Should", "2": "Nit"}' > "$work/severities.json"
python3 "$work/compose.py" "$work/blocks.json" "$work/severities.json" > "$work/composed.md"

ok "a finding block composes one heading"            "$(grep -c '^### Should · F1 · the response is returned without checking its status$' "$work/composed.md")" 1
ok "  from the finding's live severity"              "$(grep -c '^### Nit · F2 · ' "$work/composed.md")" 1
ok "  and carries no glyph"                          "$(grep -c '^### [🔴🟠⚪🔵]' "$work/composed.md")" 0
ok "the body ends in exactly one newline"            "$(python3 -c "
b = open('$work/composed.md').read()
print(b.endswith('\n') and not b.endswith('\n\n'))")" True
ok "and a prose block is carried through verbatim"   "$(grep -c '^### Problem fit$' "$work/composed.md")" 1

printf '\n  the composed body passes review_lint.py, which is the hard part of DEV-891\n'
# review_lint.py reads GitHub and nothing else, so the body is served to it through a fake `gh`
# -- the pattern scripts/test-review-lint.sh already uses. Only the network is replaced.
cat > "$work/bin/gh" <<'GHSTANDIN'
#!/bin/sh
path=
for a in "$@"; do case "$a" in api|-H|--paginate|Accept:*) ;; *) path=$a ;; esac; done
case "$path" in
  user) echo '{"login":"principal"}' ;;
  */reviews) cat "$RDWORK/reviews.json" ;;
  */comments*) echo '[]' ;;
  *) echo "fake gh: unexpected $path" >&2; exit 1 ;;
esac
GHSTANDIN
chmod +x "$work/bin/gh"
RDWORK="$work"; export RDWORK
# serve <body-file>: the PR as GitHub would return it, carrying that body as the one review
serve_body () { python3 -c "
import json, sys
json.dump([{'id': 9001, 'user': {'login': 'principal'}, 'body': open(sys.argv[1]).read(),
            'submitted_at': '2026-10-11T00:00:00Z'}], open('$work/reviews.json', 'w'))" "$1"; }
# linted <body-file> -> exit code; the report in $work/lint.out
linted () {
  serve_body "$1"
  set +e
  PATH="$work/bin:$PATH" python3 "$lint" 1 --repo o/r > "$work/lint.out" 2>&1
  c=$?
  set -e
  echo $c
}
checks () { sed -n 's|^\([0-9]*\)/\1 checks passed$|all|p' "$work/lint.out"; }
named () { grep -qE "^(FAIL|WARN)  $1( |\$)" "$work/lint.out" && echo yes || echo no; }

ok "the composed body passes the linter"             "$(linted "$work/composed.md")" 0
ok "  on every one of its checks"                    "$(checks)" all
ok "  including the new status-line check"           "$(named sections.status_line)" no
ok "  and the two findings are counted as two"       "$(grep -c '^PASS  verdict.open_count' "$work/lint.out")" 1

# =============================================================================================
printf '\nD. against a real review-desk, on a temporary database\n'
# `cut`, `regrade` and `rewrite` are the developer's and have no command line, by design, so the
# only way to assert that a draft written this way accepts them is the HTTP API on 127.0.0.1.

capable () {
  command -v review-desk >/dev/null 2>&1 || return 1
  review-desk draft put --help 2>/dev/null | grep -q -- '--sections' || return 1
  review-desk finding add --help 2>/dev/null | grep -q 'flagged_line' || return 1
}

if ! capable; then
  skipped "no review-desk on PATH that takes 'draft put --sections' -- sections A to C ran"
  skipped "  (this is the CI case: ci.yml's harnesses need no built binary)"
else
  rc () { set +e; review-desk "$@" > "$work/out" 2>"$work/err"; echo $?; set -e; }

  ok "the binary reads the temporary database"       "$(review-desk db path --json \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['path'] == '$REVIEW_DESK_DB')")" True
  rid=$(review-desk review open --repo acme/portal --pr 412 --head "$head")
  ok "  and a review opens on it"                    "$rid" 1

  printf '\n  every finding, with the hunk the fixture built\n'
  : > "$work/seqs.txt"
  for n in 1 2 3 4 5; do
    review-desk finding add --review "$rid" --file "$work/add/f$n.json" >> "$work/seqs.txt"
  done
  ok "all five findings are accepted"                "$(wc -l < "$work/seqs.txt" | tr -d ' ')" 5
  ok "  numbered from one"                           "$(tr '\n' ' ' < "$work/seqs.txt")" "1 2 3 4 5 "
  ok "  and the store kept the hunk it was given"    "$(review-desk review show --review "$rid" --json \
      | python3 -c "
import json, sys
held = json.load(sys.stdin)['findings'][0]['hunk']
want = json.load(open('$work/hunk.json'))
print(held['start_line'] == want['start_line']
      and [(l['marker'], l['text']) for l in held['lines']]
          == [(l['marker'], l['text']) for l in want['lines']])")" True
  ok "  with the flagged line on it"                 "$(review-desk review show --review "$rid" --json \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['findings'][0]['flagged_line'])")" 16

  printf '\n  the refusals the brief is written around\n'
  python3 - "$work/add/f1.json" "$work" <<'BAD'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
out = pathlib.Path(sys.argv[2])
(out / "badline.json").write_text(json.dumps(dict(doc, flagged_line=99)))
# A removal carries no number at all, so there is no value that names one -- which is why the
# control for it is an out-of-range number rather than "the removal's line": that line has none.
(out / "badremoved.json").write_text(json.dumps(dict(doc, flagged_line=0)))
newline = json.loads(json.dumps(doc))
newline["hunk"]["lines"][0]["text"] = "two\nlines"
(out / "badnewline.json").write_text(json.dumps(newline))
BAD
  ok "a line the hunk does not draw is refused"      "$(rc finding add --review "$rid" --file "$work/badline.json")" 1
  ok "  naming the range it would accept"            "$(grep -c 'a line this hunk draws, 13 to 21' "$work/err")" 1
  ok "  which is the brief's own rule"               "$(grep -c 'has to be one of the numbers that hunk' "$brief")" 1
  ok "a flagged line of zero is refused"             "$(rc finding add --review "$rid" --file "$work/badremoved.json")" 1
  ok "a hunk entry holding two lines is refused"     "$(rc finding add --review "$rid" --file "$work/badnewline.json")" 1
  ok "  naming the one-line-per-entry rule"          "$(grep -c 'one file line per entry' "$work/err")" 1

  printf '\n  the draft, written in parts\n'
  ok "the sections document is accepted"             "$(rc draft put --review "$rid" --sections "$work/blocks.json")" 0
  # The one silent failure worth an assertion of its own: a `--sections` write that left the
  # draft at `drafting` would keep it out of the developer's inbox, and the review would wait
  # for an approval nobody had been asked for. `--file` marks it ready; so must this.
  status () { review-desk draft show --review "$1" --json | python3 -c "
import json, sys
print(json.load(sys.stdin)['draft']['status'])"; }
  ok "  and the draft is ready, not drafting"        "$(status "$rid")" ready
  review-desk draft put --review "$rid" --sections "$work/blocks.json" --drafting > /dev/null
  ok "  while --drafting keeps it out of the inbox"  "$(status "$rid")" drafting
  review-desk draft put --review "$rid" --sections "$work/blocks.json" > /dev/null
  ok "  and a plain write puts it back to ready"     "$(status "$rid")" ready
  review-desk draft show --review "$rid" --json \
    | python3 -c "
import json, sys
open('$work/real.md', 'w').write(json.load(sys.stdin)['draft']['body'])"
  ok "  and the body is the composition, to the byte" "$(cmp -s "$work/composed.md" "$work/real.md" \
      && echo same || echo differs)" same
  ok "  which the linter passes on the real body"    "$(linted "$work/real.md")" 0
  ok "  on every one of its checks"                  "$(checks)" all
  # One finding, two blocks: the heading is composed from the finding, so a second block would
  # repeat it. The refusal happens before anything is written, so the good blocks above survive
  # it -- which the decisions below depend on.
  python3 -c "
import json
blocks = json.load(open('$work/blocks.json'))
json.dump(blocks + [blocks[2]], open('$work/twice.json', 'w'))"
  ok "a second block about one finding is refused"   "$(rc draft put --review "$rid" --sections "$work/twice.json")" 1
  ok "  and the body it refused is still the first"  "$(review-desk draft show --review "$rid" --json \
      | python3 -c "
import json, sys
print(json.load(sys.stdin)['draft']['body'] == open('$work/composed.md').read())")" True

  printf '\n  cut, regrade and rewrite, for every posted finding\n'
  review-desk serve --port 0 --json > "$work/serve.out" 2>&1 &
  server=$!
  n=0
  while [ "$n" -lt 100 ] && ! grep -q '"address"' "$work/serve.out" 2>/dev/null; do
    n=$((n + 1)); sleep 0.1
  done
  api=$(python3 -c "
import json
print(json.load(open('$work/serve.out'))['serve']['url'].rstrip('/') + '/api/v1')" 2>/dev/null || echo "")
  ok "the server answers on 127.0.0.1"               "$(echo "$api" | grep -c '^http://127.0.0.1:')" 1
  decide () { python3 "$work/post.py" "$api/reviews/$1/findings/$2/decide" "$3" "$work/decided.json"; }
  # Order matters: a regrade then a rewrite then a cut, so each one is made on a block the one
  # before it left behind. Cutting first would leave nothing to regrade.
  for seq in 1 2; do
    ok "F$seq accepts regrade"                       "$(decide "$rid" "$seq" '{"decision":"regrade","severity":"blocker"}')" 200
    ok "F$seq accepts rewrite"                       "$(decide "$rid" "$seq" '{"decision":"rewrite","title":"a 500 posts as a success","text":"The response is returned unchecked."}')" 200
    ok "F$seq accepts cut"                           "$(decide "$rid" "$seq" '{"decision":"cut"}')" 200
  done
  ok "the regrade changed the heading, not a word of the text" "$(python3 -c "
import json
print(json.load(open('$work/decided.json'))['finding']['severity'])")" blocker

  printf '\n  the control: one block of markdown refuses all three\n'
  # Without this the three 200s above could be a property of the API rather than of the draft.
  other=$(review-desk review open --repo acme/portal --pr 413 --head "$base")
  echo '{"lens":"l","severity":"should","claim":"c","file":"a.php","line":1}' \
    | review-desk finding add --review "$other" --file - > "$work/otherseq"
  oseq=$(cat "$work/otherseq")
  printf 'One block of markdown, as a review was written before this.\n' \
    | review-desk draft put --review "$other" --file - > /dev/null
  for d in '{"decision":"cut"}' '{"decision":"regrade","severity":"blocker"}' \
           '{"decision":"rewrite","title":"t","text":"x"}'; do
    ok "a one-block draft refuses it"                "$(decide "$other" "$oseq" "$d")" 409
  done
  ok "  saying it was written as one block"          "$(grep -c 'written as one block of markdown rather than in parts' "$work/decided.json")" 1

  printf '\n  and nothing was written outside the temporary directory\n'
  ok "the store is the temporary one"                "$(test -f "$work/rd.db" && echo yes || echo no)" yes
  ok "REVIEW_DESK_DB was never unset"                "$REVIEW_DESK_DB" "$work/rd.db"
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  server=
fi

# =============================================================================================
printf '\nE. negative controls -- reverse each guard and require the test to fail\n'
# Each substitution is counted rather than assumed: a sed matching nothing would turn a control
# into a second copy of the test it controls.

sed 's/^| a line beginning with `-` | `"marker": "removed"`, `text` is the rest of the line | \*\*no\*\* |$/| a line beginning with `-` | `"marker": "removed"`, `text` is the rest of the line | yes |/' \
    "$brief" > "$work/numbered.md"
ok "the numbering reversal changed one line"         "$(python3 "$work/hunkspec.py" "$work/numbered.md" \
    | grep -c '"removed": true')" 1
# A removal that takes a number shifts every number after it, so the text against 16 is no longer
# line 16. This is the control for the one assertion that cannot agree with itself.
python3 "$work/hunkspec.py" "$work/numbered.md" > "$work/badspec.json"
git -C "$fix" diff -U3 "$base" "$head" -- jobs/DeliverWebhook.php \
  | python3 "$work/hunk.py" "$work/badspec.json" jobs/DeliverWebhook.php 16 > "$work/badhunk.json"
python3 "$work/numbers.py" "$work/badspec.json" "$work/badhunk.json" > "$work/badnumbered.txt"
ok "a numbered removal puts the wrong text on 16"    "$(test "$(sed -n 's/^16 //p' "$work/badnumbered.txt")" \
    = "$(git -C "$fix" show "$head:jobs/DeliverWebhook.php" | sed -n '16p')" && echo same || echo differs)" differs

sed 's/^git diff -U3 <base> <head> -- <path>$/git diff -U0 <base> <head> -- <path>/' \
    "$brief" > "$work/nocontext.md"
ok "the context reversal changed one line"           "$(grep -c 'git diff -U0' "$work/nocontext.md")" 1
ok "  and the reader reports the brief's own number" "$(ask "d['context']" "$work/nocontext.md")" 0
# -U0 is the honest failure of a hunk with no context: the page draws the change and nothing
# around it, which is what "the code around the flagged line" was asked for.
python3 "$work/hunkspec.py" "$work/nocontext.md" > "$work/nospec.json"
git -C "$fix" diff -U0 "$base" "$head" -- jobs/DeliverWebhook.php \
  | python3 "$work/hunk.py" "$work/nospec.json" jobs/DeliverWebhook.php 16 > "$work/nohunk.json"
ok "no context draws four lines, not ten"            "$(python3 -c "
import json
print(len(json.load(open('$work/nohunk.json'))['lines']))")" 4

# The defect DEV-891 is named after: a session that stored no hunk. `apply.py` with its hunk
# step reversed produces exactly that record, and the SAME expression section B passes has to
# fail on it.
sed 's/^        if built.returncode == 0:$/        if False:  # HUNK STEP REVERSED/' \
    "$work/apply.py" > "$work/nohunk.py"
ok "the hunk-step reversal changed one line"          "$(grep -c 'HUNK STEP REVERSED' "$work/nohunk.py")" 1
mkdir -p "$work/stripped"
python3 "$work/nohunk.py" "$work/spec.json" "$work/findings.json" "$fix" "$base" "$head" \
    "$work/stripped" > "$work/stripped.txt"
ok "  and left no finding in the change at all"       "$(grep -c ' in ' "$work/stripped.txt")" 0
ok "  so no document carries a hunk"                  "$(grep -l '"hunk"' "$work"/stripped/f*.json \
    2>/dev/null | wc -l | tr -d ' ')" 0
# With nothing reading as in-change, `incomplete` has nothing to count -- so the control that
# matters is the one that KEEPS the in-change answer and drops only the fields.
python3 - "$work/applied.txt" "$work/half.txt" <<'HALF'
import pathlib, sys
rows = pathlib.Path(sys.argv[1]).read_text().split("\n")
pathlib.Path(sys.argv[2]).write_text("\n".join(
    r.split(" in ")[0] + " in " if " in " in r else r for r in rows))
HALF
ok "the field reversal emptied the field list"        "$(grep -c ' in $' "$work/half.txt")" 2
ok "an in-change finding with no fields is caught"    "$(incomplete "$work/half.txt")" 2

# The composition, reversed: a glyph typed into the title composes twice.
python3 - "$work/blocks.json" "$work/glyph.json" <<'GLYPH'
import json, pathlib, sys
blocks = json.loads(pathlib.Path(sys.argv[1]).read_text())
blocks[2]["title"] = "🟠 Should · S1 · " + blocks[2]["title"]
pathlib.Path(sys.argv[2]).write_text(json.dumps(blocks))
GLYPH
python3 "$work/compose.py" "$work/glyph.json" "$work/severities.json" > "$work/glyphed.md"
ok "a typed heading composes the severity twice"      "$(grep -c '^### Should · F1 · 🟠 Should · S1 · ' "$work/glyphed.md")" 1
ok "  which is why the brief says to write the title only" "$(grep -c 'would compose to' "$brief")" 1

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
