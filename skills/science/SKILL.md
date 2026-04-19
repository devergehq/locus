---
id: science
name: Science
description: Hypothesis-test-analyze cycles for systematic problem-solving and debugging.
triggers:
  - experiment with
  - iterate on
  - improve
  - optimize
  - hypothesis
  - why is this happening
  - systematically debug
  - narrow it down
  - test different approaches
  - what if we tried
  - bisect this problem
  - isolate the issue
  - measure the impact
  - benchmark this
tags:
  - thinking
  - debugging
  - systematic
requires:
  delegation: false
---

# Science

The scientific method applied to software engineering. Hypothesis → test → analyze → refine. The meta-skill governing systematic problem-solving.

## Workflows

### Quick Diagnosis
Single hypothesis-test cycle. State what you think is wrong, design a minimal test, execute, interpret. For well-scoped bugs with a likely cause.

### Bisection
Binary search through the problem space. Systematically halve the search area until the root cause is isolated. For problems where the cause could be anywhere.

### Benchmark
Measure-change-measure cycles. Establish a baseline, make one change, measure again. For performance optimization and configuration tuning.

### Full Investigation
Multi-round hypothesis refinement. Each round's results inform the next hypothesis. For complex, poorly-understood problems where the first hypothesis is probably wrong.

## Process

1. **Observe** — Gather symptoms and context without jumping to conclusions
2. **Hypothesise** — State a falsifiable hypothesis ("The bug is caused by X because Y")
3. **Design test** — Minimal experiment that distinguishes this hypothesis from alternatives
4. **Execute** — Run the test. Record actual results, not expected results.
5. **Analyse** — Did the test confirm or refute the hypothesis?
6. **Refine** — Update understanding. Generate next hypothesis if needed. Repeat.

## Rules

- One variable at a time. If you change two things and it works, you don't know which one fixed it.
- Record negative results. Knowing what ISN'T the cause is as valuable as finding the cause.
- State the hypothesis BEFORE testing. Post-hoc rationalisation is not science.
