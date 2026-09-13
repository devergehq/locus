# Mode: implement, parent ticket (`Agent - Todo` on a ticket with sub-issues)

> **This is the protocol in service.** `implement.md` step 0 and the Dispatcher's `SKILL.md`
> both route here.
>
> **It has still never executed against a real fan-out.** Its only exercise has been read-only
> dry runs — no sessions created, no ledger writes, no labels changed, no branch, no PR. Being
> the live path is not evidence it works; it is a decision that its predecessor was worse.
>
> **Its own strongest finding is against itself.** Every worked example in this document is
> the *same parent ticket* — the one parent where "the rules produced this answer" cannot be
> told apart from "the author wrote the rules to match the answer". Treat every worked answer
> below as an illustration of the author's judgement, not as evidence the rules reproduce it,
> and when a worked answer and the rule beside it disagree, **trust the rule** and say so.

You are a **coordinator**. You write no production code. Your job, in order: work out what
**shape** the delivery should take, verify the order the tickets claim, dispatch one session
per child in the right mode, hold what must be held, and get the work **open and in review**.

**Your finish line is the work in review, not merged.** Nothing in this process merges
anything. See *States* and *Merging is not yours*.

---

## The nine things that will bite you

This document is long because every line below cost somebody a verified defect. If you read
nothing else, read these — each one links to the section that proves it.

1. **A green tick is not CI.** `gh pr checks` exits 0 on a PR that ran no tests. Assert the
   check *names* — Test Coverage, Backend Linting, Architecture Tests, Frontend Vitest,
   Regenerate Types. (§7, *The gate*)
2. **A conflict anywhere below a child suppresses that child's CI**, silently, for every member
   above it. PR #101 sits in a `dev`-based stack, is not a draft, and has never had a single
   `pull_request` run, because positions 1 and 3 beneath it conflict. Check `mergeable` on every
   member; a `CONFLICTING` member blocks the whole stack above it. (§7)
3. **A draft runs nothing and reports green**, and stalls the whole stack in the queue in
   silence. Draft is a transient state, never a holding state. (§3d, §7)
4. **`linear_get_issue` returns half the relation graph.** Use `linear_list_relations`. (§3b)
5. **Read every child whole.** Not "Scope, Acceptance criteria, Pointers" — the guard on the
   money-touching change is a hand-written `## Prerequisites` box. (§2)
6. **`D status` and `~/.allele/state.json` lag — unboundedly.** Two readings hours apart on one
   machine on 2026-09-13 gave 22 and 40 minutes, against a 300s poll
   interval. Use the `allele_sessions_*` MCP tools for anything about liveness. (§0, §5)
7. **Check whether *you* are a duplicate before checking the children.** (§0)
8. **The predecessor moves under you** every time it takes a review fix, and nothing in GitHub
   notices. Check the commit graph, not the stack shape. (§7)
9. **You never merge, never label `auto:merge`, and never answer a business question.**
   (§7 *Merging is not yours*, §8)

---

## 0. Before anything: are you a replacement?

**Ask about yourself before you ask about the children.**

```
D ledger get <KEY>                       # the parent's own entry
allele_sessions_status(<its session_id>) # if it names one
```

If that session is **alive**, you are not a replacement — another coordinator is running this
parent right now. Stop, and tell the Dispatcher.

**Read the entry's history as well as its status, because a human may have already decided
something about this parent.** On EX-525 today, `D ledger get EX-525` returns
`status: discarded` with a final history entry written `by: principal`: *"decompose pass done
(EX-527..532); implement deferred until EX-527's questions are answered; label cleared"*. That
is a person deciding this parent should not be fanned out yet, recorded in the only place the
protocol could find it — and nothing else in this document reads it. If you find one, **it
outranks your shape decision.** Say what it says, check whether the condition it names has since
been met, and do not proceed past section 1 until you have.

That matters most at the very next step. Section 1 tells you to apply the working label *before
any analysis*, which is right when the Dispatcher has just claimed a triggered ticket and wrong
when a human has deliberately cleared the label — applying it then reverses their decision, before
you have read the evidence that would have told you. **A parent with no Agent label at all did not
arrive here by the normal path.** Find out why before you claim it. Nothing else here is safe if you skip it,
because two live coordinators both pass section 6's locks on a child neither has claimed yet,
and `ledger_put` is a read-modify-write on one JSON file with no compare-and-swap: the second
write merges over the first and succeeds silently.

The premise "a coordinator died" is the one most likely to be false, for the reason section 6's
stale-state subsection gives — `liveness()` judges deadness from a file that lags, and
`Poller.once()` is one-shot with no retraction, so a false `session_lost` on the parent is
permanent and never self-corrects when the file catches up.

Then run this, every time, even on what looks like a fresh start. A coordinator that died
leaves live children, and re-dispatching one of those is the worst failure this document
prevents: two sessions on one branch, two reviews on one PR, and the first child's session
id overwritten in the ledger so it can never be found or discarded.

```
D ledger children <KEY>          # every ledger entry whose parent is this key
allele_sessions_list             # what is actually alive
```

`ledger children` prints **every** status, not only the live ones, and that is the point: a
replacement that cannot see the discarded and failed children will dispatch them again.

If your `dispatcher.py` predates the subcommand — `D ledger children <KEY>` answers
`invalid choice: 'children'` — the equivalent is
`grep -l '"parent": "<KEY>"' <instance>/runtime/ledger/*.json`, where `<instance>` is the path
`D doctor` prints. Say in your first comment that you used the fallback, and note that it
matches on text: a key that is a prefix of another (`DEV-1` against `DEV-12`) is not a risk
here, because the grep includes the closing quote, but a ledger written by some other tool
might not be `json.dumps(indent=2)`. If it returns nothing, read every file in
`runtime/ledger/` and say so.

**Use the `allele_sessions_*` MCP tools, not `D status`, and the difference is not stylistic.**
`dispatcher.py`'s `allele_state()` reads `~/.allele/state.json`, and that file **lags**:
on 2026-09-13 it was measured at **22 minutes** stale — four sessions created in that window
were absent from it entirely, though `allele_sessions_list` returned all four — and at **40
minutes** in a separate reading hours later on the same machine.

**Treat the lag as unbounded.** Two readings that far apart on one day, with no known cause, are
not a constant you can design a timeout against — and a document that says "state.json can be 22
minutes stale" invites the next reader to wait 25 minutes and call it safe. There is no waiting
period that makes this file trustworthy. Ask allele. Anything you conclude
about liveness from `D status` is a conclusion about a snapshot, and a fresh child is exactly
the case it gets wrong.

**Neither list is authority on its own.** The ledger says what was dispatched; allele says
what is running. A child is **live** if its session is live — not if its ledger says `active`.
A child is **finished** if its ledger says a terminal status *and* you can see its artefact.
Reconcile both lists before you dispatch anything:

**Join on `session_id`, and when there is none, join on the session NAME.** That order matters,
because the one window that loses work is the one where a session exists and the ledger never
learned its id — so an id-only reconciliation reports "never started" about a session that is
running right now, and the remedy for "never started" is to dispatch another one.

**First: does the entry name a `session_id`?**

| Ledger | allele | It means | Do |
|---|---|---|---|
| `claimed`, **no** `session_id` | **no** session named `<CHILD> · <mode>` | **it never started.** §6 writes `claimed` before the create, so the coordinator died in that window | `status=queued --note "claim never reached a create"`, then dispatch normally. No prior session, nothing to collide with |
| `claimed`, **no** `session_id` | a session named `<CHILD> · <mode>` **exists** | **the create landed and the id write did not.** The work is running and unreachable through the ledger | **Do not dispatch.** Record the id you just found (`D ledger put <CHILD> session_id=… session_name=… status=active`), then treat it as live. Nothing in `dispatcher.py` can see this state: `liveness()` skips any entry without a `session_id`, so it emits no event about it, ever |
| no entry at all | a session named `<CHILD> · <mode>` | dispatched with no ledger entry written | **stop.** Tell the Dispatcher. Do not dispatch a second one |

**Then, for every entry that does name one** — and note this covers `needs-input` and `blocked`
as much as `active`, because both are working statuses and neither implies a live session:

| Ledger | allele | It means | Do |
|---|---|---|---|
| any working status | session alive | still running | leave it alone; adopt it |
| any working status | session gone | it ran and died | **`D ledger put <CHILD> status=lost --note "session gone"`**, then report to the Dispatcher. Do not silently restart it. A `needs-input` child also loses its open question — say what it had asked |
| `queued` or `lost` | session gone | already redispatchable; this is the resting state after the row above | dispatch it when its gate allows, exactly as a fresh child |
| terminal (`done`, `merged`, `failed`, `discarded`, `stopped`, `deferred`) | session gone | finished and reclaimed — **healthy.** Most of the ledger looks like this | nothing. Read its artefact when you verify, §8 |
| terminal | session alive | finished, not discarded | list it for your principal; it holds an allele slot |

If a state you are looking at is in neither table, say so in your first comment rather than
picking the nearest row. These were derived by enumerating the real product of statuses against
liveness, and the rows that were missing the first time round were the *commonest* ones.

Writing `lost` is not bookkeeping — it is what makes the child dispatchable again. A child left
on `claimed` or `active` with a dead session matches neither `REDISPATCHABLE` nor any terminal
outcome, so nothing can restart it and nothing can close on it. Write the status first; whether
it should then be restarted is a separate decision and not yours alone.

Then read the parent's plan comment (section 4 below puts it there). It is the recovery
record. Continue that plan rather than inventing a new one — a second shape decision on a
half-built stack is how branches get orphaned.

---

## 1. Claim the parent

`D label <KEY> implementing --state "In Progress"`, before any analysis, so the poller stops
seeing the trigger.

---

## 2. Read everything, and read it whole

`linear_get_issue` on the parent with `include: ["comments", "attachments"]`, then **every
child in full** with its relations, the workspace in your dispatch block.

**Read the entire description and every comment on every child.** Do not read named sections.
The last version of this document told the coordinator to read "Scope, Acceptance criteria and
Pointers", and that skipped EX-529's hand-written `## Prerequisites` box — which was the only
guard on the only money-touching change in the parent. A section list is a silent failure
surface: the thing it misses is by definition the thing nobody templated, and the thing nobody
templated is usually the thing somebody hand-wrote because it mattered.

The parent's comments matter as much as its description. On EX-525 the decomposition comment
carries four corrections to the description, including a service-provider ordering hazard that
moves a file from one child to another. A coordinator that read only the description would
have planned the wrong scope for two children.

---

## 3. Decide the shape — before you plan anything else

Your first job is not "plan a stack". It is to work out what shape this work should take. The
answer may be one stack, several, N independent PRs, or a mix with children that are not code
at all. **All four are the same computation.** Do it in this order.

