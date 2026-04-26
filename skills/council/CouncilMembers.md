# Council Members

**Trait-composed participants for Council debates.** Council members are not named characters — they are **trait bundles** assembled via `locus agent compose`, which produces distinct, measurable cognitive profiles (evidence: Social Laboratory, DEBATE benchmark, Adaptive Heterogeneous Multi-Agent Debate).

Named characters with backstories are deliberately avoided. The literature shows they add persona drift (>30% self-consistency degradation after 8-12 turns, Li et al. 2402.10962) and, when demographic, cause ~33% reasoning degradation (Gupta et al., ICLR 2024). Functional trait bundles produce stable, distinct cognitive profiles without these harms.

## Default Council Roster

A standard Council debate uses these four members. The composition of each is a specific trait bundle — diverse across the dimensions that matter for debate (evidence approach, risk tolerance, domain focus).

### 1. Architect

**Traits:** `architecture + systems-thinking + skeptical`

**Focus:** Structural implications, coupling/cohesion, long-term architectural consequences of the decision. Flags invariants and failure modes.

### 2. Engineer

**Traits:** `implementation + pragmatic + empirical`

**Focus:** What actually ships, maintenance burden, tech debt, the gap between design and reality. Grounds the debate in implementation cost.

### 3. Designer

**Traits:** `design + empirical + systems-thinking`

**Focus:** User experience, accessibility, interaction consequences of the decision. Thinks about what users notice and the cognitive load of the interface.

### 4. Researcher

**Traits:** `research + systematic + empirical`

**Focus:** Precedent, data, evidence. What have others tried? What does the measurable evidence say? Grounds arguments in findings rather than opinion.

## Adding Members for Domain-Specific Debates

Add a member when the debate's domain demands it:

| Domain at stake   | Add this member | Traits                                           |
|-------------------|-----------------|--------------------------------------------------|
| Security / auth   | Security        | `security + adversarial + skeptical`             |
| Product scope     | Product         | `product + pragmatic + systems-thinking`         |
| Data / schema     | Data            | `data + systematic + empirical`                  |
| Infrastructure    | Infrastructure  | `infrastructure + pragmatic + systems-thinking`  |
| Testing / QA      | QA Tester       | `testing + skeptical + systematic`               |
| New / junior view | Intern          | `implementation + exploratory + rapid`           |
| Adversarial       | Pentester       | `security + adversarial + systematic`            |

An "Intern" member — trait bundle `implementation + exploratory + rapid` — is valuable for fresh-eyes critique; the literature on domain-novices surfacing issues experts miss is consistent across software engineering research.

## Removing Members

For narrow debates, reduce the council. "Just architect and engineer" is a valid two-member debate for implementation-level decisions.

A one-member "council" is not a debate — skip the skill and use First Principles or Iterative Depth instead.

## Composing a Member Prompt

Each member is spawned via `locus delegate run` with a prompt composed from their trait bundle:

```
locus agent compose --traits "architecture,systems-thinking,skeptical" \
                    --role "Council member: Architect" \
                    --task "Initial position on <topic>" \
                    --output prompt
```

Produces a prompt that blends:
- the three trait `prompt_fragment` entries from `agents/traits.yaml`
- a role statement ("You are the Architect on this Council")
- the task-specific context (round instructions, topic, transcript so far)

The member has no name, no backstory, no voice. They have a stance and a job.

## Diversity Principle

The default four members are diverse across:

- **Evidence source:** code (Engineer), data (Researcher), user behaviour (Designer), structural reasoning (Architect)
- **Time horizon:** ships-this-week (Engineer), weeks-to-months (Designer), long-term (Architect), historical (Researcher)
- **Risk posture:** pragmatic (Engineer), skeptical (Architect), empirical (others)

Adding members should widen this diversity, not duplicate it. Two architects is one council seat, not two.
