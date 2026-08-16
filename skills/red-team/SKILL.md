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

**The red-team skill is the orchestrator. Each attacker runs in OpenCode via `allele_sessions_create`.**

The orchestrator (this Claude session) is responsible for:
- Picking the attacker roster — trait bundles chosen for **diversity of attack vector** (security, contrarian, adversarial, systematic, etc.)
- Composing each attacker's prompt via `locus agent compose --traits ... --role ... --task ...` with the proposal text inlined
- Dispatching all attackers in a single assistant message (parallel)
- Synthesising convergent insights, steelman, and counter-argument from the collected attack reports

Each attacker dispatch shape:

**1 — compose the worker's prompt.** Run this and read its output:

```bash
locus agent compose \
  --traits "<attack-vector trait bundle>" \
  --role "Red-team attacker: <vector name>" \
  --task "<workflow-specific task; see workflow files>"
```

**2 — dispatch it.** Pass the composed text as `prompt`:

```
allele_sessions_create(
  project: "<project>",
  name:    "<short label — this becomes the address>",
  prompt:  "<the composed prompt from step 1>"
)
```

**Why:** attackers reasoning in their own context produce more honest adversarial diversity than Task subagents that share the orchestrator's context (which subtly biases them toward the orchestrator's existing framing). Per-attacker trait composition + a fresh context per attacker + a structured report is the red-team's adversarial contract.

**DO NOT use the platform-native Task tool for attacker dispatch.** Task subagents burn the orchestrator's context budget AND inherit its framing. Use `allele_sessions_create` so each attacker comes in cold.

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

- **With `allele_sessions_create` available**: full parallel adversarial fanout — up to 8-12 `allele_sessions_create` calls in one assistant message, each attacker on a distinct vector.
- **`allele_sessions_create` rate-limited**: degrade to sequential per-attacker dispatch (slower; lose the parallelism benefit but keep the per-attacker context isolation).
- **`allele_sessions_create` not on PATH**: red-team degrades to in-context simulation by the orchestrator (lossy — adversarial diversity is reduced because all attackers share the orchestrator's framing). Surface the degradation in the output and recommend the caller fix the runtime before treating the result as load-bearing.