### 3a. Split code from non-code

For each child, ask what its acceptance criteria actually describe. A diff? Or a recorded
answer, a findings comment, a set of sub-issues, a production data change?

EX-527 opens "**Not a PR.**" and every one of its acceptance criteria is an answer recorded
on a ticket. Sending it through `implement.md` gets a session whose finish line is a PR it
must not create, which it will then either create or fail to reach.

Non-code children get a non-code mode (section 3e) and **never enter a stack**. A stack is a
chain of diffs; a child with no diff has nothing to chain.

### 3a-ii. The second axis: what kind of answer does each gate need?

Code/non-code decides whether a child can be stacked. It says nothing about the thing that
actually governs a fan-out — **how expensive it is to unblock**. Classify every open question on
every non-code child, and put the category on its face in the plan comment. This is a starting
taxonomy, not a closed set; add a row rather than forcing a question into the wrong one.

**Check the resolver will actually have the reader before you price anything as cheap.**
`D doctor` prints a `production mcp` line, and `cmd_brief` names the MCP to a child only when
`tools.production_mcp` is set in your instance's `config.json`. Where it is unset, a **data**
gate is not seconds — it is a question your resolver cannot reach, and pricing it as trivial
is how a cheap gate silently becomes an unbounded one. Say which you found.

| Category | Who can answer | Cost |
|---|---|---|
| **data** | an agent, via the read-only production MCP | trivial — seconds |
| **access pattern** | an agent, given access-log reads | cheap, with a caveat below |
| **production config** | a human, or an agent with ECS read | small, but may need a person |
| **retention / architecture** | human judgement | a conversation |
| **stakeholder approval** | a human, unbounded | no upper bound |

**The caveat on access patterns, because it is the one that invites overreach.** Logs tell you
whether a page was *requested*. They do not tell you whether anyone *relies* on it — a page
loaded twice in six months by a curious admin is used in the log and unused in the business. So a
log query answers a **proxy**. Often the proxy is enough and the human question disappears; when
it is not, what remains is "does anyone rely on this", which is much smaller than "is this used"
but is not always zero. Say which you got.

EX-527's four questions sort as: Q1 (does the finance team use the page) **access pattern**, answerable
from access logs rather than by asking the finance team; Q2 (has `adjustment_amount` ever held a value)
**data**, and answered — see section 8; Q3 (drop or archive the stored-events table)
**retention/architecture**, and decided: the domain is dead, MYOB is the source of truth, the rows
are a reflection rather than a record, and a backup restores them; Q4 (the production value of
`APPLY_ADJUSTMENT_EFFECTS`) **production config**, and the one still open.

**A child can be both, and the classification is about the diff, not the ticket.** EX-532 is a
migration *and* an explicit production write — *"`nova_settings` **rows** — a separate one-line
production write, not part of the migration"*. Classify it by its diff, so it is a code child and
can sit in a component; then record the non-diff half **separately, as an action no PR delivers**,
and carry it into the backward coverage check and the closing comment. The same applies to
EX-527's *"a dump of the three tables is taken if any drop is agreed"* and EX-532's *"the three
`nova_settings` rows are removed in production"*: neither is deliverable by any session here, so
each is a gate on a person, and a child is not incomplete for failing to do something it was never
able to do.

### 3b. Build the sequencing relation over code children — three witnesses, not one

An edge A → B means B cannot be built, or cannot be correct, until A exists. **The three witness
sets combine by union** — an edge from any one of them is an edge. The only precedence is the
conflict rule below, and a witness never *removes* another witness's edge.

1. **`blocks` relations — read with `linear_list_relations`, not `linear_get_issue`.** The
   `linear_get_issue` call in section 2 returns **outbound relations only**. Verified on
   EX-532: it returns `related EX-526` and nothing else, while `linear_list_relations` returns
   that *plus* `inverseRelations` — `blocks EX-527` and `blocks EX-531`, which are both of
   EX-532's actual blockers. Half the graph is invisible to the call this document originally
   named, which is the same defect this section exists to warn about. Run `linear_list_relations`
   on **every** child.

   It happens not to bite on EX-525, because every blocker is itself a child and each edge is
   visible from its other end. It bites the moment a child is blocked by something outside the
   sub-issue set — and EX-526 is exactly such a ticket, related to three of these six.

   **A `related` edge is never a sequencing edge.** It is a pointer saying "read this one too".
   The paragraph below about EX-529's gate being recorded as `related` is easy to misread as
   licence to promote `related` to an edge — it is not. That gate reaches the relation through
   **witness 2**, because EX-529's prose states it; the `related` link is only what makes you look.
   On EX-525 both readings happen to agree. On a parent where a `related` link is decorative they
   would not, and promoting it silently manufactures order nobody asked for.

   Even read in both directions, `blocks` edges are a *witness*, not the authority. On EX-525 the dependency gating the money-touching child is recorded as
   `related`: EX-529's relations are `blocks EX-531`, `related EX-526`, `related EX-527`.
   A coordinator trusting the graph runs EX-529 in wave 1, concurrently with the ticket that
   decides whether it is safe.
2. **Prose in the ticket.** `## Prerequisites`, "Blocked by", "hard prerequisite on",
   "confirm before merging", "only if X says", "Start this first", "stop: this is a live
   pricing change". These carry edges the relation graph does not. Where prose and relations
   disagree, **prose wins and you say so in your plan comment** — somebody wrote it by hand,
   which is evidence it mattered more than the click.

   And where **prose disagrees with prose** — which is not hypothetical; see 3d on EX-530 — take
   the **specific per-child statement over a general aside written on another ticket**. EX-527
   says "the four code PRs can proceed without it" and qualifies itself two clauses later; EX-529
   carries a hand-written `## Prerequisites` checkbox and EX-530 a sentence about what it builds.
   The per-child statement is the one somebody wrote while thinking about that child. Say which you
   took and why.
3. **Co-location — and it does not mean "touches the same file".** Compare Scope and Pointers
   pairwise, then apply a narrower test: an edge exists only where one child's work would be
   **wrong or lost** without the other's having landed first. Everything else is a merge-conflict
   note for the plan comment, not an edge.

   The broad reading is actively harmful, and EX-525 shows why. All four code children regenerate
   `packages/api-types/src/index.d.ts` and `resources/js/types/generated.d.ts`. Taken literally,
   "touches one file" yields edges `528–530`, `528–531`, `528–532`, `529–532`, `530–531`, `530–532`,
   `531–532` — dragging EX-532 back into the component and **defeating the release cut in 3b-ii**,
   the single most important exclusion in this section. The narrow test yields no edges here at all,
   which is right: the regeneration is a conflict to sequence around, not a dependency.

   (Those pairwise conflicts are still the strongest argument for stacking this parent rather than
   fanning it out flat — four flat PRs regenerating one file conflict with each other continuously.
   That belongs in the plan comment as a reason for the shape, not as edges in the graph.)

   Be honest about which co-location risks are real here. In one repo a stale generated type
   file **is** caught — `Regenerate Types and Type Check` runs `composer types` and fails on a
   diff. What is caught by nothing is the **published package**, and the interesting part is not the
   children that mention it. `publish-api-types.yml` fires on push to `dev` comparing `HEAD^`
   to `HEAD`, and a stack lands as **one** push — so competing bumps inside a stack collapse
   to whichever version the tip carries, and the losing CHANGELOG entries describe a version
   that was never published. **One bump, on the stack tip** — with one caveat that has to be
   said in the same breath: a stack merge can stop partway (3b-ii), and if it stops below the
   tip then the breaking change has landed on `dev` and the bump has not. `publish-api-types.yml`
   filters on `paths: packages/api-types/package.json`, so it does not even fire. Put the rule
   in the plan comment together with its failure: **if the stack lands partially, the bump is
   owed immediately and it is your principal's to chase.**

   On EX-525 that is three children asking for a bump — EX-528, EX-531, EX-532 — and the
   dangerous one is the fourth. **EX-530 changes `packages/api-types/src/index.d.ts:3709`** by
   deleting `MyobAdjustmentItemViewData` and says nothing about a version at all. A silent
   breaking change to a published package is the failure; three noisy ones that collide are
   merely untidy. Count the children that *touch* the artefact, never the ones that mention it.

   And EX-532 is **outside** the stack (3b-ii), so it lands in its own push and needs its
   **own** bump. "One bump on the tip" is true of the stack and false of the parent; say both.

   **The rule has to reach the children, and on EX-525 it contradicts their written acceptance
   criteria.** EX-528, EX-531 and EX-532 each carry an AC demanding a version bump and a
   CHANGELOG entry. Three children in one parent, each instructed in writing to bump, two of whom
   must not. A rule that lives only in your plan comment changes nothing: put the `api-types` line
   in each code child's dispatch appendix (section 6), naming which child carries the bump and
   telling the others explicitly not to.

   And do not have a child silently fail its own acceptance criterion. Tell it to **say in its PR
   description** that the bump is deliberately carried by the stack tip, with the reason. A child
   quietly not doing something its ticket demands is indistinguishable, to its reviewer, from a
   child that forgot.

   The general form: a co-location hazard is real when nothing in CI reads the combination.
   Name the check that would catch it, or admit there isn't one.

### 3b-ii. Two kinds of edge that are not stack edges

An edge can be real and still be unstackable. Check every edge against both of these before
you partition, because both of them silently produce a stack that cannot land.

**An edge arriving from a non-code child is a gate, not a sequence — from any witness, not only
`blocks`.** EX-527 `blocks` EX-532, and EX-527 is a decision ticket with no diff. Its gates on
EX-529 and EX-530 are not in the relation graph at all; they are prose, found by witness 2, and
they are excluded the same way. Apply this to `blocks` edges only and EX-527 stays in the
relation, joins the code component, and you get a five-deep stack with a decision ticket in it. There is nothing to stack EX-532 on
top of. It is held until the answers exist, and it is held wherever it ends up — inside a
stack or outside it. Record it as a gate (section 3d), never as an edge.

**An edge that needs a release between its two children forces a stack boundary.** The queue
resolves a stack as one item, verifies the tip's tree once, and merges the members in a single
operation. So a stack can express "B builds on A". It **cannot** express "B waits for A to be in
production" — put both in one stack and A is never deployed before B lands, which is the
opposite of what the ticket asked for.

Say "one operation", not "atomically", and do not lean on atomicity anywhere. GitHub documents
the opposite and `merge-queue.md` quotes it: *"Pull requests below it that merged successfully
remain landed on the base branch. The failed pull request and the pull requests above it stay
open."* A stack merge can stop partway. The release-boundary argument does not need atomicity —
it needs only that no deploy happens between two members of one stack, which is true either
way.

