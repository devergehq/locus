---
id: issue-craft
name: Issue Craft
description: How to write a Linear issue that a human can decide on in ten seconds and an agent can build from without asking a question — the first-screen contract, native folds, sections as answers, and a linter that checks the result. Hands over method; it does not write your ticket. USE WHEN writing or rewriting a Linear issue, deciding what belongs in a ticket body, judging whether a ticket is ready to hand to an agent, or checking a drafted ticket before saving.
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
  - first screen
---

# Issue craft

**This skill hands you a method. It does not write your ticket.**

Invoking it loads the craft and stops. It does not read your Linear issue, draft a description,
or save anything. If you invoked it while writing a ticket yourself, you should get material to
read and nothing else happening in the background — that is the intended behaviour.

> **Sibling to `review-craft`.** That skill governs how you write up a change you have read;
> this one governs how you write up work that has not happened yet. They share one principle and
> invert one: both demote rather than delete, and where a review is budgeted end to end, a ticket
> budgets only its first screen. The reason is in `house-style.md` under "Why a ticket is not a
> review".

## What is here

| File | What it carries | Read it when |
|---|---|---|
| `house-style.md` | The craft: the first-screen contract, the fold mechanics, sections as answers, evidence discipline, the six ticket shapes, what the research does and does not support | Before you write anything down |
| `issue_lint.py` | A deterministic, read-only check of a *saved* issue against the mechanical rules | Before you tell anyone the ticket is ready |

## The short version

Everything below is argued in `house-style.md`. This is the part worth holding in your head.

- **The first screen must let a reader decide. Everything below it is folded, and nothing is
  ever cut.** Demote, don't delete.
- **Budget the first screen, never the document.** A ticket is a durable record, read once at
  speed and consulted for years. "Shorten" applied to a record can only be obeyed by
  paraphrasing, and paraphrasing eats the specifics that made it worth keeping.
- **The title is a claim, with a number in it where one exists.** "An empty string silently
  clears content on 11 write paths", not "Fix argStr handling". The backlog view is the only
  part most readers ever see.
- **Sections are answers to questions. No answer, no section.** A template that cannot shrink
  gets filled with ceremony, and ceremony is what teaches people to skim.
- **Evidence is never paraphrased.** A path, a count, a production figure and a date get moved
  or folded. They never get reworded for flow.
- **Use Linear's own fields.** Priority, estimate, labels and state are native, filterable and
  screen-readable. Do not build a second severity scale in markdown beside them.
- **Date what was true.** "Currently" is a landmine in a document consulted in eighteen months.
- **A ticket with an open question is not ready**, however complete it looks. Ask it as a
  question; never write a guess as a step.

## Using the linter

```bash
python3 issue_lint.py --key DEV-123        # lint the saved issue (needs LINEAR_API_KEY)
python3 issue_lint.py draft.md             # lint a local draft
```

It checks the mechanical rules only: paired folds, first-screen budget, a long body that folds
nothing, unfilled placeholders, rotting relative dates, unpaired backticks, a title that names a
topic rather than making a claim, a markdown severity scale competing with Linear's priority
field, and markup Linear silently drops. **It cannot tell a good ticket from a bad one** — it
catches the failures that are invisible until someone is depending on them.

**Lint the saved issue, not your draft, wherever you can.** The failure this exists to catch is
silent: an unpaired `+++` swallows the entire rest of the ticket into a collapsed section, the
write returns success, and the ticket looks fine until someone opens it.

**A ticket is not finished until the linter passes.** Run it, fix what it names, run it again.

## Verified behaviour, and its date

The mechanics in `house-style.md` rest on a live probe of Linear run on **15 September 2026**
(issues DEV-667 and DEV-668, both since trashed). What was tested, and what was not, is recorded
in that file under "Mechanics". Linear ships changes weekly; if a fold behaves differently from
what is written there, re-probe and update the file rather than working around it.
