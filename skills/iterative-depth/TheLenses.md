# The 8 Lenses of Iterative Depth

Each lens is a structured perspective that forces exploration of a problem from a fundamentally different angle. Lenses are ordered from most concrete to most abstract, and from most universally applicable to most specialised.

Different lenses surface different requirements, failure modes, and ISC criteria. A single-pass analysis misses whatever isn't in view from one angle. Running the problem through multiple lenses surfaces criteria no single pass could produce.

---

## Lens 1 — Literal (surface requirements)

**Question:** "What did they explicitly say? What are the concrete, stated requirements?"

**Grounded in:** Requirements elicitation fundamentals.

**Focus:** Parse the exact words. Identify every stated requirement, constraint, preference. No interpretation — only what was said.

**ISC output:** Criteria for every explicitly stated requirement.

**Prompt:** "List every concrete, testable requirement explicitly stated in this request. Do not infer — only extract."

---

## Lens 2 — Stakeholder (who else cares?)

**Question:** "Who are all the people, systems, and entities affected? What does each need?"

**Grounded in:** Viewpoint-Oriented Requirements Engineering (Finkelstein & Nuseibeh), Triangulation (Denzin).

**Focus:** Identify every stakeholder beyond the requester. End users, maintainers, administrators, downstream systems, future developers. What does each need that wasn't stated?

**ISC output:** Criteria for stakeholder needs that weren't in the original request.

**Prompt:** "Identify every stakeholder affected by this work. For each, what requirement would *they* add that the requester didn't mention?"

---

## Lens 3 — Failure (what goes wrong?)

**Question:** "What could fail? What would an adversary exploit? What are the edge cases?"

**Grounded in:** Misuse Cases (Sindre & Opdahl), Pre-Mortem (Klein), STRIDE threat modelling.

**Focus:** Assume the solution exists. Now break it. Error states, race conditions, security holes, data corruption, user confusion, performance under load. Every way this could go wrong.

**ISC output:** Anti-criteria (what must *not* happen) and defensive criteria.

**Prompt:** "This solution ships tomorrow. List every way it fails in the first week. Be adversarial."

---

## Lens 4 — Temporal (past, present, future)

**Question:** "How does this change over time? What's the history? What happens in 6 months?"

**Grounded in:** Causal Layered Analysis (Inayatullah), Progressive Elaboration (PMBOK).

**Focus:** Why does this problem exist now? What was tried before? What changes in the future that would break this solution? Migration paths, backwards compatibility, scale changes.

**ISC output:** Criteria for durability, migration, and future-proofing.

**Prompt:** "What context created this request? What will change in 3-12 months that could invalidate this solution?"

---

## Lens 5 — Experiential (how should it feel?)

**Question:** "When this works perfectly, how does the user *feel*? What's the experience?"

**Grounded in:** Appreciative Inquiry (Cooperrider), de Bono's Red Hat thinking (emotions).

**Focus:** Beyond functional correctness — the qualitative experience. Speed, elegance, surprise, delight, confidence, trust. What's the difference between "works" and "works beautifully"?

**ISC output:** Quality-of-experience criteria that elevate from functional to euphoric surprise.

**Prompt:** "Describe the perfect user experience of this solution. What makes someone say 'this is exactly what I wanted' vs. 'this technically works'?"

---

## Lens 6 — Constraint inversion (what if?)

**Question:** "What if we removed all constraints? What if we added extreme ones?"

**Grounded in:** TRIZ (Altshuller), Lateral Thinking (de Bono), Reframing (Dorst).

**Focus:** Remove assumed constraints — what would we build with infinite time/resources? Then add extreme constraints — what if it had to work offline, in 100ms, with zero dependencies? Both directions reveal hidden assumptions.

**ISC output:** Criteria that challenge assumptions and reveal what's truly essential.

**Prompt:** "What constraints are we assuming that weren't stated? Remove them — what changes? Now impose extreme constraints — what's truly essential?"

---

## Lens 7 — Analogical (what patterns apply?)

**Question:** "What similar problems have been solved before? What patterns from other domains apply?"

**Grounded in:** Cognitive Flexibility Theory (Spiro), cross-domain transfer research.

**Focus:** This problem isn't unique. What similar problems exist in other codebases, other industries, other fields? What patterns emerged there? What mistakes were made?

**ISC output:** Criteria derived from proven patterns and lessons from analogous solutions.

**Prompt:** "What are 3-5 analogous problems in other domains? What solutions worked there? What criteria would those solutions imply here?"

---

## Lens 8 — Meta (is this the right question?)

**Question:** "Are we solving the right problem? Is the framing itself correct?"

**Grounded in:** Hermeneutic Circle (Gadamer), Double-Loop Learning (Argyris), Soft Systems Methodology (Checkland).

**Focus:** Step outside the problem entirely. Is the request a symptom of a deeper issue? Is there a reframing that dissolves the problem instead of solving it? Would a different question yield a better outcome?

**ISC output:** Criteria that reframe or expand the problem definition itself.

**Prompt:** "Forget the specific request. What is the *underlying* need? Is there a reframing that produces a better outcome than what was asked for?"

---

## SLA-based lens selection

| Tier       | Lenses | Which ones                                             | Budget |
|------------|--------|--------------------------------------------------------|--------|
| Minimal    | 0      | Skip IterativeDepth entirely                           | 0s     |
| Standard   | 2      | Literal + Failure                                      | <30s   |
| Extended   | 4      | Literal + Stakeholder + Failure + Experiential         | <2min  |
| Advanced+  | 8      | All 8 lenses                                           | <5min  |

At Standard tier, the two most commonly productive lenses run as brief internal thought exercises — not spawned agents.

At Extended, 4 lenses run. These can be parallelised as 2 pairs of background agents.

At Advanced+, all 8 lenses run in parallel. Results synthesised at the end.

## Custom depth

When invoked with a specific count ("do 3 passes"), select lenses in order from Lens 1 through Lens N. The ordering is designed so earlier lenses are more universally applicable.

For domain-specific overrides (e.g., a purely technical problem with no end users): the Algorithm may skip Lens 2 (Stakeholder) or Lens 5 (Experiential) and substitute the equivalent lens of domain interest.
