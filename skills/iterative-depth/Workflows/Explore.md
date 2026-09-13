# Explore Workflow

**SLA-scaled multi-lens exploration.** Runs the problem through 2-8 lenses per `TheLenses.md`, producing refined ISC criteria that no single-pass analysis would surface.

## Execution

### Step 1 — Select lenses by SLA

| Tier       | Lenses | Which ones                                             |
|------------|--------|--------------------------------------------------------|
| Minimal    | 0      | Skip IterativeDepth entirely                           |
| Standard   | 2      | Literal + Failure                                      |
| Extended   | 4      | Literal + Stakeholder + Failure + Experiential         |
| Advanced+  | 8      | All 8 lenses                                           |

Or, if the Algorithm calls this skill with an explicit count, use Lenses 1..N.

### Step 2 — Run each lens

For each selected lens, apply its prompt template from `TheLenses.md`. Each lens produces ISC candidate criteria specific to that angle.

At Standard tier: the lens prompts run as internal thought, not delegated agents (save latency, small problem).

At Extended+: delegate. Each lens becomes its own dispatched allele session with a
trait-composed role matching the lens intent.

**Create the lens sessions one `allele_sessions_create` at a time**, reading each returned
`session_id` before composing the next; the lenses then run concurrently. Reclaim each with
`allele_sessions_discard(session_id)` once its criteria have been read into Step 3. Eight lenses is eight sessions against
a global cap of twenty shared with every other dispatcher on the machine, so reclaim as you
go rather than at the end. The rule, its reason and the vehicle table for when allele is not
reachable are in the Algorithm's **Dispatch** section — this file does not restate them.

| Lens           | Trait bundle for delegated agent                                 |
|----------------|------------------------------------------------------------------|
| Literal        | `research + systematic + rapid`                                  |
| Stakeholder    | `product + systems-thinking + exploratory`                       |
| Failure        | `security + adversarial + thorough`                              |
| Temporal       | `architecture + systems-thinking + iterative`                    |
| Experiential   | `design + empirical + narrative`                                 |
| Constraint Inv.| `rationalist + contrarian + exploratory`                         |
| Analogical     | `research + analogical + exploratory`                            |
| Meta           | `rationalist + contrarian + systems-thinking`                    |

### Step 3 — Consolidate criteria

Each lens's output is a list of ISC candidate criteria. Consolidate across lenses:

1. **Dedupe** — multiple lenses often surface the same criterion from different angles. Keep one, note the lenses that converged on it (convergence is evidence of importance).
2. **Apply the Splitting Test** (from the Algorithm) — any candidate that fails atomicity gets split.
3. **Classify** — criterion vs. anti-criterion (what must NOT happen).
4. **Rank** — by a mix of convergence (how many lenses surfaced this) and severity (how badly missing it would hurt).

### Step 4 — Output

```markdown
## IterativeDepth: Explore — <Problem>

### Lenses applied
- Literal
- Stakeholder
- Failure
- <etc>

### Criteria surfaced (consolidated)

**Criteria:**
- [ ] ISC-N: <text> (from lens: Literal)
- [ ] ISC-N+1: <text> (from lenses: Stakeholder, Analogical)
- ...

**Anti-criteria:**
- [ ] ISC-A-N: <text> (from lens: Failure)
- ...

### Convergent insights
- <Insight X — surfaced by Lenses 2, 3, 7 — high confidence>
- <Insight Y — surfaced by Lens 8 only — lower confidence, but load-bearing if correct>

### Framing shift (Lens 8 only)
<If Lens 8 ran and produced a reframing: what is the deeper question this request is really asking?>
```

## Budget

- Standard (2 lenses, internal thought): <30s
- Extended (4 lenses, running concurrently): <2min, +~4s of sequential creates
- Advanced+ (8 lenses, running concurrently): <5min, +~8s of sequential creates

## Composition with other skills

- **Before** IterativeDepth: good context from `research` skill if the problem space is unfamiliar.
- **After** IterativeDepth: `council` to arbitrate tensions surfaced across lenses; `red-team` to attack the consolidated criteria.
- **Composable with** `first-principles`: Lens 6 (Constraint Inversion) and Lens 8 (Meta) directly echo first-principles decomposition.
