# House style for agent-authored reviews and PR bodies

The reader is a senior engineer mid-task who will **skim first**. Your job is to make the skim
land accurately, and to make the depth reachable in one click for the moment they choose to go in.

Accuracy is not the problem — a correct review nobody reads has failed anyway.

**The standard we hold ourselves to** is Google's, from *Software Engineering at Google* (CACM 2018):
under **10% effective false positives**, where "an issue is an effective false positive if developers
did not take some positive action after seeing it." A finding that is true, and that nobody acts on,
counts against you. "But it was correct" is not a defence.

For calibration: human reviewers run at 64–68% usefulness across ~1.5M comments (Bosu et al., 2015),
so one in three human comments already misses. And attention decays with **position**, not time —
a defect's odds of being caught fall 64% when its file sits last (arXiv 2208.04259). What goes first
matters more than what goes in.

## The one rule

**The body tells the story; the findings live on the code; only proof is folded away.** Nothing is
ever deleted — evidence is demoted, not dropped. A review that reads as a list of bare assertions has
over-corrected just as badly as a wall of text: the reasoning is the review, and it stays visible.

**Budget: 150 visible words in the body. Hard ceiling 400, whatever the size of the diff.**

For scale, measured across the market in 2026: Devin ships 26 words, Qodo 189, Ellipsis 218,
Sourcery 654 (half boilerplate), and Graphite Diamond ships no top-level body at all. A 1,918-word
body is about 3× the longest any commercial reviewer ships.

**The body is triage, not the review.** Findings belong **inline, on the line they concern** —
Diamond, Bugbot and Devin are inline-only. The body says how many, how bad, and the one thing that
matters most.

**At most three findings raised in the body.** Qodo ships `num_max_findings = 3` as a literal
default, and measured tools raise 1.1–3.4 findings per PR. Anything past three goes inline only,
or into a collapsed "Also found" list. If everything is important, nothing is.

## Whose name is on it

- **Self-review on our own PR** — an agent pre-review, like Greptile's. It carries the
  `🤖 Agent review` header and the `agent:<KEY>/<mode>` marker on every comment.
- **A review of someone else's PR** — this is **your principal's review**, posted only after they
  approve it in the session. No agent header and no marker unless they ask for one. The style below
  still applies: it is a house style, not a bot signature.

## Shape of a review: the body is an index, the findings live on the code

Do not rebuild in markdown what GitHub already does. **Each finding is an inline thread on the line
it concerns.** The review body is a short index that links to them. This buys three things we were
faking: the argument sits beside the code it is about, each finding gets its own **Resolve
conversation** so progressive disclosure is native, and the resolution state becomes the tracker
instead of prose claiming something was fixed.

The body runs in the order a reader thinks — decide, then act, then audit:

```markdown
🤖 **Agent review · round N** · `agent:<KEY>/<mode>`
Reviewer: <traits> · <backend> · reviewed <sha-short>

**2 Blockers · 5 Should · 5 Nits — 10 fixed, 2 open.** <The one sentence that matters most.>

**Method** · read <what you read> · ran <what you ran> · **N suppressed** · **N not verified** ·
**N areas not reviewed** — detail at the end

### Problem fit
<2–3 sentences: the problem as you understand it, and whether this change is the right shape for it.>

### Open — needs a decision
| | Where | Finding | Disposition |
|---|---|---|---|
| 🔴 Blocker · pre-existing | [`ProviderWebhookClient.ts:63`](link-to-thread) | `RequestRecorder` persists the bearer token when `RECORD_REQUESTS` is on | Open |
| 🟠 Should · in diff | [`ReconcilePlansCommand.ts:88`](link-to-thread) | Retry budget is shared across flags | Declined — <reason> |

### Resolved in this PR
| | Where | Finding | Fixed in |
|---|---|---|---|
| 🟠 Should · in diff | [`ReconcilePlansCommand.ts:104`](link-to-thread) | Webhook URL reached Sentry breadcrumbs | `3bcbe55` |

<details><summary>How this review was made — scope, suppressed findings, what I could not verify</summary>
… provenance: what was checked and held, Suppressed (N, with reasons), Not verified, how to reproduce …
</details>
```

A **Disposition column on the Open table** gives declined findings a home: a reader may want to
overrule one, but it is not waiting on them, and it should not read as an open question.

