<!-- Worked example. The codebase is invented; every language behaviour it turns on is real and
     checkable in a Node REPL with no access to that codebase. Visible body 127 words — counted
     outside <details>, excluding table rows and this comment (target 150, ceiling 400). Count it
     yourself: the method is stated so the number is falsifiable.
     Note on shape: this demonstrates finding craft. The index shape the linter enforces is the
     template in house-style.md — two tables, a Method line — which this example predates. -->

🤖 **Agent review · round 1** · `agent:EX-303/implement`
Reviewer: testing, adversarial, thorough · independent PR reviewer · reviewed `1834c8f`

**0 Blockers · 2 Should.** The fix is right and survived a hard attempt to break it — but the
neighbour this PR dismisses as unrelated is a worse instance of the same bug.

### Problem fit
`InvoicePolicy` compares `raisedBy` to a user id and the factory handed out a random one, so
denial tests passed by luck. Replacing it with a non-matching constant fixes the flake at the
right level. It also surfaced a real production issue — that column carries free text from the
upstream provider and user ids from the app — correctly deferred, not fixed here.

### Findings
| | Location | Finding |
|---|---|---|
| 🟠 Should | [`test/factories/creditNote.ts:20`](#) | `parseInt(token(), 10)` collides 1 in 49 — worse than the bug being fixed, and dismissed as unrelated |
| 🟠 Should | PR description → Security impact | The deferred `parseInt` vs `Number` issue has no ticket; EX-303 closes on merge and it goes with it |

> [!WARNING]
> File the `parseInt`/`Number` ticket before merging. EX-303 closes when this merges.

<details><summary>🟠 Should — <code>parseInt(token(), 10)</code> collides 1 in 49, and the dismissal is backwards</summary>

`planId: parseInt(token(), 10)` collides with a low autoincrement plan id about **1 in 49** draws,
against **never** for the `1000 + random*9000` form this PR removes — 500,000 draws each. `token()`
is `Math.random().toString(36).slice(2, 8)`, and **`parseInt` stops at the first non-digit**, so a
token beginning `7f…` parses to `7`. Analytically (1/36)(26/36) ≈ 1 in 50, which the measurement
matches. The dismissal assumed base 36 means "wider id space", which is the opposite of what
parsing it back in base 10 does.

Worse in passing: **72.2% of draws are `NaN`**, and `NaN === NaN` is `false`, so most runs pass the
denial assertion because the id never equals *anything* — including the one the test intends.

`planId` is trusted alone by three customer-facing financial queries —
`src/billing/queries/invoicedTotalForPlan.ts:40`, `src/billing/queries/customerSpendSummary.ts:109`,
`src/billing/reports/contributionSummary.ts:103` — so a generated row landing on a real plan can
surface in another customer's spend summary.

Not a reason to widen this PR. But "left alone as unrelated" is the wrong disposition: it needs a ticket.
</details>

<details><summary>🟠 Should — the deferred coercion issue exists only in prose</summary>

`parseInt('7 Eleven Staff', 10) === 7` while `Number('7 Eleven Staff')` is `NaN` (verified, Node
v24.14.0). `ProviderInvoice.raisedBy` is `string | null` and is written straight into the column by
`src/sync/importInvoiceFromProvider.ts:85` with no numeric guard, so the column really does carry
unvalidated free text on the provider path while `InvoicePolicy` reads it as an id.

Deferring it from a test-fixture PR is right. But it lives only in a comment on EX-303 and a
paragraph in this description, and a full-text tracker search (96 results) finds no dedicated ticket.
</details>

<details><summary>Also found — 2 Nits (posted inline, not blocking)</summary>

**⚪ `test/factories/attachment.ts:24` — same class, latent today**

`ownerId: parseInt(token(), 10)` with a random `ownerType` is the same bug. **Latent, not a live
flake:** every test exercising `delete-attachment:assigned` or `delete-invoice-attachment:all` sets
both explicitly. It becomes a **1-in-3** flake the moment someone writes a denial test against a bare
`attachmentFactory()`, because `src/billing/policies/attachmentPolicy.ts:68` compares `ownerType`
alone and there are three types. Eleven similar hits repo-wide; grep in Evidence.

**⚪ PR description, Summary — the count is off**

Seven files, not eight: `planThresholds.test.ts` contains no denial assertion at all. With
`invoiceScope.test.ts` correctly excluded, six are genuinely at risk. Worth fixing because the repo
squash-merges with the PR body as the commit message, making this permanent.
</details>

<details><summary>Evidence — commands and output</summary>

```
node -e '...500k draws...'  → parseInt(token(),10) 1 in 49 · 1000+random*9000 never · NaN 72.2%
node -e 'console.log(parseInt("7 Eleven Staff",10), Number("7 Eleven Staff"))' → 7 NaN
grep -rnE "(Id|By)'?: parseInt\(token\(\)" test/factories/ src/
  → 11 hits the PR does not mention
for f in test/billing/invoice/*.test.ts; do ... done → 7 files
npx vitest run test/billing/invoice --repeat=50 → 50/50 pass on the branch
```
</details>

<details><summary>Checked and fine</summary>

`Number(null) === 0` is safe at both call sites: the other operand is `user.id` on a persisted
record, so never 0. The constant chosen cannot collide with a real user id in the suite. The guard
tests the implementation rather than the invariant, but it holds.
</details>

<details><summary>Suppressed — 3 findings I did not raise, and why</summary>

- `invoiceFactory` still seeds `raisedBy` as a number rather than the branded type — consistent with
  every other factory here, so changing it is a repo-wide decision, not this PR's.
- Two more `parseInt(token(), 10)` id seeds in `test/factories/` sit on models with no policy that
  compares the column — no reachable authorisation path.
- The test name reads as the implementation rather than the invariant. True, but it is the file's
  existing convention and renaming one of eight helps nobody.
</details>

<details><summary>Risks and not verified</summary>

- The 1-in-49 figure is empirical over 500,000 draws. `Math.random()`'s distribution is not
  specified by the language, so the analytic 1 in 50 is the claim I would defend, not the measurement.
- Postgres vs the in-memory test driver: the `parseInt` comparison was reasoned about, not exercised
  against the real driver under CI.
- I did not check whether any UI renders `raisedBy` as a name rather than an id.
</details>
