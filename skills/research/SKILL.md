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

**Mandatory protocol:** `UrlVerificationProtocol.md`. Every URL returned must be verified — research agents hallucinate URLs, and a single broken link is a catastrophic failure.

## Execution model

**The research skill is the orchestrator. The research work runs in OpenCode via `locus delegate run`.**

The orchestrator (this Claude session) is responsible for:
- Choosing methodology mix (academic / investigative / contrarian / multi-angle / deep-investigation)
- Deciding agent count (1 for Quick, 3 for Standard, 12 for Extensive, 1×N passes for Deep)
- Composing per-agent prompts (via `locus agent compose --traits ... --role ... --task ...`)
- Synthesising returned envelopes (convergence, contradictions, gaps)
- Verifying every URL before returning results

The work itself — running searches, reading sources, drafting findings, citing — runs in a delegated OpenCode process per `locus delegate run --backend opencode --task-kind research`. The orchestrator never does the raw research itself; it dispatches and synthesises.

**Why:** raw research output (search results, page reads, scratch reasoning) is voluminous and would burn the orchestrator's context. The delegated process returns a compact JSON envelope (`summary`, `findings`, `evidence`, `risks`, `files_referenced`) — only the synthesis enters this context.

**DO NOT use the platform-native Task tool for research dispatch.** Task-tool subagents are other Claudes burning the same context budget. Research dispatch goes through `locus delegate run`, which runs an entirely different model (typically `openai/gpt-5.5`) under a different provider.

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
Single researcher, single query. ~10-15 seconds. Best for factual lookups, API documentation, well-scoped questions.

### Standard (default)
3 methodology-diverse researchers in parallel (typically: academic + multi-angle + investigative). ~15-30 seconds. Best for most research requests.

### Extensive
12 researchers — 3-way parallel expansion across 4 methodology types. ~60-90 seconds. Best when the question has multiple facets and confidence matters.

### Deep
Iterative deep-investigation researcher, persistent vault across sessions. 3-60 minutes depending on scope. Best for landscape mapping and complex domains where single-pass is insufficient.

## Degradation

- **With `locus delegate run` available**: parallel multi-researcher execution across Standard/Extensive/Deep — three or more `locus delegate run` Bash calls dispatched in a single assistant message.
- **`locus delegate run` available but rate-limited / failing**: degrade to *sequential* `locus delegate run` calls (one researcher at a time). Slower, but the work still happens out-of-context and the envelope semantics are unchanged.
- **`locus delegate run` not on PATH** (development environment, foreign machine): fall back to in-context execution via `web_search` + `web_fetch`. The orchestrator's context absorbs the raw research — accept the cost and keep the methodology rotation. Note this in the response so the user knows context was burned.
- **Partial failure across N parallel delegations**: if M of N succeed (M ≥ 1), synthesise from the M results and list the failed researcher(s) under the `Gaps` section of the output. Do not retry blindly — flag and move on.
- **Without web access at all** (delegated process can't browse): the OpenCode side will return an envelope with empty `findings` and a risk note. Surface the gap; don't fabricate.

## Output discipline

Every research output ends with:

- **Findings** — numbered, each with a citation
- **Confidence** — where evidence is strong vs weak
- **Contradictions** — where sources disagree, flagged
- **Gaps** — what couldn't be found
- **Sources** — verified URLs only; every one passed the UrlVerificationProtocol

Never cite a URL you have not verified resolves.

## Integration

### Feeds into
- **first-principles** — research surfaces assumptions to decompose
- **council** — research informs multi-perspective debate
- **red-team** — research grounds adversarial analysis

### Uses
- **`locus delegate run --backend opencode --task-kind research`** — the actual research execution; this skill is the orchestrator only
- **`locus agent compose`** — builds methodology-specific prompts before dispatch
- **extract-wisdom** — for insight extraction from specific sources
- **iterative-depth** — for multi-angle research decomposition

The general `delegation` skill is not needed for research dispatch — see "Execution model" above for the direct `locus delegate run` path.
