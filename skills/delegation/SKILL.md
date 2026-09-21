---
id: delegation
name: Delegation
description: Parallelise work by dispatching real allele sessions — trait-composed prompts, inter-session conversation, and slot reclamation. USE WHEN 3+ independent workstreams, parallel execution, agent specialisation, Extended+ effort, agent team, swarm, create an agent team.
triggers:
  - delegation
  - parallelise
  - parallel agents
  - agent team
  - swarm
  - spin up agents
  - launch agents
  - dispatch a session
  - 3+ workstreams
  - Extended+ effort
tags:
  - orchestration
  - parallel
  - multi-agent
requires:
  delegation: true
---

# Delegation

**Auto-invoked by the Algorithm when work can be parallelised or requires agent specialisation.**

Work leaves this session by becoming a **real allele session** — visible in the sidebar,
interruptible, takeable-over, with its own workspace and branch. Not a subagent, not a
hidden process, nothing the human cannot see.

Delegation is *not* a license for sprawl. Each session costs a workspace, a slot against
the global cap, and coordination attention. Dispatch when the work genuinely benefits from
parallelism, specialisation, isolation, or an independent perspective.

## When to delegate

- **3+ independent workstreams** at Extended+ effort.
- **Multiple identical non-serial tasks** (the same change across 12 files).
- **Specialisation needed** — security review for auth, design review for UI.
- **Codebase investigation spanning 5+ files.**
- **Work that must produce its own commits** on its own branch.
- **Adversarial validation** — Red Team's parallel attackers.
- **Multi-perspective debate** — Council's members.
- **A blocker you cannot resolve here** — dispatch an investigation rather than stalling.

**Do not delegate** when:

- A single Grep/Glob/Read answers it in seconds.
- The task is one file change with no research needed.
- The work depends on context already loaded here that would be expensive to transfer.
- You are at depth 3.

## The rules are not here

The dispatch rules — the lifecycle, addressing, status semantics, the vehicle table, depth,
the global cap, reclamation — live in one place: the **Dispatch** section of
`algorithm/v2.0.md`, shipped as the `locus-algorithm` skill. Read them there.

This file used to restate them. That is how it came to carry a flat ban on native subagents
months after the Algorithm replaced that ban with a routing table, and a "parallel fan-out"
pattern that told orchestrators to do the exact thing the canonical rule forbids. Restated
rules drift; a pointer cannot.

Four of the canonical rules are worth naming here because every pattern below depends on
them, but the canonical text is still the Algorithm's:

- **One `allele_sessions_create` at a time**, its result read before the next is issued.
  Never batch creates into a single assistant message. Workers run concurrently either way.
- **Route down the vehicle table** when allele is not reachable, and announce the row you
  landed on. A native subagent is permitted as a last resort — it is not forbidden, it is
  expensive, and taking it silently is the actual failure.
- **`allele_sessions_status`, never `ListAgents`**, to decide whether a worker has finished.
- **Every dispatched session is reclaimed** with `allele_sessions_discard`, or recorded as
  still working with a reason.

## What this skill adds

**Compose then dispatch.** Run `locus agent compose` in Bash, read its output, and pass that
text as the `prompt` argument to `allele_sessions_create`. Trait composition is what makes
workers actually think differently — it is doing more work than any other lever here.

```bash
locus agent compose \
  --traits "security,skeptical,thorough" \
  --role "Auth reviewer" \
  --task "Review the auth module for injection risks"
```

**Keep the prompt short.** Orientation plus an artifact URL beats a long inline brief — one
atomic paste with nothing to interleave, and a truncated brief produces a session that
starts confidently on half a specification.

**`state_age_secs` is the field worth knowing about.** The Algorithm tells you to use
`allele_sessions_status` rather than `ListAgents`; the reason to actually read its output is
that it tells you *blocked for forty minutes*, which is actionable, rather than *blocked*,
which is not.

## The report contract

A dispatched session does not return a value — it *replies*. So ask for the shape you need,
in the dispatch prompt, and every downstream step keeps working:

```
When you have finished, SendMessage back to me with exactly these sections:

summary           one paragraph — your answer
findings          bulleted observations
evidence          concrete references you actually checked (file:line, URL, command output)
risks             caveats, limits, things you could not verify
files_referenced  paths you read or named
```

