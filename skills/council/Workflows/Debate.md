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

Dispatch N parallel `locus delegate run` calls (one per member) in a single assistant message. Each member's prompt follows the Round 1 template in `RoundStructure.md` and uses the canonical dispatch idiom documented there:

```bash
PROMPT=$(locus agent compose \
  --traits "<member trait bundle>" \
  --role "Council member: <RoleName>" \
  --task "<Round 1 task text from RoundStructure.md, with topic substituted>")

locus delegate run \
  --backend opencode \
  --task-kind general \
  --mode native \
  --dir . \
  --prompt "$PROMPT" \
  --output json
```

**DO NOT use the platform Task tool for this step** — see `RoundStructure.md`'s "Dispatch idiom" section for the rationale.

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

### Step 3 — Round 2: Responses & Challenges

Dispatch N parallel `locus delegate run` calls, each `--task` text including the full Round 1 transcript per the Round 2 template in `RoundStructure.md`. Same dispatch idiom as Step 2 — only the `--task` text changes.

Collect and display:

```markdown
### Round 2: Responses & Challenges

**Architect:**
<response engaging with Round 1 arguments>

<repeat for each member>
```

### Step 4 — Round 3: Synthesis

Dispatch N parallel `locus delegate run` calls with the full Rounds 1+2 transcripts inlined per the Round 3 template in `RoundStructure.md`. Same dispatch idiom as Step 2.

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
