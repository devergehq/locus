# Deep Investigation Workflow

**Iterative landscape mapping with persistent vault. Multi-session if needed.**

The skill orchestrates and writes the vault. Each research pass shells out to `locus delegate run --backend opencode --task-kind research --mode native`, with the trait bundle from `agents/deep-investigation-researcher.md` composed via `locus agent compose`.

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

The vault survives across sessions. A subsequent invocation can resume where the prior one left off. **The orchestrator owns all vault writes** — `locus delegate run` is read-only.

## Execution model

**The skill is the orchestrator. The research work runs in OpenCode via `locus delegate run`. The orchestrator writes the vault.**

Per iteration:
1. Orchestrator reads the current vault state (landscape, rubric, iteration log) — this is cheap, the files are small.
2. Orchestrator composes a research prompt that bundles all context the delegated researcher needs (scope, current rubric, target entity, prior findings to build on).
3. Orchestrator calls `locus delegate run --backend opencode --task-kind research --mode native --dir .` with the composed prompt.
4. Delegated process does the heavy work (search, primary-source reads, cross-references) and returns a compact JSON envelope (`summary`, `findings`, `evidence`, `risks`, `files_referenced`).
5. Orchestrator transforms the envelope into a dossier file written to `entities/<slug>.md`, updates the scoring rubric, appends to the iteration log.

**DO NOT use the platform-native Task tool for the research pass.** Task subagents are other Claudes burning the same context budget. Use `locus delegate run --backend opencode` so the heavy investigation runs out-of-context and only a compact envelope returns. The orchestrator writes the vault from that envelope.

## Execution

### Iteration 1 — landscape mapping

1. **Scope the domain** — what is the bounded area of investigation? Orchestrator writes the scope to `landscape.md` (skeleton only — entities will be filled by the first delegated pass).
2. **Broad scan via delegated research** — dispatch one `locus delegate run` call asking for the landscape: categories, entities, time periods, key actors. Trait bundle per `agents/deep-investigation-researcher.md`:

   ```bash
   LANDSCAPE_PROMPT=$(locus agent compose \
     --traits "research,iterative,hypothesis-driven,systems-thinking" \
     --role "Deep investigation researcher (iteration 1, landscape pass)" \
     --task "Scope: <domain>. Surface categories, entities, time periods, key actors. Return a structured catalogue. Do not deep-dive any single entity — that comes in later iterations.")

   locus delegate run \
     --backend opencode \
     --task-kind research \
     --mode native \
     --dir . \
     --prompt "$LANDSCAPE_PROMPT" \
     --output json
   ```

3. **Orchestrator builds the scoring rubric** from the returned envelope's `findings` — classify each entity CRITICAL / HIGH / MEDIUM / LOW by (relevance × information value). Write to `landscape.md`.
4. **First deep-dive (delegated)** — pick the highest-priority entity; dispatch a second `locus delegate run` call with the entity-specific prompt below. Orchestrator writes the dossier from the returned envelope.
5. **Orchestrator writes the iteration log** — what was done, what was learned, what the next iteration should do.

### Iteration N — entity deep-dive

1. **Orchestrator reads the iteration log** to resume state.
2. **Select next entity** — the highest-priority un-researched entity per the scoring rubric.
3. **Delegated deep-dive** — dispatch `locus delegate run` with the entity context the delegate needs:

   ```bash
   ENTITY_PROMPT=$(locus agent compose \
     --traits "research,iterative,hypothesis-driven,systems-thinking" \
     --role "Deep investigation researcher (iteration N, entity deep-dive)" \
     --task "Scope: <domain>. Target entity: <entity>. Current rubric notes: <relevant excerpt>. Prior findings to build on: <relevant prior dossiers, summarised>. Deep-dive the target entity using primary sources, cross-references, and contradiction checks.")

   locus delegate run \
     --backend opencode \
     --task-kind research \
     --mode native \
     --dir . \
     --prompt "$ENTITY_PROMPT" \
     --output json
   ```

4. **Orchestrator writes the dossier** to `entities/<entity-slug>.md` from the envelope's `summary` + `findings` + `evidence`. Verify every URL via `UrlVerificationProtocol.md` before writing.
5. **Orchestrator updates the scoring rubric** — what did this iteration reveal that changes priorities? Write to `landscape.md`.
6. **Orchestrator updates the iteration log** with what was done, what was learned, what the next iteration should do.

### Advanced mode — parallel deep-dives

Dispatch two `locus delegate run` calls in the *same assistant message*, each targeting a different priority entity. The platform parallelises them. The orchestrator writes both dossiers when both envelopes return. Roughly halves wall-clock time, doubles cost.

```bash
# Same message, two independent Bash tool calls:
ENTITY_A_PROMPT=$(locus agent compose --traits "research,iterative,hypothesis-driven,systems-thinking" \
  --role "..." --task "<entity A context>")
locus delegate run --backend opencode --task-kind research --mode native --dir . \
  --prompt "$ENTITY_A_PROMPT" --output json
```

```bash
ENTITY_B_PROMPT=$(locus agent compose --traits "research,iterative,hypothesis-driven,systems-thinking" \
  --role "..." --task "<entity B context>")
locus delegate run --backend opencode --task-kind research --mode native --dir . \
  --prompt "$ENTITY_B_PROMPT" --output json
```

### Exit condition

The investigation exits when:
- All CRITICAL and HIGH entities have dossiers, AND
- All categories in the landscape have at least one researched entity, AND
- The last iteration added no new entities to the rubric (the domain is closed).

On exit, the orchestrator writes `synthesis.md` — the answer that the collected vault produces. Synthesis is the orchestrator's job: it has read all the dossiers and can integrate across them. Do not delegate synthesis; the cross-entity reasoning is exactly what the orchestrator's context is for.

## URL verification

Every citation in every dossier must pass `UrlVerificationProtocol.md`. The scale of deep investigation multiplies the risk of hallucinated URLs; verification is non-negotiable. Verify URLs from the delegated envelope **before** writing them into a dossier — once they're in the vault, they look authoritative.

## Failure handling

- **Delegated research returns empty findings** — log the failure in the iteration log, mark the entity as "research-failed" in the rubric (not "not-yet-researched"), and move to the next entity. Do not retry blindly.
- **Delegated research times out** — same as empty findings; the orchestrator continues with what's done.
- **Rate-limited / `locus delegate run` failing across multiple iterations** — pause the investigation, surface the situation to the user, offer to resume later. Vault state is preserved on disk.

## Budget

Per iteration: 3-15 minutes depending on entity depth (delegated research dominates the wall clock; orchestrator vault writes are seconds). Full investigation: 30 minutes to several hours, depending on domain scope. If the budget overflows, the rubric lets you stop cleanly at any point — the vault is useful even if incomplete.

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
- Delegated research calls: N (cost-relevant)

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
- **Asking the delegate to write the dossier directly.** `locus delegate run` is read-only — the delegate returns findings; the orchestrator writes the vault file. Trying to delegate writes will silently produce nothing on disk.
- **Delegating the cross-entity synthesis.** Synthesis is what the orchestrator's context is for. Delegating it loses the integration the vault was built to enable.
- **Using the platform-native Task tool for the research pass.** Burns the orchestrator's context with the same Claude doing the research. Use `locus delegate run` so the heavy work happens in a different model under a different provider.
