# Output Format

Council debates produce **visible transcripts**. The user can read the actual conversation, not just the synthesis. This is load-bearing — the value is in the reasoning path, not just the destination.

## Debate header

```markdown
## Council Debate: <Topic>

**Members:** <list of members participating, with trait bundles>
**Rounds:** 3 (Positions → Responses → Synthesis)
```

## Per-round header

```markdown
### Round N: <Round Name>
```

## Per-member response

```markdown
**<Role>:**
<response text>
```

Keep markers minimal — the role name in bold is enough. No emojis, no character tags, no role-plays. The output is a professional transcript, not a chat log.

## After all rounds

```markdown
### Council Synthesis

**Areas of convergence:**
- <bullet points>

**Remaining disagreements:**
- <bullet points>

**Recommended path:**
<prose recommendation, 1-3 paragraphs>

**Dissenting notes (if any):**
<prose, preserving minority objection>
```

## What the transcript is *not*

- Not a chat simulation. No "Hi everyone, I think..." conversational fluff.
- Not a role-play. No "*Architect rolls eyes*" character notes.
- Not a voice recording. No audio markers, no prosody, no vocal instructions.

The transcript is a structured record of cognitive positions and the arguments between them. It should read like minutes from a meeting of competent professionals, not like fiction.

## Preserving evidence

When a member cites specific evidence (a paper, a metric, a past incident, a documented principle), the transcript preserves it verbatim. Paraphrased evidence loses its force.

## Length discipline

Each member's contribution per round: 50-150 words. The synthesis: 100-400 words.

Long-winded responses are not more insightful — they hide the position. Hold members to the word budget in their prompts.
