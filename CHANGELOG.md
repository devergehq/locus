# Changelog

All notable changes to Locus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Locus uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — on a pre-1.0 line,
which puts breaking changes in the MINOR position.

`Cargo.toml`'s `[workspace.package]` version is the source of truth. A release
tag must equal that version with a leading `v`; `.github/workflows/release.yml`
refuses to build when they disagree.

## [Unreleased]

### Fixed

- **Worker briefs no longer trip the `reasoning_extraction` refusal.** v0.5.3 fixed the
  Algorithm, but dispatched workers on Opus 5.5 were still refused: DAR-603, 557, 563 and 555
  (`req_011CfLJyhfDxQxHrAdS8LySX`, `req_011CfLK6z3AkuqFgKhCb7PPQ`,
  `req_011CfLK34vzSfN6hABdTEVTb`, `req_011CfLKAfHQb85fpSgaUrjoJ`), two of them before the
  Algorithm skill loaded. Probing on fresh 5.5 sessions found the trigger is cumulative and
  random: `_common.md` and `implement.md` read together were refused 7 times in 8, and each
  alone was clear. The worker briefs and `traits.yaml` now describe the work, its evidence and
  its decisions rather than the agent's own thinking. The self-review asks for a `Checked, not
  flagged` list, and working notes hold "the supporting detail". Measured on 5.5, the reworded
  pair had 0 refusals in 8 against 2 in 2 for the old pair run alongside it. One of the 8 was
  stopped once and recovered on the retry, so the risk is reduced, not gone. Only wording
  changed.
- **The Algorithm's wording no longer trips the `reasoning_extraction` refusal.**
  Workers on Opus 5 and Opus 5.5 were refused under that category, and the API said
  the request looked like "reverse engineering or duplicating model outputs"
  (`req_011CfKGP9yoALfXSqKZc4Nfo`, Opus 5.5, straight after loading
  `locus:locus-algorithm`; `req_011CfJgWvma2ep2Za2j1TyCx`, Opus 5). The OBSERVE
  output called "reverse engineering" is now **request analysis** (`REQUEST
  ANALYSIS:`) in `algorithm/v2.0.md`, the generated skill, and the OpenCode
  CLAUDE.md template. Output Requirements now ask for a record of the work in the
  response: the phase, what it found, what was decided, the evidence and the next
  step. The old text asked for a "visible response" so the user could "trace how the
  work moved". "One-sentence reasoning" is now "rationale", and "intermediate
  reasoning" (when not to dispatch) is now "intermediate steps", in the spec and in
  `protocols/orchestration.md`. Only wording changed. Phases, ISC floors, effort
  tiers and the classification check are the same. v0.5.1 (#50) reworded some of
  this already, and that wasn't enough.
- **`review_lint.py` lints a principal's review.** It found reviews only by the
  `agent:<KEY>/<mode>` marker, which a review posted as the principal carries by
  design. On the reviews posted most it printed "no agent review found" and checked
  nothing. With no marked review it now lints your latest review. `--review-id ID`
  lints exactly one, whoever posted it. Only the agent header and marker checks are
  skipped, and the first line names the review that was read. Nothing to lint now
  exits 2 rather than 1. `scripts/test-review-lint.sh` covers this against a fake `gh`.

### Changed

- **`review-craft` fits GitHub's column.** A body renders about 760px wide, and a
  table that can't fit breaks its words between letters. `house-style.md` gains "Fit
  GitHub's column": cells hold short scannable things only, and a finding that needs
  prose becomes a section with its diagram beneath it. `review_lint.py` fails a table
  cell over 140 characters or an unbroken token over 40 (`layout.table_prose`,
  `layout.table_tokens`), budgets each body section as a thread, and warns on a body
  diagram that is not under a finding or Problem fit (`layout.diagram_homed`).
- **`review-craft` draws workflow findings.** Where a finding — or the Problem-fit
  paragraph — describes a sequence, a state machine, a before/after ordering, a
  transaction boundary or a branching failure, a small mermaid flowchart goes directly
  beneath its prose, which points at it. Supplement, never replace; one per workflow
  finding; a single predicate gets none; any `classDef` with a `fill:` also sets
  `color:` so it reads in GitHub's dark theme. This replaces a cap of one diagram per
  review. `review_lint.py` no longer counts mermaid source against a thread's or the
  body's prose budget, and no longer fails a PR description for carrying a diagram.
  `pr_lint.py` is unchanged: in a body the fence is raw characters in the squash commit.
- **`review_lint.py` no longer checks the PR description.** Its `description.no_html`
  check failed any description containing `<details>`, which `house-style.md` has
  permitted since 18 September — so a review of a well-formed PR could fail on text the
  reviewer never wrote. Descriptions belong to `pr_lint.py`, which already budgets folds.
- **Dispatcher workers use allele for helpers and wait for a slot, never falling back
  on their own.** The "Independent help" rule in `skills/dispatcher/workers/_common.md`
  now makes `allele_sessions_create` the helper vehicle with no hedge. What happens next
  depends on the response:
  - A capacity error means wait and retry. The worker tells the Dispatcher it is waiting
    and quotes allele's error.
  - A depth error is reported and the worker carries on without the helper.
  - OpenCode is used only when the principal asks for it.

  The session cap is still mentioned, but now only as the reason to discard a helper
  promptly. `stack.v2.md` §3 matches: a coordinator whose blind reviewer hits a capacity
  refusal waits for a slot instead of posting its plan unreviewed. This lines the briefs
  up with the Algorithm's "Busy is not absent". On 2026-09-21 four review workers had read
  the cap warning as permission to send their blind reviewer to OpenCode "to spare a
  slot" while allele had room.

## [0.5.0] — 2026-09-20

`review-craft` stops carrying one repository in its head, and starts respecting the
template a repository already has.

### Added

- **Template fidelity.** `pr_lint.py` finds a repository's PR templates and reports
  which one a description is closest to and which of its headings are missing. The
  severity follows **the strength of the claim, not anyone's house policy**: a template
  **supplied** by the caller (`--template PATH`, a file or a directory) is an assertion
  that this is the shape here, so drift from it is an `ERROR`; one **discovered** by
  walking conventional paths is an inference, so drift is a `WARN`; and a repository
  with **no** templates produces no finding whatsoever. `--require-template` and
  `--template-advisory` move the line either way. Discovery looks past GitHub's three
  auto-fill paths, because a repository that wants a new PR body to arrive empty has to
  keep its templates somewhere GitHub does not recognise — and those are exactly the
  repositories with a considered convention. Extra headings are never a fault: a
  template is a floor, not a cage.
- **Caller-supplied exempt sections.** `--exempt-section NAME` (repeatable) adds to the
  default exemption list, `--no-default-exempt` replaces it, `--exempt-cap N` moves the
  per-section ceiling. The default list is the intersection of what templates commonly
  ask for and is explicitly not a closed set; the agent drafting a description is the one
  that knows which of its template's sections are fixed overhead, so it is the one that
  should say.

### Changed

- **The budget charges the narrative, not the references.** Sections matching `Related`,
  `References`, `Links`, `Security impact`, `Security`, `Deployment` and `Rollback` are
  no longer counted, up to **750 raw characters each**. Two reference links are ~145 raw
  characters before a word of prose — 18% of an 800-character floor — and the same count
  fell on the security sentence and the rollback line somebody reads during an incident.
  Shaving those to reach a character count was the rule doing harm. The cap keeps the
  exemption honest: past it a section is charged again, so `## Related` cannot quietly
  become the new body. 750 is p90 of 226 such sections measured across 99 live PR bodies
  (p50 263, p75 473, p90 728, p95 1,018, max 1,634).
