---
id: review-craft
name: Review Craft
description: How to read a change, how to write what you found, and how to write the PR description that carries the decision — eight review lenses, four severities, a visible budget, evidence folded or moved to a comment rather than dropped, and two linters that check the result. Hands over method; it does not perform a review. USE WHEN reviewing a PR, writing review comments, deciding a severity, judging whether a finding is worth raising, checking a drafted review before posting, or writing or shortening a PR description.
triggers:
  - review craft
  - review style
  - house style
  - review lenses
  - severity
  - how should I review
  - review this properly
  - review checklist
  - finding severity
  - pr description
  - pull request description
  - pr body
  - working notes
---

# Review craft

**This skill hands you a method. It does not review anything.**

Invoking it loads the craft and stops. It does not read your diff, open your PR, dispatch a
reviewer or post a comment. If you invoked it while reviewing something yourself, you should get
material to read and nothing else happening in the background — that is the intended behaviour,
not a failure to start.

Nothing here runs on its own. **When you want a review performed, ask for one in as many words**;
the `dispatcher` skill's `review` mode is the thing that claims a ticket, prepares a draft and
waits for a human to approve it before anything reaches GitHub.

> **Not to be confused with `/code-review`**, which Claude Code ships and which *performs* a
> review of your changes. This skill governs *how one reads* — the lenses to run, the vocabulary
> to grade with, and the shape the write-up takes. Reach for `/code-review` to get findings; reach
> for this to decide what counts as a finding and how to say it.

## What is here

| File | What it carries | Read it when |
|---|---|---|
| `lenses.md` | Eight lenses distilled from six months of review history, each with its evidential strength stated | **After** your own read of the diff, never before — they anchor you if they go first |
| `house-style.md` | The shape of a review: the one rule, the word budget, the four severities, `<details>` proofs, suggestion blocks, posting mechanics — **and the shape of a PR description**: the record/working split and the budget for a diff | Before you write anything down |
| `review_lint.py` | A deterministic, read-only check of a *posted* review against those rules | Before you tell anyone the review is ready |
| `pr_lint.py` | The same, for a *PR description* — its budget for that diff, headings, placeholders, rotting dates, and the comment its working notes link to | Before you tell anyone the PR is ready |
| `examples/synthetic-billing-review.md` | One worked review, end to end | When you want the shape rather than the rules |

## The short version

Everything below is argued in `house-style.md`. This is the part worth holding in your head.

- **The body tells the story; the findings live on the code; only proof is folded away.** Nothing
  is deleted — evidence is demoted, not dropped.
- **150 visible words in the body. Hard ceiling 400, whatever the size of the diff.** Table rows
  do not count. A specific — a path, a line range, a number — outranks the budget.
- **Four severities, never invented mid-review:** 🔴 Blocker, 🟠 Should, ⚪ Nit, 🔵 Question. A
  Question is not a finding in disguise; if you know it is wrong, say it is wrong.
- **At most three findings in the body.** Anything past three goes inline or into a fold.
- **Ask the Google question of every finding before it goes anywhere: will the author take an
  action?** If you cannot name one, it belongs in Suppressed with a reason, not in a thread. A
  finding that is true and that nobody acts on counts against you.
- **Numbers, not adjectives.** "1 in 81 draws", not "quite likely".
- **Say what you did not check.** The coverage gap is the most honest number in a review and the
  easiest one to bury.
- **Draw the workflow.** Where a finding describes a sequence, a state machine, a before/after
  ordering, a transaction boundary or a branching failure, put a small ```` ```mermaid ```` flowchart
  directly beneath its prose and point the prose at it. Supplement, never replace. One per workflow
  finding, a dozen nodes or fewer; a single predicate gets none. Any `classDef` with a `fill:` also
  sets `color:` — GitHub renders both themes. Free in a review; counted raw in a PR body.

### Writing the PR description

- **The description is the record of the decision**, and where the repo squash-merges with
  `PR_BODY`, it *is* the commit message. It carries five things and stops: why, what changed in
  shape, what a reviewer should look at, risks, and the references.
- **The working goes in a PR comment headed `## Working notes`** — the evidence census, the
  production queries and their output, the method, the alternatives you rejected, the transcript —
  complete and **verbatim**. The description links to it in one line. **Nothing is deleted; it
  moves.** If you are paraphrasing to make something fit, you are moving the wrong thing.
  **By heading, never by position:** the working moves out late, so its comment is the newest.
- **Budget the body at `min(4000, max(800, 12 × changed lines))` RAW characters** of the body as
  stored, excluding the Claude Code attribution footer. Raw, not "visible" — the squash copies
  markup, link targets and folded blocks verbatim. A specific — a path, a line range, a count, a
  date — outranks it.
- **Write to the repository's template if it has one.** Fill it, add to it freely — extra headings
  are never a fault. **Keep its shape and tighten the prose inside it**; that is what the budget
  is for. Cut a section only when it genuinely does not apply, and say so in a line rather than
  deleting the heading. A description *shorter* than its template is fine; one *unrecognisable*
  from it is not shorter, it is different. Don't invent your own shape where a convention exists.
