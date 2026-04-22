# Extract Alpha Workflow

**Extract the highest-signal, least-obvious insights from a piece of content.** "Alpha" here means edge — the insight that most readers would miss, the reframe that shifts downstream decisions.

## When to use

- Consuming long-form content (book chapter, paper, long essay, hour-long talk).
- Asking "what did I *miss* in here that matters?"
- Not for quick summaries — for the non-obvious insights specifically.

Distinguish from:

- **Summarise** — compress; ExtractAlpha does not compress, it *filters* for signal.
- **Extract Wisdom** — lists ideas, insights, quotes; ExtractAlpha specifically ranks and surfaces the one or two most consequential claims.

## Execution

### Step 1 — Ingest the content

Load the content — article, transcript, PDF, etc. Do not attempt this workflow on content you cannot actually access.

### Step 2 — First pass: enumerate claims

Pass 1 over the content. Enumerate every distinct claim — not every sentence, but every load-bearing assertion. Typical long-form content yields 15-50 claims.

### Step 3 — Rank by non-obviousness × consequentiality

For each claim, score on two axes:

- **Non-obviousness (0-3):** how many readers would reach this conclusion on their own before reading?
  - 0: everyone already knows this
  - 1: domain-familiar readers know this
  - 2: only specialists know this
  - 3: this is genuinely new, at least to the expected reader

- **Consequentiality (0-3):** if true, how much does this shift downstream decisions?
  - 0: interesting but doesn't change behaviour
  - 1: adjusts emphasis
  - 2: changes priorities
  - 3: reframes the whole problem

Total score = non-obviousness × consequentiality (0 to 9).

### Step 4 — Surface the top 3-5

The top 3-5 claims by score are the "alpha". Present them with:

- The claim itself, quoted verbatim if possible.
- Why it scores high on non-obviousness.
- What decision it would change.
- Where in the content it appears (page / timestamp).

### Step 5 — Reframes, not just facts

The highest-value alpha is usually a **reframe** — a new way of seeing an existing problem — rather than a new fact. When ranking, weight reframes higher than standalone factual claims.

### Step 6 — Output

```markdown
## Extract Alpha: <Content title>

### The alpha (ranked)

**1. <claim>** — score <N>/9
- Why non-obvious: <reasoning>
- What it changes: <downstream decision>
- Source: <page/timestamp>

**2. <claim>** — score <N>/9
- ...

### Notable reframes
- **<reframe>** — from <existing frame> to <new frame>.

### What got dropped
<one paragraph noting claims that looked alpha-like but scored low on consequentiality, and why — this builds trust in the ranking>

### Verified sources (if external citations)
- <URL 1>
- <URL 2>
```

## Speed target

~60s for a short article. ~2-3 minutes for a book chapter or transcript. Longer content benefits from delegated chunking.

## Anti-patterns

- **Listing everything that sounded smart.** Ranking means rejection. If fewer than half the claims were dropped, the extraction is shallow.
- **Treating famous quotes as alpha.** Famous = well-known = low non-obviousness.
- **Scoring by how well-written the claim is.** Elegant phrasing is not alpha.
