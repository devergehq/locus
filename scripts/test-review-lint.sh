#!/bin/sh
# Unit tests for skills/review-craft/review_lint.py.
#
# review_lint.py only ever reads GitHub, so these run it against a fake `gh` on
# PATH that answers four API paths from fixture files. The fake is kept to a
# path-to-file lookup on purpose: anything cleverer is its own bug surface.
#
# What is pinned: which review gets linted (an agent review, a principal's
# markerless one, or exactly --review-id), that a principal's review is not
# failed for lacking the agent header, the GitHub-width layout checks and the
# four-column budget on a review body's tables.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lint="$root/skills/review-craft/review_lint.py"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

cat > "$work/bin/gh" <<'EOF'
#!/bin/sh
path=
for a in "$@"; do case "$a" in api|-H|--paginate|Accept:*) ;; *) path=$a ;; esac; done
case "$path" in
  user) cat "$FIX/user.json" ;;
  */reviews) cat "$FIX/reviews.json" ;;
  */comments*) cat "$FIX/comments.json" ;;
  *) echo "fake gh: unexpected $path" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

pass=0
fail=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-54s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-54s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

# fixture <reviews-json> <comments-json>: the PR as GitHub would return it
fixture () {
  FIX="$work/fix"; rm -rf "$FIX"; mkdir "$FIX"; export FIX
  echo '{"login":"principal"}' > "$FIX/user.json"
  printf '%s' "$1" > "$FIX/reviews.json"
  printf '%s' "$2" > "$FIX/comments.json"
}
# run [args] -> exit code; output in $work/out
run () { set +e; PATH="$work/bin:$PATH" python3 "$lint" 1 --repo o/r "$@" >"$work/out" 2>&1; c=$?; set -e; echo "$c"; }
says () { grep -q -- "$1" "$work/out" && echo yes || echo no; }
# rule <name> -> yes/no: did the last run FAIL or WARN on this rule?
rule () { grep -qE "^(FAIL|WARN)  $1( |\$)" "$work/out" && echo yes || echo no; }
ran () { grep -qE "^(PASS|FAIL|WARN)  $1( |\$)" "$work/out" && echo yes || echo no; }
# review <id> <login> <body-file> -> one review object
review () { python3 -c 'import json,sys; print(json.dumps({"id":int(sys.argv[1]),"user":{"login":sys.argv[2]},"body":open(sys.argv[3]).read(),"submitted_at":"2026-09-22T00:00:00Z"}))' "$@"; }

# ---- bodies

# A principal's review in the sectioned layout: no header, no marker, the finding
# under its own heading with its diagram beneath it.
cat > "$work/sectioned.md" <<'EOF'
**1 Should · 1 open.** A correction that throws after the reopen strands the invoice OPEN.

**Method** · read the diff and its callers · ran the feature tests · **0 suppressed** · **0 not verified** · **1 area not reviewed** (the migration) — Suppressed: none.

### Problem fit
The PR moves the reopen behind a preflight, which is the right shape: refusals now happen before anything changes at the payer.

### Should · F1 · a correction that throws after the reopen strands the invoice OPEN

**in diff** · `Open — needs a decision`

