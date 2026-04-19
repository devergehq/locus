---
id: parser
name: Parser
description: Extract structured data from URLs, files, transcripts, and documents into clean JSON or markdown.
triggers:
  - parse
  - extract
  - structured data
  - JSON
  - transcript
  - entities
  - extract from URL
  - extract from PDF
tags:
  - extraction
  - parsing
  - structured-data
requires:
  delegation: false
  inference: true
---

# Parser

Structured data extraction from diverse content sources. Takes unstructured input (URLs, files, transcripts, documents) and produces clean, typed output.

## Capabilities

### URL Extraction
Fetch a URL and extract structured content — article text, metadata, author, date, key entities.

### Transcript Extraction
Extract and process transcripts from YouTube videos, podcasts, or audio files.

### Entity Extraction
Identify and extract named entities (people, organisations, locations, technologies, dates) from any text content.

### Document Parsing
Extract structured data from PDFs, spreadsheets, and other document formats. Tables, forms, and metadata.

### Batch Processing
Process multiple inputs in sequence, producing a consistent output schema across all items.

## Output Formats

- JSON (structured, typed)
- Markdown (human-readable)
- YAML (configuration-friendly)
