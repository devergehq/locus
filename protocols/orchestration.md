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
- You need to watch the intermediate reasoning directly, not just the result.
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

**Do not fall back to native Task/Agent subagents**, and do not abandon delegation. The
guardrail names the mechanism; it is not a reason to do the work inline.

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