The body's word budget **excludes table rows** — they are scan targets, not prose.

**One Method line carries the provenance**, directly under the verdict where the eye already is: what
you read, what you ran, and three counts — suppressed, not verified, and **not reviewed**. The
coverage gap is the most honest number in a review and the one most easily buried; it appears as a
count up here and as a list in the folded block. There is no separate Scope line: two lines of
provenance above the tables is a wall of its own.

**A grouped row or thread declares how many findings it holds, as `×N`** — `⚪ Nit ×5 · mixed`. Without
it the verdict's arithmetic cannot be checked by anyone, including you: five grouped nits counted as
one row is exactly how a verdict line goes wrong.

**A reply still carries the `agent:` marker**, in a trailing `<sub>`. It is not a finding and takes
none of the finding rules, but without the marker a worker's own ticket watcher reports its proof
reply as if a human had commented on the PR.

**`×N` is for findings sharing one thread.** Findings that each have their own thread get their own
row — collapsing three claims behind one link is the conflation the four-part shape exists to undo.

**Replies are not findings.** Moved proof, an answer to the author, a note about a resolution — none
of them take the finding shape, the marker rules, or the budget.

**Two tables, not one.** The first question a reader has is *is there anything for me to do*, and
that is not the same question as *how severe was it*. Open findings demand attention; resolved ones
are record, and cost a skim nothing.

**Tag every finding `in diff` or `pre-existing`.** A reader deciding whether the author must act now
needs that before anything else. A pre-existing blocker surfaced by this PR is important and is not
this author's debt.

**Label a finding that corrects the author's claims**, rather than the code, as `correction`. It is a
different kind of thing from a defect — and it is where these reviews beat a diff scanner.

## Each finding, in its thread

Bold labels inside running prose read as one grey block. Put the finding **inside a GitHub alert**,
which renders a coloured left rail and carries severity before a word is read:

```markdown
> [!WARNING]
> **Should · pre-existing** — `<Tooltip onClick={stop}>` throws on every click · `Open — needs a ticket`
>
> **What** · <one or two sentences of mechanism — what actually goes wrong>
> **Why it matters** · <the consequence, with a number where you have one>
> **What I'd do** · <the action you expect>
>
> <details><summary>Proof</summary>
>
> commands, output, call-site inventory
> </details>

<sub>agent:<KEY>/<mode></sub>
```

Severity picks the alert: **Blocker → `[!CAUTION]`** (red), **Should → `[!WARNING]`** (amber),
**Question → `[!NOTE]`**. Verified rendering: `<details>` works inside the alert, and inside a
blockquote GitHub turns single newlines into `<br>` by itself, so the three labels stay on their own
lines with no trailing spaces. The alert prints its own "Warning" title above your severity word —
mild duplication, accepted, because `Blocker`/`Should`/`Nit` is our vocabulary and it stays
searchable. The `agent:` marker sits **outside** the rail: it is provenance, not finding.

**Disposition goes on the title line as a code span**, not as a fourth label at the bottom. It is
status, and status belongs at the top.

**Nits take a lighter shape — no alert, no labels.** Four labels on a one-line nit is why nits read
as heavy as blockers:

```markdown
⚪ **Nit** — `ToggleGroup` declares a `disabled` prop it never binds · `Fixed in a8f7cc6`
`ToggleGroup.tsx:10` declares it; nothing passes it to `ToggleGroupRoot`. Latent until someone
wires it up, then disabled options show the hand.
**Fix:** bind the prop, and add `data-[disabled]:cursor-not-allowed` to the option slot.
```

The contrast between the two shapes is the point: weight should track severity.

Consistency is the point: once a reader has learned the shape on the first finding, the fourth takes
five seconds. Evidence goes in the thread — ideally as a **reply**, so the proof sits under the claim
it proves, not in an appendix at the other end of the page.

**A grouped thread's budget scales with what it holds** — roughly 250 visible characters per finding
it carries, so five grouped nits at ~1,100 is right, not bloated. Keep a single-finding thread under
**700 visible characters** before the fold — four labelled parts plus a path and
a number do not fit in 400 — and end every comment with the `agent:<KEY>/<mode>` marker.

