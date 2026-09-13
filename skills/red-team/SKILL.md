---
id: red-team
name: Red Team
description: Adversarial analysis to find weaknesses, fatal flaws, and failure modes in ideas, designs, and arguments.
triggers:
  - red team
  - attack idea
  - critique
  - stress test
  - poke holes
  - devil's advocate
  - find weaknesses
  - break this
  - what could go wrong
  - what am I missing
  - tear this apart
  - find the flaws
  - why would this fail
tags:
  - thinking
  - adversarial
  - quality
requires:
  delegation: true
---

# Red Team

Adversarial analysis that spawns multiple attack agents to find fatal flaws in ideas, designs, arguments, and implementations. Unlike Council (collaborative-adversarial), Red Team is purely adversarial — its job is to destroy weak arguments.

## Dispatch discipline

This skill does not restate the dispatch rules. Restated rules drift — this file used to
tell the orchestrator to fire 8-12 `allele_sessions_create` calls in one assistant message,
which is precisely what the canonical rule forbids. The canonical text is the **Dispatch**
section of `algorithm/v2.0.md`, shipped as the `locus-algorithm` skill. Read it there.

Two of its rules bind every dispatch in this skill and its workflows:

- **One `allele_sessions_create` at a time**, with its result read before the next is
  issued. Never batch creates into a single assistant message.
- **Every attacker you dispatch is reclaimed** with `allele_sessions_discard` once its
  report is collected, or recorded as still working with a reason.

**Do not "optimise" this back to a parallel fanout.** The win is real and it is about eleven
seconds across twelve attackers; the cost, the last time this skill was run as written, was
an overlapping create returning another caller's `session_id` — mis-filed dispatch
attribution, five sessions that refused to discard, and one attacker holding another
worker's reviewer. The workers still run concurrently either way. Only the creates queue.
The full argument, and the condition under which the rule may be retired, is in the
Algorithm's Dispatch section.

## Execution model

**The red-team skill is the orchestrator. Each attacker runs in its own dispatched allele
session — its own context, its own workspace.**

The orchestrator (this Claude session) is responsible for:
- Picking the attacker roster — trait bundles chosen for **diversity of attack vector** (security, contrarian, adversarial, systematic, etc.)
- Composing each attacker's prompt via `locus agent compose --traits ... --role ... --task ...` with the proposal text inlined
- Dispatching the attackers **one at a time**, confirming each `session_id` before composing the next
- Synthesising convergent insights, steelman, and counter-argument from the collected attack reports
- Reclaiming every attacker session once its report is in

Each attacker dispatch shape:

**1 — compose the worker's prompt.** Run this and read its output:

```bash
locus agent compose \
  --traits "<attack-vector trait bundle>" \
  --role "Red-team attacker: <vector name>" \
  --task "<workflow-specific task; see workflow files>"
```

**2 — dispatch it.** Pass the composed text as `prompt`. One call, on its own, and read
the returned `session_id` before composing the next attacker:

```
allele_sessions_create(
  project: "<project>",
  name:    "<short label — this becomes the address>",
  prompt:  "<the composed prompt from step 1>"
)
```

**3 — reclaim it.** When the attacker's report has been read into the synthesis, call
`allele_sessions_discard(session_id)`. An attacker left running holds a slot against the
global cap and becomes invisible work nobody owns.

**Why:** attackers reasoning in their own context produce more honest adversarial diversity than Task subagents that share the orchestrator's context (which subtly biases them toward the orchestrator's existing framing). Per-attacker trait composition + a fresh context per attacker + a structured report is the red-team's adversarial contract.

**Prefer `allele_sessions_create` hard over a native Task subagent.** Task subagents burn the orchestrator's context budget and inherit its framing, which is fatal to a red team specifically — correlated attackers produce convergence that means nothing. But the preference is not a prohibition: when no sanctioned vehicle is reachable, route down the Algorithm's vehicle table and announce the degradation, rather than stalling.

## Process

1. **Steelman first** — Build the strongest possible version of the argument
2. **Attack from multiple angles** — Each agent attacks from a different vector:
   - Logical fallacies and reasoning errors
   - Missing edge cases and failure modes
   - Scalability and performance concerns
   - Security and trust assumptions
   - Market and competitive reality
   - Technical feasibility
   - User experience failure
   - Regulatory and compliance gaps
3. **Synthesise** — Rank findings by severity, identify fatal vs survivable flaws

## Degradation

Route down the Algorithm's **Which vehicle** table and stop at the first available row; the
rows below say only what red-team specifically loses at each one.

- **Allele reachable** (tier 1): full adversarial roster, 8-12 attackers on distinct vectors, dispatched one create at a time. Attackers run concurrently once created; the creates do not.
- **Allele reachable but every slot taken**: busy is not absent. Wait, or reclaim a slot with `allele_sessions_discard`. Do not drop to a less observable vehicle because the system is busy.
- **`locus delegate run --backend opencode`** (tier 2): attackers still come in cold with their own trait composition, but there is no session to question and no follow-up. Say so.
- **Native `Task` subagents** (tier 3, last resort): adversarial diversity is materially reduced — attackers share the orchestrator's framing, so convergence stops being evidence. State that in the output before the findings, not after.
- **Nothing reachable**: say red-team is unavailable and name the roster you would have dispatched. In-context simulation by the orchestrator is not a red team; do not present it as one.

The `allele_*` tools are MCP tools, not a binary — their absence means allele is not running
and this session is outside it, which is a normal way to run Locus rather than a broken
install.
