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

### Step 3 — Delegate via `allele_sessions_create`

**The skill orchestrates; a dispatched allele session does the research.** Compose the prompt with `locus agent compose`, then issue a single `allele_sessions_create`. The trait bundle below picks the chosen methodology's canonical composition (per `agents/{methodology}-researcher.md`).

**Prefer `allele_sessions_create` hard over a native Task subagent.** A Task subagent is another Claude burning this session's context budget and inheriting its framing. The preference is not a prohibition — when no sanctioned vehicle is reachable, route down the Algorithm's vehicle table and announce the degradation.

Pick the trait bundle for the chosen methodology:

| Methodology               | Trait bundle                                                |
|---------------------------|-------------------------------------------------------------|
| academic-researcher       | `research,empirical,rationalist,systematic,skeptical`       |
| investigative-researcher  | `research,skeptical,contrarian,exploratory`                 |
| contrarian-researcher     | `research,contrarian,skeptical,adversarial`                 |
| multi-angle-researcher    | `research,exploratory,iterative,analogical`                 |

Then:

**1 — compose the worker's prompt.** Run this and read its output:

```bash
locus agent compose \
  --traits "<bundle from table above>" \
  --role "<methodology> researcher" \
  --task "<the focused query>"
```

**2 — dispatch it.** Pass the composed text as `prompt`:

```
allele_sessions_create(
  project: "<project>",
  name:    "<short label — this becomes the address>",
  prompt:  "<the composed prompt from step 1>"
)
```

The report carries `summary`, `findings`, `evidence`, `files_referenced`. Use those directly, then `allele_sessions_discard(session_id)` — Quick mode has no second pass that needs the session.

### Step 4 — Adversarial claim verification

Per `AdversarialVerificationProtocol.md` — extract falsifiable claims from the findings, then dispatch 3 adversarial verifiers per claim via `allele_sessions_create`, **one create at a time**. Even Quick mode produces claims worth pressure-testing — a single unchecked wrong answer is worse than a slower correct one.

For Quick mode, expect 2-4 claims, so 6-12 verifier sessions. Run them in waves of at most 6 live sessions, discarding each wave before the next. Wall-clock cost: ~20-40s additional.

### Step 5 — Verify URLs

Per `UrlVerificationProtocol.md` — on surviving claims only. One hallucinated URL is still catastrophic.

### Step 6 — Return

```markdown
## Research (Quick): <question>

### Answer
<direct answer to the question>

### Verified Findings (survived adversarial review)
1. <claim> — vote: N-M survive · [source] · confidence

### Refuted Claims (for transparency)
- "<claim>" — vote: N-M refuted · reason

### Source
- <verified URL>

### Confidence
<High / Medium / Low — one-sentence justification>

### Caveats
<anything the answer doesn't cover>
```

## Speed target

~35-50 seconds (15s research + 20-40s verification, including ~1s per sequential create).

## Escalation

If the Quick answer surfaces ambiguity, multiple credible interpretations, or contested evidence, recommend the caller escalate to Standard.