The preflight refuses the known bad inputs before the reopen, but the real correction still runs after it, in [`ProcessInvoiceUpdatesAction.php:212`](https://github.com/o/r/blob/abc/app/Http/Actions/Invoices/ProcessInvoiceUpdatesAction.php#L212). If it throws for a reason the dry run missed, the invoice is left OPEN — the red path below. I'd wrap the reopen and the correction in one compensating step.

```mermaid
flowchart TD
    A["preflight"] -->|"passes"| R["reopen"]
    R --> C{"correction"}
    C -->|"throws"| STR["stranded OPEN"]
```
EOF

# The layout that failed live: prose in a cell, a full path in another.
cat > "$work/squashed.md" <<'EOF'
**1 Should · 1 open.** A correction that throws after the reopen strands the invoice OPEN.

**Method** · read the diff · **0 suppressed** · **1 area not reviewed** — Suppressed: none.

### Problem fit
Right shape.

### Open — needs a decision
| | Where | Finding | Disposition |
|---|---|---|---|
| 🟠 Should | [`app/Http/Actions/Invoices/ProcessInvoiceUpdatesAction.php:212`](https://github.com/o/r/pull/1#discussion_r1) | The preflight refuses the known bad inputs before the reopen, but the real correction still runs after it, so a throw after the reopen at the payer leaves the invoice OPEN with nothing to put it back | Open |

### Diagrams
```mermaid
flowchart TD
    A --> B
```
EOF

# A five-column index: every cell short, no long token — the columns alone are the defect.
cat > "$work/fivecol.md" <<'EOF'
**1 Should · 1 open.** A correction that throws after the reopen strands the invoice OPEN.

**Method** · read the diff · **0 suppressed** · **1 area not reviewed** — Suppressed: none.

### Problem fit
Right shape.

### Open — needs a decision
| | Id | Where | Finding | Disposition |
|---|---|---|---|---|
| 🟠 Should | S1 | [`Process…Action.php:212`](https://github.com/o/r/pull/1#discussion_r1) | A throw after the reopen strands the invoice OPEN | Open |
EOF

# The house index, verbatim in shape: an agent review with one thread.
cat > "$work/agent.md" <<'EOF'
🤖 **Agent review · round 1** · `agent:DEV-1/review`
Reviewer: engineer · claude · reviewed abc1234

**1 Should · 1 open.** The retry budget is shared across flags, so one noisy flag starves the others.

**Method** · read the diff and the command's callers · ran the unit tests · **0 suppressed** · **0 not verified** · **1 area not reviewed** — detail at the end

### Problem fit
The change adds per-flag reconciliation, which is the right shape for a queue that used to drain in one pass; the shared retry budget is the one place it still behaves as a single pass.

### Open — needs a decision
| | Where | Finding | Disposition |
|---|---|---|---|
| 🟠 Should · in diff | [`ReconcilePlansCommand.ts:88`](https://github.com/o/r/pull/1#discussion_r10) | Retry budget is shared across flags | Open |

<details><summary>How this review was made</summary>

Suppressed (0). Not verified: none. Not reviewed: the migration.
</details>
EOF

cat > "$work/thread.md" <<'EOF'
> [!WARNING]
> **Should · in diff** — the retry budget is shared across flags · `Open`
>
> **What** · `ReconcilePlansCommand.ts:88` keeps one counter for every flag.
> **Why it matters** · A flag failing 5 times exhausts the budget for the other 11.
> **What I'd do** · Key the counter by flag.

<sub>agent:DEV-1/review</sub>
EOF

thread='{"id":10,"user":{"login":"principal"},"pull_request_review_id":100,"body":'"$(python3 -c 'import json;print(json.dumps(open("'"$work/thread.md"'").read()))')"'}'

echo "Which review is linted"
fixture "[$(review 5 principal "$work/sectioned.md")]" '[]'
ok "a markerless review is linted, not skipped" "$(run)" 0
ok "and the output names it as the principal's" "$(says 'review 5 by principal · principal review, no marker')" yes
ok "the agent header is not demanded of it"     "$(ran index.header)" no
ok "nor the agent marker"                       "$(ran index.marker)" no

fixture "[$(review 5 principal "$work/sectioned.md"), $(review 6 principal "$work/squashed.md")]" '[]'
run >/dev/null
ok "with two, the latest is linted, not the longest" "$(says 'review 6 by')" yes

fixture "[$(review 7 colleague "$work/sectioned.md")]" '[]'
ok "nobody's review but a colleague's exits 2"  "$(run)" 2
ok "and says how to lint theirs"                "$(says 'review-id')" yes
ok "--review-id lints a colleague's on request" "$(run --review-id 7)" 0
ok "and names its author"                       "$(says 'review 7 by colleague')" yes
ok "--review-id not on the PR exits 2"          "$(run --review-id 99)" 2

echo "An agent review lints as before"
fixture "[$(review 100 principal "$work/agent.md"), $(review 101 principal "$work/sectioned.md")]" "[$thread]"
ok "the house index passes"                     "$(run)" 0
ok "a marked review outranks a later markerless one" "$(says 'review 100 by principal · agent review')" yes
ok "and the agent header is checked"            "$(ran index.header)" yes
ok "the house table trips no layout check"      "$(rule 'layout\.[a-z_]+')" no

echo "GitHub-width layout"
fixture "[$(review 6 principal "$work/squashed.md")]" '[]'
ok "the squashed table fails"                   "$(run)" 1
ok "on its prose cell"                          "$(rule layout.table_prose)" yes
ok "on its full path"                           "$(rule layout.table_tokens)" yes
ok "a link target is not a token: only text is" "$(says 'discussion_r1')" no
ok "a diagram under 'Diagrams' warns"           "$(rule layout.diagram_homed)" yes
ok "and the warning is a WARN, not a FAIL"      "$(grep -c '^FAIL  layout.diagram_homed' "$work/out" || true)" 0

fixture "[$(review 5 principal "$work/sectioned.md")]" '[]'
run >/dev/null
ok "one-sentence claims in the worked example pass" "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
print(r.layout(open('$root/skills/review-craft/examples/synthetic-billing-review.md').read()))")" "([], [])"
ok "a diagram under its finding is homed"       "$(rule layout.diagram_homed)" no
ok "a full path in prose is fine"               "$(rule layout.table_tokens)" no
ok "the section is budgeted as a thread"        "$(ran sections.budget)" yes
ok "and the verdict counts sections"            "$(ran verdict.open_count)" yes

fixture "[$(review 8 principal "$work/fivecol.md")]" '[]'
ok "a five-column index fails"                  "$(run)" 1
ok "on its column count"                        "$(rule layout.table_columns)" yes
ok "and the budget is named"                    "$(says 'over 4 columns')" yes
ok "and the count that broke it"                "$(says 'found 5')" yes
ok "not on a cell: every cell is short"         "$(rule layout.table_prose)" no
ok "nor on a token"                             "$(rule layout.table_tokens)" no
ok "the delimiter does not split one table in two" "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
print(r.table_columns(open('$work/fivecol.md').read()))")" "[5]"
ok "the house four-column index passes"          "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
print(r.table_columns(open('$work/agent.md').read()))")" "[4]"
ok "a wide table in a thread is not the body's" "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
b = open('$work/agent.md').read()
print([n for n in r.table_columns(b) if n > r.BODY_COLS])")" "[]"

python3 -c "print('### Should · F1 · long\n\n**in diff** · \`Open\`\n\n' + 'word ' * 200)" \
    > "$work/longsec.md"
{ sed -n '1,7p' "$work/sectioned.md"; cat "$work/longsec.md"; } > "$work/over.md"
fixture "[$(review 5 principal "$work/over.md")]" '[]'
run >/dev/null
ok "a section over a thread's budget fails"     "$(rule sections.budget)" yes
ok "but not the index word count"               "$(rule index.length)" no

# The status line, which moved out of the heading because a record composes the heading. Most of
# what follows is controls rather than tests: `sections.status_line` is a new check and its first
# two drafts were unfalsifiable, so each way of breaking it is pinned beside the pass.
printf '\n%s\n' "The status line a composed heading cannot carry"
fixture "[$(review 9001 principal "$work/sectioned.md")]" '[]'
ok "the house section carries tag and chip"     "$(run)$(rule sections.status_line)" "0no"
# A chip alone is matched by the `**What** ·` line below it in every well-formed finding, so
# deleting the status line outright has to fail. On the first draft of the check it did not.
sed '/^\*\*in diff\*\* · `Open — needs a decision`$/d' "$work/sectioned.md" > "$work/nostatus.md"
ok "the status-line reversal removed one line"  "$(grep -c 'in diff' "$work/nostatus.md")" 0
fixture "[$(review 9001 principal "$work/nostatus.md")]" '[]'
ok "a section with no status line fails"        "$(run)$(rule sections.status_line)" "1yes"
sed 's/^\*\*in diff\*\* · `Open — needs a decision`$/**in diff** · Open/' "$work/sectioned.md" \
    > "$work/nochip.md"
fixture "[$(review 9001 principal "$work/nochip.md")]" '[]'
ok "a disposition that is not a code span fails" "$(run)$(rule sections.status_line)" "1yes"
sed 's/^\*\*in diff\*\* · `Open — needs a decision`$/`Open — needs a decision`/' \
    "$work/sectioned.md" > "$work/notag.md"
fixture "[$(review 9001 principal "$work/notag.md")]" '[]'
ok "a chip with no in-diff tag fails"           "$(run)$(rule sections.status_line)" "1yes"
# The exemption, which is house style rather than laxity: a nit takes the lighter shape.
python3 - "$work/sectioned.md" "$work/nitsection.md" <<'NIT'
import pathlib, sys
doc = pathlib.Path(sys.argv[1]).read_text()
doc = doc.replace("### Should · F1 ·", "### Nit · F1 ·")
doc = doc.replace("**in diff** · `Open — needs a decision`\n\n", "")
doc = doc.replace("**1 Should · 1 open.**", "**1 Nit · 1 open.**")
pathlib.Path(sys.argv[2]).write_text(doc)
NIT
fixture "[$(review 9001 principal "$work/nitsection.md")]" '[]'
ok "a nit section is exempt, as on a thread"    "$(run)$(rule sections.status_line)" "0no"
# And the severity a section's check reads comes from the HEADING, where the word is not bold.
# Reading it with SEV (which requires bold) returned "" for every section and exempted them all.
ok "a section severity is read without bold"    "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
head = '### Should · F1 · a title'
print(bool(r.HEAD_SEV.search(head)), bool(r.SEV.search(head)))")" "True False"


echo "The shape Review Desk composes (DEV-929)"

# The body and the four threads below are not written by hand: they are what
# `review-desk draft handover --review <id> --json` printed for an approved draft of six
# findings, four of them carrying a line inside the diff, built on review-desk 13a78ee. That
# is the shape every posted review now has, so it is the shape this linter has to read.
#
# What it caught: `verdict.{blocker,should,nit}_split` added every section heading to the
# table's rows, and in this shape a finding with nowhere to anchor has BOTH an index row and
# a section. The two unanchored findings here were each counted twice, so a correct verdict
# line failed twice over - "says 2 Should, rows hold 3" and "says 2 Nits, rows hold 3".
# Before `unrowed`, this fixture scored 24/27 and exited 1.
cat > "$work/composed.md" <<'EOF'
**2 Blockers · 2 Should · 2 Nits — 6 open.** The export path ships columns the policy forbids.

**Method** · read the export path and its callers · ran the suite · **0 suppressed** · **0 not verified** · **2 areas not reviewed** — detail at the end

### Problem fit
The change puts a column policy in front of the export path. That is the right shape for the problem.

### Open — needs a decision

| | Where | Finding | Status |
| -- | -- | -- | -- |
| 🔴 Blocker · F1 | [`ColumnPolicy.php:52`](https://github.com/acme/portal/blob/d41c8e2abc/app/Reporting/ColumnPolicy.php#L52) | The column policy is skipped when the definition names no columns | Open · on the code |
| 🔴 Blocker · F2 | [`DeliverWebhook.php:57`](https://github.com/acme/portal/blob/d41c8e2abc/jobs/DeliverWebhook.php#L57) | A retried delivery carries no idempotency key | Open · on the code |
| 🟠 Should · F3 | [`Writer.php:31`](https://github.com/acme/portal/blob/d41c8e2abc/app/Export/Writer.php#L31) | The export status is not checked before the file is written | Open · on the code |
| 🟠 Should · F5 | [the pull request](https://github.com/acme/portal/pull/514) | The description does not say what happens to a skipped export | Open · in the body |
| ⚪ Nit · F4 | [`WriterTest.php:12`](https://github.com/acme/portal/blob/d41c8e2abc/tests/WriterTest.php#L12) | The test name says what it does, not what it proves | Open · on the code |
| ⚪ Nit · F6 | [the pull request](https://github.com/acme/portal/pull/514) | The changelog entry is missing | Open · in the body |

### Should · F5 · The description does not say what happens to a skipped export

**pre-existing** · `Open`

**What** · the description says nothing about a skipped export.

**Why it matters** · a reader cannot tell whether skipping is intended.

**What I'd do** · say what a skipped export does.

### Nit · F6 · The changelog entry is missing

**pre-existing** · `Open`
The changelog says nothing about the policy.

<details><summary>How this review was made</summary>

Suppressed: none. Not verified: none. Not reviewed: the migration, the seed data.
</details>
EOF
cat > "$work/composed-t1.md" <<'EOF'
> [!CAUTION]
> **Blocker · F1** — The column policy is skipped when the definition names no columns · `Open`
>
> **in diff** · `Open — needs a decision`
>
> **What** · the guard returns before the policy is read.
>
> **Why it matters** · an export ships columns the policy forbids.
>
> **What I'd do** · treat a definition naming no columns as deny.
EOF
cat > "$work/composed-t2.md" <<'EOF'
> [!CAUTION]
> **Blocker · F2** — A retried delivery carries no idempotency key · `Open`
>
> **in diff** · `Open — needs a decision`
>
> **What** · the guard returns before the policy is read.
>
> **Why it matters** · an export ships columns the policy forbids.
>
> **What I'd do** · treat a definition naming no columns as deny.
EOF
cat > "$work/composed-t3.md" <<'EOF'
> [!WARNING]
> **Should · F3** — The export status is not checked before the file is written · `Open`
>
> **in diff** · `Open — needs a decision`
>
> **What** · the guard returns before the policy is read.
>
> **Why it matters** · an export ships columns the policy forbids.
>
> **What I'd do** · treat a definition naming no columns as deny.
EOF
cat > "$work/composed-t4.md" <<'EOF'
⚪ **Nit · F4** — The test name says what it does, not what it proves · `Open`
**in diff** · `Open`
The name says what the test does, not what it proves.
EOF
# A thread comment as GitHub returns it, anchored where the hand-over said it sits.
anchored_at () { python3 -c 'import json,sys; print(json.dumps({"id":int(sys.argv[1]),"user":{"login":"principal"},"pull_request_review_id":900,"path":sys.argv[2],"line":int(sys.argv[3]),"body":open(sys.argv[4]).read()}))' "$@"; }
composed_threads="$(anchored_at 1000 app/Reporting/ColumnPolicy.php 52 "$work/composed-t1.md"), $(anchored_at 1001 jobs/DeliverWebhook.php 57 "$work/composed-t2.md"), $(anchored_at 1002 app/Export/Writer.php 31 "$work/composed-t3.md"), $(anchored_at 1003 tests/WriterTest.php 12 "$work/composed-t4.md")"

# The shape before Review Desk composed anything: sections and no index at all. A section is
# the only record of its finding there, so it still counts -- the fix narrows what is added to
# the rows, and must not stop adding it. The second assertion is the control: with the count
# wrong on the same body, the check still fails, so the first is not passing vacuously.
fixture "[$(review 899 principal "$work/sectioned.md")]" '[]'
run >/dev/null
ok "with no index, a section still counts"      "$(rule verdict.should_split)" no
ok "  and the check is live, not vacuous"       "$(ran verdict.should_split)" yes
sed 's/^\*\*1 Should · 1 open\.\*\*/**2 Should · 1 open.**/' "$work/sectioned.md" > "$work/miscount.md"
fixture "[$(review 899 principal "$work/miscount.md")]" '[]'
run >/dev/null
ok "  a wrong count on that body still fails"   "$(rule verdict.should_split)" yes
ok "  naming what the body holds"               "$(says 'says 2 Should, rows hold 1')" yes

fixture "[$(review 900 principal "$work/composed.md")]" "[$composed_threads]"
ok "the composed body passes whole"             "$(run)" 0
ok "a finding with a row and a section counts once" "$(rule verdict.should_split)" no
ok "and so does an unanchored nit"              "$(rule verdict.nit_split)" no
ok "the anchored findings still count"           "$(says 'says 2 Blockers, rows hold 2')" yes
ok "six rows, two sections, four threads"       "$(says '6 open rows, 0 resolved rows, 2 body sections')" yes

# The pairing itself, so that a change to the heading's or the row's shape fails here rather
# than in a verdict count nobody can read.
ok "a section whose finding has a row is dropped" "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
row = '| \U0001f7e0 Should \u00b7 F5 | [x](http://y) | the description says nothing | Open |'
print(r.unrowed(['### Should \u00b7 F5 \u00b7 the description says nothing'], [row]))")" "[]"
ok "a section whose finding has none is kept"   "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
row = '| \U0001f7e0 Should \u00b7 F5 | [x](http://y) | the description says nothing | Open |'
print(len(r.unrowed(['### Should \u00b7 F9 \u00b7 something else entirely'], [row])))")" "1"
ok "with no number, the title pairs it"         "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
row = '| \U0001f7e0 Should | [x](http://y) | the description says nothing about it | Open |'
print(r.unrowed(['### Should \u00b7 the description says nothing about it'], [row]))")" "[]"

echo "The marker a session joins a comment to its finding by (DEV-929)"

# Two findings on one line is ordinary -- a Should about what a line does, a Nit about what it
# is called -- so `path` and `line` cannot tell their threads apart. Review Desk is ADDING
# `<!-- review-desk:F<seq> -->` to the end of every composed thread to be joined on instead:
# agreed for DEV-929 and not yet in their branch at 598c4df, which is why the fixture below
# carries the marker rather than being harvested from the binary like the composed body above.
# The linter's part of that bargain is not to CHARGE it: a comment renders as nothing, and
# `prose` measures what a reader reads. Measured before the change: each marker spent ~24
# characters of a 700-character single-finding budget.
ok "an HTML comment is not charged as prose"    "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
body = '> **Should · F3** — a title · \`Open\`\n>\n> **What** · x.\n\n<!-- review-desk:F3 -->'
print('review-desk' in r.prose(body))")" "False"
ok "  and the prose around it survives"         "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
body = '> **Should · F3** — a title · \`Open\`\n>\n> **What** · x.\n\n<!-- review-desk:F3 -->'
print(r.prose(body))")" "Should · F3 — a title · Open What · x."
ok "  a multi-line comment too"                 "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import review_lint as r
print(r.prose('a <!-- one\ntwo --> b'))")" "a b"

# Two threads on one line, each marked, and the body's index row count is still right.
cat > "$work/sameline.md" <<'EOF'
**1 Should · 1 Nit — 2 open.** The response is returned without checking its status.

**Method** · read `DeliverWebhook` and its callers · ran the job's tests · **0 suppressed** · **1 area not reviewed** — Suppressed: none.

### Problem fit
Keeping the response is the right shape; the caller needs it to decide whether to retry.

### Open — needs a decision
| | Where | Finding | Status |
| -- | -- | -- | -- |
| 🟠 Should · F1 | [`DeliverWebhook.php:16`](https://github.com/o/r/blob/abc/jobs/DeliverWebhook.php#L16) | the response is returned without checking its status | Open · on the code |
| ⚪ Nit · F2 | [`DeliverWebhook.php:16`](https://github.com/o/r/blob/abc/jobs/DeliverWebhook.php#L16) | `$response` says its type, not its role | Open · on the code |
EOF
cat > "$work/sameline-t1.md" <<'EOF'
> [!WARNING]
> **Should · F1** — the response is returned without checking its status · `Open`
>
> **in diff** · `Open — needs a decision`
>
> **What** · `handle` returns the response without reading its status.
>
> **Why it matters** · a 500 is recorded as a delivery.
>
> **What I'd do** · throw on a non-2xx before returning.

<!-- review-desk:F1 -->
EOF
cat > "$work/sameline-t2.md" <<'EOF'
⚪ **Nit · F2** — `$response` says its type, not its role · `Open`
**in diff** · `Open`
The name says what it holds, not what it is for.

<!-- review-desk:F2 -->
EOF
fixture "[$(review 910 principal "$work/sameline.md")]" \
  "[$(anchored_at 8001 jobs/DeliverWebhook.php 16 "$work/sameline-t1.md"), \
    $(anchored_at 8002 jobs/DeliverWebhook.php 16 "$work/sameline-t2.md")]"
ok "two threads on one line lint clean"         "$(run)" 0
ok "  and the marker is in the body GitHub returns" "$(python3 -c "
import json
threads = json.load(open('$work/fix/comments.json'))
print(sum('<!-- review-desk:F' in t['body'] for t in threads))")" 2
ok "  one marker each, so the join is unique"   "$(python3 -c "
import json, re
threads = json.load(open('$work/fix/comments.json'))
keys = [re.findall(r'<!-- review-desk:(F\d+) -->', t['body']) for t in threads]
print(sorted(k[0] for k in keys if len(k) == 1))")" "['F1', 'F2']"
# `set([...])` rather than a set comprehension: the harness runs under `sh`, and a `{` with a
# comma in it is brace expansion -- the comprehension was expanded into two broken variants that
# each raised a SyntaxError, and the assertion then compared empty to empty and "passed".
ok "  which path and line could not be"         "$(python3 -c "
import json
threads = json.load(open('$work/fix/comments.json'))
print(len(set([(t['path'], t['line']) for t in threads])), 'key for', len(threads), 'threads')")" "1 key for 2 threads"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
