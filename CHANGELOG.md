# Changelog

All notable changes to Locus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Locus uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — on a pre-1.0 line,
which puts breaking changes in the MINOR position.

`Cargo.toml`'s `[workspace.package]` version is the source of truth. A release
tag must equal that version with a leading `v`; `.github/workflows/release.yml`
refuses to build when they disagree.

## [Unreleased]

### Added

- **A review request reaches Review Desk the moment the poller sees it, and a review the
  developer dismissed is not dispatched.** Review Desk heard nothing about a request until a
  session ran `review open`, so it could not say how many requests had come in, which were never
  started, or which were dropped — DEV-945's first gap, filed after a stray review nobody could
  remove. `Poller.review_requests` now calls `review open --repo … --pr … --head … --title …
  --ledger <its own key>` for each request no live session holds, **before** it emits the
  request, and says nothing whatever about it: the `review_desk` pass asks the same install in
  the same tick and is what reports it absent, broken or too old. A request the principal
  skipped, or one nobody got to, is now a row on the Reviews list. Recorded once per key and
  head commit, and **never for a review a session has been linked to** — after a link a new
  commit is the next ROUND rather than a move, and a round nobody asked for is a second request
  on Review Desk's list. Marked only on success, because a repeat `review open --ledger` writes the links
  again and would leave every never-started request looking freshly touched for ever. An older
  Review Desk that refuses `--ledger` (`error.code` `usage`) is retried once without it; the
  first answer that is **absent or broken** stops recording for the rest of the tick, since one
  install answers for every request and at a 30s timeout asking per request is one stalled tick
  per page — where a refusal is about one request, so the rest of the page is still recorded and
  the refusal is said once per repository. **A recorded request is `review_requested` on Review Desk's own work list**, so three
  guards keep one request reaching the Dispatcher once: a request GitHub showed this tick, one
  somebody has already decided about (`skipped`, `deferred` or `merged`), and one whose ledger
  entry does not exist — the last being a request
  recorded on sight, never claimed, and no longer shown by GitHub, which stays in the record for
  the developer rather than being offered for ever. **A dismissed review stops the dispatch**
  (review-desk `dismissed_at`): `review_dismissed` names the review, its page and the
  developer's own reason, once per request, and nothing below it runs. Whether a review is
  dismissed has no commit of its own, so it is asked by reading — `review show`, at
  `reemit_after_secs` — and a Review Desk that cannot be reached leaves the dismissal standing,
  because not knowing is not a restore. A restore clears the said-once mark, so a second
  dismissal is said again. A build older than the field answers without it, which reads as not
  dismissed, which is exactly how this behaved before dismissal existed. **Dismissing, restoring
  and deleting are the developer's, from the page**: all three are the dashboard's API and have
  no command-line path at all, so no session can perform one. Nothing exits 2, and an instance
  with Review Desk off, absent or older behaves exactly as it did.

- **Every session the dispatcher starts says which allele group it belongs in.** On 12 October
  2026 the `tc-portal` project held 56 sessions in one flat list, and finding "the review of PR
  9586" meant reading every name. `group` on `allele_sessions_create` is allele's own (DEV-853,
  built alongside this), and `allele.groups` in the instance config says which group each mode
  goes in: `linear` for the four modes a Linear label triggers, `review` for a review request.
  Defaulted in code, so no instance needs an edit; `init` adds the block on a re-run so a mode
  can be turned off, and a mode set to `null` or `""` dispatches ungrouped. `D brief` names the
  group in its **Allele group** line, which is the whole mechanism: the session about to be
  created is named a group by the prompt it is already holding, and the worker reads the same
  line as the group for helpers of its own — a worker can read no config, so the brief is the
  only channel. A coordinator writes its own group on a child's claim and `D brief` prefers
  that, so a stack and a review's blind pass sit with the session that dispatched them rather
  than scattering. The ledger records the group the session was sent with. **`group` is passed
  only when the `allele_sessions_create` tool a session has been given lists it** — an allele
  that predates named groups refuses an unknown parameter, and a create that fails after the
  claim is the half-claimed ticket `SKILL.md` exists not to leave behind; when it is absent,
  dispatch is exactly what it was and nothing is said about it. A group over allele's 40
  characters, or one that is not a string, is read as ungrouped and crossed by a new `allele
  groups` line in `D doctor` — unlike the `intervals` line, which only reports, because a
  rejected group silently returns every session of that mode to the flat list. The dispatcher
  session itself is human-started, so `SKILL.md` asks its human for the group `dispatcher`;
  nothing in Locus can group a session it did not create. 70 assertions in
  `scripts/test-dispatcher-groups.sh` with five reversals, and two Rust pins in `bundled.rs`:
  `allele.groups` is a fifth per-mode config site, and the omit-when-the-tool-lacks-it rule is
  pinned in the three files that dispatch. **The real end-to-end run is owed** — the installed
  allele has no `group` parameter yet. (DEV-938)

