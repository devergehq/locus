# Red Team Integration

How Red Team composes with other Locus skills and where it fits in the Algorithm.

## Algorithm integration

Red Team is typically invoked in one of three Algorithm phases:

### THINK phase — pressure-testing the plan

During THINK, the Algorithm runs a premortem. Red Team deepens this: "here are the ISC criteria I intend to build against; find the fatal flaw in my plan before I commit effort." The output refines the ISC set — new criteria are added to cover failure modes the original set missed.

### VERIFY phase — final stress test

Before declaring work complete, Red Team attacks the built artifact. "This design ships tomorrow — tell me what breaks in the first week." Surviving this pass is stronger evidence of readiness than passing tests alone.

### Pre-publication / pre-commit review

For high-stakes output (architectural proposals, major PRs, external-facing designs), Red Team is invoked independently before the artifact is finalised.

## Skill composition

### Red Team + First Principles

Red Team attacks conclusions; First Principles attacks assumptions. Running First Principles **before** Red Team ensures the Red Team isn't defending an unsound foundation. Running First Principles **after** Red Team is rarely useful — if Red Team missed a load-bearing flaw, First Principles probably will too.

Recommended order: **First Principles → proposal → Red Team**.

### Red Team + Council

Council produces a recommendation. Red Team attacks the recommendation. This is the canonical "decide then stress-test" pattern for Extended+ effort.

Recommended order: **Council (reach recommendation) → Red Team (attack recommendation) → revise if the attack is load-bearing**.

### Red Team + Science

Red Team produces a hypothesis ("this proposal fails because X"). Science then tests it with a minimal experiment.

This composition is valuable when Red Team surfaces a concern but the concern is not obviously correct — Science provides empirical resolution rather than rhetorical victory.

## Output for downstream consumption

Red Team output is graded on two dimensions:

1. **Convergence** — how many attackers independently surfaced the same insight?
2. **Depth** — is the insight a surface objection (weak) or a load-bearing assumption failure (strong)?

The final synthesis ranks insights by (convergence × depth), and the top 1-3 become ISC anti-criteria or refinement criteria for the main work.

## Guardrails

- Red Team does not become an excuse for indefinite refinement. Timebox the cycle — if the ISC set is not meaningfully stronger after one Red Team pass, the returns are diminishing and the work should proceed.
- Red Team does not override explicit user direction. If the user has accepted a trade-off knowingly, Red Team surfacing the same trade-off is not grounds for reversal — just documentation.
- Red Team does not attack the proposal's author; it attacks the proposal. Avoid ad-hominem or motivational reasoning in outputs.
