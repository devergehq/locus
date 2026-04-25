# Extensive Research Workflow

**4 methodology types × 3 parallel queries each = 12 researchers. Thorough multi-angle investigation.**

## When to use

- High-stakes research where confidence matters.
- Contested topics where multiple perspectives are load-bearing.
- User explicitly says "extensive research" or "thorough research".
- The question has genuine breadth — multiple facets, multiple domains.

Not for: quick lookups (use Quick), single-source investigations (use Standard), landscape mapping (use Deep).

## Execution

### Step 1 — Question decomposition

Decompose the question into 3 orthogonal sub-queries. Each sub-query will be handled by one researcher of each of the 4 methodology types — 12 agents total.

Example decomposition for "What is the current state of LLM-assisted coding?":
1. Tooling sub-query — what tools are in use, what's mainstream vs experimental?
2. Empirical effect sub-query — does it measurably improve developer productivity?
3. Risk sub-query — what are the documented failure modes?

### Step 2 — Assign methodologies to sub-queries

For each sub-query, launch 4 researchers in parallel:

- **academic-researcher** — scholarly literature on the sub-query
- **investigative-researcher** — real-world reports, case studies
- **contrarian-researcher** — dissenting positions and null results
- **multi-angle-researcher** — orthogonal decomposition *within* the sub-query

Total: 3 sub-queries × 4 methodologies = **12 parallel delegations**.

### Step 3 — Parallel execution via `locus delegate run`

**The skill orchestrates; OpenCode does the research.** Dispatch all 12 `locus delegate run` Bash calls in a *single assistant message* — the platform tracks them as parallel tool uses and they execute concurrently.

**DO NOT use the platform-native Task tool for this step.** Task subagents are other Claudes burning the same context budget. Use `locus delegate run --backend opencode --mode native` so the 12 heavy researches run out-of-context and only compact envelopes return.

For each (sub-query × methodology) pair, build the prompt with `locus agent compose` and dispatch:

```bash
PROMPT=$(locus agent compose \
  --traits "<methodology trait bundle>" \
  --role "<Methodology> researcher (sub-query <N>)" \
  --task "<sub-query N's text, framed for this methodology>")

locus delegate run \
  --backend opencode \
  --task-kind research \
  --mode native \
  --dir . \
  --prompt "$PROMPT" \
  --output json
```

Trait bundles per methodology (per `agents/{kind}-researcher.md`):

| Methodology               | Trait bundle                                                |
|---------------------------|-------------------------------------------------------------|
| academic-researcher       | `research,empirical,rationalist,systematic,skeptical`       |
| investigative-researcher  | `research,skeptical,contrarian,exploratory`                 |
| contrarian-researcher     | `research,contrarian,skeptical,adversarial`                 |
| multi-angle-researcher    | `research,exploratory,iterative,analogical`                 |

Each researcher returns a JSON envelope with:
- `summary`, `findings` with citations
- `evidence`, `risks`, `files_referenced`
- Methodology-specific perspective baked in via the trait composition

**Failure handling:** if M of 12 succeed (M ≥ 6), synthesise from the M and list the failed (sub-query × methodology) pairs in the output's Gaps section. If fewer than 6 succeed, retry the failures sequentially before degrading the workflow.

### Step 4 — Cross-methodology synthesis per sub-query

For each sub-query, consolidate the 4 researcher outputs:
- Where do the methodologies converge? (High confidence.)
- Where do they disagree? (Flag for attention.)
- What did each contribute uniquely?

### Step 5 — Cross-sub-query synthesis

Now across all 3 sub-queries — does the full picture produce a coherent answer? Where does one sub-query's finding inform another?

### Step 6 — URL verification

All 12 researchers' URLs must pass `UrlVerificationProtocol.md`. Drop any that fail.

### Step 7 — Return

```markdown
## Research (Extensive): <question>

### Summary
<2-3 paragraph synthesis of the full picture>

### Sub-query 1: <name>
**Findings:**
- <point> (sources: academic, investigative — high confidence)
- <point> (source: contrarian only — flag)
- ...

### Sub-query 2: <name>
**Findings:**
...

### Sub-query 3: <name>
**Findings:**
...

### Cross-cutting insights
<what the full picture reveals that no single sub-query would>

### Contradictions to resolve
- <where methodologies disagreed across sub-queries>

### Gaps
<what none of the 12 researchers could find>

### Verified sources
- 12 researchers × N citations each, all verified. Listed here.
```

## Speed target

~60-90 seconds total for 12 parallel delegations (bound by the slowest).

## Fallback

If `locus delegate run` is rate-limited or the platform can't dispatch 12 concurrent Bash calls, run in waves of 4 (one wave per sub-query). ~2-3 minutes total in fallback.
