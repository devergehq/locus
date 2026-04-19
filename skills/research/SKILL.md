---
id: research
name: Research
description: Comprehensive research with progressive depth modes — from quick single-pass to extensive multi-agent parallel investigation.
triggers:
  - research
  - do research
  - quick research
  - extensive research
  - deep investigation
  - find information
  - investigate
tags:
  - research
  - information-gathering
requires:
  delegation: false
  inference: true
---

# Research

Multi-depth research framework that scales from quick single-agent lookups to extensive multi-agent parallel investigation.

## Workflows

### Quick
Single-pass research. One focused investigation, immediate results. Best for factual lookups, API documentation, or well-scoped questions. No delegation required.

### Standard
Structured research with multiple angles. Gathers context from 2-3 perspectives, synthesises findings. No delegation required but benefits from it.

### Extensive
Multi-agent parallel research (requires delegation). Launches 4-8 specialised research agents simultaneously — each exploring a different facet of the question. Results are synthesised into a comprehensive report. Falls back to sequential Standard mode if delegation is unavailable.

### Deep
Iterative investigation with hypothesis refinement (requires delegation). Multiple rounds of research where findings from each round inform the next. Best for complex, poorly-understood domains. Falls back to Standard mode if delegation is unavailable.

## Degradation

- **With delegation**: Full multi-agent parallel research in Extensive/Deep modes.
- **Without delegation**: Extensive/Deep fall back to sequential Standard-style execution. Still thorough, but slower and less diverse in perspectives.
