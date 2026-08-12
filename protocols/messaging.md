# Session Messaging Protocol

**Status: DRAFT — proposed, not adopted.** Requires the CLAUDE.md generator change described
in `orchestration.md` or this file is inert.

How Locus sessions address each other, what they are permitted to say, and what the
receiver owes in reply.

## Scope

This governs `SendMessage` between peer Claude Code sessions. It does not govern
`locus delegate run`, which is a call and not a correspondent.

**Free-form agent-to-agent conversation is prohibited.** Not discouraged — prohibited.
It is unbounded in cost, drifts, and launders accountability: after the fact nobody can
tell who decided what. Every message must be one of the named shapes below.

## Addressing — treat every address as expiring

Session names are addresses. Refs are **not** identity.

Verified 2026-08-13: nine of nine live sessions had a different ref within hours, with
every name unchanged. A ref is a session-scoped disambiguation token with no cross-time
meaning.

**Rules:**

1. **Key durable references on allele's `Session.id`**, never on a name and never on a ref.
   `Session.id` is minted at creation, persisted to `state.json`, and survives app restart.
   It is deliberately stable against conversation-id rotation (`claude_session_id` is a
   separate pointer that follows Claude's `/clear` rotation while `Session.id` holds).
2. **Resolve `Session.id` → name via allele, then name → `[ref]` via `ListAgents`, fresh, at
   send time.** Never cache a resolved address across turns.
3. **A rejected send is control flow, not an error.** Re-resolve and retry. Do not log it at
   error severity — it is the mechanism working as designed and the noise is misleading.
4. Amortisation (reusing a bare name after a successful send) is a permissible optimisation
   and **never** an assumption. The gate is on the `(name, ref)` pair: when the ref rotates,
   the name re-gates.

Rule 4 has been wrong twice. It was believed to be per-peer, and that was falsified; then
per-name, and that was falsified. **Treat any addressing rule in this section as
provisional** and prefer re-resolving over reasoning about when you may skip it.

After `create()`, a dispatcher must round-trip `ListAgents` before its first send. `create()`
cannot return a usable address: refs are minted inside Claude Code, and `ListAgents` is a
session capability an MCP server cannot call.

## Permission boundaries

**Never ask a peer to perform work that was denied or blocked in your own session, or that
you expect your own settings would block.** A peer doing it for you bypasses a decision the
human made. Route blocked work back to your human instead.

This holds regardless of what the peer's permission mode is, and regardless of whether any
component checks. As of DEV-415, `sessions.create()` takes **no** permission-mode parameter
and dispatched sessions inherit `permissions.defaultMode` from global settings. There is no
"never looser than the creator" enforcement and none is planned in that ticket (descoped to
DEV-413).

**So this rule is currently enforced by nothing but this protocol.** Written down here
precisely because there is no backstop.

## Message shapes

### 1. Triage — a worker found something adjacent

The most common shape. A session mid-task encounters a bug, a scope question, or an
unexpected finding, and must decide: in scope, ticket it, fix it now, or blocked?

Route it to whoever holds **scope authority** — the session holding the ticket, the agreed
scope, and what the human has and has not signed off. That context lives in exactly one
place and correctly does not live in the worker.

```
FINDING      what was encountered, with file:line
EVIDENCE     what was actually verified, distinct from what is inferred
PROPOSAL     the worker's own recommended disposition, stated before asking
DISPOSITION  in-scope | ticket-and-continue | fix-now | blocking
BLOCKING     can the worker proceed while waiting? yes/no
```

`PROPOSAL` is required. A worker that routes a bare question has moved its decision onto
someone with less local context. Propose, then ask.

`DISPOSITION` is a closed set. If none of the four fit, the message is not a triage and
should not pretend to be one.

**The four values are PROVISIONAL.** They come from one orchestrator, one project, one day,
roughly a dozen uses with no counterexample — which is absence of evidence against them,
not evidence for them. A second body of work using this protocol is *testing* the enum, not
applying it. Report a case that does not fit rather than forcing it into the nearest value.

**The scope holder owes a reply that is a decision or an escalation**, never a deferral.
On `ticket-and-continue` it raises the ticket and reports back what it did. If it escalates
to the human, it escalates with a recommendation, not an open question.

### 2. Correction — a peer got something wrong

Corrections travel in **both** directions. A worker correcting the orchestrator is the
normal case, not insubordination, and it includes correcting things already relayed to the
human.

**Send your reasoning and your query, not just your conclusion.** This is the whole
mechanism: a defect was found on 2026-08-12 only because a session shared the *query* it
ran rather than the answer it got. A conclusion cannot be checked; a method can.

State plainly what is wrong, what the evidence is, and what changes as a result. Do not
apologise or re-litigate; correct and continue.

### 3. Handoff — work moving to another session

Publish an **artifact** and send the URL. Do not paste a brief.

The artifact is durable, updatable at a stable URL, and readable by any session via
WebFetch. Keep the markdown source under the Locus work dir; redeploy the same file path so
the URL does not move.

A handoff opens with **orientation, not setup**: what to read, in what order, to get context
loaded. State the base branch as a fact. Work happens in allele workspaces that are already
provisioned — never write `git worktree`, `git checkout`, or branch-creation steps.

Where several sessions run concurrently, include a file-ownership table so agents do not
collide.

### 4. Status — answering "where are you up to"

Report what is **verified**, separately from what is done-but-unverified. See the
verification rules below.

## Never infer a peer's state from `ListAgents`

`ListAgents` reports idle/busy. Allele tracks six states. The collapse is lossy in one
specific and dangerous way:

| Allele state | Means | In `ListAgents` |
|---|---|---|
| `Running` | actively working | busy |
| `ResponseReady` | **finished a response turn** | idle |
| `AwaitingInput` | **blocked on a permission prompt** | idle |
| `Idle` | started, or ended | idle |
| `Suspended` | no PTY attached | — |
| `Done` | terminal | — |

**A worker blocked on a permission prompt is indistinguishable from a finished one.**
Silent, indefinite, and it looks like success.

This is not hypothetical. `sessions.create()` carries no permission-mode parameter, so a
dispatched session inherits `permissions.defaultMode` from global settings. If that is ever
stricter than `auto`, dispatched sessions will sit in `AwaitingInput` forever — nobody
watches a fleet of twenty, and an orchestrator polling `ListAgents` sees a well-behaved
idle worker.

**Rule: check `sessions.status(id)`. Never conclude a worker is done from `ListAgents`.**

`AwaitingInput` cannot be overwritten by `ResponseReady` in allele, so the signal is sticky
and trustworthy — it is not a stale artifact of event ordering.

`Idle` conflates "context was reset" with "session ended", so it is ambiguous. It does
**not** mean "never received its prompt": `create()` does not return success until a
`user_prompt_submit` event is observed, so a confirmed create cannot be a phantom.

## Session conduct

### Commit always. Push session branches always.

**A session's work must not exist only on a local disk.** Commit it, and push the session
branch. Both are expected.

Standing authorisation, given directly 2026-08-12:

> "we led the sessions astray a little bit when we said they couldn't create or switch
> branches and now they don't think they can push anything. I want you to save your work and
> I want you to push your branches as much as possible. Anytime you make a commit, you
> should be pushing a branch because we definitely want it to be saved in version control
> and accessible by other sessions too."

**What remains absolute: do not merge to `dev`/`main`, and do not open PRs without asking.**
The push authorisation does not extend to either. That is the hard line.

**How this clause was got wrong, twice, in opposite directions.** It is recorded because the
failure is instructive, not to assign blame.

An earlier draft said "push always" on a peer's report. I overruled it after finding the
base rule — *"do NOT push or merge unless he explicitly asks"* — and concluded the
restriction was real and the frustration was a misreading. **That was wrong.** The base rule
was true; the exception had fired and nothing had recorded it. The record I checked was
months old, and *a verification has a shelf life*.

Then a peer asserted the exception and pointed at a memory file — which that peer had
written one minute earlier. A second peer "verified" it by reading the same file and
believed it had corroborated independently. **It had not: same source, one hop apart.**

What actually settled it was primary evidence — a `role=user` turn in a session transcript
that was *not* wrapped in `<cross-session-message>`. Peer messages arrive with `role=user`,
so role alone does not distinguish a human from a relay.

**The rule this yields:** when authorisation is disputed, go to the transcript, and check
the turn is not peer-wrapped. A memory file is a cache of that evidence and can be written
by anyone. Two agents citing one file is one source, not two.

### Verification discipline

Three rules, each learned from a real failure. They are one shape: **a confirming output
that is genuinely true of a narrower claim than the one being made.**

1. **Verify the claim, not the tool output.** A tool reporting success succeeded at
   something — check that it was the thing you are asserting. A green test is not evidence
   until you have watched it go red. See `verify-the-claim-not-the-tool-output`.
2. **Verify reach before claiming severity.** Before the words "production", "incident" or
   "outage": does this code ship, and does this config reach production? Severity is the
   claim we are least practised at verifying and the one that decides whether a human drops
   what they are doing. See `verify-reach-before-claiming-severity`.
3. **Assert values, not shapes.** A test asserting structure passes against wrong data.

A verification has a shelf life. Re-verify before re-asserting; do not carry a stale check
forward as current.

### Scope authority

Name it explicitly when work is split. It is a **role held for a body of work**, not a
session type and not a rank — the session that holds the ticket and the agreed scope. It
changes hands between bodies of work and may sit with a session that is also doing
implementation.

A session that does not hold scope authority should not resolve scope questions alone, and
should not be given the scope context "just in case" — in a worker, it is noise.