- **Tell the linter what you know.** `--template PATH` says *this is the shape here* and makes
  drift an `ERROR`; a template the linter merely discovers is a `WARN`; a repo with no templates
  gets no finding at all. Severity follows the strength of the claim, not anyone's house policy.
- **The budget charges the narrative, not the references.** `Related`, `Security impact`,
  `Deployment`, `Rollback` and friends carry free up to 750 characters each. Never shave a ticket
  link, a security sentence or a rollback step to reach a count — they are not on the count. That
  default list is an intersection, not a closed set: pass `--exempt-section NAME` (repeatable) for
  the ones your template asks for that it does not name.
- **The budget is a target, not a gate.** `pr_lint.py` reports a `WARN` under **2×** and an
  `ERROR` only at 2× or more. Get *close* to the budget; do not shave a path, a count or a date
  to get *under* it. The census that forced the rule runs 3×–22×, so the red check still lands on
  the thing it was built for.
- **`<details>` does fold in a PR body.** An earlier version of this guide said otherwise and that
  was false. But a squash copies the raw tags into the commit message, so folds in the body are
  for reviewer aids you are content to keep in `git log`, never for the transcript.
- **Run `pr_lint.py` against the real PR before you call it ready.**

## Using the linters

```bash
python3 review_lint.py <PR> --repo OWNER/REPO         # a posted review
python3 pr_lint.py --repo OWNER/REPO --pr <PR>        # a PR description
python3 pr_lint.py draft.md --changed-lines 50        # a description before the PR exists
```

**Post the `## Working notes` comment before you shorten the body.** `pr_lint.py` errors when the
body links to working notes and no comment on the PR opens with that heading — so the intuitive
order (rewrite the body, then post the comment) leaves a live PR sitting in a failed-lint state
with a dead link in its description. Comment first, then edit the body to link it.

`pr_lint.py` will not guess a draft's diff size. `--changed-lines` is
`gh pr diff <n> --stat | tail -1`, or `additions + deletions` from the API. A budget checked
against a guessed denominator reports PASS about nothing.

Both exit **0** on pass (warnings included), **1** on errors, **2** when they could not run. Both
check **mechanics only**: a clean run means nothing is broken, not that anything is worth reading.

`review_lint.py` reads GitHub's *rendered* HTML rather than the markdown you sent, because the
failure mode it exists to catch is silent: a malformed body returns HTTP 201 and a perfectly
valid comment containing the wrong text.

`--repo` is **required and has no default** in both, deliberately. It carried one for as long as this
script lived beside a single repository, which made it a footgun the moment it did not: run
anywhere else and it lints a different repository's PR of the same number, then reports PASS.

**A review is not finished until `review_lint.py` passes, and a PR is not ready until
`pr_lint.py` passes.** Run it, fix what it names, run it again. A document nobody can fail is a
suggestion; this is the rule.

## On the worked example

`examples/synthetic-billing-review.md` reviews an invented codebase. The codebase is invented;
**every language behaviour the review turns on is real** and checkable in a Node REPL by someone
with no access to that codebase. That constraint is the point: a worked example whose central
mechanism cannot be verified teaches format and not judgement, which is the failure it exists to
demonstrate the opposite of.

It reproduces the finding craft of a real review. It predates the index shape `review_lint.py`
enforces — it carries one findings table rather than the Open/Resolved pair, and no `Method`
line. **Copy its judgement, not its index**: the index to copy is the template in
`house-style.md`, which is what the linter checks.

## Revision

**22 September 2026.** Workflow findings now carry a mermaid diagram beneath their prose, replacing
a cap of one diagram per review that the first live evidence ran against. `review_lint.py` excludes
mermaid from prose budgets and no longer checks the PR description at all — that stale check
failed any description with `<details>`, which this skill permits; `pr_lint.py` owns descriptions
and still counts a fence raw. Argued in `house-style.md` under "Draw the workflow".

**20 September 2026 (second change).** Template fidelity is now checked: `pr_lint.py` reports
which template a description is closest to and what it is missing. Severity follows provenance — a
template **supplied** via `--template` is an assertion and drift is an `ERROR`; one **discovered**
on a conventional path is an inference and drift is a `WARN`; a repository with no templates gets
no finding. The budget now charges only the narrative sections, with references, security impact
and deployment/rollback carrying free up to 750 characters each (p90 of 226 measured sections) and
`--exempt-section` to add your template's own. Both argued in `house-style.md`.

Also that day, `house-style.md` was **de-identified**. It had been written against one named
repository — linked PR numbers, its domain names, its ticket keys, and in one place its internal
governance record used to justify a default severity. Every measurement stayed; the provenance
went. A skill that installs anywhere must carry no repository in its head.

**20 September 2026.** The budget's `ERROR` threshold moved from 1.25× to **2×**, and is now
stated in the prose instead of living only in `pr_lint.py`. The formula, the constants and the
raw-character unit are unchanged — only the point where the tool stops advising and starts
blocking. Argued in `house-style.md` under "The budget is a target, and the linter now says so".

**18 September 2026.** This skill used to say PR descriptions were out of scope, partly on a false
claim — that a description cannot fold. It can. The section that replaced it, and the census of
eleven agent-authored PRs that forced the change, are in `house-style.md` under
"PR descriptions: the description is the record, the working is a comment".
`pr_lint.py` landed with it.
