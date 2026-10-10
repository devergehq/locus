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

# The status line, which moved out of the heading because a record composes the heading. Three of
# these four are controls: `sections.status_line` is a new check and its first two drafts were
# unfalsifiable, so each way of breaking it is pinned beside the pass.
printf '\n%s\n' "The status line a composed heading cannot carry"
fixture "[$(review 9001 principal "$work/sectioned.md")]" '[]'
ok "the house section carries tag and chip"     "$(run)$(rule sections.status_line)" "0no"
# A chip alone is matched by `**What** · `handle` ...`, the line below it in every well-formed
# finding, so deleting the status line outright has to fail. On the first draft it did not.
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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