- **The dispatcher's poller runs the harvest, and a draft waiting on the developer is read every
  20 seconds.** Two waits nobody had set. `review-desk harvest` had existed since DEV-859 with
  nothing calling it, so layer 7 of every posted review read `pending` for ever and
  `workers/review.md` said of it "nothing you do" — true of the session, and nobody else had the
  job. The poller now runs `review-desk harvest --repo <owner/repo>` for each repository it
  serves, one attempt per tick and no more often than `limits.harvest_interval_secs` (900),
  the turn going to whichever repository has waited longest,
  which is how a reply or a resolved thread that arrives after the session is discarded reaches
  the record. It is the first call in `dispatcher.py` that writes to Review Desk and it cannot
  sign off: it records what GitHub already says, running it twice records nothing twice, and a
  failure is one `harvest_failed` per interval per reason that stops nothing. And the first
  sign-off posted for real waited 4 minutes 28 seconds behind `watch_interval_secs` 300, so a
  review session's watcher now reads Review Desk every `limits.draft_watch_interval_secs` (20)
  while its draft is waiting on the developer, and `watch_interval_secs` otherwise. **Only the
  Review Desk reads speed up.** A red team found that `cmd_watch`'s one `time.sleep` throttles
  `pull_request`'s four GitHub calls as well, which at 20 seconds is 720 an hour per watcher
  against a token the poller shares, held for as long as a human leaves a draft `ready`; so
  `Watcher.tick` gained `full`, and a fast pass makes no GitHub call at all — asserted, not
  argued. Both settings are defaulted in code, so no instance needs an edit, `init` adds them to
  an older `limits` block without touching a tuned value, and `D doctor` gained an `intervals`
  line that names a value it is ignoring and never fails over one. A self-review then found the
  harvest sweep taking the first repository that was DUE rather than the one that had waited
  longest, which over sixteen simulated hours harvested three repositories 66-68 times each and
  the fourth and fifth not once; it now takes the oldest mark. A second review pass then found the
  assertion for that fix passing on the starving code — three repositories over three
  back-to-back ticks go round either way — so it now ages two marks differently and fails on it.
  100 new assertions in `scripts/test-dispatcher-review-desk.sh` (396 to 496), against a
  stand-in `review-desk` and a throwaway instance: no real harvest, no `~/.review-desk`, no `~/.locus/data/dispatcher`,
  nothing on 7777. (DEV-931)