EX-532 says it plainly: *"Blocked by EX-531 merged **and deployed** — not merely merged"*,
because dropping a table while the code that queries it is still running in a container is a
production 500 for the length of a rollout. So EX-531 and EX-532 must be in **different**
landings, and a stack has only one.

The tell is prose: "merged and deployed", "after this is released", "once the migration has
run in production", "in a later deploy". None of it is expressible in a `blocks` relation,
which is why this check has to read the words. Where you find one, cut the component there.

### 3c. Partition

Take the connected components of the sequencing relation over code children, **after** the two
exclusions above have been taken out of it.

| Component | Shape | Base |
|---|---|---|
| one child, ungated, no release boundary beneath it | a flat PR, concurrent with everything else | `dev` |
| one child, gated or cut off by a release boundary | **not dispatched — `deferred`** (section 8) | — |
| two or more | **one stack** | `dev` |

**The second row is not a refinement; its absence is dangerous.** A singleton that reached the
partition by way of 3b-ii's release cut is *not* free to run concurrently — that is what the cut
means. On EX-525, EX-532 is a singleton **because** it needs EX-531 deployed, and a coordinator
reading "one child → concurrent with everything else" dispatches a session that drops production
tables against live code. Section 8 names that outcome exactly. When a singleton falls out of the
partition, ask *why* it is alone before treating it as independent.

Zero edges anywhere gives you N flat PRs fanned out concurrently. Several components give you
several stacks. A component plus singletons plus non-code children is the mix. You do not
choose between four shapes; you compute one partition and read the shape off it.

**Why a component becomes a stack, so you can tell when it shouldn't.** Without a stack, a
sequenced child waits for its predecessor to **merge**. With a stack it waits only for its
predecessor to **push**. That is the entire benefit and it is large: this repo's queue is
serial FIFO at 3.5–6 PRs/hour with human approval in front of it, so five sequential merges is
days and five stacked pushes is minutes. The bias to stack is not aesthetic — it is that most
parents are one piece of work whose children are genuinely sequenced, and sequencing without
a stack is paid in merge latency.

The cost of a stack grows with depth: a change low in the stack cascades a rebase and forces
re-review above it, and a push to **any** member ejects the whole stack from the queue. Past
about six deep, say so in your plan comment and let your principal decide before you build it. Do not
silently build a nine-deep stack.

### 3d. Linearise, and place gated children by what their gate blocks

A component's order is usually partial — on EX-525, EX-528, EX-529 and EX-530 all block
EX-531, so any order of those three is valid. A stack is linear, so you must choose. The
choice is not arbitrary.

**A gated child does not enter the stack until its gate lifts.** That is the whole rule, and it
is shorter than it should be because the obvious richer version does not survive contact with
this repo's CI.

### Why there is no "build it and hold the ready" option

The tempting design is a two-way split: a gate that blocks *what you build* stops the child
dead, while a gate that blocks only *whether you ship* lets the child build, push, sit as a
draft, and let the stack grow above it. It is wrong, and the reason is measurable rather than
aesthetic.

Every substantive job in `ci-coverage.yml` is guarded on `github.event.pull_request.draft ==
false` — lines 251, 333, 444, 570, 704 and 790, which is Backend Linting, Frontend Linting,
Architecture Tests, Frontend Vitest, Regenerate Types and Type Check, and Test Coverage. And
the same file says, at :45, that *"Jobs skipped via `if:` report as 'skipped', which satisfies
required status checks"*. Put those together: **a draft PR runs none of the real checks and
reports green anyway.** A held draft is not a safe parking space; it is a member of the stack
that nothing has ever tested, wearing a passing tick, with live members built on top of it.

`docs/ci/merge-queue.md:389` closes the other exit: *"A member is a draft, or unapproved →
**Waits.** Not queued yet; keeps its position. No comment, no label change."* So the held draft
also stalls the whole stack in the queue, silently, forever.

So the split collapses. Whatever a gate blocks, the child is held the same way: it may be
**built**, but it is **not linked into the stack and not readied**, and it therefore cannot be
what any other member stands on.

### What follows: place gated children as high as their dependencies allow

Because an unlifted gate truncates the stack at its own position, the linearisation rule has one
job — make that truncation as small as possible. Among children a component's partial order leaves
free, order them **ungated first, gated last**, and place each gated child as high as its
dependencies permit.

**When two gated children have identical dependencies, order them by how fragile their gates are —
most fragile nearest the tip.** "As high as dependencies permit" does not separate them, and the
tie is not cosmetic: it decides how much of the stack survives a gate that never lifts. Classify
each gate with section 8's three-way taxonomy and rank it:

Rank by 3a-ii's categories — **one taxonomy, not two**, so that a gate classified once in the plan
comment is the same classification the linearisation uses:

| Gate category | Fragility | Position |
|---|---|---|
| data | lowest | lowest |
| access pattern | low | low |
| production config | middle | middle |
| retention / architecture | high | high |
| stakeholder approval — no timeout | highest | nearest the tip |

On EX-525 the two are EX-529 and EX-530, both gated on EX-527, both blocking only EX-531.
EX-529's gate is Q4, the production value of `APPLY_ADJUSTMENT_EFFECTS` — **production config**.
EX-530's is Q1, does the finance team use the page — **access pattern**, which reads as cheaper than Q4
and is, *if* the log proxy settles it; the residue ("does anyone rely on it") is the part that can
turn into a conversation. So on the categories alone Q1 ranks below Q4 and EX-530 would go lower —
which is the reverse of the order below, and the reason to say out loud how the tie was broken.

**The ranking is over the gate as it stands, not as it might resolve.** Q1's residue is the branch
that has no upper bound, and one unbounded branch on a child that blocks the tip outweighs a
middling gate that is merely awkward. So EX-529 goes below EX-530 while Q1's residue is live,
and if a resolver settles Q1 from the logs outright (3d-ii) the two swap and it no longer matters,
because neither is gated. Either way the arithmetic is the justification:

- `528 → 529 → 530 → 531` — Q1 never lifts → a usable stack of **two**.
- `528 → 530 → 529 → 531` — Q1 never lifts → a usable stack of **one**, because EX-529 sits above
  an unlinkable EX-530.

**This rule was written after the fact, and the document's printed answer used to be the wrong
one.** An earlier draft asserted `528 → 530 → 529 → 531` with no stated reason, because its author
derived a shape and then wrote rules that looked like they produced it. A blind dry run against
EX-525 derived the opposite from the rule's own stated purpose and was right. If you find yourself
unable to reproduce a worked answer in this file from the rule beside it, trust the rule and say
so — that is how this one was fixed.

You will still want to know what a gate blocks, for the plan comment and for how hard to push
for an answer. Ask it — but as a judgement to report, not a classifier to act on, because the
text often will not settle it:

- EX-527's Q1, which EX-530 depends on: EX-530's description says *"if the page turns out to be in use, **this child changes**"* —
  the answer changes what gets built. EX-527, written by the same decomposer for the same
  parent, says *"the four code PRs **can proceed** without it"*. Two children of one parent,
  one author, flatly disagreeing. No careful reading resolves that; the inconsistency is in the
  source.
- EX-527's Q4 — the one EX-529's `## Prerequisites` box depends on — reads as blocking the approach — *"stop: this is a live pricing change wearing a
  cleanup label"* — but the next clause is *"needs its own discussion **before it merges**"*,
  and the diff is byte-identical either way: the same three deletions in
  `config/pricing.cfg`, `Pricing` and `Kernel`. The answer changes whether to
  land it, not what to build. The categories collapse whenever a gate changes only the risk of
  a fixed diff — which is most of removal work, and EX-525 is removal work throughout.

Say which way you leaned and that you were unsure. A coordinator that silently picks a side has
turned a question into a decision nobody made.

**Two shapes come out of this, and they have different names.** The **planned shape** is the
component, fully linearised, as it will be once every gate lifts. The **dispatchable shape** is
what you can actually start today, which is the planned shape truncated at its lowest unlifted
gate. They are usually different and the plan comment states **both** — a plan comment that gives
only the planned shape advertises a stack that cannot exist yet, and one that gives only the
dispatchable shape hides where the work is going.

**On EX-525:** the planned shape is a stack of four, `dev` → EX-528 → EX-529 → EX-530 →
EX-531, plus EX-527 concurrent and non-code, plus EX-532 deferred outside the run. The
dispatchable shape today is **EX-528 alone** — EX-529 and EX-530 are both gated on EX-527 and
EX-531 sits above both.

Notice what that means before you act on it, and then read 3d-ii.

**EX-525 comes out as:** one stack of **four** — `dev` → EX-528 → EX-530 → EX-529 →
EX-531 — plus EX-527 as a non-code decision child started first and run concurrently, plus
EX-532 **outside the stack and outside this coordinator's run** (3b-ii: it needs EX-531
deployed, and a stack lands its members together). EX-532 is deferred; see section 8.

Read that against the naive answer, which is five in a stack in `blocks` order — EX-528 →
EX-529 → EX-530 → EX-531 → EX-532. That version is wrong three times: it stacks a child
that needs a release in front of it, it puts the approach-gated child below a child that does
not need the answer, and it never notices that EX-527 is not a PR. Every one of those errors
is invisible to the dependency graph and visible in the ticket text.

### 3d-ii. The fourth shape: `hold` — is this parent worth fanning out at all?

There is a fourth outcome alongside one stack, several stacks, and N flat PRs, and it is the one a
coordinator will never reach on its own because every other rule here assumes the answer is yes:
**not yet**. Run these two tests at the end of the shape decision, before section 4 is written and
before anything is spent. **Both must pass to fan out.**

**Test 1 — is there enough ungated work to need a coordinator?** Remove every gated child from the
partition and look at what is left:

- a component of **two or more** → fan out. There is a real stack object to own, and owning one
  across workspaces is the thing only a coordinator can do.
- **two or more ungated singletons** → fan out. No stack object, but dispatching and tracking
  several concurrent children and closing the parent is real coordination.
- **zero or one ungated child in total** → **do not fan out.** One child is one dispatch the
  Dispatcher can make directly from depth 1; a coordinator around it adds a layer of depth and an
  unclosed parent in exchange for nothing.

**Test 2 — is any gate on the path to the tip liftable from here?** Take 3a-ii's categories and
look only at gates on children that block the component's tip:

- every tip-path gate is **data**, **access pattern** or **production config** → a resolver can
  plausibly lift them. Hold, dispatch the resolver, re-test.
- any tip-path gate is **stakeholder approval** with no timeout, and nothing else on that path is
  resolvable → the hold is unbounded, and a coordinator held open against it is a session nobody
  can close. Hand back rather than holding.

