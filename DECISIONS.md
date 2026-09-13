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

---

## DEV-627 — The Dispatcher ships as Python, and that makes Python a second implementation language

**Date:** 2026-09-13
**Status:** Open — recorded so the choice is made deliberately rather than by default

### The question

`skills/dispatcher/dispatcher.py` is ~800 lines of Python: a poller, a watcher, a ledger, a
Linear GraphQL client, a label mutator, a brief generator and an installer. Locus is otherwise a
Rust workspace — `crates/`, eleven subcommands, a bundled-content pipeline and a CI matrix that
runs `fmt`, `clippy` and `test` and knows nothing about Python.

Shipping it as it stands means Locus has two implementation languages for one product.

**This decision record does not settle that.** It exists so that the answer is chosen later, on
purpose, rather than inherited — which is what happens when nobody writes the question down.

### What was done now, and why

**Ship the Python.** Unchanged except for splitting config from code and adding `init`.

The alternative — port to Rust before landing anything — was rejected on sequencing, not on
merit. The Python is *working software with a live deployment*: a poller has been running it on
a 300-second loop, and its behaviour is the specification. A port written before that
specification is extracted is a rewrite of something nobody has finished reading. Landing the
working version first makes the port a refactor with a reference implementation and a diff,
instead of a reconstruction from memory.

It also keeps the two questions apart. "Should this be in the plugin" and "what language should
it be in" have different answers, different evidence and different urgency, and bundling them
means the harder one silently decides the easier one.

### Why this is cheap to undo now and expensive later

Nothing in the Rust tree depends on the Python today. `bundled.rs` treats it as opaque bytes —
the same treatment `scripts/statusline.sh` already gets — so removing it is deleting entries from
a list.

That stops being true the moment anything in `crates/` reads the dispatcher's config schema,
shells out to it, or shares a type with it. **`init` was deliberately kept in Python for exactly
this reason.** A `locus dispatcher init` subcommand would have been the natural place for it, and
would have put the config schema, the Linear client and the label vocabulary into the Rust tree —
settling this question in the most expensive direction before it had been asked.

### What would decide it

Reopen when one of these is true:

1. **A second consumer.** If anything in `crates/` needs the ledger or the config, the duplication
   is real and the port pays for itself.
2. **The CI gap bites.** There is no `ruff`, no `mypy`, no Python test job. A defect that Rust's
   toolchain would have caught and Python's absent one did not is the empirical argument.
3. **Install friction.** The skill assumes `python3` on PATH. Rust would make it one binary.
4. **It stops changing.** A port is safest against a stable target. The dispatcher is still
   learning — nine commits in its first week — and porting a moving specification is the worst
   time to do it.

### The honest case against porting at all

Three of the four candidate reasons above are conditional, and the fourth may never fire. The
Python is ~800 lines of standard library with no dependencies, it is read and edited mostly by
agents rather than humans, and "one language per repo" is an aesthetic preference until it costs
something measurable. **"Never port it" is a legitimate outcome of this record**, and it should
not be treated as the failure case. What would be a failure is drifting into a half-port, where
some of the dispatcher is Rust and some is Python and the boundary is wherever somebody stopped.
