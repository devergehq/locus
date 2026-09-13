# Deep Investigation Workflow

**Iterative landscape mapping with persistent vault. Multi-session if needed.**

The skill orchestrates and writes the vault. Each research pass runs in its own dispatched
allele session.

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

The vault survives across sessions. A subsequent invocation can resume where the prior one
left off. **The orchestrator owns all vault writes.** Not because a dispatched session cannot
write — it can, and it has its own workspace and branch to write in — but because that
workspace is *not this one*. A worker asked to write `entities/<slug>.md` writes it into its
own tree, where the vault will never see it. The worker returns findings; the orchestrator
writes the vault.

## Execution model

**The skill is the orchestrator. Each research pass runs in a dispatched allele session. The
orchestrator writes the vault.**

Dispatch discipline is not restated here: one `allele_sessions_create` at a time with its
result read before the next, and every session reclaimed with `allele_sessions_discard`. The
canonical text is the Algorithm's **Dispatch** section; `SKILL.md`'s "Dispatch discipline"
points at it.

Per iteration:
1. Orchestrator reads the current vault state (landscape, rubric, iteration log) — this is cheap, the files are small.
2. Orchestrator composes a research prompt that bundles all context the delegated researcher needs (scope, current rubric, target entity, prior findings to build on).
3. Orchestrator calls `allele_sessions_create` — one call, result read before any next one
4. The dispatched session does the heavy work (search, primary-source reads, cross-references) and replies with a report in the standard shape (`summary`, `findings`, `evidence`, `risks`, `files_referenced`).
5. Orchestrator transforms the report into a dossier file written to `entities/<slug>.md`, updates the scoring rubric, appends to the iteration log.
6. Orchestrator discards the session. Deep runs for hours across many iterations — a skill
   that never reclaims will hold the entire global cap of twenty before the domain is
   mapped, and every one of those sessions is invisible work nobody owns.

**Prefer `allele_sessions_create` hard over a native Task subagent** — a Task subagent burns
this session's context with the same heavy investigation the vault exists to keep out of it.
The preference is not a prohibition: when no sanctioned vehicle is reachable, route down the
Algorithm's vehicle table and announce the degradation.

## Execution

### Iteration 1 — landscape mapping

1. **Scope the domain** — what is the bounded area of investigation? Orchestrator writes the scope to `landscape.md` (skeleton only — entities will be filled by the first delegated pass).
2. **Broad scan via delegated research** — dispatch one `allele_sessions_create` call asking for the landscape: categories, entities, time periods, key actors. Trait bundle per `agents/deep-investigation-researcher.md`:

   ```bash
   LANDSCAPE_PROMPT=$(locus agent compose \
     --traits "research,iterative,hypothesis-driven,systems-thinking" \
     --role "Deep investigation researcher (iteration 1, landscape pass)" \
     --task "Scope: <domain>. Surface categories, entities, time periods, key actors. Return a structured catalogue. Do not deep-dive any single entity — that comes in later iterations.")

   allele_sessions_create(
  project: "<project>",
  name:    "<short label — this is the address>",
  prompt:  $LANDSCAPE_PROMPT
)
   ```

3. **Orchestrator builds the scoring rubric** from the report's `findings` — classify each entity CRITICAL / HIGH / MEDIUM / LOW by (relevance × information value). Write to `landscape.md`.
4. **First deep-dive (delegated)** — pick the highest-priority entity; dispatch a second `allele_sessions_create` call with the entity-specific prompt below. Orchestrator writes the dossier from the worker's report.
5. **Orchestrator writes the iteration log** — what was done, what was learned, what the next iteration should do.

### Iteration N — entity deep-dive

1. **Orchestrator reads the iteration log** to resume state.
2. **Select next entity** — the highest-priority un-researched entity per the scoring rubric.
3. **Delegated deep-dive** — dispatch `allele_sessions_create` with the entity context the delegate needs:

   ```bash
   ENTITY_PROMPT=$(locus agent compose \
     --traits "research,iterative,hypothesis-driven,systems-thinking" \
     --role "Deep investigation researcher (iteration N, entity deep-dive)" \
     --task "Scope: <domain>. Target entity: <entity>. Current rubric notes: <relevant excerpt>. Prior findings to build on: <relevant prior dossiers, summarised>. Deep-dive the target entity using primary sources, cross-references, and contradiction checks.")

   allele_sessions_create(
  project: "<project>",
  name:    "<short label — this is the address>",
  prompt:  $ENTITY_PROMPT
)
   ```

