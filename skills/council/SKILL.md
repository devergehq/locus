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

- **With delegation**: Full parallel multi-agent debate.
- **Without delegation**: Unavailable. Council requires multiple agents debating simultaneously.
