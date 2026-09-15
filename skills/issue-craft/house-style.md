# House style for agent-authored Linear issues

The reader is **an engineer, mid-triage, deciding**. Sometimes a BA; occasionally a product
person, but almost always with an engineer sitting next to them explaining it. Write for the
engineer and the other cases take care of themselves.

They have two questions, in this order: *is this mine, and must I act now?* Then: *do I
understand it well enough to start?* Everything in this document serves those two questions in
that order.

The second reader is an agent, which will ingest the whole thing at no cost. That reader is
why nothing is ever deleted.

## The one rule

**The first screen must let a reader decide. Everything below it is folded, and nothing is ever
cut.**

Evidence is demoted, never dropped. A ticket that reads as three bullet points has failed just
as badly as a wall of text: the detail is the ticket, and it stays — one click away, in the same
document, where both readers can reach it.

## Why a ticket is not a review

`review-craft` budgets a review body to 150 visible words. **Do not carry that here**, and the
reason is a scar rather than a preference.

That budget was once applied to PR *descriptions*. It was wrong twice over: it cut across the
repo's own templates, and because a description cannot collapse anything, "shorten" could only
be obeyed by paraphrasing. Paraphrasing silently ate specifics — including a lead about a test
file that existed nowhere else. Seven descriptions had to be restored from GitHub's edit history.

The rule that came out of it: **budget artefacts consumed in a feed; never budget a durable
record.** A review is read once, in a stream, and then is mostly history. A ticket is read once
at speed and then consulted for years — by the implementer, by whoever picks it up after them,
by the person doing the post-incident read, and by every agent that touches the area.

So the budget moves. **Budget the first screen. The document is unbounded.**

This works in Linear specifically because Linear folds natively, which GitHub PR descriptions do
not. The mechanism is in "Mechanics" below, and it was verified rather than assumed.

## The title

**A claim, with a number in it where one exists.** The title is the only part of a ticket most
people ever read, because the backlog view is title, label and state. A title that names a topic
makes the reader open the ticket to find out whether it matters. A title that makes a claim lets
them decide without opening it.

```
Good  An empty string silently clears content on 11 write paths
Good  state.json is rewritten on the UI thread every render tick, freezing the app under disk load
Good  pr_seen evicts the newest entries first

Bad   Fix argStr handling
Bad   Investigate performance issue
Bad   Improve the poller
```

The three good ones are real, and they are good because you can act on the title alone: you know
what is broken, roughly where, and how much of it there is. The bad ones are topics wearing a
title's clothes.

**A number in the title is worth a paragraph in the body.** "11 write paths" tells a triager the
size of the thing before they have read a word of the description.

This is `review-craft`'s "every finding line is a claim, not a topic", moved up one level. It
costs nothing and it is the highest-leverage line in the ticket.

## The first screen

Everything above the first fold or the first `##`. This is the only budgeted region, and the
budget is **about 80 words**, hard ceiling 150.

It answers, in this order:

1. **What is wrong, or what is missing.** One or two sentences. Concrete.
2. **What changes.** One or two sentences. Not the steps — the shape.
3. **Anything that stops a reader picking it up.** A blocking dependency, an open question, a
   flag, a decision someone else owns.

That is all. Size, priority and ownership are Linear fields, not prose — see "Use the native
fields".

If the first screen cannot be written, the ticket is not understood well enough to file. That is
a finding, not a formatting problem, and the right response is to say so rather than to pad.

**A specific outranks the budget.** If trimming to fit would cost a path, a count, a version or
a production figure, go over. The budget exists to protect the reader's attention, not to
compete with the facts.

## Below the first screen

Folded, sectioned, and complete. This is the part an agent eats and a human reaches for when
they have decided to engage. There is no length limit and there should not be one.

What typically lives here, when there is something true to say:

- **Evidence.** The call sites, the counts, the query and its result, the log line, the
  reproduction. Dated.