- **The budget's `ERROR` threshold moved from 1.25× to 2×**, and is now stated in the
  prose instead of living only in the source. The budget is a *target*: get close to it,
  do not shave a path, a count or a date to get under it. 1.25× put a red check below the
  level practitioners call acceptable — a 1,200-character body for a small diff is 1.5×,
  and a 5,000-character description that earned its place is 1.25× of the ceiling. Both
  were failing. **The formula, the three constants and the raw-character unit are
  unchanged**; only the point where the tool stops advising and starts blocking has moved.
  The warning band now says a named specific outranks the budget, which the guidance
  claimed and the tool had no way to express.
- **Both loosenings were verified together, not separately.** Against the twelve-PR
  census that forced the budget, under the worst case — every PR claiming four exempt
  sections at the full cap, 3,000 characters free — **all twelve are still `ERROR`, the
  closest at 2.4×** against a 2.0× threshold. Checking them one at a time would have
  shown two comfortable margins and hidden the real one.
- **`review-craft` is de-identified.** `house-style.md` had been written against a single
  named repository: its PRs linked by number, its domain vocabulary in the worked
  description, its ticket keys, and in one place its internal governance record used to
  justify a default severity. **A skill that installs anywhere must carry no repository in
  its head**, and a default argued from one repository's policy is that repository leaking
  into everyone else's tooling. Every measurement, date and method is unchanged and still
  checkable; the provenance is gone. Census PRs are labelled A–L, the population is
  described rather than named, and the worked description's domain is invented on the same
  principle `examples/` already used. The standing rule is recorded in the file: if it
  names somebody's repository, ticket system or internal policy, it does not belong there.

