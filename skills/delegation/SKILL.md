---
id: delegation
name: Delegation
description: Parallelise read-only work via Locus Delegate workers, trait-composed prompts, parallel dispatch, and two-tier (lightweight vs full) delegation. USE WHEN 3+ independent workstreams, parallel execution, agent specialisation, Extended+ effort, agent team, swarm, create an agent team.
triggers:
  - delegation
  - parallelise
  - parallel agents
  - agent team
  - swarm
  - spin up agents
  - launch agents
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

Delegation is *not* a license for sprawl — each delegated agent pays an overhead (context transfer, startup latency, coordination). Use this skill when the task meaningfully benefits from parallelism, specialisation, or isolation.

## When to delegate

Delegate when any of these hold:

- **3+ independent workstreams** at Extended+ effort.
- **Multiple identical non-serial tasks** (update 12 files with same pattern).
- **Specialisation needed** (security review for auth, design review for UI, architecture review for structural changes).
- **Codebase investigation spanning 5+ files** benefits from parallel workers.
- **Research and implementation** can proceed without polluting orchestrator context.
- **Adversarial validation** — Red Team's parallel attackers.
- **Multi-perspective debate** — Council's parallel members.

**Do not delegate** when:

- A single Grep/Glob/Read would answer the question in seconds.
- The task is a single file change with no research needed.
- Fewer than 3 workstreams would genuinely parallelise.
- The spawned agent would start with zero useful context.

## Execution Rule

All agent-style delegation MUST use `locus delegate run`. Do not use platform-native Task, Agent, or Team tools for Locus delegation. If `locus delegate run` is unavailable or failing, do not fall back to native subagents; continue serially or ask the user how to proceed.

## Patterns

### 1. Foreground Locus Delegate (default)

Standard delegation — the spawning agent blocks until the delegated agent completes. Use when you need the result before proceeding.

```bash
locus delegate run \
  --backend opencode \
  --task-kind general \
  --mode native \
  --dir . \
  --prompt "<bounded read-only task>" \
  --output json
```

### 2. Parallel dispatch

N independent operations launched as separate `locus delegate run` Bash calls in one assistant message, results collected when all complete. Use for uniform read-only work, such as mapping separate subsystems.

### 3. Bounded context delegation

Pass only the files or prompt context the worker needs. Use `--context-file` for concrete references and keep the prompt narrow.

Good for: research during implementation, documentation digestion, parallel investigations.

### 4. Artifact-isolated delegation

Each delegated run writes artifacts under its delegation artifact directory. The orchestrator reads the compact JSON envelope first and opens raw artifacts only if necessary.

Good for: large research sweeps, codebase maps, source digests.

Delegation is currently read-only. Do not send workers tasks that require editing files, committing, or mutating persistent state.

### 5. Trait-composed custom agents

When the work needs specialist cognitive profiles that don't match the 16 built-in archetypes, compose custom agents via `locus agent compose`:

```bash
locus agent compose --traits "security,skeptical,thorough" \
                    --role "Auth reviewer" \
                    --task "Review the auth module for injection risks"
```

The output is a composed prompt that combines trait fragments from `agents/traits.yaml`. Pass this prompt to `locus delegate run --prompt`.

### 6. Agent batches

For Extended+ tasks, run multiple Locus Delegate workers as a batch. The orchestrator owns coordination, synthesis, criteria tracking, and any follow-up edits.

Agent batches differ from persistent teams: workers do not coordinate with each other. They return compact envelopes to the orchestrator.

Trigger phrases: "create an agent team", "swarm", "team of agents".

## Two-tier delegation

Not every delegation needs a full agent. Match delegation weight to task complexity.

### Lightweight delegation

For: one-shot extraction, classification, summarisation, simple Q&A against provided content.

- Use a smaller configured `--model` when appropriate.
- Cap turns at 3 — if it can't finish in 3 turns, it needs full delegation.
- Provide all input inline in the prompt (no tool-use expected).

Examples: "classify this text as X/Y/Z", "extract the 5 key points from this article", "summarise this in 2 sentences".

### Full delegation

For: multi-step reasoning, tasks requiring tool use (file reads, searches, web), tasks that need their own iteration loop.

- Use the configured default model or pass `--model` explicitly.
- No turn cap — agent iterates until done.
- Agent uses tools autonomously.

Examples: "research X and produce a report", "refactor these 5 files", "debug why test Y fails".

### Decision rule

Ask: *"Can this be answered in one LLM call with no tool use?"* → Lightweight. Otherwise → Full.

| Signal                                              | Tier        |
|-----------------------------------------------------|-------------|
| Input fits in prompt; output is extraction          | Lightweight |
| Needs to read files, search, or browse              | Full        |
| Needs iteration or self-correction                  | Full        |
| Simple transform of provided content                | Lightweight |
| Requires domain expertise + research                | Full        |

**Why this matters:** full delegation carries ~10-30s of startup + context overhead. Lightweight returns in 2-5s. Over an Extended+ Algorithm run with 10+ delegations, the difference is minutes. Pattern inspired by the RLM two-tier `llm_query()` / `rlm_query()` design (Zhang/Kraska/Khattab 2025).

## Effort-level scaling

| Effort        | Delegation strategy                                          |
|---------------|--------------------------------------------------------------|
| Minimal       | No delegation — direct tools only                            |
| Standard      | 1-2 Locus Delegate workers max for discrete subtasks         |
| Extended      | 2-4 workers; parallel research or exploration                |
| Advanced      | 4-8 workers for 3+ independent workstreams                   |
| Deep          | Multi-wave delegation with orchestrator-owned synthesis      |
| Comprehensive | Unbounded only when bounded prompts and synthesis are clear  |

## Anti-patterns

- **Delegating what Grep/Glob/Read does in <2 seconds.**
- **Spawning agents for single-file changes.**
- **Creating teams for fewer than 3 independent workstreams.**
- **Sending agents work without full context** — they start fresh.
- **Using built-in agent archetypes (Architect, Engineer) when the task actually needs a custom trait bundle.**
- **Using full delegation for one-shot extraction/classification** — use lightweight tier.
- **Using platform-native Task/Agent tools** — use `locus delegate run` instead.
- **Parallelising dependent work** — if B needs A's output, they can't run in parallel.

## Composition

Delegation is used by most other skills:

- **Council, RedTeam** — invoke parallel delegation for members/attackers
- **Research (Extensive, Deep)** — parallel research agents
- **IterativeDepth (Extended+)** — parallel lens agents
- **Algorithm BUILD phase** — delegates investigative subtasks per the Context Management Protocol
