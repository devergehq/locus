# Red Team Philosophy

## Origin

Military red teaming — dedicated teams that attack plans, strategies, and assumptions to find vulnerabilities before an adversary does. The Locus adaptation applies the same discipline to architectural proposals, strategies, and plans.

## Core insight

**The goal is not destruction — it's finding the fundamental flaw.** The most powerful critique is usually *one* core issue: a hidden assumption that's actually false, a logical step that doesn't follow, a category error (treating X like Y), or an ignored precedent that directly contradicts.

A weak critique is a long list of small objections. A strong critique surfaces the single load-bearing problem that, if acknowledged, collapses the entire structure.

## Success criteria

A successful Red Team analysis satisfies all of the following:

- **Steelman first.** The strongest version of the argument must be present. A reader who wrote the original proposal should say "yes, that's my argument" — not "you strawmanned me".
- **Counter-argument defeats the steelman, not a weaker version.** If the rebuttal only defeats a cartoon of the proposal, the analysis is cheap.
- **Multiple trait-composed attackers converged on the same insights.** If the engineers, architects, and pentesters all surfaced the same core issue, it's a load-bearing flaw — not a quirk of one perspective.
- **The reader says "I hadn't thought of that."** If the critique is obvious in retrospect, the analysis worked. If the critique is obvious in prospect, the analysis didn't go deep enough.

## The attacker roster

Unlike PAI's named-character 32-agent pattern, Locus Red Team uses **trait-composed attackers** organised into four cognitive types:

| Type          | Trait bundle                                                    | Attack angle                                                      |
|---------------|-----------------------------------------------------------------|-------------------------------------------------------------------|
| Engineers     | `implementation + skeptical + systematic`                       | Technical rigour, integration realities, failure modes in code    |
| Architects    | `architecture + systems-thinking + skeptical`                   | Structural issues, coupling, invariants, long-term erosion        |
| Pentesters    | `security + adversarial + systematic`                           | Exploit paths, trust-boundary violations, misuse cases            |
| Interns       | `implementation + exploratory + rapid`                          | Fresh-eyes questions, "why does this need to exist at all?"       |

At Extended+ effort, spawn 2 of each for 8 parallel attackers. At Deep effort, spawn up to 4 of each for 16. The bounding principle: more attackers produce diminishing convergence; convergence is the signal, not coverage.

## What the Red Team is *not*

- Not a blanket "say no" exercise. The steelman step is mandatory.
- Not destructive nihilism. The goal is to improve the proposal, not to refuse to engage.
- Not personal. Attackers critique the argument, not the author.
- Not a replacement for Council. Council is collaborative-adversarial (debate to find best path); Red Team is purely adversarial (attack the idea).

## When Red Team is the wrong tool

- When the goal is to **choose between** options — use Council.
- When the goal is to **decompose** a problem — use First Principles.
- When the goal is to **surface hidden requirements** — use Iterative Depth.
- When the goal is to **test an empirical claim** — use Science.

Red Team is specifically for: "here is a proposal/plan/strategy that I believe is correct; attack it hard enough that I'll notice if it isn't."