### Fixed

- `--exempt-section` values are now folded the same way headings are, so `on-call runbook`
  matches a heading of `On-call runbook`. Without it the flag silently matched nothing.
- `pr_lint.py` no longer exits 2 when probing a template path that does not exist. Template
  discovery deliberately looks at paths that are absent in most repositories; treating the
  first miss as a failure made the linter unrunnable anywhere but the repository it was
  written in.

## [0.4.0] — 2026-09-20

`review-craft` takes back PR descriptions, and gives the working somewhere to go.

### Changed

- **`review-craft` now governs PR descriptions**, which it previously ruled out of
  scope. It did so on two reasons. The first was sound: a description is a durable
  record and must not inherit the 150-word review budget. The second was **false** —
  it said a description "cannot collapse anything". GitHub renders
  `<details><summary>` in PR bodies and in every kind of comment; the probe is
  recorded and dated in `house-style.md`. The false reason ruled out the one
  mechanism that reconciles *complete* with *short*, so "never budget a durable
  record" was left to carry the argument alone and was read as "length does not
  matter". By 18 September that had produced eleven agent-authored PRs on one repo
  carrying 9,000–39,000 character descriptions with zero folds — 307,000 characters
  across twelve commits, in a repo that squash-merges with `PR_BODY` as the commit
  message. The worst was 17,638 characters for 50 changed lines, one of them
  application code. A human reviewer flagged it; nothing in the skill would have.
  What replaces it: **the description is the record of the decision** (why, what
  changed in shape, what to look at, risks, references) and is budgeted at
  `min(4000, max(800, 12 × changed lines))` **raw** characters of the body as stored,
  excluding the Claude Code attribution footer — raw, because the squash copies the
  body verbatim and because that is the unit the three constants were measured in; **the working — the
  evidence, the queries and their output, the method, the alternatives rejected —
  moves whole and verbatim into a PR comment headed `## Working notes`**, which the
  description links to in one line. The comment is identified by that heading and
  never by its position — the working is moved out late, so it is the newest
  comment on the PR, not the first. Nothing is deleted; it moves. The three
  constants are measured, not chosen: slope 12 from the 10.6-character median across
  45 recent human-authored PRs, ceiling 4,000 from the p89 of 5,557 PR bodies, floor
  800 from just above the p25.
- **`issue-craft` corrected** in the same place. Its "why a ticket is not a review"
  section repeated the false no-folds claim as part of the paraphrase scar. The scar
  and its rule stand — *budget artefacts consumed in a feed; never budget a durable
  record* — with a dated correction explaining that the scar's real lesson was that
  the detail had nowhere to go, and that a budget with a destination is a move while
  a budget without one is a paraphrase machine.

