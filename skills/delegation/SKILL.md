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

Work that is *dispatched* leaves this session by becoming a **real allele session** —
visible in the sidebar, interruptible, takeable-over, with its own workspace and branch.
Dispatch is one of three routes, not the only sanctioned one; see the routing table in
`protocols/orchestration.md` for when native subagents are the right call instead.

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

## Execution rule — route, do not prohibit

There is no blanket ban on native subagents. There is a routing decision, and getting it
wrong in either direction costs something. The full table lives in
`protocols/orchestration.md`; the short form:

- **Writes anything** (code, commits, PRs), needs a host-only tool, or needs tight
  interactive latency → **native subagent**. `locus delegate run` is read-only, so routing
  implementation work to it routes it nowhere.
- **Adversarial, multi-perspective, or an independent second opinion** → **dispatch**. A
  native subagent inherits this session's framing and fails the same way this session
  fails; correlated errors cannot serve as a check.
- **Needs its own workspace or branch**, or is a 5+ file sweep whose conclusion is all that
  matters here → **dispatch**.
- **A single Grep/Glob/Read answers it**, it is one file change with no research, it depends
  on context already loaded here that is costly to transfer, or you are at depth 3 →
  **do it here.**

Whichever route you take, it must stay visible to the human.

## The lifecycle

```
1. compose   locus agent compose --traits "..." --role "..." --task "..."
2. dispatch  allele_sessions_create(project, name, prompt)   -> session_id, name
3. address   ListAgents -> "name [ref]"        fresh, every send; refs rotate
4. converse  SendMessage(to: "name [ref]", ...)
5. check     allele_sessions_status(session_id) -> state == "response_ready"
6. reclaim   allele_sessions_discard(session_id)
```

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

**`session_id` is the only durable identity.** Names are stable in practice; refs are not
stable at all and rotate wholesale. Never cache an address. A rejected send means
"re-resolve and retry", not failure.

**Never conclude a worker is finished from `ListAgents`.** It collapses six states into
idle/busy. `response_ready` means finished; `awaiting_input` means blocked on a permission
prompt with nobody coming unless a human acts. `state_age_secs` tells you *blocked for
forty minutes*, which is actionable, rather than *blocked*, which is not.

**Discard when done.** `allele_sessions_discard` commits uncommitted work and archives the
branch before removing the workspace, so reclaiming a slot never loses anything. A session
left running holds a slot and becomes invisible work nobody owns.

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

- **Depth 3.** Depth 0 is a human-started session; it dispatches workers at depth 1; those
  may dispatch specialists at depth 2; depth 3 is the floor and does not dispatch. Beyond
  that the original intent is too diluted through rounds of telephone to be worth having.
- **Global cap 20** concurrent dispatched sessions, aggregate across every dispatcher. Per-
  dispatcher caps do not compose — twenty dispatchers each under a limit of twenty is four
  hundred sessions, every one individually compliant.
- Both are enforced by allele and derived from the creating session's own record. Depth is
  never caller-supplied.

## Patterns

### 1. Parallel fan-out

N independent workers dispatched in one message, each with its own trait composition.
Use for uniform work across separate subsystems, or for perspective diversity.

Dispatch all of them, then converse with each as results arrive — do not serialise on the
slowest.

### 2. Conversational delegation

The point of dispatch over a one-shot call: the worker can come back with a question, and
you can answer it. Brief it, let it work, respond to what it raises, and iterate.

**Send your reasoning and your queries, not only your conclusions.** A conclusion cannot be
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

For Extended+ tasks, dispatch several workers as a batch. The orchestrator owns
coordination, synthesis, criteria tracking, and follow-up edits.

Workers in a batch do not coordinate with each other by default. They can — every session
can reach every other by name — but unstructured cross-talk drifts and launders
accountability. Keep exchanges purposeful and attributable.

Trigger phrases: "create an agent team", "swarm", "team of agents".

## When allele is not available

The allele MCP talks to a socket allele binds at startup. If the `allele_*` tools are not
present, **allele is not running and this session is outside it** — a plain terminal,
`claude.ai/code`, CI, or allele simply closed. That is a normal way to run Locus, not an
error.

**Fall back to `locus delegate run`, and say which mode you are in.**

```bash
locus agent compose --traits "..." --role "..." --task "..."   # unchanged
locus delegate run --backend opencode --task-kind general --mode native \
  --dir . --prompt "<composed prompt>" --output json
```

You lose the session — no workspace, no branch, no conversation, and it returns an envelope
rather than replying. You keep delegation, which is the thing that matters. Say so once, in
the shape `protocols/degradation.md` requires, rather than silently producing lesser work:

```
Dispatch normally creates real allele sessions. allele is not available here,
so this is running through `locus delegate run` instead: read-only, no branch,
and no way to ask the worker a follow-up question.
```

Work the routing table sends to **native** is unaffected — that route never depended on
allele. Do not abandon routing and do the work inline because one mechanism is missing.

Note `locus delegate run` is **not** a security boundary — see the warning in
`orchestration.md`. It is the standalone path, not the safe one.

## What this is not

- **Not free-form agent conversation.** Messages carry findings, decisions, questions and
  corrections. Unbounded chat drifts and makes it impossible to tell afterwards who decided
  what.
- **Not a way around permissions.** Never ask a peer to do work blocked in your own session.
  Route it back to the human instead.
- **Not invisible.** Everything lands in the sidebar. An orchestrator quietly running a
  fleet is worse than the manual version even when it is faster.