**A specific outranks the budget.** If trimming to fit would cost a path, a line range or a number,
go over — the four parts exist to carry those, and paraphrasing them away defeats the structure.

**Say who resolved a thread.** A finding raised, fixed and resolved by the same account inside two
minutes reads as theatre, however honest it is. End the comment with "Fixed in `sha` — resolved by
the PR author, not by the reviewer", so the collapse is transparent rather than self-congratulatory.

**Findings raised and fixed before the PR was published** go in the Resolved table, and the verdict
line says so: "6 raised during development and 6 fixed; 2 open" rather than "6 fixed, 2 open", which
implies a reviewer saw them live. Keep a digit against every noun — "all fixed" reads fine and leaves
the arithmetic uncheckable.

**A very long proof goes in a reply, not a nested fold.** Inside an alert the rail extends behind the
fold, so a long `<details>` drags a coloured box a long way down the page. Short proof: nest it.
Long proof: reply with it, and the rail stays the size of the finding. **This is about the rail, not
the budget** — a fold already costs nothing against the budget, so moving proof out will not fix an
over-budget thread. That needs prose trimming, and never at the cost of a path or a number.

**Proof goes in a reply only on threads that stay open.** A resolved thread is already collapsed by
GitHub, so a reply there just doubles the comment count; fold the proof into the comment instead.

**One thread per Blocker and per Should. Nits group** into a single thread with one index row — five
resolved nit threads is noise, and the Volume rule outranks "one thread per finding". **But never
collapse threads that already carry a conversation**: an existing reply from the author is record,
and grouping that destroys it costs more than the noise it saves. Grouping applies to threads you
are about to create.

**Findings with nothing in the diff to anchor to go in one "Corrections and unanchored findings"
comment** on the PR conversation — this is the one top-level comment the post-once rule allows
beyond the index, and the index links to *that comment's* URL. Corrections to the PR
description, a missing ticket, a wrong figure, a CI file the diff never touches — these are often the
most valuable findings and they must stay navigable. An unlinked table row is the last resort, not
the convention.

**Tag `correction` only when it changes what a reader would believe.** In a self-review, correcting
your own description is routine; tagging nine of fifteen findings that way tells the reader nothing.
A wrong figure someone would repeat is a correction; a typo is a Nit.

**A pre-existing finding usually has nothing to anchor to**, because GitHub only anchors inside the
diff. Pin it to the diff line that *triggers* the behaviour, and say in the thread that the code at
fault is elsewhere, naming it. A finding with nothing to pin to at all — a missing ticket, a wrong
figure in the description — stays in the body table with no link.

## Mechanics

Posting is two steps, because a link to a thread needs the thread to exist:

1. **Create the threads** — one per finding. Build a JSON payload and use `--input`:
   ```bash
   jq -n --arg sha "$SHA" --arg path "$P" --arg body "$(cat finding.md)" \
     '{commit_id:$sha, path:$path, line:42, side:"RIGHT", body:$body}' > t.json
   gh api repos/OWNER/REPO/pulls/N/comments --input t.json
   ```
   **`-f body=@finding.md` does not work.** `-f` is a literal string field, so the file path posts as
   text. `-F` expands `@`, and `--input` is safer still for bodies with newlines and backticks.
   Keep each returned `html_url`.
2. **Replace the body** with the index, each table row linking to its thread's `html_url`:
   `gh api -X PUT repos/OWNER/REPO/pulls/N/reviews/<review_id> --input body.json`.
   A submitted review body is updated with **PUT**, not PATCH. Inline comments are
   `PATCH repos/OWNER/REPO/pulls/comments/<comment_id>`.
   **Check the rendered HTML, not the markdown you sent.** `gh api -H "Accept: application/vnd.github.html+json"`
   returns `body_html`, so whether a fold survived a blockquote or three labels collapsed into one
   paragraph is checkable from the terminal rather than by eye.

   **Read back what you posted.** The failure is silent: a bad body field returns HTTP 201 with a
   perfectly valid comment containing the wrong text. The cheap check is the response body's length —
   146 characters where you sent 1,200 is the tell, without a second API call.

   Note: every `pulls/N/comments` POST creates a body-less review container, so the REST review count
   climbs even though the UI renders them as threads. That is expected; the index is still one body.

**This section is about self-reviews**, where the reviewer and the author are the same session. On
someone else's PR, the author resolving your thread is them acting on feedback — normal
collaboration, and none of your business to prevent.

