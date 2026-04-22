# Science — Methodology

The Science skill applies the scientific method as a universal problem-solving algorithm. It is the meta-skill from which others derive discipline.

## The universal cycle

```
GOAL         → What does success look like?
 ↓
OBSERVE      → What is the current state?
 ↓
HYPOTHESIZE  → What might work? (Always plural.)
 ↓
EXPERIMENT   → Design and run a test.
 ↓
MEASURE      → What happened? (Data collection.)
 ↓
ANALYZE      → How does it compare to the goal?
 ↓
ITERATE      → Adjust hypothesis; repeat.
 ↓
<back to HYPOTHESIZE>
```

## Phase-by-phase detail

### Goal (the anchor)

Without clear success criteria, you cannot judge results. A goal is:

- **Specific** — "reduce login latency from 3s to under 1s" not "make login faster"
- **Measurable** — there is a metric you can compute
- **Falsifiable** — there are outcomes that would count as "not achieved"
- **Time-bounded** — "by Friday" or "within one deployment cycle"

A vague goal guarantees vague results. If the goal cannot be made specific, the real problem is that the desired outcome is not yet understood.

### Observe (current state)

Before any hypothesis, know the current state:

- Current metric value (baseline).
- Current behaviour under various conditions.
- Variation — how does the metric move normally? What's the noise floor?

Skipping baseline observation makes it impossible to distinguish "intervention worked" from "noise".

### Hypothesize (always plural)

**Never propose one idea when three would surface the trade-space.** The first hypothesis is usually wrong or incomplete. Generate at least 3 before committing to one.

Good hypotheses share:

- **Causal form:** "If X, then Y will change by Z" (not just "X is bad").
- **Specificity:** name the variable, the expected direction, the magnitude.
- **Falsifiability:** there is an outcome that would disprove this hypothesis.

### Experiment (minimum viable test)

Design the smallest experiment that could falsify the hypothesis:

- What is the independent variable — what are you changing?
- What is the dependent variable — what are you measuring?
- What is the control — what stays the same?
- What is the blinding — can you avoid biasing the measurement?

The minimum viable experiment is the one that:

- Produces a clear signal within reasonable time.
- Doesn't require hidden dependencies to succeed.
- Can fail honestly.

### Measure (goal-relevant data only)

Collect only the data relevant to the hypothesis. Over-instrumentation produces noise and tempts p-hacking later.

Collect **before** looking at results — decide what counts as success and failure up front.

### Analyze (honest comparison)

Compare measured results to the goal:

- Did the hypothesised change happen?
- In the hypothesised direction?
- To the hypothesised magnitude?
- Were there unexpected side effects?

Honest analysis distinguishes:

- **Supported** — evidence favours the hypothesis.
- **Refuted** — evidence contradicts the hypothesis.
- **Underdetermined** — noise was too high, or the experiment didn't actually test the claim.

Underdetermined is a valid and common outcome. Calling underdetermined results "supported" is the most common failure of this phase.

### Iterate

Based on analysis:

- If refuted — what's the next hypothesis?
- If underdetermined — design a better experiment.
- If supported — confirm with a larger test before generalising; a single supporting result is not proof.

Cycle until the goal is reached or the problem is understood to be different from the one originally framed.

## Relationship to the Algorithm

The Locus Algorithm is a specialised application of this cycle:

- OBSERVE ↔ Observe
- THINK ↔ Hypothesize (multiple hypotheses via premortem + risks)
- PLAN ↔ Experiment design
- BUILD/EXECUTE ↔ Run the experiment
- VERIFY ↔ Measure + Analyze
- LEARN ↔ Iterate

The Algorithm's ISC Count Gate is the Science discipline of "specify success before starting" applied to task execution.

## Anti-patterns

| Anti-pattern                                | Correction                                         |
|---------------------------------------------|----------------------------------------------------|
| "Make it better"                            | "Reduce X from A to B by C"                        |
| "I think X will work"                       | "Here are 3 approaches — X, Y, Z — test each"      |
| "Prove I'm right"                           | "Design a test that could disprove"                |
| Selective reporting of supporting data      | Pre-commit to the metric and reporting method      |
| Indefinite experimentation                  | Ship and learn from production observations        |
