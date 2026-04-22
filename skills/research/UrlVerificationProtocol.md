# URL Verification Protocol

**MANDATORY for all research workflows in this skill.**

## Critical warning

```
---------------------------------------------------------------
 EVERY URL MUST BE VERIFIED BEFORE INCLUDING IN RESULTS
 Research agents HALLUCINATE URLs — NEVER trust them blindly.
 A single broken link is a CATASTROPHIC FAILURE.
---------------------------------------------------------------
```

## Why this matters

Research agents (any model) routinely hallucinate URLs that look plausible but do not exist. Common failure modes:

- URLs with correct domain but wrong path
- URLs with plausible article titles that were never published
- URLs combining real domains with fabricated paths
- URLs to articles that were deleted or moved
- URLs that resolve but whose content does not match the cited claim

A single unverified URL makes every finding in the report suspect. The cost of verification is a few seconds; the cost of a hallucinated citation is trust.

## Verification workflow

Before including any URL in research output:

1. **Verify with the platform's fetch tool** — actually fetch the URL and confirm it returns content (not 404, 403, or error).
2. **Confirm content matches claim** — the fetched content must actually support what you are citing it for. URLs that resolve but whose content is unrelated fail verification.
3. **Use curl as backup** — `curl -s -o /dev/null -w "%{http_code}" -L <URL>` to check HTTP status. Expect 200.
4. **Never include unverified URLs** — if you cannot verify, do not include. A smaller verified list is worth more than a larger partially-hallucinated one.

## Acceptable vs unacceptable

| Acceptable                                                                 | Unacceptable                                    |
|-----------------------------------------------------------------------------|-------------------------------------------------|
| URL verified via fetch returns actual content                               | URL from research agent without verification    |
| URL returns 200 AND content matches citation                                | URL returns 403 / 404 / 500                     |
| URL content actually supports the specific claim                            | URL exists but content doesn't match citation   |

## When a URL fails verification

1. Remove it from the result set.
2. Search for an alternative source for the same claim.
3. Verify the replacement URL before inclusion.
4. If no verifiable source exists, **soften the claim** — "I could not find a primary source for X" is a valid finding. Manufacturing a citation for a claim is worse than admitting the evidence is absent.

## URL format discipline

- Prefer canonical URLs over shortener services.
- Prefer primary sources (paper at arxiv.org or publisher DOI) over secondary summaries.
- Include the year of publication where relevant — "Author et al., Venue Year" — so readers can judge recency independently of the URL.

## For the Algorithm's verification gate

URL verification is part of the VERIFY phase when a research output is being checked. A research output with any unverified URL fails verification and must be revised before the task can be marked complete.
