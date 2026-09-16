---
id: issue-craft
name: Issue Craft
description: How to write a Linear issue that a human can act on from the headings alone and an agent can build from without asking a question — the summary, the ask under its own heading, headings as the skeleton, folds for raw evidence only, tables and diagrams where they carry a fact, and a linter that checks the result. Hands over method; it does not write your ticket. USE WHEN writing or rewriting a Linear issue, deciding what belongs in a ticket body, judging whether a ticket is ready to hand to an agent, or checking a drafted ticket before saving.
triggers:
  - issue craft
  - ticket craft
  - write a ticket
  - write an issue
  - rewrite this ticket
  - is this ticket ready
  - ticket style
  - ticket house style
  - agent ready
  - decision needed
---

# Issue craft

**This skill hands you a method. It does not write your ticket.**

Invoking it loads the craft and stops. It does not read your Linear issue, draft a description,
or save anything. If you invoked it while writing a ticket yourself, you should get material to
read and nothing else happening in the background — that is the intended behaviour.

> **Sibling to `review-craft`.** That skill governs how you write up a change you have read;
> this one governs how you write up work that has not happened yet. They share one principle and
> invert one: both demote rather than delete, and where a review is budgeted end to end, a ticket
> is not budgeted at all. The reason is in `house-style.md` under "Why a ticket is not a review".

## What is here

| File | What it carries | Read it when |
|---|---|---|
| `house-style.md` | The craft: the skeleton, the ask, what folds and what does not, showing rather than telling, editing an existing ticket, evidence discipline, the six ticket shapes, what the research does and does not support | Before you write anything down |
| `examples/synthetic-defect-ticket.md` | One worked ticket in the house style, with the shape annotated | When you want to see the shape rather than read the argument |
| `issue_lint.py` | A deterministic, read-only check of a *saved* issue against the mechanical rules | Before you tell anyone the ticket is ready |

## The short version

Everything below is argued in `house-style.md`. This is the part worth holding in your head.

- **A reader must find the ask and the shape of the problem without opening anything. Bulk is
  folded, and nothing is ever cut.** Demote, don't delete.
- **No word budget, anywhere.** A ticket is a durable record. The first version of this style
  budgeted the opening paragraph, and it produced flat tickets with the decision buried at the end
  of a sentence and the acceptance criteria folded out of sight. Structure replaces the budget.
- **Headings are the skeleton. Folds are not.** A reader scanning the headings and the bold should
  come away with the argument. A ticket with no headings has no hierarchy.
- **The ask gets its own heading, near the top, with the owner named.** `## Decision needed —
  Patrick`, then a blockquote with the question in bold. Never a trailing sentence, never in a
  fold. Readiness is a label, withheld while the ask is open.
- **Fold raw evidence, method and bulk. Never fold the acceptance criteria, the scope, or the ask.**
  If a section is short enough to read, do not fold it; if it is long, keep the answer visible and
  fold the workings under it.
- **Show it.** A table for anything compared or counted. A code fence for a path, query or error.
  Bold for the one sentence per section that must not be missed. A mermaid diagram where the thing
  is a flow, a state machine or a timeline — when it replaces a paragraph, not when it restates a
  list.
- **The title is a claim, with a number where one exists, under about fifteen words.** The claim
  goes in the title, the explanation in the summary, the decision in the ask.
- **Evidence is never paraphrased.** A path, a count, a production figure and a date get moved
  or folded. They never get reworded for flow.
- **Use Linear's own fields.** Priority, estimate, labels and state are native, filterable and
  screen-readable. Do not build a second severity scale in markdown beside them.
- **Date what was true.** "Currently" is a landmine in a document consulted in eighteen months.
- **An agent appends; it does not rewrite.** A decision taken after filing is recorded, dated and
  attributed, above the question it answers. The original text stays. Never retitle someone
  else's ticket silently.

## Using the linter

```bash
python3 issue_lint.py --key DEV-123        # lint the saved issue (needs LINEAR_API_KEY)
python3 issue_lint.py draft.md             # lint a local draft
```

It checks the mechanical rules only: paired folds and closed code fences, a summary that exists,
a long body with no headings, an acceptance-criteria or scope section inside a fold, an ask buried
in a fold or in prose with no heading of its own, a title that names a topic or runs past twenty
words, unfilled placeholders, rotting relative dates, unpaired backticks, a markdown severity
scale competing with Linear's priority field, and markup Linear silently drops. **It cannot tell
a good ticket from a bad one** — it catches the failures that are invisible until someone is
depending on them.

**Lint the saved issue, not your draft, wherever you can.** The failure this exists to catch is
silent: an unpaired `+++` swallows the entire rest of the ticket into a collapsed section, the
write returns success, and the ticket looks fine until someone opens it.

**A ticket is not finished until the linter passes.** Run it, fix what it names, run it again.

## Verified behaviour, and its date

The mechanics in `house-style.md` rest on a live probe of Linear run on **15 September 2026**
(issues DEV-667 and DEV-668, both since trashed). What was tested, and what was not, is recorded
in that file under "Mechanics". Linear ships changes weekly; if a fold behaves differently from
what is written there, re-probe and update the file rather than working around it.

## Revision

**16 September 2026.** The first version (15 September) budgeted the opening at about 80 words and
told authors that everything below it was folded. Within a day it had produced tickets with no
headings, the acceptance criteria and the out-of-scope section collapsed, and the one open
question written as the last sentence of a paragraph — the reader opened every fold looking for
what they were meant to do and found it on the third read. The budget is gone; the skeleton, the
ask, "what folds" and "show it" replaced it. The tickets written on 14 September, with headings,
tables and a visible UNRESOLVED section, were the better shape all along.
