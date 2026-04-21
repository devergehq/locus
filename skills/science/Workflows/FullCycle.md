# Full Cycle Workflow

**Complete Science cycle — goal through iteration.** Use when the problem is substantive and you need structured rigour across all seven phases.

## Execution

1. **Define goal** — fill the Goal template from `Templates.md`. Specific, measurable, falsifiable, time-bounded. Stop and confirm with the requester if the goal cannot be made concrete.

2. **Observe baseline** — collect current state data. Do not skip this step; you cannot measure a delta without a baseline.

3. **Generate hypotheses (≥3)** — fill the Hypothesis template at least three times. Plurality is mandatory.

4. **Design experiment** — pick the hypothesis with the highest (expected value × cost efficiency) to test first. Fill the Experiment template.

5. **Run the experiment** — do the intervention, collect the data.

6. **Measure and analyze** — fill Results and Analysis templates. Honest verdict — supported, refuted, or underdetermined.

7. **Iterate** — based on verdict:
   - **Supported:** confirm with larger test; if robust, generalise.
   - **Refuted:** return to hypothesis generation with the refutation informing the new hypotheses.
   - **Underdetermined:** redesign the experiment for clearer signal, then re-run.

## Output

Structured record in `{data}/memory/research/science/{YYYY-MM-DD}_{slug}/`:

- `goal.md` — filled Goal template
- `hypotheses.md` — all hypotheses, ranked
- `experiment-<N>.md` — one per experiment run
- `results-<N>.md` — one per experiment
- `analysis.md` — running analysis across experiments
- `conclusion.md` — final verdict when the cycle exits

## Budget

Scales with the problem. A micro-level cycle (flaky test) completes in minutes. A meso-level cycle (feature investigation) takes hours. A macro-level cycle (product decision) spans weeks with multiple iterations.

The discipline is the same regardless of scale.
