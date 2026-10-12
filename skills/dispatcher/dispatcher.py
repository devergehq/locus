#!/usr/bin/env python3
"""Dispatcher: Linear labels + GitHub review requests -> allele worker sessions.

The deterministic half of the agent dispatcher. The judgement half (claiming, dispatching,
talking to the principal) lives in SKILL.md and runs in a human-started allele session.
Standard library only.

CODE and CONFIG are separate roots, and the distinction is load-bearing:

  code      this file's directory. Worker briefs, the config template. Read-only, shipped
            with the plugin, identical for every instance.
  instance  ~/.locus/data/dispatcher/<slug>/. config.json plus runtime/ (ledger, watch
            state, poll state, heartbeat). Written, per-repo, never shipped.

Resolve an instance with --instance <slug>, or $DISPATCHER_INSTANCE, or by having exactly
one instance installed. `doctor` prints both roots.

  init --instance SLUG                   Create the Agent label group and write config.json.
  poll [--once] [--backlog|--no-backlog] Dispatcher's eyes. One JSON line per new event.
  watch KEY [--pr OWNER/REPO#N] [--once] A worker's eyes on its own ticket and PR.
                                         Stops when the key's ledger status says nothing will
                                         speak on it again, or at --max-hours / --max-ticks.
  reap [--dry-run]                       Terminate this instance's orphaned watchers and
                                         remove cursor files for keys that are finished with.
  ledger list [--all] | get KEY | put KEY [k=v ...] [--note TEXT] [--by WHO]
  label ISSUE STATE [--state NAME]       Set the ticket's one Agent-group label ('none' clears).
  comment ISSUE [--key KEY] [--mode M] [--reply-to ID]   Signed Linear comment, body on stdin.
  brief KEY                              Print the dispatch prompt for the ledger entry KEY.
  review-posted KEY --approved-at N --body-file P
                                         Read-only: is the principal's approved review already
                                         on that pull request? What makes posting once safe.
  status                                 Ledger vs allele, as a table.
  doctor                                 Check env, auth, labels, paths.

Nothing here posts to GitHub. Linear writes happen only through `label` and `comment`.

Review Desk, when it is installed, is a third source and a third set of a worker's eyes: the
poller asks it what needs an agent, the watcher relays the developer's two sign-offs to the
session waiting for them, and `review-posted` asks GitHub whether an approved draft is already
up. Absent is silent, broken is loud, and neither ever blocks a review. Nothing here can sign
off: Review Desk's command line has no command for it, and this file makes exactly one HTTP
call to the dashboard, for `doctor`'s health line.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# The code root: worker briefs and the config template, shipped read-only beside this file.
CODE_DIR = Path(__file__).resolve().parent

# The instance root: everything that differs between repos, and everything that is written.
DISPATCHER_HOME = Path(os.environ.get("DISPATCHER_HOME", "~/.locus/data/dispatcher")).expanduser()

_instance: Path | None = None


SLUG = re.compile(r"[A-Za-z0-9._-]+")

ME = Path(__file__).resolve()


def instance_path(value: str) -> Path:
    """A slug under DISPATCHER_HOME, or a path used as given.

    Accepting a path is what lets `brief` hand a worker something that resolves without
    inheriting this process's environment: a bare slug only means anything relative to a
    DISPATCHER_HOME the worker cannot see.
    """
    if os.sep in value or value.startswith("~"):
        path = Path(value).expanduser()
        if not path.is_absolute():
            # A poller is started by a supervisor whose working directory is not the operator's,
            # so a relative path in a launchd plist or systemd unit resolves somewhere else
            # entirely — and silently, since it would simply fail to find a config.json.
            raise SystemExit(f"instance path {value!r} must be absolute, or a bare slug under "
                             f"{DISPATCHER_HOME}")
        return path.resolve()
    if not SLUG.fullmatch(value) or value in (".", ".."):
        raise SystemExit(f"bad instance slug {value!r}: letters, digits, dot, dash, underscore, "
                         f"or an explicit path")
    return DISPATCHER_HOME / value


def resolve_instance(slug: str | None) -> Path:
    """Find the instance directory, or explain how to make one.

    Identity is `config.json`, not directory name: a directory without one is not an
    instance, which is what keeps stray subdirectories from being mistaken for a half
    installed one.
    """
    slug = slug or os.environ.get("DISPATCHER_INSTANCE")
    if slug:
        path = instance_path(slug)
        if not (path / "config.json").is_file():
            raise SystemExit(
                f"no config.json in {path}\n"
                f"create it with:  python3 {ME} init --instance {slug} --team-key KEY"
            )
        return path
    found = sorted(p.parent for p in DISPATCHER_HOME.glob("*/config.json"))
    if len(found) == 1:
        return found[0]
    if not found:
        raise SystemExit(
            f"no dispatcher instance under {DISPATCHER_HOME}\n"
            f"create one with:  python3 {ME} init --instance <slug> --team-key KEY"
        )
    names = ", ".join(p.name for p in found)
    raise SystemExit(f"several instances ({names}); pass --instance <slug> or set DISPATCHER_INSTANCE")


def instance() -> Path:
    global _instance
    if _instance is None:
        _instance = resolve_instance(None)
    return _instance


def runtime() -> Path:
    override = os.environ.get("DISPATCHER_RUNTIME")
    return Path(override).expanduser() if override else instance() / "runtime"


def ledger_dir() -> Path:
    return runtime() / "ledger"


def watch_dir() -> Path:
    return runtime() / "watch"


def poll_state() -> Path:
    return runtime() / "poll-state.json"


def heartbeat() -> Path:
    return runtime() / "poller-heartbeat"


def quiet_log() -> Path:
    return runtime() / "quiet-log.jsonl"


def error_log() -> Path:
    """Where a thrown poller section is recorded, independently of stdout. See `record_error`."""
    return runtime() / "poller-errors.jsonl"

# Ledger statuses. WORKING counts against max_workers; ALIVE means a session should exist.
#
# `blocked` is a working status deliberately, but NOT for the two reasons first written down
# here, both of which are false and were caught by a red team before they could mislead anyone:
#
#   * It is not what stops the poller re-triggering. `linear_triggers` gates on the *label*
#     (`if not mode: continue`) before it reads a status at all. `Agent - Blocked` does that.
#   * It is not what keeps it on `D status`. That filter is `ALIVE | {"queued"}`, and `queued`
#     is already visible while sitting outside WORKING.
#
# The real reason is the one set it must stay OUT of: REDISPATCHABLE. `SKILL.md` tells the
# Dispatcher to drain `queued` entries whenever a slot frees, so a held parent filed as
# redispatchable would be dispatched again by the queue-drain — which is precisely what
# `stack.v2.md` §3d-ii forbids ("One resolver per hold"). WORKING is the set that is visible,
# not redispatchable, and already sibling to `needs-input`, which `blocked` is the other half
# of: `needs-input` is somebody owing an answer, `blocked` is the work not being ready.
#
# Its one cost is that WORKING ⊂ ALIVE, and ALIVE means "a session should exist" — which a
# handed-back parent's does not. `liveness()` opts it back out; see the guard there.
WORKING = {"claimed", "active", "needs-input", "blocked"}
ALIVE = WORKING | {"done", "stopped"}
REDISPATCHABLE = {None, "queued", "lost", "failed", "discarded"}
# Statuses deliberately in NO set above, and the absence is the behaviour rather than an
# oversight: `merged` and `deferred` mean no session should exist (so not ALIVE) and the item
# must never be dispatched again (so not REDISPATCHABLE). They therefore stop appearing as live
# work with no call-site change. A named TERMINAL set was proposed and declined — nothing would
# read it, and a constant nothing reads is a second place for this decision to drift.
#
# **DEV-945 gave it a reader, so here it is.** Recording a review request on sight means Review
# Desk's work list now carries a `review_requested` item for keys it never had one for, and the
# Review Desk source must not offer a key somebody has already decided about. `skipped` is the
# principal's own decision; `deferred` and `merged` are the two above. Read by
# `request_spoken_for` and by nothing else, which is why it is defined here rather than guessed
# at there — the set and the paragraph above it have to agree, and now they are adjacent.
DECIDED = {"skipped", "deferred", "merged"}

# Statuses after which nothing will ever speak on the key again, so a `watch` process still
# running on it is an orphan. Read by `cmd_watch`, `cmd_doctor` and `cmd_reap`.
#
# The set above says a named TERMINAL set was declined because nothing would read it. Three
# things now do, so that argument has expired rather than been overruled — but the reason it was
# made still governs what goes IN. A status is a member because a call site acts on it, not
# because it sounds final:
#
#   `lost`      the Dispatcher's word for "the session ran and died" (`stack.v2.md` §, and
#               `SKILL.md`'s `session_lost` row re-queues the work to a *replacement*, which
#               starts its own watcher). A watcher on a `lost` key is delivering to nobody.
#   `deferred`  no session should exist and the item is never dispatched again.
#   `merged`    A member, but read the next sentence before relying on it. Nothing in this repo
#               writes it — `grep -rn "status=merged"` is empty — because `implement.md` records a
#               merge as `status=done --note "merged"`, so **the status to reason about after a
#               merge is `done`, not this.** It is a member anyway because `stack.v2.md` tells a
#               coordinator at :149 and :1453 that `merged` is terminal, so someone following the
#               documented vocabulary will eventually write it; membership costs nothing if they
#               never do, and the alternative is that watcher running the full ceiling.
#   `stopped`   NOT a member. `_common.md` has a stopped worker write the status and *wait*, and
#               what it waits for — a re-label, a human comment — reaches it only through this
#               watcher. Killing it strands the worker. It is bounded by the ceiling instead,
#               which every watcher gets regardless of status.
#   `done`      NOT a member, and it is the membership DEV-795 and this file disagree about.
#               See `watch_stop_reason`.
WATCH_DEAD = {"discarded", "failed", "lost", "merged", "skipped", "deferred"}

# A PR state that means the review is over. `Watcher.pull_request` already computes and persists
# `pr_status`, so this is read from the cursor file rather than from GitHub.
PR_CLOSED = {"merged", "closed"}

# Hours a `watch` process may run before it stops regardless of what the ledger says.
# `limits.watch_max_hours` overrides it; the code default covers every config.json written
# before this key existed, which is all of them.
WATCH_MAX_HOURS = 120.0

LINEAR_KEY = re.compile(r"^[A-Z][A-Z0-9]+-\d+$")
PR_URL = re.compile(r"github\.com/([^/]+/[^/]+)/pull/(\d+)")
BODY_LIMIT = 1500
# The error log is bounded so a section failing every tick for a month cannot fill the disk.
# Trimmed by bytes rather than by a line count, because records vary by an order of magnitude with
# the length of the traceback, and a fixed line count spends most of the budget or none of it.
ERROR_LOG_MAX_BYTES = 256 * 1024


# --------------------------------------------------------------------------- basics

def load_config() -> dict:
    return json.loads((instance() / "config.json").read_text())


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def now_z() -> str:
    """For GitHub `since=` query params, where a literal '+' would decode as a space."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def write_json(path: Path, data) -> None:
    """Atomic: a crash mid-write leaves the old file, never half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


# Every line this program says to its reader goes through `emit`, which makes counting calls the
# cheapest possible definition of "did anything happen this tick". `Poller.mark_quiet` compares it
# either side of a tick. A counter and not a flag so that nesting or a second reader cannot reset
# it halfway through.
_emitted = 0


def emit(event: str, **fields) -> None:
    global _emitted
    _emitted += 1
    print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)


def clip(text: str | None) -> str:
    text = (text or "").strip()
    return text if len(text) <= BODY_LIMIT else text[:BODY_LIMIT] + " …(truncated — read the full text at the url)"


def usable_secs(value) -> bool:
    """Whether `positive_secs` will take this value as the number of seconds it is given for.

    Separate from `positive_secs` so that `doctor` and the loops cannot disagree about what a
    usable value is. An earlier version had them disagree: `positive_secs` parsed a numeric
    string with `int()` and USED it, while `doctor` rejected any string and told the operator
    their value was being ignored. One of the two had to be wrong and the operator could not
    tell which, so there is now one predicate and both read it.

    `isinstance(True, int)` is True in Python, so `true` in a JSON config would otherwise be
    one second. Excluded by name rather than by hoping nobody writes it.
    """
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def positive_secs(value, fallback: int) -> int:
    """A seconds setting, or the code default when the config does not hold a usable one.

    Total by design, where most of this file would rather raise. Both callers sit inside a loop
    whose host restarts it — the poller under `Monitor`, a worker's watcher under a persistent
    one — so a value that threw would not fail once. It would fail, respawn, run a full tick and
    fail again with no sleep in between, which is the one shape that turns a typo in a config
    into a hot loop against GitHub. A string, a null, a zero and a negative all therefore read
    as "not set", and the code default is what a setting nobody has written means anyway.

    **`doctor` says so out loud, and never fails over it.** A value this rejects is a value the
    operator edited and never saw take effect, which is worth a line and is not worth stopping
    the Dispatcher for — nothing is misbehaving, and the setting it concerns was designed to be
    absent on every existing instance. See `intervals_check`.
    """
    return value if usable_secs(value) else fallback


def pr_key(repo: str, number: int) -> str:
    return f"gh-{repo.split('/')[-1]}-{number}"


def requested_key(key: str) -> str:
    """One pull request's key with the case taken off, for comparing keys ACROSS SOURCES.

    **The two review sources spell a repository differently, and only this comparison has to
    survive it.** GitHub's search hands back `nameWithOwner` as the repository is registered —
    `devergehq/Locus` — so `review_requests` keys that pull request `gh-Locus-86`. Review Desk
    stores `repo` lower-cased and `review_desk_repos` asks it in that form, so an item that
    carries no `ledger_id` is keyed `gh-locus-86` by `review_desk_item`'s own fallback. Those
    are the same request and the same pull request, and before this function the
    one-request-one-event guard compared them as strings and missed: both sources emitted, and
    two sessions could be dispatched for one review. Found by review of this branch, reproduced
    with `search_doc Acme/Portal` against the harness.

    **`pr_key` itself is deliberately NOT normalised**, and that is not timidity. It names a
    FILE — `runtime/ledger/gh-Locus-86.json` — and every live entry, every running watcher's
    cursor and every `D ledger` the principal types is already spelled the way GitHub spelled
    it. Lower-casing it would make the next tick read a claimed review as unclaimed and dispatch
    a second session onto a live branch, on upgrade, for exactly the instances this is meant to
    protect. So the key keeps its case and the comparison loses it.

    What is left uncovered, said plainly: `request_spoken_for`'s other two shapes read the
    LEDGER by key, so for a review carrying no `ledger_id` on a mixed-case repository they can
    still miss their entry. That is the same pre-existing asymmetry, it predates DEV-945, and
    the fix for it is a ledger re-keying with a migration — its own ticket, not this one.
    """
    # `str()` first, because the key can come straight off Review Desk's `work list` —
    # `item["ledger_id"]`, which `review_desk_item` type-checks neither there nor here. Before
    # this comparison existed a non-string was harmless (a dict miss and an f-string); now it
    # would be an `AttributeError` out of the per-repository loop, losing the whole Review Desk
    # pass for every remaining repository that tick. The same class of fragility `review_of`
    # exists for, found by review of this branch.
    return str(key).lower()


def marker(key: str, mode: str) -> str:
    return f"agent:{key}/{mode}"


# --------------------------------------------------------------------------- clients

def linear(cfg: dict, query: str, variables: dict | None = None) -> dict:
    env = cfg["linear"]["api_key_env"]
    token = os.environ.get(env)
    if not token:
        raise RuntimeError(f"{env} is not set in this shell (source ~/.config/linear-mcp/keys.env)")
    request = urllib.request.Request(
        "https://api.linear.app/graphql",
        data=json.dumps({"query": query, "variables": variables or {}}).encode(),
        headers={"Authorization": token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"linear HTTP {error.code}: {error.read().decode(errors='replace')[:300]}") from None
    if body.get("errors"):
        raise RuntimeError("linear: " + "; ".join(e.get("message", "?") for e in body["errors"]))
    return body["data"]


def gh(*args: str):
    result = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:2])}: {result.stderr.strip()[:300]}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def allele_state(cfg: dict) -> tuple[dict, set]:
    state = json.loads(Path(cfg["allele"]["state_file"]).expanduser().read_text())
    live = {s["id"]: s for s in state.get("sessions", [])}
    archived = {s["id"] for s in state.get("archived_sessions", [])}
    return live, archived


# ----------------------------------------------------------------------------- session groups

# Which named allele group each mode's sessions land in. On 12 October 2026 the `tc-portal`
# project held 56 sessions in one flat list, and finding "the review of PR 9586" meant reading
# every name; `group` on `allele_sessions_create` (allele's DEV-853) puts a session under a named
# section of its project instead.
#
# One group per mode, and nothing else decides it: not the ticket, not its Linear project, not
# its labels. Four modes share `linear` because what a person is looking for is "the agents
# working my tickets" rather than which pass each one is on, and a review lands in `review`
# because a review is the thing most often hunted for by name.
#
# Defaulted here rather than only in `config.example.json`, like every other setting in this
# file, so an instance whose config has never heard of `allele.groups` gets these with no edit.
GROUP_DEFAULTS = {"implement": "linear", "investigate": "linear", "decompose": "linear",
                  "decide": "linear", "review": "review"}

# allele refuses a longer one with an error, so a value over this never reaches a create: the
# dispatch site reads it as ungrouped and `doctor` crosses it. Passing it through would fail
# every create for that mode, and a create that fails after the claim is the one state
# `SKILL.md` says must never be left behind.
MAX_GROUP_LEN = 40


def groups_cfg(cfg: dict) -> dict:
    """The `allele.groups` block with every mode defaulted.

    **`None` is a VALUE here, not an absence**, which is where this differs from `review_cfg`
    and `review_desk_cfg` and why it does not share their one-liner. `"implement": null` is how
    an operator says "dispatch this mode ungrouped", and filtering nulls out the way those two
    do would hand that mode `linear` and quietly ignore the edit.
    """
    block = dict(GROUP_DEFAULTS)
    block.update((cfg.get("allele") or {}).get("groups") or {})
    return block


def group_for(cfg: dict, mode: str) -> str | None:
    """The group a `mode` session is dispatched into, or `None` for ungrouped.

    Trimmed, because allele trims before it matches and a value with a stray space would
    otherwise read as a second group in `doctor`'s line while landing in the first.

    Anything that is not a usable string — a number, a list, a value past `MAX_GROUP_LEN` — is
    read as ungrouped, which is the non-blocking direction, and crossed by `doctor`. That split
    is this file's existing doctrine for a setting somebody can mistype: read it in a way that
    cannot stop a dispatch, and fail in the one command whose job is to fail.
    """
    value = groups_cfg(cfg).get(mode)
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value or len(value) > MAX_GROUP_LEN:
        return None
    return value


def group_problems(cfg: dict) -> list[str]:
    """Every `allele.groups` value that cannot be dispatched as written. For `doctor`.

    Reads the raw block rather than `groups_cfg`, because a default is never a problem and a
    mode nobody has configured must not be reported as one.
    """
    said = []
    for mode, value in sorted(((cfg.get("allele") or {}).get("groups") or {}).items()):
        if value is None:
            continue
        if not isinstance(value, str):
            said.append(f"allele.groups.{mode} is {value!r}, not a string — it is being read as "
                        f"ungrouped; use null to mean that on purpose")
        elif len(value.strip()) > MAX_GROUP_LEN:
            said.append(f"allele.groups.{mode} is {len(value.strip())} characters, and allele "
                        f"refuses anything over {MAX_GROUP_LEN} — it is being read as ungrouped")
    return said


# ------------------------------------------------------------------------------- review mode

# How a review worker works, independently of Review Desk. `blind_options_pass` is the step that
# dispatches one session given the numbered problems and an export of the base commit and nothing
# else, before the diff is read in depth — `workers/review.md` step 3, taught in `review-craft`'s
# `understand.md`.
#
# **Deliberately not under `review_desk`.** The pass runs with Review Desk missing, off or broken,
# and burying its switch under an optional integration's block would make it unreachable on the
# instances most likely to want it. Defaulted here, like every other setting in this file, so an
# instance whose config has never heard of the block behaves as though it said `true`.
#
# There is no size threshold and there is not going to be one: a ten-line change can have
# catastrophic consequences, which is the whole argument for reading the problem before the diff.
REVIEW_DEFAULTS = {"blind_options_pass": True}


def review_cfg(cfg: dict) -> dict:
    """The `review` block with every key defaulted. `None` is treated as absent, as elsewhere."""
    block = dict(REVIEW_DEFAULTS)
    block.update({k: v for k, v in (cfg.get("review") or {}).items() if v is not None})
    return block


# --------------------------------------------------------------------------- review desk

# Review Desk (devergehq/review-desk) keeps the record of a review: the brief, the options, the
# findings and the draft. It is optional, and the three rules its own brief states govern every
# line below: one way in (the command line), one direction of dependency (Locus calls it; it
# never calls Locus), and **absent is silent, broken is loud**.
#
# Nothing here may block. A review must be preparable with Review Desk missing, too old,
# refusing or hanging, and the fallback is always the behaviour this file had before it existed.
REVIEW_DESK_DEFAULTS = {"mode": "auto", "command": "review-desk",
                        "url": "http://127.0.0.1:7777", "brief_gate": "never"}

REVIEW_DESK_MODES = ("auto", "on", "off")
REVIEW_DESK_GATES = ("never", "always")

# The five kinds `work list` answers with, spelled as Review Desk 0.1.0 names them in
# `crates/store/src/model.rs`. A kind from a NEWER Review Desk is still ignored rather than
# guessed at — this file would have no idea what an agent is supposed to do about it, and
# inventing a dispatch for a kind it has never heard of is worse than leaving it listed — but it
# is no longer ignored *silently*: see `Poller.unknown_kind`.
#
# `nits_to_ticket` is the one this file was missing. The developer asks, on the draft page, for
# the findings they held back to be filed as one ticket; Review Desk files nothing and reports
# the request here. Four names meant that request reached no session and said nothing about
# itself, which is DEV-934.
REVIEW_DESK_KINDS = ("review_requested", "brief_settled", "draft_sent_back", "draft_approved",
                     "nits_to_ticket")

# Kinds this file has read and deliberately does nothing with. **Empty, and load-bearing empty.**
# It is the difference between "this one was considered and is not ours" and "nobody here has
# heard of this", which is the only distinction `unknown_kind` can act on: a kind named here is
# silent, and every other unhandled kind is loud. `nits_to_ticket` was in neither list for five
# weeks, and nothing in a running dispatcher could say so.
REVIEW_DESK_IGNORED_KINDS: tuple[str, ...] = ()

# The four a WATCHER relays to the session already working the review. `review_requested` is
# deliberately absent: a session reading its own review does not need telling to start.
REVIEW_DESK_WATCH_KINDS = ("brief_settled", "draft_sent_back", "draft_approved",
                           "nits_to_ticket")

# How long a Review Desk call may take before it is called broken. Generous against a cold
# SQLite file on a laptop, and short enough that a hung binary cannot stall a poll tick.
REVIEW_DESK_TIMEOUT = 30

# The prefix `review_desk_detail` puts on clap's own refusal, which is how an OLDER Review Desk
# says it has never heard of a flag. `main.rs` in the Review Desk checkout remaps clap's usage
# exit to 1 and gives the document the code `usage`, so a refusal reading like this one is the
# only refusal in this file that means "too old for that argument" rather than "no".
#
# Read off the detail string rather than the document because `review_desk_run` hands back a
# detail and not a payload on a non-zero exit, and `review_desk_detail` below composes that
# detail as `f"{code}: {message}"`. Measured against a binary built from review-desk 0e0bf1b:
# `{"error":{"code":"usage","message":"error: unexpected argument '--ledger' found ..."}}`.
REVIEW_DESK_USAGE_REFUSAL = "usage:"

# The same fact read a second way, for the case the prefix above cannot cover. The prefix holds
# when Review Desk answers `--json` with its own error document — measured at 82c0a09 for both
# an unexpected argument and an unrecognised SUBCOMMAND, both on stdout with `code: usage` — but
# a wrapper script, or a build whose `--json` handling predates that document, can let clap's
# own text out instead, and then the detail is the raw line rather than `usage: …`. Both of
# clap's shapes are named here because mistaking either for an ordinary refusal is the
# difference between "this build cannot do that" and "that request was refused", and this file
# acts very differently on the two.
REVIEW_DESK_UNKNOWN_TEXT = ("unrecognized subcommand", "unexpected argument",
                            "unrecognised subcommand")


def review_desk_unknown(detail: str) -> bool:
    """Is this refusal Review Desk saying it has never heard of what it was asked?"""
    lowered = (detail or "").lower()
    return (lowered.startswith(REVIEW_DESK_USAGE_REFUSAL)
            or any(shape in lowered for shape in REVIEW_DESK_UNKNOWN_TEXT))

# And the one refusal that means "there is no such review". `review_desk_run`'s own docstring
# says an unknown review id is the only refusal this file asks for on purpose, so every OTHER
# refusal — a locked database, a validation this file has not met — must not be read as a
# record that has been deleted. Read off review-desk's `error.code` for a missing row, the same
# code its `work list --review` refuses an unknown id with.
REVIEW_DESK_MISSING_REFUSAL = "not_found:"

# `harvest` gets its own, and the reason is that it is the one Review Desk command that is not a
# local read: it asks GitHub for every open pull request a posted review is waiting on, so its
# duration is a function of the network and of how many reviews a repository has, where every
# other call here is a SQLite query. Sized against the budget it has to fit inside rather than
# against a measurement nobody has: ONE harvest runs per poll tick (see `Poller.harvest`), so the
# worst case a tick can absorb is this number, and 120s sits inside the shipped
# `poll_interval_secs` of 300 with room for the rest of the tick.
#
# A harvest killed at the timeout is reported broken and retried on the next interval, and that
# is safe rather than merely tolerable: Review Desk's own README has it recording nothing twice,
# so a half-finished harvest is a harvest that recorded less, never one that recorded wrongly.
HARVEST_TIMEOUT = 120

# How often one repository is harvested, when `limits.harvest_interval_secs` does not say.
# A harvest records what became of findings on a review that is already posted — a reply, a
# resolved thread, a line changed since — so nothing is waiting on it the way a session waits on
# a sign-off. Fifteen minutes is `reemit_after_secs`, which is the cadence everything else in
# this file that is "soon enough" already uses.
HARVEST_INTERVAL_SECS = 900

# How often a review session's watcher reads Review Desk while its review's draft is waiting on
# the developer, when `limits.draft_watch_interval_secs` does not say. The first sign-off posted
# for real waited 4m28s behind a 300s `watch_interval_secs`; twenty seconds is short enough that
# the wait reads as the click taking effect, and long enough that the two local reads it costs
# are nothing. It is never read as LONGER than `watch_interval_secs` — see `watch_interval`.
DRAFT_WATCH_INTERVAL_SECS = 20

# The draft status that means the developer, and nobody else, is what the review is waiting for.
# Review Desk stores five — `drafting`, `ready`, `approved`, `sent_back`, `posted`
# (`crates/store/src/migrations.rs`) — and only this one is a draft the session has finished and
# handed over. `drafting` is the session still writing; the other three are all answered.
DRAFT_WAITING = "ready"


def review_desk_cfg(cfg: dict) -> dict:
    """The `review_desk` block with every key defaulted.

    **An instance whose config.json has never heard of Review Desk needs no edit.** The defaults
    live here rather than in `config.example.json` alone, so a missing block is exactly `auto`
    and an existing instance picks this version up by upgrading the plugin and nothing else.
    `init` writes the block as well, so it is there to edit, but it is never required.

    An unknown `mode` is left verbatim and read as `auto` at every decision site, which is the
    silent and non-blocking direction — a typo must not stop reviews. `doctor` is where it is
    named, because `doctor` is the command whose job is to fail.
    """
    block = dict(REVIEW_DESK_DEFAULTS)
    block.update({k: v for k, v in (cfg.get("review_desk") or {}).items() if v is not None})
    return block


def harvest_interval(cfg: dict) -> int:
    """`limits.harvest_interval_secs`, defaulted here so no existing instance needs an edit."""
    return positive_secs((cfg.get("limits") or {}).get("harvest_interval_secs"),
                         HARVEST_INTERVAL_SECS)


def review_desk_off(rd: dict) -> bool:
    return rd.get("mode") == "off"


def review_desk_loud_when_absent(rd: dict) -> bool:
    """Only `on` is loud about an absent Review Desk. Every mode is loud about a broken one."""
    return rd.get("mode") == "on"


def review_desk_link(rd: dict, review_id, draft: bool = False) -> str | None:
    """The dashboard address of one review, or of its draft — the two pages a developer acts on.

    Taken from `web/app/pages` in the Review Desk checkout: `/reviews/<id>` is where a brief is
    confirmed and `/reviews/<id>/draft` is where a draft is approved. `url` is for putting in a
    message and for `doctor`'s reachability line; **nothing in this file drives the dashboard's
    API**, and a session that tried would be reaching for the one surface only the developer may
    use.
    """
    base = (rd.get("url") or "").rstrip("/")
    if not base or review_id is None:
        return None
    return f"{base}/reviews/{review_id}/draft" if draft else f"{base}/reviews/{review_id}"


def review_desk_detail(text: str) -> str:
    """The `message` out of a `--json` refusal, so a loud line says something a person can use."""
    try:
        payload = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return ""
    error = (payload or {}).get("error") or {}
    code, message = error.get("code"), error.get("message")
    return f"{code}: {message}" if code and message else (message or "")


def review_desk_run(rd: dict, *args: str, json_out: bool = True,
                    timeout: int = REVIEW_DESK_TIMEOUT) -> tuple[str, object, str]:
    """Run one Review Desk command. Never raises, and never blocks a review.

    Returns `(state, payload, detail)`, where state is one of:

      `ok`       exit 0. `payload` is the parsed document, or the stripped text when
                 `json_out` is False (`--version` is not JSON, and says so in Review Desk's own
                 README).
      `refused`  exit 1 — understood and refused. An unknown review id is the only refusal this
                 file asks for on purpose.
      `broken`   exit 2, a timeout, an unreadable answer, or any other exit code. Review Desk's
                 README pins 2 to "could not run" and remaps clap's own usage exit to 1, which
                 is what makes this tri-state readable without parsing prose.
      `absent`   the command does not resolve on this machine.

    `subprocess.run` on an argv LIST, never a shell: `command` is a config value, and a config
    value reaching a shell is an injection with a straight face.
    """
    argv = [rd.get("command") or REVIEW_DESK_DEFAULTS["command"], *args]
    said = " ".join(args[:2]) or argv[0]
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (FileNotFoundError, NotADirectoryError):
        return "absent", None, f"{argv[0]} is not on PATH"
    except subprocess.TimeoutExpired:
        return "broken", None, f"{argv[0]} {said} did not answer in {timeout}s"
    except OSError as exc:
        # Installed and unusable — not executable, wrong architecture. A broken install, which is
        # loud in every mode, and emphatically not the silent `absent`.
        return "broken", None, f"{argv[0]} could not be run: {exc}"
    text = (done.stdout or "").strip()
    fallback = (done.stderr or "").strip() or text
    if done.returncode == 0:
        if not json_out:
            return "ok", text, ""
        try:
            return "ok", json.loads(text) if text else None, ""
        except json.JSONDecodeError:
            return "broken", None, (f"{argv[0]} {said} exited 0 with output that is not JSON — "
                                    f"too old to use: {text[:160]}")
    state = "refused" if done.returncode == 1 else "broken"
    return state, None, (review_desk_detail(text) or fallback[:200]
                         or f"{argv[0]} {said} exited {done.returncode}")


def canonical_repo(repo: str) -> str:
    """A repository as Review Desk stores it: trimmed and lower-cased.

    **`review find` does not normalise its `--repo` and every other call here does, which is
    how the look before the first write came to be dead on half the instances that have one.**
    Measured against review-desk 82c0a09: `review open --repo Trilogy-Care/tc-portal` stores
    `trilogy-care/tc-portal`, `work list --repo Trilogy-Care/tc-portal` finds it, and
    `review find --repo Trilogy-Care/tc-portal` answers `reviews: []` — echoing the query back,
    so the mismatch is invisible in the answer. GitHub hands this file `nameWithOwner` as the
    repository is registered, and `Trilogy-Care/tc-portal` is the live instance's own slug, so
    the look answered "no review here" for every request on it and the blind write it exists to
    prevent happened anyway.

    `review_desk_repos` has said this for its own callers since DEV-865 — "`DevergeHQ/Locus`
    from a config would answer with an empty list and read as nothing waiting" — and the lesson
    is the same one: send the canonical form, never the spelling you were handed.

    **`review find` normalises its own `--repo` from review-desk 4c05319, and this stays.** The
    measurement above was taken at 82c0a09 and is still true of it; a dispatcher ships to
    whatever build is installed, so what was load-bearing against one build is belt and braces
    against the next, and the canonical form is the right thing to send either way.
    """
    return (repo or "").strip().lower()


def same_commit(a, b) -> bool:
    """Are these the same commit, however the two sides spell it?

    **The two sides are not always the same side.** GitHub answers `headRefOid` as the object is
    named; Review Desk normalises what it stores — `normalise::head_sha` trims and lower-cases —
    and the poller's record can hold either, because it is seeded by a look at Review Desk
    before the first write and by GitHub's own value after one. Comparing them as strings made
    any case difference read as "the commit moved", on every tick, for ever: one `review open`
    WRITE per tick, which is the `last_activity_at` churn the once-per-commit rule exists to
    prevent. Normalising the comparison holds the rule whichever spelling the record happens to
    carry, which a rule about what to STORE could not.
    """
    return (a or "").strip().lower() == (b or "").strip().lower()


def review_id(value) -> int | None:
    """A Review Desk review id as an int, from wherever it came from, or None.

    **Two sources spell it differently and both are legitimate.** Review Desk answers `id` as a
    number; the LEDGER carries `review_desk_id` as whatever `D ledger put review_desk_id=7` was
    given, which is the string `"7"`. `Watcher.review_desk` already copes by calling `str()` on
    it, and this is the same coping in the other direction. `bool` is excluded first because it
    is an `int` in Python and `True` is not review 1.
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def review_of(payload) -> dict | None:
    """The `review` object out of a Review Desk document, or None if there is not one.

    **The `isinstance` is the point of the function.** `review_desk_run` hands back anything that
    PARSES, so a document that is a top-level array or a string — an older build, a wrapper
    script, a shell that printed something before the JSON — would make `payload.get` an
    `AttributeError` in the middle of a poll tick. On this path that would throw out of
    `review_requests` and emit no review request at all that tick, every tick: the opposite of
    what every other answer from a strange build does here, which is to be called broken, said
    once, and dispatched around. `review_desk_work` type-checks its own array for the same
    reason and `cannot_be_told` names the failure in as many words.
    """
    if not isinstance(payload, dict):
        return None
    review = payload.get("review")
    return review if isinstance(review, dict) else None


