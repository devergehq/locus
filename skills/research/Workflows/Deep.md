# Deep Investigation Workflow

**Iterative landscape mapping with persistent vault. Multi-session if needed.**

Delegates to the `deep-investigation-researcher` agent archetype. See `agents/deep-investigation-researcher.md` for the agent's stance and iteration protocol.

## When to use

- "Map the X landscape" — broad domain with unknown boundaries.
- Multi-session research — the question cannot be answered in one pass.
- The investigation produces reference material that should persist (dossiers, actor profiles, entity catalogues).
- User explicitly says "deep investigation" or "map the X landscape".

Not for: single-question research (use Quick or Standard), finite-scope multi-angle research (use Extensive).

## How it differs from Extensive

Extensive is one-shot — 12 researchers, synthesis, done. Deep is iterative — each pass deepens the vault and informs the next pass. Extensive answers a question; Deep maps a domain.

## Vault location

All artifacts persist to `{data}/memory/research/deep/{slug}/`:

```
{slug}/
├── landscape.md               # iteration 1 output: entity catalogue + scoring rubric
├── iteration-log.md           # what was learned per pass
├── entities/
│   ├── <entity-slug>.md       # per-entity dossier
│   └── ...
└── synthesis.md               # final cross-entity synthesis (written on exit)
```

The vault survives across sessions. A subsequent invocation can resume where the prior one left off.

## Execution

### Iteration 1 — landscape mapping

1. **Scope the domain** — what is the bounded area of investigation? Write the scope to `landscape.md`.
2. **Broad scan** — surface the categories, entities, time periods, key actors.
3. **Scoring rubric** — classify each entity CRITICAL / HIGH / MEDIUM / LOW by (relevance × information value).
4. **First deep-dive** — pick the highest-priority entity; write its dossier to `entities/<slug>.md`.
5. **Iteration log** — record what was done, what was learned, what the next iteration should do.

### Iteration N — entity deep-dive

1. **Read the iteration log** to resume state.
2. **Select next entity** — the highest-priority un-researched entity per the scoring rubric.
3. **Deep-dive** — primary sources, cross-references, contradictions. Write dossier.
4. **Update scoring rubric** — what did this iteration reveal that changes priorities?
5. **Update iteration log**.

### Exit condition

The investigation exits when:
- All CRITICAL and HIGH entities have dossiers, AND
- All categories in the landscape have at least one researched entity, AND
- The last iteration added no new entities to the rubric (the domain is closed).

On exit, write `synthesis.md` — the answer that the collected vault produces.

## URL verification

Every citation in every dossier must pass `UrlVerificationProtocol.md`. The scale of deep investigation multiplies the risk of hallucinated URLs; verification is non-negotiable.

## Delegation model

Each iteration spawns one `deep-investigation-researcher` agent with full context: the scope, the current rubric, the target entity. The agent does the deep-dive, writes the dossier, updates the rubric, returns.

Advanced mode: two parallel `deep-investigation-researcher` agents on two different entities per iteration — roughly halves wall-clock time, doubles cost.

## Budget

Per iteration: 3-15 minutes depending on entity depth. Full investigation: 30 minutes to several hours, depending on domain scope. If the budget overflows, the rubric lets you stop cleanly at any point — the vault is useful even if incomplete.

## Output

On exit, return:

```markdown
## Deep Investigation: <Scope>

### Vault location
`{data}/memory/research/deep/{slug}/`

### Coverage
- Entities researched: N CRITICAL / M HIGH / P MEDIUM / Q LOW
- Categories covered: <list>
- Iterations run: N

### Synthesis
<the answer the collected vault produces — this is the readable deliverable>

### Key findings
1. <finding across entities>
2. ...

### Open questions
<what the investigation surfaced but could not resolve>

### Verified sources
<count + path to full list in the vault>
```

## Anti-patterns

- **Running Deep when Extensive would have answered the question.** Deep is for domain mapping, not one-shot answers.
- **Not persisting to the vault.** In-memory state is lost at compaction; the vault is the only surviving record.
- **Skipping the scoring rubric update.** If priorities don't shift across iterations, the rubric isn't doing its job.
- **Completing the rubric with no synthesis.** The synthesis is the deliverable; without it, the vault is just notes.