### Added

- **`skills/review-craft/pr_lint.py`**, the description linter, beside `review_lint.py`.
  Takes `--repo OWNER/REPO --pr N` (via `gh`) or a local draft with an explicit
  `--changed-lines`; it will not guess a diff size, because a budget checked against a
  guessed denominator reports PASS about nothing. Checks the visible body against the
  budget for that diff, a long body with no headings, unfilled template placeholders,
  rotting relative-date words, oversized `<details>` in a body a squash will copy raw,
  and — when the body links to working notes — that a comment carrying that heading
  exists on the PR. Mechanics only, like `issue_lint.py`; exit 0 pass, 1 errors, 2
  could not run.
- **`scripts/test-pr-lint.sh`**, 37 cases in the form `scripts/test-plugin-hooks.sh`
  already uses.

### Changed (instructions)

- `skills/review-craft/SKILL.md`, `skills/dispatcher/workers/implement.md` (step 5),
  `skills/dispatcher/workers/review.md` (new step 4b) and `agents/engineer.md` now
  describe the record/working split and require `pr_lint.py` to pass before a PR is
  called ready. Stack children inherit it through `implement.md`.

## [0.3.4] — 2026-09-16

`issue-craft` realigned after one day in use: structure replaces the word budget.

### Changed

- **`issue-craft` realigned** after one day in use (DEV-681). The 15 September version budgeted
  the opening at about 80 words and said everything below it was folded. Within a
  day it had produced tickets with no headings, the acceptance criteria and the
  out-of-scope section collapsed, and the one open question written as the last
  sentence of a paragraph (observed on a live ticket, where the reader opened every fold looking for
  the action item and found it on the third read). The word budget is gone. In its
  place: headings as the skeleton, the ask under its own heading near the top with
  the owner named, folds for raw evidence and method only, tables, code fences and
  mermaid where they carry a fact, and a rule that an agent appends to an existing
  description rather than rewriting it. The linter drops the first-screen word
  ceiling and gains checks for a long body with no headings, a folded criteria or
  scope section, an ask buried in prose or a fold, a title past twenty words and an
  unclosed code fence. A worked example ships under `skills/issue-craft/examples/`.

## [0.3.3] — 2026-09-15

One new skill: the house style for Linear issues, sibling to `review-craft`.

### Added

- **`issue-craft`** (`9b6abfc`, DEV-669). Three skills described how to write a
  Linear ticket and they disagreed: `plan-issue` is a runbook welded to one
  person's loop, `fuelled-feature-ticket` is a fixed six-section template for one
  team, and nothing at all covered a spike, a record, a request or a security
  finding. This is one craft document, six thin shapes over a single contract,
  and a linter.

  It shares `review-craft`'s one principle and inverts one. Both demote rather
  than delete. But a review is consumed in a feed and is budgeted end to end,
  whereas a ticket is a durable record — read once at speed, then consulted for
  years — so only its **first screen** is budgeted and the document is unbounded.
  That distinction is a scar: the review budget was once applied to PR
  descriptions, which cannot fold, so "shorten" could only be obeyed by
  paraphrasing, and seven descriptions had to be restored from edit history.

- **`issue_lint.py`**, the deterministic gate. It checks paired folds, the
  first-screen budget, a long body that folds nothing, unfilled placeholders,
  rotting relative dates, unpaired backticks, titles that name a topic rather
  than make a claim, a markdown severity scale competing with Linear's own
  priority field, and markup Linear silently drops.

  The check that matters most was not in the original design. The linter was
  tested against a real ticket previously described as a wall; it passed clean,
  which was wrong. That ticket's actual failure is that nothing in it is folded,
  which drove the "long body, nothing folded" check.

### Notes

The Linear mechanics the skill rests on were probed live rather than assumed,
on 15 September 2026, against two throwaway issues:

- `+++ Title` ... `+++` renders as a native collapsible, **collapsed by
  default**. Linear accepts `>>>` as the opener and normalises it to `+++`.