**Resolve sparingly, and never before a human has read the review.** Collapse is for things the
reader has already processed; resolving your own threads at post time hides the reasoning before
anyone has seen it, and on a self-review it makes the whole review look pre-agreed. So:

- **Resolve at post time only** findings that were raised *and* fixed before the PR was published —
  nobody was ever waiting on those, and the Resolved table already carries them.
- **Leave everything else open** until your principal has read it. They resolve, or tell you to.
- **On a small review — five threads or fewer — resolve nothing before the first read.** Collapse
  exists to manage noise, and four threads are not noisy. The publication-timing exception is a
  permission, not an instruction: use it only where collapsing actually buys the reader something.
- **A mixed thread is open.** If one thread collects sites found across several rounds — some before
  publication, some after — it stays open. A reader who has not seen the later finding should not
  find it collapsed.
- **Never resolve a grouped thread** that holds several findings — one collapse hiding five findings
  is the worst case of this.
- If leaving them open makes the page noisy, that is a **volume signal**, not a collapse problem:
  raise fewer findings.

To resolve once that point is reached:

```bash
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<thread-node-id>
```

Thread node ids come from `repository.pullRequest.reviewThreads` in GraphQL.

**Anchors do not work in a review body.** GitHub emits no `id` attributes there — headings included —
so a `#user-content-…` link is always dead. Write "detail at the end" in plain text instead.

**Count from the tables, every time.** The verdict line's numbers are the first thing a skimmer takes
on trust and the easiest thing to get wrong: a grouped row holding five nits counts as five findings,
not one. Recount against the rendered tables before posting, and recount again after any edit that
adds or moves a row.

**Post after CI is green.** A review that lands while checks are still running gets read twice.

## Vocabulary

Four severities, Title Case, never invented mid-review:

| | Means | Evidence needed |
|---|---|---|
| 🔴 **Blocker** | Merging causes wrong behaviour, data loss, or a security or authorisation hole | Reproduction, or the exact code path |
| 🟠 **Should** | A real defect or risk, bounded; merging is defensible if it's ticketed | The mechanism, and why it's bounded |
| ⚪ **Nit** | Readability or consistency. The author may ignore it without replying | None |
| 🔵 **Question** | You genuinely cannot determine it and need the author's knowledge | Say what you checked first |

A Question is not a finding in disguise. If you know it's wrong, say it's wrong.

**Direction findings.** When the change is the wrong shape for the problem — a patch on a symptom,
a schema that will need changing again, a workaround for something fixable upstream — say so in
**Problem fit**, not as a Nit at the bottom. If it should block, make it a Blocker and say what you
would build instead.

## Casing and formatting

- **Sentence case headings**: "Problem fit", "Not verified". Not "problem fit", not Title Case.
- Bold **only** severity labels and the one-sentence verdict. Bold inside a paragraph stops working
  when everything is bold.
- Backticks for every identifier, path and value. `file.ts:68`, linked to the line where you can.
- Numbers, not adjectives: "1 in 81 draws", not "quite likely".
- No emoji beyond the four severity glyphs and the 🤖 header. **The word carries the severity, not
  the glyph** — emoji-only schemes (Devin) and image badges (Greptile) can't be searched, filtered or
  read by a screen reader.
- No confidence score. Only one of nine tools prints one, and a score the reader cannot interrogate
  gets ignored — as Greptile's does here.

## Reach for these before prose

