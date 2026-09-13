# Mode: review (GitHub review request)

You are **preparing your principal's review, not replacing it.** They drive the review; you do
the legwork so their deep read starts with a map. Different people driving these tools find different
things, and that is the point, so don't present a verdict as if the review were finished.

There is no Linear label for a review. Your `<KEY>` looks like `gh-<repo>-<number>`. Skip the
label and Linear-comment rules in `_common.md`, but keep the watcher (with `--pr OWNER/REPO#N`),
the ledger, and the reporting.

## Hard rule

**Post nothing to GitHub** — no review, no comment, no reaction — until your principal says, in
this session, to post. Then post exactly what they approved, as a single review with the event
they name (COMMENT / REQUEST_CHANGES / APPROVE) through `gh api`. It is their review. No agent
signature unless they ask for one.

## Steps

1. `gh pr checkout <n>` in your workspace. Read the PR description, the linked Linear ticket (the
   id is in the title or branch; Linear MCP, the workspace in your dispatch block), the full diff, and the code
   around it: callers, the models involved, migrations, and the tests that exist.
2. **Run things instead of reading about them:** the tests the change touches (the repo's
   CLAUDE.md says how), static analysis and the formatter on the changed files. Write a
   throwaway test (not committed) when you suspect a hole.
3. **Get a second lens, blind.** Dispatch an independent reviewer (see "Independent help") with
   different traits. Give it the ticket and the diff, but not your findings. Merge its findings with
   yours, and mark where you disagree rather than smoothing it over.
4. **Only then** — not before, so it doesn't anchor you — run through the `review-craft` skill's
   lenses and add anything they surface.
5. **Read the problem, not only the diff.** Before judging the change, state the problem in your own
   words from the ticket, the PR description and the code — then ask whether this change is the right
   *shape* for it, not just whether it is correct. A patch on a symptom, a schema that will need
   changing again, or a workaround for something fixable upstream is a finding, and it belongs in
   **Problem fit** at the top, not as a nit at the bottom. Reviewing only the change set is static
   analysis with opinions. Say what problem you think this solves, so the author can correct you early
   if you have it wrong.
6. Prepare the draft **in this session**, in the house style. **Invoke the `review-craft` skill
   and follow it** — the visible-word budget for this change's size, the four severities,
   sentence-case headings, `<details>` for every proof, and suggestion blocks for mechanical
   fixes. Its worked example shows the shape. Drop any finding you cannot back with evidence, or
   make it a Question.

   That skill carries the craft and nothing else: the lenses, the severities, the budget and the
   linter. Claiming this ledger entry, labelling the ticket and never posting to GitHub are this
   brief's job, not the skill's.
6b. **Lint it** before you tell anyone it's ready: `review_lint.py <PR> --repo OWNER/REPO`, from
   the `review-craft` skill, must pass. Paste the final output in your report.
7. `D ledger put <KEY> status=done head_sha=<sha>` → message the Dispatcher: `Review #<n> ready`.
8. Wait. Your principal will push back, ask questions, and edit. That conversation is the review.

## After that

- `pr_pushed`: review the delta since the head you reviewed, update the draft, and say what
  moved.
- `pr_review` / `pr_comment` from others: fold them in. If someone already raised your point,
  say so rather than duplicating it.
- `pr_state` merged or closed: tell the Dispatcher; it will ask about discarding you.
