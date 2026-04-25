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

### Step 2 — Generate candidates via `locus delegate run`

Dispatch 3-5 parallel `locus delegate run` calls in a single assistant message, each with a trait bundle chosen for **diversity across design philosophy**, not just role. **DO NOT use the platform-native Task tool** — see SKILL.md's "Execution model" section.

| Candidate | Trait bundle                                              | Design philosophy              |
|-----------|-----------------------------------------------------------|--------------------------------|
| Minimal   | `architecture,pragmatic,rapid`                            | Ship-first, refactor-later     |
| Bullet    | `security,adversarial,systematic`                         | Defence-in-depth, assume-breach|
| Elegant   | `architecture,systems-thinking,iterative`                 | First-principles clean design  |
| Scrappy   | `implementation,contrarian,rapid`                         | Minimum viable, break rules    |
| Thorough  | `architecture,systematic,thorough`                        | Comprehensive, edge-case-first |

Per candidate:

```bash
PROMPT=$(locus agent compose \
  --traits "<bundle from table above>" \
  --role "Adversarial designer: <Candidate name>" \
  --task "Produce a standalone candidate design for this task, expressing your design philosophy without compromise.

Task scope:
<scope text from Step 1>

Constraints:
<non-negotiable constraints>

Success criterion:
<criterion>

Return the full design text.")

locus delegate run \
  --backend opencode \
  --task-kind general \
  --mode native \
  --dir . \
  --prompt "$PROMPT" \
  --output json
```

The orchestrator collects N candidate designs from the `summary` field of each envelope.

### Step 3 — Adversarial cross-attack via `locus delegate run`

For each (attacker, target) pair where attacker ≠ target, dispatch one `locus delegate run`. With 5 candidates that's 20 attacks; with 3 candidates it's 6. Dispatch all in a single assistant message (or in waves of N if rate-limited).

Per attack:

```bash
PROMPT=$(locus agent compose \
  --traits "<attacker's trait bundle>" \
  --role "Adversarial designer attacking from <attacker philosophy>" \
  --task "Attack this design from your design philosophy. Where does it fail? What would you do differently? Be specific — reference parts of the design, not generalities.

Target design:
<target candidate's design text>")

locus delegate run \
  --backend opencode \
  --task-kind general \
  --mode native \
  --dir . \
  --prompt "$PROMPT" \
  --output json
```

Output: per-candidate attack summary aggregated from the envelopes — the flaws each other candidate's attacker surfaced.

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
