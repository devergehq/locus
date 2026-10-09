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


def pr_key(repo: str, number: int) -> str:
    return f"gh-{repo.split('/')[-1]}-{number}"


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

# The four kinds `work list` answers with. A fifth one from a newer Review Desk is ignored rather
# than guessed at: this file would have no idea what an agent is supposed to do about it, and
# inventing a dispatch for a kind it has never heard of is worse than leaving it listed.
REVIEW_DESK_KINDS = ("review_requested", "brief_settled", "draft_sent_back", "draft_approved")

# The three a WATCHER relays to the session already working the review. `review_requested` is
# deliberately absent: a session reading its own review does not need telling to start.
REVIEW_DESK_WATCH_KINDS = ("brief_settled", "draft_sent_back", "draft_approved")

# How long a Review Desk call may take before it is called broken. Generous against a cold
# SQLite file on a laptop, and short enough that a hung binary cannot stall a poll tick.
REVIEW_DESK_TIMEOUT = 30


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


def review_desk_run(rd: dict, *args: str, json_out: bool = True) -> tuple[str, object, str]:
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
        done = subprocess.run(argv, capture_output=True, text=True, timeout=REVIEW_DESK_TIMEOUT)
    except (FileNotFoundError, NotADirectoryError):
        return "absent", None, f"{argv[0]} is not on PATH"
    except subprocess.TimeoutExpired:
        return "broken", None, f"{argv[0]} {said} did not answer in {REVIEW_DESK_TIMEOUT}s"
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
        for section in (self.linear_triggers, self.review_requests, self.review_desk,
                        self.liveness):
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
        present = {}
        for pr in nodes:
            if not pr or (g.get("skip_drafts") and pr.get("isDraft")):
                continue
            repo = pr["repository"]["nameWithOwner"]
            key = pr_key(repo, pr["number"])
            present[key] = {"repo": repo, "number": pr["number"]}
            entry = ledger.get(key) or {}
            status = entry.get("status")
            common = dict(key=key, repo=repo, number=pr["number"], title=pr["title"], url=pr["url"],
                          author=(pr.get("author") or {}).get("login"), head_sha=pr["headRefOid"],
                          opened=(pr.get("createdAt") or "")[:10],
                          ledger_status=status, session_id=entry.get("session_id"))
            returned = previous is not None and key not in previous
            if backlog:
                self.state["review_backlog"].append(key)
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
        if kind not in REVIEW_DESK_KINDS or not isinstance(rid, int) or not isinstance(number, int):
            return
        # `ledger_id` is what `review link --ledger` was given, which is this instance's own key.
        # A review STARTED FROM THE DASHBOARD has never been linked and carries null, so the key
        # is derived the same way `review_requests` derives it — which is what makes the two
        # sources agree about one pull request instead of opening a second entry for it.
        key = item.get("ledger_id") or pr_key(repo, number)
        entry = ledger.get(key) or {}
        if review_desk_live(live, entry):
            return
        # The rate limit is taken BEFORE the GitHub read, so a quiet item costs no API call on
        # the ticks in between. The marker therefore means "this item was considered", not "this
        # item was emitted", which is the cheaper and not the more surprising reading: nothing
        # downstream can tell the difference, because a skipped item emits nothing either way.
        if not self.due(f"review_desk|{kind}|{rid}|{item.get('entered_at')}", every):
            return
        state = self.pr_state(repo, number)
        if state in PR_CLOSED:
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
        emit("review_desk_resume", kind=kind, note=item.get("note"),
             sign_off=item.get("sign_off"), draft=review_desk_link(rd, rid, draft=True), **common)

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
            info = gh("pr", "view", str(number), "-R", repo, "--json", "state,merged")
            state = "merged" if info.get("merged") else (info.get("state") or "").lower()
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

    def tick(self) -> None:
        cfg = load_config()
        for section in (self.issue, self.pull_request, self.review_desk):
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
        """The developer's two acts, relayed to the session that is waiting for them.

        Confirming a brief and approving a draft happen in the dashboard and nowhere else. The
        session that wrote them cannot see the dashboard, so without this it waits forever — the
        "approval delivery" open question in Review Desk's own brief, which named this watcher as
        the candidate.

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
                continue
            ident = f"{kind}|{item.get('review_id')}|{item.get('entered_at')}"
            if ident in seen:
                continue
            seen.add(ident)
            # `note` is the developer's prose and is data, not instructions — Review Desk's
            # README says so of this exact field. Relayed verbatim in its own key.
            emit(kind, key=self.key, review_desk_id=rid, round=item.get("round"),
                 sign_off=item.get("sign_off"), entered_at=item.get("entered_at"),
                 note=item.get("note"), review=review_desk_link(rd, rid),
                 draft=review_desk_link(rd, rid, draft=True))
        self.state["rd_seen"] = sorted(seen)[-200:]


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
    while True:
        stop = watch_stop_reason(args.key, watcher.state, args.exit_on_done)
        if stop:
            status, why, from_ledger = stop
            emit("watch_stopped", key=args.key, reason="ledger", status=status, ticks=ticks,
                 cursor_removed=from_ledger and watcher.forget(), detail=why)
            return
        watcher.tick()
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
        time.sleep(load_config()["limits"]["watch_interval_secs"])


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
    composed = subprocess.run(["locus", "agent", "compose", "--traits", t["traits"], "--role", t["role"], "--task", task],
                              capture_output=True, text=True)
    head = composed.stdout.strip() if composed.returncode == 0 else f"You are {t['role']}.\n\nYour task: {task}"
    # Briefs resolve against CODE_DIR; only the instance flag carries state. Pointing these at
    # the instance directory is the silent failure in this file: every worker would start by
    # failing to read a brief that was never installed there.
    workers = CODE_DIR / "workers"
    # The absolute instance path, not the slug. A worker is a fresh session that inherits none
    # of this process's environment, so a bare slug resolves against the DEFAULT home — which
    # is the wrong directory, or none, whenever DISPATCHER_HOME is set here.
    tool = f"python3 {CODE_DIR / 'dispatcher.py'} --instance {instance()}"
    extra = []
    production_mcp = (cfg.get("tools") or {}).get("production_mcp")
    if production_mcp:
        extra.append(f"- Production reads: the `{production_mcp}` MCP, read-only, aggregates and ids only.")
    if mode in ("review", "implement"):
        extra.append("- Review craft: invoke the `review-craft` skill for the house style, the lenses and the linter.")
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

    check("watchers", watchers)
    check("watch cursors", cursors)
    check("review desk", review_desk_check)
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
                             template["review_desk"]))
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