- **`review-craft` now lints a brief.** `skills/review-craft/brief_lint.py` checks the structured
  brief Review Desk stores — deterministic, read-only, standard library only, 18 rules. Nothing
  checked one before: on the review that forced `understand.md` the session recorded 310 words of
  prose and a 50-line typed sketch for what the approved board carries in 85 words and one
  picture, and the house target of 150 words for a draft met 1,381, so asking in prose does not
  hold. A headline that is one sentence of at most 20 words, both flows drawn and inside
  their row ranges, every numbered problem marked on a box in each flow and carrying both its
  lines, a top layer with no class name, path or `::` and no sentence of three semicolon-joined
  clauses, every length limit, and a problem half that names neither an option nor an after-only
  box — the half a blind pass may be shown. A slot limit is a cap and the 150-word top layer is a
  budget, deliberately tighter than the sum of the caps; when the budget is what failed, the
  failure names the longest lines to tighten. Detail behind a click is never length-checked and there is no limit
  keyed on the size of the diff. `brief_lint.py <file.json>` needs no `review-desk`; `--review N`
  reads the saved brief through it and a missing binary is loud and exits 2, never 1. A brief
  written the old way is reported as "not structured" once, rather than as the four failures it
  would otherwise collect about slots it never had. The limits sit in one table at the top of the file with their provenance
  (`--limits`); `understand.md` owns them, which made two tighter than DEV-884 proposed and
  settled the headline at 20 words. Review Desk's own real-length brief passes all 18.
  `scripts/test-brief-lint.sh` covers every rule failing and passing, in 139 assertions.

- **CI runs the four `scripts/test-*.sh` harnesses.** They covered the Python skill scripts and
  nothing executed them, so DEV-794's own finding — "nothing caught it, because nothing tested it" —
  would have stayed true of the suite written to close it. All four were green together (65 + 26 + 79
  + 36 = 206 assertions) and none needs credentials, the network or a built binary. The step globs
  `scripts/test-*.sh`, so a harness added afterwards is picked up with no registration — eight of
  them now, 673 assertions. None had ever run
  on Linux, so the first red run there is information rather than a regression.

### Fixed

- **A review session kept running after its pull request merged, and the poller opened rounds on
  merged pull requests.** On 13 October 2026 the session for `tc-portal#9585` was still running
  hours after that pull request merged, telling Patrick "the draft was never posted" — about a
  round opened after the author pushed that nothing was ever going to post. Four rounds of #9568
  are the same shape. Three things were true at once. `watch_stop_reason` was merge-aware on the
  `done` path only, so a review worker that was anything else — `active` mid-round,
  `needs-input`, `stopped` — kept its watcher to the 120-hour ceiling; **a review key now stops
  on a merged or closed pull request whatever its status is**, in the same pass that read the
  merge and after the `pr_state` that tells the worker, and only a review key, because
  `implement.md` writes `status=done --note "merged"` only once it has seen the merge and a
  merged pull request still collects comments its author should answer. `Watcher.pull_request`
  suppressed every emission on a first tick, so a session dispatched after the merge heard
  nothing about the one fact deciding its brief; it now emits `pr_state` on a first tick over a
  closed pull request, for review keys only. And the poller's GitHub pass trusted `is:open` in
  the instance's own `review_query` — config, and GitHub's search index lags a merge — so it
  **asks for each row's `state` in the query it already makes and confirms a closed-looking row
  with a live `gh pr view`** before dropping it: nothing establishes whether `search` resolves
  `state` from the live record or from the same snapshot that produced the row, and a stale
  `CLOSED` would drop a live review request. A dropped row leaves `prs_present`, as a row that
  goes draft already does, so the clearance sweep reports the merge on the tick it is seen with
  `why_cleared`'s own live reason rather than when the index catches up — which under a
  `review_query` without `is:open` is never. Where that sweep will not speak — a first tick, a
  key GitHub had not shown before, and a request no session ever held — **`review_request_closed`
  says it instead**, once per key per `reemit_after_secs`, because it was the only silent refusal
  in a poller whose every other refusal names itself. **One request is still recorded, and only
  one: a pull request Review Desk has never held a review of at all**, written as a first review
  so that no round can be spent on it. The first cut of this recorded none, on the ticket's
  original wording; the review of that commit objected that this deletes the single row DEV-945
  exists to produce — a request nobody got to, on a pull request that then merged unreviewed,
  which is the review that did not happen — and Patrick narrowed the criterion to match. A pull
  request it HAS reviewed is never written to again, because `review open` on a head the author
  has pushed since is the next round. Nothing is dispatched from either case, and the event's
  `review_desk_id` says which one it was. A recorded-closed row is marked as such and held out of
  dispatch permanently by a fourth shape in `request_spoken_for`: it lives on the work list for
  ever, so `review_desk_item`'s `pr_state` check is re-rolled every interval and `pr_state`
  answers `None` on any `gh pr view` failure — one flaky call would otherwise have dispatched a
  review worker onto a merged pull request, which is DEV-959's own harm arriving through the row
  DEV-959 adds. Found by an independent `/code-review` pass over the recording commit, along with
  a `due` mark spent on a write that a broken Review Desk never performed, a live-session gate
  resting on the premise `WORKER_ARMED` exists to retire, a dropped `old` flag, a `look_stopped`
  guard that was not checked, and a malformed `review find` round that read as "no review at all"
  and would have been written to.
