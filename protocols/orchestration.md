# Orchestration Protocol

How a Locus session decides to move work out of itself, and where it goes.

## Principle

**Orchestration is a capability, not a role.** Any session may orchestrate. What makes a
session an orchestrator is that it holds the scope context for a body of work — not a
configuration flag, not a session type. Tomorrow it is a different session on a different
project.

Every session can dispatch, and every session it dispatches can dispatch in turn, to a
bounded depth. A worker that hits a blocker is expected to resolve it — by answering it
locally, routing it to whoever holds scope, or dispatching an investigation — rather than
stalling and waiting to be unblocked.

## Two mechanisms

| | **Do it here** | **Dispatch** (`allele_sessions_create`) |
|---|---|---|
| Identity | this session | persistent, addressable, in the sidebar |
| Context | yours, and it fills up | fresh per session |
| Writes | yes | yes, own workspace and branch |
| Human sees it | yes | yes — interruptible and takeable-over |
| Costs | your context | a slot against the global cap |

Cross-session messaging (`ListAgents` / `SendMessage`) is a channel, not a third mechanism.
It is how you talk to what you dispatched.

## When to dispatch

Dispatch when any of these hold:

- **The work needs its own workspace or branch** — anything producing commits.
- **3+ independent workstreams** that genuinely parallelise.
- **Investigation spanning 5+ files**, where only the conclusion matters here.
- **An independent perspective is the deliverable** — red team, council, tie-break,
  second opinion, "am I fooling myself".
- **A blocker you cannot resolve** without derailing the work in front of you.

**Do not dispatch** when:

- A single Grep/Glob/Read answers it in seconds.
- The work depends on context already loaded here that would be costly to transfer.
- You need to watch the intermediate steps directly, not just the result.
- You are at depth 3.

## Independence, and what actually produces it

When the point is that a worker should *not* share your assumptions, the levers that
matter, in order:

1. **Trait composition.** `locus agent compose` builds a genuinely different reasoning
   stance — expertise, stance, approach. This is doing most of the work.
2. **A fresh context.** A dispatched session starts with its prompt and nothing else. It is
   not you continuing to reason; it has never seen your working.
3. **Task framing.** Give attackers *different* attack vectors, and council members
   *different* briefs. Identical prompts produce correlated answers regardless of mechanism.

What dispatched sessions **do** share is base instruction — the same `CLAUDE.md`, settings,
and Algorithm. That shapes *how* they run a session more than *what* they conclude, but it
is not nothing: if several workers converge, weigh that they were told to reason the same
way. Convergence is evidence; it is not proof.

**Delegate to find, dispatch to fix.** An agent that both diagnoses and repairs cannot be an
independent check on its own diagnosis. Keep the judgement and the artifact in different
sessions.

## The lifecycle, depth, and the cap

**Canonical text: the Dispatch section of `algorithm/v2.0.md`**, shipped as the
`locus-algorithm` skill. The lifecycle, addressing, status semantics, the vehicle table,
depth 3, the global cap of 20 and the reclamation obligation are all specified there, and
are deliberately not restated here. Details of addressing, state and reporting live in
`messaging.md`.

This section used to carry its own copy. That copy went stale — it still banned native
subagents outright long after the Algorithm replaced the ban with a routing table — while
reading as authoritative. A second copy of a rule is a second rule.

Two of the canonical rules are named here only because this document's "when to dispatch"
advice is unusable without them:

- **One `allele_sessions_create` at a time**, its result read before the next is issued.
  Never batch creates into a single assistant message. Workers run concurrently either way;
  only the claims queue. The incident that produced this rule, and the condition under which
  it may be retired, are recorded in the Algorithm.
- **Every session dispatched is either discarded with `allele_sessions_discard` or recorded
  as still working with a reason.** Discard commits uncommitted work and archives the branch
  before removing the workspace, so reclaiming a slot never loses anything.

## When allele is not available

The allele MCP talks to a socket allele binds at startup. If the `allele_*` tools are not
present, **allele is not running and this session is outside it** — a plain terminal,
`claude.ai/code`, CI, or allele simply closed. That is a normal way to run Locus, not an
error.

**Route down the Algorithm's vehicle table and announce the row you landed on.** The tiers,
what each costs, and why a native subagent is permitted as a last resort rather than
forbidden, are canonical there. Declare the degradation in the shape
`protocols/degradation.md` requires, rather than silently producing lesser work.

What matters here is the judgement the table cannot make for you: decide whether the work
warranted delegation *before* you try to dispatch it. "It did not need delegating after all",
concluded after the vehicles failed, is marking your own homework.

Note `locus delegate run` is **not** a security boundary — see the warning below. It is the
standalone path, not the safe one.

## A note on `locus delegate run`

Locus routes delegation to the allele MCP when it is available, and to `locus delegate run`
when it is not. The command is the standalone path, not legacy.

If you use it directly, know that **it is not a security boundary.** `DelegationMode::ReadOnly`
is a label, not an enforcement — the on-disk config has `bash: allow` beside `edit: deny`,
so `sed -i`, `tee` and `git commit` all walk around it, and `is_read_only()` is a mode
comparison. `webfetch`, `websearch` and `external_directory` are all `allow`, so repository
and web content are both injection surfaces. Tracked as DEV-419.

Dispatch does not have this problem in the same shape: a dispatched session writes to its
own branch in its own workspace, where a human can review, interrupt and take over.

## What this is not

- **Not free-form agent conversation.** Messages carry findings, decisions, questions and
  corrections. Unbounded chat drifts and launders accountability — afterwards nobody can
  tell who decided what.
- **Not a way around permissions.** Never ask a peer to do work blocked in your own session.
  Route it back to the human.
- **Not invisible.** Everything lands in the sidebar. An orchestrator quietly running a
  fleet is worse than the manual version even when it is faster.
