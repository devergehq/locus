# Define Goal Workflow

**Force a vague request into a specific, measurable, falsifiable, time-bounded goal.** Use when the requester has stated an intent but not a success criterion.

## Why this matters

Without a goal, you cannot judge results. Vague goals ("make it better", "improve performance") guarantee vague outcomes — any result can be rationalised as progress. The most common cause of wasted engineering effort is starting work before the goal is specific.

## Execution

### 1. Parse the stated intent

Write down what the requester actually said. Do not interpret yet.

### 2. Identify the ambiguity

For each term in the stated intent, ask:

- What does this mean concretely?
- How would it be measured?
- At what threshold is it "enough"?

"Make it faster" — how much faster? For which operation? Under what conditions? Measured how?

"Improve quality" — which quality dimension? Test coverage? Readability? User-reported defects?

### 3. Propose candidate goals (≥3)

Generate at least three candidate goals at different specificity / ambition levels:

- **Minimum viable:** the smallest change that could count as success
- **Ambitious:** what success would look like with room to spare
- **Stretch:** a goal only achievable with substantial investment

Each candidate fills the Goal template from `Templates.md`.

### 4. Confirm with requester

Present the candidates. The requester picks one or refines. Do not proceed without explicit agreement — assumed goals are the source of late-stage rework.

### 5. Write down the confirmed goal

Record the final goal in the task's PRD `## Context` section. The goal is now the reference against which all later work is judged.

## Output

```markdown
### Stated intent
"<original request, verbatim>"

### Ambiguity surfaced
- <term>: <what it could mean>
- <term>: <what it could mean>

### Candidate goals
1. **Minimum:** <filled Goal template>
2. **Ambitious:** <filled Goal template>
3. **Stretch:** <filled Goal template>

### Confirmed goal
<the one the requester selected, possibly with edits>

### Why this version
<one sentence on why the other candidates were rejected>
```

## Anti-patterns

- **Choosing ambition without checking.** A stretch goal the requester didn't want wastes time.
- **Accepting vague goals after one round of clarification.** If still vague, iterate.
- **Treating an example as the goal.** "Like X" is not a goal — derive the measurable criterion behind the example.
