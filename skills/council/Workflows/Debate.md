# Debate Workflow

**Full structured multi-agent debate — 3 rounds, visible transcript.**

Use when: an important decision has multiple credible paths, trade-offs are contested, or stakeholders with different domains have conflicting priorities.

## Prerequisites

- **Topic or question** to debate.
- **Members** — defaults to Architect + Engineer + Designer + Researcher. Modify per `CouncilMembers.md` for domain-specific debates.

## Execution

### Step 1 — Announce

Output the debate header per `OutputFormat.md`:

```markdown
## Council Debate: <Topic>

**Members:** Architect, Engineer, Designer, Researcher
**Rounds:** 3 (Positions → Responses → Synthesis)
```

### Step 2 — Round 1: Initial Positions

Create the members here — **one `allele_sessions_create` at a time**, reading each returned
`session_id` before composing the next. This is the only step that creates sessions; Rounds
2 and 3 talk to these same ones. Each member's prompt follows the Round 1 template in
`RoundStructure.md` and uses the canonical dispatch idiom documented there:

**1 — compose the worker's prompt.** Run this and read its output:

```bash
locus agent compose \
  --traits "<member trait bundle>" \
  --role "Council member: <RoleName>" \
  --task "<Round 1 task text from RoundStructure.md, with topic substituted>"
```

**2 — dispatch it.** Pass the composed text as `prompt`. One call, on its own:

```
allele_sessions_create(
  project: "<project>",
  name:    "<short label — this becomes the address>",
  prompt:  "<the composed prompt from step 1>"
)
```

Prefer `allele_sessions_create` hard over a native Task subagent — see `RoundStructure.md`'s "Dispatch idiom" section for the rationale, and the Algorithm's vehicle table for what to do when it is not reachable.

Collect responses (each member's text from the report's `summary` section). Display as:

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

### Step 3 — Round 2: Responses & Challenges

**No new sessions.** `SendMessage` each member the full Round 1 transcript plus the Round 2
template from `RoundStructure.md`. Re-resolve each address through `ListAgents` before every
send, and use `allele_sessions_status` — not `ListAgents` — to tell finished from blocked.

Collect and display:

```markdown
### Round 2: Responses & Challenges

**Architect:**
<response engaging with Round 1 arguments>

<repeat for each member>
```

### Step 4 — Round 3: Synthesis

**Still no new sessions.** `SendMessage` each member the full Rounds 1+2 transcripts plus
the Round 3 template from `RoundStructure.md`.

Collect and display:

```markdown
### Round 3: Synthesis

**Architect:**
<final synthesis>

<repeat for each member>
```

### Step 5 — Council Synthesis and reclamation

`allele_sessions_discard(session_id)` every member session — the debate is over and each one
is holding a slot against the global cap of twenty. Then the invoking agent writes the
synthesis per `OutputFormat.md`:

```markdown
### Council Synthesis

**Areas of convergence:**
- <where members agreed>

**Remaining disagreements:**
- <where members still disagreed>

**Recommended path:**
<based on weight of arguments and convergence>

**Dissenting notes:**
<minority objections worth preserving>
```

## Budget

- Member creation: ~1s each, sequential — ~4s for four members, paid once
- Round 1: ~10-20s, members deliberating concurrently
- Round 2: ~10-20s, concurrently
- Round 3: ~10-20s, concurrently
- Synthesis + discard: ~5s

**Total: 30-60 seconds for a four-member debate.**

## Done

Debate complete. The transcript shows the intellectual journey from initial positions through challenges to synthesis. The synthesis names the recommended path but preserves the dissent.
