# Interview Research Workflow

**Prepare for an in-depth interview with a specific person — research their work, positions, recent writing, and the sharp questions that would make the interview valuable.**

Modelled on Tyler Cowen-style interview preparation: surface the subject's specific views, find the tensions in their thinking, and generate questions that have not been asked a hundred times before.

## When to use

- Preparing to interview someone — podcast, profile, hiring conversation, customer call.
- Need to engage with a specific thinker's positions, not general information.

## Execution

### Step 1 — Subject scoping

Identify the subject and the interview frame:

- **Who** — full name, current role.
- **What for** — what is the interview's topic? What is the angle?
- **Prior interviews** — what have they already been asked? (So you can avoid those.)
- **Format** — podcast / written / short call — affects question shape.

### Step 2 — Researcher assignment (parallel delegation)

Three methodology-diverse researchers, each tuned to a different facet of the subject:

1. **Academic researcher** — subject's papers, public academic work, intellectual lineage.
2. **Investigative researcher** — subject's recent work, projects, public statements, controversies or reversals of position.
3. **Contrarian researcher** — positions where the subject's view diverges from consensus or from their own past views.

**The skill orchestrates; OpenCode does the research.** Dispatch all three `locus delegate run` Bash tool calls in a single assistant message — the platform tracks them as parallel tool uses and they execute concurrently.

**DO NOT use the platform-native Task tool for this step.** Task subagents are other Claudes burning the same context budget. Use `locus delegate run --backend opencode --mode native` so the raw research happens out-of-context and only a compact envelope returns.

Substitute `<subject>` in each prompt with the subject's full name plus a one-line role descriptor (e.g., `"Jane Doe, computational biologist at MIT"`). Build each prompt with `locus agent compose` and dispatch all three blocks in a single assistant message:

```bash
ACADEMIC_PROMPT=$(locus agent compose \
  --traits "research,empirical,rationalist,systematic,skeptical" \
  --role "Academic researcher" \
  --task "<subject>'s published work, papers, and intellectual lineage. Surface the specific positions they have argued in print, with citations.")

locus delegate run \
  --backend opencode \
  --task-kind research \
  --mode native \
  --dir . \
  --prompt "$ACADEMIC_PROMPT" \
  --output json
```

```bash
INVESTIGATIVE_PROMPT=$(locus agent compose \
  --traits "research,skeptical,contrarian,exploratory" \
  --role "Investigative researcher" \
  --task "<subject>'s recent work, projects, public statements over the last 24 months. Flag controversies, reversals of position, or unfinished arguments.")

locus delegate run \
  --backend opencode \
  --task-kind research \
  --mode native \
  --dir . \
  --prompt "$INVESTIGATIVE_PROMPT" \
  --output json
```

```bash
CONTRARIAN_PROMPT=$(locus agent compose \
  --traits "research,contrarian,skeptical,adversarial" \
  --role "Contrarian researcher" \
  --task "Positions where <subject> diverges from consensus, or from their own earlier views. Identify the strongest critics of those positions and what those critics actually argue.")

locus delegate run \
  --backend opencode \
  --task-kind research \
  --mode native \
  --dir . \
  --prompt "$CONTRARIAN_PROMPT" \
  --output json
```

Each call returns a JSON envelope on stdout with `summary`, `findings`, `evidence`, `risks`, `files_referenced`, and `raw_output_path`.

**Failure handling:** if 2 of 3 succeed, generate questions from the 2 and flag the missing methodology in the output. If 0 of 3 succeed, report failure and offer to retry sequentially.

### Step 3 — Generate candidate questions

From the three researcher outputs, produce **three classes** of questions:

1. **Specific to their work** — questions only they can answer meaningfully.
2. **Tension points** — places where two of their views are in apparent conflict; invite them to reconcile.
3. **Counterfactuals** — "What would change your mind about X?" / "Who is the strongest critic of your view on Y, and what is their best point?"

Avoid:

- Questions they have been asked repeatedly in prior interviews.
- Generic questions ("What advice would you give to your younger self?").
- Questions that require them to say something controversial without context.

### Step 4 — Ordering

Sequence questions for a conversational arc:

- Open with one grounding question that confirms you've done the homework.
- Move into specific-to-their-work territory.
- Surface tensions in the middle, when rapport is established.
- Close with a question that asks them to look forward.

### Step 5 — Output

```markdown
## Interview Prep: <Subject>

### Subject profile
<1-paragraph summary — role, recent work, interview angle>

### Intellectual positions
- <key position> — source
- <key position> — source

### Tensions
- **Tension:** <position A> vs. <position B>. Possible reconciliation: <speculation>.
- **Tension:** ...

### Prior interview themes (to avoid repeating)
- <theme> — asked by <interviewer> on <date>
- ...

### Candidate questions

**Opening:**
1. <grounding question>

**Specific to their work:**
2. <question>
3. <question>

**Tension points:**
4. <question — surface the tension>
5. <question>

**Counterfactual / forward-looking:**
6. <question>

### Verified sources
- <URL 1>
- <URL 2>
- ...
```

## Speed target

~60-90 seconds for the three parallel researchers; 2-3 minutes total including question generation.
