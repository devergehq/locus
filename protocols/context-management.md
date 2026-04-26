# Context Management Protocol

How Locus manages context window usage across long sessions.

## Principles

1. **Context is finite.** Every AI model has a context window. Long sessions degrade quality as the window fills with stale information.
2. **Checkpoint aggressively.** Write state to disk so it survives compaction.
3. **Delegate investigation through Locus.** Exploratory work uses `locus delegate run`; only compact results enter the main context.
4. **Summarise at phase boundaries.** At each Algorithm phase transition (Extended+ effort), compress accumulated context.

## Checkpointing

At each Algorithm phase transition, write a checkpoint file to `{data}/memory/state/`:

```markdown
---
timestamp: {ISO 8601}
task: {task description}
phase: {current phase}
effort: {effort level}
progress: {N/M criteria}
---

## ISC Status
{list each criterion with pass/fail/pending}

## Key Results
{numbers, decisions, code references from this phase}

## Next Actions
{what the next phase should do}
```

## Context Compaction

When accumulated tool outputs and reasoning exceed ~60% of the working context:

**Preserve:**
- ISC criteria status (which passed/failed/pending)
- Key results (numbers, decisions, file paths, code references)
- Current phase and next actions

**Discard:**
- Verbose tool output
- Intermediate reasoning
- Raw search results
- Repeated information

## Recovery

If context is lost after compaction:
1. Read the most recent checkpoint from `{data}/memory/state/`
2. Read the PRD from `{data}/memory/work/{slug}/PRD.md`
3. PRD frontmatter + criteria checkboxes contain the full state
