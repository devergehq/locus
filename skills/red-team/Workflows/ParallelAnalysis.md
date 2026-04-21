# Parallel Analysis Workflow

**Stress-test existing content through parallel adversarial attack, convergent synthesis, and steelman-plus-counter-argument output.**

Use when: an existing proposal, design, strategy, or plan needs rigorous adversarial analysis before commitment.

## The five-phase protocol

### Phase 1 — Decomposition

Break the proposal into its atomic claims. Not the proposal's sentences — its load-bearing assertions. A typical decomposition yields 15-30 claims. Each claim is:

- A standalone statement that could be true or false.
- Independent of other claims (removing one does not invalidate another in isolation).
- Granular — "the system is secure" becomes multiple claims like "authentication uses X", "authorisation enforces Y", "session invalidation happens on Z".

Output: a numbered list of atomic claims.

### Phase 2 — Parallel analysis

Launch 8-16 parallel attackers (per the roster in `Philosophy.md`). Each receives:

- The full proposal text.
- The list of atomic claims from Phase 1.
- The attacker's trait-composed role prompt.
- The explicit task: "Attack this proposal. Identify the single most load-bearing flaw. If you find multiple, rank by impact and surface the top one."

Each attacker returns:

- **Steelman of the proposal** (not a paraphrase — the strongest version).
- **Top flaw** — the load-bearing problem if the proposal has one.
- **Supporting evidence** — why this flaw matters.
- **Secondary concerns** — 2-3 further issues, ranked.

### Phase 3 — Synthesis

Identify **convergent insights** — flaws that multiple attackers independently surfaced. Convergence is the primary signal.

- **Strong convergence** (6+ attackers): near-certain load-bearing flaw.
- **Medium convergence** (3-5 attackers): strong candidate — likely real.
- **Singular insights** (1-2 attackers): retain if the insight is deep; discard if it is a surface quibble.

Output: ranked list of insights by convergence and depth.

### Phase 4 — Steelman

Compose the strongest version of the proposal. A proponent reading this should say "yes, that's my argument" — not "you misrepresented me".

Length: 6-10 points, each one sentence. The steelman must address the most credible case for the proposal, including rebuttals to the obvious critiques.

### Phase 5 — Counter-argument

Compose the devastating rebuttal. The counter-argument must:

- Defeat the steelman, not a strawman version.
- Use the convergent insights from Phase 3 as its primary structure.
- Be concrete — reference specific claims, specific failure modes, specific precedents.
- Lead with the load-bearing flaw. One strong argument at the top is worth more than seven weak arguments.

Length: 6-10 points, each one sentence.

## Output format

```markdown
## Red Team: Parallel Analysis — <Proposal>

### Atomic claims (decomposition)
1. <claim>
2. <claim>
...

### Convergent insights (synthesis)
- **<insight>** — surfaced by N/total attackers. <brief note>
- ...

### Steelman — the strongest version
1. <point>
2. <point>
...

### Counter-argument — the rebuttal
1. **<load-bearing flaw>** — <one-sentence explanation>
2. <point>
...

### Recommended action
- **If the steelman holds:** <what this implies>
- **If the counter-argument lands:** <what needs to change before commitment>
```

## Budget

Decomposition: ~30s. Parallel analysis: ~30-60s. Synthesis: ~30s. Steelman + counter: ~30s. **Total: 2-3 minutes** for 8 attackers, 4-5 minutes for 16.
