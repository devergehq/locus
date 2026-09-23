# Mode: implement (`Agent - Todo`)

Finish line: **a clean PR marked ready for review**, after an independent self-review has come
back with no blockers and CI is green. Not a draft, not "mostly done".

## Steps

0. **Does this ticket have sub-issues?** Check before anything else (`linear_get_issue` on your
   key, in the workspace named in your dispatch block). If it has children, you are not
   implementing this ticket — the work is in the children. **Read `stack.v2.md`, beside this
   file, and follow it instead of the steps below**, which describe a single-ticket pass. A parent implemented as one branch
   collapses the decomposition it was given and buries the risky change inside a large diff.
   If it has no children, carry on from step 1.

1. **Move the ticket:** `D label <KEY> implementing --state "In Progress"`.
2. **Understand before touching code.** Ticket, comments, parent, linked docs, and the code it
   names. Read the repo's CLAUDE.md and follow it — its testing, formatting, static analysis, PR
   and branch rules are the standard. If the requirements don't pin down a business rule, use the
   Needs Input protocol now, before building.
3. **Branch** per the repo's convention — its CLAUDE.md names the pattern and the branch to cut
   from; do not assume `main`. If that branch already exists on the remote, a previous session
   started it: check it out and continue.
4. **Build it with tests.** Tests that fail without the change and pass with it. Run the relevant
   tests, the formatter and static analysis locally before every push.
5. **Push early and open a draft PR**, written from the repo's own PR templates and rules (title
   `<KEY>: <what changes, in plain words>`). Keep the sections those templates give you, and fill
   them following `review-craft`'s **"PR descriptions"** section:
   - **The description is the record of the decision.** Why, what changed in shape, what a
     reviewer should look at, risks, references — and it stops there. Where the repo
     squash-merges with the PR body as the commit message, that *is* the commit message.
   - **The supporting detail goes in a PR comment whose first line is `## Working notes`**, complete and
     **verbatim** — the evidence census, the queries and their output, the checks you ran, and the
     options you weighed with the reason you chose one. The description links to it in one line. **Nothing is deleted;
     it moves.** If you find yourself paraphrasing to make something fit, you are moving the
     wrong thing: a budget obeyed by paraphrasing is the failure this rule was written after.
     The comment is identified **by that heading, never by its position** — you move the notes
     out late, so it is the newest comment, not the first.
   - **Budget the body at `min(4000, max(800, 12 × changed lines))` RAW characters** of the body
     as stored (the Claude Code attribution footer aside), where changed lines is
     `additions + deletions`. Raw, not "visible": the squash copies markup, link targets and
     folded blocks verbatim. A path, a line range, a count or a date outranks the budget.
   - `<details>` **does** render in a PR body, but a squash copies the raw tags into the commit
     message. Fold only reviewer aids you are content to see in `git log`; never the transcript.
   - **Run the linter before you call the PR ready**, and paste its output when you report:
     `python3 ~/.locus/skills/review-craft/pr_lint.py --repo OWNER/REPO --pr <n>`. Exit 1 means
     fix it and run it again.

   Put the link on the ticket with `D comment`.
6. **Independent self-review, posted on the PR.** It's visible there, like Greptile's, so people
   can see a review happened and compare the two.
   - Dispatch a reviewer (see "Independent help") that works only from the ticket, the PR description and
     the diff — the same inputs a fresh reviewer would have. Ask for a verdict line, problem fit, findings (Blocker / Should / Nit / Question ·
     `path` · `line` · the claim in one line · evidence), what it did not verify, **and a
     `Checked, not flagged` list** — issues it looked at and deliberately left out, with a reason each. Ask for that
     list explicitly: without it the reader cannot tell a clean area from an unchecked one.
   - **Round 1: post its findings word for word as one GitHub review**, event `COMMENT` only. Never
     APPROVE or REQUEST_CHANGES. Don't soften, merge or drop any finding; your responses go in the
     threads, not in its text.
     ```
     gh api repos/OWNER/REPO/pulls/N/reviews -X POST --input review.json
     {"commit_id": "<head sha>", "event": "COMMENT", "body": "<body>",
      "comments": [{"path": "...", "line": 42, "side": "RIGHT", "body": "<finding>\n\n<sub>agent:<KEY>/implement</sub>"}]}
     ```
     If your session's auto-mode classifier refuses that call, `gh pr review <n> --comment --body-file <f>`
     posts the body and is usually allowed. **It cannot carry inline comments**, though, and the findings
     belong on the line — so if you have to fall back, say so when you report, and say that the
     inline comments are missing rather than quietly dropping them. The fix is a permission rule, not
     a smaller review.
     The body follows the `review-craft` skill — visible-word budget, the four severities,
     sentence-case headings, `<details>` around every proof, a suggestion block for anything
     mechanical. That skill's worked example shows the shape. Tell the
     reviewer that style up front, so its report arrives in it rather than needing a rewrite. Every inline comment ends with the `agent:<KEY>/implement` marker so your
     watcher skips it. Findings with no line to anchor to go in the body.
   - Fix the blockers and should-fixes. Reply **in each inline thread** with the commit that fixed
     it, or one line on why you declined it (signed with the same marker).
   - **Rounds 2–3:** the reviewer re-checks the new head. Post **one** signed PR comment per round:
     what was fixed, and any new findings. New findings get inline comments; nothing else is re-posted.
     Still blocked after round 3 → Needs Input with the specific disagreement.
   - Discard the reviewer session once you have its report.
6b. **Lint it.** `review-craft`'s `review_lint.py <PR> --repo OWNER/REPO` must pass before you
   call the review done. Fix what it names — it checks arithmetic you cannot check by eye — and paste the final
   output in your report.
7. **CI green.** `gh pr checks <n> --watch`. Fix real failures. A flake gets one re-run, with a
   note saying so.
8. **Ready it.** `gh pr ready <n>` → `D label <KEY> done --state "In Review"` →
   `D ledger put <KEY> status=done pr_url=<url>` → one ticket comment: the PR link, what changed,
   how you verified it, **what you did not verify**, and a two-line self-review summary → message
   the Dispatcher. Link the self-review in that comment.

Do not request reviewers — your principal decides who reviews.

**If a coordinator dispatched you** (you are a child of a parent ticket), three things change:
report to the coordinator's reply address rather than the Dispatcher's; use the **base branch and
PR base it gave you** instead of the repo default in step 3; and remember you are at depth
2, so your reviewer sits at depth 3 and **cannot dispatch anything of its own**. Ask it for a
report, not for work it would need to delegate.

## After you're done

Stay alive with your watcher running until your principal discards you.

- `pr_review` / `pr_comment` from a human asking for a change: make it, push, and reply once on
  GitHub, signed — start the reply with `🤖 agent:<KEY>/implement` — saying what changed.
- A judgement call, or a comment you disagree with: don't argue on GitHub. Needs Input on the
  ticket, quoting the comment, and let your principal decide.
- `pr_state` merged: `D ledger put <KEY> status=done --note "merged"` and tell the Dispatcher.
