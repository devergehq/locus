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

## Three mechanisms

| | **Do it here** | **Native subagent** (`Task`/`Agent`) | **Dispatch** (`allele_sessions_create`) |
|---|---|---|---|
| Identity | this session | a descendant of this session | persistent, addressable, in the sidebar |
| Context | yours, and it fills up | fresh, but framed by your prompt | fresh per session |
| Writes | yes | yes, in your workspace | yes, own workspace and branch |
| Human sees it | yes | as a tool call | yes — interruptible and takeable-over |
| Error correlation | n/a | **high — inherits your blind spots** | low — different model, cold start |
| Costs | your context | your budget and framing | a slot against the global cap |

Cross-session messaging (`ListAgents` / `SendMessage`) is a channel, not a fourth mechanism.
It is how you talk to what you dispatched.

## Routing: which mechanism, and when

Three mechanisms are available, and **none of them dominates.** Route by the shape of the
work, not by policy.

| Route | Use it for | Costs |
|---|---|---|
| **Do it here** | Trivial lookups a single Grep/Glob/Read answers in seconds. Work depending on context already loaded here that would be costly to transfer. Work whose intermediate reasoning you need to watch directly. | Your context |
| **Native subagent** (`Task`/`Agent`) | **Anything that writes** — code, commits, PRs. Tight interactive iteration where latency matters. Work needing a host-only tool or MCP server the delegate backend lacks. Bounded fan-out over context already established here. | Shares this session's budget and framing |
| **Dispatch** (`allele_sessions_create`, or `locus delegate run` outside allele) | Adversarial review, red teams, council members, tie-breaks, "am I fooling myself". Work that needs its own workspace and branch. Investigation spanning 5+ files where only the conclusion matters here. Large parallel sweeps. Anything wanting a durable, replayable audit artifact. | A slot against the global cap; latency; no access to your loaded context |

### Why adversarial work must leave the family

A native subagent is a descendant of this session: it inherits the framing, the assumptions
and the blind spots that produced the thing it is meant to attack. Its errors are therefore
**correlated with yours**, which is precisely the property an independent check must not
have. A different model family, in its own process, with its own trait composition, fails
differently — and only uncorrelated failure produces a real second opinion.

This is not a claim that dispatch is cheaper. It is not: a subagent's raw tool traces stay
out of the parent context but its final result still enters, and Locus returns a compact
envelope while retaining the full trace externally — so both forms manage context. The
argument for dispatch on adversarial work is **independence**, not economy.

### Why write work stays native

`locus delegate run` is read-only. Routing implementation work to it means routing it
nowhere. Native subagents write, commit and open PRs; that is the route for work that
produces artifacts, unless the work also needs its own branch — in which case dispatch a
real allele session, which has a workspace.

### Also dispatch when

- **3+ independent workstreams** genuinely parallelise.
- **A blocker you cannot resolve** without derailing the work in front of you.

### Never route anywhere

- You are at **depth 3** — that is the floor, and it does not dispatch.

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

## The lifecycle

```
1. compose   locus agent compose --traits "..." --role "..." --task "..."
2. dispatch  allele_sessions_create(project, name, prompt)   -> session_id, name
3. address   ListAgents -> "name [ref]"        fresh, every send; refs rotate
4. converse  SendMessage(to: "name [ref]", ...)
5. check     allele_sessions_status(session_id) -> state == "response_ready"
6. reclaim   allele_sessions_discard(session_id)
```

Details of addressing, state and reporting live in `messaging.md`. The two rules worth
repeating here because getting them wrong is silent:

- **`sessions_create` returns a `session_id`, never an address.** Re-resolve at every send.
- **Never conclude a worker is finished from `ListAgents`.** It cannot distinguish
  *finished* from *blocked on a permission prompt*.

## Depth and breadth

- **Depth 3.** Depth 0 is human-started. It dispatches workers at depth 1, which may
  dispatch specialists at depth 2. Depth 3 does not dispatch. Past that the original intent
  is too diluted through rounds of telephone to be worth the slot.
- **Global cap 20** concurrent dispatched sessions, aggregate across all dispatchers. Per-
  dispatcher caps do not compose: twenty dispatchers each under a limit of twenty is four
  hundred sessions, every one individually compliant.
- Both are derived by allele from the creating session's record. **Depth is never
  caller-supplied** — anything a session can assert about its own depth is something it can
  be wrong about, and the sessions asserting it are the ones running the rule that causes
  the recursion.

**Discard is part of the job, not cleanup.** `allele_sessions_discard` commits uncommitted
work and archives the branch before removing the workspace, so reclaiming a slot never
loses anything. A dispatched session left running holds a slot and becomes invisible work
nobody owns. Every session you dispatch is either discarded or explicitly still working
with a stated reason.

## When allele is not available

The allele MCP talks to a socket allele binds at startup. If the `allele_*` tools are not
present, **allele is not running and this session is outside it** — a plain terminal,
`claude.ai/code`, CI, or allele simply closed. That is a normal way to run Locus, not an
error.

**Fall back to `locus delegate run`, and say which mode you are in.**

```bash
locus agent compose --traits "..." --role "..." --task "..."   # unchanged
locus delegate run --backend opencode --task-kind general --mode native \
  --dir . --prompt "<composed prompt>" --output json
```

You lose the session — no workspace, no branch, no conversation, and it returns an envelope
rather than replying. You keep delegation, which is the thing that matters. Say so once, in
the shape `protocols/degradation.md` requires, rather than silently producing lesser work:

```
Dispatch normally creates real allele sessions. allele is not available here,
so this is running through `locus delegate run` instead: read-only, no branch,
and no way to ask the worker a follow-up question.
```

Work the routing table sends to **native** is unaffected — that route never depended on
allele. Do not abandon routing and do the work inline because one mechanism is missing.

Note `locus delegate run` is **not** a security boundary — see the warning in
`orchestration.md`. It is the standalone path, not the safe one.

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