- **Mechanism.** Why it happens, down to the code path. Named files and methods.
- **The plan.** What to change, file by file. See "Where the solution goes".
- **Alternatives rejected**, each with the reason. This is the single most valuable section for
  the next person, and the one most often left out.
- **Deliberately out of scope.** Adjacent defects and tempting tidy-ups, each with its own
  ticket where one exists. Publishing what you considered and dropped is what earns you the
  right to keep the first screen short.
- **Acceptance criteria.** See below.

## Sections are answers to questions

**No answer, no section.** Cut it.

A fixed template that cannot shrink is a machine for producing unfilled boilerplate, and
unfilled boilerplate is what teaches people that tickets are not worth reading. This is the same
failure a PR template produces when it auto-fills a body that then passes a description check
and fails review.

Never leave a heading with a template prompt under it. Never leave `*(placeholder)*` in a saved
ticket — either fill it, ask the question, or cut the section. A placeholder in a draft is
honest; a placeholder in a saved ticket is a lie about completeness.

## Evidence is never paraphrased

Developers' most-wanted information is the part that is hardest to supply: steps to reproduce,
stack traces, and concrete cases (Bettenburg et al., 466 responses across Apache, Eclipse and
Mozilla). The gap between what a ticket contains and what the implementer needs is an
*information* gap, not a prose gap.

So the expensive part of a ticket is the evidence, and it is the part that must never be
smoothed for readability:

- A path, a line number, a class or a method name is copied, never described.
- A count is a digit. "Several call sites" is not a substitute for "11".
- A production figure carries the environment it came from and the date it was read.
- A quoted error is quoted, not summarised.

If evidence makes the ticket long, fold it. Folding costs the reader one click and the agent
nothing. Rewording it costs everyone the fact.

## Date what was true

A ticket is consulted long after it was written, and agent-authored tickets rot faster than
human ones because they are denser with specifics.

- No bare "currently", "now", "recently", "at the moment", "the latest".
- Production facts carry the date they were read and the environment: *"3,412 rows on prod,
  read 15 Sep 2026"*.
- Version-dependent claims name the version.
- A claim about a file names the file, so a reader can check whether it still says that.

The linter flags the rotting words. It cannot flag a missing date, so that one is on you.

## Acceptance criteria: observable, encoding free

The only hard rule is that a criterion must be **observable and falsifiable**. A "done" you
cannot test is a wish.

- **Gherkin where something executes it.** If QA reads the scenarios verbatim as the test plan,
  Gherkin earns its cost and you should use it. Team FUE works this way.
- **Checkboxes everywhere else.** For a copy change, a config flip or a refactor, a Gherkin
  scenario is ceremony that costs words and buys nothing.
- **Include the negative space.** "Retrying does not create a second bill." "With the flag off,
  nothing changes." The guard cases are where implementations diverge from intent, and they are
  what an agent will otherwise decide for itself.
- **Every criterion has something in the plan that delivers it, and every step exists because of
  a criterion.** A mismatch means one side is wrong. Fix that side rather than papering over it.

A criterion that is really an implementation instruction has been written at the wrong level.
Rewrite it as the behaviour it was reaching for.

## Use the native fields

Linear has `priority`, `estimate`, `labels`, `state`, `cycle`, `project` and relations. They are
filterable, sortable, screen-readable and visible in the backlog view where the decision actually
gets made.

**Do not build a second severity scale in markdown beside them.** A 🔴/🟠 vocabulary in the
description is a second source of truth that will disagree with the priority field, and
disagreement between a field and its prose restatement is a catalogued issue-tracker smell in its
own right.

This is a real difference from `review-craft`, where coloured severity rails earn their place
precisely because GitHub has no severity field. Linear does. Use it.

The same goes for size (`estimate`), ownership (`assignee`), and readiness (a label). A state a
poller can read is worth more than a sentence a human has to interpret — and it is what makes a
ticket dispatchable.

