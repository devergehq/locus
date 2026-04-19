# Memory Schema

How Locus persists and organises knowledge across sessions.

## Directory Structure

```
{data}/
├── memory/
│   ├── work/              # PRDs and work artifacts
│   │   └── {slug}/
│   │       └── PRD.md
│   ├── learning/          # Session learnings
│   │   └── session/
│   │       └── {YYYY-MM}/
│   │           └── {YYYYMMDD}-{HHMMSS}_{slug}.md
│   ├── research/          # Research output archives
│   │   └── {YYYY-MM}/
│   │       └── {YYYYMMDD}-{HHMMSS}_{slug}.md
│   └── state/             # Runtime state (ephemeral, not synced)
│       └── checkpoint-{timestamp}.md
├── projects/              # Per-project memory
│   └── {project-slug}/
│       └── memory.md
├── context-packs/         # Optional identity/org context
│   ├── personal/
│   └── org/
└── skill-customizations/  # Per-skill user overrides
    └── {skill-id}/
        └── preferences.yaml
```

## Learning Entry Format

```markdown
---
timestamp: {ISO 8601}
task: {task description}
project: {project path or name}
effort: {effort level}
category: SESSION
---

# Learnings: {task description}

## Insights

- {insight 1}
- {insight 2}

## Context

{1-2 sentences on what was built/changed}
```

## Project Memory

Each project can have persistent memory at `{data}/projects/{slug}/memory.md`. This contains:
- Architectural decisions and their rationale
- Known conventions and patterns
- Tech stack and dependency notes
- Previous work context

Project memory is automatically loaded when working in a recognised project directory.

## Sync

- `memory/work/`, `memory/learning/`, `memory/research/`, `projects/`, `context-packs/`, `skill-customizations/` are synced between machines
- `memory/state/` is ephemeral and NOT synced (checkpoints are machine-local)
- Sync uses git — `locus sync` is sugar over commit + push/pull
- Conflicts: append-only files (learnings, research) use last-write-wins; PRDs use manual merge
