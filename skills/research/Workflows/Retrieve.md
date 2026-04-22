# Retrieve Workflow

**Fetch content that resists normal retrieval — CAPTCHA, bot detection, JS-heavy SPAs, paywalls, geo-blocks.**

When normal fetch returns a 403, a CAPTCHA challenge, a bot-block page, or an empty shell (JS that hasn't executed), escalate to this workflow.

## When to use

- A URL returns a 403 or a cookie/consent wall on normal fetch.
- Content is JS-rendered and the platform's basic fetch returns a blank HTML shell.
- The platform has detected automation and returned a CAPTCHA.
- Geo-blocking returns a "not available in your region" page.

Not for: content legitimately unavailable (404 — content deleted), content explicitly disallowed by `robots.txt`, or auth-gated content without explicit authorisation.

## Escalation ladder

Try the cheapest method first. Escalate only on failure.

### Tier 1 — Normal fetch with realistic headers

Often the only issue is that the default fetch omits a User-Agent, Accept-Language, or Referer header. Retry with realistic browser headers (a current Chrome / Safari User-Agent, Accept-Language matching the target region).

If success: return content.

### Tier 2 — Platform browser tool

Use the platform's native browser automation (Claude Code's browser, Playwright MCP, etc.). A real headless browser executes JS, accepts cookies if needed, and mimics human patterns.

Wait for the page's content to actually render before extracting. Don't grab the HTML at first navigation — many SPAs lazy-load.

If success: return content.

### Tier 3 — Browser with longer interaction

If Tier 2 returns an empty or incomplete result:

- Scroll the page to trigger lazy-loaded content.
- Wait for specific selectors to appear before extracting.
- Handle consent banners by clicking through — *if and only if* the banner has a neutral accept / reject choice (do not accept tracking by default).
- Wait 2-5 seconds for network to settle.

If success: return content.

### Tier 4 — External scraping proxy

If earlier tiers fail due to sustained bot detection, and the task is authorised, escalate to an external scraping proxy service that rotates IPs and solves CAPTCHAs (e.g., BrightData, ScrapingBee).

Preconditions before Tier 4:
- Task is explicitly authorised (not just implicitly scoped).
- `robots.txt` allows crawling.
- Site ToS permits it.

If any precondition fails: **do not escalate to Tier 4**. Return failure with explanation.

### Tier 5 — Archived versions

If the content still can't be retrieved directly:

- Check Wayback Machine (`web.archive.org/web/*/URL`) for an archived version.
- Check other archive services (archive.today, archive.org).

An archived version is a legitimate substitute if the current version is genuinely unavailable and the archived version is representative.

## Failure return

If all tiers fail, return failure explicitly:

```markdown
## Retrieve: <URL> — FAILED

**Attempts:**
1. Tier 1 (headers) — <result, e.g. 403>
2. Tier 2 (browser) — <result, e.g. CAPTCHA page>
3. Tier 3 (extended) — <result>
4. Tier 4 (proxy) — <result or "not attempted: robots.txt disallow">
5. Tier 5 (archive) — <result, e.g. "no archive available">

**Recommendation:** <next step — try a different source, wait, contact the site owner, etc.>
```

Manufacturing plausible content is **never** acceptable. A failure is a real finding.

## Success return

```markdown
## Retrieve: <URL> — SUCCESS

**Tier used:** <which tier succeeded>
**Content fetched:** <bytes / word count>
**Caveats:** <anything incomplete — "lazy-loaded section 3 was not fully populated">

### Content
<retrieved content or path to file>

### Verification
URL returns 200 for the tier-appropriate mechanism. Content presence verified.
```

## Anti-patterns

- **Jumping to Tier 4 first.** Expensive, often unnecessary.
- **Treating a 403 as "content doesn't exist".** It may exist; the request was refused.
- **Accepting consent banners that include tracking.** Neutral reject-all is the default.
- **Retrieving paywalled content.** Paywall = explicit access control; do not bypass.
- **Manufacturing content when retrieval fails.** Failure is a finding. Fabrication is a catastrophic failure.

## Budget

Tier 1: ~5s. Tier 2: ~30s. Tier 3: ~1min. Tier 4: varies (often 30s-2min). Tier 5: ~30s. Full ladder: 3-5min before declaring failure.