This is the same shape the old out-of-process envelope had, which is deliberate: it keeps
synthesis, rubric-building and dossier-writing unchanged. The difference is that it is now
a **request** rather than something a tool guarantees — so state it explicitly, and if a
worker replies without it, ask again rather than parsing prose.

**`evidence` is load-bearing.** A worker reporting a conclusion cannot be checked; one
reporting the command it ran and the output it saw can. Ask for the method, not the verdict.

## Limits

Depth 3 and a global cap of 20 concurrent sessions, both enforced by allele and both
specified in the Algorithm's Dispatch section. The consequence worth planning around: the
cap is *aggregate across every dispatcher on the machine*, so a twelve-worker fan-out is
most of the machine's capacity and not merely most of yours.

## Patterns

### 1. Fan-out

N independent workers, each with its own trait composition. Use for uniform work across
separate subsystems, or for perspective diversity.

**Create them one at a time** — one `allele_sessions_create`, read the `session_id`, then
the next. Then converse with each as results arrive; do not serialise on the slowest. The
workers overlap; only the creates queue, at about a second each.

The two are easy to confuse, and the confusion is what this skill previously shipped. "Fan
out N workers" is a statement about how the *work* runs. "N creates in one message" is a
statement about how the *claims* are issued, and it is the one that broke — see the
Algorithm's Dispatch section for the incident and for why the rule has no exception clause.

**Size the fan-out against the cap, not against the task.** Eight live workers is a
comfortable ceiling for one dispatcher; beyond that, run waves and reclaim each wave with
`allele_sessions_discard` before starting the next.

### 2. Conversational delegation

The point of dispatch over a one-shot call: the worker can come back with a question, and
you can answer it. Brief it, let it work, respond to what it raises, and iterate.

**Send your working and your queries, not only your conclusions.** A conclusion cannot be
checked; a method can. Corrections travel in both directions — a worker correcting the
orchestrator is the normal case.

### 3. Blocker resolution

A worker that hits something it cannot resolve has three options and should prefer them in
this order: answer it locally, route it to whoever holds scope authority, or dispatch an
investigation of its own. It should not stall.

### 4. Specialisation via traits

When the work needs a cognitive profile the built-in archetypes do not match, compose one.
Pick 2-4 traits across axes — one expertise, one stance, one approach is the standard shape.

### 5. Agent batches

For Extended+ tasks, dispatch several workers as a batch — created one at a time, running
concurrently. The orchestrator owns coordination, synthesis, criteria tracking, follow-up
edits, and reclaiming every session in the batch when it is done.

Workers in a batch do not coordinate with each other by default. They can — every session
can reach every other by name — but unstructured cross-talk drifts and launders
accountability. Keep exchanges purposeful and attributable.

Trigger phrases: "create an agent team", "swarm", "team of agents".

## When allele is not available

The allele MCP talks to a socket allele binds at startup. If the `allele_*` tools are not
present, **allele is not running and this session is outside it** — a plain terminal,
`claude.ai/code`, CI, or allele simply closed. That is a normal way to run Locus, not an
error.

**Route down the Algorithm's vehicle table and announce the row you landed on.** The table,
its tiers and the argument for each are canonical there and deliberately not copied here.
Two points specific to composing workers:

- `locus agent compose` is unchanged at every tier. Trait composition is the lever that
  survives degradation; it is worth keeping even when the session does not.
- Tier 2 (`locus delegate run --backend opencode`) returns an envelope rather than replying,
  so the report contract below becomes a request you cannot follow up on. Ask for the shape
  anyway, and say in the output that you could not question the answer.

Declare the degradation in the shape `protocols/degradation.md` requires, rather than
silently producing lesser work.

Note `locus delegate run` is **not** a security boundary — see the warning in
`protocols/orchestration.md`. It is the standalone path, not the safe one.

## What this is not

- **Not free-form agent conversation.** Messages carry findings, decisions, questions and
  corrections. Unbounded chat drifts and makes it impossible to tell afterwards who decided
  what.
- **Not a way around permissions.** Never ask a peer to do work blocked in your own session.
  Route it back to the human instead.
- **Not invisible.** Everything lands in the sidebar. An orchestrator quietly running a
  fleet is worse than the manual version even when it is faster.
