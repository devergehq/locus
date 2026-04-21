---
id: delegation
name: Delegation
description: Parallelise work via background/foreground agents, trait-composed custom agents, worktree-isolated agents, and two-tier (lightweight vs full) delegation. USE WHEN 3+ independent workstreams, parallel execution, agent specialisation, Extended+ effort, agent team, swarm, create an agent team.
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
- **Codebase changes spanning 5+ files** benefit from parallel workers.
- **Research and execution** can proceed simultaneously.
- **Adversarial validation** — Red Team's parallel attackers.
- **Multi-perspective debate** — Council's parallel members.

**Do not delegate** when:

- A single Grep/Glob/Read would answer the question in seconds.
- The task is a single file change with no research needed.
- Fewer than 3 workstreams would genuinely parallelise.
- The spawned agent would start with zero useful context.

## Patterns

### 1. Foreground delegation (default)

Standard delegation — the spawning agent blocks until the delegated agent completes. Use when you need the result before proceeding.

```
<platform-native Task tool with subagent_type="engineer" or similar>
```

### 2. Background delegation

Non-blocking. The spawning agent continues immediately; results read later. Use when results aren't needed immediately.

Good for: research during implementation, long builds, parallel investigations.

### 3. Parallel dispatch

N identical operations launched in a single message, results collected when all complete. Use for uniform work (e.g., "update this pattern in 12 files" — one agent per file).

### 4. Worktree-isolated delegation

Each agent gets its own git worktree. Files edited by different agents do not conflict. Auto-cleaned when the agent finishes (unless it committed changes).

Good for: multiple agents editing the same files, competing approaches to the same change, file-safe parallelism.

Composable with background + parallel dispatch.

### 5. Trait-composed custom agents

When the work needs specialist cognitive profiles that don't match the 16 built-in archetypes, compose custom agents via `locus agent compose`:

```bash
locus agent compose --traits "security,skeptical,thorough" \
                    --role "Auth reviewer" \
                    --task "Review the auth module for injection risks"
```

The output is a composed prompt that combines trait fragments from `agents/traits.yaml`. Feed this into the platform's delegation mechanism as the agent's system prompt.

### 6. Agent teams (platform-native coordination)

When the platform supports persistent multi-agent coordination (e.g., Claude Code's `TeamCreate`), use it for Extended+ tasks that benefit from shared state, task lists, and multi-turn messaging.

Agent teams differ from parallel dispatch: teams persist, coordinate, and collaborate; parallel dispatch is fire-and-forget.

Trigger phrases: "create an agent team", "swarm", "team of agents".

## Two-tier delegation

Not every delegation needs a full agent. Match delegation weight to task complexity.

### Lightweight delegation

For: one-shot extraction, classification, summarisation, simple Q&A against provided content.

- Use the platform's **smallest fast model** (e.g., Haiku for Claude).
- Cap turns at 3 — if it can't finish in 3 turns, it needs full delegation.
- Provide all input inline in the prompt (no tool-use expected).

Examples: "classify this text as X/Y/Z", "extract the 5 key points from this article", "summarise this in 2 sentences".

### Full delegation

For: multi-step reasoning, tasks requiring tool use (file reads, searches, web), tasks that need their own iteration loop.

- Default model (Sonnet/Opus).
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
| Standard      | 1-2 foreground agents max for discrete subtasks              |
| Extended      | 2-4 agents; background for research                          |
| Advanced      | 4-8 agents; agent teams for 3+ workstreams                   |
| Deep          | Full team orchestration, parallel workers, background + fg   |
| Comprehensive | Unbounded — teams + parallel + background + worktrees        |

## Anti-patterns

- **Delegating what Grep/Glob/Read does in <2 seconds.**
- **Spawning agents for single-file changes.**
- **Creating teams for fewer than 3 independent workstreams.**
- **Sending agents work without full context** — they start fresh.
- **Using built-in agent archetypes (Architect, Engineer) when the task actually needs a custom trait bundle.**
- **Using full delegation for one-shot extraction/classification** — use lightweight tier.
- **Parallelising dependent work** — if B needs A's output, they can't run in parallel.

## Composition

Delegation is used by most other skills:

- **Council, RedTeam** — invoke parallel delegation for members/attackers
- **Research (Extensive, Deep)** — parallel research agents
- **IterativeDepth (Extended+)** — parallel lens agents
- **Algorithm BUILD phase** — delegates investigative subtasks per the Context Management Protocol
