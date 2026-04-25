# Standard Research Workflow

**Default research mode: 3 methodology-diverse researchers in parallel, 1 query each.**

## When to use

- User says "research this" / "do research" with no specific depth modifier.
- Need multiple perspectives quickly.
- The topic has more than one credible framing.

## Execution

### Step 1 — Craft one query per methodology

The three methodologies chosen for Standard mode are picked for *diversity of approach*, not diversity of source API. Default set:

- **academic-researcher** — scholarly-source bias, citation discipline
- **multi-angle-researcher** — orthogonal sub-query decomposition
- **investigative-researcher** — triangulation, follow-the-lead

If the topic is notably contested or has entrenched consensus, swap one in for **contrarian-researcher**.

Craft one focused query per methodology — each should be tuned to that methodology's strengths:

- Academic query: framed for scholarly search ("empirical evidence on X", "peer-reviewed studies of Y")
- Multi-angle query: broad enough to admit orthogonal decomposition ("how does X affect Y across technical / economic / social dimensions")
- Investigative query: specific enough to follow leads ("who is actually using X in production and what do they report")

### Step 2 — Launch three delegations in parallel via `locus delegate run`

**The skill orchestrates; OpenCode does the research.** Dispatch three `locus delegate run` Bash tool calls in a single assistant message — the platform tracks them as parallel tool uses and they execute concurrently.

**DO NOT use the platform-native Task tool for this step.** Task subagents are other Claudes burning the same context budget. Use `locus delegate run --backend opencode` so the raw research happens out-of-context and only a compact envelope returns.

For each of the three methodologies, build the prompt with `locus agent compose`, then pass it to `locus delegate run`. The trait bundles below match the corresponding `agents/*-researcher.md` files.

**Academic researcher** (traits per `agents/academic-researcher.md`):

```bash
ACADEMIC_PROMPT=$(locus agent compose \
  --traits "research,empirical,rationalist,systematic,skeptical" \
  --role "Academic researcher" \
  --task "<academic query — empirical evidence on X, peer-reviewed studies of Y>")

locus delegate run \
  --backend opencode \
  --task-kind research \
  --dir . \
  --prompt "$ACADEMIC_PROMPT" \
  --output json
```

**Multi-angle researcher** (traits per `agents/multi-angle-researcher.md`):

```bash
MULTI_PROMPT=$(locus agent compose \
  --traits "research,exploratory,iterative,analogical" \
  --role "Multi-angle researcher" \
  --task "<broad query admitting orthogonal decomposition — how does X affect Y across technical / economic / social dimensions>")

locus delegate run \
  --backend opencode \
  --task-kind research \
  --dir . \
  --prompt "$MULTI_PROMPT" \
  --output json
```

**Investigative researcher** (traits per `agents/investigative-researcher.md`):

```bash
INVESTIGATIVE_PROMPT=$(locus agent compose \
  --traits "research,skeptical,contrarian,exploratory" \
  --role "Investigative researcher" \
  --task "<specific lead-following query — who is actually using X in production, what do they report>")

locus delegate run \
  --backend opencode \
  --task-kind research \
  --dir . \
  --prompt "$INVESTIGATIVE_PROMPT" \
  --output json
```

**Dispatch convention:** put all three Bash calls in the *same assistant message* so the platform parallelises them. Each call returns a JSON envelope on stdout with `summary`, `findings`, `evidence`, `risks`, `files_referenced`, and `raw_output_path`.

**Why `--task-kind research`:** routes to the model resolved from `delegation.defaults.opencode.research.model` in `~/.locus/locus.yaml` (currently `openai/gpt-5.5`). No need to pass `--model` unless you want to override the default for this run.

**Why `--dir .`:** research is workspace-agnostic; the working directory is recorded in the artifact for citation context. Use the orchestrator's CWD by default.

**Failure handling:** if 2 of 3 succeed, synthesise from the 2 and flag the missing methodology in the `Gaps` section of the output. If 0 of 3 succeed (rate limits, network outage), report the failure to the user and offer to retry sequentially (`Workflows/Quick.md` mode times three).

### Step 3 — Synthesise

Combine the three perspectives:

- **Convergence** — where all three agree (high confidence)
- **Unique contributions** — what each methodology surfaced that the others did not
- **Contradictions** — where they disagree (flag)

### Step 4 — Verify all URLs (mandatory)

Apply `UrlVerificationProtocol.md` — verify every URL before returning results. Failed verifications remove the citation; do not manufacture replacements.

### Step 5 — Return results

```markdown
## Research: <topic>

### Summary
<1-2 paragraph synthesis>

### Findings
1. <finding> — [verified citation]
2. ...

### Points of agreement (high confidence)
- <point> — surfaced by all three researchers

### Unique contributions
- **From academic search:** <distinctive finding>
- **From multi-angle decomposition:** <distinctive finding>
- **From investigative triangulation:** <distinctive finding>

### Contradictions
- <where sources disagreed, flagged>

### Gaps
- <what couldn't be found>

### Sources
- <verified URL 1>
- <verified URL 2>
- ...
```

## Speed target

~15-30 seconds for delegated parallel execution.
