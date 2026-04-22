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
  delegation: false
  inference: true
---

# Research

Multi-depth research framework that scales from quick single-pass lookups to extensive multi-agent parallel investigation and iterative deep investigation.

**Mandatory protocol:** `UrlVerificationProtocol.md`. Every URL returned must be verified — research agents hallucinate URLs, and a single broken link is a catastrophic failure.

## Researcher archetypes (not per-API theatre)

Locus does NOT use per-model-provider researcher theatre (ClaudeResearcher / GeminiResearcher / PerplexityResearcher). The evidence-backed design uses methodology-based researchers that differ in *how* they research, not which API they call. See the `agents/*-researcher.md` files:

- **academic-researcher** — peer-reviewed and preprint literature, citation discipline
- **investigative-researcher** — journalism-style triangulation and follow-the-lead
- **contrarian-researcher** — counter-evidence, dissenting positions
- **multi-angle-researcher** — orthogonal sub-query decomposition
- **deep-investigation-researcher** — iterative vault-building across passes

The underlying model is whatever the platform provides. The diversity is in method.

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

- **With delegation**: full multi-researcher parallel in Standard/Extensive/Deep modes.
- **Without delegation**: all modes fall back to sequential single-researcher execution. Still thorough via methodology rotation, but slower and less diverse per unit time.

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
- **delegation** skill — for parallel researcher dispatch
- **extract-wisdom** — for insight extraction from specific sources
- **iterative-depth** — for multi-angle research decomposition