def review_desk_work(rd: dict, *narrow: str) -> tuple[str, list, str]:
    """`work list`, which is the found test and the answer in the same call.

    **There is no cached "is Review Desk installed" flag anywhere in this file, and that is the
    design rather than an omission.** The required behaviour is that found-ness survives neither
    a broken install being fixed nor a working one breaking, and a cache with a time-to-live
    fails in both directions for as long as the window lasts. The cheap way to get that is not a
    shorter window: it is to make the probe BE the call the caller was going to make anyway. The
    poller lists work per repository, the watcher lists its own review, and each of those calls
    answers "is it there" on the way past, at no extra cost and with no staleness at all. What
    this file does remember is only whether the loud line has been said lately, which is a fact
    about the Dispatcher's inbox rather than about the install.

    A `refused` without `--review` is read as **broken**, which is the "too old to use" case the
    ticket asks for. Review Desk remaps a usage error to 1, so an older binary with no
    `work list` subcommand refuses exactly here — and there is nothing for it to legitimately
    refuse when no review id was given. With `--review`, exit 1 means that review is gone, which
    is a real condition and is handed back as `refused` for the caller to report.
    """
    state, payload, detail = review_desk_run(rd, "work", "list", "--json", *narrow)
    if state == "refused" and "--review" not in narrow:
        return "broken", [], (detail or "`work list` was refused with no --review to refuse — "
                                        "this Review Desk is too old to use")
    if state != "ok":
        return state, [], detail
    items = (payload or {}).get("work")
    if not isinstance(items, list):
        return "broken", [], ("`work list --json` answered without a `work` array — "
                              "this Review Desk is too old to use")
    return "ok", items, ""


def review_desk_repos(cfg: dict, ledger: dict) -> list[str]:
    """The repositories this instance serves, spelled the way Review Desk stores them.

    `allele.repo_project_map` is the config's own statement of which repositories this dispatcher
    serves, and it is the first source. The template's `OWNER/REPO` placeholder is dropped: an
    instance that never edited it serves no repository, and asking Review Desk about a literal
    `OWNER/REPO` is a call that could only ever answer with an empty list.

    Every repository named on a ledger entry is added as well, so a dispatcher that has reviewed
    a repository keeps hearing about it whether or not the map was ever filled in — which
    matters most for the case this whole section exists for, a review whose session is gone.
    The cost is bounded by the number of DISTINCT repositories a person reviews, not by the
    number of entries, so it is two or three calls a tick rather than one per ledger file.

    Lowercased, because Review Desk stores `repo` canonical — trimmed and lowercased, as its
    README says — and matches `--repo` against the stored form. `DevergeHQ/Locus` from a config
    would answer with an empty list and read as nothing waiting.
    """
    repos = {r.strip().lower() for r in (cfg.get("allele") or {}).get("repo_project_map") or {}}
    for entry in ledger.values():
        repos.add((entry.get("repo") or "").strip().lower())
    return sorted(r for r in repos if r and r != "owner/repo")


def review_desk_live(live: dict, entry: dict) -> bool:
    """Is a session this instance dispatched still working this key?

    Review Desk refuses to judge this and says so in as many words — "it does not judge whether
    a session is alive. Allele owns that, and Review Desk is not told." So the judgement is made
    here, from the two things this instance owns: its own ledger and allele's state file. Both
    are needed, and the existing `ALIVE` set is exactly the right one rather than a new one:

      * `ALIVE` includes `done`, and that is load-bearing. A review worker writes `done` when
        its draft is ready and then STAYS UP with its watcher running, which is what lets it
        hear the approval. Treating a `done` key as dead would dispatch a second session
        alongside a live one holding the same draft.
      * A `blocked` entry is in `WORKING` and has no session by design, so it falls out on the
        `sid in live` test rather than needing a special case.
      * A working status whose session allele no longer lists is the `session_lost` shape, and
        calling it alive would leave an approved draft unposted for as long as the ledger lied.
    """
    sid = entry.get("session_id")
    return bool(sid) and entry.get("status") in ALIVE and sid in live


# --------------------------------------------------------------------------- ledger

