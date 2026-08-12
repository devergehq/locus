# Orchestration Protocol

**Status: DRAFT — proposed, not adopted.** Requires the CLAUDE.md generator change in
`crates/locus-adapter-claude/src/config_gen.rs` (see "Loading" below) or this file is inert.

How a Locus session decides to move work out of itself, and where.

## Principle

**Orchestration is a capability, not a role.** Any session may orchestrate. What makes a
session an orchestrator is that it holds the scope context for a body of work — not a
configuration flag, not a session type. Tomorrow it is a different session on a different
project.

## Three mechanisms, not two

| Mechanism | Identity | Writes | Framing | Visible to human |
|---|---|---|---|---|
| **Do it here** | this session | yes | yours | yes |
| **`locus delegate run`** | none — a call that returns | see warning below | *stripped* | only via the envelope |
| **allele dispatch** (`sessions.create`) | persistent, addressable | yes, own branch | *inherited* | yes, in the sidebar |

Cross-session messaging (`ListAgents` / `SendMessage`) is orthogonal to all three and
already ships. It is a channel, not a mechanism for moving work.

## The routing questions

Ask both. They are independent, and either can fire alone.

### Q1 — Does the work need to produce reviewable artifacts?

Commits, branches, files that must persist and be inspected by a human.

**If yes → dispatch.** Not because delegate cannot write (it can — see warning), but
because a dispatched session writes to *its own branch in its own workspace*, which a
human can review, interrupt, and take over. Delegate writes land wherever `--dir` points,
unreviewed and unattributed.

### Q2 — Is independence of framing the deliverable?

Does the value of the output depend on the producer *not* sharing your assumptions?
Red team, council, tie-break, second opinion, "am I fooling myself".

**If yes → delegate, necessarily.** Dispatch structurally cannot supply this. A dispatched
session inherits the same `CLAUDE.md`, the same `settings.json`, and the same
`additionalDirectories` as its dispatcher. It is not merely the same model family — it is
loaded with identical framing *by construction*. Three dispatched sessions agreeing are
three samples from one prior.

`locus delegate run --mode native` deliberately strips the Algorithm, Mode Classification,
skills and protocols (`generate_native_agents_md`). **That stripping is structural.** The
different model family is a *contingent* property of today's backend configuration — real,
useful, but not guaranteed. State the claim on the durable half.

### Both fire

Independence governs the **judgement**; dispatch produces the **artifact**.
Delegate to find, dispatch to fix. Never one agent doing both — an agent that both
diagnoses and repairs cannot be an independent check on its own diagnosis.

### Neither fires

There is no default. Choose on which failure you would rather have:

- **Prefer dispatch** when a human may want to watch, interrupt, or take over, and when
  the intermediate reasoning is worth keeping.
- **Prefer delegate** when context economy dominates and a compact envelope is genuinely
  all you need.

An earlier draft of this protocol said "delegate is the default". That was wrong and is
recorded here so it is not re-derived: two independent adversarial reviews converged
against it, on least-privilege grounds and on observability grounds respectively.

## WARNING — delegate is not a security boundary

**`DelegationMode::ReadOnly` is a label, not an enforcement.** Verified on disk in
`~/.locus/opencode-native-xdg/opencode/opencode.json`:

```json
{ "bash": "allow", "edit": "deny", "external_directory": "allow",
  "webfetch": "allow", "websearch": "allow", "task": "deny" }
```

`edit: deny` is walked around by `bash: allow` — `sed -i`, `perl -pi`, `tee`, `git commit`
all work. `is_read_only()` in `crates/locus-core/src/delegation.rs:150` is a mode
comparison, nothing more. The "Do not delegate further" line in
`generate_native_agents_md` is instruction text, not a control.

**Therefore:**

- Never describe delegation as read-only *for safety purposes*. It is read-only *by
  convention*, which holds against an ordinary model and not against a prompt-injected one.
- `webfetch`/`websearch`/`external_directory` are all `allow`, so repository content and
  fetched web content are both injection surfaces.
- Do not route work to delegate on the grounds that it is "safer". Route it there for
  framing independence or context economy — the honest reasons.

This is a real capability gap in a local developer tool, not a production incident.
No remote attacker is implied. It deserves a ticket, not an escalation.

