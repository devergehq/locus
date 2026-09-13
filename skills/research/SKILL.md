---
id: research
name: Research
description: Comprehensive research with progressive depth modes — from quick single-pass to extensive multi-agent parallel investigation. Methodology-based researcher agents (academic, investigative, contrarian, multi-angle, deep-investigation) rather than per-API-provider theatre.
triggers:
  - research
  - do research
  - quick research
  - extensive research
  - deep investigation
  - find information
  - investigate
  - extract alpha
  - extract knowledge
  - interview research
  - youtube extraction
  - web scraping
  - enhance content
tags:
  - research
  - information-gathering
requires:
  delegation: true
  inference: true
---

# Research

Multi-depth research framework that scales from quick single-pass lookups to extensive multi-agent parallel investigation and iterative deep investigation.

**Mandatory protocols:**
- `UrlVerificationProtocol.md` — every URL returned must be verified. Research agents hallucinate URLs, and a single broken link is a catastrophic failure.
- `AdversarialVerificationProtocol.md` — every falsifiable claim is pressure-tested by 3 adversarial verifiers before inclusion. Methodology diversity ensures coverage; adversarial verification ensures validity. Both are required across all modes.

## Dispatch discipline

This skill does not restate the dispatch rules — restated rules drift. The canonical text is
the **Dispatch** section of `algorithm/v2.0.md`, shipped as the `locus-algorithm` skill.
Three of its rules bind every dispatch in this skill and its workflows:

- **One `allele_sessions_create` at a time**, with its result read before the next is
  issued. Never batch creates into a single assistant message. Researchers run concurrently
  once created; only the creates queue, at about a second each.
- **Global cap of twenty** concurrent dispatched sessions, aggregate across every dispatcher
  on the machine — not per-run. Extensive mode's 12 researchers and the verification fan-out
  both have to fit inside it, which is why both run in waves.
- **Every researcher and every verifier is reclaimed** with `allele_sessions_discard` once
  its report is read, or recorded as still working with a reason.

## Execution model

**The research skill is the orchestrator. The research work runs in dispatched allele
sessions — each with its own context and its own workspace.**

The orchestrator (this Claude session) is responsible for:
- Choosing methodology mix (academic / investigative / contrarian / multi-angle / deep-investigation)
- Deciding agent count (1 for Quick, 3 for Standard, 12 for Extensive, 1×N passes for Deep)
- Composing per-agent prompts (via `locus agent compose --traits ... --role ... --task ...`)
- Synthesising the returned reports (convergence, contradictions, gaps)
- Extracting falsifiable claims and dispatching adversarial verification (3 votes per claim)
- Verifying every URL before returning results

The work itself — running searches, reading sources, drafting findings, citing — runs in a dispatched allele session created via `allele_sessions_create`. The orchestrator never does the raw research itself; it dispatches, synthesises, and reclaims.

**Why:** raw research output (search results, page reads, scratch reasoning) is voluminous and would burn the orchestrator's context. The dispatched session replies with a report in the standard shape (`summary`, `findings`, `evidence`, `risks`, `files_referenced`) — only the synthesis enters this context.

**Prefer `allele_sessions_create` hard over a native Task subagent.** A Task subagent is another Claude burning this session's context budget and inheriting its framing, which costs methodology diversity — the thing the archetypes exist to produce. The preference is not a prohibition: when no sanctioned vehicle is reachable, route down the Algorithm's vehicle table and announce the degradation rather than stalling.

## Researcher archetypes (methodology, not per-API theatre)

Locus does NOT use per-model-provider researcher theatre (ClaudeResearcher / GeminiResearcher / PerplexityResearcher). The evidence-backed design uses methodology-based researchers that differ in *how* they research, not which API they call. The methodology is encoded in the trait bundle passed to `locus agent compose` and in the role/task framing of the delegated prompt:

- **academic-researcher** — peer-reviewed and preprint literature, citation discipline
- **investigative-researcher** — journalism-style triangulation and follow-the-lead
- **contrarian-researcher** — counter-evidence, dissenting positions
- **multi-angle-researcher** — orthogonal sub-query decomposition
- **deep-investigation-researcher** — iterative vault-building across passes

See the `agents/*-researcher.md` files for the trait bundles each archetype uses. The underlying model that runs the delegated process is whatever `~/.locus/locus.yaml` resolves for `delegation.defaults.opencode.research.model` (currently `openai/gpt-5.5`); the diversity per archetype is in the trait composition, not the model.

## Workflow routing

