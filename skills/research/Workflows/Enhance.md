# Enhance Workflow

**Improve content quality by adding supporting evidence, citations, counter-examples, or depth.** Use when existing content is structurally sound but needs reinforcement.

## When to use

- A draft is complete but thin — needs citations, examples, or counter-arguments.
- An argument lacks evidentiary support.
- A technical piece needs worked examples.
- A recommendation needs risk / trade-off analysis.

Not for: rewriting (that's a different task), structural editing (that's editorial), or fact-checking (that's `Retrieve.md` + verification).

## Execution

### Step 1 — Identify the weak spots

Read the existing content carefully. Mark each paragraph / claim with one of:

- **Supported** — has citation / example / evidence already.
- **Assertion** — needs support (evidence, example, counter-example).
- **Hollow** — claims something without specifying what; needs concretisation.
- **Unguarded** — makes a strong claim without acknowledging counter-cases.

Weak spots are the Assertion / Hollow / Unguarded categories.

### Step 2 — Scope the enhancements

For each weak spot, decide the type of enhancement:

| Weak spot type   | Enhancement type                                    |
|------------------|-----------------------------------------------------|
| Assertion        | Evidence — citation, data point, precedent          |
| Hollow           | Specification — concrete example or definition      |
| Unguarded        | Counter-case — acknowledged limit or counter-example|

### Step 3 — Research the enhancements

**The skill orchestrates; OpenCode does the research.** For each weak spot, dispatch one `locus delegate run` Bash call with the methodology that fits the enhancement type. If the weak-spot count is ≤ 12, dispatch all calls in a *single assistant message* so the platform parallelises them. If > 12, run in waves of 12.

**DO NOT use the platform-native Task tool for this step.** Task subagents are other Claudes burning the same context budget. Use `locus delegate run --backend opencode --mode native` so the heavy research runs out-of-context and only compact envelopes return.

Map the weak-spot type from Step 2 to a methodology + trait bundle:

| Weak spot type   | Methodology              | Trait bundle                                                |
|------------------|--------------------------|-------------------------------------------------------------|
| Assertion        | academic-researcher      | `research,empirical,rationalist,systematic,skeptical`       |
| Hollow           | investigative-researcher | `research,skeptical,contrarian,exploratory`                 |
| Unguarded        | multi-angle-researcher   | `research,exploratory,iterative,analogical`                 |

Per weak spot:

```bash
PROMPT=$(locus agent compose \
  --traits "<bundle from table above>" \
  --role "<methodology> researcher" \
  --task "<weak-spot text — verbatim sentence from Step 1 plus its weak-spot type from Step 2>. Source supporting material: a verified citation, a concrete example or a counter-case as appropriate. Return the source, a verified URL, and a suggested 1-3 sentence integration that preserves the original author's voice.")

locus delegate run \
  --backend opencode \
  --task-kind research \
  --mode native \
  --dir . \
  --prompt "$PROMPT" \
  --output json
```

Each enhancement returns (via the JSON envelope's `summary` / `findings` / `evidence` fields):
- The source / evidence
- A verified URL
- A suggested integration — where in the content it slots, how long the insertion should be.

**Failure handling:** if a weak-spot delegation fails, the original content stays as-is — do not invent supporting material. Flag failed weak spots in the enhancement log.

### Step 4 — Integrate

For each enhancement:
- Insert at the weak spot it supports.
- Keep the tone of the original.
- Preserve the author's voice — don't rewrite surrounding prose unless necessary.
- Add citations inline, not as an appendix.

### Step 5 — Verify

- All inserted URLs pass `UrlVerificationProtocol.md`.
- No claim was introduced that the original author didn't commit to.
- No existing claim was modified — only supported.

### Step 6 — Return

The enhanced content with a changelog:

```markdown
## Enhanced: <title>

<enhanced content — original + insertions>

---

### Enhancement log
- **Para 2:** added evidence (source: <URL>) for the claim about X.
- **Para 4:** concretised "modern systems" with two specific examples (source: <URL>).
- **Para 7:** added counter-case on Y (source: <URL>) to guard the strong claim.

### Verified sources
<list of verified URLs introduced>
```

## Anti-patterns

- **Rewriting instead of enhancing.** Enhance adds; rewrite replaces. Know which you are doing.
- **Over-citing.** Citation discipline means one strong source beats three weak ones.
- **Changing the author's claim.** Enhancement supports; it does not alter the argument.
- **Decorative enhancement.** If a weak spot is acceptable as-is, leave it. Not every claim needs a citation.

## Budget

Depends on the piece's length and the number of weak spots. Typical: 3-10 minutes per weak spot if a single researcher delegation per enhancement.
