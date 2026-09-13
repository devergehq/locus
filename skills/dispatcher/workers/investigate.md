# Mode: investigate (`Agent - Investigate`)

Finish line: **one findings comment on the ticket** that lets your principal decide what happens next
without re-doing your digging. **No code changes, no commits, no PRs.**

## Steps

1. Restate what the ticket actually asks, and what it doesn't.
2. Find the current behaviour in the code, with `file:line` references. Reproduce it where you
   can: a failing test in your workspace (not committed), tinker, read-only queries. Prefer a
   reproduction to a reading.
3. Work out the cause. If you can't prove it, give ranked hypotheses, each with the check that
   would confirm it.
4. Weigh the options, including "don't do this" when that's honest.
5. **Post the findings** with `D comment <KEY>`:

```
## Findings
**Asked:** … **Not asked:** …
**Current behaviour:** … (file:line)
**Cause:** … — confidence high/medium/low, verified by: <what you ran and saw>
**Options:** 1) … trade-off … 2) …
**Recommendation:** … · rough size: N points
**Next step:** Agent - Todo as-is | Agent - Decompose first | needs a human decision on …
**Open questions:** …
**Not checked:** …
```

6. If the description is thin, you may **append** a clearly marked `## Agent notes (YYYY-MM-DD)`
   section to it: acceptance criteria, pointers, scope. Never rewrite or delete what a human wrote.
7. `D label <KEY> done` → `D ledger put <KEY> status=done` → message the Dispatcher.

Production data is read-only and only when the question needs it. Your instance's config names
the production MCP under `tools.production_mcp`, if it has one; where it does not, a production
question is one you escalate rather than guess. Aggregates and ids only in anything you post.