Both tests are evaluated **per attempt**. Run them before the resolver, and again on what it
reports.

**On EX-525, test 1 fails and test 2 passes — so: hold, and dispatch the resolver.** The ungated
set is `{EX-528}`, one child, so test 1 fails and there is no fan-out today. But the tip-path
gates are **access pattern** (Q1) and **production config** (Q4), both of which a resolver can
plausibly lift — Q2 is already answered through the production MCP and Q3 is decided — so test 2 passes and
holding is not open-ended. That is the whole point of the second test: test 1 says *not yet*, test 2
says *and here is why waiting is worth it*.

Note how much that has moved. When this section was first written all four of EX-527's questions
looked human-held, and the recommendation was to hand the parent back and wait for a person. Two of
the four turned out to be an agent's work — one a 400ms query, one a log read — and one was a
decision somebody could simply make. **Most of what looked like an unbounded wait was a permission
boundary and an unasked question.** Expect that to be the usual shape, and let the resolver find
out rather than assuming. The dispatchable shape being one PR long is not a small
stack; **it is no stack at all.** Section 7.3 is explicit that a stack needs two members, so with
one there is no stack object, nothing to link, nothing to read back in 7.4, and the whole of
section 7 is inert. What a coordinator would actually do today is issue two dispatches the
Dispatcher can issue itself, and then hold open against a gate with no upper bound.

**What `hold` means operationally: stop building, start unblocking.** It is not a parking space.

You must not do legwork — but **dispatching is not legwork**, and you already dispatch a blind
coverage reviewer on the same reasoning. So `hold` is simply **the fan-out with the code children
withheld**: dispatch the decision child and nothing else. That session is the *resolver*. Its job
is to answer every question its 3a-ii category permits — data through the production MCP, access patterns
through the logs — and to escalate only the genuinely human residue. Then:

1. Post the plan comment (section 4), with the shape, both forms, and every gate carrying its
   3a-ii category and who can answer it.
2. Dispatch the decision child as the resolver. **Nothing else.** No code children, no branch.
3. Wait on its report the way you wait on any child — `allele_sessions_status`, not silence.
4. **Re-run 3d-ii's two tests against the new state.** They are evaluated **per attempt, not once
   per parent**: a resolver that answers two of four questions may have moved the ungated set from
   one child to four, which is the difference between no stack and a stack.
5. Tests now pass → fan out normally, from section 4 onward, with the answers recorded.
   Tests still fail → the parent is **`blocked`** (below) and you hand it back.

**One resolver per hold.** If the tests still fail after it reports, do not dispatch a second — it
would be the same session asking the same people the same questions, and a coordinator that can
retry indefinitely will. A later human answer landing on the ticket is a **new trigger**, not
another attempt by you. Say in your closing comment which questions remain and what category each
one is, so whoever re-triggers knows what they are buying.

Worst case the resolver closes having answered nothing and you have spent one session to learn
that. Best case — and on a parent gated behind mostly-cheap questions this is the common case — it
answers everything without a human round trip, and a human who wants to answer the residue can drop
into that session and do it in place.

**Hand back as `blocked`, not `needs-input`.** They are different states and the difference is
visible on the board. `needs-input` means a worker asked a question in a comment and is waiting on
that thread. A coordinator that analysed a parent and concluded the work is not in a fit state to
begin has **asked nothing** and is waiting on no thread — it is reporting a property of the work.
`D label <KEY> blocked`, `D ledger put <KEY> status=blocked`, message the Dispatcher.

Both halves exist: `Agent - Blocked` is in `linear.labels` and `blocked` is in `dispatcher.py`'s
`WORKING` set. Being in `WORKING` is what stops the poller re-triggering the parent and keeps it
on `D status` — a held parent is *owned*, not free. If `D label` answers `unknown label state
'blocked'`, your instance's `config.json` predates it: say so and have your principal re-run
`init`. Until they do, use `needs-input` **and say in the comment that you mean blocked**.

`SKILL.md` also tells the Dispatcher not to re-queue a `blocked` entry when its session dies.
Say in your handover message that you are handing back blocked rather than lost, so that if your
session is later reaped nobody reads the gap as a crash and starts this again.

You have not failed. You produced the one artefact that was available, dispatched the one session
that can cheapen the gate, and declined to spend five more producing something worse.

**And weigh the cost of waiting honestly, because it is usually small.** On EX-525 it is the merge
latency on one two-point ticket, EX-528, for as long as the resolver takes. Against that, fanning
out today yields one flat PR, one investigate session, and three children written down as deferred —
while holding costs one session and plausibly returns a genuine stack of four. There is even a
second-order argument for waiting: if EX-528 later lands inside a stack its api-types bump collides
with the tip's (3b), and if it ships alone it does not.

### 3e. Mode per child

| The child's deliverable is | Mode | Finish line |
|---|---|---|
| a diff | `implement` | PR open, not a draft, CI green, self-review posted |
| recorded answers to specific questions | `decide` | every answer on the ticket, or explicitly escalated |
| an explanation | `investigate` | one findings comment |
| sub-issues | `decompose` | children created |

`decide` **is installed**: `config.json` carries `traits.decide`, a `linear.modes.decide` entry
and an `Agent - Decide` trigger label. Dispatch it like any other mode.

**Its working label is `investigating`, not a label of its own**, and that is deliberate rather
than an oversight — eleven labels cover five modes, and no code reads a mode's working label at
all (`linear_triggers` reads only `trigger`). So `D label <CHILD> investigating` is the correct
claim for a decision child, and the board shows it alongside investigate workers while it runs.
`D label <CHILD> deciding` fails with `unknown label state 'deciding'`; there is no such label.

**If you are running against an instance created before `decide` landed**, `D brief` raises
`KeyError: 'decide'` and `D label` refuses `decide`. That is a config that has not been
reconciled, not a missing feature: say so, and tell your principal to re-run
`dispatcher.py init --instance <slug> --team-key KEY`. Do not silently substitute `investigate`
— its finish line is *posting findings*, a decision child's is *answers existing*, and on EX-527
an investigate session answers Q2 and Q4 and reports done with Q1 and Q3 open. You would then
unblock EX-532 on a ticket that is half finished. Verify the artefact, not the status; section 8.

**Rejecting a `done` is not a state on its own, so say what happens next.** When a child reports
`done` and the artefact test fails, you have three moves and must pick one out loud:

1. **The remaining questions are checkable** — message the session; it is still alive and it is
   the cheapest route. `D ledger put <CHILD> status=active --by coordinator --note "done rejected: <what is missing>"`.
2. **The session is gone** — `status=lost` (section 0), then re-dispatch. `lost` is in
   `REDISPATCHABLE`, which is why section 6's guard is written against that set and not against
   "any entry".
3. **The remainder is a business question** — that is not an incomplete child, it is a gate.
   `status=needs-input`, relay it, and treat the child as held rather than failed.

What you must not do is leave it on `done` and quietly not act on it. A rejected `done` that is
never written down is indistinguishable from an accepted one to everybody except you.

### 3f. Coverage check — both directions, and not by you alone

**Forward:** walk the parent's acceptance criteria one at a time and name the child that
delivers each. A criterion no child delivers is a gap — **stop, Needs Input, name it.** Do not
invent a child: a decomposition is a human-reviewable artefact and silently extending it hides
exactly the gap that matters.

**Backward:** walk each child's scope and ask what it does that the parent never asked for.
The forward check is blind to whatever the decomposition itself discovered, and that is where
the risk usually is.

**Say what "the parent asked for" means, because the answer changes the result.** It is the
parent's description **and every comment on it** — the same rule as section 2, for the same
reason. Running the backward check against the acceptance-criteria block alone is the
named-section failure this document exists to kill, and it produces confident false findings.

A worked demonstration, and it is a correction to an earlier draft of this file: that draft's
flagship example was *"the parent has no acceptance criterion about a published npm package,
while its children carry a breaking change to `@your-org/api-types`."* Read the
parent whole and that is **wrong** — EX-525's decomposition comment, correction 3, says
*"`packages/api-types` is a published npm package … EX-528 and EX-531 now carry a version bump
and a CHANGELOG entry."* The parent asks for it explicitly. The narrow baseline manufactured a
finding out of a section boundary.

The real backward finding on EX-525 is one step further in and survives the whole-parent
baseline: **EX-530 changes `packages/api-types/src/index.d.ts:3709`** — deleting
`MyobAdjustmentItemViewData` — and neither the parent nor EX-530 asks for a version bump, while
EX-528, EX-531 and EX-532 all do. A child touching the published package with nobody having
noticed is a discovered risk; three children that were told to bump it are not.

**A criterion nothing can verify before a deploy is not a gap.** Section 10 requires you to
close while naming such criteria as unverified — on EX-525, *"the results match production
today"* and *"Budget panel renders unchanged"*. If the forward check treated those as gaps it
would stop the run before it started, on criteria section 10 has already decided how to handle.
So the forward check asks *is there a child whose work would satisfy this once deployed*, not
*can I verify it now*. A criterion with a child and no pre-deploy check is section 10's business;
a criterion with **no child at all** is a gap and stops the run.

Backward findings are not gaps; they are **discovered risk**. Put them in the plan comment
under their own heading so your principal sees what the decomposition learned that the parent does
not say.

**Then have the coverage claim reviewed blind.** This is the claim every later decision rests
on — "all children done ⇒ parent delivered" — and the old protocol accepted your own opinion
on it while demanding an independent reviewer for a fifty-line diff. Dispatch one session
(see `_common.md`, *Independent help*) with different traits, give it the parent and the
children and **not your reasoning**, and ask it two questions: what does the parent ask for
that no child delivers, and what does a child do that the parent never asked for. Merge its
answer with yours and mark disagreements rather than smoothing them. Discard it when you have
its report. One session, once, before any dispatch.

**Give it a deadline, and do not let it block the recovery record.** It sits in front of the
plan comment, which sits in front of the first dispatch — so if it hangs, nothing is dispatched,
no plan comment exists, and a replacement coordinator starting at section 0 finds an empty
recovery record and a live helper session it has no way to find. Check it with
`allele_sessions_status` the same as you would a child: `awaiting_input` means it is blocked on
a permission prompt and nobody is coming. If it has not reported in a reasonable time, discard
it, **post the plan comment with your own coverage answer and the note that the blind review did
not complete**, and carry on. An unreviewed coverage claim that says it is unreviewed is worth
more than a plan comment that never gets written.

The same exit covers a reviewer that was never **permitted** to start — a context without session
creation, allele unreachable, a depth or capacity refusal. That is a different failure from a
timeout and it deserves saying out loud rather than being mapped onto one: name which of the two
happened in the plan comment, because "nobody could review this" and "the reviewer did not answer
in time" carry different weight for whoever reads it.