def ledger_path(key: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", key):
        raise SystemExit(f"bad ledger key: {key}")
    return ledger_dir() / f"{key}.json"


def ledger_get(key: str) -> dict | None:
    return read_json(ledger_path(key), None)


def ledger_all() -> dict[str, dict]:
    """Every ledger entry, skipping any file that will not parse.

    `read_json` catches `FileNotFoundError` and nothing else, so one truncated or hand-edited
    entry raised `JSONDecodeError` out of here — and `tick()` calls this OUTSIDE the per-section
    try whose whole purpose is that "one failing source must never kill the poller". A single
    bad file therefore took down `children`, `list`, `status` and the poller together.

    Skipped rather than raised: the other entries are still true, and a recovery is the worst
    moment to have every command refuse. The entry is named on stderr so it is not silent.
    """
    if not ledger_dir().exists():
        return {}
    entries = {}
    for path in sorted(ledger_dir().glob("*.json")):
        try:
            entries[path.stem] = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            print(f"warning: skipping unreadable ledger entry {path.name}: {exc}", file=sys.stderr)
    return entries


def ledger_put(key: str, fields: dict, note: str | None = None, by: str | None = None) -> dict:
    """Merge fields into one ledger entry, under a lock.

    The lock is not belt and braces. This is a read-modify-write over a whole JSON document,
    and two sessions legitimately write one key: a coordinator setting `parent=` on a child at
    claim time, and the Dispatcher writing `status=lost` at the same child from its own handler.
    Unlocked, and with no entry on disk yet, both start from a fresh dict and the loser's fields
    do not merge — they are **gone**. Demonstrated with a deterministic interleaving: the
    coordinator's `mode` and `parent` both vanished, leaving `status=lost`, which is
    REDISPATCHABLE. That child is then invisible to `ledger children`, invisible to `SKILL.md`'s
    presence-of-`parent` guard, and passes `stack.v2.md` §6's lock — so it gets a second session
    on its own live branch, which is the exact failure the `parent` field exists to prevent.

    `flock` on a sidecar, held across the read and the write, because the write itself is an
    `os.replace` of a different inode and cannot be locked usefully. Advisory and POSIX-only,
    which is the platform this ships on; a lock that cannot be taken is not worth failing a
    ledger write over, so an OSError falls through to the old unlocked behaviour.
    """
    path = ledger_path(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = path.with_name(f".{path.name}.lock")
    try:
        handle = open(lock, "w")
    except OSError:
        handle = None
    try:
        if handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
        entry = ledger_get(key) or {"key": key, "created_at": now_iso(), "history": []}
        changed = {k: v for k, v in fields.items() if entry.get(k) != v}
        entry.update(fields)
        entry["updated_at"] = now_iso()
        if changed or note:
            record = {"at": entry["updated_at"]}
            if by:
                record["by"] = by
            if changed:
                record["set"] = changed
            if note:
                record["note"] = note
            entry["history"].append(record)
        write_json(path, entry)
        return entry
    finally:
        if handle:
            handle.close()


def working_count() -> int:
    return sum(1 for e in ledger_all().values() if e.get("status") in WORKING)


# --------------------------------------------------------------------------- poll

# `team_key` was in config and in nothing else, so the scope read as team-wide and behaved as
# workspace-wide. It was protected only by the accident that the Agent labels happened to belong
# to one team: an unscoped assignee+label query against a real workspace returns issues from
# every team the user is assigned on. Setting team_key now means what it says. Leaving it null
# keeps the old workspace-wide behaviour, deliberately and visibly.
TRIGGERS_Q = """
query($labels: [ID!]%s) {
  issues(first: 50, filter: {
    assignee: { isMe: { eq: true } },%s
    labels: { some: { id: { in: $labels } } },
    state: { type: { nin: ["completed", "canceled"] } }
  }) {
    nodes { identifier title url team { key } project { name } labels { nodes { id } } }
  }
}"""


def triggers_query(team_key: str | None) -> tuple[str, dict]:
    if team_key:
        return TRIGGERS_Q % (", $team: String!", "\n    team: { key: { eq: $team } },"), {"team": team_key}
    return TRIGGERS_Q % ("", ""), {}

# The review query's page size, named because two places must agree about it: the query asks for
# this many, and `review_requests` treats `issueCount` exceeding a FULL page as truncation. With the
# number written twice, a change to one would silently turn the truncation check into a check on any
# count/hit-list disagreement -- which fires outside truncation and, before the union commit below,
# had a cost.
REVIEW_PAGE = 50

REVIEWS_Q = """
query($q: String!) {
  search(query: $q, type: ISSUE, first: %d) {
    issueCount
    nodes { ... on PullRequest {
      number title url isDraft headRefOid createdAt author { login } repository { nameWithOwner }
    } }
  }
}""" % REVIEW_PAGE


class Poller:
    def __init__(self) -> None:
        self.state = read_json(poll_state(), {})
        for bucket in ("emitted", "once", "blocked", "errors"):
            self.state.setdefault(bucket, {})
        self.state.setdefault("prs_present", None)
        # State written before backlog tracking existed: whatever was already pending is backlog.
        self.state.setdefault("review_backlog", sorted(self.state["prs_present"] or []))
        # Which review request is recorded in Review Desk, and on which head commit: the key for
        # the pull request, against the commit the recording was of. See `record_request` for why
        # it is remembered at all, and `review_requests` for where it is pruned.
        self.state.setdefault("recorded", {})
        # Keyed on THIS PROCESS, and never on the state file. `started` is persisted, so reading
        # it made `backlog` true once per instance LIFETIME instead of once per session: the
        # `tc-portal` instance carried "2026-09-11T13:18:11+00:00" for 19 days, and SKILL.md step 4's
        # whole start-up contract -- list the review backlog, ask before dispatching -- was
        # unreachable dead code for every one of them (DEV-794). A fresh `Poller` is a fresh
        # session's eyes, so the first tick of the process is the first tick, full stop.
        #
        # This is also the answer to the migration question, and the answer is that there is
        # nothing to migrate. Every instance already carrying a poisoned `started` is fixed by its
        # next arm. The two alternatives both cost more and buy less: a version marker has to
        # interpret the poisoned key and leaves a fork in behaviour between instances created
        # before and after the fix, and a separate session-scoped field needs a session identity
        # that nothing in the sanctioned host can supply -- `Monitor` does not hand the command one.
        #
        # `started` is still written below, as write-only provenance -- when this instance's poller
        # first ran -- so nothing that reads it breaks and the 11 Sep date stays on disk as the
        # evidence for this bug.
        #
        # The cost, stated because it is real rather than hidden: a host that re-arms the poller
        # announces a backlog on each arm, and so does every run of a host that drives
        # `poll --once` on a cadence.
        #
        # Not on every tick, though, and the difference is worth being exact about because the
        # first draft of this comment got it wrong. `due()` gates emission at
        # `reemit_after_secs`, so a given key is announced at most once per that window however
        # often the poller runs. Measured over three consecutive fresh processes inside one
        # window: run 1 emitted the `review_request`, runs 2 and 3 emitted none. What fires on
        # every run is `poller_started`, not the backlog list.
        #
        # That second host is not hypothetical. As of 30 September 2026 it is the PRODUCTION one:
        # the principal stopped hosting the poller under `Monitor` -- the arrangement this ticket
        # is about -- and drives `poll --once` in the foreground instead, "until we can guarantee
        # that the monitor has some rigor to it and we can start to trust it again". Under that
        # host every unclaimed review request reads as `backlog: true`, so none of them
        # auto-dispatches and each one needs a human decision.
        #
        # That is chosen here rather than merely tolerated, because it is exactly what the
        # Dispatcher is already doing by hand -- and by hand means from memory, which is the
        # failure mode the contract exists to remove. `review_backlog` is pruned at the end of
        # every `review_requests` pass to keys that are still present AND still unclaimed, so what
        # a fresh process re-asks about is the set nobody has decided on yet.
        #
        # If the automatic path is ever wanted back under a per-tick host, the flag needs a session
        # identity supplied by the caller, and the reason none is available today is the second row
        # of the migration table on the pull request.
        self.first_tick = True
        # Separate from `first_tick`, which `--no-backlog` may switch off. This one records that a
        # new process ran at all, and nothing may suppress it: raised in review after a session whose
        # FIRST call carried `--no-backlog` auto-dispatched three requests and emitted no
        # `poller_started`, leaving nothing downstream aware that a process had run with the policy
        # off. A policy nobody can observe is barely better than one nobody chose.
        self.announced = False
        # Reset per tick; here as well so a test that calls one section directly does not have
        # to know that `tick()` is what creates it.
        self.pr_states: dict = {}
        # Every review request GitHub showed this tick, whatever its ledger status, **held
        # lower-cased**. Read by `request_spoken_for` so that one request reaches the Dispatcher
        # once. See `requested_key` for why the case has to be taken off it.
        self.requested: set = set()
        # Whether recording review requests has been given up on for this tick. One install
        # answers for every request, so an absent or broken one is asked once. See
        # `record_request`.
        self.record_stopped = False
        # And whether READING a request's dismissal has been given up on: a build with no
        # `review show` refuses every one of them, and asking per recorded request would be a
        # subprocess per request per tick for ever. Separate from `record_stopped` because such
        # a build records perfectly well — it is only the dismissal it cannot be asked about.
        self.read_stopped = False
        # Whether the install answering this tick refused `--ledger`, which dates it before the
        # move as well. See `record_request`.
        self.record_old = False
        # Whether LOOKING before the first write has been given up on for this tick: a build
        # with no `review find` answers the same way for every request, and the recording goes
        # on without the look rather than stopping. See `find_request`.
        self.look_stopped = False
        # Whether the read failed because the BUILD cannot answer it — no `review show`, or an
        # answer carrying no review — as against a transient failure. It decides one thing: a
        # final answer keeps the re-ask window (asking again next tick would learn the same
        # thing for ever), and a transient one clears it so the next tick tries again.
        self.read_unsupported = False
        # The install-level failures the recording path met this tick, keyed by the COMMAND that
        # met them: `{"review open": (state, detail, repo), …}`. Kept rather than said on the
        # spot so that one place decides how they are reported — see `record_unreachable`, which
        # shares the `review_desk` pass's rate-limit mark so one fault is one line.
        #
        # Keyed rather than a single slot because this file and SKILL.md both promise one line
        # per call: a hung install can break the write on one key and the read on the next, and
        # a single slot kept whichever came last — silently dropping the other, which was
        # usually the read, which is the dismissal guard.
        self.record_broken: dict = {}

    # Rate-limited emission: the same marker fires at most once per `every` seconds.
    def due(self, mark: str, every: int) -> bool:
        last = self.state["emitted"].get(mark)
        if last and time.time() - last < every:
            return False
        self.state["emitted"][mark] = time.time()
        return True

    # One-shot emission: fires once until the marker is cleared.
    def once(self, mark: str) -> bool:
        if mark in self.state["once"]:
            return False
        self.state["once"][mark] = now_iso()
        return True

    def record_error(self, section: str, exc: Exception) -> None:
        """Record a thrown section where stdout reaching a reader is not a precondition.

        Two destinations, both unconditional, because the rate limit in `error()` is a courtesy to
        the Dispatcher's event stream and not a reason to lose the record:

          stderr                       the host's own log. Under `Monitor` that is the task's
                                       output file; under background Bash, the redirect.
          runtime/poller-errors.jsonl  outlives the host. Appended and closed per record, and
                                       BEFORE `tick()` reaches its state write, so a section that
                                       throws followed by a process that dies still leaves the
                                       reason on disk. `state["errors"]` cannot do that: it is only
                                       the rate-limit clock, and it is written once at end of tick.

        DEV-794 is what this absence cost. `error()` reported a thrown section by emitting on the
        same stdout that may be the broken thing, at most once per signature per 1800s with the
        timestamps persisted ACROSS sessions -- so a failure repeating for a week could report
        twice an hour, to nobody, and leave no trace anywhere else. The one question that ticket
        could not settle from the evidence it had -- "is a section throwing and being swallowed?"
        -- is a question this file answers by existing.
        """
        print(f"poller: {section} failed: {type(exc).__name__}: {str(exc)[:200]}",
              file=sys.stderr, flush=True)
        record = {"at": now_iso(), "section": section,
                  "error": f"{type(exc).__name__}: {exc}"[:400],
                  "traceback": traceback.format_exc()[-1200:]}
        try:
            path = error_log()
            path.parent.mkdir(parents=True, exist_ok=True)
            # Keep the tail: the newest failure is the one being diagnosed. The slice is in
            # characters against a cap in bytes, which is deliberate slack -- this is a guard
            # against filling a disk, not an accounting of one -- and the partial first line the
            # slice lands in is dropped rather than left as unparseable JSON.
            if path.exists() and path.stat().st_size > ERROR_LOG_MAX_BYTES:
                tail = path.read_text(errors="replace")[-(ERROR_LOG_MAX_BYTES // 2):]
                path.write_text(tail.split("\n", 1)[-1] if "\n" in tail else "")
            with path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(record, ensure_ascii=False) + "\n")
        except Exception:
            # Failing to record a failure must never be the thing that kills the poller. stderr
            # has already carried it by this point, so the record is degraded, not lost.
            pass

    def trust_empty(self, source: str, count: int, matched: int | None = None) -> bool:
        """Is an empty result from `source` the truth, or the source failing quietly?

        Returns True when the caller may act on `count` as fact — which for an empty result means
        committing the destructive state that follows from "nothing is there".

        DEV-799. Both sources used to treat an empty result as an empty world. On the review side
        that cleared live reviews with the reason "review request removed", re-emitted a PR the
        principal had **skipped** as `rerequested`, and dropped a start-up item's backlog flag so it
        would auto-dispatch — which silently undoes DEV-794's fix. On the Linear side it deleted
        every trigger marker. Nothing threw and nothing was recorded, so the tick committed the
        emptiness as fact and the next tick could not tell.

        **One test decides it: an empty result is believed only on the second consecutive zero.**
        Everything vanishing in one tick is far more often a flaky index than a real emptying, and
        the cost of believing it a tick late is one tick of staleness against a false
        `review_cleared`. A source that has never returned anything is believed at once — a fresh
        instance with no open reviews must not sit in a suspicious state forever — and that case is
        carried by `last_nonempty_at` being absent, not by any special-casing of the count.

        `matched` (GitHub's `issueCount`) then sharpens it in one direction only: `matched > 0` with
        `count == 0` is the search telling us it matched work and returned none of it, which is not
        a fact about the world at any streak length and is never believed.

        **An earlier version of this method also believed `matched == 0` at once, and that was a
        blocker found in review.** The reasoning was that GitHub had affirmatively said "nothing
        matched", so it was a fact. It is not: `issueCount` and `nodes` are computed from the same
        query against the same eventually-consistent index, so a stale index returns `0` for both —
        which is precisely the shape this method exists to catch, and the short-circuit waved it
        through. Executed against the guarded source, an `issueCount: 0` tick reproduced all four
        DEV-799 harms verbatim. The stated cost of removing it was also wrong: the claim was that a
        genuinely-emptied instance would "sit one tick behind forever", when the second zero
        believes, so the cost is one tick once. **Do not reinstate it without a captured
        `(issueCount, len(nodes))` pair from a degraded response showing the two disagree.**

        **On pagination, measured rather than assumed.** `issueCount` is the TOTAL number of matches,
        not the size of the page: against the live review query on 30 September 2026, `first: 1`
        returned `{"issueCount": 11, "returned": 1}` and `first: 50` returned
        `{"issueCount": 11, "returned": 11}`. So `matched > count` on a full page is ordinary
        truncation rather than a failing search — handled by the caller, which refuses the
        destructive commit for a different reason (see `review_requests`) — while `matched > 0` with
        `count == 0` is unreachable by pagination, because page one of a non-empty match always
        carries `min(page, count)` items.

        **This guard is per process only in the sense that its code is.** `zero_streak` is persisted
        in `poll-state.json`, so under a host that runs `poll --once` on a cadence the streak
        accumulates across runs, which is what makes the second-zero rule work there at all. What
        does not carry is the guard itself: an orphaned poller can outlive the plugin version that
        started it — one process reaped on 30 September 2026 was running locus 0.5.2 against this
        same instance — and a poller without this method commits an empty result as fact. The
        `sources` bucket's *keys* survive such a poller, because it reads the whole state file and
        writes it back; its *values* can be rolled back to that poller's read-time snapshot, because
        `poll_state()` takes no lock across the read-modify-write where `ledger_put` explicitly
        does. Nothing here can fix that; DEV-795 owns the lifecycle.
        """
        seen = self.state.setdefault("sources", {}).setdefault(source, {})
        if count:
            seen.update(last_count=count, last_at=now_iso(), last_nonempty_at=now_iso(),
                        zero_streak=0)
            return True
        streak = seen.get("zero_streak", 0) + 1
        seen.update(last_count=0, last_at=now_iso(), zero_streak=streak)
        if matched:
            # `matched` is truthy only when the source both reported a count and returned nothing.
            # No rate limit on the decision, only on the telling: the decision must be made every
            # tick or the destructive commit slips through on the quiet ones.
            if self.due(f"{source}|matched_not_returned", 900):
                emit("source_empty", source=source, matched=matched, returned=0, believed=False,
                     last_nonempty_at=seen.get("last_nonempty_at"),
                     reason=f"{source} matched {matched} and returned 0 — treating as a fault")
            return False
        if streak == 1 and seen.get("last_nonempty_at"):
            # Deliberately reached for BOTH `matched == 0` and `matched is None`. The distinction
            # between them — `None == 0` is False in Python, so a source with no count at all, such
            # as Linear, has only this test — no longer selects between code paths, and that is the
            # point: after the blocker above, an affirmative zero and an absent count are treated
            # identically, because neither is evidence that the world is empty.
            emit("source_empty", source=source, matched=matched, returned=0, believed=False,
                 last_nonempty_at=seen.get("last_nonempty_at"),
                 reason=f"{source} returned 0 after a non-empty tick — waiting for a second")
            return False
        return True

    def error(self, section: str, exc: Exception) -> None:
        self.record_error(section, exc)
        sig = f"{section}:{str(exc)[:80]}"
        last = self.state["errors"].get(sig)
        if not last or time.time() - last > 1800:
            self.state["errors"][sig] = time.time()
            emit("error", section=section, message=str(exc)[:400])

    def tick(self) -> None:
        said = _emitted
        cfg = load_config()
        ledger = ledger_all()
        backlog = self.first_tick
        # Per TICK, not per process: a pull request merged between two polls must be seen as
        # merged on the second. One `gh pr view` per Review Desk item would otherwise be one per
        # item per tick, and the answer cannot change inside a tick.
        self.pr_states = {}
        # Both per tick, and both about this tick's two review sources agreeing: what GitHub
        # showed, and whether Review Desk is still worth asking. `review_requests` fills the
        # first and `review_desk` reads it, which is why the section order below is not
        # arbitrary.
        self.requested = set()
        self.record_stopped = False
        self.read_stopped = False
        self.read_unsupported = False
        self.look_stopped = False
        self.record_old = False
        self.record_broken = {}
        # `review_requests` runs BEFORE `review_desk`, and since DEV-945 that order carries
        # behaviour rather than habit. The GitHub pass records each request it sees in Review
        # Desk, which puts it on `work list` as `review_requested` — so the Review Desk pass has
        # to know what GitHub already showed, or one request would reach the Dispatcher twice and
        # two sessions could land on one review. `self.requested` is that knowledge and it is
        # filled by the earlier section.
        #
        # `harvest` is LAST, and deliberately. It is the only section that makes a call off this
        # machine to anything but an API — it asks GitHub about every review a repository has
        # posted — so a slow one delays nothing but the heartbeat, and every event a human might
        # act on has already been emitted by the time it starts.
        for section in (self.linear_triggers, self.review_requests, self.review_desk,
                        self.liveness, self.harvest):
            try:
                section(cfg, ledger, backlog)
            except Exception as exc:  # one failing source must never kill the poller
                self.error(section.__name__, exc)
        # Read before `poller_started` can fire, so start-up is not activity: a poller arming
        # itself is the dispatcher saying hello, not the world saying anything. `announced` is
        # once per PROCESS, so counting that one emit would make the first tick of every arm look
        # busy when nothing had happened — which is the whole thing this counter exists to deny.
        quiet = _emitted == said
        if not self.announced:
            # Keyed on `announced`, not on `first_tick`, because `--no-backlog` sets `first_tick`
            # False before the first tick and these three things are not the flag's business.
            #
            # `setdefault`, not assignment. `first_tick` is true once per PROCESS, so an assignment
            # here would rewrite `started` on every arm and destroy the one thing it is still for:
            # when this instance's poller first ran. Write-once keeps it honest, and keeps
            # `tc-portal`'s 2026-09-11 stamp on disk as the evidence for DEV-794.
            self.state.setdefault("started", now_iso())
            self.announced = True
            emit("poller_started", working=working_count(), max_workers=cfg["limits"]["max_workers"],
                 backlog_suppressed=not backlog,
                 ledger_open=sum(1 for e in ledger.values() if e.get("status") in ALIVE))
        self.first_tick = False
        self.mark_quiet(quiet, cfg)
        write_json(poll_state(), self.state)
        heartbeat().write_text(now_iso())

    def linear_triggers(self, cfg: dict, ledger: dict, backlog: bool) -> None:
        labels = cfg["linear"]["labels"]
        modes = cfg["linear"]["modes"]
        # A label the config names but has no id for — a config reconciled by hand, or one
        # whose `init` never ran — must not reach the query. `$labels: [ID!]` rejects a null,
        # `linear()` raises, `tick()` catches it per section, and the result is that EVERY
        # Linear trigger stops being emitted workspace-wide while the Dispatcher looks healthy.
        # One unusable mode is worth losing; all of them is not.
        unminted = sorted(m["trigger"] for m in modes.values() if not labels.get(m["trigger"], {}).get("id"))
        if unminted and self.once(f"unminted|{','.join(unminted)}"):
            emit("error", section="linear_triggers",
                 message=f"no label id in config.json for {', '.join(unminted)} — those modes "
                         f"cannot be triggered. Re-run `dispatcher.py init --instance <slug> "
                         f"--team-key KEY` to mint them.")
        by_trigger = {labels[m["trigger"]]["id"]: name for name, m in modes.items()
                      if labels.get(m["trigger"], {}).get("id")}
        # "" is not null: an empty team_key would silently widen the scope to the whole
        # workspace while reading, in the file, as though a team had been chosen.
        team_key = (cfg["linear"].get("team_key") or "").strip() or None
        query, variables = triggers_query(team_key)
        data = linear(cfg, query, {"labels": list(by_trigger), **variables})
        every = cfg["limits"]["reemit_after_secs"]
        seen = set()
        for issue in data["issues"]["nodes"]:
            key = issue["identifier"]
            label_ids = [l["id"] for l in issue["labels"]["nodes"]]
            mode = next((by_trigger[i] for i in label_ids if i in by_trigger), None)
            if not mode:
                continue
            seen.add(key)
            entry = ledger.get(key) or {}
            status = entry.get("status")
            common = dict(key=key, mode=mode, title=issue["title"], url=issue["url"],
                          team=issue["team"]["key"], project=(issue.get("project") or {}).get("name"),
                          ledger_status=status, session_id=entry.get("session_id"))
            if status in WORKING:
                # A trigger label on a ticket the ledger says is being worked: a human re-triggered
                # mid-flight, or a claim died between the ledger write and the label swap.
                if self.due(f"{key}|retrigger|{mode}", every):
                    emit("linear_retrigger", **common)
            elif self.due(f"{key}|trigger|{mode}", every):
                emit("linear_trigger", backlog=backlog, **common)
        # Called AFTER the emission loop, where `review_requests` calls it before. Both are correct
        # for the same reason and only one of them used to say so: the loop is a no-op whenever the
        # result is empty, which is the only case that can return False, so nothing above has been
        # emitted and nothing needs undoing. If a later edit gives this loop a side effect that
        # fires on an empty result, move this call above it.
        if not self.trust_empty("linear", len(data["issues"]["nodes"])):
            # The sweep below is this section's destructive commit. On an unbelieved empty result it
            # would delete every trigger marker, and recovery would then re-emit each one — a fresh
            # `linear_trigger` having lost `backlog: true`, and a false `linear_retrigger` for
            # anything the ledger has working. Narrower than the review side, because only tickets
            # still carrying a trigger label are in the query at all, but the same shape.
            return
        # A ticket that left the trigger query and comes back later should fire at once.
        for mark in [m for m in self.state["emitted"] if "|trigger|" in m or "|retrigger|" in m]:
            if mark.split("|")[0] not in seen:
                del self.state["emitted"][mark]

    def review_requests(self, cfg: dict, ledger: dict, backlog: bool) -> None:
        g = cfg["github"]
        data = gh("api", "graphql", "-f", f"query={REVIEWS_Q}", "-f", f"q={g['review_query']}")
        search = data["data"]["search"]
        nodes = search["nodes"]
        # The RAW node count, not `len(present)`. A page of nothing but drafts is a real "nothing
        # is requested" once `skip_drafts` has filtered it, and judging trust on the filtered
        # count would report that as a failing search.
        matched = search.get("issueCount")
        trusted = self.trust_empty("github", len(nodes), matched)
        if trusted and matched and len(nodes) >= REVIEW_PAGE and matched > len(nodes):
            # TRUNCATION, which is a third shape and not a variant of emptiness. `first: 50` means
            # the surplus is simply absent from `nodes`, and GitHub's search order is not stable
            # between ticks, so which 50 come back shifts with no change in the world. Executed with
            # 52 open: page one, then the same 52 rotated by two, produced two `review_cleared`
            # reading "review request removed" against PRs open and under active review. That is
            # DEV-799's opening harm reached through a NON-empty response.
            #
            # The emission loop below still runs — the rows that did come back are real and the
            # Dispatcher should see them. Only the CLEARED SWEEP is skipped; `prs_present` is still
            # committed, as the union of what was known and what came back, because freezing it is
            # what produced the blocker described at that early return. The cost is clearance
            # detection for as long as the truncation lasts: while over the page size, a review that
            # genuinely stops being requested is not reported. Silence about a real clearance is the
            # better failure than a confident false one, but it is a failure and it is bounded only
            # by somebody paging the query.
            #
            # `TRIGGERS_Q` carries the same `first: 50` and Linear reports no count at all, so on
            # that source this is undetectable as well as unguarded.
            if self.due("github|truncated", 900):
                emit("source_empty", source="github", matched=matched, returned=len(nodes),
                     believed=False,
                     reason=f"github matched {matched} and returned {len(nodes)} — page one of "
                            f"first: 50 only, so the cleared sweep is skipped")
            trusted = False
        every = cfg["limits"]["reemit_after_secs"]
        previous = self.state["prs_present"]
        rd = review_desk_cfg(cfg)
        recording = not review_desk_off(rd)
        present = {}
        for pr in nodes:
            if not pr or (g.get("skip_drafts") and pr.get("isDraft")):
                continue
            repo = pr["repository"]["nameWithOwner"]
            key = pr_key(repo, pr["number"])
            present[key] = {"repo": repo, "number": pr["number"]}
            # Whatever its status, and before anything below can decide not to speak about it.
            # `request_spoken_for` reads this set, and what it is answering is "did GitHub
            # already show the Dispatcher this request", not "was an event emitted for it".
            self.requested.add(requested_key(key))
            entry = ledger.get(key) or {}
            status = entry.get("status")
            # **Before the dismissal check below, which `continue`s.** Backlog-ness is a fact
            # about this poller having started with work already waiting, and a dismissed
            # request that is RESTORED later in the same process must still read as backlog —
            # otherwise it alone auto-dispatches while every request seen on the same tick asks
            # first, which is SKILL.md step 4's contract. Found by review of this branch.
            returned = previous is not None and key not in previous
            if backlog:
                self.state["review_backlog"].append(key)
            # **Recorded before the request is emitted, which is the whole of DEV-945's first
            # gap.** Review Desk could not say how many requests had come in or which were never
            # started, because it heard nothing until a session ran `review open`. Now the
            # request is in the record whether or not a session is ever dispatched for it — so a
            # request the principal skipped, or one nobody got to, is a row the developer can
            # see and (once Review Desk has it) dismiss.
            #
            # **A request any session has held is left alone, and the ledger is what says so.**
            # That session recorded it on the way in, and once a session is linked to a review a
            # new commit is the next ROUND rather than a move — so recording after the author
            # pushes would spend a round nobody asked for, and put it on Review Desk's list as a
            # request of its own. `session_id` on the entry is the test rather than the status,
            # because `lost`, `failed`, `discarded`, `merged` and `deferred` are all keys a
            # session has held and the field survives every one of them. The status test stays
            # beside it for `blocked`, which is WORKING and has no session by design.
            #
            # Review Desk's own `session_id` is read as well — see `record_request` — but this
            # one is what makes the protection immediate: the worker links its session a minute
            # after it starts, and a read of the record is `reemit_after_secs` away.
            #
            # Not a loss for a review nobody picked up: a request with no session is recorded,
            # and a session that died before linking leaves an entry whose `session_id` is the
            # one the Dispatcher wrote at claim time, which is the correct answer either way.
            #
            # **Not gated on `review_desk_repos`, unlike the reading pass, and that asymmetry is
            # chosen.** The read pass asks per repository and must ask about something, so an
            # unedited `repo_project_map` leaves it silent. This pass is handed the request by
            # GitHub and already knows the repository, and the question the ticket asks — "how
            # many requests have actually happened" — is about the principal's review requests
            # rather than about the repositories an instance has been configured to dispatch
            # into. The consequence, stated rather than hidden: a request in a repository the
            # map does not name is recorded and is NOT offered by the Review Desk pass, so until
            # something gives that repository a ledger entry the row is one the developer can
            # see and this poller will not dispatch from. The GitHub pass dispatches it, which
            # is what creates that entry.
            if recording and status not in ALIVE:
                self.record_request(rd, key, repo, pr["number"], pr.get("headRefOid"),
                                    pr.get("title"), every, entry)
                # **A dismissed review is not dispatched**, and nothing below this line runs
                # for one: not the backlog, not the request, not the re-request. The developer
                # took it out of play, in the dashboard, with a reason — the one decision of
                # theirs that reaches this file as a reason not to act. GitHub goes on
                # requesting the review either way, which is why the GitHub source needs
                # telling at all: Review Desk's own list already leaves a dismissed review out.
                #
                # **Asked of every request that could be dispatched, which is not the same set
                # as the requests that are written to.** Found in review: the two were one
                # condition for a commit, and a `lost` entry carrying a `session_id` — a
                # dismissed review whose worker died — fell outside it. Nothing read the
                # dismissal, nothing said it, and a replacement was dispatched onto a review the
                # developer had taken out of play, which is the one thing this is here to stop.
                # Whether to WRITE is `record_request`'s question and is narrower.
                if self.dismissed_request(rd, key, repo, pr):
                    continue
            common = dict(key=key, repo=repo, number=pr["number"], title=pr["title"], url=pr["url"],
                          author=(pr.get("author") or {}).get("login"), head_sha=pr["headRefOid"],
                          opened=(pr.get("createdAt") or "")[:10],
                          ledger_status=status, session_id=entry.get("session_id"))
            if status == "skipped":
                # The principal said skip. It stays quiet until the request is withdrawn and made again.
                if returned:
                    emit("review_request", backlog=False, rerequested=True, **common)
            elif status in REDISPATCHABLE:
                if self.due(f"{key}|review_request", every):
                    # Backlog-ness sticks until the PR is claimed or skipped, so a 15-minute
                    # re-emission of a start-up item still reads as "ask first", not "dispatch".
                    emit("review_request", backlog=key in self.state["review_backlog"], **common)
            elif returned and status in ALIVE:
                emit("review_rerequested", **common)
        # Said here rather than after the commit below, because the commit is the thing a
        # truncated page skips — and a truncated page is a FULL one, so the loop above ran,
        # attempted its recordings, and may be holding the only evidence anybody has that the
        # install is broken. Reported for 50 requests and lost for want of a return statement
        # was found in review.
        self.record_unreachable(rd, every)
        if not trusted:
            # Everything below this line commits "nothing is requested" as fact: it prunes the
            # start-up backlog, tells the Dispatcher that live reviews were cleared, and overwrites
            # `prs_present`, which is what makes the NEXT tick read every PR as newly returned.
            #
            # A PARTIAL result needs the middle course, and getting this wrong was a blocker found in
            # review. The comment here used to say "the loop above emitted nothing — `nodes` is empty
            # whenever `trusted` is False — so there is nothing to undo". That invariant was true
            # when only emptiness could clear `trusted`, and the truncation guard above broke it in
            # the same breath as documenting it: a truncated page is FULL, so the loop does emit, and
            # returning without committing froze `prs_present` at its pre-truncation snapshot.
            # `returned` was then measured against that snapshot every tick, and its two ungated
            # emits — a `skipped` PR re-offered as `rerequested: true`, and a false
            # `review_rerequested` — fired once per tick for as long as the truncation lasted.
            # Executed: three truncated ticks, six false events, overriding an explicit human skip
            # three times. Worse than not guarding truncation at all, inside truncation's own
            # trigger condition.
            #
            # So: commit the UNION. The rows that came back are real and are kept; the rows that did
            # not come back are kept too, so nothing reads as newly returned next tick. Pruning the
            # backlog against the union also stops it growing by a page per run. What stays off for
            # the duration is only clearance detection — a review that genuinely stops being
            # requested is not reported until the count drops back under the page size.
            if matched and nodes:
                self.state["prs_present"] = {**(previous or {}), **present}
                self.state["review_backlog"] = sorted({
                    k for k in self.state["review_backlog"]
                    if (k in present or k in (previous or {}))
                    and (ledger.get(k) or {}).get("status") in (None, "queued")})
            return
        # Anything claimed, skipped or no longer requested has left the start-up backlog.
        self.state["review_backlog"] = sorted({
            k for k in self.state["review_backlog"]
            if k in present and (ledger.get(k) or {}).get("status") in (None, "queued")
        })
        if previous is not None:
            for key, where in previous.items():
                entry = ledger.get(key) or {}
                if key in present or entry.get("status") not in ALIVE:
                    continue
                emit("review_cleared", key=key, reason=self.why_cleared(cfg, where),
                     session_id=entry.get("session_id"), session_name=entry.get("session_name"))
        self.state["prs_present"] = present
        # Pruned with `prs_present` and on the same evidence: this tick is trusted to say what is
        # requested, so what it does not name is not requested. That bounds the dict by the
        # number of OPEN requests rather than by every commit of every review in this instance's
        # history — the poll state is read and rewritten every tick, and a dict that only grows
        # is a file that only grows.
        #
        # The cost is one call: a request that clears and is made again is recorded again, which
        # hands back the same review and is the honest reading of it — somebody asking twice is
        # activity, and the record says so.
        #
        # **A dismissal is kept whatever the search said.** It is held nowhere else, and losing
        # it sends the next tick that sees the request back to `review open` — a WRITE, on a
        # record the developer deliberately took out of play, and the `last_activity_at` harm
        # this file keeps arranging itself to avoid. The cost is one dict entry per dismissed
        # request, for as long as the instance lives, and that is the right side to err on: the
        # entry is small and the write is on a row somebody said to leave alone.
        self.state["recorded"] = {k: v for k, v in self.state["recorded"].items()
                                  if k in present or v.get("dismissed")}

    def record_unreachable(self, rd: dict, every: int) -> None:
        """Say that Review Desk could not be reached while recording a request.

        **"Broken is loud in every mode but `off`" had a hole, and recording opened it wider.**
        The `review_desk` pass is what reports an install absent or broken, and it returns
        BEFORE probing anything when `review_desk_repos` is empty — an instance with an unedited
        `repo_project_map` and no reviews in its ledger. That silence was defensible while
        nothing else touched the install: there was nothing to be silent about. This path now
        runs `review open` on such an instance, so the fact exists and was being thrown away —
        a fresh `mode: on` instance could meet a broken Review Desk, record nothing, and say
        nothing.

        **It does not ask whether that pass will speak, and the first version did.** It checked
        `review_desk_repos` and stayed quiet when there was a repository to ask about, on the
        reasoning that the other pass would report the same install. It probes a DIFFERENT
        subcommand: `work list` is a read and `review open` is a write, so one can time out on
        write contention with the dashboard while the other answers `ok` — and that install was
        then silent for ever while recording produced nothing. Found by review of this branch.

        What stops two voices for one fault is not a condition here but a shared mark: this
        emits the `review_desk` pass's own event with that pass's own rate-limit signature, so
        the same install failing the same way is one line whichever path meets it first.

        **Two lines are possible and are not a bug, and the field that says so is `call`.** The
        mark carries the detail, and `review_desk_run` writes the SUBCOMMAND into the detail of
        a timeout — "review-desk review open did not answer in 30s" against "review-desk work
        list did not answer in 30s". A hung binary therefore reports once per call. That is the
        honest shape rather than an accident of the mark: a Review Desk can fail a write while
        answering a read, which is the entire reason this path speaks at all, so collapsing the
        two would hide exactly the case it was added for. An install failing identically on both
        shares a detail and is one line.
        """
        for call, (state, detail, repo) in sorted(self.record_broken.items()):
            self.say_unreachable(rd, every, call, state, detail, repo)

    def say_unreachable(self, rd: dict, every: int, call: str, state: str, detail: str,
                        repo: str) -> None:
        """One install-level failure, said once."""
        if state == "absent" and not review_desk_loud_when_absent(rd):
            return
        mark = "review_desk|absent" if state == "absent" else f"review_desk|{state}|{detail[:60]}"
        if self.due(mark, every):
            # `call` is whichever command met it, carried rather than assumed: it was hard-coded
            # as `review open` for one pass, so a hung `review show` reported a contradiction —
            # that field against a `detail` naming the other command. On an `absent` install no
            # command ran at all, and the one named is simply the one that tried first.
            emit("review_desk_unavailable", state=state, mode=rd["mode"], command=rd["command"],
                 repo=repo, call=call, detail=detail)

    def record_request(self, rd: dict, key: str, repo: str, number: int, head: str | None,
                       title: str | None, every: int, entry: dict) -> None:
        """Keep Review Desk's record of one review request current. Says nothing.

        `review open` is the command, and Review Desk's own README says why there is not one of
        its own: a review with no brief **is** a request — `work list` reports it as
        `review_requested` — so recording a request is opening a review and nothing more. Every
        claim below was measured against a binary built from review-desk 0e0bf1b (DEV-945's
        other half) against a temporary database:

          recorded twice          one review. `created` false the second time, no round spent
          a new head, unstarted   the request MOVES to it, `head_moved_from` naming the old one
          a new head, started     the next round, exactly as before this existed
          `--ledger`, older build exit 1, `error.code` `usage`, nothing written

        `--ledger` carries this instance's own key for the pull request, which is the same value
        the worker later writes with `review link --ledger`, so the two agree about one review
        rather than opening a second entry for it.

        **Once per key and head commit, and marked only when the call succeeded.** Two reasons,
        and the second is the one that is easy to miss: a repeat `review open --ledger` WRITES
        (it sets the links again), so it moves `review.last_activity_at` — and a call on every
        tick would leave every never-started request looking freshly touched for ever, which is
        the one thing the dashboard reads that field for. Marking on success only is what keeps
        "an install you fix is used on the very next poll" true of this path as well.

        **Silent about the install, with one exception each way.** The `review_desk` section asks
        the same install about the same repositories in this same tick and is what reports it
        absent, broken or too old, so a second voice here would be the "nothing extra said" that
        an instance without Review Desk is owed. The two exceptions are the outcomes nobody else
        covers: a refusal of ONE recording, which that section never sees, and an install that is
        absent or broken on an instance where that section has no repository to ask about and so
        returns without probing at all. Both are said through the same event and the same rate
        limit it uses, so an instance that has both voices still hears one line.

        **Two calls on two cadences, and the second is what makes a dismissal reach this
        poller.** `review open` runs when the recorded commit is not the one GitHub is showing,
        because that is when there is something to write. Whether the developer has DISMISSED
        the review is a different question, it has no commit of its own, and it is asked by
        reading — `review show`, at `reemit_after_secs`, which is the cadence everything else
        in this file re-asks on. Both keep `recorded[key]` current, and the caller decides from
        that record rather than from whichever call happened this tick.

        Returns nothing, because `self.state["recorded"][key]` is the whole answer: the commit
        recorded, the review's id, and whether the developer has dismissed it.
        """
        if not head:
            # No head commit, no recording: `review open` requires one, and a search row without
            # `headRefOid` is a row this file cannot describe a review of.
            return
        # Per KEY, not per tick: it is a fact about the build that answered for THIS request,
        # and as a tick-wide flag it leaked onto every key recorded after the one that set it —
        # permanently, because the record keeps it and a key marked `old` never has its head
        # followed again. Found by review of this branch.
        self.record_old = False  # per key, and the comment above says why
        held = self.state["recorded"].get(key) or {}
        # **`record_stopped` stops writing and looking. It does not stop reading**, and the
        # early return it used to sit in did: `find_request` sets it for a new key, and the
        # dismissal read for every key already recorded was then cancelled for the rest of the
        # tick — one strange `review find` on one new request killing the dismissal guard for
        # forty others, every tick, for the life of the install. That is the asymmetry
        # `read_request` has a paragraph about, in the opposite direction.
        # **Nothing is written to a review whose session and dismissal this poller has not
        # read** — from the look, or from the dismissal read, which carries the same two fields.
        # The looser wording is deliberate and was once stricter ("not looked at"), which the
        # review of the commit before this one showed is no longer literally true: a key whose
        # look was REFUSED falls through to the read, and a read that answers writes a record,
        # after which `if not held` is false and the look never runs for that key again. It is
        # safe because `review show` answers with `session_id` and `dismissed_at` — the two
        # facts the look exists to supply — and unsafe to describe as a guarantee about looking.
        #
        # The first call on a key used to be the write, and `review open` on a commit the author has pushed since
        # answers `created: true` with the NEXT ROUND when a session is linked to the review it
        # finds — so a review opened from the dashboard, linked by its own session, with no
        # ledger entry here, was handed a round nobody asked for by the very first tick that saw
        # the request. Found by review of this branch; the harness had always established a
        # record with an earlier poll, which is exactly how it stayed invisible.
        #
        # `review find` is a READ, costs one call per key this instance has no record of, and
        # answers the newest round first — measured at review-desk 82c0a09, dismissed rounds
        # included, which is right: the newest round is the row `review open` would act on.
        # Whether this request may be WRITTEN to. A look that failed takes the write away and
        # nothing else: the key that met the failure used to return here, which cancelled its own
        # dismissal read — and the ledger may well hold the review id to read it with. Found by
        # the review of the commit before this one, which is also where the `return` this
        # replaces was shown to be load-bearing: dropping it without this flag would make
        # `writing` true and produce exactly the blind write the look exists to prevent.
        looked = True
        if not held and not self.look_stopped and not self.record_stopped:
            found = self.find_request(rd, repo, number, every)
            if self.record_stopped or found == "refused":
                looked = False
            elif found is not None:
                held = self.remember(key, found, found.get("head_sha") or head)
        asked = f"review_desk|dismissal|{key}"
        # **The ledger is a second source for the review's id, and the only one for a review
        # this poller never recorded.** A worker writes `review_desk_id` on its entry before it
        # records anything else, so a request picked up before this change existed — or one
        # whose session opened the review itself — can still be READ for a dismissal here. With
        # no id from either source there is nothing to read, and the window is left alone rather
        # than spent: re-entering this branch every tick to learn nothing was found in review.
        rid = review_id(held.get("review")) or review_id(entry.get("review_desk_id"))
        # **A review a session has been linked to is never written to**, and the LEDGER is what
        # says so first: the worker links its session a minute after it starts, where a read of
        # the record is `reemit_after_secs` away. `session_id` on the entry rather than its
        # status, because `lost`, `failed`, `discarded`, `merged` and `deferred` are all keys a
        # session has held and the field survives every one of them.
        linked = bool(entry.get("session_id")) or bool(held.get("session"))
        # **A review a session has been linked to is read and never written to either, and that
        # is a harder rule than the ledger's.** Review Desk moves an unstarted request's head and
        # starts a NEW ROUND once a session is linked — measured at review-desk 2180224: link a
        # session, open on a new commit, and the answer is `created: true`, round 2, which
        # `work list` then offers as a request of its own. The ledger status catches the ordinary
        # case (a live session is not recorded for at all), but `lost`, `failed`, `merged` and
        # `deferred` are all keys a session HAS held, and on those a push would have the poller
        # spending a round nobody asked for. The replacement worker spends it when it starts,
        # deliberately, which is whose job it is. `session_id` on the review is the fact, so the
        # fact is what this reads rather than inferring it from a status.
        #
        # **What `linked` cannot see, and it is review-desk's to close.** That store refuses to
        # move a round that holds a brief, a finding, a draft, a layer past `pending` or round
        # commits -- "started" is wider than "a session is linked" -- and `review find`'s row
        # carries none of those. So in the window where a session has written a brief and not
        # yet called `review link --session`, on a review this instance has no ledger entry
        # for, a push can still have this poller start a round. Narrowing it needs `started` on
        # the row rather than a guess from here, which is asked of DEV-945's other half.
        #
        # **A dismissal THIS POLLER HAS READ is never written to again**, whatever the author
        # pushes to the pull request. The claim is deliberately that narrow: `dismissed` is
        # learned by the read below, so a push that lands before the first read — or after the
        # poll state is lost — is recorded, and `review open`'s own answer is what then reports
        # the dismissal. One write, once, and nothing after it. `review open` on a new commit
        # would move the dismissed review's head — Review Desk allows it, and a push is not the developer
        # changing their mind — but it WRITES, which moves `last_activity_at` on a row somebody
        # said to leave alone. That is the same harm the prune above keeps a dismissal to avoid,
        # and it arrived here by the head test running first. The record goes on naming the
        # commit Review Desk was TOLD, so a restore puts the two out of step and the very next
        # tick moves it, which is where moving it belongs.
        # **A head that moved is only followed on a build that can MOVE one.** The move and
        # `--ledger` landed in the same review-desk commit (0e0bf1b), so a build that refuses
        # the flag is a build where `review open` on a new commit creates a new ROUND instead —
        # measured against the installed 0.1.0: `created: true`, round 2, a second row for one
        # request, which is the "two unstarted reviews for one request is wrong" the other half
        # was written to prevent. `old` is set on the retry path and remembered, so such a build
        # records a request once and then leaves it alone: exactly the behaviour that preceded
        # this branch, which is what every other degradation here falls back to.
        writing = (looked and not self.record_stopped and not held.get("dismissed") and not linked
                   and not (held.get("old") and held.get("head"))
                   and not same_commit(held.get("head"), head))
        if writing:
            review = self.open_request(rd, key, repo, number, head, title, every)
        elif rid is not None and not self.read_stopped and self.due(asked, every):
            review = self.read_request(rd, key, rid, every, repo)
            if review is None and not self.read_unsupported:
                # **The window is not spent on a read that did not happen.** `due` writes its
                # marker when it is evaluated, so a Review Desk broken for one tick would
                # otherwise put the next read a whole `reemit_after_secs` away — and a
                # dismissal made in between would go on being dispatched for that long. Cleared
                # here, the next tick asks again, which is what makes "an install you fix is
                # used on the very next poll" true of this branch as well as the other.
                #
                # Not when `read_stopped` is set, though: that read DID happen and answered that
                # this build has no `review show` to run. Clearing the window there would ask
                # again every tick, for every recorded request, for ever.
                self.state["emitted"].pop(asked, None)
        else:
            return
        if review is None:
            # Nothing was learned — absent, broken, refused, or a review that is gone. What was
            # already recorded stands, including a dismissal: a Review Desk that cannot be
            # reached is not the developer changing their mind.
            return
        # The commit this record is compared against next tick: GitHub's after a WRITE, and
        # after a read the one Review Desk is holding — which is the record's own if there is
        # one and the answer's otherwise. GitHub's commit is the one thing it must not be on
        # this path: the read became reachable with no prior record in the commit before this
        # one, and storing GitHub's head there told every later tick the request was already
        # recorded at a commit Review Desk had never been given, so it was never written again.
        # Safe to store either spelling because `same_commit` normalises the comparison.
        self.remember(key, review,
                      head if writing else (held.get("head") or review.get("head_sha") or head),
                      old=self.record_old or bool(held.get("old")))

    def remember(self, key: str, review: dict, head: str, old: bool = False) -> dict:
        """Write what one Review Desk answer says about a request into the poll state.

        One place, because three callers answer the same question — `review find` before the
        first write, `review open` after a write, `review show` on the dismissal read — and
        three copies of this dict would be three chances for them to disagree about what a
        record holds.
        """
        held = {
            # The commit this record is to be compared against next tick. The caller decides
            # which one that is: after a WRITE it is the commit GitHub named, and after a read
            # it is the one Review Desk was told before — a dismissed row is not moved, so
            # recording the commit GitHub is showing would claim a head the store does not hold
            # and no restore would ever move it.
            #
            # **Either spelling is safe, and the CALLER picks which.** Review Desk normalises
            # what it is given — `normalise::head_sha` trims and lower-cases — so a record
            # holding its echo and a record holding GitHub's own differ in case, and this value
            # is consumed only by `same_commit`, which normalises both sides. That is what makes
            # the choice the caller's: GitHub's commit after a write, because that is what was
            # written; Review Desk's after a read, because a read must not claim a commit the
            # store was never given.
            #
            # **This paragraph used to say the opposite** — GitHub's spelling wherever there is a
            # choice — and justified it with the churn `same_commit` now prevents, while both
            # callers did the other thing. A future editor trusting it over the call sites would
            # restore GitHub's head on the read path and with it the bug the commit before this
            # one fixed: a record claiming a commit Review Desk never held, so the request reads
            # as already recorded and is never written again.
            "head": head,
            "review": review.get("id"),
            # `dismissed_at` is the fact and the reason is for the reader, so they are kept
            # apart: a build older than migration 16 has neither key, which reads as not
            # dismissed, which is exactly how this behaved before dismissal existed.
            "dismissed": bool(review.get("dismissed_at")),
            "reason": review.get("dismissed_reason"),
            # Whether a session has been linked to it, which is what makes a push the next ROUND
            # rather than a move. Read, never written: `review link --session` is the
            # worker's, and it covers what this instance's ledger cannot know — a review opened
            # from the dashboard, or one a session linked itself to without this dispatcher
            # claiming it.
            "session": review.get("session_id"),
            # Whether the build that answered has no `--ledger`, and so no move either. Kept on
            # the record rather than on the Poller because it is a fact about the install this
            # KEY was recorded against, and a tick that records nothing should not forget it.
            "old": old,
        }
        self.state["recorded"][key] = held
        return held

    def open_request(self, rd: dict, key: str, repo: str, number: int, head: str,
                     title: str | None, every: int) -> dict | None:
        """`review open`: the request, written. Returns the review, or None if it was not."""
        # Canonical here as well. This one the store normalises for itself, so it is the same
        # row either way — but two calls about one pull request spelling it two ways is the
        # inconsistency the bug above grew in, and the cost of consistency is nothing.
        facts = ["review", "open", "--repo", canonical_repo(repo), "--pr", str(number),
                 "--head", head]
        if title:
            # `--title=<value>`, ONE argument, because a pull request may legitimately be called
            # `-fix the thing` and clap reads a separate value beginning with `-` as a flag it
            # has never heard of. Measured against review-desk 82c0a09: `--title "-fix the
            # thing"` is refused with `usage: error: unexpected argument '-f' found`, which this
            # file would then read as "this build has never heard of `--ledger`", retry without
            # the flag, fail identically, and report a refusal — for every tick that pull
            # request stayed open. `--title=-fix the thing` is accepted and stored verbatim.
            facts.append(f"--title={title}")
        state, payload, detail = review_desk_run(rd, *facts, "--ledger", key, "--json")
        retried = False
        if state == "refused" and review_desk_unknown(detail):
            # An older Review Desk: it has `review open` and has never heard of `--ledger`. The
            # request is still worth recording without it — the worker writes the ledger id with
            # `review link` when it starts, which is how it reached the record before DEV-945 —
            # so it is retried ONCE, without the flag, and never again. A second refusal is a
            # refusal about something else and is left alone.
            state, payload, detail = review_desk_run(rd, *facts, "--json")
            # Remembered only if it ANSWERS, below. Set here, it was a guess: `review_desk_unknown`
            # is a substring test over a detail that can be raw stderr, so a usage-shaped refusal
            # about something else would have stamped the build `old` — and `old` is what stops a
            # head ever being followed again. A retry that succeeds without the flag is the
            # evidence the refusal was about the flag.
            retried = True
        if state in ("absent", "broken"):
            # One install answers for every request, so there is nothing to learn from asking
            # again this tick — and a great deal to lose: at a 30s timeout, a hung binary asked
            # once per request is one stalled tick per page of requests. Asked once, it costs
            # what the `review_desk` section's own call already costs.
            self.record_stopped = True
            if state == "absent":
                # Nothing on this install can be asked anything, reads included — the same rule
                # `find_request` and `read_request` apply where they meet it.
                self.read_stopped = True
            # Kept, not said: `record_unreachable` says it at the end of `review_requests`, and
            # carries the repository this was met on because SKILL.md tells the Dispatcher to
            # name it.
            self.record_broken["review open"] = (state, detail, repo)
            return None
        if state != "ok":
            # A refusal about THIS request rather than about the install, so the rest of the page
            # is still recorded and nothing is remembered: the next tick tries it again.
            #
            # **And it is said, once per reason per `reemit_after_secs`.** This is the one
            # outcome on this path that no other voice covers: the `review_desk` pass reports
            # absent, broken and too-old, and a refusal of a recording is none of those. A
            # refusal that repeats records nothing at all, while `work list` goes on answering
            # `ok` with an empty list — so the Reviews page would read "no requests came in",
            # which is the exact sentence DEV-945 exists to stop being unanswerable.
            #
            # **Rate limited per REPOSITORY, and the pull request it names is one example rather
            # than the extent of it.** A refusal is almost never about one request — a store that
            # does not know `acme/portal` refuses every request in it — and the first draft of
            # this keyed the limit on the refusal's own message, which names the request, so
            # forty silently-unrecorded requests were reported as one. `review_desk_unknown_kind`
            # already had this shape and says so in SKILL.md; this now says it too.
            if self.due(f"review_desk|record_refused|{repo}", every):
                emit("review_desk_unavailable", state="refused", mode=rd["mode"],
                     command=rd["command"], repo=repo, number=number, call="review open",
                     detail=detail, example=True)
            return None
        if retried:
            # The retry answered, so the flag's claim is now evidenced rather than inferred: this
            # build has no `--ledger`, and therefore no move either — the two landed together.
            self.record_old = True
        review = review_of(payload)
        if review is None:
            # **Exit 0 with an answer this file cannot read is BROKEN, not nothing.**
            # `review_desk_work` calls the same shape "too old to use" and so does this, and the
            # reason it cannot be passed over quietly is what happens next: nothing is recorded,
            # so the commit never matches, so `writing` is true again on the following tick and
            # on every tick after it — one WRITE per request per tick, for ever, which is the
            # churn this whole path is arranged around. Found in review; the test that covered
            # this shape ran one tick, which is exactly how it passed.
            self.record_stopped = True
            detail = (f"{rd.get('command')} review open exited 0 with an answer carrying no "
                      f"review — too old to use")
            # Said here and not through `record_broken`, which is the carrier for a failure that
            # has no repository to name. This one has one, and two carriers for one fault is two
            # lines about it.
            if self.due(f"review_desk|record_unreadable|{repo}", every):
                emit("review_desk_unavailable", state="broken", mode=rd["mode"],
                     command=rd["command"], repo=repo, call="review open", detail=detail)
        return review

    def find_request(self, rd: dict, repo: str, number: int, every: int):
        """`review find`: the newest round Review Desk holds for a pull request.

        Returns the newest round, `None` for "this pull request has no review" — which is the
        ordinary case and means "write, and create it" — and the string `"refused"` for "this
        pull request could not be looked at", which means write nothing.

        **A read that exists so the first write is not blind.** It answers newest round first —
        measured at review-desk 82c0a09, with dismissed rounds included, which is what is
        wanted: the newest round is the row `review open` would act on, so it is the row whose
        head, session and dismissal decide whether writing to it is safe.

        None for a pull request with no review at all, which is the ordinary case and means
        "write, and create it". A failure stops RECORDING for the tick rather than only reading:
        this call is part of the write path, the install answers the same way for every request,
        and a write nobody could look at first is the thing this exists to prevent.
        """
        state, payload, detail = review_desk_run(rd, "review", "find", "--repo",
                                                 canonical_repo(repo), "--pr", str(number),
                                                 "--json")
        if state in ("absent", "broken"):
            self.record_stopped = True
            if state == "absent":
                # Nothing on this install can be asked anything, reads included.
                self.read_stopped = True
            self.record_broken["review find"] = (state, detail, repo)
            return None
        if state == "refused" and review_desk_unknown(detail):
            # **A build that has never heard of `review find`, which must not take the feature
            # with it.** Looking first is a guard against spending a round on a review somebody
            # else opened; recording at all is the ticket. So this one degrades to the behaviour
            # that preceded the look — write, and accept the narrow risk — rather than stopping,
            # which on such a build would record nothing, for ever, silently. It is said once so
            # that "the look is unavailable here" is a fact somebody can read, and `look_stopped`
            # keeps it to one call a tick instead of one per request.
            #
            # Found by review: the first version stopped recording on any non-`ok`, which also
            # made `open_request`'s `--ledger` retry unreachable on exactly the older builds it
            # was written for.
            self.look_stopped = True
            if self.due("review_desk|look_unsupported", every):
                emit("review_desk_unavailable", state="broken", mode=rd["mode"],
                     command=rd["command"], repo=repo, call="review find",
                     detail=f"{rd.get('command')} has no `review find`, so a request is recorded "
                            f"without looking at the review first: {detail[:120]}")
            return None
        if state != "ok":
            # A refusal about THIS pull request — a repository the store does not know, a
            # validation this file has not met. Nothing is written to it, because the look is
            # what makes a write safe and this one did not happen; the rest of the page is
            # unaffected, and it is said once per repository exactly as a refused recording is.
            if self.due(f"review_desk|look_refused|{repo}", every):
                emit("review_desk_unavailable", state="refused", mode=rd["mode"],
                     command=rd["command"], repo=repo, number=number, call="review find",
                     detail=detail, example=True)
            return "refused"
        rounds = (payload or {}).get("reviews") if isinstance(payload, dict) else None
        if not isinstance(rounds, list):
            self.record_stopped = True
            detail = (f"{rd.get('command')} review find exited 0 with an answer carrying no "
                      f"rounds — too old to use")
            self.record_broken["review find"] = ("broken", detail, repo)
            return None
        newest = rounds[0] if rounds else None
        return newest if isinstance(newest, dict) else None

    def read_request(self, rd: dict, key: str, rid, every: int, repo: str) -> dict | None:
        """`review show`: whether the developer has dismissed a request already recorded.

        **A read, deliberately, and not another `review open`.** Opening again would answer the
        same question — the review comes back either way — but it WRITES, and a write every
        fifteen minutes on a request nobody has started is the `last_activity_at` problem the
        once-per-commit rule above exists to avoid. Nothing in Review Desk moves on a read.

        A review that is GONE — and only that refusal, `not_found` and no other — is forgotten
        rather than remembered as missing: the developer deleted a review that never started,
        which they may only do while it never started, and the next tick records the request
        again from GitHub. That is the intended shape rather
        than a hole in it — delete is for a row that should not exist, and the way to tell this
        poller to leave a real request alone is to dismiss it.
        """
        if not isinstance(rid, int):
            return None
        state, payload, detail = review_desk_run(rd, "review", "show", "--review", str(rid),
                                                 "--json")
        if state in ("absent", "broken"):
            # **A broken READ stops reading and nothing else.** It used to stop recording too,
            # which contradicted the one argument this path rests on: a Review Desk can fail a
            # write while answering a read, and the other way round. One recorded key whose
            # `review show` timed out would otherwise leave every NEW request on the page
            # unrecorded — the gap DEV-945 exists to close — and the notice would name the
            # wrong command. `absent` is different: nothing on that install can be asked
            # anything, so it stops both.
            self.read_stopped = True
            if state == "absent":
                self.record_stopped = True
            self.record_broken["review show"] = (state, detail, repo)
            return None
        if state == "refused":
            if review_desk_unknown(detail):
                # A build with no `review show` to run, which is a different fact from a review
                # that is gone and must not be read as one. Forgetting the record here would
                # send every following tick back to `review open`, and that WRITES: an older
                # Review Desk would be given the `last_activity_at` churn this whole path is
                # arranged to avoid. Nothing is learned and nothing is forgotten.
                #
                # And nothing else is asked this tick. The answer is about the BUILD rather than
                # about this review, so asking once per recorded request would be one subprocess
                # per request per tick, for ever, for an answer that cannot change until the
                # install does. Recording itself carries on: this build opens reviews perfectly
                # well, which is why `record_stopped` is the wrong flag for it.
                self.read_stopped = True
                self.read_unsupported = True
                # **And it is said, which it was not.** This is the one "too old to use" in the
                # file that was silent, and what it costs is not nothing: on such a build the
                # dismissal guard never learns anything, so a review the developer dismissed is
                # offered for dispatch every `reemit_after_secs` with no line anywhere saying
                # why. Said once, through the same event and the same mark shape as the others.
                if self.due("review_desk|read_unsupported", every):
                    emit("review_desk_unavailable", state="broken", mode=rd["mode"],
                         command=rd["command"], repo=repo, call="review show",
                         detail=f"{rd.get('command')} has no `review show`, so a dismissal "
                                f"cannot be read and a dismissed review may be dispatched: "
                                f"{detail[:120]}")
                return None
            if detail.startswith(REVIEW_DESK_MISSING_REFUSAL):
                self.state["recorded"].pop(key, None)
                return None
            # Any other refusal is not a review that is gone — a locked database, a validation
            # this file has not met — and forgetting the record for one would send the next tick
            # to `review open`, which writes, possibly on a dismissed row. `review_desk_run`
            # says an unknown review id is the only refusal this file asks for on purpose, so
            # the rest are nothing learned and nothing forgotten.
            return None
        review = review_of(payload)
        if review is None:
            # **Exit 0 with an answer this file cannot read is BROKEN here too.** The write path
            # grew this guard a pass earlier and the read path did not, which is the asymmetry a
            # review of this branch found: without it, `review show` answering `[]` or
            # `{"review": null}` read as "nothing learned", the window was cleared, and the next
            # tick asked again — one subprocess per recorded request per tick, for ever, with
            # the dismissal guard silently dead and nothing said. `read_stopped` is the right
            # flag: such a build still records, and it is the reading it cannot do.
            self.read_stopped = True
            self.read_unsupported = True
            detail = (f"{rd.get('command')} review show exited 0 with an answer carrying no "
                      f"review — too old to use")
            if self.due("review_desk|read_unreadable", every):
                emit("review_desk_unavailable", state="broken", mode=rd["mode"],
                     command=rd["command"], repo=repo, call="review show", detail=detail)
        return review

    def dismissed_request(self, rd: dict, key: str, repo: str, pr: dict) -> bool:
        """Has the developer dismissed this request's review? Says so once if they have.

        **A dismissal is a decision, and the only one of the developer's decisions that reaches
        this file as a reason not to act.** Review Desk's own list already leaves a dismissed
        review out, so nothing arrives from that source either; this is the GitHub source being
        told the same thing, because GitHub goes on requesting the review whatever Review Desk
        holds — dismissing is not withdrawing.

        Said once per request and per review, not once per tick: the Dispatcher is told why it
        is not dispatching a request it can see, and then left alone about it. The mark is
        cleared the moment the review is not dismissed, so a RESTORE followed by a second
        dismissal is said again — it is a new decision about the same request.

        Nothing here dismisses, restores or deletes anything, and there is no command that
        could: Review Desk's dismissal is the dashboard's API and has no command-line path at
        all. The developer's decision is read here and nowhere made.
        """
        held = self.state["recorded"].get(key) or {}
        mark = f"review_dismissed|{key}|{held.get('review')}"
        if not held.get("dismissed"):
            self.state["once"].pop(mark, None)
            return False
        if self.once(mark):
            emit("review_dismissed", key=key, repo=repo, number=pr["number"],
                 review_desk_id=held.get("review"), reason=held.get("reason"),
                 review=review_desk_link(rd, held.get("review")),
                 title=pr.get("title"), url=pr.get("url"))
        return True

    def request_spoken_for(self, key: str, entry: dict, item: dict) -> bool:
        """Is there nothing for the Review Desk pass to say about this `review_requested`?

        All three shapes are DEV-945's own making: before a request was recorded on sight, a
        review with no brief could only be one a session or the dashboard had opened, and every
        one of them was work.

        The first shape compares keys from two sources that case a repository differently, so it
        compares them through `requested_key`. The other two read this instance's own ledger,
        and that lookup is left as it was — see `requested_key` for what it leaves uncovered.

          1. **GitHub showed it this tick, AND the GitHub pass speaks for its status.** One
             request, one event: that pass is already telling the Dispatcher about this request,
             on its own cadence and with its own backlog flag, and Review Desk's copy is the
             record rather than a second source. Two events for one request is two sessions on
             one review.

             The second half of the condition is not decoration. The GitHub pass emits for a
             status in `REDISPATCHABLE` and for a `skipped` key that came back, and for
             `done`, `stopped` and `blocked` it says NOTHING — they are ALIVE, so they are
             never recorded, and `returned` is false while the pull request stays present. A
             review whose worker stopped before writing a brief is exactly that shape, and
             suppressing Review Desk for it left both sources silent and the review stalled.
             SKILL.md names the fifteen-minute re-offer as the net under a session that keeps
             dying; this keeps it.
          2. **Somebody has already decided about this key** — `skipped` by the principal,
             `deferred` or `merged` by the work itself (`DECIDED`). They decided about the
             REQUEST, and the row this poller wrote is not a second opinion. Without this,
             recording such a request would hand it straight back for dispatch, overriding the
             decision — and `review_requests` goes quiet about those keys, so nothing else
             would object. `skipped` alone was tested here and `deferred` was not, until a
             review of this branch found that the status the file itself defines as "never
             dispatched again" was being offered for dispatch on any tick GitHub stayed quiet.
          3. **It names a ledger entry that does not exist.** Only this poller links a review to
             a ledger entry nobody created; a worker writes its entry before it opens anything.
             So this is a request recorded on sight that was never claimed, and GitHub is no
             longer showing it: the pull request closed, or the request was withdrawn. There is
             nothing to start. It stays in the record for the developer to see, and to dismiss
             when Review Desk can be asked to — which is the other half of DEV-945.

        What shape 3 costs: on a tick where the GitHub search failed or was truncated, a request
        that IS still being made looks like a withdrawn one and nothing is dispatched for it.
        That tick says `source_empty` for its own reason, and the next healthy tick shows the
        request again.

        **And what shape 3 cannot see, said plainly: a Review Desk too old for `--ledger`.** On
        that build the recording is retried without the flag, so a request this poller recorded
        and nobody claimed carries no ledger id at all — indistinguishable here from a review
        opened in the dashboard, which must still be dispatched. So on such an install a
        withdrawn, never-started request goes on being offered every `reemit_after_secs` until
        somebody acts on it, which is the behaviour this shape removes everywhere else. Closing
        it needs either a record that outlives the request — the growth this file's prune exists
        to bound — or Review Desk saying who recorded a review, which is its side of the line.
        The retry is the ticket's own instruction, so this is a stated limit rather than a
        choice reopened here.
        """
        if requested_key(key) in self.requested and entry.get("status") in REDISPATCHABLE:
            return True
        if entry.get("status") in DECIDED:
            return True
        return bool(item.get("ledger_id")) and not entry

    @staticmethod
    def why_cleared(cfg: dict, where: dict) -> str:
        try:
            info = gh("pr", "view", str(where["number"]), "-R", where["repo"],
                      "--json", "state,latestReviews")
        except Exception:
            return "no longer requested (could not read PR)"
        if info["state"] != "OPEN":
            return f"PR {info['state'].lower()}"
        mine = [r for r in info.get("latestReviews") or [] if (r.get("author") or {}).get("login") == cfg["github"]["login"]]
        if mine:
            return f"you submitted a review ({mine[-1].get('state', '').lower()})"
        return "review request removed"

    def liveness(self, cfg: dict, ledger: dict, backlog: bool) -> None:
        live, archived = allele_state(cfg)
        after = cfg["limits"]["blocked_alert_after_secs"]
        tracked = set()
        for key, entry in ledger.items():
            sid = entry.get("session_id")
            if not sid or entry.get("status") not in ALIVE:
                continue
            # A `blocked` entry is in ALIVE so it stays visible on `D status`, but its
            # coordinator has handed the parent back and its pass is over — no session need
            # exist. Policing one produces a false `session_blocked` page after 120s, a
            # `session_suspended` as soon as the session is parked (which is the common
            # resting state), and finally a `session_lost` whose SKILL.md handler would put
            # the trigger label back on a parent somebody deliberately declared unfit to
            # start. That re-arms the retry loop `stack.v2.md` §3d-ii forbids by name.
            if entry.get("status") == "blocked":
                continue
            tracked.add(sid)
            common = dict(key=key, mode=entry.get("mode"), session_id=sid,
                          session_name=entry.get("session_name"), ledger_status=entry.get("status"))
            session = live.get(sid)
            if session is None:
                kind = "session_archived" if sid in archived else "session_lost"
                if self.once(f"{sid}|{kind}"):
                    emit(kind, **common)
                continue
            status = session.get("last_known_status")
            if entry.get("status") in WORKING and status == "AwaitingInput":
                first = self.state["blocked"].setdefault(sid, time.time())
                if time.time() - first >= after and self.once(f"{sid}|blocked|{int(first)}"):
                    emit("session_blocked", waiting_secs=int(time.time() - first), **common)
            else:
                self.state["blocked"].pop(sid, None)
            if entry.get("status") in WORKING and status == "Suspended":
                if self.once(f"{sid}|suspended|{entry.get('updated_at')}"):
                    emit("session_suspended", **common)
        for sid in [s for s in self.state["blocked"] if s not in tracked]:
            del self.state["blocked"][sid]

    def review_desk(self, cfg: dict, ledger: dict, backlog: bool) -> None:
        """The third source: what Review Desk says needs an agent, per repository served.

        Linear says what the principal has asked for and GitHub says who has asked for a review.
        Neither can say that a brief was confirmed or a draft approved, because those happen in
        the dashboard — so before this section a draft the developer approved reached nobody once
        its session was gone, and that is the hole DEV-865 was filed about.

        Three things this section deliberately does NOT do:

          * **It does not claim.** The ledger entry is the claim, written by the Dispatcher
            before it creates a session, exactly as for a Linear trigger or a review request.
            Review Desk's own README is explicit that `work list` has no lease and that two
            callers polling one database both see the same item.
          * **It does not commit anything.** `linear_triggers` and `review_requests` each end in
            a destructive commit — a marker sweep, a `prs_present` overwrite — which is what
            `trust_empty` exists to guard. This section only emits, so an empty answer costs
            nothing to believe and the second-zero rule would be noise here. More than noise: an
            empty list is Review Desk's NORMAL answer, because it lists only work the developer
            has already acted on, so a `zero_streak` on this source would read as a fault on
            every quiet day. The bucket therefore records a count and a time and nothing else.
          * **It does not decide whether a session is alive from Review Desk.** See
            `review_desk_live`.
        """
        rd = review_desk_cfg(cfg)
        if review_desk_off(rd):
            return
        repos = review_desk_repos(cfg, ledger)
        if not repos:
            # Nothing to ask about, so nothing is asked and nothing is said. An instance with an
            # unedited `repo_project_map` and no reviews in its ledger is indistinguishable, from
            # the outside, from one with Review Desk switched off — which is what keeps a
            # dispatcher that has never heard of Review Desk silent about it.
            return
        every = cfg["limits"]["reemit_after_secs"]
        try:
            live, _ = allele_state(cfg)
        except Exception as exc:
            # Whether a session is alive decides between "that session's watcher has it" and
            # "dispatch a replacement", and getting it wrong in the second direction puts two
            # sessions on one review. Unknown therefore means dispatch NOTHING, which is the
            # recoverable direction: the next tick tries again.
            if self.due("review_desk|liveness", every):
                emit("review_desk_unavailable", state="unknown_liveness", mode=rd["mode"],
                     detail=f"allele's state file could not be read, so whether a session is "
                            f"still working a review is unknown and nothing was dispatched: "
                            f"{str(exc)[:200]}")
            return
        counted = 0
        for repo in repos:
            state, items, detail = review_desk_work(rd, "--repo", repo)
            if state == "absent":
                # One answer for every repository: the binary either resolves or it does not.
                # Silent under `auto`, which is what "absent is silent" means, and loud under
                # `on` — where the principal has said they expect it to be there.
                if review_desk_loud_when_absent(rd) and self.due("review_desk|absent", every):
                    emit("review_desk_unavailable", state="absent", mode=rd["mode"],
                         command=rd["command"], detail=detail)
                return
            if state != "ok":
                # Broken is loud in every mode but `off`, and loud is one message rather than one
                # per tick: the signature carries the detail so a NEW failure still speaks.
                if self.due(f"review_desk|{state}|{detail[:60]}", every):
                    emit("review_desk_unavailable", state=state, mode=rd["mode"],
                         command=rd["command"], repo=repo, detail=detail)
                continue
            counted += len(items)
            for item in items:
                self.review_desk_item(rd, ledger, live, repo, item, every)
        self.state.setdefault("sources", {})["review_desk"] = {
            "last_count": counted, "last_at": now_iso()}

    def review_desk_item(self, rd: dict, ledger: dict, live: dict, repo: str, item: dict,
                         every: int) -> None:
        """One `work list` item: dispatch it, resume it, or leave it to the session that has it."""
        kind, rid = item.get("kind"), item.get("review_id")
        number = item.get("pr")
        # Split in two, because the two halves are not the same fact. A kind this file cannot
        # place is a Review Desk newer than this dispatcher, and somebody has to be told; an item
        # whose ids are not integers is a malformed answer there is nothing useful to say about,
        # and it is dropped as it always was.
        if kind not in REVIEW_DESK_KINDS:
            self.unknown_kind(kind, rid, repo, every)
            return
        if not isinstance(rid, int) or not isinstance(number, int):
            return
        # `ledger_id` is what `review link --ledger` was given, which is this instance's own key.
        # A review STARTED FROM THE DASHBOARD has never been linked and carries null, so the key
        # is derived the same way `review_requests` derives it — which is what makes the two
        # sources agree about one pull request instead of opening a second entry for it.
        key = item.get("ledger_id") or pr_key(repo, number)
        entry = ledger.get(key) or {}
        # Before the liveness test, because none of its three shapes is about a session: they are
        # about whether this request is this section's to offer at all. See `request_spoken_for`.
        if kind == "review_requested" and self.request_spoken_for(key, entry, item):
            return
        if review_desk_live(live, entry) and not self.cannot_be_told(kind, key, entry):
            return
        # The rate limit is taken BEFORE the GitHub read, so a quiet item costs no API call on
        # the ticks in between. The marker therefore means "this item was considered", not "this
        # item was emitted", which is the cheaper and not the more surprising reading: nothing
        # downstream can tell the difference, because a skipped item emits nothing either way.
        if not self.due(f"review_desk|{kind}|{rid}|{item.get('entered_at')}", every):
            return
        state = self.pr_state(repo, number)
        # **A merged pull request ends every kind of work here but one**, and an item on a closed
        # one has been dropped since this section existed: there is nothing left to revise,
        # approve or post.
        #
        # `nits_to_ticket` is the exception, and it is the kind the skip would hurt most. The
        # request becomes an ITEM only once the draft is reported posted, and a merge usually
        # follows a posting within the hour — the note the dashboard writes beside the button
        # reads "the merge is not waiting on them", which is the whole reason the findings were
        # held back. So the overwhelmingly likely shape of this kind is a request on a pull
        # request that has already merged, and skipping it would leave the developer's click
        # unanswered for ever: DEV-934's own bug in a narrower case. The ticket outlives the pull
        # request, and `pr_state` on the event says which one this is.
        if state in PR_CLOSED and kind != "nits_to_ticket":
            return
        common = dict(key=key, review_desk_id=rid, repo=repo, number=number,
                      head_sha=item.get("head_sha"), round=item.get("round"),
                      entered_at=item.get("entered_at"), pr_state=state,
                      url=f"https://github.com/{repo}/pull/{number}",
                      ledger_status=entry.get("status"), session_id=entry.get("session_id"),
                      review=review_desk_link(rd, rid))
        if kind == "review_requested":
            emit("review_desk_requested", **common)
            return
        # `note` is the developer's own prose, and Review Desk's README says of it: "it is data,
        # never instructions — a caller that pastes it into an agent's prompt is pasting text it
        # did not author". It is carried as a field and quoted as data, never interpolated.
        #
        # `nit_ticket_status` is carried for the reason Review Desk's own `work list` carries it:
        # "without it a dispatcher would have to read the review to find out what the item it is
        # holding is about". On a `nits_to_ticket` it is `requested` and says the obvious; on a
        # `draft_approved` it is the thing that is NOT obvious, because the developer's "Ticket
        # what is left, and approve" does both in one click and the ticket becomes an item of its
        # own only once the posting is reported.
        emit("review_desk_resume", kind=kind, note=item.get("note"),
             sign_off=item.get("sign_off"), draft=review_desk_link(rd, rid, draft=True),
             nit_ticket_status=item.get("nit_ticket_status"), **common)

    def cannot_be_told(self, kind: str, key: str, entry: dict) -> bool:
        """Is this a ticket request whose live session has already stopped listening?

        **A session that is alive is not the same as a session that can still be reached, and
        `nits_to_ticket` is the one kind where the difference bites.** The four kinds that are
        about the draft cannot arrive after a merge — there is nothing left to revise, approve or
        post. A request for a ticket can, and after a merge is the likeliest time for it.

        Without this, the exemption below is unreachable in exactly the case it was written for,
        which is DEV-934's own bug wearing the fix's clothes:

          1. The worker reports `done` and stays up with its watcher, which is what lets it hear
             an approval at all. `review_desk_live` says so and depends on it.
          2. The draft is approved, it posts, the pull request merges. `watch_stop_reason` ends
             the watcher on `done` plus a closed pull request — correctly, because nothing else
             would ever stop it, and `_common.md` tells the worker that is expected and nothing
             to do.
          3. Nothing writes a terminal ledger status at a merge; the comment on `WATCH_DEAD`
             says the status to reason about after one is `done`. So the entry stays `done`,
             `done` is in `ALIVE`, and allele still lists the session because nobody discarded
             it.
          4. The developer clicks "File as one ticket for an agent", and `review_desk_live`
             answers True about a session whose eyes are shut.

        Read from the WATCHER'S OWN CURSOR, for one local file and no GitHub call. **An absent
        cursor means the watcher has been and gone, not that it has yet to start**, and getting
        that the wrong way round is how the first version of this shipped the very bug above:
        `cmd_watch` deletes the cursor on three of `watch_stop_reason`'s four stop paths, and
        `--exit-on-done` — which SKILL.md tells the Dispatcher to offer the principal — is one
        of them. Only `Watcher.tick` ever writes a cursor, so once it has exited nothing will
        write that file again; the absence is permanent, and reading it as "not yet" left the
        request reaching nobody for ever on a documented path.

        What makes the rule safe rather than merely safer is that the cursor's presence tracks
        the stop paths almost exactly:

          | How the watcher stopped | Cursor afterwards | Read as |
          |---|---|---|
          | `WATCH_DEAD` status, `--exit-on-done`, or no pull request | deleted | cannot be told |
          | `done` with a merged or closed pull request | kept, `pr_status` closed | cannot be told |
          | `ceiling` or `max_ticks` | kept, `pr_status` as it was | still listening |

        The last row is the one that must stay as it is: `_common.md` tells a worker to re-arm
        the Monitor after a ceiling, so a cursor with an open `pr_status` is a watcher that is
        coming back. A cursor that exists with NO `pr_status` is one that has armed and not yet
        read the pull request, which is also a watcher that is listening.

        **The hole left, named rather than implied:** a watcher killed by a signal leaves its
        cursor with an open `pr_status` and does not come back, so this reads it as listening.
        Nothing local can tell that from a ceiling, and the ceiling case is the common one.

        A worker that passed `--as` keeps its cursor under another name, so this finds none and
        reads it as deaf. That is the right direction for the same reason the default is: a
        replacement files a ticket somebody asked for, and `review.md`'s first step has it check
        for a filing before it makes one, where the other direction is a request nobody answers.

        The event still carries `session_id` and `ledger_status`, so the Dispatcher can try the
        session that is sitting there before it dispatches a replacement. SKILL.md says so.
        """
        if kind != "nits_to_ticket" or entry.get("status") != "done":
            return False
        # A cursor that is not a populated object is a cursor no watcher is using — deleted,
        # empty, or half-written by a process that died over it. `isinstance` rather than trust
        # for the same reason the ids above are type-tested: `.get` on something that parsed as
        # a list is an AttributeError in the middle of a poll tick.
        cursor = read_json(watch_dir() / f"{key}.json", {})
        if not isinstance(cursor, dict) or not cursor:
            return True
        return cursor.get("pr_status") in PR_CLOSED

    def unknown_kind(self, kind, rid, repo: str, every: int) -> None:
        """Name, once per interval, a kind of work this file cannot place. Blocks nothing.

        **This is the only place a dropped kind can be seen at all, and where it sits is the
        argument for there being only one such place.** `review_desk_item` tests the kind BEFORE
        it asks whether a session is alive, so an item nobody here can place is named whether or
        not a session owns that review — which is what makes one loud site sufficient, and why
        `Watcher.review_desk` stays silent about the same item instead of repeating it every
        twenty seconds while a draft waits.

        DEV-934 is what it is for. Review Desk added a fifth `WorkKind` in DEV-877; this file
        went on naming four, and `nits_to_ticket` reached no session and said nothing about
        itself. It was found by reading the two sources side by side, which is the only way it
        could have been found: there was no line anywhere to grep for.

        Loud is never blocking. The item is left exactly as unhandled as it was, nothing is
        dispatched on a guess, and the tick carries on — the loudness is about the operator
        being able to ask for the handling, not about this file doing something it cannot do.

        **The signature is the kind's name and nothing else.** Keyed on the review as well, a
        repository holding fifty items of a new kind would emit fifty lines about one missing
        feature. The actionable fact is the name, and `repo` and `review_desk_id` both ride along
        as ONE EXAMPLE each of where it was seen — the first repository the tick reached, not the
        extent of it. A global signature and a per-repository field in the same event would
        otherwise read as "this kind is waiting there", when it may be waiting in all of them.

        What it rests on, said rather than assumed: the poller has to be ASKING about that
        repository. `review_desk_repos` takes them from `allele.repo_project_map` and from the
        `repo` on every ledger entry, so a review claimed without `repo=` — which SKILL.md's
        dispatch step writes and nothing else does — would be named by nobody, the watcher being
        silent by design.
        """
        if not isinstance(kind, str) or not kind or kind in REVIEW_DESK_IGNORED_KINDS:
            return
        if not self.due(f"review_desk|unknown_kind|{kind}", every):
            return
        emit("review_desk_unknown_kind", kind=kind, repo=repo, review_desk_id=rid,
             known=list(REVIEW_DESK_KINDS),
             detail=f"Review Desk reported work of kind '{kind}', which this dispatcher has no "
                    f"handling for. Nothing was dispatched for it and nothing is blocked; the "
                    f"item stays on Review Desk's list for a version that knows it. `repo` and "
                    f"`review_desk_id` are one example of where it was seen, not the extent of "
                    f"it — this is said once per kind, not once per repository.")

    def harvest(self, cfg: dict, ledger: dict, backlog: bool) -> None:
        """Read posted reviews' outcomes back from GitHub, one repository a tick.

        `review-desk harvest` has existed since DEV-859 and **nothing called it**, so layer 7 of
        every posted review read `pending` for ever and `workers/review.md` said of it "nothing
        you do". That sentence was true of the session and nobody had been given the job. The
        poller is where it belongs because of what a harvest reads: a reply to a finding, a
        thread the author resolved, a line changed since the review was posted. Those arrive
        hours or days after the session that wrote the review is gone, and this is the one
        process in the dispatcher that outlives every review.

        **The first call in this file that WRITES to Review Desk**, and three properties are
        what make that safe to do from a poll tick:

          * It cannot sign off. A harvest records what GitHub already says; approving a draft
            and posting a review are not on its surface at all, so the rule that only the
            developer signs off is untouched by it.
          * Running it twice records nothing twice — Review Desk's own README — so a harvest
            killed at the timeout, or run twice by two instances serving one repository, is one
            that recorded LESS rather than one that recorded wrongly. There is no lease and
            nothing here invents one.
          * It commits nothing of the POLLER's own, so `trust_empty` has nothing to guard here,
            for the same reason it has nothing to guard in `review_desk`.

        **What it does NOT do is move layer 7's row**, and that is worth writing down because
        the symptom this fixes looks like it would. In Review Desk 0.1.0 the only writer of that
        layer is `draft posted`, which sets it `pending` with the detail "posted, waiting for
        the harvest"; nothing in the harvest crate writes a layer at all, so the row still reads
        that way after a harvest has recorded everything GitHub had to say. What a harvest
        changes is the RECORD — replies, resolved threads, lines changed since. The row is
        Review Desk's to advance, and DEV-931's own out-of-scope list puts what the dashboard
        shows after sign-off on that side of the line.

        An attempt is counted whatever it answers, and the thing being counted is the SLOW one:
        a timeout. So a repository whose harvest fails has had its turn, and waits an interval
        like any other — the next tick belongs to whichever repository has waited longest.

        **One harvest ATTEMPT per tick, and the arithmetic is the point rather than a detail.**
        A harvest is the only Review Desk call that goes to the network, so N repositories at
        `HARVEST_TIMEOUT` each would be N x 120s added to a tick whose interval is 300s —
        starving `liveness` and the heartbeat while the per-section try/except reported nothing
        wrong. One attempt bounds a tick at one timeout, and the repository that gets it is the
        one whose mark is oldest, so the turns rotate: with N repositories, a poll interval of P
        and a harvest interval of I, each repository is harvested every `max(I, N x P)`. Three
        repositories at the shipped 300s and 900s is 900s. Past that the effective interval
        stretches, which is the stated cost of refusing to let one tick hold N network calls.

        **The interval is a floor, not a clock, and the production host is why that matters.**
        Nothing here wakes itself up: `due()` only refuses to run again too soon. Under a host
        that leaves `poll` running the floor is the cadence, and under the one the principal
        actually drives — `poll --once` in the foreground, see the note in `__init__` — a
        harvest happens when they poll. Both are strictly more than the nothing that ran before.
        """
        rd = review_desk_cfg(cfg)
        if review_desk_off(rd):
            return
        repos = review_desk_repos(cfg, ledger)
        if not repos:
            # Same silence as `review_desk`: an instance with an unedited `repo_project_map` and
            # no reviews in its ledger has nothing to harvest and says nothing about harvesting.
            return
        every = harvest_interval(cfg)
        # The LONGEST-WAITING repository, which is not the first one in the sort — and the
        # difference is a repository that is never harvested at all. `due()` stamps absolute
        # time, so a sweep that took the first repository whose interval had elapsed handed the
        # one slot a tick has to the same early names for ever. Simulated against this loop:
        # five repositories at the shipped 300s poll and 900s interval harvested the first three
        # 66-68 times over sixteen hours and the fourth and fifth NOT ONCE, and under the host
        # the principal actually drives, where a tick is further apart than the interval, only
        # the alphabetically first repository was ever asked about. Those repositories keep
        # exactly the symptom this section exists to remove, silently.
        #
        # `min` over the marks is the whole fix: a repository with no mark sorts first, and if
        # the oldest mark is not due then no mark is, so one test still answers for all of them.
        # It is also what makes the arithmetic above true rather than aspirational.
        repo = min(repos, key=lambda r: self.state["emitted"].get(f"harvest|{r}", 0))
        if self.due(f"harvest|{repo}", every):
            state, payload, detail = review_desk_run(rd, "harvest", "--repo", repo, "--json",
                                                     timeout=HARVEST_TIMEOUT)
            if state == "absent":
                # One answer for every repository, and silent under `auto` — absent is silent is
                # the whole contract, and a dispatcher that has never heard of Review Desk must
                # not start talking about harvests. Under `on` the principal has said they
                # expect it to be there, so it is said once per interval.
                if review_desk_loud_when_absent(rd) and self.due("harvest|absent", every):
                    emit("harvest_failed", state="absent", mode=rd["mode"], repo=repo,
                         command=rd["command"], detail=detail)
                return
            if state != "ok":
                # Loud in every mode but `off`, once per interval per reason. The signature
                # carries the repository AND the detail, because `review_desk_run` builds its
                # own message from the first two arguments — "harvest --repo" for every
                # repository alike — so a signature without them would let one repository's
                # failure silence another's.
                if self.due(f"harvest|{state}|{repo}|{detail[:60]}", every):
                    emit("harvest_failed", state=state, mode=rd["mode"], repo=repo,
                         command=rd["command"], detail=detail)
                return
            self.harvested(repo, payload)

    @staticmethod
    def harvested(repo: str, payload) -> None:
        """Say what a harvest recorded, and say nothing when it recorded nothing.

        A quiet harvest is the normal case — it is run on a cadence rather than because
        something happened — so emitting per run would put a line in the Dispatcher's inbox
        every fifteen minutes saying that GitHub had no news. Emitting only when something was
        recorded is what makes layer 7 observable without making it noise: the one event says a
        posted review has replies, resolutions or changed lines in the record that were not
        there before, which is a thing a human may want to read and nothing anybody dispatches.
        """
        reviews = [r for r in ((payload or {}).get("harvest") or {}).get("reviews") or []
                   if isinstance(r, dict)]
        # `isinstance(..., int)` rather than `int(...)`: a field whose type Review Desk changed
        # should leave this counting the others, not raise a section error that reads as the
        # harvest having failed when it ran and recorded.
        counts = {field: sum(r[field] for r in reviews if isinstance(r.get(field), int))
                  for field in ("replies_recorded", "threads_resolved_recorded",
                                "code_changed_recorded")}
        if not any(counts.values()):
            return
        emit("harvest_recorded", repo=repo, reviews=len(reviews), **counts)

    def pr_state(self, repo: str, number: int) -> str | None:
        """`merged`, `open`, `closed`, or None when GitHub could not be asked.

        None is deliberately NOT read as closed by the caller. An item the dispatcher cannot
        place is better dispatched and discarded by a human who can read the pull request than
        dropped silently — the first is recoverable and the second loses the work. The event
        carries `pr_state: null` so the Dispatcher knows it was never established.
        """
        if (repo, number) in self.pr_states:
            return self.pr_states[(repo, number)]
        try:
            # `state` alone, and the field list is the whole of the bug this line replaced.
            # `gh pr view` has no `merged` field — that is the REST API's, which
            # `Watcher.pull_request` reads through `gh api` — so `--json state,merged` exits 1
            # with "Unknown JSON field", every call raised, and `pr_state` was null for every
            # item. A merged pull request was therefore never skipped against real GitHub.
            # The harness missed it because the stand-in `gh` answered the shape I had assumed;
            # the real run is what caught it, and the stand-in now refuses that field list.
            # `state` already carries it: OPEN, CLOSED or MERGED.
            info = gh("pr", "view", str(number), "-R", repo, "--json", "state")
            state = (info.get("state") or "").lower() or None
        except Exception:
            state = None
        self.pr_states[(repo, number)] = state
        return state

    def mark_quiet(self, quiet: bool, cfg: dict) -> None:
        """Count consecutive ticks that said nothing, so "nothing is happening" can be read.

        Quiet means *no events at all*, not "no work found", and the difference bites: a tick in
        which every section threw still emits an `error`, so it is not quiet — while the same
        tick 30 minutes later is, because `error()` rate-limits the same signature to once per
        1800s. Quiet therefore answers "is there anything to read", which is the question the
        cost of staying awake turns on. It does not answer "is the poller healthy"; that is what
        the error trail is for.

        This counts and nothing else. Whether an idle dispatcher should stop on its own, ask
        first, or stop only its poller is DEV-795's open decision and the principal's to make;
        a counter is useful under all three and commits to none, which is why it ships alone.
        """
        was = self.state.get("quiet_ticks", 0)
        if quiet:
            self.state["quiet_ticks"] = was + 1
            self.state.setdefault("quiet_since", now_iso())
            return
        if was:
            self.log_quiet_run(was, cfg)
        self.state["quiet_ticks"] = 0
        self.state.pop("quiet_since", None)

    def log_quiet_run(self, ticks: int, cfg: dict) -> None:
        """Append one line when a quiet run *ends*, so a threshold can be chosen from a
        distribution instead of from arithmetic.

        DEV-795 asks whether an idle dispatcher should stop itself, and warns in the same breath
        that the cost driving the question is the principal's observation rather than a measured
        figure — so it also warns against picking a threshold by arithmetic on it. This is the
        cheap measurement that replaces the arithmetic: after a week of real traffic the file
        answers how long quiet runs actually last overnight versus in the working day, which is
        the only honest input to an N-quiet-ticks threshold.

        Logged at the END of a run rather than each tick, because a run's length is the quantity
        of interest and a per-tick log would be 288 lines a day saying nothing.

        **The field order is the format.** Anything plotting this reads positionally or by key,
        and a dict literal keeps insertion order where a comprehension over a sorted set would
        not. Add new fields at the end.
        """
        record = {
            "ended_at": now_iso(),
            "started_at": self.state.get("quiet_since"),
            "ticks": ticks,
            "interval_secs": cfg["limits"]["poll_interval_secs"],
            "secs": ticks * cfg["limits"]["poll_interval_secs"],
        }
        try:
            with quiet_log().open("a") as handle:
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        except OSError as exc:
            # A measurement that cannot be written must not take the poller down with it.
            print(f"warning: cannot append to {quiet_log().name}: {exc}", file=sys.stderr)


def cmd_poll(args) -> None:
    runtime().mkdir(parents=True, exist_ok=True)
    poller = Poller()
    if getattr(args, "backlog", None) is not None:
        poller.first_tick = args.backlog
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        poller.tick()
        if args.once:
            return
        time.sleep(load_config()["limits"]["poll_interval_secs"])


# --------------------------------------------------------------------------- watch

ISSUE_Q = """
query($id: String!, $since: DateTimeOrDuration!) {
  issue(id: $id) {
    identifier description
    state { name type }
    labels { nodes { id name parent { id } } }
    comments(first: 50, filter: { createdAt: { gt: $since } }) {
      nodes { id body createdAt url parent { id } user { name } botActor { name } }
    }
    attachments(first: 25) { nodes { url } }
  }
}"""


class Watcher:
    def __init__(self, key: str, pr: str | None, as_: str | None = None) -> None:
        self.key = key
        # Two sessions legitimately watch one ticket — a coordinator and the child it gated.
        # One state file between them means a restart resumes from the other's cursor and
        # silently skips whatever arrived in between, which on a gated ticket is the answer
        # the whole stack is held behind. `--as` gives each reader its own cursor.
        self.path = watch_dir() / (f"{key}.{as_}.json" if as_ else f"{key}.json")
        self.state = read_json(self.path, {})
        self.fresh = not self.state
        entry = ledger_get(key) or {}
        self.mode = entry.get("mode") or ("review" if key.startswith("gh-") else "implement")
        self.own = f"agent:{key}/"
        if pr:
            repo, number = pr.rsplit("#", 1)
            self.state["pr"] = {"repo": repo, "number": int(number)}
        elif "pr" not in self.state and entry.get("repo") and entry.get("number"):
            self.state["pr"] = {"repo": entry["repo"], "number": int(entry["number"])}

    def tick(self, full: bool = True) -> None:
        """One pass. `full` is False on the cheap passes between two full ones.

        **The two cadences are the whole of DEV-931's second half, and the split is what keeps
        it from being a rate-limit incident.** `issue` asks Linear and `pull_request` makes four
        GitHub REST calls; `review_desk` and `draft_wait` are two local SQLite reads through
        `review-desk`. Running the lot every 20 seconds while a draft waits on the developer
        would be 720 GitHub calls an hour per watcher, against a 5,000/hr token the poller
        shares — for as long as a human leaves a draft `ready`, which can be a weekend, and
        near-silently, because `watch_error` only speaks when its signature changes.

        So a fast pass reads Review Desk and nothing else, and GitHub and Linear are asked
        exactly as often as they were before this existed. `cmd_watch` owns the clock; `full`
        defaults to True so `--once`, a test and any other host see the behaviour unchanged.
        """
        cfg = load_config()
        sections = ((self.issue, self.pull_request, self.review_desk, self.draft_wait) if full
                    else (self.review_desk, self.draft_wait))
        for section in sections:
            try:
                section(cfg)
            except Exception as exc:
                sig = f"{section.__name__}:{str(exc)[:80]}"
                if self.state.get("last_error") != sig:
                    self.state["last_error"] = sig
                    emit("watch_error", key=self.key, section=section.__name__, message=str(exc)[:400])
        if self.fresh:
            self.fresh = False
            emit("watching", key=self.key, label=self.state.get("label"), state=self.state.get("state"),
                 pr=self.state.get("pr"))
        write_json(self.path, self.state)

    def forget(self) -> bool:
        """Delete this reader's cursor. Only ever called when the key is finished with.

        A cursor's whole job is to remember where this reader got to, so that a restart does not
        re-report what it has already reported — and, more importantly, does not *skip* what
        arrived while it was down. Deleting one for a live key would do exactly that skipping,
        which is why this is not called on the ceiling path: a ceiling says the process has run
        long enough, never that the work is over.

        Nothing else removes them, which is the other half of DEV-795: `runtime/watch/` on the
        `tc-portal` instance held 123 cursors for 9 live watchers.
        """
        try:
            self.path.unlink()
            return True
        except FileNotFoundError:
            return False

    def issue(self, cfg: dict) -> None:
        if not LINEAR_KEY.match(self.key):
            return
        since = self.state.get("comments_since") or now_iso()
        issue = linear(cfg, ISSUE_Q, {"id": self.key, "since": since})["issue"]
        group = cfg["linear"]["label_group_id"]
        label = next((l["name"] for l in issue["labels"]["nodes"] if (l.get("parent") or {}).get("id") == group), None)
        state = issue["state"]["name"]
        digest = hashlib.sha1((issue.get("description") or "").encode()).hexdigest()
        if not self.fresh:
            for c in sorted(issue["comments"]["nodes"], key=lambda c: c["createdAt"]):
                if self.own in (c.get("body") or ""):
                    continue
                emit("comment", key=self.key, author=(c.get("user") or c.get("botActor") or {}).get("name"),
                     at=c["createdAt"], reply_to=(c.get("parent") or {}).get("id"), id=c["id"],
                     url=c.get("url"), body=clip(c.get("body")))
            if label != self.state.get("label"):
                if label is None:
                    emit("stop", key=self.key, reason=f"'{self.state.get('label')}' removed — a human took the ticket back")
                else:
                    emit("label_changed", key=self.key, previous=self.state.get("label"), current=label)
            if state != self.state.get("state"):
                kind = issue["state"]["type"]
                # A ticket reaching a *completed* state is the end of the work, not an
                # instruction to abandon it. `_common.md` tells a worker receiving `stop` to
                # write `status=stopped`, so firing one at a worker that has already reported
                # `done` makes it overwrite its own terminal status — which reads as "still
                # waiting" to a coordinator trying to close the parent.
                #
                # `canceled` is deliberately NOT covered. Cancelling a ticket is an abandon
                # instruction whatever the ledger says, and `state_changed` has no handler in
                # `_common.md`, so widening this to both types would drop that signal entirely.
                done_already = (ledger_get(self.key) or {}).get("status") in ("done", "merged")
                if kind == "canceled" or (kind == "completed" and not done_already):
                    emit("stop", key=self.key, reason=f"ticket moved to {state}")
                else:
                    emit("state_changed", key=self.key, previous=self.state.get("state"), current=state)
            if digest != self.state.get("description_sha"):
                emit("description_changed", key=self.key)
        newest = max([since] + [c["createdAt"] for c in issue["comments"]["nodes"]])
        self.state.update(comments_since=newest, label=label, state=state, description_sha=digest)
        if "pr" not in self.state:
            for attachment in issue["attachments"]["nodes"]:
                match = PR_URL.search(attachment.get("url") or "")
                if match:
                    self.state["pr"] = {"repo": match.group(1), "number": int(match.group(2))}
                    if not self.fresh:
                        emit("pr_linked", key=self.key, url=attachment["url"])
                    break

    def pull_request(self, cfg: dict) -> None:
        where = self.state.get("pr")
        if not where:
            return
        repo, n = where["repo"], where["number"]
        pr = gh("api", f"repos/{repo}/pulls/{n}")
        head, status = pr["head"]["sha"], ("merged" if pr.get("merged") else pr["state"])
        first = "pr_head" not in self.state
        since = self.state.get("pr_since") or now_z()
        seen = set(self.state.get("pr_seen", []))
        items = []
        if not first:
            for r in gh("api", f"repos/{repo}/pulls/{n}/reviews?per_page=100") or []:
                if r.get("submitted_at") and r["submitted_at"] > since:
                    items.append(("pr_review", r, {"review_state": r.get("state")}))
            for c in gh("api", f"repos/{repo}/pulls/{n}/comments?since={since}&per_page=100") or []:
                items.append(("pr_comment", c, {"path": c.get("path"), "line": c.get("line")}))
            for c in gh("api", f"repos/{repo}/issues/{n}/comments?since={since}&per_page=100") or []:
                items.append(("pr_comment", c, {}))
        ignore_bots = cfg["github"].get("ignore_bots", True)
        for kind, item, extra in sorted(items, key=lambda t: t[1].get("submitted_at") or t[1].get("created_at") or ""):
            ident = f"{kind}:{item['id']}"
            user = item.get("user") or {}
            body_text = item.get("body") or ""
            if ident in seen or self.own in body_text or (ignore_bots and user.get("type") == "Bot"):
                continue
            seen.add(ident)
            # another agent's comment is not a human reviewing: say so, or the worker treats proof as feedback
            other_agent = re.search(r"agent:([A-Za-z0-9-]+/\w+)", body_text)
            if other_agent:
                extra = {**extra, "by_agent": other_agent.group(1)}
            if kind == "pr_review" and not (item.get("body") or "").strip() and item.get("state") == "COMMENTED":
                continue  # the container for inline comments, which arrive on their own
            emit(kind, key=self.key, pr=n, author=user.get("login"), url=item.get("html_url"),
                 body=clip(item.get("body")), **extra)
        if not first and head != self.state.get("pr_head"):
            emit("pr_pushed", key=self.key, pr=n, previous=self.state.get("pr_head"), current=head)
        if not first and status != self.state.get("pr_status"):
            emit("pr_state", key=self.key, pr=n, previous=self.state.get("pr_status"), current=status)
        self.state.update(pr_head=head, pr_status=status, pr_since=now_z(), pr_seen=sorted(seen)[-500:])


    def review_desk(self, cfg: dict) -> None:
        """The developer's acts in the dashboard, relayed to the session that is waiting for them.

        Confirming a brief, approving or sending back a draft, and asking for the held-back
        findings to be filed as one ticket all happen in the dashboard and nowhere else. The
        session that wrote them cannot see the dashboard, so without this it waits forever — the
        "approval delivery" open question in Review Desk's own brief, which named this watcher as
        the candidate.

        **A `nits_to_ticket` is not an answer about the draft**, and the relay is what makes that
        visible rather than a thing a worker has to infer. Review Desk ranks the request above its
        "the draft is ready, nobody's turn" branch, so the item arrives while the draft is still
        waiting on the developer: the session files the ticket and goes back to waiting.
        `workers/review.md` says so in as many words, because the one failure that matters here
        is a session reading any dashboard click as a sign-off.

        Gated on the LEDGER carrying `review_desk_id`, which means two things at once: a review
        this instance never recorded is never polled for, and a session whose entry carries one
        is by definition working a recorded review. A `work list --review` failure therefore
        raises, and `tick()` turns it into a `watch_error` like any other section's — loud,
        once per changed signature, and never fatal.

        **An absent binary raises here where the poller stays silent, and the asymmetry is the
        point.** The poller's silence under `auto` is about an install that was never there. By
        the time an entry carries a review id, Review Desk HAS been there and has the record, so
        its disappearance is a broken install and broken is loud in every mode but `off`.

        It also emits on the FIRST tick, where `issue()` and `pull_request()` deliberately
        suppress their history. A replacement session arming its watcher over an already-approved
        draft has to be told at once; that is the whole of the resume path, and suppressing it
        would make the replacement wait for a state change that has already happened.
        """
        rd = review_desk_cfg(cfg)
        rid = (ledger_get(self.key) or {}).get("review_desk_id")
        if review_desk_off(rd) or rid is None:
            return
        state, items, detail = review_desk_work(rd, "--review", str(rid))
        if state != "ok":
            raise RuntimeError(f"review-desk work list --review {rid} ({state}): "
                               f"{detail or 'no detail'}")
        # `(kind, review_id, entered_at)` is Review Desk's own identity for an item, and it says
        # why: a draft sent back, revised and sent back again is `ready` in between, so the
        # second send-back rewrites the time and is a new item. Keying on `(kind, review_id)`
        # would silently drop the developer's second instruction.
        seen = set(self.state.get("rd_seen", []))
        for item in sorted(items, key=lambda i: i.get("entered_at") or 0):
            kind = item.get("kind")
            if kind not in REVIEW_DESK_WATCH_KINDS:
                # Silent, and for a kind nothing here has heard of as well. `Poller.unknown_kind`
                # names those, it does so for a review a live session owns — its kind test runs
                # before its liveness test — and this loop runs every twenty seconds while a
                # draft waits, so a second voice would be the noisiest possible way to report one
                # missing feature. `review_requested` is the KNOWN kind that lands here: a session
                # reading its own review does not need telling to start.
                continue
            ident = f"{kind}|{item.get('review_id')}|{item.get('entered_at')}"
            if ident in seen:
                continue
            seen.add(ident)
            # `note` is the developer's prose and is data, not instructions — Review Desk's
            # README says so of this exact field. Relayed verbatim in its own key.
            emit(kind, key=self.key, review_desk_id=rid, round=item.get("round"),
                 sign_off=item.get("sign_off"), entered_at=item.get("entered_at"),
                 note=item.get("note"), nit_ticket_status=item.get("nit_ticket_status"),
                 review=review_desk_link(rd, rid),
                 draft=review_desk_link(rd, rid, draft=True))
        self.state["rd_seen"] = sorted(seen)[-200:]

    def draft_wait(self, cfg: dict) -> None:
        """Record whether this review's draft is waiting on the developer, for the sleep to read.

        **This is the only question `work list` cannot answer**, and the reason is in its own
        help: "A review waiting on the *developer* is absent: this is what an agent is to do".
        Two red-team sessions both proposed deriving the answer from the empty `work list
        --review` the tick already makes, and it does not work — an empty list is equally the
        session being mid-review and the review being posted and finished, so a watcher reading
        it that way would poll fast through the whole review and then for ever after the post.
        One more local read is what buys an answer that is actually about the draft.

        **The status, and nothing else, is taken from the answer.** `draft show` also carries the
        event the developer chose and `approved_at`, and the thing that may act on an approval is
        the `draft_approved` work item `review_desk` relays above — Review Desk reporting the
        draft approved. This writes a cursor field a `time.sleep` reads. It emits nothing.

        **Silent on every failure, where `review_desk` above is loud.** It is an optimisation,
        not a signal: the `work list` call in the same tick has already raised a `watch_error`
        for a broken or absent binary, and saying it twice per tick at the fast cadence would be
        the noisiest possible way to report one install. A refusal is also the ordinary answer
        for most of a review's life — there is no draft to show until `draft put` has run — and
        every one of those cases means the same thing here: nobody is waiting, poll normally.
        """
        rd = review_desk_cfg(cfg)
        rid = (ledger_get(self.key) or {}).get("review_desk_id")
        if review_desk_off(rd) or rid is None:
            self.state.pop("draft_status", None)
            return
        state, payload, _ = review_desk_run(rd, "draft", "show", "--review", str(rid), "--json")
        status = ((payload or {}).get("draft") or {}).get("status") if state == "ok" else None
        if isinstance(status, str):
            self.state["draft_status"] = status
        else:
            # Popped rather than set to None, because absent means "not established" and a
            # present null would read, to anyone looking at the cursor, as a draft with no
            # status. Either way `watch_interval` sleeps the ordinary interval.
            self.state.pop("draft_status", None)


def watch_interval(cfg: dict, state: dict) -> int:
    """How long to sleep before the next pass: shorter while the draft waits on the developer.

    `min(quick, normal)`, because a "shorter interval" that is longer than the one it replaces is
    a setting that lies — and an instance that lengthened `watch_interval_secs` to spare an API
    budget must not have a new key quietly undo it.

    **A watcher on a Linear ticket never reaches the second branch**, which is worth stating
    because it bounds the whole change: `draft_status` is written only where the ledger entry
    carries a `review_desk_id`, and that is a review. Every other watcher on the box behaves
    exactly as it did, one full pass per `watch_interval_secs`, bit for bit.

    `watch_interval_secs` is still read the way every other `limits` key in this file is read,
    and raises on a config that does not have it. The new key is NOT, and the asymmetry is
    deliberate: `positive_secs` says why a key no config has written yet may not throw inside
    this loop.
    """
    normal = int(cfg["limits"]["watch_interval_secs"])
    if state.get("draft_status") != DRAFT_WAITING:
        return normal
    quick = positive_secs((cfg.get("limits") or {}).get("draft_watch_interval_secs"),
                          DRAFT_WATCH_INTERVAL_SECS)
    return min(quick, normal)


def full_pass_due(last_full: float, cfg: dict) -> bool:
    """Is a pass that asks Linear and GitHub due, `last_full` being when the last one started?

    `watch_interval_secs` keeps its original meaning here — how often the ticket and the pull
    request are read — and the short interval added by DEV-931 only inserts cheaper passes
    between two of them. A watcher with no draft waiting sleeps that same interval, so every
    pass is due when it wakes and this returns True on every one of them.
    """
    return time.time() - last_full >= int(cfg["limits"]["watch_interval_secs"])


def watch_stop_reason(key: str, state: dict, exit_on_done: bool) -> tuple[str, str] | None:
    """Why this watcher should stop, from local files only. `None` means carry on.

    One `open()` of a JSON file per tick, and no API call at all, which is what lets this run
    *before* the first tick as well as between them. That ordering is the difference between a
    fix and a busier bug: `_common.md` starts a watcher inside a persistent `Monitor`, so an
    exiting watcher may be relaunched immediately, and a relaunch onto a dead key has to cost one
    file read rather than the six GitHub calls a tick makes.

    `done` is the status DEV-795 and `implement.md` disagree about, and both are right about
    different halves of it:

      * The ticket lists `done` as terminal, which is correct once a PR has merged —
        `implement.md`'s "After you're done" writes `status=done --note "merged"`, leaving the
        status it already had. Merged keys outnumber discarded ones, so a watcher that holds on
        through a merge is the same leak under a politer name.
      * `implement.md` step 8 also writes `status=done` while the PR is still *open*, and then
        says "stay alive with your watcher running" so the worker can answer `pr_review` and
        `pr_comment`. Nothing else watches a done key's PR. Exiting there makes the worker deaf
        at the exact moment the review it is waiting for arrives.

    So `done` alone is not the discriminator and `pr_status` is: `Watcher.pull_request` already
    computes `("merged" if pr.get("merged") else pr["state"])` and persists it in the cursor, so
    the distinction costs another local read and no request. A `done` key whose PR is merged or
    closed stops on the next tick; a `done` key with an open PR stops only at the ceiling.

    **A `done` key with no pull request at all is terminal**, and getting that wrong was the one
    real leak in the first version of this function. `investigate.md`, `decide.md` and
    `decompose.md` all write `status=done` and never open a PR, while `_common.md` step 3 arms a
    watcher for every mode — so gating the whole `done` branch on `pr_status`, a field only
    `pull_request()` ever sets, left every finished non-PR worker running to the ceiling and
    reported it as `working` to both `doctor` and `reap`. The review loop is the *only* reason
    `done` is not terminal, so the exception has to be conditional on there being a review to wait
    for. `state["pr"]` is that test: `Watcher.__init__` fills it from `--pr` or the ledger's
    `repo`/`number`, and `issue()` fills it from the ticket's attachments.

    `--exit-on-done` is the ticket's acceptance criterion taken literally, kept because it is the
    behaviour the principal asked for and the choice is his. It is not the default, and the
    reason is in the PR.

    The third element of the return is **whether the ledger alone decided it**, which is what tells
    `cmd_watch` it may delete the cursor. Terminality read from the ledger is reconstructible on the
    next process; terminality read from a file you are about to delete is not.
    """
    status = (ledger_get(key) or {}).get("status")
    if status in WATCH_DEAD:
        return status, f"ledger status '{status}' — nothing will speak on this key again", True
    if status == "done":
        if exit_on_done:
            return status, "ledger status 'done' and --exit-on-done was given", True
        if not state.get("pr"):
            return status, "ledger status 'done' and no pull request to watch", True
        pr = state.get("pr_status")
        if pr in PR_CLOSED:
            # Cursor kept: `pr_status` lives only in it, so deleting it would make the next
            # relaunch re-derive the merge over a full tick's API calls, forever.
            return status, f"ledger status 'done' and its PR is {pr}", False
    return None


def cmd_watch(args) -> None:
    cfg = load_config()
    hours = args.max_hours if args.max_hours is not None else float(
        cfg["limits"].get("watch_max_hours", WATCH_MAX_HOURS))
    # Wall-clock, and from THIS process's start rather than the key's. Two deliberate choices:
    #
    #   * Not ticks. `watch_interval_secs` is 90 in the shipped config and 300 on `tc-portal`, so
    #     a ceiling counted in ticks is a different amount of time on every instance — and the
    #     ticket rules out "cheaper ticks forever" for the same reason it has to rule out
    #     "a ceiling that shortens when you shorten the interval".
    #   * Not persisted. Storing the deadline in the cursor would carry it across relaunches, so
    #     one expiry would make the key permanently unwatchable and no operator action short of
    #     deleting state would bring it back. A process ceiling is recoverable by restarting;
    #     that is the whole point of a backstop whose primary is the ledger check.
    expires = time.time() + hours * 3600
    watcher = Watcher(args.key, args.pr, args.as_)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if ledger_get(args.key) is None:
        # A key with no ledger entry is a typo or a watcher started before its dispatch. Neither
        # is fatal — `Watcher` tolerates a missing entry by design — but silence here is how a
        # mistyped key spends the whole ceiling polling a ticket nobody is working.
        emit("watch_unknown_key", key=args.key,
             detail=f"no ledger entry for '{args.key}'; watching anyway until the ceiling")
    ticks = 0
    # The clock for `Watcher.tick`'s two cadences. Zero so the first pass is always a full one:
    # `issue` and `pull_request` suppress their history on their first run, and a process whose
    # first pass skipped them would have nothing to suppress and would report a ticket's whole
    # backlog the first time it did run them.
    last_full = 0.0
    while True:
        stop = watch_stop_reason(args.key, watcher.state, args.exit_on_done)
        if stop:
            status, why, from_ledger = stop
            emit("watch_stopped", key=args.key, reason="ledger", status=status, ticks=ticks,
                 cursor_removed=from_ledger and watcher.forget(), detail=why)
            return
        full = full_pass_due(last_full, load_config())
        if full:
            last_full = time.time()
        watcher.tick(full=full)
        ticks += 1
        if args.once:
            return
        if args.max_ticks and ticks >= args.max_ticks:
            emit("watch_stopped", key=args.key, reason="max_ticks", ticks=ticks, cursor_removed=False,
                 detail=f"--max-ticks {args.max_ticks} reached; the key is not finished, so the "
                        f"cursor is kept and the same command resumes from it")
            return
        if time.time() >= expires:
            emit("watch_stopped", key=args.key, reason="ceiling", ticks=ticks, cursor_removed=False,
                 detail=f"ran {hours:g}h without the ledger going quiet (limits.watch_max_hours); "
                        f"the key is not finished, so the cursor is kept and the same command "
                        f"resumes from it")
            return
        # Re-read, rather than reusing the `cfg` above: the sleep has always taken the config
        # as it is NOW, so that an interval edited under a long-running watcher takes effect
        # without a restart. `watcher.state` is what the pass just wrote, so a draft that went
        # `ready` in this pass is polled at the shorter interval from this sleep onwards.
        time.sleep(watch_interval(load_config(), watcher.state))


# --------------------------------------------------------------------------- label / comment

LABEL_Q = """
query($id: String!) {
  issue(id: $id) { id identifier labels { nodes { id name parent { id } } } team { states { nodes { id name } } } }
}"""


def cmd_label(args) -> None:
    cfg = load_config()
    labels = cfg["linear"]["labels"]
    if args.label != "none" and args.label not in labels:
        raise SystemExit(f"unknown label state '{args.label}'; one of: none, {', '.join(labels)}")
    if args.label != "none" and not labels[args.label].get("id"):
        # Without this the id travels as a null against `$add: String!` and Linear answers with
        # a variable-type error, which reads as a bug in this program rather than as a config
        # that was never reconciled against the workspace.
        raise SystemExit(f"'{args.label}' has no label id in config.json. Re-run "
                         f"`dispatcher.py init --instance <slug> --team-key KEY` to mint it.")
    issue = linear(cfg, LABEL_Q, {"id": args.issue})["issue"]
    group = cfg["linear"]["label_group_id"]
    target = labels[args.label]["id"] if args.label != "none" else None
    current = [l for l in issue["labels"]["nodes"] if (l.get("parent") or {}).get("id") == group]
    # Every id travels as a variable. This is the only mutation in the file assembled by hand,
    # and its label ids come straight out of config.json — a file this program's own `init`
    # closes by telling the user to go and edit. Interpolating them produced valid injected
    # GraphQL when tested with a hostile id; parameterising costs nothing and ends it.
    variables: dict[str, str] = {"issueId": issue["id"]}
    parts = []
    for i, label in enumerate(current):
        if label["id"] == target:
            continue
        variables[f"r{i}"] = label["id"]
        parts.append(f"r{i}: issueRemoveLabel(id: $issueId, labelId: $r{i}) {{ success }}")
    if target and target not in [l["id"] for l in current]:
        variables["add"] = target
        parts.append("add: issueAddLabel(id: $issueId, labelId: $add) { success }")
    if args.state:
        state = next((s for s in issue["team"]["states"]["nodes"] if s["name"].lower() == args.state.lower()), None)
        if not state:
            raise SystemExit(f"no workflow state '{args.state}' on this team")
        variables["stateId"] = state["id"]
        parts.append("st: issueUpdate(id: $issueId, input: { stateId: $stateId }) { success }")
    if parts:
        declarations = ", ".join(f"${name}: String!" for name in variables)
        linear(cfg, f"mutation({declarations}) {{\n" + "\n".join(parts) + "\n}", variables)
    before = ", ".join(l["name"] for l in current) or "none"
    after = labels[args.label]["name"] if target else "none"
    if ledger_get(issue["identifier"]):
        ledger_put(issue["identifier"], {}, note=f"label {before} -> {after}" + (f"; state -> {args.state}" if args.state else ""), by=args.by)
    print(f"{issue['identifier']}: {before} -> {after}" + (f" (state: {args.state})" if args.state else ""))


def cmd_comment(args) -> None:
    cfg = load_config()
    key = args.key or args.issue
    mode = args.mode or (ledger_get(key) or {}).get("mode") or "agent"
    body = sys.stdin.read().strip()
    if not body:
        raise SystemExit("empty comment body on stdin")
    signed = f"🤖 **Agent · {mode}** · `{marker(key, mode)}`\n\n{body}"
    issue_id = linear(cfg, 'query($id: String!) { issue(id: $id) { id } }', {"id": args.issue})["issue"]["id"]
    data = {"issueId": issue_id, "body": signed}
    if args.reply_to:
        data["parentId"] = args.reply_to
    out = linear(cfg, "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { url } } }",
                 {"input": data})
    print(out["commentCreate"]["comment"]["url"])


# --------------------------------------------------------------------------- brief

def cmd_brief(args) -> None:
    cfg = load_config()
    entry = ledger_get(args.key)
    if not entry:
        raise SystemExit(f"no ledger entry for {args.key}; `ledger put` it first")
    mode = entry["mode"]
    t = cfg["traits"][mode]
    if mode == "review":
        subject = f"PR {entry['repo']}#{entry['number']} — {entry.get('title', '')} — {entry.get('url', '')}"
        task = (f"Prepare your principal's review of {entry['repo']}#{entry['number']}. "
                f"They drive the review; you do the legwork.")
    else:
        subject = f"{args.key} — {entry.get('title', '')} — {entry.get('url', '')}"
        task = f"{mode.capitalize()} Linear ticket {args.key}, working autonomously through the brief below."
    # The fallback head below existed for a `locus` that ran and failed, and `subprocess.run`
    # raises rather than returning for a `locus` that is not there at all — so this command
    # crashed with a traceback on any machine without the binary, including every CI runner.
    # Found by the first test ever to drive `brief`, in DEV-865's harness. A brief is how a
    # worker gets dispatched, so there is no reading of this file on which that is acceptable.
    plain = f"You are {t['role']}.\n\nYour task: {task}"
    try:
        composed = subprocess.run(
            ["locus", "agent", "compose", "--traits", t["traits"], "--role", t["role"],
             "--task", task], capture_output=True, text=True)
        head = composed.stdout.strip() if composed.returncode == 0 else plain
    except (OSError, subprocess.SubprocessError):
        head = plain
    # Briefs resolve against CODE_DIR; only the instance flag carries state. Pointing these at
    # the instance directory is the silent failure in this file: every worker would start by
    # failing to read a brief that was never installed there.
    workers = CODE_DIR / "workers"
    # The absolute instance path, not the slug. A worker is a fresh session that inherits none
    # of this process's environment, so a bare slug resolves against the DEFAULT home — which
    # is the wrong directory, or none, whenever DISPATCHER_HOME is set here.
    tool = f"python3 {CODE_DIR / 'dispatcher.py'} --instance {instance()}"
    extra = []
    # The allele group, named in every brief, for two readers at once. Whoever is about to
    # create this session reads it off the brief it is already holding — which is why there is
    # no second command to run at dispatch time and why a config with no `allele.groups` block
    # still dispatches into one — and the session itself reads it as the group its own helpers
    # go in. A worker can read no config, so the brief is the only channel either way.
    #
    # The ledger wins over the mode's default when it carries one, and that is the whole of
    # inheritance: a coordinator writes `group=<its own group>` on a child's claim, so the
    # child's brief names the group the coordinator was dispatched with rather than the group
    # its own mode would have had.
    #
    # A recorded string is the answer, the empty one included: `group=""` on a claim is a
    # coordinator saying ungrouped, and falling back to the mode's default there would override
    # the session that actually knows.
    recorded = entry.get("group")
    if isinstance(recorded, str):
        group = recorded.strip() or None
        if group and len(group) > MAX_GROUP_LEN:
            group = None
    else:
        group = group_for(cfg, mode)
    if group:
        extra.append(f"- Allele group: `{group}`. Pass `group: \"{group}\"` on every "
                     f"`allele_sessions_create` you issue, so your helpers sit with you in the "
                     f"sidebar — **only if the tool you have been given lists a `group` "
                     f"parameter**. An allele that predates it refuses an unknown parameter, so "
                     f"when it is absent, dispatch without it and say nothing.")
    else:
        extra.append("- Allele group: none. Dispatch your helpers with no `group` argument.")
    production_mcp = (cfg.get("tools") or {}).get("production_mcp")
    if production_mcp:
        extra.append(f"- Production reads: the `{production_mcp}` MCP, read-only, aggregates and ids only.")
    if mode in ("review", "implement"):
        extra.append("- Review craft: invoke the `review-craft` skill for the house style, the lenses and the linter.")
    if mode == "review":
        # Named either way. A worker cannot read this config — the brief is the only channel —
        # and "it is on" is as load-bearing as "it is off": step 3 is not optional when it is on.
        on = bool(review_cfg(cfg)["blind_options_pass"])
        extra.append(
            "- Blind options pass: **on**. `review.md` step 3 — dispatch it, and reclaim it when "
            "it reports." if on else
            "- Blind options pass: **off** for this instance. Skip `review.md` step 3, say so once "
            "in your provenance and in your report, and mark every option as the ticket's.")
    # Review Desk is named in the brief ONLY for a review, and only when it is configured on.
    # `auto` with nothing installed adds no line at all, which is what keeps a worker on a
    # machine without it reading exactly the brief it read before this existed.
    rd = review_desk_cfg(cfg)
    if mode == "review" and not review_desk_off(rd):
        extra.append(f"- Review Desk: `{rd['command']}`, mode `{rd['mode']}`, brief gate "
                     f"`{rd['brief_gate']}`, dashboard {rd.get('url') or '(no url set)'}. "
                     f"Follow `review.md`'s **With Review Desk** section if `work list` answers; "
                     f"if the command is not there, mode `auto` means carry on exactly as the "
                     f"steps above say and say nothing about it.")
        rid = entry.get("review_desk_id")
        if rid is not None:
            # A replacement is TOLD, rather than left to infer it. `_common.md` step 1 already
            # says an earlier session in the history makes you a replacement, but a review
            # started from the dashboard has no earlier session of ours at all — the record is
            # the only thing that carries the history, and this is the line that names it.
            extra.append(f"- **You are resuming Review Desk review {rid}**, which already holds "
                         f"the brief, the findings and any draft. Read it with `{rd['command']} "
                         f"review show --review {rid}` BEFORE anything else, and continue from "
                         f"what is there rather than starting again. "
                         f"{review_desk_link(rd, rid) or ''}")
    print(f"""{head}

## Dispatch
- Ledger key: `{args.key}` · mode: `{mode}`
- Subject: {subject}
- Why: {entry.get('why', 'label/review request seen by the Dispatcher')}
- Brief: read `{workers / '_common.md'}` then `{workers / f'{mode}.md'}` and follow them. They override any habit of stopping to ask.
- Tool: `{tool}` (watch · label · comment · ledger)
- Linear MCP workspace: `{cfg['linear']['mcp_workspace']}`
{chr(10).join(extra)}
- The Dispatcher that sent you is reachable at the reply address allele gave you above. Report to it on every status change.

Start now: read the two brief files, then begin.""")


# --------------------------------------------------------------- the posting check

def normalise_body(text: str | None) -> str:
    """Compare two review bodies the way two systems can actually agree on.

    GitHub hands back a body it has stored, and what it stores is not byte-identical to what was
    sent: line endings come back as CRLF where the poster sent LF, and trailing spaces survive a
    round trip in one direction and not the other. A byte-exact comparison therefore answers "no
    matching review" about the very review it is looking at, and the caller posts a second one on
    somebody's pull request. Normalising is not laxness here; byte-exactness is the bug.
    """
    lines = (text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    return "\n".join(line.rstrip() for line in lines).strip()


def gh_pages(payload) -> list:
    """Flatten `gh api --paginate --slurp`, tolerating a single page that was not wrapped.

    `--slurp` wraps each page in an outer array, so the shape is a list of lists. Both shapes are
    accepted because the one that matters is cheap to accept and getting it wrong means reading
    an empty list of reviews — which is the answer that posts a duplicate.
    """
    if not isinstance(payload, list):
        return []
    if payload and isinstance(payload[0], list):
        return [item for page in payload for item in (page or [])]
    return payload


def cmd_review_posted(args) -> None:
    """Has the principal's approved review already been posted on this pull request?

    Read-only, and the one thing standing between `draft_approved` and a duplicate review on
    somebody's pull request. Review Desk leaves `draft_approved` listed until something reports
    the draft posted — it has no lease and says so — so a session that posts and then dies is
    followed by one that would post again. GitHub is the only system that knows, which is why
    this lives here rather than in a brief: a check only written down in prose is a check that
    cannot be tested, and this one's failure mode is public.

    **Three tests, and all three must hold**, because each one on its own matches something it
    should not:

      login  the principal's, so the author's review and a bot's are not mistaken for ours.
      time   submitted at or after the approval, so the previous round's review is not. A tie on
             the second resolves to "after": the inclusive side is the one that SKIPS the post,
             and between a missed duplicate and a caused one there is no contest.
      body   the approved text, normalised, so the principal's own hand-written review on the
             same pull request is not read as this draft.

    A `PENDING` review is GitHub's word for one that exists and has not been submitted. It is not
    posted and must not be counted.
    """
    cfg = load_config()
    entry = ledger_get(args.key)
    if not entry:
        raise SystemExit(f"no ledger entry for {args.key}; this check reads its repo and number")
    repo, number = entry.get("repo"), entry.get("number")
    if not repo or not number:
        raise SystemExit(f"{args.key} carries no repo/number in the ledger, and this check needs "
                         f"both to ask GitHub anything")
    login = (cfg["github"].get("login") or "").strip().lower()
    if not login:
        raise SystemExit("github.login is not set in config.json, so there is no author to match")
    body = sys.stdin.read() if args.body_file == "-" else Path(args.body_file).read_text()
    want = normalise_body(body)
    # Paginated, because a long-lived pull request can hold more than one page of reviews and the
    # principal's is as likely to be on the second. `per_page=100` alone was the first version of
    # this line, and it is exactly the shape that posts a duplicate on a busy pull request.
    reviews = gh_pages(gh("api", "--paginate", "--slurp",
                          f"repos/{repo}/pulls/{number}/reviews?per_page=100"))
    hit = None
    for review in reviews:
        if (review.get("user") or {}).get("login", "").strip().lower() != login:
            continue
        if (review.get("state") or "").upper() == "PENDING":
            continue
        at = review.get("submitted_at")
        if not at or parse_iso(at) < float(args.approved_at):
            continue
        if normalise_body(review.get("body")) != want:
            continue
        hit = review
        break
    if args.json:
        print(json.dumps({"posted": bool(hit), "review_id": (hit or {}).get("id"),
                          "submitted_at": (hit or {}).get("submitted_at"),
                          "state": (hit or {}).get("state"), "repo": repo, "number": number,
                          "login": login, "reviews_read": len(reviews)}, ensure_ascii=False))
    elif hit:
        print(f"posted: review {hit['id']} by {login}, {str(hit.get('state', '')).lower()}, at "
              f"{hit.get('submitted_at')} — do NOT post again. Record it with "
              f"`review-desk draft posted --review <id> --github-review {hit['id']}`.")
    else:
        print(f"not posted: none of the {len(reviews)} review(s) on {repo}#{number} is by "
              f"{login}, at or after the approval, with this body. Posting is the next step.")


# --------------------------------------------------------------------------- status / doctor

def cmd_ledger(args) -> None:
    if args.action == "list":
        for key, entry in ledger_all().items():
            if args.all or entry.get("status") in ALIVE | {"queued"}:
                print(f"{key:<22} {entry.get('mode', ''):<12} {entry.get('status', ''):<12} {entry.get('session_name') or '-'}")
    elif args.action == "children":
        # Parent fan-out recovery. A coordinator that died leaves live children, and this is
        # the only way to find them: `parent` is written on every child and, until this
        # existed, read by nothing — so a replacement coordinator re-dispatched live children
        # onto live branches.
        #
        # Prints every status on purpose, not just ALIVE. A replacement that cannot see the
        # discarded and failed children will dispatch them again, which is the same defect
        # wearing a different hat.
        for key, entry in sorted(ledger_all().items()):
            if entry.get("parent") == args.key:
                print(f"{key:<22} {entry.get('mode', ''):<12} {entry.get('status', ''):<12} "
                      f"{entry.get('session_id') or '-':<38} {entry.get('session_name') or '-'}")
    elif args.action == "get":
        print(json.dumps(ledger_get(args.key), indent=2, ensure_ascii=False))
    else:
        fields = {}
        for pair in args.fields:
            k, _, v = pair.partition("=")
            try:
                fields[k] = json.loads(v)
            except json.JSONDecodeError:
                fields[k] = v
        entry = ledger_put(args.key, fields, note=args.note, by=args.by)
        print(f"{args.key}: {entry.get('status')}")


def allele_dispatched(live: dict) -> int:
    """Sessions allele counts against its own cap.

    The discriminator is `origin.kind == "dispatched"`, verified against a live
    ~/.allele/state.json — an earlier proposal for this line read a boolean `origin.dispatched`
    that does not exist, and would have printed 0 forever.

    No state filter, deliberately: allele's `live_dispatched_count` filters on
    `origin.is_dispatched()` alone, and its own comment says "'Exist' is literal: a suspended
    or finished worker holds its slot until it is discarded."
    """
    return sum(1 for s in live.values() if (s.get("origin") or {}).get("kind") == "dispatched")


def allele_dispatch_limit(cfg: dict) -> str:
    """`dispatch.max_sessions` from allele's settings, or '?' if it cannot be read.

    Unreadable is not zero and must never print as a number: a cap of 0 would read as "you
    are already over" and a cap of 35 read from nowhere would read as headroom that may not
    exist. `D status` is a diagnostic, so it says it does not know.
    """
    path = (cfg.get("allele") or {}).get("settings_file") or "~/.config/allele/settings.json"
    try:
        return str(json.loads(Path(path).expanduser().read_text())["dispatch"]["max_sessions"])
    except Exception:
        return "?"


def quiet_runs() -> list[int]:
    """Lengths of the quiet runs recorded so far. Unreadable or absent reads as none, because a
    diagnostic that fails on its own optional log file is worse than one that says nothing."""
    try:
        lines = quiet_log().read_text().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            out.append(int(json.loads(line)["ticks"]))
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            continue
    return out


def last_error() -> str | None:
    """The newest record in the poller's error log, for `status`. None when there is none.

    Read defensively on purpose: a `status` that raises because the error log is unreadable would
    hide every other number on the line, which is the opposite of what the log is for.
    """
    try:
        lines = [l for l in error_log().read_text(errors="replace").splitlines() if l.strip()]
    except OSError:
        return None
    if not lines:
        return None
    try:
        record = json.loads(lines[-1])
    except ValueError:
        return lines[-1][:200]
    # `ago` rather than a bare `pass`: an unreadable `at` used to drop the age from the line with no
    # sign it had been dropped, which is the same conflation `ago` was fixed to avoid.
    age = f", {ago(record.get('at'))}"
    return f"{record.get('section')}{age}: {record.get('error')} · {len(lines)} in {error_log()}"


def ago(stamp: str | None) -> str:
    """A human age for a stored timestamp, distinguishing absent data from unreadable data.

    `except Exception` rather than a tuple, deliberately. `parse_iso(None)` raises `AttributeError`
    on `None.replace`, which the original tuple did not catch — so a `sources` bucket written by
    another version of this file, with different key names, took `status` down with it. `status` is
    SKILL.md start-up step 2, and a diagnostic that raises is worse than one that shrugs.
    """
    if stamp is None:
        return "never"
    try:
        return f"{int(time.time() - parse_iso(stamp))}s ago"
    except Exception:
        return "unreadable"


def source_summary() -> str | None:
    """Per-source counts for `status`: what each source last returned, and when it last had work.

    This is the line that would have shown DEV-794 on the day. `poller heartbeat: 31s ago` was true
    throughout an incident in which the GitHub search was returning nothing over ten open review
    requests, because a heartbeat measures the process and not what the process could see.
    """
    sources = read_json(poll_state(), {}).get("sources") or {}
    if not sources:
        return None
    parts = []
    for name in sorted(sources):
        seen = sources[name]
        part = f"{name} {seen.get('last_count', '?')} items {ago(seen.get('last_at'))}"
        if not seen.get("last_count") and seen.get("last_nonempty_at"):
            part += f" (last non-empty {ago(seen['last_nonempty_at'])})"
        if seen.get("zero_streak"):
            part += f" [{seen['zero_streak']} empty in a row]"
        parts.append(part)
    return " · ".join(parts)


def cmd_status(args) -> None:
    cfg = load_config()
    try:
        live, archived = allele_state(cfg)
    except Exception as exc:
        live, archived = {}, set()
        print(f"(allele state unreadable: {exc})")
    hb = heartbeat()
    beat = hb.read_text().strip() if hb.exists() else None
    age = f"{int(time.time() - parse_iso(beat))}s ago" if beat else "never"
    # Two counts, deliberately side by side, because they measure different things and only
    # one of them bites. `max_workers` refuses nothing anywhere in this file — it is a number
    # the Dispatcher is asked to respect — and it counts *ledger entries*, while allele counts
    # *sessions*. They diverge by exactly the reviewers each worker dispatches, which never
    # reach the ledger: `D status` has read `working 0/15` while allele held fifteen.
    print(f"poller heartbeat: {age} · ledger working {working_count()}/{cfg['limits']['max_workers']}"
          f" (advisory) · allele dispatched {allele_dispatched(live)}/{allele_dispatch_limit(cfg)}"
          f" (enforced)")
    # The heartbeat above says the poller is alive. It does NOT say an event reached anyone, and
    # DEV-794 is three hours of `heartbeat 31s ago` over a poller that surfaced 1 of 10 review
    # requests. Until the event channel is acknowledged rather than hoped at, the most useful
    # second number is whether a section has been throwing -- which stdout may never have carried.
    # What each source last returned. An empty source is the failure mode the heartbeat cannot
    # see, and the one that cost six days of unsurfaced review requests (DEV-794, DEV-799).
    sources = source_summary()
    print(f"sources: {sources}" if sources else "sources: nothing recorded yet")
    failure = last_error()
    print(f"last poller error: {failure}" if failure else "last poller error: none recorded")
    # "Nothing is happening" was previously only inferable — from a heartbeat that advances whether
    # or not anything was delivered. This says it. `quiet_since` is the honest half of the pair: a
    # count of ticks means nothing without the interval that produced them.
    quiet = read_json(poll_state(), {})
    # The recorded runs print either way. A poll-state that has never started still sits beside a
    # quiet-log from a previous install or a restored backup, and a measurement that exists but is
    # not shown is the same failure as not taking it.
    runs = quiet_runs()
    seen = f" · {len(runs)} run(s) recorded, longest {max(runs)} ticks" if runs else ""
    if not quiet.get("started"):
        print(f"quiet ticks: — (this instance has never polled){seen}")
    else:
        ticks = quiet.get("quiet_ticks", 0)
        since = f" since {quiet['quiet_since']}" if ticks and quiet.get("quiet_since") else ""
        print(f"quiet ticks: {ticks} consecutive{since}"
              f"{' — no events delivered' if ticks else ' — last tick had events'}{seen}")
    print(f"{'KEY':<22} {'MODE':<12} {'LEDGER':<12} {'ALLELE':<14} SESSION")
    for key, entry in ledger_all().items():
        if not args.all and entry.get("status") not in ALIVE | {"queued"}:
            continue
        sid = entry.get("session_id")
        allele = (live.get(sid) or {}).get("last_known_status") or ("archived" if sid in archived else ("missing" if sid else "-"))
        print(f"{key:<22} {entry.get('mode', ''):<12} {entry.get('status', ''):<12} {allele:<14} {entry.get('session_name') or '-'}")


# --------------------------------------------------------------------------- watchers on the box

# Flags of `watch` that consume the next token. Needed because the tokeniser below has to know
# which bare word is the ledger key: `watch --pr Trilogy-Care/tc-portal#9395 DAR-614` is a real
# command line off this machine, and a walker that skipped only `--instance`'s value would read
# the repo#number as the key, look it up, find no entry, and report the wrong thing.
# `--max-ticks` and `--max-hours` are here because they were added by the same change as this set
# and were missed: `watch --max-hours 2 DAR-563` parses `2` as the key, which spares a real orphan
# forever and lists it under a key that does not exist. Any flag added to the `watch` parser that
# takes a value must be added here too, and a `store_true` flag must not be.
WATCH_VALUE_FLAGS = {"--instance", "--as", "--pr", "--max-ticks", "--max-hours"}


def etime_secs(etime: str) -> int | None:
    """`ps` elapsed time to seconds. Four widths in the wild: `04:26`, `15:05:54`, `01-20:16:46`
    and `06-14:12:27`. Display only — nothing in `reap` gates a signal on age, and if anything
    ever does, this parser stops being cosmetic."""
    days, _, rest = etime.strip().rpartition("-")
    try:
        parts = [int(p) for p in rest.split(":")]
        offset = int(days or 0) * 86400
    except ValueError:
        return None
    if len(parts) not in (2, 3):
        return None
    secs = 0
    for part in parts:
        secs = secs * 60 + part
    return offset + secs


def age_words(etime: str) -> str:
    secs = etime_secs(etime)
    if secs is None:
        return etime
    days, rest = divmod(secs, 86400)
    hours, rest = divmod(rest, 3600)
    if days:
        return f"{days}d{hours}h"
    return f"{hours}h{rest // 60:02d}m" if hours else f"{rest // 60}m{rest % 60:02d}s"


def parse_watch_argv(argv: list[str]) -> dict | None:
    """Read one `ps` argv as a `watch` invocation, or return None.

    This is the safety-critical function in `reap`, because everything it returns gets a SIGTERM.
    Two filters, and neither is belt-and-braces — each closes a false positive that is live on
    the machine this was written on, and each covers the other's gap:

      * **The script must be at argv index 0, 1 or 2.** `ps` flattens argv to a space-joined
        string with no quoting, so a wrapper's whole command line arrives as tokens
        indistinguishable from real arguments. Every watcher here is started through
        `/bin/zsh -c 'source … && eval "python3 …/dispatcher.py --instance … watch DAR-667 …"'`,
        and that wrapper's flattened tokens contain `…/dispatcher.py`, `--instance`, the path,
        `watch` and the key — so "some token ends in /dispatcher.py" passes on the wrapper. The
        index does not: a real invocation has the script at 1 (interpreter first), the wrapper
        buries it deep inside index 2's `-c` string.
      * **argv[0] must be a python interpreter, case-folded**, unless it is the script itself.
        `casefold` is not tidiness: the live watchers' argv[0] is
        `…/Python.framework/Versions/3.10/Resources/Python.app/Contents/MacOS/Python`, whose
        basename is `Python`, and `"Python".startswith("python")` is False — a version of this
        check without it matched **zero of the nine** orphans while reporting a clean run. This
        filter is what stops `/bin/sh -c "/path/dispatcher.py watch K"`, where the script does
        land at index 2.

    The third live false positive needs no filter of its own: three `claude` sessions on this box
    carry the words "dispatcher.py" and "watch" in their *prompt text*, one of them the session
    that wrote this function. They fail both tests.

    **Do not simplify this to a content match.** A wrapper's argv text is character-identical to
    its child's, so no test on the *words* can tell them apart — argv[0] and the index are the only
    two things that differ, which is why both are checked and why neither is redundant. A version
    of this function that greps the joined argv would send SIGTERM to thirteen shell wrappers and
    ten Claude sessions, and would report a tidy list while doing it.
    """
    if not argv:
        return None
    script = next((i for i, a in enumerate(argv[:3]) if os.path.basename(a) == "dispatcher.py"), None)
    if script is None:
        return None
    # `python3 -c '/x/dispatcher.py watch K'` puts the script at index 2 behind a python argv[0], so
    # it is the one shape both filters above pass together. `-c` means the following token is a
    # program to read, never a script to run, so its presence before the script settles it.
    if "-c" in argv[:script]:
        return None
    head = os.path.basename(argv[0]).casefold()
    if script > 0 and not (head.startswith("python") or head == "dispatcher.py"):
        return None
    rest, cmd, key, as_, where = argv[script + 1:], None, None, None, None
    i = 0
    while i < len(rest):
        token = rest[i]
        if token.startswith("-"):
            name, sep, value = token.partition("=")
            if not sep and name in WATCH_VALUE_FLAGS:
                value = rest[i + 1] if i + 1 < len(rest) else None
                i += 1
            if name == "--instance":
                where = value
            elif name == "--as":
                as_ = value
        elif cmd is None:
            cmd = token
        elif key is None:
            key = token
        i += 1
    if cmd != "watch" or not key:
        return None
    return {"key": key, "as": as_, "instance": where, "script": argv[script]}


VERSION_SEGMENT = re.compile(r"^\d+(?:\.\d+)+$")


def script_version(script: str) -> str | None:
    """The plugin version a watcher is *running*, read out of its own script path.

    Not cosmetic. `gh-tc-portal-9395`'s watcher was executing locus 0.5.2 while every other
    watcher on the box ran 0.5.4: an orphan outlives the install that started it, because the
    plugin cache keeps a directory per version and a running process holds the path it was
    launched with. So `reap` must never key on one `dispatcher.py` location — it matches any argv
    token whose basename is `dispatcher.py`, which is what makes it version-agnostic — and
    `doctor` has to *show* the version, or the next person debugging a missed watcher has no way
    to see that two different programs are involved.
    """
    for part in reversed(Path(script).parts):
        if VERSION_SEGMENT.match(part):
            return part
    return None


def cursor_path(key: str, as_: str | None) -> Path:
    return watch_dir() / (f"{key}.{as_}.json" if as_ else f"{key}.json")


def attribute_instance(parsed: dict, sole: Path | None) -> Path | None:
    """Which instance this watcher belongs to, or None when that cannot be established.

    None is not a shrug — it is what keeps `reap` from signalling a process it cannot prove is
    ours. Everything `reap` terminates comes through here.

    An argv that names `--instance` answers it outright. An argv that does not needs `sole` AND a
    cursor of ours for that key: see the comment at the `sole` assignment for why the sole instance
    alone is not enough, and why a cursor is the only evidence available to a process that cannot
    read another process's environment.
    """
    if parsed["instance"]:
        try:
            return instance_path(parsed["instance"]).resolve()
        except SystemExit:
            return None
    if sole and cursor_path(parsed["key"], parsed["as"]).exists():
        return sole
    return None


def live_watchers() -> list[dict]:
    """Every `watch` process on this machine, with the ones belonging to this instance resolved.

    `ps` rather than a pidfile, and that is the whole reason this is not the simpler design: the
    nine orphans DEV-795 is about were started before any version of this code could have written
    a pidfile. A mechanism that cannot see the population it was built for is a mechanism that
    reports a clean machine.

    Status is filled in **only** for watchers attributable to this instance. Reading our ledger
    for another instance's key would not be a missing answer, it would be a confident wrong one —
    two instances can hold the same key with different statuses.
    """
    try:
        out = subprocess.run(["ps", "-Ao", "pid=,etime=,args="], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"cannot run ps: {exc}") from None
    here = instance().resolve()
    # A watcher resolved from $DISPATCHER_INSTANCE, or by being the only instance installed, carries
    # no `--instance` in its argv — `resolve_instance` documents both paths.
    #
    # An earlier version of this comment claimed attributing such a watcher to the sole installed
    # instance is safe because "any other resolution would have had to name it". **That is false**,
    # and a review caught it: `instance_path` accepts an absolute path anywhere on the filesystem,
    # so `$DISPATCHER_INSTANCE=/opt/elsewhere/inst` is a legal launch whose argv names no instance
    # and whose instance is not the one under DISPATCHER_HOME. On a single-instance box that
    # assumption would have made another instance's *live* watcher reapable — a wrong SIGTERM,
    # which is the one failure this whole function exists to avoid.
    #
    # Another process's environment cannot be read from `ps`, so the gap cannot be closed by
    # inspecting the process. It is closed with evidence from our own filesystem instead: a watcher
    # belonging to this instance writes its cursor into *our* `runtime/watch/` at the end of every
    # tick, so the cursor existing is corroboration that the process is ours. Both ways this fails
    # are the safe way — a cursor already pruned, or a watcher that has not finished its first tick,
    # leaves the process unattributed and therefore never signalled.
    installed = sorted(p.parent for p in DISPATCHER_HOME.glob("*/config.json"))
    sole = installed[0].resolve() if len(installed) == 1 else None
    found = []
    for line in out.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3 or not parts[0].isdigit():
            continue
        pid, etime, argv = int(parts[0]), parts[1], parts[2].split()
        if pid == os.getpid():
            continue
        parsed = parse_watch_argv(argv)
        if not parsed:
            continue
        where = attribute_instance(parsed, sole)
        mine = where is not None and where == here
        row = {"pid": pid, "etime": etime, "age": age_words(etime), "key": parsed["key"],
               "as": parsed["as"], "instance": where, "mine": mine, "status": None, "stop": None,
               "script": parsed["script"], "version": script_version(parsed["script"])}
        if mine:
            row["status"] = (ledger_get(parsed["key"]) or {}).get("status")
            row["stop"] = watch_stop_reason(parsed["key"], read_json(cursor_path(parsed["key"], parsed["as"]), {}), False)
        found.append(row)
    return sorted(found, key=lambda r: -(etime_secs(r["etime"]) or 0))


def prunable_cursors() -> tuple[list[tuple[Path, str, str]], list[Path]]:
    """Cursor files this instance no longer needs, and the ones it cannot account for.

    A cursor is prunable exactly when a watcher reading it would stop, which is `watch_stop_reason`
    again rather than a second rule that could disagree with the first.

    Filename is `<key>.json` or `<key>.<reader>.json`, and a ledger key may itself contain dots
    (`ledger_path` allows them), so the split is resolved against the ledger — longest key that
    the stem equals, or begins with followed by a dot — not by counting dots. A stem that matches
    no entry is returned separately and is not deleted by default: `ledger` has no `rm`, so an
    unmatchable cursor is a hand-edited runtime or a key from another era, and neither is
    something to clean up silently.
    """
    if not watch_dir().exists():
        return [], []
    entries = ledger_all()
    prunable, unknown = [], []
    for path in sorted(watch_dir().glob("*.json")):
        stem = path.stem
        key = max((k for k in entries if stem == k or stem.startswith(k + ".")), key=len, default=None)
        if key is None:
            unknown.append(path)
            continue
        stop = watch_stop_reason(key, read_json(path, {}), False)
        if stop:
            prunable.append((path, key, stop[0]))
    return prunable, unknown


def still_watching(pid: int, key: str) -> bool:
    """Re-read this one pid immediately before signalling it.

    Between the `ps` that found a process and the `kill` that ends it, that process can exit and
    its pid be reissued. The window is short and the consequence is not: SIGTERM to a stranger.

    Agreement on the parsed argv and the key is enough, and a start-time comparison was dropped
    rather than left out: for this check to pass wrongly, the reissued pid would have to be
    *another* `dispatcher.py watch` process on the *same* ledger key — in which case it is an
    orphan on a dead key too, and terminating it is the correct outcome rather than an accident.
    """
    try:
        out = subprocess.run(["ps", "-p", str(pid), "-o", "args="], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return False
    parsed = parse_watch_argv(out.stdout.strip().split())
    return bool(parsed and parsed["key"] == key)


def cmd_reap(args) -> None:
    watchers = live_watchers()
    dead = [w for w in watchers if w["mine"] and w["stop"]]
    live = [w for w in watchers if w["mine"] and not w["stop"]]
    foreign = [w for w in watchers if not w["mine"]]
    killed, missed = [], []
    for w in dead:
        if args.dry_run:
            print(f"  would kill  pid {w['pid']:<7} {w['key']:<22} {w['age']:>8}  {w['status']}")
            continue
        if not still_watching(w["pid"], w["key"]):
            missed.append(w)
            print(f"  vanished    pid {w['pid']:<7} {w['key']:<22} {w['age']:>8}  gone before the signal")
            continue
        try:
            os.kill(w["pid"], signal.SIGTERM)
        except (ProcessLookupError, PermissionError) as exc:
            missed.append(w)
            print(f"  failed      pid {w['pid']:<7} {w['key']:<22} {w['age']:>8}  {exc}")
            continue
        killed.append(w)
        print(f"  killed      pid {w['pid']:<7} {w['key']:<22} {w['age']:>8}  {w['stop'][1]}")
    for w in live:
        print(f"  left        pid {w['pid']:<7} {w['key']:<22} {w['age']:>8}  status "
              f"{w['status'] or '(no ledger entry)'} — still being worked")
    for w in foreign:
        where = w["instance"] or "unattributable"
        print(f"  not mine    pid {w['pid']:<7} {w['key']:<22} {w['age']:>8}  {where}")
    prunable, unknown = prunable_cursors()
    removed = 0
    for path, key, status in prunable:
        if args.dry_run:
            print(f"  would prune {path.name}  ({key} is {status})")
            continue
        try:
            path.unlink()
            removed += 1
        except OSError as exc:
            print(f"  cursor kept {path.name}: {exc}")
    if unknown:
        # Named, not counted: an unmatchable cursor is the fossil the ticket's 123 files are made
        # of, and a bare number is what let them accumulate unexamined for a fortnight.
        print(f"  {len(unknown)} cursor file(s) match no ledger entry, left in place: "
              f"{', '.join(p.name for p in unknown[:6])}{' …' if len(unknown) > 6 else ''}")
    verb = "would terminate" if args.dry_run else "terminated"
    cursors = f"{len(prunable)} cursor file(s) would be removed" if args.dry_run else f"{removed} cursor file(s) removed"
    print(f"reap: {verb} {len(dead)} orphan(s) of {len(watchers)} watcher process(es) on this "
          f"machine ({len(live)} live here, {len(foreign)} elsewhere) · {cursors}")
    if missed:
        print(f"  {len(missed)} could not be signalled — re-run to confirm")


def review_desk_dashboard(rd: dict) -> str:
    """Whether the dashboard answers at `url`. One GET, short timeout, never raises.

    `GET /api/v1/health` is the endpoint Review Desk's README uses for exactly this, and it is
    the ONLY HTTP call anywhere in this file to the dashboard. Everything else a session does
    goes through the command line, which is Review Desk's "one way in" — and the two endpoints
    that sign off are reachable over this same API, so a dispatcher that learned to speak it
    would be one edit away from signing off for the developer.
    """
    url = (rd.get("url") or "").rstrip("/")
    if not url:
        return "no url set, so no dashboard to check"
    try:
        with urllib.request.urlopen(f"{url}/api/v1/health", timeout=3) as response:
            body = json.load(response)
        return (f"dashboard answers at {url} (schema {body.get('schema_version', '?')}, "
                f"front end {'embedded' if body.get('front_end_embedded') else 'not built'})")
    except Exception as exc:
        # Not a failure: see the note in `review_desk_check`. The developer starts `serve`.
        return f"no dashboard at {url} ({type(exc).__name__}) — sign-off needs `review-desk serve`"


def cmd_doctor(args) -> None:
    cfg = load_config()
    checks = []

    def check(name, fn):
        try:
            checks.append((True, name, fn() or "ok"))
        except Exception as exc:
            checks.append((False, name, str(exc)[:200]))

    check("linear auth", lambda: linear(cfg, "{ viewer { name email } }")["viewer"]["email"])

    def labels():
        unminted = sorted(k for k, v in cfg["linear"]["labels"].items() if not v.get("id"))
        if unminted:
            raise RuntimeError(f"no id in config.json for: {', '.join(unminted)} — re-run `init`")
        wanted = {v["id"] for v in cfg["linear"]["labels"].values()}
        group = cfg["linear"]["label_group_id"]
        got = linear(cfg, 'query($id: String!) { issueLabel(id: $id) { children { nodes { id } } } }', {"id": group})
        missing = wanted - {n["id"] for n in got["issueLabel"]["children"]["nodes"]}
        if missing:
            raise RuntimeError(f"labels missing from the Agent group: {missing}")
        return f"{len(wanted)} labels in group"

    check("linear labels", labels)
    check("gh auth", lambda: gh("api", "user")["login"])
    check("allele state", lambda: f"{len(allele_state(cfg)[0])} sessions")
    check("locus", lambda: subprocess.run(["locus", "--version"], capture_output=True, text=True).stdout.strip())

    def runtime_writable():
        r = runtime()
        r.mkdir(parents=True, exist_ok=True)
        probe = r / ".probe"
        probe.write_text("x")
        probe.unlink()
        return str(r)

    def production_mcp():
        name = (cfg.get("tools") or {}).get("production_mcp")
        if not name:
            # Not an error — plenty of instances have no production reader. It is reported
            # because `stack.v2.md` §3a-ii prices "data" gates at seconds *on the assumption
            # that a decide child has one*, and `cmd_brief` only names it when it is set. A
            # coordinator budgeting against a reader its resolver was never given is how a
            # cheap gate becomes an unbounded one.
            return "none set — `decide` children get no production reader, and data gates are not cheap"
        return name

    # Watchers are reported by `doctor` and not only by `reap` because the nine orphans DEV-795
    # was filed about were invisible to every command in this file — the only way to see them was
    # `ps`, which means nobody saw them for six days. A check that FAILS on an orphan, rather than
    # printing a number, is what makes `doctor`'s exit code carry the information.
    rows: list[dict] = []

    def watchers():
        rows.extend(live_watchers())
        orphans = [w for w in rows if w["stop"]]
        unattributed = [w for w in rows if w["instance"] is None]
        if orphans:
            raise RuntimeError(f"{len(orphans)} orphaned watcher(s) on a finished key — `reap` "
                               f"terminates them: {', '.join(w['key'] for w in orphans)}")
        note = f"{len(rows)} live, {sum(1 for w in rows if w['mine'])} on this instance"
        if unattributed:
            note += f", {len(unattributed)} unattributable"
        # More than one plugin version running at once is normal after an upgrade and worth
        # saying out loud: an orphan keeps executing the install it was launched from, so a
        # version column is how you notice that the code you are reading is not the code running.
        versions = sorted({w["version"] for w in rows if w["version"]})
        if len(versions) > 1:
            note += f" · running {', '.join(versions)}"
        return note

    def cursors():
        # Reports, never fails. `SKILL.md`'s start-up step says "anything ✗: tell your principal and
        # stop", and there are 112 stale cursors on `tc-portal` — so failing here would stop the
        # Dispatcher from starting until someone swept a directory of dead files. An orphaned
        # *process* is worth that hard stop because it is spending API budget; a leftover file is
        # costing nothing but disk and can wait for the next `reap`.
        prunable, unknown = prunable_cursors()
        total = len(list(watch_dir().glob("*.json"))) if watch_dir().exists() else 0
        note = f"{total} cursor file(s)"
        if prunable:
            note += f", {len(prunable)} for finished keys — `reap` removes them"
        if unknown:
            note += f", {len(unknown)} matching no ledger entry"
        return note

    def review_desk_check():
        """What state Review Desk is in, and whether that state is a failure.

        The mode decides which absences fail, and only the mode:

          off   never called. Reported so a reader is not left wondering why a configured
                dashboard is being ignored, and never a failure.
          auto  used when found, silent when not. Reported either way — `doctor` is the command
                whose job is to say what is there — and a failure only when something is BROKEN.
          on    the principal has said they expect it. An absent one fails here as well.

        **A dashboard that does not answer is reported and never fails.** `SKILL.md`'s start-up
        step stops the Dispatcher on any cross, and `review-desk serve` is the developer's to
        start — out of scope for this change, by the ticket's own words. A review can be
        prepared and recorded with nothing serving; only the two sign-offs need the dashboard,
        and failing here would stop the Dispatcher over a window the developer has not opened.
        """
        rd = review_desk_cfg(cfg)
        mode = rd.get("mode")
        said = [f"mode {mode}"]
        if mode not in REVIEW_DESK_MODES:
            # Read as `auto` everywhere else, which is the non-blocking direction. Named here,
            # because a typo that silently disables a configured integration is worth one cross.
            raise RuntimeError(f"review_desk.mode is {mode!r}, which is not one of "
                               f"{', '.join(REVIEW_DESK_MODES)} — it is being read as 'auto'")
        if rd.get("brief_gate") not in REVIEW_DESK_GATES:
            raise RuntimeError(f"review_desk.brief_gate is {rd.get('brief_gate')!r}, not one of "
                               f"{', '.join(REVIEW_DESK_GATES)}")
        if mode == "off":
            return "off — nothing is recorded in Review Desk and nothing is polled"
        # The same `work list` the poller runs, so "found" is established by the call rather than
        # by a flag. `--version` and `db path` are asked only for the report.
        state, _, detail = review_desk_work(rd)
        if state == "absent":
            if review_desk_loud_when_absent(rd):
                raise RuntimeError(f"mode is 'on' and {rd['command']} is not on PATH — reviews "
                                   f"still run the way they did before Review Desk existed, and "
                                   f"nothing is recorded.")
            return f"{mode} · {rd['command']} is not installed — reviews run as they do today"
        if state != "ok":
            raise RuntimeError(f"{rd['command']} is installed and {state}: {detail} — reviews "
                              f"still run the old way, and nothing is being recorded")
        ok, version, _ = review_desk_run(rd, "--version", json_out=False)
        said.append(version if ok == "ok" and version else "version unknown")
        ok, where, _ = review_desk_run(rd, "db", "path", "--json")
        said.append(f"db {(where or {}).get('path', '?')}" if ok == "ok" else "db path unknown")
        said.append(review_desk_dashboard(rd))
        return " · ".join(said)

    def review_check():
        """The review-mode settings. One cross for a value a worker would read as the wrong answer."""
        raw = (cfg.get("review") or {}).get("blind_options_pass")
        if raw is not None and not isinstance(raw, bool):
            raise RuntimeError(f"review.blind_options_pass is {raw!r}, not true or false — a "
                               f"worker is told it is on whenever the value is truthy, so a "
                               f"string like \"off\" switches nothing off")
        on = review_cfg(cfg)["blind_options_pass"]
        where = "config" if raw is not None else "default"
        return f"blind options pass {'on' if on else 'off'} ({where})"

    def groups_check():
        """Which allele group each mode is dispatched into, and a cross for one that cannot be.

        **It fails, where `intervals` only reports**, and the difference is what the value does
        when it is wrong. A rejected interval changes nothing — the default is already in force.
        A group past allele's 40 characters, or a number where a name belongs, silently moves
        every session of that mode back into the flat list this setting exists to get them out
        of, and the operator who typed it has no other way to find out.

        A mode mapped to `null` is not a fault and is named as `ungrouped`: it is the documented
        way to dispatch one mode into no group at all.
        """
        problems = group_problems(cfg)
        if problems:
            raise RuntimeError(" · ".join(problems))
        raw = (cfg.get("allele") or {}).get("groups") or {}
        # Per mode, and each one says whether the answer came from the config or from this file,
        # which is `review mode`'s idiom and is the question an operator asks of a group they did
        # not expect to see. `ungrouped` is spelled out rather than left blank: a mode with no
        # group and a mode whose line is missing are different facts.
        return " · ".join(
            f"{mode} → {group_for(cfg, mode) or 'ungrouped'}"
            f"{' (config)' if mode in raw else ' (default)'}"
            for mode in sorted(groups_cfg(cfg)))

    def intervals_check():
        """The two intervals DEV-931 adds, and a line when one of them is being ignored.

        **This check reports and never fails, and the distinction is the whole of it.**
        `positive_secs` reads anything but a positive whole number as "not set", because a value
        that threw inside the poller's loop or a watcher's would respawn and run with no sleep
        at all. That is right for the loop and leaves the operator uninformed: they edited a
        setting and nothing happened. So this says so — and stops there, because `SKILL.md`'s
        start-up step stops the Dispatcher on any cross, and a typo in a cosmetic interval whose
        default is already in force is not worth a dispatcher that will not start. Nothing is
        misbehaving; a number is being ignored.

        `review_desk.mode`'s cross one section up is the contrast rather than the precedent: a
        truthy string there CHANGES what a worker is told to do. A rejected interval changes
        nothing, which is exactly why it must not block.
        """
        # `isinstance`, not `or {}`. The latter covers absent, null, `{}`, `[]` and `0` and
        # leaves a TRUTHY non-dict — `"limits": 5` — reaching `.get` and raising, which `check`
        # would turn into the very cross this function exists not to be. Such a config breaks
        # `cmd_poll` and `cmd_status` as well, so a cross would be defensible; it would just be
        # charged to the wrong check, and this one promises in its first line not to raise.
        limits = cfg.get("limits") if isinstance(cfg.get("limits"), dict) else {}
        said = []
        for key, default in (("draft_watch_interval_secs", DRAFT_WATCH_INTERVAL_SECS),
                             ("harvest_interval_secs", HARVEST_INTERVAL_SECS)):
            raw = limits.get(key)
            if raw is None:
                said.append(f"{key} {default}s (default)")
            elif usable_secs(raw):
                said.append(f"{key} {raw}s (config)")
            else:
                said.append(f"{key} is {raw!r}, which is not a positive whole number of "
                            f"seconds — IGNORED, and {default}s used")
        # `int()` in a try, because that is what `watch_interval` and `full_pass_due` do with
        # this key and this line has to describe them rather than itself. Gated on
        # `usable_secs` instead, a quoted `"10"` printed no cap line while the watcher was
        # sleeping 10s and the operator was told their 20s was in force. `watch_interval_secs`
        # predates DEV-931 and is read with `int()` everywhere, so it is NOT narrowed to match
        # `usable_secs` — that would change what an existing instance's config means.
        try:
            watch = int(limits.get("watch_interval_secs"))
        except (TypeError, ValueError):
            watch = None
        quick = positive_secs(limits.get("draft_watch_interval_secs"), DRAFT_WATCH_INTERVAL_SECS)
        if watch is not None and quick > watch:
            # `watch_interval` takes the smaller of the two, so the behaviour is defined and
            # this is not a fault either. Said because a draft interval nobody will ever sleep
            # is a setting whose owner believes it is doing something.
            said.append(f"the draft interval is capped at watch_interval_secs {watch}s")
        return " · ".join(said)

    check("watchers", watchers)
    check("watch cursors", cursors)
    # Order matters only for the reader: `skills/dispatcher/SKILL.md` names these as the third
    # and the fourth check, so swapping them makes its prose wrong rather than its logic.
    check("review desk", review_desk_check)
    check("review mode", review_check)
    check("allele groups", groups_check)
    check("intervals", intervals_check)
    check("production mcp", production_mcp)
    check("runtime writable", runtime_writable)
    check("code root", lambda: str(CODE_DIR))
    check("instance root", lambda: str(instance()))
    check("worker briefs", lambda: f"{len(list((CODE_DIR / 'workers').glob('*.md')))} briefs in {CODE_DIR / 'workers'}")
    for ok, name, detail in checks:
        print(f"{'✓' if ok else '✗'} {name}: {detail}")
    if rows:
        print(f"\n{'PID':<8} {'KEY':<22} {'AGE':>8} {'VER':<7} {'LEDGER':<12} WATCHER")
        for w in rows:
            if not w["mine"]:
                note = f"another instance ({w['instance']})" if w["instance"] else "instance unknown — not reapable"
            else:
                note = f"ORPHAN — {w['stop'][1]}" if w["stop"] else "working"
            reader = f" --as {w['as']}" if w["as"] else ""
            print(f"{w['pid']:<8} {w['key'] + reader:<22} {w['age']:>8} {w['version'] or '?':<7} "
                  f"{(w['status'] or '?') if w['mine'] else '?':<12} {note}")
    sys.exit(0 if all(ok for ok, *_ in checks) else 1)


# --------------------------------------------------------------------------- init

TEAM_Q = 'query($key: String!) { teams(filter: { key: { eq: $key } }) { nodes { id key name } } }'

# `first` on both levels is deliberate and tuned: the outer default of 50 multiplied by a
# 100-child inner page puts this over Linear's query-complexity ceiling (measured: 11,635
# against a limit of 10,000, HTTP 400). Ten candidate groups is far more than a workspace
# has by one name, and `hasNextPage` guards the child page rather than a bigger number.
GROUPS_Q = """
query($name: String!) {
  issueLabels(first: 10, filter: { name: { eq: $name } }) {
    nodes {
      id name isGroup parent { id } team { id key }
      children(first: 50) { nodes { id name } pageInfo { hasNextPage } }
    }
  }
}"""

LABEL_COLOURS = {
    "todo": "#5e6ad2", "investigate": "#5e6ad2", "decompose": "#5e6ad2", "decide": "#5e6ad2",
    "implementing": "#f2c94c", "investigating": "#f2c94c", "decomposing": "#f2c94c",
    "needs-input": "#f2994a", "blocked": "#bb87fc", "done": "#4cb782", "failed": "#eb5757",
}


def create_label(cfg: dict, fields: dict) -> dict:
    """Create one label, and refuse to carry on if the mutation did not produce one.

    `issueLabelCreate` can return `success: false` with a null `issueLabel`. Indexing straight
    into it turns that into a TypeError three lines later, which reads as a bug in this script
    rather than as a refused write.
    """
    result = linear(cfg, """
        mutation($input: IssueLabelCreateInput!) {
          issueLabelCreate(input: $input) { success issueLabel { id name } } }""",
        {"input": fields})["issueLabelCreate"]
    label = result.get("issueLabel")
    if not result.get("success") or not label or not label.get("id"):
        raise SystemExit(f"Linear refused to create the label {fields.get('name')!r}; "
                         f"nothing further was written. Re-run once the cause is fixed — "
                         f"labels are matched by name, so anything already created is reused.")
    return label


def fill_absent(where: str, existing: dict, template: dict) -> list[str]:
    """Add template keys the config has never heard of. Never touch one it already has.

    `init` rebuilds its config from the *existing* file on a re-run, which is what keeps label
    ids stable — and it meant a config written before a mode existed could never learn about
    it. A workspace would stay on nine labels forever while the template shipped eleven, and
    the failure surfaced as `unknown label state 'blocked'` a long way from here.

    Deliberately shallow, and deliberately only over the three maps `dispatcher.py` reads by
    key. A recursive merge across the whole config would fill `allele.repo_project_map` with
    the template's `"OWNER/REPO": "your-project"` placeholder — adding junk to a live config in
    the name of reconciling it. "Fill absent keys" is only safe where every key is vocabulary.
    """
    added = [k for k in template if k not in existing]
    for k in added:
        existing[k] = template[k]
    # Qualified, because one mode lands in four maps under the same name: an unqualified
    # summary reads "decide, blocked, decide, decide, decide" and tells the operator nothing
    # about which of the four sites was short.
    return [f"{where}.{k}" for k in added]


def cmd_init(args) -> None:
    """Create the Agent label group and its labels, and write config.json.

    Every other config value is a string somebody can type. The label ids are not: they are
    minted by the workspace, and without them nothing in this program can claim a ticket.
    That is the whole reason this subcommand exists.

    Safe to re-run **against the same team**, including after a partial failure. Labels are
    matched by name against the workspace rather than against config.json, so a run that created
    the group and four children before dying leaves those four discoverable: the next run reuses
    them and creates the rest. Linear is the source of truth for ids, which is what makes the
    interrupted case benign — config.json is only written once every id is in hand.

    The promise stops at the team boundary, because the team filter that makes group lookup
    unambiguous also means a different --team-key finds nothing to reuse. That case is refused
    rather than trusted to the reader.

    Two re-runs this cannot make safe, both of which create workspace state while reporting it:
    renaming a label in config.json (the new name is created; the old one stays on live tickets),
    and an `Agent` group made by hand as a workspace-level label rather than a team one (its team
    is null, the filter rejects it, and a duplicate is created alongside it).
    """
    dest = DISPATCHER_HOME / args.instance
    config_path = dest / "config.json"
    existing = read_json(config_path, None)
    template = json.loads((CODE_DIR / "config.example.json").read_text())
    template.pop("_comment", None)
    if existing:
        cfg = existing
        print(f"reconciling the config already at {config_path}")
    else:
        cfg = template

    if args.api_key_env:
        cfg["linear"]["api_key_env"] = args.api_key_env
    if args.workspace:
        cfg["linear"]["mcp_workspace"] = args.workspace
    if args.team_key and args.team_key != (existing or {}).get("linear", {}).get("team_key") \
            and (existing or {}).get("linear", {}).get("label_group_id") and not args.force:
        raise SystemExit(
            f"{config_path} is already bound to team "
            f"{existing['linear'].get('team_key')!r} with "
            f"{len(existing['linear'].get('labels') or {})} label ids from it.\n"
            f"Re-running with --team-key {args.team_key!r} would create a second label group and "
            f"overwrite every id in place. Tickets already carrying the old team's Agent labels "
            f"would drop out of the trigger query, and this tool could no longer see or clear "
            f"those labels.\n"
            f"Use a separate --instance for a second team, or --force if that really is what you want."
        )
    if args.team_key:
        cfg["linear"]["team_key"] = args.team_key
    if args.github_login:
        cfg["github"]["login"] = args.github_login
    if args.project:
        cfg["allele"]["default_project"] = args.project

    team_key = (cfg["linear"].get("team_key") or "").strip() or None
    cfg["linear"]["team_key"] = team_key
    if not team_key:
        raise SystemExit("--team-key is required: a workspace can hold several label groups "
                         "named the same thing on different teams, so the name alone is ambiguous")

    teams = linear(cfg, TEAM_Q, {"key": team_key})["teams"]["nodes"]
    if not teams:
        raise SystemExit(f"no team with key {team_key!r} in this workspace")
    team = teams[0]
    print(f"team {team['key']} — {team['name']}")

    # Find the group on THIS team. Matching on name alone is what makes a second, unrelated
    # "Agent" group on someone else's team look like yours.
    groups = [g for g in linear(cfg, GROUPS_Q, {"name": args.label_group})["issueLabels"]["nodes"]
              if g["isGroup"] and not g.get("parent") and (g.get("team") or {}).get("id") == team["id"]]
    created, reused = [], []

    if groups:
        group = groups[0]
        reused.append(args.label_group)
    elif args.dry_run:
        group = {"id": "<new-group-id>", "children": {"nodes": []}}
        created.append(args.label_group)
    else:
        group = create_label(cfg, {"name": args.label_group, "isGroup": True, "teamId": team["id"],
                                   "description": "Agent dispatch states. Managed by the Dispatcher."})
        group["children"] = {"nodes": []}
        created.append(args.label_group)

    cfg["linear"]["label_group_id"] = group["id"]
    children = group.get("children") or {"nodes": []}
    if (children.get("pageInfo") or {}).get("hasNextPage"):
        raise SystemExit(f"the {args.label_group!r} group has more than 100 children; this would "
                         f"re-create labels it simply could not see. Paginate before re-running.")
    by_name = {c["name"]: c["id"] for c in children.get("nodes", [])}

    # Teach an older config the vocabulary this version ships, after every refusal above has
    # had its chance — a run that is about to be rejected should not announce what it would
    # have learned. Ids stay null here; the loop below either finds the label in the workspace
    # or creates it, exactly as on a fresh install.
    # Four sites, not three. `SKILL.md` dispatches with `orchestration: allele.orchestration
    # [<mode>]`, so a mode present in `modes` and `traits` but absent from `orchestration` has
    # no value to pass at the one step that creates the session.
    learned = (fill_absent("labels", cfg["linear"]["labels"], template["linear"]["labels"])
               + fill_absent("modes", cfg["linear"]["modes"], template["linear"]["modes"])
               + fill_absent("traits", cfg.setdefault("traits", {}), template["traits"])
               + fill_absent("orchestration", cfg.setdefault("allele", {}).setdefault("orchestration", {}),
                             template["allele"]["orchestration"])
               # Five sites now. `review_desk` qualifies for `fill_absent`'s stated rule — every
               # key in it is vocabulary with a real default, not a placeholder somebody must
               # edit — so a re-run teaches an older config the block without putting junk in it.
               # It is a convenience rather than a migration: `review_desk_cfg` defaults the same
               # four keys in code, so an instance that never re-runs `init` behaves as `auto`.
               + fill_absent("review_desk", cfg.setdefault("review_desk", {}),
                             template["review_desk"])
               # Six. `review` qualifies on the same rule: one boolean with a real default and
               # nothing for anybody to edit. `review_cfg` defaults it in code as well, so this is
               # how an older instance comes to SHOW the setting it was already getting.
               + fill_absent("review", cfg.setdefault("review", {}), template["review"])
               # Seven, and this one needs its rule checked rather than assumed, because `limits`
               # is the block whose values an instance is most likely to have TUNED —
               # `tc-portal` runs `watch_interval_secs` 300 against the template's 90. It
               # qualifies anyway: `fill_absent` adds only keys the config has never heard of and
               # never touches one it has, so a tuned value is not at risk, and every key here is
               # a number with a real default rather than a placeholder somebody must edit. What
               # it buys is that `draft_watch_interval_secs` and `harvest_interval_secs` become
               # VISIBLE on an instance that predates them, instead of being defaults in code
               # that nobody can find to change.
               + fill_absent("limits", cfg.setdefault("limits", {}), template["limits"])
               # Eight, and the same rule again: five mode names with a real default each and
               # nothing for anybody to edit. `group_for` defaults them in code, so this is how
               # an instance that predates `allele.groups` comes to SHOW the groups it is
               # already dispatching into — and `null` against a mode is how an operator turns
               # one off, which they cannot do to a setting they cannot see.
               + fill_absent("groups", cfg.setdefault("allele", {}).setdefault("groups", {}),
                             template["allele"]["groups"]))
    if learned:
        print(f"new in this version: {', '.join(learned)}")

    for key, spec in cfg["linear"]["labels"].items():
        name = spec["name"]
        if name in by_name:
            spec["id"] = by_name[name]
            reused.append(name)
            continue
        if args.dry_run:
            spec["id"] = f"<new-{key}-id>"
            created.append(name)
            continue
        label = create_label(cfg, {"name": name, "parentId": group["id"], "teamId": team["id"],
                                   "color": LABEL_COLOURS.get(key, "#95a2b3")})
        spec["id"] = label["id"]
        created.append(name)

    missing = [k for k, v in cfg["linear"]["labels"].items() if not v.get("id")]
    if missing:
        raise SystemExit(f"labels left without an id: {missing}")

    if args.dry_run:
        print(f"\n--dry-run: nothing was created and nothing was written to {config_path}")
    else:
        write_json(config_path, cfg)
        (dest / "runtime" / "ledger").mkdir(parents=True, exist_ok=True)
        (dest / "runtime" / "watch").mkdir(parents=True, exist_ok=True)
        print(f"\nwrote {config_path}")
    print(f"created {len(created)}: {', '.join(created) or '-'}")
    print(f"reused  {len(reused)}: {', '.join(reused) or '-'}")
    print(f"config keys filled {len(learned)}: {', '.join(learned) or '-'}")
    if not created and not learned and not args.dry_run:
        # Counted separately on purpose. This line used to read `if not created`, which counts
        # *workspace* creations only — so a run that rewrote config.json and re-armed a mode
        # announced itself as a no-op.
        print("nothing changed in the workspace or the config — this run was a no-op, as a "
              "re-run should be")
    print(f"\nnext: review {config_path}, then `python3 {Path(__file__).name} "
          f"--instance {args.instance} doctor`")


# --------------------------------------------------------------------------- main

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    # Declared on the root AND on every subcommand: `--instance X poll` and `poll --instance X`
    # both being natural, one of them silently failing is a trap rather than a convention.
    instance_help = ("instance slug under ~/.locus/data/dispatcher, or an explicit path "
                     "(default: $DISPATCHER_INSTANCE, or the only one installed)")
    parser.add_argument("--instance", dest="root_instance", help=instance_help)
    sub = argparse.ArgumentParser(add_help=False)
    sub.add_argument("--instance", help=instance_help)
    common = sub
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("init", help="create the Agent label group and write config.json")
    p.add_argument("--instance", required=True, help="slug for this dispatcher instance, e.g. the repo name")
    p.add_argument("--team-key", dest="team_key", help="Linear team key the labels belong to, e.g. ENG")
    p.add_argument("--label-group", dest="label_group", default="Agent", help="name of the parent label (default: Agent)")
    p.add_argument("--api-key-env", dest="api_key_env", help="env var holding the Linear API key")
    p.add_argument("--workspace", help="Linear MCP workspace name")
    p.add_argument("--github-login", dest="github_login", help="your GitHub login, for review requests")
    p.add_argument("--project", help="default allele project for dispatched workers")
    p.add_argument("--dry-run", dest="dry_run", action="store_true", help="print what would be created; write nothing")
    p.add_argument("--force", action="store_true", help="allow a re-run that rebinds an existing config to another team")
    p.set_defaults(fn=cmd_init)

    p = sub.add_parser("poll", parents=[common])
    p.add_argument("--once", action="store_true")
    # The backlog announcement is a property of the PROCESS by default (DEV-794), which is right
    # for the sanctioned long-lived host and for a per-tick host's first run alike. These let a
    # caller say so explicitly instead of relying on the host's shape, which is the difference
    # between a policy and an emergent consequence — raised in review on #63. The default is
    # unchanged, so neither flag is required.
    p.add_argument("--backlog", dest="backlog", action="store_true", default=None,
                   help="announce a start-up backlog on this run's first tick (the default)")
    p.add_argument("--no-backlog", dest="backlog", action="store_false",
                   help="suppress it: for a host that drives `poll --once` on a cadence and has "
                        "already asked its principal about the backlog once")
    p.set_defaults(fn=cmd_poll)

    p = sub.add_parser("watch", parents=[common])
    p.add_argument("key")
    p.add_argument("--pr", help="OWNER/REPO#N — otherwise discovered from the ticket's attachments")
    p.add_argument("--as", dest="as_", help="reader name; gives this watcher its own comment cursor")
    p.add_argument("--once", action="store_true")
    p.add_argument("--max-ticks", dest="max_ticks", type=int,
                   help="stop after this many ticks, whatever the ledger says")
    p.add_argument("--max-hours", dest="max_hours", type=float,
                   help=f"stop after this many hours (default: limits.watch_max_hours, "
                        f"else {WATCH_MAX_HOURS:g})")
    p.add_argument("--exit-on-done", dest="exit_on_done", action="store_true",
                   help="also stop the moment the ledger says 'done', without waiting for the PR "
                        "to close — see watch_stop_reason for why this is not the default")
    p.set_defaults(fn=cmd_watch)

    p = sub.add_parser("reap", parents=[common],
                       help="terminate this instance's orphaned watchers and remove cursors for finished keys")
    p.add_argument("--dry-run", dest="dry_run", action="store_true",
                   help="report what would be terminated and removed; signal nothing, delete nothing")
    p.set_defaults(fn=cmd_reap)

    p = sub.add_parser("ledger", parents=[common])
    p.add_argument("action", choices=["list", "get", "put", "children"])
    p.add_argument("key", nargs="?")
    p.add_argument("fields", nargs="*", help="k=v (v parsed as JSON when it can be)")
    p.add_argument("--all", action="store_true")
    p.add_argument("--note")
    p.add_argument("--by")
    p.set_defaults(fn=cmd_ledger)

    p = sub.add_parser("label", parents=[common])
    p.add_argument("issue")
    p.add_argument("label")
    p.add_argument("--state", help="also move the ticket to this workflow state")
    p.add_argument("--by")
    p.set_defaults(fn=cmd_label)

    p = sub.add_parser("comment", parents=[common])
    p.add_argument("issue")
    p.add_argument("--key")
    p.add_argument("--mode")
    p.add_argument("--reply-to", dest="reply_to")
    p.set_defaults(fn=cmd_comment)

    p = sub.add_parser("brief", parents=[common])
    p.add_argument("key")
    p.set_defaults(fn=cmd_brief)

    p = sub.add_parser("review-posted", parents=[common],
                       help="has the principal's approved review already been posted? read-only")
    p.add_argument("key", help="the ledger key, which carries the repo and the pull request")
    p.add_argument("--approved-at", dest="approved_at", required=True,
                   help="the approval time, in integer seconds since the epoch, as "
                        "`review-desk draft show --json` reports it")
    p.add_argument("--body-file", dest="body_file", required=True,
                   help="the approved body, or - for standard input")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_review_posted)

    p = sub.add_parser("status", parents=[common])
    p.add_argument("--all", action="store_true")
    p.set_defaults(fn=cmd_status)

    sub.add_parser("doctor", parents=[common]).set_defaults(fn=cmd_doctor)

    args = parser.parse_args()
    if args.cmd == "ledger" and args.action in ("get", "put", "children") and not args.key:
        parser.error("ledger get/put/children need a KEY")
    # `doctor` resolves lazily: it is the command you run to find out why an instance will not
    # resolve, so exiting here would make it useless in exactly that case.
    if args.cmd not in ("init", "doctor"):
        global _instance
        _instance = resolve_instance(getattr(args, "instance", None) or args.root_instance)
    elif args.cmd == "doctor":
        try:
            globals()["_instance"] = resolve_instance(getattr(args, "instance", None) or args.root_instance)
        except SystemExit as exc:
            print(f"✗ instance: {exc}")
            print(f"✓ code root: {CODE_DIR}")
            print(f"  worker briefs: {len(list((CODE_DIR / 'workers').glob('*.md')))} in {CODE_DIR / 'workers'}")
            raise SystemExit(1) from None
    args.fn(args)


if __name__ == "__main__":
    main()