- An **unpaired `+++` swallows the entire rest of the document** into the fold.
  The API returns success and nothing warns you. This is why the linter exists.
- Folds **survive a human editing the issue in Linear's own web editor** — both
  fold pairs came back byte-identical, so they are a first-class node rather
  than a markdown artefact.
- The API serves a **stale body for roughly 60 seconds** after an editor edit,
  with `updatedAt` unchanged, so an agent reading just after a human edit can
  get the old text.

An earlier claim that folds "round-trip" rested only on the API storing the
token. That proved storage, not rendering, and the two are different claims.

The house style also records what the evidence does **not** support: an
interview study of 26 practitioners against 31 issue-tracker smells rated
"description too long" not problematic by 6 of 13, and the 14 problems they did
report are system-level rather than prose-level. The legibility problem the
skill addresses is specific to agent-authored density, which nobody has studied,
and it says so rather than borrowing authority it does not have.

## [0.3.2] — 2026-09-14

The coordinator protocol goes into service, and the three things it depended on
get built. Also four defects in the live dispatcher that the work surfaced.

### Added

- **`D ledger children <KEY>`** (`21def50`, DEV-628). The coordinator writes
  `parent=<KEY>` on every child it dispatches and, until now, nothing read it —
  so a replacement coordinator could not find the children still running and
  would dispatch a second session onto each one's live branch. This is the
  command that closes that.
- **A `decide` mode** for children that record answers rather than produce a PR.
  It shipped in 0.3.1 wired to nothing, so such a child fell through to
  `investigate`, whose finish line is a findings comment.
- **`blocked`**, distinct from `needs-input`. `needs-input` means a question was
  asked and a thread is open; `blocked` means the work was analysed and is not in
  a fit state to begin. It sits in `WORKING` so the poller will not re-trigger a
  parent that has been claimed and held.
- **`init` teaches an existing config a vocabulary it has not heard of**, and
  creates only the labels a workspace lacks, so an install from an earlier
  version picks up new modes without losing its ids.

### Changed

- **Coordinators now run `stack.v2.md`.** `implement.md` and `SKILL.md` both
  routed to the superseded protocol. The old file stays as a 32-line signpost:
  bundled content syncs into `~/.locus` and is never removed there, so deleting
  it would leave the old protocol on disk under the name the previous
  instructions named, where a redirect costs nothing.

### Fixed

- **`ledger_put` had no lock.** It is a read-modify-write, and two sessions
  legitimately write one child key — a coordinator setting `parent=` and the
  Dispatcher writing `status=lost`. Under interleaving an entire writer's update
  was lost, including the `parent` field the recovery path depends on. Now holds
  `flock` across the read and the write.
- **One unparseable ledger file stopped everything.** `ledger_all` raised outside
  the poller's per-section guard, so a single truncated entry killed the poll loop
  and every command at once. Now skipped with a warning.
- **A label with a null id silently disabled every Linear trigger** while the
  Dispatcher reported healthy. Now loud in `poll`, `label` and `doctor`.
- **`SKILL.md` named a poller path that has never existed**, and omitted
  `--instance`, which fails outright once a machine has more than one.

## [0.3.1] — 2026-09-13

Two skills, and the audit that found the first of them was teaching agents to
reproduce a bug the runtime had already fixed.

### Added

- **The Dispatcher ships as a skill** (`91b6ee2`, DEV-627). It watches a Linear
  workspace for label triggers and GitHub for review requests, and turns each
  into a real worker session with its own workspace and branch. Code and config
  are separate: the skill is identical everywhere, while each repo gets its own
  instance directory holding config, ledger and poll state, so one machine can
  run a dispatcher per repo. `dispatcher init` creates the label group a
  workspace needs, because the label ids are the one config value nobody can
  type by hand.
- **`review-craft`** (`91b6ee2`). The review vocabulary, lenses, house style and
  linter, extracted because three separate modes already reached for them. It
  hands over a method and performs no review — deliberately noun-shaped so it
  cannot be confused with a skill that acts.

