# Decompose Workflow

**Systematic decomposition to foundational truths, then reconstruction from verified axioms.**

Use when: a problem keeps recurring despite surface fixes, an inherited convention is under question, or you need to separate genuine constraints from assumed ones.

## Process

### Step 1 — State the claim or approach

Write it down explicitly. One sentence. "We use microservices because they scale better than monoliths." "The login flow must support SSO." "React components should be functional, not class-based."

Do not begin decomposition until the claim is in writing. Ambiguity is a shield against critique.

### Step 2 — List every assumption

For each word or concept in the claim, ask: what is taken for granted?

- Factual assumptions: "microservices scale better than monoliths" — evidence?
- Definitional assumptions: what counts as "scale"? Requests/sec? Developer throughput? Operational complexity?
- Temporal assumptions: scale for whom, now, or projected?
- Alternative assumptions: is the binary (micro vs mono) exhaustive? What about modular monolith?
- Source assumptions: where did this belief come from? Is the source still valid?

Aim for 8-15 assumptions. Most claims contain more than the author realises.

### Step 3 — Challenge each assumption

For each assumption, ask three questions:

1. **Is this actually true?** Evidence — not reputation.
2. **Is this necessary?** Would the claim still hold if this assumption were false?
3. **Where did it come from?** A specific authority? A past context that no longer applies? A habit?

Mark each assumption:

- **Axiom** — actually true, necessary, and its source is valid.
- **Legacy** — was true in a prior context; unclear if still true.
- **Unverified** — asserted, not demonstrated.
- **False** — demonstrably wrong.

### Step 4 — Find the axioms

After the challenge pass, what remains in the "axiom" category? These are the foundational truths. The claim is only as strong as its axioms.

### Step 5 — Reconstruct

From the verified axioms, rebuild. Does the original claim follow? Does a different claim follow better?

Often the reconstructed claim is narrower than the original — fewer premises support fewer conclusions. That narrowing is the product of the exercise.

## Output format

```markdown
## First Principles: Decomposition — <Claim>

### The claim
<single sentence>

### Assumptions surfaced
1. <assumption> — [axiom / legacy / unverified / false]
2. ...

### Axioms
- <axiom> — source: <where this verification comes from>
- ...

### Reconstruction
Given only the axioms: <what follows>.

### Delta
<What changed from the original claim? What premises dropped? What conclusions are no longer supported?>

### Recommended action
- <what to do given the reconstruction>
```

## When this beats staying with the original

The Decompose workflow is worth the effort when:

- The original claim is load-bearing (many decisions depend on it).
- The claim has been inherited, not derived.
- Symptoms keep recurring despite fixes (suggesting the fixes addressed the wrong level).
- The cost of the wrong claim persisting is high.

It is *not* worth it for claims that are well-known, easily verified, or low-stakes. Not every inherited convention deserves a decomposition — only the ones bearing real weight.

## Budget

A careful decomposition is 10-30 minutes of focused thinking. Rushed decomposition produces superficial assumption lists and misses the load-bearing ones.

## Composition with other skills

- **Red Team** — attacks a proposal; First Principles attacks the foundations that generated the proposal. Run First Principles *before* Red Team when the foundation itself is in question.
- **Iterative Depth Lens 6 (Constraint Inversion) and Lens 8 (Meta)** — overlap with First Principles. Use First Principles when the decomposition is the task; use Iterative Depth when decomposition is one of multiple angles.
