# Review lenses — run these AFTER your own read, not before

These come from six months of review history on one codebase, read comment by comment. They are
**methods two reviewers used productively** — not one person's style — and they don't make a
checklist that replaces judgement. Where a lens is weakly evidenced, it says so.

The underlying report named the PRs and the reviewers behind every line. It is not shipped, and
the identifying examples have been removed from the lenses below. Where that cost a lens its
evidence rather than just its identifiers, the lens says so in place rather than substituting a
new justification.

For each lens, write one line in your draft: **applied → found X**, **applied → nothing**, or
**not applicable because…** Skipping silently is not an option.

**L1 — Sibling diff (strong).** Name the other call sites that answer the same question. Does this
one do what they do: includes, guards, scoping, the tax check on every write path?
*Seen in the history: an action shipped with 8 of the count/exists includes its 10 sibling call
sites carry, and a downstream API returned 400 for every caller.*

**L2 — Both sides of a comparison (strong; one real escape).** For any remaining / ratio / A−B /
header-vs-lines figure: do both sides share the same scope (fees, stages, streams, date window,
request query params)? If they don't, **which side matches the figure the user sees next to it**?
Making them agree is not enough.
*Seen in the history: a scope mismatch was caught in review, resolved to the wrong side of the
comparison, and shipped for four months before anyone noticed.*

**L3 — Does the guard ever run? (strong for shell/CI).** For each catch / skip / fallback, prove it
is reachable. Watch for `set -e`/`pipefail`, non-zero exits on partial success, `TypeError` not
being an `Exception`, baseline suppressions, and skipped jobs and `needs:`.

**L4 — Can this test fail? (moderate).** Would it fail on an empty table? On reverted code? On a
config state production actually has? Is a `refresh()` or `?? []` hiding the bug?

**L5 — Who can reach this, in what state, and what ships? (moderate; one security near-miss).**
New input: is it scoped to the caller's ownership, not just `exists:`? Each write: which roles, in
which lifecycle states (a terminal state such as PAID is the one people forget)? On low-trust
surfaces — a third party, an end customer, a signed URL — diff the **serialised payload**, not
just the rendered template.

**L6 — Production census, cross-tabbed (strong as a method).** Run the new predicate against
production (read-only, aggregates only). **Cross-tab it against every existing flag or exclusion
on the same rows.** Use the numbers to kill your own suggestions too: "defensive" floors and
clamps have been refuted by real negative lines.

**L7 — Ticket fit (moderate; applied unevenly).** Map each acceptance criterion to a diff line
and a test. Is anything the ticket calls TBD shipping undecided? Does the PR contradict an
explicit instruction in the ticket?

*This lens was the most unevenly applied of the eight: in the sample it was one reviewer's
strongest habit and the other's rarest. That is why it is here — a lens one experienced reviewer
leans on and another skips is exactly the one you will skip by default. Give it deliberate
attention.* **The force of that observation came from its being two identifiable reviewers, and
de-identification cost it: you now have the claim without the evidence. Treat it as a prompt to
check yourself, not as a measured finding.**

**L8 — Where does each non-blocking finding land? (process).** In your draft, mark every
non-blocking finding **fix now / ticket it / consciously decline**. About 28% of non-blocking
comments in the sample were never answered, and the code under them never changed.

## Calibration — how reviews here have been wrong
- Claims that something was "verified" when it wasn't, e.g. a mutator snippet, or "no cherry-pick
  conflict" (there were 6). Say exactly what you ran.
- Suggestions the toolchain rejects — a null-safe operator that the project's static analyser
  flagged as never-null across 363 call sites, for one real example. Check that a suggested fix
  passes static analysis before proposing it.
- Two AI-assisted reviewers converging on the same finding is **not** independent confirmation. If
  your blind second lens and you agree, check it against production or a test before raising severity.
