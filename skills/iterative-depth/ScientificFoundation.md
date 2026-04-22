# Scientific Foundation — Iterative Depth

Iterative Depth is not a bag of ad-hoc lenses. Each lens is grounded in an established scientific technique from cognitive science, requirements engineering, AI/ML reasoning research, or design thinking. This document names the sources.

## The meta-technique: multi-pass exploration

The underlying claim — that running the same problem through multiple structured perspectives surfaces insights invisible to any single pass — is supported across several literatures:

- **Self-Consistency** (Wang et al., ICLR 2023) — sampling multiple reasoning paths and taking the majority vote measurably improves LLM reasoning on math/commonsense benchmarks. Single-pass reasoning systematically underperforms.
- **Ensemble Methods** in ML more broadly (Breiman 1996, Dietterich 2000) — combining diverse model outputs outperforms any single model when the diversity is genuine and errors are uncorrelated.
- **Hermeneutic Circle** (Gadamer, *Truth and Method*, 1960/1975) — understanding emerges from iterative movement between whole and parts; the first pass is always partial.
- **Triangulation** (Denzin, *The Research Act*, 1970) — multiple independent methods converging on the same finding produce stronger evidence than any single method.

Running multiple lenses is the structured application of these principles to requirements analysis.

## Lens-specific foundations

### Lens 1 (Literal) — Requirements Engineering fundamentals
Standard practice in requirements engineering: parse the literal statement first, interpret second. Extraction discipline prevents early over-interpretation.

### Lens 2 (Stakeholder) — Viewpoint-Oriented RE
Finkelstein & Nuseibeh (1996) formalised the idea that requirements are viewpoint-relative. Different stakeholders perceive different requirements from the same system. A complete specification requires enumerating viewpoints explicitly.

### Lens 3 (Failure) — Misuse Cases + Pre-Mortem + STRIDE
- Sindre & Opdahl (2005) formalised misuse cases — the inverse of use cases.
- Gary Klein's pre-mortem technique (HBR 2007) — assume the project failed; work backward to causes.
- Microsoft's STRIDE threat modelling provides a structured framework for enumerating failure modes.

### Lens 4 (Temporal) — Causal Layered Analysis
Inayatullah (1998) — analysing a problem across four layers including historical cause, discourse, and myth. Progressive Elaboration (PMBOK) formalises the temporal evolution of requirements.

### Lens 5 (Experiential) — Appreciative Inquiry + de Bono
Cooperrider & Srivastva (1987) — AI methodology for organisational change focuses on what's working and aspirational states. de Bono's Six Thinking Hats (1985) — the red hat specifically addresses emotions and intuition as a distinct perspective.

### Lens 6 (Constraint Inversion) — TRIZ + Lateral Thinking
Altshuller's TRIZ (Theory of Inventive Problem Solving) — one of the 40 inventive principles is ideality (removing constraints). de Bono's lateral thinking (1970) — systematic techniques for escaping habitual framings.

### Lens 7 (Analogical) — Cognitive Flexibility Theory
Spiro et al. (1992) on knowledge transfer across contexts — flexible re-representation of concepts in multiple contexts improves learning and transfer. Cross-domain analogies are a canonical technique in problem-solving research.

### Lens 8 (Meta) — Double-Loop Learning + Soft Systems
- Argyris & Schön's double-loop learning (1978) — questioning the framing itself, not just the solution.
- Checkland's Soft Systems Methodology (1981) — root definitions and rich pictures explicitly work at the level above the stated problem.

## Why these 8 lenses, not 12 or 5

The 8 lenses span an intentionally complete space:

- **Concrete → Abstract** (Lens 1 → Lens 8)
- **Static → Dynamic** (Lens 1 → Lens 4)
- **Inside-view → Outside-view** (Lens 1 → Lens 7/8)

Pairs of lenses are orthogonal (Literal vs. Meta; Failure vs. Experiential; Stakeholder vs. Analogical). No pair strictly subsumes another.

Fewer than 8 drops orthogonal dimensions. More than 8 produces diminishing returns — in practice, by Lens 8 we are at diminishing marginal insight, and adding a ninth lens would largely overlap with existing ones.

## Empirical caveat

The specific claim "these 8 lenses collectively outperform 4 arbitrary lenses on ISC completeness" has not been formally benchmarked in the Locus codebase. The foundations cited above support the *method* (multi-pass structured exploration); the specific lens selection is a design choice informed by those foundations but not directly measured.

If this were measured, a reasonable benchmark would be: take N real projects, generate ISC lists with single-pass analysis, 4-lens pass, and 8-lens pass, then compare coverage of failure modes discovered in the first month of deployment. That evaluation is in the FUTURE_GAPS.md backlog under the Evals skill.