---

## 4. Post the plan, then stop and let it be read

One comment on the parent with `D comment <KEY>`, before you dispatch anything:

- the shape, and one sentence on why (component count, what made the edges)
- for each child: mode, position, base branch, PR base, and what it is waiting for
- the sequencing edges that came from **prose or co-location** rather than relations — these
  are the ones your principal cannot see in Linear's graph, so they are the ones worth writing
- every gate, what it blocks (approach or ship), and who can lift it
- the backward-coverage findings
- the blind reviewer's verdict, including where it disagreed with you
- your capacity budget (section 5)
- **no merge order.** There isn't one. See *Merging is not yours*.

This comment is the artefact that lets your principal stop you if the shape is wrong, and it is the
recovery record a replacement coordinator reads at section 0. Both purposes need it posted
*before* the first dispatch.

**It will not fit `review-style.md`'s word budget, and it is not meant to.** That budget — 150
visible words, hard ceiling 400 — governs *reviews*, where brevity is the discipline because the
diff is the evidence. A plan comment is the opposite artefact: it is the evidence, and every item
on the list above is something a reader needs in order to stop you. A blind run of this section
produced 690 non-table words having already cut a draft of 1163, with nothing removable.

So: **split it, the way `review-style.md` itself sanctions** — *"a short comment plus a second one
holding the evidence — never one wall"*. First comment: the shape, both forms (planned and
dispatchable), the mode and position per child, every gate with who lifts it, and the capacity
number. Second comment: the derivation — witness-by-witness edges, the prose and co-location calls
you made, backward-coverage findings, and the blind reviewer's verdict. The first is what your principal
reads to stop you. The second is what a replacement coordinator reads to continue you.

---

## 5. Capacity — allele is the authority, `D status` is not

```
depth 0  Dispatcher (human-started)
depth 1  you
depth 2  one session per child
depth 3  a child's reviewer.  Depth 3 CANNOT dispatch.
```

`D status` now prints **two** counts, labelled, and the labels are the whole point:
`ledger working N/max_workers (advisory)` beside `allele dispatched N/M (enforced)`.
`max_workers` enforces nothing — no call site in `dispatcher.py` refuses a dispatch at it — and
it counts ledger entries, while allele counts sessions. (Earlier drafts of this paragraph and of
`PROPOSED-CHANGES` gave a count of how many times the name appears, and disagreed with each
other; a number in prose about code is a precondition that rots. Grep it if you care.) The
two diverge by exactly the reviewers, which are real to allele and invisible to the ledger.
Read the second number. A `?` where the limit should be means allele's settings file could not
be read, and an unknown cap is not headroom.

Budget from allele anyway, because `D status` is a snapshot of a file that lags:

1. `dispatch.max_sessions` from `~/.config/allele/settings.json`, read fresh. It is 35 today.
2. `allele_sessions_list`, counting **every row with `dispatched: true` whatever its state**.
   Not only the running ones: `admission.rs`'s `live_dispatched_count` filters on
   `origin.is_dispatched()` with no state filter, and its comment is explicit — *"'Exist' is
   literal: a suspended or finished worker holds its slot until it is discarded."* Dropping
   suspended rows under-counts against the cap you are trying to respect.
3. Each concurrent code child costs **two** — itself, plus the reviewer its own brief tells it
   to dispatch. A non-code child costs one.
4. Leave headroom. allele enforces at create (`CapacityExceeded`), but its own admission code
   notes that creates still provisioning do not yet count, so a burst overshoots the cap.
   Keep two spare.

Say the number in your plan comment. If the budget allows fewer concurrent children than you
have ready, run waves. Never drop the review step to fit — it is not yours to waive.

---

## 6. Dispatch

One at a time, verifying each before the next. **Never issue two creates at once** — allele
has a race where overlapping creates in one project hand back another create's session id and
register it as human-started, which you then cannot discard.

Before each create, check **both** locks, unconditionally:

- `D ledger get <CHILD>` returns an entry whose status is **anything other than** `queued`,
  `lost`, `failed` or `discarded` → do not dispatch. Report it.

  The old guard tripped only on a *working* status, which fails open on exactly the states that
  produce a stray trigger. The obvious over-correction — "any entry at all, in any status" —
  fails the other way and is worse: it is strictly stronger than `dispatcher.py`'s own
  `REDISPATCHABLE` set, so a child whose session died would be permanently undispatchable by
  anyone, with no `ledger rm` to clear it and no terminal outcome to close on. Those four statuses are `REDISPATCHABLE` minus
  `None`, which the set also includes and which means "no entry at all" — handled by
  section 0's table rather than here. Match that set rather than inventing a stricter one.
- `allele_sessions_list` contains a session named `<CHILD> · <mode>` → do not dispatch.

**Dispatch a stack member only after its predecessor reports a pushed branch, by name.** A child
handed `Base branch: origin/fix/EX-528` for a branch that does not exist yet does not fail —
`implement.md` step 3 falls back to `the integration branch`, and you get a flat PR that looks fine and is
not in your stack. Nothing detects that until link time, by which point several branches are
wrong. And the branch name is not derivable: the convention is `<type>/<TICKET-ID>` and `<type>`
is the child's own call, so `fix/` and `refactor/` are both legal for the same ticket. Ask for
the name; do not guess it.

So a stack serialises its own dispatch, which is worth saying plainly because section 5's
capacity arithmetic otherwise reads as if it binds. On EX-525 peak concurrency is one code
child plus its reviewer, plus EX-527, plus you — four sessions against a cap of 35. Compute
the number anyway and put it in the plan comment; on this parent the answer is that capacity is
not the constraint, and saying so is more useful than a budget nobody needs.

Then, per child:

```
D ledger put <CHILD> mode=<mode> status=claimed title="…" url=… project=<project> \
  parent=<KEY> "why=child of <KEY>, dispatched by coordinator" --by coordinator
D label <CHILD> <working label> --state "In Progress" --by coordinator
D brief <CHILD>   →   allele_sessions_create(project, name: "<CHILD> · <mode>", prompt: <brief + appendix>)
allele_sessions_status(<session_id>)    # your requested name, dispatched: true, past provisioning
D ledger put <CHILD> session_id=… session_name=… reply_to=… status=active --by coordinator
```

`parent=<KEY>` is load-bearing — it is what section 0 queries. Set it on the `claimed` put,
before the create, so a coordinator that dies mid-create still leaves a findable child.

**Write it in the same `ledger put` as the claim, not in a later one.** `ledger_put` merges
under a lock now, so a concurrent write from the Dispatcher no longer discards your fields —
that was a real defect, demonstrated: unlocked, the whole of one writer's update vanished, and
a child left with `status=lost` and no `parent` is invisible to `ledger children`, invisible to
`SKILL.md`'s guard, and passes this section's own lock. The lock closes the interleaving; it
does not close the gap between two of *your* puts. One put, every field.

**Children never get a trigger label** — not `Agent - Todo`, and not `Agent - Investigate`,
`Agent - Decompose` or `Agent - Decide` either. Any of the four makes the Dispatcher's poller
see the child and dispatch it a second time, from depth 1, outside your control. `cmd_label`
will happily set one, so this is a rule about what you type, not a thing the tool prevents.
Straight to the working label. (For a `decide` child that working label is `investigating`;
there is no `deciding`.)

### The stale-state hazard, and the one line that defuses it

There is a race that puts a trigger label back on a child without anybody choosing to, and it
fires routinely rather than rarely.

`dispatcher.py`'s poller checks liveness against the same lagging `~/.allele/state.json`. Its
`liveness()` does `session = live.get(sid)` and, when that is `None`, emits **`session_lost`**
— and a child you dispatched seconds ago, whose `session_id` is already in the ledger with
status `active`, is `None` in a file that has not been written yet. `SKILL.md`'s handler for
`session_lost` on a Linear ticket is *put the trigger label back and re-queue*. The poller then
sees a trigger on a child and dispatches a second session onto it.

The staleness measured above — 22 and 40 minutes in two readings on the same day — is four to
eight times the 300-second poll interval, and unbounded as far as anyone here knows. This is not
a narrow window.

Two things defuse it, and you must do both:

1. **`parent=<KEY>` on the ledger entry, written before the create.** `SKILL.md`'s fan-out guard
   is keyed on the **presence of `parent`, whatever the entry's status** — deliberately, because a
   status-conditioned version fails open on exactly the states that produce a stray trigger:
   `discarded` and `lost` are both redispatchable and `done` is not a working status either, so a
   finished child re-labelled by hand would sail through. That guard is the thing standing between
   your children and a second session, and it can only see children you have written `parent` on.
   Write it before the create, not after.
2. **Say it in your plan comment and in your first message to the Dispatcher:** these children
   are yours, a `session_lost` on any of them comes to you, and no trigger label goes back on a
   child. Say it explicitly. The Dispatcher's `session_lost` handler is written for top-level
   tickets and re-labels by default; it needs to be told that these are not those.

### The appendix you add to every code child's brief

```
Base branch:  origin/<predecessor branch>   (or the integration branch at position 1)
PR base:      <predecessor branch>          (or dev at position 1)
Stack:        position N of M in the stack for <KEY>. Your coordinator owns the stack
              object; you own your branch and your PR. The ONLY `gh stack`
              subcommand you may run is `view`. Everything else is forbidden: your
              workspace has no stack state, so init/add/submit/sync/rebase/push/
              modify/checkout do the wrong thing quietly, and `unstack` "removes a
              stack locally AND on GitHub" — it would destroy the object every
              member's CI depends on. An allowlist, not a blocklist.
Open your PR AS A DRAFT and tell your coordinator. Do not `gh pr ready` until it
              tells you to. The ready is what fires CI, and CI is only correct once
              you are in the stack.
Branch check: THIS OVERRIDES `implement.md` step 3, which says an existing remote
              branch means "check it out and continue". As a stack member you must NOT.
              Check `D ledger get <CHILD>` history first and report to your coordinator.
              An existing branch is either your own earlier session or a collision, and
              continuing a collision loses one session's work with no error.
Concurrent:   <siblings running now>
api-types:    <one of: "you carry the single packages/api-types version bump and CHANGELOG
              entry for this stack" | "do NOT bump packages/api-types — the tip carries the
              single bump for this stack; say so in your PR description where your acceptance
              criteria ask for one" | omit this line entirely if the parent touches no
              published package>
Report to:    your coordinator (the reply address allele gave you), not the Dispatcher.
Depth:        you are at depth 2, so your reviewer is a leaf and cannot dispatch.
```

Non-code children get no branch lines. They get the acceptance criteria restated as the
output shape, and the instruction that a question only a person can answer leaves the process
(section 8). Add two lines to a `decide` child's brief:

