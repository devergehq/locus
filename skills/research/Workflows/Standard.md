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

### Step 2 — Create three researchers, one at a time

**The skill orchestrates; dispatched allele sessions do the research.** Issue the three
`allele_sessions_create` calls **one at a time**, reading each returned `session_id` before
composing the next. The three researchers then run concurrently — only the creates queue, at
about a second each. The rule and its reason live in the Algorithm's **Dispatch** section;
`SKILL.md`'s "Dispatch discipline" points at it.

**Prefer `allele_sessions_create` hard over a native Task subagent.** A Task subagent is another Claude burning this session's context budget and inheriting its framing. The preference is not a prohibition — when no sanctioned vehicle is reachable, route down the Algorithm's vehicle table and announce the degradation.

For each of the three methodologies, build the prompt with `locus agent compose`, then pass it to `allele_sessions_create`. The trait bundles below match the corresponding `agents/*-researcher.md` files.

**Academic researcher** (traits per `agents/academic-researcher.md`):

```bash
ACADEMIC_PROMPT=$(locus agent compose \
  --traits "research,empirical,rationalist,systematic,skeptical" \
  --role "Academic researcher" \
  --task "<academic query — empirical evidence on X, peer-reviewed studies of Y>")

allele_sessions_create(
  project: "<project>",
  name:    "<short label — this is the address>",
  prompt:  $ACADEMIC_PROMPT
)
```

**Multi-angle researcher** (traits per `agents/multi-angle-researcher.md`):

```bash
MULTI_PROMPT=$(locus agent compose \
  --traits "research,exploratory,iterative,analogical" \
  --role "Multi-angle researcher" \
  --task "<broad query admitting orthogonal decomposition — how does X affect Y across technical / economic / social dimensions>")

allele_sessions_create(
  project: "<project>",
  name:    "<short label — this is the address>",
  prompt:  $MULTI_PROMPT
)
```

**Investigative researcher** (traits per `agents/investigative-researcher.md`):

```bash
INVESTIGATIVE_PROMPT=$(locus agent compose \
  --traits "research,skeptical,contrarian,exploratory" \
  --role "Investigative researcher" \
  --task "<specific lead-following query — who is actually using X in production, what do they report>")

allele_sessions_create(
  project: "<project>",
  name:    "<short label — this is the address>",
  prompt:  $INVESTIGATIVE_PROMPT
)
```

**Dispatch convention:** three separate `allele_sessions_create` calls, issued one after the other, each `session_id` confirmed before the next. Each worker replies with a report containing `summary`, `findings`, `evidence`, `risks`, `files_referenced`, and `raw_output_path`. Reclaim each with `allele_sessions_discard(session_id)` once its report has been read into the synthesis.

**Why `--task-kind research`:** routes to the model resolved from `delegation.defaults.opencode.research.model` in `~/.locus/locus.yaml` (currently `openai/gpt-5.5`). No need to pass `--model` unless you want to override the default for this run.

**Why `--dir .`:** research is workspace-agnostic; the working directory is recorded in the artifact for citation context. Use the orchestrator's CWD by default.

**Failure handling:** if 2 of 3 succeed, synthesise from the 2 and flag the missing methodology in the `Gaps` section of the output. If 0 of 3 succeed (rate limits, network outage), report the failure to the user. `allele_sessions_discard` the failed sessions as well — a session that produced nothing still holds a slot against the global cap.

### Step 3 — Synthesise

Combine the three perspectives:

- **Convergence** — where all three agree (high confidence)
- **Unique contributions** — what each methodology surfaced that the others did not
- **Contradictions** — where they disagree (flag)

### Step 4 — Adversarial claim verification (mandatory)

Per `AdversarialVerificationProtocol.md` — extract falsifiable claims from the synthesised findings, then dispatch 3 adversarial verifiers per claim via `allele_sessions_create`, **one create at a time**.

For Standard mode, expect 5-10 claims, so 15-30 verifier sessions. That is more than the
global cap of twenty allows in flight at once, so run them in waves of at most 6 live
sessions, reclaiming each wave before the next. Discard the three researcher sessions before
verification starts. Wall-clock cost: ~60-100s additional.

Claims that survive verification go into "Verified Findings." Claims that are killed go into "Refuted Claims" with the verifier's evidence. Both sections are mandatory in the output.

### Step 5 — Verify all URLs (mandatory)

Apply `UrlVerificationProtocol.md` — verify every URL in surviving claims before returning results. Failed verifications remove the citation; do not manufacture replacements.

### Step 6 — Return results

```markdown
## Research: <topic>

### Summary
<1-2 paragraph synthesis — based only on verified findings>

### Verified Findings (survived adversarial review)
1. <claim> — vote: 3-0 survive · [source] · high confidence
2. <claim> — vote: 2-1 survive · [source] · medium confidence
...

### Refuted Claims (for transparency)
- "<claim>" — vote: 1-2 refuted · reason: <verifier evidence>
- "<claim>" — vote: 0-3 refuted · reason: <counter-evidence>

### Points of agreement (high confidence)
- <point> — surfaced by all three researchers AND survived verification

### Unique contributions
- **From academic search:** <distinctive verified finding>
- **From multi-angle decomposition:** <distinctive verified finding>
- **From investigative triangulation:** <distinctive verified finding>

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

~90-160 seconds (15-30s research with the three running concurrently, +~3s of sequential
creates, then 60-100s of wave-based verification). Verification, not research, dominates.