- **`workers/review.md` tells a review worker what to do when its pull request goes.** One line
  to the Dispatcher naming the round and whether its draft was posted, its own terminal ledger
  status (`merged` on a merge, `done` on a close, because a close is reversible), and then it
  ends. **An approved draft on a merged pull request is never posted**, whatever Review Desk
  still reports, and the worker says which of the two orderings it was. Writes that would
  *advance* the review stop; writes that *record an outward act already performed* — `draft
  posted`, `finding link`, `review nit-ticket` — do not, because leaving one unsaid makes the
  record lie about what is on GitHub. `nits_to_ticket` still outlives the merge and is filed
  before the worker says its line.
- **The Dispatcher discards a merged review worker itself**, by Patrick's decision on DEV-959: a
  narrow exception to `## Never`'s standing rule, written beside it, and covering only a review
  worker whose pull request GitHub reports merged or closed and which has stopped. Every other
  discard still needs the yes. Nothing in this repo calls `allele_sessions_discard`, which a
  stand-in `allele` recording zero calls across a poll tick and a watch tick is what establishes
  — so every discard is one a Dispatcher session chose from prose a human can read.
- **`Poller.cannot_be_told` read a `nits_to_ticket` as deliverable to a session whose watcher the
  merge had shut.** Its guard tested for `done` because `done` was the only status the old stop
  rule could produce; `WORKER_ARMED` (`ALIVE` minus `claimed`) names the premise instead. The
  absent-cursor branch stays scoped to `done`: `_common.md` step 2 writes `active` and step 3
  arms the watcher, so for those seconds an absent cursor is a watcher that has yet to start.
- **"File as one ticket for an agent" reached nobody.** Review Desk answers `work list` with five
  kinds of work and `REVIEW_DESK_KINDS` named four, so `nits_to_ticket` — the developer asking, on
  the draft page, for the findings they held back to be filed as one ticket — was dropped by the
  poller and by the watcher both. Review Desk files no ticket and says so, so that request was
  work for an agent that nobody was ever handed, and it had been since DEV-877. It now reaches
  whichever is true: the live session, through its own watcher, or a replacement, through
  `review_desk_resume`. Both emits carry `nit_ticket_status`, which on a `draft_approved` is the
  fact that is not otherwise visible — "Ticket what is left, and approve" is one click, and the
  ticket becomes an item of its own only once the posting is reported. `workers/review.md` gained
  the event and a section: one ticket covering the review's `held_back` findings, in the Linear
  workspace from the dispatch block and the team from the review's own `ticket_id`, written with
  `issue-craft` and reported back with `review-desk review nit-ticket --review <id> --ticket
  <NEW-ID>` — which is what clears the item and moves the draft page's button from "Queued as one
  ticket" to "Filed as <NEW-ID>". It says in two places that **filing is not a sign-off**: Review
  Desk ranks the request above its "nobody's turn" rule, so the item arrives while the draft may
  still be waiting on the developer, and nothing a session may do about it has changed. It also
  warns off `finding list`, which Review Desk's own `work list` help names and 0.1.0 does not have
  — a session that followed that help would exit 1 holding nothing. **And the next new kind will
  say so**: `Poller.unknown_kind` emits one `review_desk_unknown_kind` per kind name per
  `reemit_after_secs`, dispatching nothing and blocking nothing, sitting where the kind is tested
  rather than where liveness is — so an unknown kind is named even for a review somebody is
  working, which is what lets the watcher stay silent instead of repeating it every 20 seconds.
  `REVIEW_DESK_IGNORED_KINDS` is empty and load-bearing empty: it is the only way to say "read,
  and deliberately not ours" as against "never heard of it", and the fifth kind was in neither
  list for five weeks with no line anywhere to grep for. 103 new assertions in
  `scripts/test-dispatcher-review-desk.sh` (496 to 599), including a crossing that fails if Review
  Desk's contract lists a kind this file neither handles nor names as ignored, and twelve reversals
  — one showing that the crossing cannot see a kind missing from the *relay* list, which is why
  the relay test exists beside it, and one showing that a `nits_to_ticket` is dispatched on a
  **merged** pull request where no other kind is: the request becomes an item only once the draft
  is reported posted, a merge usually follows that, and the dashboard's own note beside the button
  is "the merge is not waiting on them", so the skip every other kind wants would have left the
  developer's click unanswered for ever. Against a stand-in `review-desk` and a throwaway
  instance: no real review, no real ticket, no `~/.review-desk`, no `~/.locus/data/dispatcher`,
  nothing on 7777. (DEV-934)

