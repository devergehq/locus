# Adversarial Claim Verification Protocol

**MANDATORY for all research workflows in this skill.**

## Purpose

Research agents — regardless of methodology — can report claims that are widespread but wrong. Methodology diversity ensures coverage (did we look in enough places?). Adversarial verification ensures validity (is what we found actually true?). Both are required.

## When this runs

After synthesis, before URL verification. The orchestrator extracts discrete claims from the synthesised findings, then dispatches adversarial verifiers to pressure-test each one.

## Step 1 — Claim extraction

The orchestrator (not a delegate) extracts falsifiable claims from the synthesised findings. Each claim must have:

```
{
  claim:         "<concrete, checkable assertion — not a vague generality>",
  quote:         "<direct quote from source that supports the claim>",
  sourceUrl:     "<URL where the quote was found>",
  sourceQuality: "<primary | secondary | blog | forum | unreliable>",
  importance:    "<central | supporting | tangential>",
  methodology:   "<which researcher archetype surfaced this>"
}
```

**Extraction rules:**
- Only extract claims that are **falsifiable** — "X is interesting" is not a claim; "X reduces latency by 30%" is.
- One claim per assertion. "X improves speed and reduces cost" is two claims.
- The quote must be a **direct excerpt** from the source, not a paraphrase.
- If the source is cited but no direct quote is available, mark `sourceQuality: "unreliable"` regardless of the source's actual authority — unquoted claims are unanchored.
- Prioritise central claims. If the synthesis produced >15 claims, verify central and supporting only; log tangential claims as unverified.

### Source quality ratings

| Rating | Definition | Example |
|---|---|---|
| **primary** | Original research, official documentation, first-party data | Peer-reviewed paper, API docs, company earnings report |
| **secondary** | Reporting on primary sources, informed analysis | Tech journalism citing a paper, industry analysis |
| **blog** | Opinion, experience report, tutorial | Personal blog, Medium post, dev.to article |
| **forum** | Community discussion, unverified claims | Reddit, HN comments, Stack Overflow answers |
| **unreliable** | Marketing, press release, unquoted, fetch-failed | Product landing page, PR wire, broken URL |

## Step 2 — Adversarial verification dispatch

For each extracted claim, dispatch **3 adversarial verifiers** via `allele_sessions_create`. Use the `adversarial-verifier` agent definition (traits: `research,skeptical,adversarial,empirical`).

```bash
VERIFY_PROMPT=$(locus agent compose \
  --traits "research,skeptical,adversarial,empirical" \
  --role "Adversarial claim verifier (voter N/3)" \
  --task "Try to REFUTE this claim. ≥2/3 refutations kill it.

Claim: \"<claim text>\"
Source: <sourceUrl> (<sourceQuality>)
Supporting quote: \"<quote>\"

Checklist:
1. Does the quote actually support the claim, or is it overreach/misread?
2. WebSearch for contradicting evidence — does any credible source dispute or heavily qualify this?
3. Is the source quality sufficient for the claim's strength? (extraordinary claims need primary sources)
4. Is the claim outdated? (check dates — old claims about fast-moving fields are suspect)
5. Is this a marketing claim / press release / cherry-picked benchmark / forum speculation?

refuted=true if: unsupported by quote / contradicted / low-quality source for strong claim / outdated / marketing fluff.
refuted=false ONLY if: claim is well-supported, current, and source quality matches claim strength.
Default to refuted=true if uncertain.

Return JSON: {refuted: bool, evidence: string, confidence: 'high'|'medium'|'low', counterSource: string|null}")

allele_sessions_create(
  project: "<project>",
  name:    "<short label — this is the address>",
  prompt:  $VERIFY_PROMPT
)
```

**Dispatch rules:**
- All 3 votes for a single claim go in the **same assistant message** for parallelism.
- Multiple claims can be verified in the same batch — dispatch all votes for all claims together if the platform allows it.
- Each verifier is independent — they do not see each other's verdicts.

## Step 3 — Voting

| Votes to refute | Outcome |
|---|---|
| 3/3 refute | **Killed** — strong consensus against |
| 2/3 refute | **Killed** — majority refutes |
| 1/3 refute | **Survives** — majority supports |
| 0/3 refute | **Survives** — unanimous support |

**Edge cases:**
- If a verifier delegate fails (timeout, rate limit, error), treat as **abstain**. Need at least 2 valid votes to adjudicate.
- If only 1 valid vote: the claim is **unverified** — flag it as such in output rather than passing or killing.
- If 0 valid votes: the claim is **unverified**.

## Step 4 — Classification

After voting, claims fall into three categories:

1. **Confirmed** — survived with ≥2 supporting votes. Include in final output with vote tally and confidence.
2. **Refuted** — killed with ≥2 refuting votes. List in a transparency section with the refutation evidence.
3. **Unverified** — insufficient valid votes to adjudicate. Flag explicitly.

## Output format

Research output must include:

```markdown
### Verified Findings (survived adversarial review)
1. <claim> — vote: 3-0 survive · source: <url> · confidence: high
2. <claim> — vote: 2-1 survive · source: <url> · confidence: medium

### Refuted Claims (for transparency)
- "<claim>" — vote: 1-2 refuted · reason: <verifier's evidence>
- "<claim>" — vote: 0-3 refuted · reason: <counter-evidence found>

### Unverified Claims
- "<claim>" — insufficient votes to adjudicate
```

**The Refuted section is not optional.** Transparency about what was killed and why is part of the epistemic contract. The user should see what didn't survive and judge for themselves.

## Cost profile

Per claim: 3 delegate calls × ~10-15s each (parallel) ≈ 15s wall-clock per batch.

| Mode | Typical claims | Verification delegates | Added latency |
|---|---|---|---|
| Quick | 2-4 | 6-12 | ~15s |
| Standard | 5-10 | 15-30 | ~15-30s |
| Extensive | 10-20 | 30-60 | ~15-30s |
| Deep | per-entity | 3-15 per entity | ~15s per entity pass |

All claims within a batch verify in parallel, so wall-clock cost scales with batch count (typically 1-2 batches), not claim count.

## Relationship to URL verification

Adversarial verification and URL verification are **independent protocols**. Both are mandatory. They test different things:

- **Adversarial verification** — is the claim true? (content validity)
- **URL verification** — does the source exist and match? (citation integrity)

Run adversarial verification first, then URL verification on surviving claims only (no need to verify URLs for claims that were killed).

## Anti-patterns

- **Skipping verification for "obvious" claims.** Obvious claims are the ones most likely to be wrong — they survive because nobody checks them.
- **Reducing to 1 vote per claim.** A single verifier has a ~30-40% false negative rate. Three votes with majority rule is the minimum for reliable adjudication.
- **Treating "not refuted" as "confirmed."** A claim that wasn't refuted because the verifier couldn't find counter-evidence is not the same as a claim with positive supporting evidence. The default-to-refuted bias handles this.
- **Hiding the refuted section.** If the user can't see what was killed, they can't judge the filter's quality.