**Readiness is a label, and it is withheld while any question is open.** An unlabelled ticket
with a complete plan is the correct state for "waiting on a decision". Never label a ticket ready
with an open question, a product decision, a production data operation, or an unbounded blast
radius in it.

## Where the solution goes

**In a fold, in the body. Not in an attachment, and not mixed into the problem statement.**

The argument for an attachment is clean separation: the body stays human, the attachment carries
the agent-grade detail. It is a good argument and it was the alternative seriously considered.
It loses on one point: an attachment is a second thing to open, for the human *and* for the
agent, and every extra fetch is a place where the agent gets a stale copy, gets a 404, or simply
does not bother.

A fold gives the same separation with none of the retrieval risk. Everything is on the page.

Two rules follow:

- **The problem statement never contains solution steps.** Above the first fold is what is wrong
  and what changes in shape, never how. The moment the approach changes, a body written as steps
  becomes a lie, and nobody edits it.
- **Anything needing a decision is a question, never a guess written as a step.** A plan with an
  open question is not finished. Write the question, leave the readiness label off, and say who
  owns it.

## The six shapes

Not templates. Thin adapters on the one contract, each naming what its below-the-fold must carry.
Everything else is cut.

| Shape | First screen says | Below the fold must carry |
|---|---|---|
| **Defect** | What is wrong, who it affects, how big | Reproduction, mechanism with the code path, the evidence census, expected vs observed |
| **Change** | What is missing, what will exist after | The plan by file, acceptance criteria, alternatives rejected, out of scope |
| **Spike** | The question, and what decision it unblocks | The options being weighed, what would settle it, the timebox, what a "no answer" outcome means |
| **Record** | What was found and whether anything must be done | The findings, ranked; and what was checked and found sound, so nobody re-checks it |
| **Request** | What is being asked for, and by when | Who asked, the context, what a good answer looks like |
| **Security** | The exposure, in plain terms | Reproduction held to the minimum that proves it, affected surface, mitigation, disclosure state |

Two notes on the less obvious ones.

**Record** is the shape most often written badly, because it is written as though it were a
Change. A ticket that says "seven pre-existing defects, none introduced by this PR" is a record:
its job is to be found later, not to be picked up tomorrow. Its most valuable section is the one
listing what was checked and found *sound* — that is the section that stops the next person
repeating the audit.

**Security** is the one shape where evidence discipline is deliberately reduced. Carry enough to
prove the exposure and no more. A working exploit in a ticket is a liability in a system many
people can read.

## Mechanics

Verified by live probe on **15 September 2026** (DEV-667, DEV-668; both trashed afterwards).

**Folds are native and they round-trip.** Write `+++ Title`, content, then `+++` to close.
Linear also accepts `>>>` as the opener and normalises it to `+++` on save. The fold renders as a
real collapsible section, **collapsed by default**, which is exactly the behaviour this style
depends on.

```markdown
Visible on the first screen.

+++ Evidence: the eleven call sites
Everything in here is folded away by default.
Both readers can still reach it.
+++

Back outside the fold.
```

**An unpaired `+++` swallows the rest of the document.** Everything after an unclosed opener is
pulled into the collapsed section, the API returns success, and nothing warns you. This is the
sharpest failure mode in the whole format and it is why the linter exists. It is the direct
analogue of the unpaired-backtick bug `review_lint.py` catches.

**Verified to survive a human editing the ticket in Linear's own editor.** A ticket written via
the API, then edited by hand in the web editor and saved, came back with both fold pairs intact
and byte-identical. Folds are a first-class node, not a markdown artefact.

**The API serves a stale body for up to about a minute after an editor edit.** Observed: a
read immediately after a hand edit returned the old description with an unchanged `updatedAt`;
the same read a minute later was correct. An agent that reads a ticket right after a human
touched it can get the old text. If a read looks wrong, re-read before concluding the write
failed — and never re-write on the strength of one stale read.

