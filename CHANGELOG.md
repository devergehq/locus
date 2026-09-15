# Changelog

All notable changes to Locus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Locus uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — on a pre-1.0 line,
which puts breaking changes in the MINOR position.

`Cargo.toml`'s `[workspace.package]` version is the source of truth. A release
tag must equal that version with a leading `v`; `.github/workflows/release.yml`
refuses to build when they disagree.

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
