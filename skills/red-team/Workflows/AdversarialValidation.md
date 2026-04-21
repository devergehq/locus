# Adversarial Validation Workflow

**Produce new content via competition between adversarial proposals.**

Use when: you want to generate the best version of something (a design, a plan, a spec, an essay) by having multiple adversarial agents each produce a candidate, then synthesise the winner from the competition.

Different from ParallelAnalysis — that attacks an existing proposal; this **produces new content through adversarial design**.

## Execution

### Step 1 — Scope

State the creative task:

- What is being produced?
- What are the non-negotiable constraints?
- What is the success criterion?

Example: "Produce a design spec for the billing subsystem. Must support: monthly invoicing, prorated upgrades, dunning workflow. Success = design survives a 30-minute engineering review with no load-bearing objections."

### Step 2 — Generate candidates

Launch 3-5 parallel attackers, each with trait bundles chosen for **diversity across design philosophy**, not just role. E.g.:

| Candidate | Trait bundle                                              | Design philosophy              |
|-----------|-----------------------------------------------------------|--------------------------------|
| Minimal   | `architecture + pragmatic + rapid`                        | Ship-first, refactor-later     |
| Bullet    | `security + adversarial + systematic`                     | Defence-in-depth, assume-breach|
| Elegant   | `architecture + systems-thinking + iterative`             | First-principles clean design  |
| Scrappy   | `implementation + contrarian + rapid`                     | Minimum viable, break rules    |
| Thorough  | `architecture + systematic + thorough`                    | Comprehensive, edge-case-first |

Each produces a standalone candidate design for the same task.

### Step 3 — Adversarial cross-attack

Each candidate is attacked by the other candidates. Each attacker receives:

- The other candidate's design.
- Their own trait-composed role.
- Explicit task: "Attack this design from your design philosophy. Where does it fail?"

Output: per-candidate attack summary — the flaws each other candidate surfaced.

### Step 4 — Synthesis

The invoking agent synthesises the winner:

- Which candidate's design survived the most attacks?
- Which candidate's attacks on others were most incisive?
- Can the winning design absorb the useful critiques from the attacks against it?

Produce a **synthesised design** that takes the best candidate as a spine and incorporates the strongest critiques from the other candidates.

## Output format

```markdown
## Adversarial Validation — <Task>

### Candidates generated
1. **Minimal:** <1-2 sentence summary>
2. **Bullet:** <1-2 sentence summary>
3. **Elegant:** <1-2 sentence summary>
4. **Scrappy:** <1-2 sentence summary>
5. **Thorough:** <1-2 sentence summary>

### Cross-attack matrix
| Attacker → Target | Minimal | Bullet | Elegant | Scrappy | Thorough |
|-------------------|---------|--------|---------|---------|----------|
| Minimal           | —       | <gist> | <gist>  | <gist>  | <gist>   |
<matrix completed>

### Survival analysis
- Candidate <X> survived attacks best because <reason>.
- Candidate <Y>'s critiques of others were most incisive because <reason>.

### Synthesised design
<full design text, taking candidate <X> as spine, absorbing the load-bearing critiques surfaced during cross-attack>

### Attribution
<which parts of the synthesis came from which candidate's critique — preserves the provenance of good ideas>
```

## Budget

Candidate generation: ~60s parallel. Cross-attack: ~60-90s (more combinations). Synthesis: ~60s. **Total: 3-5 minutes.**

## When this beats single-author design

- When the design space has multiple credible regions and you're not sure which to commit to.
- When the design is high-stakes and the cost of a subtly-wrong first draft is high.
- When the team would naturally produce a design biased toward one philosophy, and adversarial diversity corrects for it.