| Intent / Trigger                                                    | Workflow                                |
|---------------------------------------------------------------------|-----------------------------------------|
| "quick research", factual lookup, single question                   | `Workflows/Quick.md`                    |
| "research X", "do research", default                                | `Workflows/Standard.md`                 |
| "extensive research", "thorough research"                           | `Workflows/Extensive.md`                |
| "deep investigation", "map the X landscape"                         | `Workflows/Deep.md`                     |
| "interview research", "interview prep"                              | `Workflows/Interview.md`                |
| "extract alpha", "highest-alpha insight"                            | `Workflows/ExtractAlpha.md`             |
| "extract knowledge from X", "extract insights from X"               | `Workflows/ExtractKnowledge.md`         |
| "YouTube research", "extract from YouTube"                          | `Workflows/YoutubeExtraction.md`        |
| "web scraping", "scrape page"                                       | `Workflows/WebScraping.md`              |
| "enhance content", "improve this article"                           | `Workflows/Enhance.md`                  |
| "retrieve this content", "fetch past CAPTCHA"                       | `Workflows/Retrieve.md`                 |

## Mode summary

### Quick
Single researcher, single query, adversarial verification on extracted claims. ~25-30 seconds. Best for factual lookups, API documentation, well-scoped questions.

### Standard (default)
3 methodology-diverse researchers in parallel (typically: academic + multi-angle + investigative), adversarial verification on synthesised claims. ~30-60 seconds. Best for most research requests.

### Extensive
12 researchers — 3-way parallel expansion across 4 methodology types, adversarial verification on cross-sub-query claims. ~90-120 seconds. Best when the question has multiple facets and confidence matters.

### Deep
Iterative deep-investigation researcher, persistent vault across sessions, per-entity adversarial verification. 3-60 minutes depending on scope. Best for landscape mapping and complex domains where single-pass is insufficient.

## Degradation

Route down the Algorithm's **Which vehicle** table and stop at the first available row; the
rows below say only what research specifically loses at each one.

- **Allele reachable** (tier 1): full multi-researcher execution across Standard / Extensive / Deep. Creates are issued one at a time; the researchers then run concurrently.
- **Allele reachable but every slot taken**: busy is not absent. Wait, or reclaim a slot with `allele_sessions_discard`. Slot pressure never unlocks a less observable vehicle.
- **`locus delegate run --backend opencode`** (tier 2): the research still runs out-of-context with its trait composition intact, but it returns an envelope rather than replying — no follow-up question, no clarification. Say so.
- **Native `Task` subagents** (tier 3, last resort): the raw research burns this session's context and the researchers share its framing, so convergence between archetypes stops being evidence of anything. State that above the findings.
- **Nothing reachable**: in-context execution via `web_search` + `web_fetch`, methodology rotation kept, and say plainly that the orchestrator's context absorbed the raw research.
- **Partial failure across N delegations**: if M of N succeed (M ≥ 1), synthesise from the M and list the failed researcher(s) under `Gaps`. Do not retry blindly — flag and move on. Discard the failed sessions too; a failed session still holds a slot.
- **Without web access at all**: the worker reports empty `findings` and says so under `risks`. Surface the gap; don't fabricate.

The `allele_*` tools are MCP tools, not a binary — their absence means allele is not running
and this session is outside it, which is a normal way to run Locus rather than a broken
install.

## Output discipline

Every research output ends with:

- **Verified Findings** — numbered, each with citation and adversarial vote tally (e.g., "3-0 survive")
- **Refuted Claims** — claims killed by adversarial verification, with the refutation evidence (transparency is mandatory)
- **Confidence** — where evidence is strong vs weak, informed by both methodology convergence and verification vote tallies
- **Contradictions** — where sources disagree, flagged
- **Gaps** — what couldn't be found
- **Sources** — verified URLs only; every one passed the UrlVerificationProtocol

Never cite a URL you have not verified resolves. Never include a claim that has not survived adversarial verification.

## Integration

### Feeds into
- **first-principles** — research surfaces assumptions to decompose
- **council** — research informs multi-perspective debate
- **red-team** — research grounds adversarial analysis

### Uses
- **`allele_sessions_create`** — the actual research execution; this skill is the orchestrator only
- **`locus agent compose`** — builds methodology-specific prompts before dispatch
- **extract-wisdom** — for insight extraction from specific sources
- **iterative-depth** — for multi-angle research decomposition

The general `delegation` skill is not needed for research dispatch — see "Execution model" above for the direct `allele_sessions_create` path.