```
Record on:    <the ticket each acceptance criterion names — often this parent, not your ticket>
Sign as you:  commenting on any ticket that is not your own, pass `--key <CHILD>` to
              `D comment`, or it signs with the OTHER ticket's marker and my watcher on that
              ticket skips your answers as its own.
```

---

## 7. Build the stack — you own the stack object, children own their PRs

This is the correction that matters most, and it is worth stating why before the mechanics.

**A base-chained PR made with `gh pr create --base` gets no CI.** `ci-coverage.yml` filters
`pull_request` on `branches: [dev, release/**]`, and that filter reads the **base** ref. PR
#102 has base `feature/unrelated-951` and `stackEntry: NONE`: no Test Coverage, no Architecture
Tests, no Backend Linting, no Frontend Vitest, no type check. `gh pr checks` exits 0 on it,
because the checks that would have failed were never created.

**A conflict anywhere below a child silently suppresses that child's CI.** This is the single
most important operational fact in this document, and an agent will read the result as success
unless it is looking for the right thing.

Stack #103 (`base=dev`, size 9), walked down the base chain:

| Position | PR | `mergeable` / `mergeStateStatus` | Test Coverage |
|---|---|---|---|
| 1 | #104 | `CONFLICTING` / `DIRTY` | yes (ran 10 Aug) |
| 2 | #105 | `MERGEABLE` / `BLOCKED` | yes (ran 10 Aug) |
| 3 | #106 | `CONFLICTING` / `DIRTY` | yes (ran 11 Aug) |
| 4–9 | #107 … #101 | `UNKNOWN` / `UNKNOWN` | **none, ever** |

GitHub cannot compute mergeability for positions 4 upward because the chain beneath them
conflicts, and the stack's own UI says so in as many words: conflicts must be resolved. PR
#101 is the case to keep in mind — `stackEntry` non-null, `stack.baseRefName == "dev"`, size 9,
open, **not** a draft, and **zero `pull_request`-event workflow runs in its entire history**.
`gh pr checks 9233` exits **0** with four rows, none of them a test.

So a conflict low in a stack is **not one child's problem**. It stalls CI for every member above
it, silently, and the members above look fine: correct position, correct stack base, green tick.
Treat a conflicting member as blocking the whole stack above that point — check
`mergeable`/`mergeStateStatus` on every member alongside the step-4 read-back, and if any member
is `CONFLICTING`, nothing above it is verified and nothing above it may be readied until it is
resolved.

**And never read absent checks as passing checks.** That is the rule that survives regardless of
mechanism, and it is why the named-check assertion below is the gate rather than a courtesy. A
PR with no CI and a PR with green CI are indistinguishable through `gh pr checks`' exit code.

### The rule, stated once

**A PR gets no CI while its merge state is conflicted or uncomputable.** In a stack that
propagates upward: a conflict below makes every member above it uncomputable, so they get
nothing either.

That is ordinary GitHub behaviour rather than anything stack-specific, and the stack only
changes how far the damage reaches. Everything else in this section follows from it.

Two other things suppress CI and are worth keeping distinct, because they have different fixes:

- **An unstacked PR with a non-`dev` base** — the `branches:` filter rejects it. PR #102:
  `stackEntry: null`, base `feature/unrelated-951`, `mergeable: MERGEABLE`, `mergeStateStatus: CLEAN`,
  and no Test Coverage. Its merge state is fine; it simply is not in a stack. Fixed by stacking
  it, not by resolving anything.
- **A draft** — six `draft == false` guards in `ci-coverage.yml`, and skipped jobs satisfy
  required checks by design. Fixed by readying it.

And the behaviour the whole design depends on is real: **a conflict-free stack based on `dev`
gets CI on every member**, on bases the branch filter excludes. Stack #108 (`base=dev`, size 5):
all five ran Test Coverage for 11-12 minutes, and #109's run is `event: pull_request`,
`head_branch: EX2-1609`, under a `branches:` list of `dev, release/**, staging, main` that does
not contain its base `EX2-1605`. The filter resolved against the stack's base.

### How to check this, and how not to

The table above is **consistent with** upward propagation and does not **prove** it, for a reason
worth internalising because it will bite anyone who tries to re-verify this:

> **Check-runs are historical. `mergeable` is a reading from now.**

Positions 1-3 are `CONFLICTING` today *and* have Test Coverage, which looks like a counterexample
and is not: #104's run started 2026-08-10T05:01:43Z, forty minutes after its last commit at
04:21:24Z, and #106's started two minutes after its own. Both ran promptly, in August, when
their chain was clean; the conflicts are a property of today. Equally, positions 1-3's coverage
predates position 4 existing at all (created 2026-08-20), so that table cannot demonstrate what
a conflict beneath them did to members that were not yet there.

So do not try to confirm this rule by comparing old check-runs against current mergeability in
either direction. The way to see it live is the one that matters operationally anyway: read
`mergeable` now, and read whether the named checks exist now.

### Which is why the gate is the named checks

The diagnostic is `mergeable`; the **gate** is the presence of the named checks. That split holds
under every hypothesis about mechanism, costs one command, and is the only thing that catches a
suppression this document has not anticipated. A PR with no CI and a PR with green CI are
indistinguishable through `gh pr checks`' exit code, so **never read absent checks as passing
checks.**

### A note on how this section was written, because it is the useful part

It took two corrections to get here and both are worth recording, because they are different
mistakes.

**First**, an earlier draft of this file called the behaviour "unreliable" and the difference
"unexplained", and proposed an experiment to settle it. That was reasoning from **absence of
evidence**: I had queried stack membership and check runs and never queried `mergeable`, so the
field that explains the variance was not in my data, and I recorded the resulting hole as a
property of GitHub rather than of my query. your principal opened the stack in the GitHub UI, which
states the conflict plainly, and corrected it in seconds.

Two further things about the second one, before it: **#102 was my own error and nothing
external caused it.** I documented its base-ref mechanism in this very section and then offered
the same PR, three paragraphs later, as a control for a question that mechanism already answered.
A narrowed premise explains the other control; it does not explain failing to read my own
paragraph. Of the two mistakes it is the more instructive, because there was nobody else in the
loop to blame it on.