**The generated `CLAUDE.md` currently asserts the false property.**
`crates/locus-adapter-claude/src/config_gen.rs:189` emits:

> Anything requiring writes, commits, or persistent state changes (delegation is read-only)

which reaches `~/.claude/CLAUDE.md:133` and is loaded into every session on the machine.
The realistic failure mode is not an attacker — it is an agent correctly following
documented guidance, treating delegation as contained, and being wrong about the blast
radius. Fix the generator line, then `locus platform add claude-code`. **Never edit the
generated file.**

## Depth and recursion

**A dispatched session must not dispatch.** Default depth limit 1. Orchestration is a
property of the session a human started.

The reason is specific and is not a misuse case: every dispatched session runs *the same
Algorithm* and therefore hits *the same routing rule* in this protocol. Unbounded recursion
would be the designed behaviour working correctly, which is exactly the kind of failure
that does not announce itself.

Depth is **not caller-supplied**. Not a parameter, not prompt text, not an honour-system
field. It is derived by allele from the creating session's own record. Anything a
dispatched session can assert about its own depth is something it can be wrong about, and
the sessions doing the asserting are the ones running the rule that causes the recursion.

Breadth is bounded separately by a **global** cap on concurrent dispatched sessions
(currently 20, aggregate across all dispatchers — per-dispatcher caps do not compose:
twenty dispatchers each under a limit of twenty is four hundred sessions, every one
individually compliant).

### The gap this protocol cannot close

Depth enforcement lives in allele and covers **dispatch only**. A dispatched session has
`bash`, and `locus delegate run` is on `PATH`, and delegates themselves have `bash: allow`.
So this chain is unbounded and invisible to allele's counter:

```
dispatched (depth 1) → locus delegate run → locus delegate run → ...
```

`task: deny` blocks OpenCode's *internal* subagent tool. It does not block the shell.

Until `locus delegate run` carries and enforces its own ancestry/depth, **a delegate must
not invoke `locus delegate run`**, and that is currently a convention only. Treat the
combined depth budget as shared across both mechanisms rather than as two separate
allowances.

## Algorithm placement

Two decisions, two phases. They are different questions and collapsing them is what makes
the placement look ambiguous.

**OBSERVE — may this work leave this session, and by which mechanism class?**
This is an authorisation and capability question. It belongs with capability selection
because it constrains everything downstream: whether data may leave the current trust
domain, whether spawning is permitted at this depth, and which of Q1/Q2 fires. Skills that
are delegate-bound (`red-team`, `council`, `research`) are already selected here, so
mechanism selection is already an OBSERVE concern.

**PLAN — how much, in what order, with what dependencies?**
This is execution topology: how many sessions, what each owns, what blocks what, which
files each may touch. It cannot be settled before the work is sequenced, which is PLAN's
stated job.

If PLAN discovers that the chosen mechanism class was wrong, that is a **return to OBSERVE**,
not a silent override — the ISC criteria and the THINK risks were written against the
original assumption and both need re-checking.

## What a dispatched session is given

Do **not** compose a trait persona for a dispatched session. `locus agent compose` builds a
*stance* for a delegate that has no identity of its own. A dispatched session already has
one: it loads `CLAUDE.md`, runs the Algorithm, and classifies its own work. A persona
layered on top competes with that.

What a dispatched session actually needs is **scope context** — a briefing, not a
personality:

- what is in scope and what was explicitly deferred, and by whom
- the base branch, stated as a fact
- which files it owns, where several sessions run concurrently
- who holds scope authority for questions (see `messaging.md`)
- what the human has and has not agreed to

Deliver this as a **published artifact URL**, not an inline brief. One atomic paste with
nothing to interleave. The failure mode of a truncated inline brief is a session that
starts confidently on half a specification. There is no byte limit at allele's layer — this
is about the delivery race, not size.

`locus agent compose` remains unchanged and delegate-only.

## Loading

This file is not read automatically. `generate_claude_md()` in
`crates/locus-adapter-claude/src/config_gen.rs` names only `memory-schema.md`; a protocol
it does not name is never loaded. Adding a protocol therefore requires a generator change
and `locus platform add claude-code`. **Never edit `~/.claude/CLAUDE.md` directly** — it is
generated and will be overwritten.