### Fixed

- **Six skills instructed the dispatch race they caused** (`67ad5fa`, DEV-626).
  `red-team`, `council`, `research`, `delegation` and `iterative-depth` all told
  the orchestrator to batch session creates into one message, which is what
  reproduced a session-id claim race. The rule now has one canonical home in the
  Algorithm's Dispatch section and the skills defer to it rather than restating
  it — restated rules drift, and this is what drift looks like. The same audit
  found no skill anywhere mentioned reclaiming its sessions, and a research
  workflow budgeting 30–60 concurrent sessions against a documented cap of 20.

## [0.3.0] — 2026-09-13

Two breaking changes shipped on master under a patch version. This release is
where the version catches up with them — and it is the release that makes the
plugin obtainable at all, because `locus upgrade` pulls from GitHub Releases and
the newest one, `v0.2.1`, predates the plugin entirely.

### Breaking

- **Locus ships as a Claude Code plugin** (`5b45c02`, DEV-579). The Algorithm
  moves out of a ~32 KB always-on block in `CLAUDE.md` and into the
  `locus-algorithm` skill, loaded on invocation rather than on every session.
  Classification is injected next to every prompt by a `UserPromptSubmit` hook
  and verified at turn end, instead of being asked for once in prose.
- **`locus platform add claude-code` no longer mutates Claude Code's own
  config** (`99ba517`, DEV-608), and `locus platform remove` exists to undo an
  install. Anything that relied on Locus writing into `~/.claude/settings.json`
  must move to the plugin.

### Added

- `.claude-plugin/marketplace.json`, so the plugin can be installed rather than
  only `--plugin-dir`'d (DEV-616):

      claude plugin marketplace add devergehq/locus
      claude plugin install locus@locus

  The entry sources the plugin from the repo root, not `dist/plugin`, because
  `/dist` is gitignored and `marketplace add` fetches a git ref.
- `locus doctor` health checks that can actually fail, rather than reporting
  success unconditionally (`51a7b4c`, DEV-506).
- An ISC ceiling and a recorded-exception path in the Algorithm, so a criteria
  count outside its tier's range is visible and argued instead of padded
  (`2384970`).

### Changed

- All six hooks run through one mechanism in the binary (`locus hook <event>`)
  with no Python dependency (`d6dc1c7`, DEV-610). The shell wrapper remains only
  to detect a missing binary, which the binary cannot do for itself.
- The Rust toolchain is pinned to 1.93 (`a8e328a`, DEV-611) and release builds
  resolve it from `rust-toolchain.toml` via `rustup show` + `rustup target add`
  rather than a separately-installed `stable` (`ff2c4dc`, DEV-611). Targets are
  installed per toolchain; the previous arrangement would have left the pinned
  toolchain with no std for `x86_64-apple-darwin`, the one genuinely
  cross-compiled target.

### Fixed

- Delegation sandboxes no longer destroy their own credentials (`f57b4b2`,
  DEV-505). Shipping a release without this would have meant the first version
  anyone installed still truncated their OpenCode auth.
- The `Stop` hook blocks on skill invocation only, and logs the post-recovery
  outcome (`7476f9a`, DEV-580).
- Delegation test roots no longer collide (`ccf5f9a`, DEV-613).

### Note on the plugin and the binary

Installing the plugin does not install the `locus` binary — it is per-platform
and built rather than vendored, so a git-cloned plugin carries none. Until the
binary is on `PATH`, all six hooks take the missing-binary path: loud, and never
blocking. **The release assets attached to this tag are what make the plugin
functional**, which is why DEV-616 (installable) and this release (functional)
are two halves of one deliverable rather than a feature and its housekeeping.

## [0.2.1] — 2026-08-16

Earlier releases are recorded in the
[GitHub Releases](https://github.com/devergehq/locus/releases) history.

[0.3.0]: https://github.com/devergehq/locus/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/devergehq/locus/releases/tag/v0.2.1
