# Quick Research Workflow

**Single researcher, single focused query. Fastest mode.**

## When to use

- Factual lookup — "what version of X does Y require?"
- API documentation — "what parameters does this endpoint accept?"
- Well-scoped single-question research — no ambiguity about what's being asked.
- User explicitly says "quick research" or just asks a concrete question.

**Not for** multi-perspective analysis, contested domains, or decision support. Escalate to Standard or Extensive.

## Execution

### Step 1 — One query, one researcher

Choose the single best-fit methodology for the question:

- Factual / technical lookup → academic-researcher
- Specific person / event / organisation → investigative-researcher
- Counter-consensus check → contrarian-researcher
- Genuinely multi-faceted (rare in Quick) → multi-angle-researcher

If in doubt, use `academic-researcher` — it has the highest citation discipline and the fewest failure modes for crisp questions.

### Step 2 — Single focused query

Craft one query. Be specific. "Bash read command flags" is a weak query; "`read -t` flag behaviour on macOS Bash 3.2 vs Bash 5" is a good Quick query — specific enough to get a precise answer.

### Step 3 — Delegate via `locus delegate run`

**The skill orchestrates; OpenCode does the research.** Compose the prompt with `locus agent compose`, then dispatch a single `locus delegate run` Bash call. The trait bundle below picks the chosen methodology's canonical composition (per `agents/{methodology}-researcher.md`).

**DO NOT use the platform-native Task tool for this step.** Task subagents are other Claudes burning the same context budget. Use `locus delegate run --backend opencode --mode native` so the heavy work runs out-of-context and only a compact envelope returns.

Pick the trait bundle for the chosen methodology:

| Methodology               | Trait bundle                                                |
|---------------------------|-------------------------------------------------------------|
| academic-researcher       | `research,empirical,rationalist,systematic,skeptical`       |
| investigative-researcher  | `research,skeptical,contrarian,exploratory`                 |
| contrarian-researcher     | `research,contrarian,skeptical,adversarial`                 |
| multi-angle-researcher    | `research,exploratory,iterative,analogical`                 |

Then:

```bash
PROMPT=$(locus agent compose \
  --traits "<bundle from table above>" \
  --role "<methodology> researcher" \
  --task "<the focused query>")

locus delegate run \
  --backend opencode \
  --task-kind research \
  --mode native \
  --dir . \
  --prompt "$PROMPT" \
  --output json
```

The returned JSON envelope has `summary`, `findings`, `evidence`, `files_referenced`. Use those directly.

### Step 4 — Verify URLs

Per `UrlVerificationProtocol.md` — even for a single result. One hallucinated URL is still catastrophic.

### Step 5 — Return

```markdown
## Research (Quick): <question>

### Answer
<direct answer to the question>

### Source
- <verified URL>

### Confidence
<High / Medium / Low — one-sentence justification>

### Caveats
<anything the answer doesn't cover>
```

## Speed target

~10-15 seconds.

## Escalation

If the Quick answer surfaces ambiguity, multiple credible interpretations, or contested evidence, recommend the caller escalate to Standard.
