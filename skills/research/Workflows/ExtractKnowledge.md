# Extract Knowledge Workflow

**Extract structured knowledge from a specific source — not summarisation, not alpha, but explicit knowledge-graph-style capture.**

Different from:
- **Summarise** — compresses; Extract Knowledge structures.
- **Extract Alpha** — filters for highest-signal insights; Extract Knowledge captures *everything* worth knowing, in a structured form.
- **Extract Wisdom** (separate skill) — ideas, insights, quotes, habits in a defined template; Extract Knowledge is more schema-flexible.

## When to use

- Turning a long article, paper, chapter, or transcript into structured reference material.
- Building up a knowledge base from primary sources.
- Preparing research material for later synthesis with other sources.

## Execution

### Step 1 — Ingest the content

Load the source — article, PDF, transcript, etc. Note provenance (URL, author, date).

### Step 2 — Choose the schema

Pick a schema appropriate to the content type:

| Content type         | Schema                                                                                |
|----------------------|---------------------------------------------------------------------------------------|
| Research paper       | Claim → Evidence → Method → Limitations → Citations                                   |
| Interview / podcast  | Person → Claim → Supporting anecdote → Timestamp                                      |
| Technical article    | Concept → Definition → Mechanism → Example → Counter-example                          |
| Narrative / history  | Event → Date → Actors → Outcome → Primary sources                                     |
| Reference material   | Entity → Attributes → Relationships → Source                                          |

Custom schemas are acceptable — declare the schema up front.

### Step 3 — Extract into the schema

Work through the content. For each load-bearing item:

- Fill the schema fields for that item.
- Preserve direct quotes where the phrasing matters.
- Cite the location (page / timestamp) within the source.

### Step 4 — Verify

- Every external citation in the extraction must pass `UrlVerificationProtocol.md`.
- Every direct quote must be verbatim — paraphrase drift is a fabrication.
- Every fact attributed to the source must actually be in the source.

### Step 5 — Output

```markdown
## Knowledge Extract: <Source title>

**Provenance:** <author, venue, date, verified URL>
**Schema:** <chosen schema name>

### Entries

**Entry 1:**
- <field 1>: <value>
- <field 2>: <value>
- <field 3>: <value>
- Source location: <page / timestamp>
- Direct quote (if applicable): "..."

**Entry 2:**
...

### Cross-references
<relationships between entries, if schema is relational>

### Verified sources
- <URL 1>
- ...
```

## Storage

Extracts can be persisted to `{data}/memory/research/knowledge/{YYYY-MM}/{source-slug}.md` for later reuse. Useful when building up reference material over time.

## Anti-patterns

- **Paraphrasing quotes.** If a phrasing matters, quote it verbatim; if not, drop the pretence of quoting.
- **Extracting trivia.** A knowledge extract is load-bearing reference material; not every fact in the source warrants extraction.
- **Hallucinating schema fields.** If the source doesn't provide a field the schema requires, mark it "not specified in source" — do not invent.

## Budget

Scales with source length: short article ~3 minutes, long paper ~10 minutes, book chapter ~20 minutes. Chunk long sources and extract in passes.
