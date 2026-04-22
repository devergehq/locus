# Science Examples

Worked examples of the Science cycle across different scales and domains.

## Example 1 — Micro (minutes): a flaky test

### Goal
Test `payment_flow_test.ts` passes reliably (currently fails ~30% of runs).

### Observe
- 10/10 local runs: 7 pass, 3 fail.
- Failures have different error messages — no single root cause visible.
- Tests use a shared in-memory database; suite runs in parallel.

### Hypothesize (3)
1. **Race condition** on shared DB state between parallel tests.
2. **Time-sensitive assertion** (e.g., "created_at equals now") with clock drift.
3. **Non-deterministic ordering** in an assertion that checks a set as a list.

### Experiment
Run the suite serially (`--maxWorkers 1`). If flakiness disappears → Hypothesis 1. If not → run Hypothesis 2 check.

### Measure
Serial run: 10/10 pass. Parallel run: 7/10 pass.

### Analyze
Hypothesis 1 supported. Root cause: shared DB state.

### Iterate
Fix with per-test schema isolation. Re-run in parallel: 10/10 pass. Done.

---

## Example 2 — Meso (hours): debugging login latency

### Goal
Reduce login p95 latency from 3.2s to under 1s within this sprint.

### Observe
- p50: 900ms, p95: 3.2s, p99: 8.4s.
- Traces show the slow tail is dominated by a single query: `SELECT * FROM user_roles WHERE user_id = ?`.
- The table has 12M rows, no index on `user_id`.

### Hypothesize (3)
1. **Missing index** on `user_roles.user_id`. Adding it drops p95 to <200ms.
2. **Connection pool exhaustion** causing queue time, not query time.
3. **Client-side retry storm** masquerading as server latency.

### Experiment
1. Check `pg_stat_statements` for actual query time on slow requests → confirms query time is >2s.
2. Check connection pool metrics → queue time is <10ms, ruling out H2.
3. H3 would show retry correlation — trace shows no retries.

### Measure
Primary query time: 2.4s median on slow requests. No connection queueing. No retries.

### Analyze
Hypothesis 1 supported. H2 and H3 refuted.

### Iterate
Add the index in a migration. Re-measure production p95.

Post-deploy: p95 drops to 180ms. Goal met.

---

## Example 3 — Macro (weeks): product-market fit for a new SaaS feature

### Goal
Determine whether the "saved filters" feature drives measurable retention improvement within 60 days of launch.

### Observe
- Current Week-4 retention: 38%.
- Current feature usage instrumentation: none for saved filters.

### Hypothesize (3)
1. **Retention lifter** — users who save a filter have materially higher retention than those who don't.
2. **Power-user only** — feature gets used, but only by the top 10% who were already retained.
3. **No effect** — feature gets used, retention is unchanged.

### Experiment
Ship the feature with cohort-level analytics. For 30 days, compare Week-4 retention of users who created a saved filter vs. matched cohorts (same signup week, same initial activity level) who did not.

### Measure
- 23% of users created at least one saved filter in the first 30 days.
- Retention for that cohort: 51% at Week 4.
- Matched control cohort: 39% at Week 4.

### Analyze
Hypothesis 1 supported with caveats:
- The 12pp delta is large.
- Confounding: users who save filters may be more deliberate overall. A/B test would be stronger than observational matching.

### Iterate
- Run an A/B test: randomly prompt a cohort to try saved filters in onboarding.
- Measure retention delta. Stronger causal inference.

---

## Example 4 — Research: persona prompting effectiveness (this project)

### Goal
Decide whether to give Locus agents named personalities, based on empirical evidence.

### Observe
- Mixed claims in popular discourse: some advocates, some skeptics.
- No internal benchmark.

### Hypothesize (3)
1. **Named personalities improve reasoning** — worth the complexity.
2. **Trait stances improve reasoning but named personalities don't** — port traits, drop names.
3. **Neither improves reasoning** — strip all of it, use plain role labels.

### Experiment
Structured literature review — 7 target papers, 3-model-agent parallel search, synthesis with citation verification.

### Measure
- Zheng et al. (EMNLP 2024): null result on 162 roles × 4 models.
- Gupta et al. (ICLR 2024): demographic personas cause ~33% reasoning degradation.
- Deshpande et al. (EMNLP Findings 2023): 6× toxicity spikes.
- Liang et al. (MAD): functional stances (pro/con/judge) show clear gains.
- Adaptive Heterogeneous Debate (Springer 2025): skeptic trait cuts TruthfulQA false answers ~20%.
- Li et al. (arXiv 2402.10962): persona drift >30% after 8-12 turns, worse on larger models.

### Analyze
Hypothesis 2 supported. Named personalities show no benefit and measurable harm. Trait stances show measurable benefit.

### Iterate
Port the trait dimension (`agents/traits.yaml`) — not the character dimension. Flag for future review: direct A/B test of trait-only vs named+traits on Locus's Council quality.
