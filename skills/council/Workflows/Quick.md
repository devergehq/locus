# Quick Workflow

**Fast consensus check — 1 round only.**

Use when: a sanity check is enough; you need multiple perspectives on a small question, not a full deliberation.

## When to use over Debate

| Situation                                                    | Workflow  |
|--------------------------------------------------------------|-----------|
| Important architectural or product decision                  | Debate    |
| Quick sanity check — "is this API design reasonable?"        | Quick     |
| Multiple stakeholders, contested trade-offs                  | Debate    |
| One-line opinion from multiple angles                        | Quick     |
| Need to see reasoning evolve through rebuttal                | Debate    |
| Need to see where the consensus is fast                      | Quick     |

## Execution

### Step 1 — Announce

```markdown
## Council Quick Check: <Topic>

**Members:** Architect, Engineer, Designer, Researcher
**Rounds:** 1 (Initial Positions only)
```

### Step 2 — Round 1: Initial Positions

Dispatch N parallel `locus delegate run` calls (one per member) in a single assistant message, per the dispatch idiom in `RoundStructure.md`. Each member's prompt follows the Round 1 template there.

**DO NOT use the platform Task tool for this step** — see `RoundStructure.md`'s "Dispatch idiom" section.

Collect responses (each member's text from the JSON envelope's `summary` field). Display as:

```markdown
### Round 1: Initial Positions

**Architect:**
<response>

**Engineer:**
<response>

**Designer:**
<response>

**Researcher:**
<response>
```

### Step 3 — Light Synthesis

The invoking agent writes a compact synthesis:

```markdown
### Quick Synthesis

**Agreement:** <what 3+ members agreed on, if anything>

**Divergence:** <most significant disagreement>

**Quick take:** <one-paragraph summary of where the consensus lands and where it doesn't>
```

## Budget

~10-20 seconds total.

## Escalation

If the Quick check surfaces significant disagreement or a high-stakes decision, recommend the caller escalate to the **Debate** workflow rather than taking the Quick synthesis as final.