- **An empty GitHub search is no longer read as an empty inbox.** `review_requests()` and
  `linear_triggers()` both treated a zero-result tick as a fact about the world and committed the
  destructive state that follows from it. Executed, the review side cleared a live review with the
  reason `"review request removed"` for an open PR, re-emitted a PR the principal had **skipped** as
  `rerequested: true`, fired a false `review_rerequested`, and dropped a start-up item's backlog flag
  permanently — which silently undoes the backlog fix above, so the two ship together. The Linear
  side deleted every trigger marker, re-emitting each one on recovery with its `backlog` flag lost.
  `REVIEWS_Q` now requests GitHub's `issueCount`, and new `Poller.trust_empty()` believes an empty
  result only on the **second** consecutive zero, refusing it outright when the search says it
  matched work and returned none of it. An unbelieved zero emits `source_empty` and skips the commit
  entirely, so recovery is a no-op rather than a burst of false events. A first draft also believed
  `issueCount == 0` at once, on the reasoning that GitHub had affirmatively said "nothing matched";
  review showed that `issueCount` and `nodes` come from the same query against the same
  eventually-consistent index, so a stale index reports zero for both — the exact shape the guard
  exists to refuse — and an `issueCount: 0` tick reproduced all four harms on the guarded source.
  Truncation is guarded too: above `REVIEW_PAGE` the surplus is absent from `nodes` and GitHub's
  search order is not stable between ticks, so 52 open requests produced two false `review_cleared`
  against PRs under active review. On a truncated page the **cleared sweep** is skipped while
  `prs_present` is still committed, as the union of what was known and what came back — a first
  version returned without committing it, which froze the snapshot and re-offered a `skipped` PR as
  `rerequested: true` once per tick, ungated, for as long as the truncation lasted. That was worse
  than not guarding truncation at all, inside truncation's own trigger condition, and review caught
  it. The cost of the guard is clearance detection alone: a review that genuinely stops being
  requested is not reported until the count drops back under a full page. `status` gains a per-source line — `github 0 items 40s ago (last non-empty 6h ago)` — which
  is what would have shown the 30 Sep incident, where `poller heartbeat: 31s ago` was true
  throughout, and `SKILL.md` gains the `source_empty` handler and the `sources:` line. `poll` gains
  `--backlog`/`--no-backlog` so a host can state the start-up policy instead of inheriting it from
  its own shape; the default is unchanged. `poller_started` now fires once per process regardless of
  that flag, carrying `backlog_suppressed`, because a session whose first call carried `--no-backlog`
  auto-dispatched everything open and emitted nothing at all to say a process had run with the policy
  off — a policy nobody can observe is barely better than one nobody chose. `status` no longer raises on a `sources` bucket or an
  error record written by another version of this file — `parse_iso(None)` throws `AttributeError`,
  which the original `except (TypeError, ValueError)` did not catch, in a function whose whole job is
  not to hide the rest of the line. The guard is per process: an orphaned poller on an older plugin
  version still commits an empty result as fact, and can roll the `sources` values back, because
  `poll_state()` takes no lock across its read-modify-write (DEV-799, folded into DEV-794's PR).

- **The dispatcher's start-up backlog is reachable again.** `Poller.__init__` read `first_tick`
  out of the *persisted* state file — `not self.state.get("started")` — while `tick()` writes
  `started` to disk, so `backlog` was true once per instance **lifetime** rather than once per
  session. The `tc-portal` instance carried `"started": "2026-09-11T13:18:11+00:00"` for 19 days,
  which made SKILL.md step 4's whole start-up contract (list the review backlog, ask before
  dispatching) unreachable dead code for all of them: `review_backlog` was `[]` and stayed `[]`,
  and on 30 Sep a three-hour session surfaced 1 of 10 open review requests. `first_tick` is now a
  property of the process, which needs no migration — every instance already carrying a poisoned
  `started` is fixed by its next arm, with no version marker to interpret. `started` is now
  written with `setdefault`, so it keeps its meaning (when this instance's poller first ran) and
  keeps the 11 Sep stamp as the evidence. Replayed against the live GitHub data with a 19-day-old
  `started`: 11 open requests, 11 flagged `backlog: false` before, 11 flagged `backlog: true` and
  a `poller_started` after. `scripts/test-dispatcher-poller.sh` pins it against a poisoned state
  fixture, and reverses the fix in a copy of the source to prove the suite discriminates. One
  behaviour change comes with it: because the flag is per process, every run of a host that drives
  `poll --once` on a cadence — which is what production does as of 30 Sep, the `Monitor`-hosted
  poller having lost the principal's trust — announces a backlog, so any review request it
  surfaces is flagged `backlog: true`, none auto-dispatches, and each needs a human decision. That
  is what the Dispatcher was already doing by hand. `due()` still gates emission at
  `reemit_after_secs`, so a key is announced at most once per that window however often the poller
  runs; what fires on every run is `poller_started` (DEV-794).

- **A thrown poller section now reports off stdout.** `Poller.error()` reported a failing section
  by calling `emit()`, which writes to stdout — the same channel that may be the thing that is
  broken — at most once per signature per 1800s, with the timestamps persisted *across* sessions.
  So a failure repeating for a week could report twice an hour, to nobody, and leave no trace
  anywhere else: `state["errors"]` is only the rate-limit clock and is written once at end of
  tick, so a section that throws and then a process that dies left nothing at all. New
  `Poller.record_error()` writes every occurrence to stderr and appends it, with a traceback, to
  `runtime/poller-errors.jsonl` before `tick()` reaches its state write. The file is trimmed by
  bytes at 256 KiB, keeping the newest. `status` now prints the last error and its age. The
  `error` event on stdout is unchanged, rate limit included, so existing readers see no
  difference (DEV-794).

- **A dispatcher watcher now stops.** `dispatcher.py watch` had no exit condition and never read
  its own key's ledger status, so nine watcher processes were alive on the `tc-portal` instance on
  30 September 2026 — all nine on keys whose status was `discarded`, the oldest for 6 days 14
  hours. Fourteen watchers were alive thirteen hours later with the orphan count still nine, so
  creation outpaces reaping: at `watch_interval_secs` 300 that is 168 ticks an hour and, at the
  four `gh api` call sites a watch tick reaches, up to ~672 GitHub REST calls an hour — ~13% of
  the authenticated budget spent largely on work that had finished days earlier. A watcher now reads its key before every tick, including the first, and stops when
  nothing will speak on that key again (`discarded`, `failed`, `lost`, `skipped`, `deferred`, or
  `done` once its PR is merged or closed), saying why and removing its own cursor file. Checking
  before the first tick is what makes the exit safe under the persistent `Monitor` that hosts it:
  a relaunch onto a dead key costs one local file read, not six API calls.

  `done` alone is deliberately **not** an exit, though DEV-795 listed it: `implement.md` writes
  `status=done` while the PR is still open and then tells the worker to stay alive for
  `pr_review`, so exiting there would make it deaf at the moment the review lands. The
  discriminator is `pr_status`, which the watcher already persists. `--exit-on-done` is the
  ticket's literal reading, kept but not the default.

  Backstops and visibility, for the case where the ledger is never updated: `--max-hours`
  (default `limits.watch_max_hours`, 120) and `--max-ticks`; `doctor` lists every `watch` process
  with its key, age and ledger status and **fails** on an orphan; and a new `reap` subcommand
  terminates this instance's orphans and removes cursor files for finished keys — 112 of the 127
  cursors on `tc-portal` were for keys nobody is working. `reap --dry-run` reports without
  signalling. Process matching is narrow on purpose: a `ps | grep dispatcher.py` on that machine
  also matched three Claude sessions quoting the docs and a `/bin/zsh -c` wrapper per watcher.

- **`reap` no longer assumes a watcher with no `--instance` is ours.** A review found the comment
  justifying that assumption was false: `instance_path` accepts an absolute path anywhere, so
  `$DISPATCHER_INSTANCE=/opt/elsewhere/inst` is a legal launch whose argv names no instance and
  whose instance is not the one under `DISPATCHER_HOME`. On a single-instance box that would have
  made another instance's *live* watcher reapable — the one failure the matching rules exist to
  prevent. A process cannot read another process's environment, so ownership is now established
  from this instance's own `runtime/watch/` cursor instead; both ways that check can fail leave the
  process unattributed and therefore never signalled.

- **`doctor` reports the plugin version each watcher is running.** One of the nine orphans was
  executing locus 0.5.2 while every other watcher on the machine ran 0.5.4: a watcher outlives the
  install that started it, because the plugin cache keeps a directory per version and a running
  process holds the path it was launched with. `reap` was already version-agnostic — it matches any
  argv token whose basename is `dispatcher.py` — but nothing showed that two different programs
  were involved, which is how a future reaper would appear to miss watchers it had never been able
  to see.

- **`status` reports consecutive quiet ticks.** The poller counts ticks that emitted nothing and
  `status` prints the run length and when it started, so "nothing is happening" can be read rather
  than inferred from a heartbeat that advances either way. Counting only: whether an idle
  dispatcher should stop on its own, ask first, or stop just its poller is an open decision. Each
  quiet run's length is appended to `runtime/quiet-log.jsonl` when the run **ends**, so that
  decision's threshold can be set from a week of real traffic rather than by arithmetic on an
  unmeasured cost — which is what the ticket asked for.

- **`review_lint.py` fails a review body's table over four columns.** An index on
  Trilogy-Care/tc-portal#9125 passed 23/24 — `layout.table_prose` reported `0 table cell(s) over
  140 characters`, correctly, its widest cell being 64 — and was reported rendering as
  `Disposit/ion` and `P/1`. The per-cell checks cannot see how many columns a row asks for.
  A total-width threshold was measured and rejected: over 96 harvested tables that pass the
  per-cell checks, the sum of each column's widest cell has a median of 133 characters and the
  table reported broken was 129, below the median; a rendered-width model fitted against Chrome
  (RMSE 49px over 123 tables) puts eight four-column tables wider than the five-column one.
  Column count is the one dimension on which it is an outlier — 1 of 103 real review bodies — and
  `house-style.md` now states the budget the worked template always implied. Threads are exempt:
  a thread's table is pasted evidence. `cells()` is unchanged, verified byte-for-byte against
  585 real bodies and threads.

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

- **CI runs once a pull request is ready, not on every push to every draft.** Both check
  workflows now trigger on `pull_request: [opened, reopened, synchronize, ready_for_review]`
  plus `workflow_dispatch`, and every job is gated on
  `if: github.event_name != 'pull_request' || github.event.pull_request.draft == false`. So a
  draft push creates a run whose jobs all report `skipped` and bills no minutes; marking the
  pull request ready, and every push after that, runs the lot. `push: branches: [master]` is
  gone from `ci.yml`, because a merge is the commit the ready pull request's run already
  tested. Two consequences follow. A check can no longer be read off `master` itself, only off
  the pull request that produced the commit. And **nothing writes a `master`-scoped cache any
  more**: Actions cache scoping lets a pull request restore the default branch's entries but
  keeps its own scoped to its own ref, so `master`'s were the shared warm base and the removed
  run was what refreshed them. They are now frozen at the last one written before this change —
  every pull request still restores them and then rebuilds whatever has moved since, which is
  slower rather than more expensive here, and no warming job has been added for it. DEV-961,
  and the number behind
  it is Review Desk's rather than this repository's: about 146 pushes across 17 branches over
  11 and 12 October 2026, about 13 billed minutes each, which took the organisation's 3,000
  monthly minutes by the 13th. Locus is public, so its minutes were free and nothing here was
  costing anything; the change lands for one rule across all three repositories, and so that
  dozens of runs nobody reads stop being queued. The gate is written as a negative guard
  rather than as `draft == false` alone, which is silently TRUE on every non-pull-request
  event — a missing property and `false` both coerce to 0 — and so would have passed a
  `workflow_dispatch` by accident rather than by intent. `reopened` is named because listing
  any type replaces the default set instead of adding to it. Concurrency groups are unchanged
  and still cancel superseded runs. No branch on this repository has protection rules, so
  nothing is blocked either way — and one wrinkle is recorded in `ci.yml` for whoever writes
  such a rule later. A skipped job satisfies a required check by design, but a skipped MATRIX
  job is never expanded: measured on commit `b78eaf6`, a draft's check runs are `rustfmt`,
  `clippy` and one literal `test (${{ matrix.os }})`, so the contexts `test (ubuntu-latest)`
  and `test (macos-14)` are **absent** on a draft rather than skipped. A rule requiring them
  would leave a draft waiting rather than passing, which is the right outcome for something
  that cannot merge and looks like a stuck check rather than a deliberate one.
- **Converting a ready pull request back to draft now stops the run in flight.**
  `converted_to_draft` is in both check workflows' `types:` and is the only type there that
  exists to make a run STOP rather than start — taking a pull request back to draft fires no
  other event, so without it the run from the last push kept going on work somebody had just
  said was not ready, which is this ticket's own waste spent after the decision not to spend
  it. With it the conversion fires a run whose every job skips on the gate, and the
  concurrency group does the rest: both runs key on the same group, so starting the second
  cancels the first. It can never start a run, because `draft == false` is false on that event
  by definition. Measured on throwaway PR #93, both runs on head `d57cd1e`: run 38331308926
  was created at 01:16:06Z and run 38331282602 went to `cancelled`, cutting `test (macos-14)`
  at 1m30s against the 3m27s it takes to finish and `test (ubuntu-latest)` at 1m31s against
  2m44s — about three minutes of runner time on one conversion. Raised by the session doing
  this ticket on `devergehq/review-desk`, which owns the trigger the three repositories share.
- **`pr-lint.yml` keeps `edited` and gains a manual trigger that takes a pull request
  number.** `edited` is this repository's one addition to the four triggers the three
  repositories settled on, and it is load-bearing: a description is edited in the web UI with
  no commit, so without it the check reports on a description that no longer exists. The
  `issue_comment` trigger is NOT draft-gated, deliberately — the working-notes comment is what
  the description links at, and the issues-API payload that event arrives with carries no
  `draft` field to gate on. The manual trigger needs the number because the action hard-exits
  on an event carrying none, so `.github/actions/pr-lint` gains an optional **`pr` input**
  that takes precedence over the event when set. Every existing caller is unaffected: it
  defaults to empty and the event is read exactly as before.
- **`implement.md` step 7 runs the suite locally instead of waiting on a draft's checks.** It
  said `gh pr checks <n> --watch` at a point in the pass where the pull request is still a
  draft, which under the rule above returns exit 0 on a run where every job was skipped — a
  green that means "nothing ran". It now runs the full local set there and reads GitHub's
  checks in step 8, after `gh pr ready` has fired `ready_for_review`. `stack.v2.md` needed no
  change: its named-check gate already runs after the ready.

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
