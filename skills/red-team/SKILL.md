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

## Execution model

**The red-team skill is the orchestrator. Each attacker runs in OpenCode via `locus delegate run --mode native`.**

The orchestrator (this Claude session) is responsible for:
- Picking the attacker roster — trait bundles chosen for **diversity of attack vector** (security, contrarian, adversarial, systematic, etc.)
- Composing each attacker's prompt via `locus agent compose --traits ... --role ... --task ...` with the proposal text inlined
- Dispatching all attackers in a single assistant message (parallel)
- Synthesising convergent insights, steelman, and counter-argument from the collected attack envelopes

Each attacker dispatch shape:

```bash
PROMPT=$(locus agent compose \
  --traits "<attack-vector trait bundle>" \
  --role "Red-team attacker: <vector name>" \
  --task "<workflow-specific task; see workflow files>")

locus delegate run \
  --backend opencode \
  --task-kind general \
  --mode native \
  --dir . \
  --prompt "$PROMPT" \
  --output json
```

**Why:** attackers reasoning in their own context produce more honest adversarial diversity than Task subagents that share the orchestrator's context (which subtly biases them toward the orchestrator's existing framing). Distinct provider + per-attacker trait composition + structured envelope is the red-team's adversarial contract.

**DO NOT use the platform-native Task tool for attacker dispatch.** Task subagents burn the orchestrator's context budget AND inherit its framing. Use `locus delegate run --mode native` so each attacker comes in cold.

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

- **With `locus delegate run` available**: full parallel adversarial fanout — up to 8-12 `locus delegate run` calls in one assistant message, each attacker on a distinct vector.
- **`locus delegate run` rate-limited**: degrade to sequential per-attacker dispatch (slower; lose the parallelism benefit but keep the per-attacker context isolation).
- **`locus delegate run` not on PATH**: red-team degrades to in-context simulation by the orchestrator (lossy — adversarial diversity is reduced because all attackers share the orchestrator's framing). Surface the degradation in the output and recommend the caller fix the runtime before treating the result as load-bearing.
