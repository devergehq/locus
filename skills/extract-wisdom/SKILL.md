---
id: extract-wisdom
name: Extract Wisdom
description: Content-adaptive extraction of insights, patterns, and actionable knowledge from videos, podcasts, articles, and documents.
triggers:
  - extract wisdom
  - analyze video
  - analyze podcast
  - extract insights
  - what's interesting
  - what did I miss
  - key takeaways
  - content analysis
tags:
  - analysis
  - content
  - extraction
requires:
  delegation: false
  inference: true
---

# Extract Wisdom

Content-adaptive wisdom extraction that detects what domains exist in the content and builds custom analysis sections. Not a fixed template — the output structure adapts to what's actually in the material.

## Process

1. **Ingest** — Load the content (transcript, article text, document)
2. **Domain detection** — What fields does this content cover? (technology, business, philosophy, science, etc.)
3. **Build custom sections** — For each detected domain, extract:
   - Key insights (non-obvious observations)
   - Actionable recommendations
   - Mental models or frameworks introduced
   - Surprising claims worth verifying
   - Quotes worth preserving
4. **Synthesise** — Cross-domain connections, overall themes, and a concise summary

## Input Types

- YouTube videos (via transcript extraction)
- Podcast episodes (via transcript)
- Articles and blog posts (via URL or text)
- PDFs and documents
- Raw text or notes