**Second**, the correction was narrowed on its way to me — "CI never runs when there are merge
conflicts" was relayed as "CI does not run where merge state cannot be resolved", which points
only at `UNKNOWN`. Against that narrower claim, a PR reading `CONFLICTING` looked like a
counterexample, and I built a control out of one (#110) and a second out of a PR that was never
a stack member at all (#102, whose missing CI this same section already explains by the branch
filter). Neither was a control. Running them was still right — they are how the relay error
surfaced instead of being inherited — but the conclusion I drew from them was wrong.

Two lessons, and the second is the less obvious one. Before writing "unexplained", ask which
field you did not query. And when a correction arrives, check the controls **and** check that the
claim you are testing is the claim that was made — a narrowed premise manufactures contradictions
that were never there.

### `gh stack` across sessions: only `link` and `view`

`gh stack`'s local tracking state lives in one checkout. Every child has its own allele
workspace, so `init`, `add`, `submit`, `sync` and `rebase` **cannot** span them — a
coordinator reaching for `gh stack submit` is reaching for state that does not exist in its
workspace. The subcommand built for exactly this case is `gh stack link`, whose own help says
it "does not rely on gh-stack local tracking state" and is "designed for users who manage
branches with external tools". Confirm the surface yourself with `gh stack --help` rather than
trusting this paragraph; it was true for v0.1.0.

### The sequence, per stack member, in this order

1. The child branches from its predecessor's **pushed** branch, builds, pushes.
2. The child opens its PR **as a draft**, base = predecessor's branch, and reports the number.
3. **You** link it, from your own workspace:
   - the first two members: `gh stack link --base <integration> <PR1> <PR2>` (a stack needs two)
   - each one after: `gh stack link --base <integration> <stack-number> <PRn>` — appends to the top

   **Pass `--base` explicitly.** Its default is *the repository's default branch*, which may or
   may not be the branch you are stacking onto — so omitting it works by coincidence rather than
   intent, and step 4 then asserts a base you never asked for.

   **The stack number comes from step 4's read-back on the first pair.** A wrong number is not
   an error: `gh stack link --help` says a numeric first argument "is treated as a stack only
   when it matches an existing stack", so a stale number is read as a PR and silently creates a
   **second** stack.

   **Link in plan order, and hold a PR that arrives early.** `link` appends, so stack order is
   arrival order while yours is section 3d's. They coincide only if PRs arrive in plan order,
   and they will not: a large child spends ten minutes on its description while a three-line
   child opens immediately.
4. **You verify the link landed.** Do not assume it:
   ```
   gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){
     pullRequest(number:$n){ baseRefName stackEntry{ position stack{ number size baseRefName }}}}}' \
     -F o=<OWNER> -F r=<REPO> -F n=<PRn>
   ```
   `stackEntry` must be non-null, `stack.baseRefName` must be `dev`, `stack.size` must be the
   number of members you have linked, and `position` must be what you planned. Assert `size` —
   without it a member silently dropped is invisible.

   **Query `mergeable` and `mergeStateStatus` in the same call, for every member.** They are the
   fields that explain whether CI can run at all, and omitting them is how an earlier draft of
   this document came to record a solved problem as an anomaly:

   ```
   gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){
     pullRequest(number:$n){ baseRefName mergeable mergeStateStatus isDraft
       stackEntry{ position stack{ number size baseRefName }}}}}' \
     -F o=<OWNER> -F r=<REPO> -F n=<PRn>
   ```

   `CONFLICTING` on any member → **stop.** That member's conflict blocks CI for everything above
   it. Tell the child to resolve it, and ready nothing above it until `mergeable` recomputes.
   `UNKNOWN` on a member whose chain is clean is GitHub computing lazily; `UNKNOWN` on a member
   with a conflict beneath it is the suppression above, and the way to tell them apart is to walk
   the chain down and look for the first `CONFLICTING`. `stackEntry: NONE` means the link did not land and this PR will get no
   CI. `gh stack view --json` is the friendlier read; the GraphQL is the one that shows you
   the base, which is the field that decides whether CI runs.
5. **Only then** tell the child to `gh pr ready`. `ready_for_review` is in `ci-coverage.yml`'s
   `types:` list, so the ready fires CI with the stack already in place. This is why the PR
   opens as a draft: it makes the state transition and the CI trigger the same event, and it
   means you never depend on the unverified question in the caveat above.
6. The child's PR going non-draft is what moves its ticket to **In Review** (section 9).

### The gate: "CI green" means these checks, present by name

`gh pr checks <n>` exiting 0 is not evidence of anything and you must never accept it as such.
On PR #102 it exits **0** with nine passing contexts — `dismiss-stale-approvals`, `gate`,
`Eject on push`, `Greptile Review`, `Advance the queue`, `update-linear-status`,
`approval-freshness` — and not one of them ran a test. The suite was never created, so there
was nothing to fail. A draft does the same thing for a different reason: its jobs report
`skipped`, which satisfies required checks by design.

So assert the **names**, present and successful, on every code child before you call it done:

```
gh pr checks <n> --json name,state \
  --jq '[.[]|select(.name|test("Test Coverage|Backend Linting|Architecture Tests|Frontend Vitest|Regenerate Types"))]
        | if length < 5 then "MISSING: only \(length) of 5 substantive checks exist" 
          else (map(select(.state!="SUCCESS"))|if length==0 then "ok" else "FAILING: \(.)" end) end'
```

`MISSING` is the answer that matters, and per the section above it is a **live** outcome on a
correctly-shaped stack, not a theoretical one. It means the PR is unstacked, or draft, or based on
something the workflow filter does not match — the three failures this whole section exists to
prevent, and the three that a green tick hides. Put the output in your closing comment rather
than the word "green", and say the same thing in the child's appendix so it does not report a
false green to you in the first place.

### The invariant that keeps a held child from becoming a permanent one

**A stack you close on must contain no drafts.** This is not style; it is the difference
between a stack that can merge and one that silently cannot.

`docs/ci/merge-queue.md` is explicit about what a draft member does: *"A member is a draft, or
unapproved → **Waits.** Not queued yet; keeps its position. **No comment, no label change**."*
So a stack with one permanently-draft member, labelled on the tip by a human, sits in the queue
forever, says nothing, changes nothing, and looks exactly like a stack that is merging slowly.
Worse, a PR that never leaves draft never fires `ready_for_review`, so by section 7's own
argument it never gets CI — and every member above it is stacked on an untested base.

Draft is therefore a **transient** state — the few minutes between opening a PR and being told
to ready it (7.2 → 7.5) — and never a holding state. Section 3d already keeps a gated child out
of the stack for this reason. What is left for close time is the check:

| At close time, a member is | Then |
|---|---|
| open, linked, not a draft, named checks green | normal `done` |
| still a draft for any reason | **it is not a member.** Unlink it, mark the child `deferred` |

Unlinking means relinking the stack without it (`gh stack link --base dev` with the remaining
members in plan order) and saying in the closing comment what it is waiting for and who holds
the answer. If removing it would orphan members above it — because they genuinely depend on its
code — then the stack is not ready and **the parent does not close**: Needs Input, naming the
gate and the person. A truncated honest stack beats a complete one with a hole in it.

That is the honest accounting. A gate that never lifts is not a child that is nearly done; it is
work that is blocked, and the closing comment has to say so rather than leaving a draft in a
queue nobody is watching.

### The predecessor moves under you, and nothing in GitHub notices

This is the failure most likely to actually happen, because it is produced by the protocol
working normally rather than by anything going wrong.

Member N+1 branches from member N's **pushed** branch — that is the whole benefit in 3c. Then
member N runs the rest of `implement.md`: a blind review, fixes for its blockers, more pushes.
Those commits land on branch N *after* branch N+1 forked from it. The stack is no longer linear,
and `merge-queue.md`'s justification for verifying only the tip — *"the tip's tree already
contains every member's changes"* — stops being true. The queue verifies a tree that is missing
member N's review fixes, and every check reports green, because each PR's CI ran on its own
branch and each branch is individually fine.

Section 7.4 does not catch it: `stackEntry`, `position`, `size` and `baseRefName` describe the
stack's *shape*, and the shape is perfect. Nothing in `dispatcher.py` reads a PR's base ref at
all, and `Watcher.pull_request` tracks only the PR's own head — so there is no event anywhere in
this system for "your base moved".

**Check the commit graph, not the shape.** For every member from position 2 upward, alongside
step 4:

```
git fetch origin
git merge-base --is-ancestor <PR(n-1) headRefOid> <PR(n) headRefOid> && echo "fresh" || echo "STALE"
```

`gh stack view --short` says the same thing more readably — it marks a member `⚠ Needs rebase` —
but it needs local stack state, so `gh stack checkout <stack-number>` first.

**And name who fixes it, because by default nobody can.** Section 7 keeps children out of
`gh stack`, and `gh stack sync`/`rebase` from your workspace would force-push branches out from
under live child sessions. So the rebase is the **child's**, on its own branch, on your
instruction: tell member N+1 to `git fetch origin && git rebase origin/<branch N>` and
force-push with `--force-with-lease`. Then re-run the ancestry check and cascade upward, lowest
first. Do this before you ready anything, and once more before you close. It is also the cheapest
conflict prevention you have: a member rebased onto its predecessor's current head is a member
that cannot go `CONFLICTING` against it, and a conflict low in the stack costs every member
above it its CI.

The stack object is a new single point of failure — it is one API object, owned by you, that
five PRs' CI depends on. Step 4 exists because of that. Re-read the stack after every link,
and once more before you close, so a stack that was silently dissolved is something you find
rather than something your principal finds.

### Merging is not yours

Nothing in this process merges anything, and there is no merge order to plan.

`docs/ci/merge-queue.md` (EX-359) is the authority and you should read it before you touch a
stack. Three things from it bind you:

- **The synchronous merge endpoint refuses stack members categorically** — not "fails a rule",
  refuses before evaluating anything.
- **Merging bottom-up destroys the stack's approvals, one level at a time.** The previous
  version of this document instructed exactly that. It is the failure that document exists to
  prevent.
- **The queue resolves the stack via the `stack`/`stackEntry` GraphQL fields and merges it
  atomically from the tip.** One place in the FIFO, one verification, one landing.

A stack enters the queue when a human applies `auto:merge` **to the tip**. Labelling any other
member gets it removed with a comment telling them to label the tip instead.

**You never apply `auto:merge`.** That label merges code without asking anyone. It is
your principal's, and applying it is the act that ends the review — which is the thing your finish
line stops short of by design.

---

## 8. Watch, and hold what should be held

A child reporting **needs-input** does not stop the rest of the work. Keep everything not
behind that gate moving.

**You never answer a business question on a child's behalf.** Relay it to the Dispatcher with
the child key and the question in one line.

There is a line worth drawing precisely, because EX-527 has both kinds in one ticket:

- **A question with a checkable answer in a system somebody can read is work, not a gate.**
  EX-527's Q4 — the production value of `APPLY_ADJUSTMENT_EFFECTS` — is one command against
  the running task definition. A `decide` child answers it.
- **A question whose system exists but was refused to one session is a permission defect, not a
  human question.** This is the branch most likely to be got wrong, and getting it wrong converts
  cheap questions into unbounded ones.

  EX-525's decomposition comment records *"The three verification queries in the comments above
  were **not** run: production reads were blocked in this session."* That reads like a fact about
  the world and is a fact about **one session's permissions**. A read-only the production MCP MCP exists —
  tunnelled, read-only enforced beneath the privilege system, 500-row default, 60s statement
  timeout — and EX-527's Q2 was answered through it in about 400ms: `myob_adjustments` 3,736 rows
  all `RECEIVED` and none `PROCESSED`, 2,980 `DEBIT` and 756 `CREDIT`, and **zero** fundings with a
  non-zero `adjustment_amount`. What blocked five worker sessions was each session's permission
  classifier refusing the call.

  So the three states are distinct and the action differs:

  | State | What it is | Do |
  |---|---|---|
  | the tool is in your toolset | work | answer it |
  | the tool exists on the machine, your session was refused | a **permission defect** | report the denial and ask for the rule. The question stays open and stays *cheap* — do not reclassify it |
  | no such capability exists anywhere | genuinely held by a person | escalate it |

  Collapsing the middle row into the third is the expensive mistake: it turns a 400ms query into
  a wait on somebody's inbox. "I could not read production" is not an answer until you have
  established **which** of those three it was.
- **A question whose answer is a preference, a policy, or a fact only a person holds is a
  business question.** EX-527's Q1 (does the finance team use the page) and Q3 (drop the stored-events
  table or keep it as an archive) leave the process. Nobody here answers them.

Getting this backwards in either direction is expensive: treating work as a gate stalls the
stack waiting for a human who has nothing to add, and treating a business question as work
gets an agent guessing at something a customer or a supplier would notice.

**Watch for the answer, and pass `--as`.** Run `D watch <KEY> --as coordinator` on the parent as
a persistent Monitor, and the same on any ticket you are holding work behind — the answer often
lands on the gating child rather than the parent, and if that child is not yet dispatched,
nobody else is looking at it. On EX-525 that is a watch on EX-525 and one on EX-527.

**`--as` is not decoration.** A watcher keeps one state file per ticket and `issue()` advances
`comments_since` past every comment it emits, so two readers of one ticket share one cursor
unless they are told apart. You and the resolver both watch EX-527 — `_common.md` step 3 makes
every child watch its own ticket — and the comment you would collide over is the answer the
whole stack is held behind. `--as <name>` gives this watcher its own file,
`<key>.<name>.json`. A `dispatcher.py` that predates the flag answers
`unrecognized arguments: --as`; drop it, and lean harder on the relay below.

**When the answer arrives, relay it to the held child anyway. Do not just restore its label.**
Separate cursors stop you *consuming* the child's comment; they do not make the child read it
sooner, and on a decision child that child is the only session that records answers on the
ticket. So: SendMessage the child the answer text itself, then restore its label. One extra
message costs nothing and removes a coin-flip from the critical path.

### Child outcomes — all of them

| Outcome | Terminal | Do |
|---|---|---|
| `done` | yes | verify the artefact, then start what it unblocks |
| `merged` | yes | note it; the queue did this, not you |
| `failed` | yes | halt everything above it, **unlink it from the stack**, and report. A member whose base never landed must not be built on — and once the tip is labelled you have no way to remove it, so unlink before you close |
| `discarded` | yes | your principal let it go. Record why, and decide whether the work is still needed |
| `stopped` | yes | it was told to stop. Report and wait — **unless** it is the Done echo below, which is not a new event |
| `deferred` | yes | it cannot start until something that happens **after** your finish line. Hand it back; do not wait (below) |
| `needs-input` | no | relay; keep the rest moving. **At close time it converts** — see below |
| silent | no | **not an outcome.** `allele_sessions_status` distinguishes `response_ready` from `awaiting_input`; silence is one of those two, never `done` |

