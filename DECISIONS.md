# Decisions

Durable records of choices that shaped Locus, with the reasoning that produced them.
A decision here is not a plan — it is something already settled, kept so that the next
person to question it inherits the argument rather than re-running it.

---

## DEV-516 — Learning persistence: keep writing, build no reader (Option C)

**Date:** 2026-09-13
**Status:** Accepted
**Supersedes:** PR #16, which chose Option A (stop writing). That PR is closed and its
decision is rejected.

### Decision

**Option C — keep writing, build no read path, record why.**

The LEARN phase's mandatory write to `{data}/memory/learning/session/` stays exactly as
it is. No read path is built. No code changes, and no change to the LEARN phase.

DEV-516 as filed offered two options — stop writing, or build a reader. Neither was
taken. The decision is the third thing the ticket did not name: continue, deliberately,
with the reason on record.

### Why

Option A's reasoning was sound, and it argued for the wrong conclusion. "Indexing
documents of unproven value is the wrong order of operations" is a correct argument for
**not building the read path**. It is not an argument for stopping the write, and the
original framing conflated the two because it only offered options where those moved
together.

Separate them and the three positions look like this:

- **Keep writing, no reader.** Costs disk and a small per-turn write. The corpus keeps
  growing. If a consumer is ever built, it arrives against a large corpus.
- **Stop writing, no reader.** The same absence of value today, and the corpus is
  permanently capped at its current size. If a consumer is ever built, it arrives against
  a frozen, finite set.
- **Build the reader now.** Premature, against data whose value is unproven.

The costs of A and C are near-identical today. Their *futures* are not. **You can always
stop writing later; you cannot retroactively write learnings for work already done.**
Stopping is the only one of the three that destroys an option, which makes it the worst
of them — and the opportunity cost is the whole difference between a corpus that was
still accumulating when a consumer arrived and one that stopped two years earlier.

### The qualification that comes with it

This is not pure option value, and the decision would be dishonest without the caveat.

The 2026 memory literature is blunt that a growing corpus is not automatically a more
valuable one. The recurring failure is teams building *store* and *retrieve* and skipping
*update*, *compress* and *forget* — which is where the failures accumulate: unbounded
growth with no eviction, stale facts surviving updates, and retrieval noise consuming the
attention the memory was meant to save.

The Memora benchmark (**arXiv 2604.20006**) introduces FAMA specifically because
accumulated memory goes stale and standard retrieval metrics do not penalise it. Across
**four LLMs and six memory agents** it found *"frequent reuse of invalid memories"* and
only *"marginal improvements"*.

So Option C is **keep writing, not keep accumulating unboundedly**. Two conditions make
the corpus worth having when a consumer eventually arrives:

1. **Every learning stays dated and project-scoped.** The schema already does this. A
   future consumer must be able to weight by recency rather than treating a 2025 learning
   as equal to a 2026 one.
2. **A size or age tripwire**, so "keep writing" does not silently become the
   unbounded-growth failure mode the original review flagged. Revisit when the corpus
   passes a threshold worth naming — not to prune it reflexively, but to decide
   deliberately rather than by neglect.

### Why not Option A (stop writing)

Because it is irreversible in the only direction that matters. Every other position here
can be walked back in an afternoon; a year of unwritten learnings cannot be recovered at
any price. A decision that forecloses the future to save a per-turn file write is buying
very little with something that is not for sale.

### Why not Option B (build one read path)

Unchanged from the original analysis, and still correct. Retrieval would have to be
built, wired into OBSERVE, and then *demonstrated* changing a session's behaviour. Until
that last step it is Option C plus maintenance. Indexing a corpus of unproven value first
creates indexing, invalidation, ranking, privacy and maintenance burden before showing
that any stored learning ever improved a task.

### State at the time of this decision

- **566+ learning documents** written.
- **No read verb** in any of the 11 top-level CLI subcommands — `init doctor status
  platform skill sync upgrade update-content hook agent delegate` — or their
  subcommands.
- The canonical project memory (`data/projects/`) is small, structured and genuinely
  referenced. It is **out of scope here and unaffected**; this decision is about
  `memory/learning/` and nothing else.

### Reversal condition

Reopen when a consumer is scoped. At that point the question is no longer "should we
still be writing" — it is "what does the reader do", and it arrives against a corpus that
never stopped growing.

Reopen sooner if the tripwire in condition 2 fires, to make the accumulate-or-prune call
deliberately.
