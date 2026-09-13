---
id: council
name: Council
description: Multi-agent debate with structured rounds where specialised agents challenge each other's positions and converge on recommendations.
triggers:
  - council
  - debate
  - perspectives
  - weigh options
  - deliberate
  - multiple viewpoints
  - should we use X or Y
  - pros and cons
  - which approach
  - trade-offs between
  - compare these options
  - help me decide
  - rank the options
  - weighted decision
tags:
  - thinking
  - multi-agent
  - decision-making
requires:
  delegation: true
---

# Council

Multi-agent debate system where specialised agents discuss topics in structured rounds, respond to each other's actual arguments, and surface insights through intellectual friction.

## Dispatch discipline

This skill does not restate the dispatch rules — restated rules drift. The canonical text is
the **Dispatch** section of `algorithm/v2.0.md`, shipped as the `locus-algorithm` skill. Two
of its rules bind every dispatch here:

- **One `allele_sessions_create` at a time**, with its result read before the next is
  issued. Never batch creates into a single assistant message. The members deliberate
  concurrently either way; only the creates queue, at about a second each.
- **Every member session is reclaimed** with `allele_sessions_discard` after the final
  round, or recorded as still working with a reason.

## Execution model

**The council skill is the orchestrator. Each member runs in its own dispatched allele
session, created once and conversed with across all three rounds.**

The orchestrator (this Claude session) is responsible for:
- Choosing the member roster (default: Architect + Engineer + Designer + Researcher; modify per `CouncilMembers.md`)
- Composing each member's opening prompt via `locus agent compose --traits ... --role ... --task ...`
- Dispatching the members **one create at a time**, confirming each `session_id` before composing the next
- Carrying the prior round's transcript to each member with `SendMessage`, not by creating a new session
- Synthesising the final council recommendation from the collected member responses
- Discarding every member session once Round 3 is collected

**One session per member, not one per member per round.** A four-member debate is four
sessions, not twelve. Creating fresh sessions each round triples the slot cost against the
global cap of twenty, throws away the member's memory of its own position — which is what
Rounds 2 and 3 are asking it to revisit — and leaves eight orphans nobody reclaims.

**Why dispatch at all:** members reasoning in their own context produce more honest
perspective diversity than Task subagents that share the orchestrator's full context.
Per-member trait composition + a fresh context per member + a structured report is the
council's epistemic contract.

**Prefer `allele_sessions_create` hard over a native Task subagent** — correlated members
produce agreement that means nothing. The preference is not a prohibition: when no
sanctioned vehicle is reachable, route down the Algorithm's vehicle table and announce the
degradation. See `RoundStructure.md` for the dispatch idiom.

## Workflows

### Debate
Full 3-round structured debate with visible transcript.

**Round 1 — Initial Positions:** Each agent gives their perspective. No interaction yet.
**Round 2 — Responses & Challenges:** Each agent reads Round 1 and responds to specific points. Genuine engagement with others' arguments.
**Round 3 — Synthesis:** Each agent identifies convergence, remaining disagreements, and final recommendation.

Optional **Round 4 — Weighted Decision Analysis:** Pairwise comparison of competing positions, criteria scoring (Feasibility 30%, Impact 30%, Risk 20%, Alignment 20%), ranked recommendations with confidence levels.

### Quick
Single-round perspective check. Each agent gives a brief take. Fast consensus or flag for full debate.

## Default Council Members

| Role | Perspective |
|------|------------|
| Architect | System design, patterns, long-term implications |
| Engineer | Implementation reality, tech debt, practical constraints |
| Researcher | Data, precedent, external examples |
| Designer | User experience, accessibility, user needs |

Additional roles can be added based on topic (Security, Writer, etc.).

## Degradation

Route down the Algorithm's **Which vehicle** table and stop at the first available row; the
rows below say only what council specifically loses at each one.

- **Allele reachable** (tier 1): full debate. N members created one at a time, then conversed with across three rounds.
- **Allele reachable but every slot taken**: busy is not absent. Wait, or reclaim a slot with `allele_sessions_discard`. Slot pressure never unlocks a less observable vehicle.
- **`locus delegate run --backend opencode`** (tier 2): members still get their own context and trait composition, but there is no session to talk to — so Rounds 2 and 3 must re-send the full transcript in a fresh one-shot call each time. Say so.
- **Native `Task` subagents** (tier 3, last resort): perspective diversity is materially reduced because all members share the orchestrator's framing. Convergence between them stops being evidence. State that above the synthesis, not below it.
- **Nothing reachable**: say council is unavailable and name the roster you would have convened. In-context simulation by one model playing four parts is not a council; do not present its agreement as convergence.

The `allele_*` tools are MCP tools, not a binary — their absence means allele is not running
and this session is outside it, which is a normal way to run Locus rather than a broken
install.