**A `stopped` that lands right after a `done` on the same key is an echo, not a new event.**
The watcher emits `stop` when a ticket reaches a terminal workflow state, and `_common.md` tells
a worker receiving `stop` to write `status=stopped`. So moving a finished child's ticket to Done,
while its session is still alive with its watcher running, used to **overwrite the `done` you
just verified** — and this section's `stopped` row says "report and wait", which is an
instruction to wait arriving at the exact moment you are trying to close.

`Watcher.issue` now suppresses that: a ticket moving to a **completed** state while the ledger
already reads `done` or `merged` emits `state_changed` instead of `stop`. Two things still apply:

- **`canceled` is deliberately not covered.** Cancelling a ticket is an abandon instruction
  whatever the ledger says, so it still fires `stop` at a `done` child — correctly. If you see
  that, the ticket was cancelled, not completed, and it is a real event.
- **Order it anyway.** Let the child set its own Done where its brief already does
  (`decide.md` step 6, `implement.md` step 8). Do not move a child's ticket to a completed state
  yourself while its session is alive — the suppression depends on the ledger having been
  written first, and you do not control the order in which a live child writes it.

**Read it correctly if it happens anyway.** A `stopped` whose ledger history shows a `done`
immediately before it, with no intervening instruction to stop, is the Done transition echoing
back — an older `dispatcher.py`, or a cancel. Treat it as `done`, say so in the closing comment,
and do not wait on it.

**`deferred` is not failure, and not waiting.** A child whose gate is a merge, a deploy, or a
release cannot be reached from inside a run whose finish line is *in review*. Waiting for it
would mean waiting for a merge, which is the thing this protocol deliberately does not do. So:
do not dispatch it, mark it `deferred`, and in your closing comment say what has to happen and
what re-triggers it.

**Be honest about how weak `deferred` is, because the closing comment is the only thing holding
it.** `deferred` is in none of `dispatcher.py`'s status sets — not `WORKING`, not `ALIVE`, not
`REDISPATCHABLE` — and both `D status` and `D ledger list` filter on `ALIVE | {"queued"}`, so a
deferred child **disappears from every listing** the moment you write it. Nothing watches for
"EX-531 deployed". The poller watches Linear labels and GitHub review requests, not deploys.
The mechanism is your principal reading your comment and remembering. Write it so that it survives
being read once, weeks later: the ticket, the trigger, the thing to wait for.

**And the re-trigger is the label section 6 forbids — deliberately.** Restarting a deferred
child means `Agent - Todo` on it, and section 6 says children never get a Todo. Both are right,
because the rule's reason is *"outside your control"*: while you own a child, a Todo produces a
second session you cannot see. Once you have closed, nobody owns it, and the poller picking it
up from depth 1 is exactly the correct outcome. Say this explicitly in the closing comment —
"EX-532 takes an `Agent - Todo` once EX-531 has deployed" — because the next reader will
otherwise find the two rules and believe one of them is a mistake.

On EX-525 that is EX-532: it needs EX-531 merged **and deployed**, and EX-531 is still in
review when you finish. A coordinator that dispatches EX-532 anyway gets a session that drops
production tables against live code.

**A gate that has not lifted by close time becomes `deferred`, with a name on it.** `deferred`
was introduced for gates that resolve *after* your finish line; a gate that may never resolve
*at all* needs the same exit, or the parent blocks indefinitely on somebody's inbox. EX-527's
Q1 and Q3 are exactly this: a the finance team preference and a team preference, with no timeout, no
escalation ladder and no agent permitted to answer either.

So at close: any child still `needs-input` becomes `deferred`, and the closing comment names
**the question, the person who holds it, and what it is blocking.** That is not declaring
victory over unfinished work — it is the difference between "blocked on your principal" written down
and "blocked on your principal" left as a session quietly waiting where nobody will look.

**Verify the artefact, not the status.** A code child is finished when its PR exists, is
linked into the stack, is not a draft and CI is green — not when its ledger says `done`. A
decision child is finished when every one of its acceptance criteria has a recorded answer —
not when a session reports done with two of four answered. **Read the criteria for where each
answer is meant to land, and look there.** Six of EX-527's seven criteria record their answers
on **EX-525** and one on **EX-529**; a coordinator that checks EX-527 itself finds an empty
ticket even when the child did everything right, marks it unfinished, and holds EX-532 behind a
gate that has already lifted. And EX-527's last criterion — *"A dump of the three tables is
taken if any drop is agreed"* — is an **action**, not an answer, and a read-only decision child
cannot produce one. A criterion the child cannot satisfy by design is a gate on a person, not an
incomplete child. This is the same discipline as the coverage check and it fails the same way if
you skip it.

Discarding a finished child session is your principal's call. List them for the Dispatcher.

---

## 9. States, exactly

| When | Ticket state |
|---|---|
| the agent starts implementing | **In Progress** |
| its PR is open and **not a draft** | **In Review** |
| merged | **Done** — and that is a human act outside this process |

Nothing in CI moves a ticket to Done on merge; the only Linear automation in this repo fires
on branch creation and only sets In Progress. So Done stays a deliberate act, and it is not
yours.

For a non-code child there is no PR, so In Review has no meaning: In Progress → Done when its
recorded artefact exists and you have read it. *(That transition is not in your principal's three; it
is the obvious extension and it is marked as an inference rather than a rule.)*

---

## 10. Close — say what is true

Close when **every child has reached a terminal outcome**, not when every child says `done`.
`done`, `merged`, `failed`, `discarded`, `stopped` and `deferred` are all terminal. The old
version could only close on all-`done`, so one discarded child deadlocked it forever — and a
`deferred` child would have deadlocked it permanently, since nothing it can do would ever move
one to `done`.

Before closing:

1. **Re-run the coverage check against what actually shipped**, not what was planned. Children
   drift; a child that descoped something moves that work back into the gap column. Run it
   both directions again — the backward direction is cheap the second time and it is where a
   descope shows up.
2. **Re-read the stack** (step 7.4). A stack silently dissolved between the last link and now
   means members are sitting without CI — and **a dissolved stack stops the close**, exactly as
   a failed coverage re-check does. Relink it and re-verify; if it will not relink, Needs Input
   naming the members and their bases. Do not close reporting a stack number that no longer
   resolves: it is a check that terminates in nothing, which is the same defect as a rule whose
   detector cannot see.
3. Account for every non-`done` terminal outcome by name. A discarded or failed child is not
   an absence; it is a decision someone has to see, and a `deferred` child is work that is
   still owed — say what it is waiting for and what re-triggers it.

Then one comment on the parent:

- every child, its PR link, its position in the stack, its state
- the stack number, its base, and its size
- **`mergeable` for every member**, because a `CONFLICTING` member means nothing above it has
  been tested no matter how green the ticks look
- **what you verified** — the named checks present and passing on which PRs, self-reviews posted, the blind coverage
  review's verdict, the stack read back from GitHub
- **what you did not verify, and why.** Say it plainly. Nothing has merged and nothing has
  deployed, so any parent criterion that can only be checked after a deploy is **unverified**.
  On EX-525 that includes "the results match production today" and "Budget panel renders
  unchanged". Listing them is the honest version of a coverage claim
- which child carries the single `packages/api-types` bump, if the parent has one
- that the stack enters the queue by `auto:merge` **on the tip**, applied by a human — and
  **"do not label the tip" in bold if any member is failed, discarded or unlinked**, because a
  stack merge lands every member from the tip down
- **that any push to any member ejects the whole stack from the queue, and that the ejection is
  invisible to every session here.** The children stay alive after you close and their briefs
  tell them to push fixes in response to review comments — which is correct behaviour that
  ejects the stack. The queue's eject comment is posted by its GitHub App, and `config.json`
  sets `"ignore_bots": true`, so no watcher sees it. Re-entry needs a fresh `auto:merge` on the
  tip. your principal is the only one who can notice, so the closing comment is where he finds out

Then `D label <KEY> done --state "In Review"` → `D ledger put <KEY> status=done` → message the
Dispatcher.

**`--state "In Review"` is correct and `status=done` means only that your pass is finished.**
The parent is in review because the stack is in review. It is not verified, and the closing
comment must not say it is — the previous version closed the parent on a ledger status meaning
"PR open" while also claiming the parent was verified against its acceptance criteria, which
was two claims where there was evidence for one.

If the coverage re-check fails, the parent does **not** close. Needs Input, naming the gap.

---

## A limit on the evidence in this file

Every worked example here is EX-525. That is deliberate — a rule tested against nothing is a
guess — but it has a cost worth stating plainly: **EX-525 is the one parent on which a reader
cannot tell "the rules produced this" from "the author produced this and then wrote rules around
it".**

That is not hypothetical. A blind execution of section 3 against EX-525, run without being told
what answer to expect, derived a different linearisation from the one this file used to print, and
was right — see 3d. It surfaced because the runner derived first and compared second. Everything
else in section 3 it reproduced.

Two consequences. **When a worked answer and the rule beside it disagree, trust the rule** and say
so. And **the next validation should be run against a parent this document has never seen**, by
someone who has not read its worked examples. One blind run found fourteen places where a careful
reader had to supply a missing half; a second parent will find a different fourteen.

## What this file replaced, and what it needs installed

`implement.md` step 0 and `SKILL.md` both route here. The file they used to name, `stack.md`,
is now a **signpost** pointing at this one. It carried the finish line this document exists to
replace — *"every child done, and the parent verified against its own acceptance criteria"* —
which is exactly the claim section 10 stops you making.

It was nearly deleted instead, and the reason it was not is worth a line, because deletion is
the obvious move: `update_content.rs` never removes files from `~/.locus/`, so deleting it here
would have removed it from no machine that had already installed it — leaving a full copy of the
superseded protocol in the directory you are reading, invisible to `git grep`. A signpost gets
overwritten by the same sync that would have left a deletion unapplied. `stack.md` says the rest.

Five things had to exist before any of this was executable, and all five ship with it:

| Needed by | What |
|---|---|
| §0 | `D ledger children <KEY>` — the only reader of the `parent` field the protocol writes |
| §3e | `traits.decide`, `linear.modes.decide`, and an `Agent - Decide` trigger label |
| §3d-ii | an `Agent - Blocked` label, and `blocked` inside `dispatcher.py`'s `WORKING` set |
| §8 | `D watch --as <name>`, so you and a resolver do not share one comment cursor |
| §8 | `stop` suppressed at a ticket whose ledger already reads `done` |

An instance whose `config.json` predates them has nine labels and no `decide`. That is a
reconcile, not a missing feature: re-run `dispatcher.py init --instance <slug> --team-key KEY`.

## If you die

Your children keep running. Their ledger entries carry `parent=<KEY>`, which section 0 queries
by that field, and your plan comment is on the parent. Those two things are the recovery
record — which is why the plan goes up before the first dispatch and `parent=` goes in on the
`claimed` put. They are not bookkeeping.
