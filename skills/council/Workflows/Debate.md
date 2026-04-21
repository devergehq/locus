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

Launch N parallel delegations (one per member). Each member's prompt follows the Round 1 template in `RoundStructure.md`, composed from their trait bundle.

For each member, compose their prompt via:

```
locus agent compose --traits "<trait-bundle>" \
                    --role "Council member: <RoleName>" \
                    --task "Round 1 initial position on: <topic>" \
                    --output prompt
```

(If the `locus agent compose` CLI is not yet available, hand-compose the prompt by concatenating the trait `prompt_fragment` entries from `agents/traits.yaml`.)

Collect responses. Display as:

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

Launch N parallel delegations, each prompt including the full Round 1 transcript. Each member's prompt follows the Round 2 template in `RoundStructure.md`.

Collect and display:

```markdown
### Round 2: Responses & Challenges

**Architect:**
<response engaging with Round 1 arguments>

<repeat for each member>
```

### Step 4 — Round 3: Synthesis

Launch N parallel delegations with full Rounds 1+2 transcripts. Round 3 template in `RoundStructure.md`.

Collect and display:

```markdown
### Round 3: Synthesis

**Architect:**
<final synthesis>

<repeat for each member>
```

### Step 5 — Council Synthesis

The invoking agent writes the synthesis per `OutputFormat.md`:

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

- Round 1: ~10-20s parallel
- Round 2: ~10-20s parallel
- Round 3: ~10-20s parallel
- Synthesis: ~5s

**Total: 30-60 seconds for a four-member debate.**

## Done

Debate complete. The transcript shows the intellectual journey from initial positions through challenges to synthesis. The synthesis names the recommended path but preserves the dissent.