- **Suggested changes.** For anything mechanical, a ```suggestion block is a one-click fix and
  replaces three sentences of explanation. Use it for every Nit that has an obvious edit.
- **Mermaid**, at most one per review, and only when the finding is about a path across three or
  more components, a state machine, or an architecture you're proposing instead. A diagram of two
  boxes is noise.
- **GitHub alerts** (`> [!WARNING]`) for at most one thing per review — the one a merger must not miss.

## Rounds: post once

The dominant complaint about AI reviewers in 2026 is not nitpicking — it is that they are stateless
and staggered: they repeat findings the author already rejected, and dribble new comments across
every push. No benchmark measures this, because precision and recall are single-shot.

- **Never re-raise a finding the author declined.** Keep the list of what was rejected, and treat a
  rejection as settled unless the code changes underneath it.
- **One comment per round**, after the push settles — not one per finding as you notice them.
- A re-review says what changed: what's fixed, what's still open, what's new. Nothing else is re-posted.

## "Not verified" is the only section with no adversary

Every other part of a review is checked by someone: findings by the author, severities by the
reader, arithmetic by the linter. The provenance block is checked by nobody, which makes it the
one place where costume survives indefinitely — caveats that sound rigorous and cost nothing.

**The test: a "not verified" item must name something that, if you checked it and it came out
badly, would change a finding's severity or remove a finding entirely.** If nothing it could
reveal would change the review, it is not a caveat; it is a hedge, and it is taking up the space
where a real one should be.

Two ways it goes wrong, both observed in a real review:

- **The caveat about untouched territory.** "The comparison was reasoned about, not exercised
  against the database driver" — where the operation in question never reaches a driver. It
  reads as honest and forecloses nothing. Often it has been carried over from an earlier review
  where it *was* load-bearing, which is why it survives a reread: it was true somewhere else.
- **The caveat that raises confidence instead of lowering it.** "The figure is empirical, so the
  analytic value is the one I would defend." That does not admit a weakness; it promotes a number
  the review never checked, in the section whose job is to admit weaknesses. If a derivation and
  a measurement disagree, the disagreement is the finding — compute it rather than choosing a
  side, because two numbers that agree to one significant figure is exactly where a real error
  hides.

**Where you got something wrong and fixed it before posting, say which way it was wrong.** "The
figure I first derived made the bug look rarer than it is" tells a reader how to weight the rest
of your numbers. "Corrected an error" tells them nothing.

## Volume

No format survives 24 findings on a cursor change. Before a finding goes anywhere, ask the question
the Google standard asks: **will the author take an action?** If not, it belongs in Suppressed with
a reason, not in a thread. Raising fewer findings is what makes the ones you raise legible.

## PR descriptions are out of scope

This style governs **reviews and comments only**.

PR descriptions follow **the repo's own templates and its own decision records**, which people
already write to and which often make the description the permanent technical record of the
change. Do not restyle, compress or reorganise a description to match anything here. Write it
from the repo's template, with the sections that template gives you.

(An earlier version of this guide imposed a 400-word target on descriptions. It was wrong twice
over: it cut across the repo's templates, and because a description cannot collapse anything,
"shorten" could only be obeyed by paraphrasing — which dropped specifics like "the 94 model files
are one import line each" and a lead about a second arch test that existed nowhere else. Seven
descriptions were restored from GitHub's edit history.)

## The linter is the gate, not this document

`python3 review_lint.py <PR> --repo OWNER/REPO`, beside this file, checks the posted review
against these rules —
index shape, method line, table links, verdict arithmetic, severity rails, the four parts,
disposition chips, thread budgets, dead anchors, and that the PR description was left alone. It reads
GitHub's rendered HTML rather than the markdown you sent.

**A review is not finished until the linter passes.** Run it, fix what it names, run it again, and
paste the final output when you report. A document nobody can fail is a suggestion; this is the rule.

## Before you post, check

1. Would the first 15 lines, alone, tell a reviewer what to do? (Verdict, problem fit, the open table.)
1b. Does the body read as a story — decide, act, audit — rather than blocks stacked in no order?
2. Is every finding line a claim, not a topic?
3. Does the visible layer fit the budget for this change size?
4. Is anything asserted without a number, a path, or a command behind it?
5. Did you state whether this change is the right shape for the problem — not just whether the diff is correct?
6. For each finding: what action do you expect the author to take? If you can't name one, it belongs
   in Suppressed, not in the review.
7. Does every finding say whether it is `in diff` or `pre-existing`, and carry a disposition?
8. Does every table row link to its thread, and is every fixed thread resolved?

## Sources

The numbers above come from a market scan of nine commercial review tools and the papers cited
inline. The scan itself is not shipped with this skill; the figures that survived it are.

Three pieces of review folklore did not survive tracing, so don't repeat them: the "60-minute
reviewer ceiling" has no primary source; "70–90% defect discovery" appears only in SmartBear
marketing, uncited; and "200–400 LOC" is a distortion of the Cisco study's "under 200, not to
exceed 400", whose upper bound rests on the unsourced 60-minute claim.