**Linear supports:** tables, mermaid (in a ```mermaid fence or via `/diagram`), checkboxes,
blockquotes, `:emoji:`, code fences, `@` mentions of issues, users and projects, and headings
H1–H4.

**Linear silently drops:** HTML `<details>` (use `+++`), GitHub alert syntax `> [!WARNING]`
(renders as a plain blockquote with the literal text), and HTML generally. The linter flags both.

## What the research supports, and what it does not

Be careful here, because the evidence does not say what we assumed it would.

**It supports:** that the gap between ticket and implementer is an information gap. Steps to
reproduce, stack traces and concrete cases are what developers most want and what reporters find
hardest to supply (Bettenburg et al., 466 responses). Protect the evidence.

**It does not support "long tickets are bad."** An interview study of 26 practitioners against 31
candidate issue-tracker "smells" found "description too long" rated *not* problematic by 6 of 13
respondents, and "no or short description" rated not problematic by 6 of 17. Both were judged
heavily context-dependent — on issue type, team, and workflow stage.

The 14 problems those practitioners actually reported are overwhelmingly system-level:
findability, issue overload, zombie issues, workflow bloat, scoping-is-hard, information islands.
Not one of them is "the prose was dense."

**So state the problem honestly.** The legibility problem this skill addresses is real and it is
*ours*: it is specific to agent-authored density, which is roughly two years old and which nobody
has studied. Do not dress it up as inherited best practice. What the literature does tell us is
that findability and scoping matter more than we were treating them — which is the argument for
the claim-title and the native fields, and against the elaborate template.

## The measurement

Every quality claim in this document is currently an opinion, and the way that argument ends is
with a number rather than with taste.

The metric to build: **how many questions did the implementer have to ask back that the ticket
should have answered?**

It is the ticket analogue of the standard `review-craft` holds itself to — Google's under-10%
effective false positive rate, where a finding nobody acts on counts against you. Here, a ticket
that has to be interrogated before work can start has failed, however complete it looked.

Agents make this cheaper to measure than it has ever been: an agent that stops to ask is a logged
event. Count them per ticket, and the disagreement about format becomes a disagreement about a
number.

**Build this early.** The PR-review work went weeks arguing about taste because it was built
late, and that was the single thing that retrospective said it would change.

## Before you save, check

1. Would the **title alone** let someone in the backlog decide whether to open it? Does it carry
   a number?
2. Does the **first screen** say what is wrong, what changes, and what would stop someone
   starting — in about 80 words?
3. Is every section an **answer to a question**? Cut the ones that are not.
4. Is any **path, count, figure or error** paraphrased rather than copied?
5. Does every production fact carry its **environment and its date**? Any bare "currently"?
6. Is every **fold paired**, and does every fold have a title?
7. Are the **acceptance criteria observable**, and do they include the negative space?
8. Are **priority, estimate and labels** set — rather than described in prose?
9. Is there an **open question**? If so, is it written as a question, and is the readiness label
   off?
10. Did you say what you **deliberately left out**, and why?
11. Has the linter passed?

## Sources

- Bettenburg, Just, Schröter, Weiss, Premraj and Zimmermann, *What Makes a Good Bug Report?*
  (FSE 2008) — 466 responses across Apache, Eclipse and Mozilla; the information-mismatch finding.
- Montgomery, Lüders, Rahe and Maalej, *Smells Depend on the Context: An Interview Study of Issue
  Tracking Problems and Smells in Practice* (ACM TOSEM; arXiv 2601.04124) — 26 practitioners, 31
  smells, 14 problems; the context-dependence finding and the system-level problem list.
- `review-craft/house-style.md` in this plugin — the Google effective-false-positive standard,
  the demote-don't-delete principle, and the PR-description budget scar.
- Live probe of Linear's renderer and API, 15 September 2026, recorded under "Mechanics".
