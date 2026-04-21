# Web Scraping Workflow

**Generic web scraping — fetch one or many pages, extract structured content.**

This workflow is **platform-generic**. It does not bind to any specific scraping service (Apify, BrightData, or equivalent). The caller uses whatever browser / HTTP tooling the platform provides.

## When to use

- Research requires data from pages not available via normal fetch (JS-rendered, behind auth, rate-limited).
- Extracting structured content from many similar pages (e.g., 50 product pages, 20 article pages).
- Normal content retrieval has failed (see `Retrieve.md`) and full scraping is warranted.

## Legal / ethical preamble

Before scraping anything:

- Check the site's `robots.txt` and Terms of Service. If scraping is forbidden, do not scrape.
- Respect rate limits. Aggressive scraping harms the target and burns trust.
- Never scrape personal data without explicit authorisation.
- If the site provides an API or data dump, use that instead.

If any of these conditions fail, refuse the scraping task and explain why.

## Execution

### Step 1 — Scope

Define exactly:
- Target URL or URL pattern
- What data fields you're extracting
- Expected volume (1 page, 10 pages, 1000 pages)

### Step 2 — Choose the fetch method

| Situation                                         | Method                                                 |
|---------------------------------------------------|--------------------------------------------------------|
| Static HTML, single page                          | Platform's native fetch / WebFetch / curl              |
| JS-rendered, single page                          | Platform's native browser tool                         |
| Static HTML, many pages                           | Batch fetch with polite delay                          |
| JS-rendered, many pages                           | Browser automation in loop with polite delay           |
| Behind CAPTCHA / bot detection                    | Escalate (see `Retrieve.md`) or refuse                 |

### Step 3 — Extract fields

For each fetched page:
- Parse to extract the scoped fields (HTML parser, CSS selectors, structured-data extraction).
- Validate — is each extracted field present and plausible?
- Record provenance — URL the field came from.

### Step 4 — Rate-limit discipline

For multi-page scraping, insert deliberate delay between requests. 1 request per second is a conservative floor; respect any `Crawl-delay` in `robots.txt`.

### Step 5 — Store / return

Output format depends on intent:

- **Structured dataset** — CSV / JSON / JSONL with one row per page.
- **Text dump** — when the extraction is rich prose, not tabular.
- **Knowledge extract** — pipe through `ExtractKnowledge.md` for schema-structured output.

### Step 6 — URL verification

Every URL referenced in the output must pass `UrlVerificationProtocol.md`. For scraped data, this also applies to any links embedded in the extracted content.

## Output

```markdown
## Web Scraping: <scope>

**Target:** <URL or URL pattern>
**Pages scraped:** <count>
**Fields extracted:** <list>
**Rate-limit policy applied:** <requests/sec, delay>
**robots.txt check:** <pass / site has no robots.txt / explicit allow>

### Sample output (first 3 rows)
<illustrative sample — full dataset persisted to file>

### Dataset location
<file path, format>

### Failures
- <URL>: <reason — 403, timeout, parse failure>
- ...

### Verified sources
<URLs used for the scope, verified>
```

## Anti-patterns

- **Scraping without checking robots.txt.**
- **Scraping at max request rate.** Politeness is both ethical and practical — you get blocked slower.
- **Hallucinating field values.** If a field is missing, mark it missing — never infer.
- **Scraping auth-gated content without authorisation.**

## Budget

Single page: ~5 seconds. Batch of 10-100 pages: minutes (bound by polite rate limit). Batch of 1000+: hours — coordinate with the user before starting.
