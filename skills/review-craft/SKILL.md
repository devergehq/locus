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

**18 September 2026.** This skill used to say PR descriptions were out of scope, partly on a false
claim — that a description cannot fold. It can. The section that replaced it, and the census of
eleven agent-authored PRs that forced the change, are in `house-style.md` under
"PR descriptions: the description is the record, the working is a comment".
`pr_lint.py` landed with it.
