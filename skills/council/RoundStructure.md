# Round Structure

Council debates run in **three rounds**. Each round has a specific purpose. Running fewer rounds produces shallow consensus; running more rounds produces diminishing returns and drift.

## Why three rounds

- **Round 1** surfaces initial positions without interference. Each member responds from their own trait bundle, uncontaminated by others' arguments. Maximum perspective diversity.
- **Round 2** forces genuine engagement with other members' actual arguments. This is where intellectual friction produces insight — not the initial positions themselves.
- **Round 3** tests whether anyone changed their mind and forces honest synthesis. Unresolved disagreement is more valuable than forced consensus.

Two rounds are insufficient: members state positions and rebut once, with no chance to revisit after hearing the rebuttal. Four or more rounds produces diminishing insight and increases persona drift risk.

## Dispatch idiom

**Create each member once, one `allele_sessions_create` at a time**, reading the returned
`session_id` before composing the next member. Rounds 2 and 3 then reach those same sessions
with `SendMessage` — they do not create new ones. The members deliberate concurrently; only
the creates queue, at about a second each. The rule and its reason are in the Algorithm's
**Dispatch** section; `SKILL.md`'s "Dispatch discipline" points at it.

Prefer `allele_sessions_create` hard over a native Task subagent — Task subagents burn the
orchestrator's context budget and inherit its framing, which makes member agreement
worthless as evidence. When no sanctioned vehicle is reachable, route down the Algorithm's
vehicle table and announce the degradation.

The shape of each member's opening dispatch is:

**1 — compose the worker's prompt.** Run this and read its output:

```bash
locus agent compose \
  --traits "<member trait bundle>" \
  --role "Council member: <RoleName>" \
  --task "<round-specific task; see per-round prompts below>"
```

**2 — dispatch it.** Pass the composed text as `prompt`. One call, on its own; read the
returned `session_id` before composing the next member:

```
allele_sessions_create(
  project: "<project>",
  name:    "<short label — this becomes the address>",
  prompt:  "<the composed prompt from step 1>"
)
```

The report's `summary` is the member's response; the orchestrator collects the N reports and assembles the transcript before the next round.

**3 — reclaim.** After Round 3 is collected, `allele_sessions_discard(session_id)` every
member. A four-member debate that leaves four sessions running has taken a fifth of the
global cap and given it to nobody.

## Round 1 — Initial Positions

**Create the members here, one at a time.** One `allele_sessions_create` per member,
each result read before the next is issued. This is the only round that creates sessions.

**Each member's `--task` text:**

```
COUNCIL DEBATE - ROUND 1: INITIAL POSITIONS

Topic: <the question being debated>

Give your initial position on this topic from your composed stance.

- Be specific and substantive (50-150 words).
- State your key concern, recommendation, or insight.
- Do not hedge — take a position.
- You will engage with other members' positions in Round 2.
```

**Collect** the responses (each from the report's `summary` section) and **display** the transcript in full before proceeding.

## Round 2 — Responses & Challenges

**Talk to the members you already created.** `SendMessage` each member the full Round 1
transcript plus the task text below — no new `allele_sessions_create` calls. Resolve the
address through `ListAgents` at every send; refs rotate. Use `allele_sessions_status` to
tell a member that has finished (`response_ready`) from one blocked on a permission prompt
(`awaiting_input`) — `ListAgents` cannot distinguish them.

**Each member's `--task` text:**

```
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

**Note on prompt size:** for a 4-member debate this Round-2 task text is ~1-2 KB (Round 1 transcript). Well within bounds.

## Round 3 — Synthesis

**Same sessions again.** `SendMessage` each member the full Rounds 1 + 2 transcripts plus
the task text below. Still no new creates. Discard every member session once the round is
collected.

**Each member's `--task` text:**

```
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

**Note on prompt size:** for a 4-member debate the Rounds-1+2 transcript is ~3-4 KB per Round-3 task text. Still fine; no truncation needed.

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

Members deliberate concurrently, so each round is as fast as the slowest member (~10-20
seconds per round). Three rounds + synthesis ≈ 30-60 seconds for a four-member debate, plus
about four seconds of sequential creates in Round 1 — paid once, not per round, because
Rounds 2 and 3 reuse the sessions.

This is the budget for the **Debate** workflow. The **Quick** workflow is Round 1 only — ~10-20 seconds total.
