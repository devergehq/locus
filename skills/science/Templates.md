# Science Templates

Fill-in templates for each phase of the Science cycle. Use them directly or as prompts for generating more specific artifacts.

## Goal template

```markdown
### Goal

**What success looks like:**
<specific, measurable, falsifiable, time-bounded statement>

**Metric:**
<the specific number that would confirm success>

**Baseline:**
<current value of the metric>

**Target:**
<the value that would count as success>

**Deadline:**
<when this is assessed>

**Counter-examples:**
<what outcomes would count as failure, not just "less success">
```

## Hypothesis template

```markdown
### Hypothesis <N>

**Statement:**
"If <intervention>, then <outcome> will <change direction> by <magnitude>, because <causal mechanism>."

**Confidence (prior):**
<low / medium / high — with one-sentence justification>

**What would refute it:**
<specific observations that would disprove this hypothesis>

**Assumptions being made:**
<list — unchecked facts that, if false, invalidate the hypothesis>
```

Always generate at least three hypotheses. One is a guess; three is a trade-space.

## Experiment template

```markdown
### Experiment: <Hypothesis ref>

**Design:**
<the actual intervention — what you'll do differently>

**Independent variable:**
<what you're changing>

**Dependent variable:**
<what you're measuring>

**Control:**
<what stays the same / what you compare against>

**Duration:**
<how long the test runs>

**Success criterion:**
<the threshold at which you'll call the hypothesis supported>

**Blinding / bias mitigation:**
<how you avoid measuring what you hope to see>

**Cost of running:**
<time, money, user-facing risk>
```

## Results template

```markdown
### Results: <Experiment ref>

**What actually happened:**
<prose summary of observations>

**Metric values:**
| Condition  | Baseline | Measured | Δ      |
|------------|----------|----------|--------|
| <group>    | <x>      | <y>      | <diff> |

**Statistical note:**
<confidence interval, sample size, or "underpowered" if relevant>

**Unexpected observations:**
<things you noticed that weren't predicted>

**Hypothesis status:**
- Supported / Refuted / Underdetermined
- Evidence strength: <low / medium / high>

**Next step:**
<what the analysis phase should ask next>
```

## Analysis template

```markdown
### Analysis

**Goal check:**
Did the measured result satisfy the success criterion? <Yes / No / Partially>

**Hypothesis verdict:**
<Supported / Refuted / Underdetermined>, with <one-sentence justification grounded in the data>

**Counter-interpretations:**
<alternative explanations for the measured outcome>

**Lessons:**
- <what you now know that you did not before>
- <what assumption was surfaced as wrong>
- <what still needs testing>

**Next hypothesis / next experiment:**
<what comes next in the cycle>
```

## Full cycle template (compact)

For quick iterations where full templates are overkill:

```markdown
### Cycle <N> — <one-line goal>

- **Goal:** <specific+measurable+deadline>
- **Hypothesis:** <if-then-because>
- **Experiment:** <smallest test that could falsify>
- **Result:** <what happened, in numbers>
- **Verdict:** <supported / refuted / underdetermined>
- **Next:** <what comes next>
```
