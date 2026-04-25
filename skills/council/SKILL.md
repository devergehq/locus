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

## Execution model

**The council skill is the orchestrator. Each member runs in OpenCode via `locus delegate run --mode native`.**

The orchestrator (this Claude session) is responsible for:
- Choosing the member roster (default: Architect + Engineer + Designer + Researcher; modify per `CouncilMembers.md`)
- Composing each member's per-round prompt via `locus agent compose --traits ... --role ... --task ...`
- Inlining the prior round's transcript into each subsequent round's `--task` text
- Synthesising the final council recommendation from the collected member responses

Each round dispatches N parallel `locus delegate run` calls (one per member) in a single assistant message. The platform parallelises them; each returns a JSON envelope with the member's response in `summary`. Only the synthesised transcript enters the orchestrator's context — the raw model deliberation stays out-of-process.

**Why:** members reasoning in their own context produces more honest perspective diversity than Task subagents that share the orchestrator's full context. Distinct provider + structured envelope + per-member trait composition is the council's epistemic contract.

**DO NOT use the platform-native Task tool for member dispatch.** See `RoundStructure.md` for the canonical dispatch idiom.

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

- **With `locus delegate run` available**: full parallel multi-agent debate; each round is N concurrent `locus delegate run` calls in one assistant message.
- **`locus delegate run` rate-limited**: degrade to sequential per-member dispatch within each round (slower; each round becomes ~N×single-call latency instead of one wave).
- **`locus delegate run` not on PATH**: council degrades to in-context simulation by the orchestrator (lossy — perspective diversity is reduced because all members share the orchestrator's context). Surface the degradation in the output.
