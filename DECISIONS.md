# Decisions

Durable records of choices that shaped Locus, with the reasoning that produced them.
A decision here is not a plan — it is something already settled, kept so that the next
person to question it inherits the argument rather than re-running it.

---

## DEV-516 — Learning persistence: stop writing (Option A)

**Date:** 2026-08-30
**Status:** Accepted
**Supersedes:** the mandatory LEARN persistence step in `algorithm/v2.0.md`

### Decision

**Option A — stop writing.** The LEARN phase's mandatory write to
`{data}/memory/learning/session/` is removed. Reflection stays; the filing does not.

The existing corpus is **frozen in place, not deleted** — see *Corpus* below.

### Why

Locus wrote 371 learning documents and could not read one of them back. That is not a
gap in the retrieval layer; there is no retrieval layer. Across all eleven top-level
commands and their subcommands — `init doctor status platform skill sync upgrade
update-content hook agent delegate` — no verb reads a learning file.

The single piece of code anywhere in the CLI that touches
`memory/learning/` is `has_matching_learning_file()` at
`crates/locus-cli/src/commands/hook.rs:693`. It is an **existence check**. Locus verified
that a learning had been filed and never once looked at what was in it. The write was
enforced; the read was never built.

Meanwhile `algorithm/v2.0.md` instructed OBSERVE to "recall relevant [learnings] for this
task type" — an instruction with no mechanism behind it. Every session that appeared to
comply was either skipping it silently or narrating a recall that did not happen. That is
the same failure the Phantom Capability Rule names, encoded in the Algorithm itself.

### Why not Option B (one read path)

Option B is the more attractive answer and it is the wrong one to take on faith:

1. **It cannot be validated cheaply.** Retrieval would have to be built, wired into
   OBSERVE, and then *demonstrated* changing a session's behaviour. Until that last step,
   Option B is Option A plus maintenance.
2. **Value is unproven, and volume is evidence against it.** 371 documents accumulated
   without one ever being consulted. `learning/FAILURES/` alone is **122 MB across 44
   entries** — roughly 2.8 MB per entry, which is sampling far past anything a retrieval
   step would want to rank or read.
3. **Order of operations.** Indexing a corpus of unproven value first creates indexing,
   invalidation, ranking, privacy and maintenance burden before demonstrating that any
   stored learning ever improved a task. The 2026 memory literature frames store /
   retrieve / update / compress / forget as five required operations; Locus built one.
   Building the second in isolation does not fix that — it just makes the imbalance more
   expensive.

DEV-516 anticipated this and set the tiebreak itself: *"If it does not get called, fall
back to A."* It does not get called, because it does not exist.

### What survives

- **PRDs** (`memory/work/`) — read by status and hook logic. Consumed, therefore kept.
- **Checkpoints** (`memory/state/`) — the compaction-recovery chain. Consumed, kept.
- **Canonical project memory** (`data/projects/`, ~3.1 MB) — small, structured, and
  genuinely referenced. **Explicitly out of scope here and unaffected.** This decision is
  about `memory/learning/` and nothing else.

Reflection itself is not the problem and is not removed. The LEARN phase still runs and
still asks its four questions; what changes is that the answers inform the session that
produced them and the human reading it, rather than being filed somewhere nothing reads.

### Corpus

The existing `memory/learning/` tree is **retained and frozen**, not deleted:

- It lives outside this repository, under the user's `~/.locus/data/`. Nothing in this
  change touches it.
- **DEV-515** (the falsification spike) may want it as evidence. Deleting the only
  dataset that could retrospectively justify or refute Option B, on the same day we
  conclude it has no demonstrated value, would destroy the ability to check that
  conclusion.

Archival or deletion is a separate, deliberate act requiring the owner's go-ahead —
the 122 MB `FAILURES/` tree in particular should be assessed on its own, as DEV-516 notes.

### Reversal condition

If DEV-515 shows that recorded learnings measurably improve later task outcomes, reopen
as Option B — but build retrieval *first*, prove a recalled learning changed a session's
behaviour, and only then restore the mandatory write.
