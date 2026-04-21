# Standard Research Workflow

**Default research mode: 3 methodology-diverse researchers in parallel, 1 query each.**

## When to use

- User says "research this" / "do research" with no specific depth modifier.
- Need multiple perspectives quickly.
- The topic has more than one credible framing.

## Execution

### Step 1 — Craft one query per methodology

The three methodologies chosen for Standard mode are picked for *diversity of approach*, not diversity of source API. Default set:

- **academic-researcher** — scholarly-source bias, citation discipline
- **multi-angle-researcher** — orthogonal sub-query decomposition
- **investigative-researcher** — triangulation, follow-the-lead

If the topic is notably contested or has entrenched consensus, swap one in for **contrarian-researcher**.

Craft one focused query per methodology — each should be tuned to that methodology's strengths:

- Academic query: framed for scholarly search ("empirical evidence on X", "peer-reviewed studies of Y")
- Multi-angle query: broad enough to admit orthogonal decomposition ("how does X affect Y across technical / economic / social dimensions")
- Investigative query: specific enough to follow leads ("who is actually using X in production and what do they report")

### Step 2 — Launch three delegations in parallel

**Single message with three Task calls**, one per researcher methodology. Use trait composition for each agent's prompt:

```bash
locus agent compose --traits "research,empirical,systematic" \
                    --role "Academic researcher" \
                    --task "<academic query>"
```

(Or the equivalent trait bundle from the relevant agent file at `agents/academic-researcher.md`.)

Each researcher:

- Receives ONE query.
- Does ONE search (may be multi-step internally).
- Returns findings with citations.

### Step 3 — Synthesise

Combine the three perspectives:

- **Convergence** — where all three agree (high confidence)
- **Unique contributions** — what each methodology surfaced that the others did not
- **Contradictions** — where they disagree (flag)

### Step 4 — Verify all URLs (mandatory)

Apply `UrlVerificationProtocol.md` — verify every URL before returning results. Failed verifications remove the citation; do not manufacture replacements.

### Step 5 — Return results

```markdown
## Research: <topic>

### Summary
<1-2 paragraph synthesis>

### Findings
1. <finding> — [verified citation]
2. ...

### Points of agreement (high confidence)
- <point> — surfaced by all three researchers

### Unique contributions
- **From academic search:** <distinctive finding>
- **From multi-angle decomposition:** <distinctive finding>
- **From investigative triangulation:** <distinctive finding>

### Contradictions
- <where sources disagreed, flagged>

### Gaps
- <what couldn't be found>

### Sources
- <verified URL 1>
- <verified URL 2>
- ...
```

## Speed target

~15-30 seconds for delegated parallel execution.