4. **Adversarial claim verification** — per `AdversarialVerificationProtocol.md`, extract falsifiable claims from the entity's findings and dispatch 3 adversarial verifiers per claim via `allele_sessions_create`, one create at a time and in waves of at most 6 live sessions. Discard the deep-dive session before verification starts. Claims that survive go into the dossier; claims that are killed are logged in the dossier's "Refuted" section with evidence. For Deep mode, expect 3-5 claims per entity deep-dive.
5. **Orchestrator writes the dossier** to `entities/<entity-slug>.md` from the report's `summary` + verified `findings` + `evidence` + refuted claims. Verify every URL via `UrlVerificationProtocol.md` before writing.
6. **Orchestrator updates the scoring rubric** — what did this iteration reveal that changes priorities? Did any refuted claims change the entity's significance? Write to `landscape.md`.
7. **Orchestrator updates the iteration log** with what was done, what was learned, what claims survived/were killed, and what the next iteration should do.

### Advanced mode — two entities in flight

Two entities can be investigated at once. Create the two sessions **one at a time** — compose
entity A's prompt, call `allele_sessions_create`, read the returned `session_id`, then do the
same for entity B. Both then run concurrently; the orchestrator writes both dossiers when
both report, and discards both. Roughly halves wall-clock time, doubles cost.

The two creates cost about two seconds against deep-dives that take minutes. Batching them
into one message is what the Algorithm's Dispatch section forbids, and the failure it
describes — a create returning another caller's `session_id` — would here mean writing entity
A's dossier from entity B's report, or from a report belonging to something else entirely.

```
# First create. Read its session_id before composing the next.
ENTITY_A_PROMPT=$(locus agent compose --traits "research,iterative,hypothesis-driven,systems-thinking" \
  --role "..." --task "<entity A context>")

allele_sessions_create(
  project: "<project>",
  name:    "<short label — this is the address>",
  prompt:  $ENTITY_A_PROMPT
)
```

```
# Only after the first has returned its session_id.
ENTITY_B_PROMPT=$(locus agent compose --traits "research,iterative,hypothesis-driven,systems-thinking" \
  --role "..." --task "<entity B context>")

allele_sessions_create(
  project: "<project>",
  name:    "<short label — this is the address>",
  prompt:  $ENTITY_B_PROMPT
)
```

### Exit condition

The investigation exits when:
- All CRITICAL and HIGH entities have dossiers, AND
- All categories in the landscape have at least one researched entity, AND
- The last iteration added no new entities to the rubric (the domain is closed).

On exit, the orchestrator writes `synthesis.md` — the answer that the collected vault produces. Synthesis is the orchestrator's job: it has read all the dossiers and can integrate across them. Do not delegate synthesis; the cross-entity reasoning is exactly what the orchestrator's context is for.

## URL verification

Every citation in every dossier must pass `UrlVerificationProtocol.md`. The scale of deep investigation multiplies the risk of hallucinated URLs; verification is non-negotiable. Verify URLs from the delegated report **before** writing them into a dossier — once they're in the vault, they look authoritative.

## Failure handling

- **Delegated research returns empty findings** — log the failure in the iteration log, mark the entity as "research-failed" in the rubric (not "not-yet-researched"), and move to the next entity. Do not retry blindly.
- **Delegated research times out** — same as empty findings; the orchestrator continues with what's done.
- **Rate-limited / `allele_sessions_create` failing across multiple iterations** — pause the investigation, surface the situation to the user, offer to resume later. Vault state is preserved on disk. Discard any sessions still held first: a paused investigation holding slots is the worst of both.
- **Every session discarded before the pass is logged.** A long investigation is the easiest place to leak slots, because no single iteration looks expensive.

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
- Sessions still held: N (should be zero on exit; name any that are not, and why)

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
- **Asking the delegate to write the dossier directly.** The delegate writes to *its own* workspace, not this one, so a dossier it writes never reaches the vault. It returns findings; the orchestrator writes the vault file. This is workspace isolation, not a permission — do not record it as "the delegate is read-only", which is true of `locus delegate run` and false of a dispatched session.
- **Delegating the cross-entity synthesis.** Synthesis is what the orchestrator's context is for. Delegating it loses the integration the vault was built to enable.
- **Reaching for a native Task subagent while allele is reachable.** It burns the orchestrator's context with the same investigation the vault exists to keep out of it. Route down the Algorithm's vehicle table; tier 3 is for when tiers 1 and 2 are both gone, and it is announced when taken.
- **Leaving sessions running between iterations.** Deep is the longest-lived workflow here and the one most likely to hold the global cap hostage. Reclaim at the end of every pass.
