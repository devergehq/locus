# Round Structure

Council debates run in **three rounds**. Each round has a specific purpose. Running fewer rounds produces shallow consensus; running more rounds produces diminishing returns and drift.

## Why three rounds

- **Round 1** surfaces initial positions without interference. Each member responds from their own trait bundle, uncontaminated by others' arguments. Maximum perspective diversity.
- **Round 2** forces genuine engagement with other members' actual arguments. This is where intellectual friction produces insight — not the initial positions themselves.
- **Round 3** tests whether anyone changed their mind and forces honest synthesis. Unresolved disagreement is more valuable than forced consensus.

Two rounds are insufficient: members state positions and rebut once, with no chance to revisit after hearing the rebuttal. Four or more rounds produces diminishing insight and increases persona drift risk.

## Round 1 — Initial Positions

**Parallel execution.** Launch one delegation per member, all in a single message.

**Each member's prompt:**

```
<trait-composed role>

COUNCIL DEBATE - ROUND 1: INITIAL POSITIONS

Topic: <the question being debated>

Give your initial position on this topic from your composed stance.

- Be specific and substantive (50-150 words).
- State your key concern, recommendation, or insight.
- Do not hedge — take a position.
- You will engage with other members' positions in Round 2.
```

**Collect** the four responses. **Display** the transcript in full before proceeding.

## Round 2 — Responses & Challenges

**Parallel execution, with full Round 1 transcript in each member's prompt.**

**Each member's prompt:**

```
<trait-composed role>

COUNCIL DEBATE - ROUND 2: RESPONSES & CHALLENGES

Topic: <the question being debated>

Round 1 transcript:
<full Round 1, all members' positions>

Now respond to the other members:

- Reference specific points they made — "I disagree with the Engineer's point about X because..."
- Challenge assumptions you see in their arguments.
- Build on points you agree with, adding your own angle.
- Maintain your composed stance — do not soften for politeness.
- 50-150 words.

The value is in genuine intellectual friction — engage with their actual arguments, not strawmen.
```

## Round 3 — Synthesis

**Parallel execution, with full Rounds 1 + 2 transcripts.**

**Each member's prompt:**

```
<trait-composed role>

COUNCIL DEBATE - ROUND 3: SYNTHESIS

Topic: <the question being debated>

Full transcript so far:
<Rounds 1 + 2>

Provide your final synthesis:

- Where does the council agree? (If anywhere.)
- Where do you still disagree, and why?
- What is your final recommendation given the full discussion?
- If your position has evolved, say so explicitly and why.
- 50-150 words.

Be honest about remaining disagreements. Forced consensus is worse than acknowledged tension.
```

## After Round 3 — Council Synthesis

The invoking agent (not the members) writes the final synthesis:

```
### Council Synthesis

**Areas of convergence:**
- <points where 3+ members agreed>

**Remaining disagreements:**
- <points still contested>
- <trade-offs that could not be resolved>

**Recommended path:**
<based on the weight of arguments and convergence, the path is...>

**Dissenting notes:**
<any member's remaining objection worth preserving>
```

The synthesis is **not** the mode of the responses. It weighs arguments for evidence, logical structure, and how well each engaged with others' actual points.

## Timing

Each parallel round is as fast as the slowest member (~10-20 seconds per round). Three rounds + synthesis ≈ 30-60 seconds for a four-member debate.

This is the budget for the **Debate** workflow. The **Quick** workflow is Round 1 only — ~10-20 seconds total.
