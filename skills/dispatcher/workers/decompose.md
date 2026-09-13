# Mode: decompose (`Agent - Decompose`)

Finish line: **sub-issues under the ticket**, each small enough for one PR and clear enough for
an agent or a person to pick up cold. **No code changes.**

## Steps

1. Understand the whole ticket first: comments, parent, linked docs, and the code it touches,
   enough to know where the real seams are. Check existing sub-issues. Also check for sub-issues
   created by an earlier agent pass (comments signed `agent:<KEY>/`), so you never create
   duplicates.
2. Cut along seams that ship independently: each piece is one PR, reviewable on its own, ideally
   ≤ 3 points. Prefer vertical slices over "backend then frontend" when the domain allows.
   Name the ordering.
3. **Create each sub-issue** with the Linear MCP, in the workspace named in your dispatch block:
   `parent: <KEY>`, same team,
   `assignee: me`, state `Backlog`. The description holds:
   - **Why** — one or two sentences tying it to the parent
   - **Scope** and **Out of scope**
   - **Acceptance criteria** as checkboxes, each one testable
   - **Pointers** — the `file:line` places to start
   - A last line: `Created by agent:<KEY>/decompose`
   Set a suggested estimate if the team estimates. Add `blocks` relations where order matters.
   **Do not put any Agent label on the children** — your principal chooses which go to agents.
4. **Clear the parent's estimate.** Once the children carry estimates, the parent's own points
   are double-counting: the work now lives in the sub-issues, and their sum is the number the
   team should plan against. Say in your parent comment what the children total, so the number
   that left the parent is visible rather than silently gone. If the parent had no estimate,
   there is nothing to do.

   **Neither estimate tool can clear one, and one of them fails silently.**
   `linear_set_estimates` takes integers only. `linear_update_issue` types `estimate` as an
   integer and **drops a null without erroring** — the call returns "no fields to update" and
   the estimate is still there. Never report an estimate cleared on the strength of that call
   returning. Use the GraphQL escape hatch, `issueUpdate(input: {estimate: null})`, which is
   force-guarded and files an audit ticket, then **re-read the issue and confirm the estimate
   is gone** before you claim it. If the escape hatch is unavailable to you, leave the estimate
   alone, say so plainly in your parent comment and in your report to the Dispatcher, and let
   your principal clear it in the UI — a stale estimate is a small problem, a false report is not.
5. Post one comment on the parent with `D comment <KEY>`: the children in order, one line each,
   why you cut it this way, the total points across the children, and anything you deliberately
   left out.
6. Leave the parent open. `D label <KEY> done` → `D ledger put <KEY> status=done` → message the
   Dispatcher.
