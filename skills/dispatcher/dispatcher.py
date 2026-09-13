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
  poll [--once]                          Dispatcher's eyes. One JSON line per new event.
  watch KEY [--pr OWNER/REPO#N] [--once] A worker's eyes on its own ticket and PR.
  ledger list [--all] | get KEY | put KEY [k=v ...] [--note TEXT] [--by WHO]
  label ISSUE STATE [--state NAME]       Set the ticket's one Agent-group label ('none' clears).
  comment ISSUE [--key KEY] [--mode M] [--reply-to ID]   Signed Linear comment, body on stdin.
  brief KEY                              Print the dispatch prompt for the ledger entry KEY.
  status                                 Ledger vs allele, as a table.
  doctor                                 Check env, auth, labels, paths.

Nothing here posts to GitHub. Linear writes happen only through `label` and `comment`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# The code root: worker briefs and the config template, shipped read-only beside this file.
CODE_DIR = Path(__file__).resolve().parent

# The instance root: everything that differs between repos, and everything that is written.
DISPATCHER_HOME = Path(os.environ.get("DISPATCHER_HOME", "~/.locus/data/dispatcher")).expanduser()

_instance: Path | None = None


def resolve_instance(slug: str | None) -> Path:
    """Find the instance directory, or explain how to make one.

    Identity is `config.json`, not directory name: a directory without one is not an
    instance, which is what keeps stray subdirectories from being mistaken for a half
    installed one.
    """
    slug = slug or os.environ.get("DISPATCHER_INSTANCE")
    if slug:
        path = DISPATCHER_HOME / slug
        if not (path / "config.json").is_file():
            raise SystemExit(
                f"no config.json in {path}\n"
                f"create it with:  python3 {Path(__file__).name} init --instance {slug} --team-key KEY"
            )
        return path
    found = sorted(p.parent for p in DISPATCHER_HOME.glob("*/config.json"))
    if len(found) == 1:
        return found[0]
    if not found:
        raise SystemExit(
            f"no dispatcher instance under {DISPATCHER_HOME}\n"
            f"create one with:  python3 {Path(__file__).name} init --instance <slug> --team-key KEY"
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

# Ledger statuses. WORKING counts against max_workers; ALIVE means a session should exist.
WORKING = {"claimed", "active", "needs-input"}
ALIVE = WORKING | {"done", "stopped"}
REDISPATCHABLE = {None, "queued", "lost", "failed", "discarded"}

LINEAR_KEY = re.compile(r"^[A-Z][A-Z0-9]+-\d+$")
PR_URL = re.compile(r"github\.com/([^/]+/[^/]+)/pull/(\d+)")
BODY_LIMIT = 1500


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


def emit(event: str, **fields) -> None:
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


# --------------------------------------------------------------------------- ledger

def ledger_path(key: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", key):
        raise SystemExit(f"bad ledger key: {key}")
    return ledger_dir() / f"{key}.json"


def ledger_get(key: str) -> dict | None:
    return read_json(ledger_path(key), None)


def ledger_all() -> dict[str, dict]:
    if not ledger_dir().exists():
        return {}
    return {p.stem: read_json(p, {}) for p in sorted(ledger_dir().glob("*.json"))}


def ledger_put(key: str, fields: dict, note: str | None = None, by: str | None = None) -> dict:
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
    write_json(ledger_path(key), entry)
    return entry


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

REVIEWS_Q = """
query($q: String!) {
  search(query: $q, type: ISSUE, first: 50) {
    nodes { ... on PullRequest {
      number title url isDraft headRefOid createdAt author { login } repository { nameWithOwner }
    } }
  }
}"""


class Poller:
    def __init__(self) -> None:
        self.state = read_json(poll_state(), {})
        for bucket in ("emitted", "once", "blocked", "errors"):
            self.state.setdefault(bucket, {})
        self.state.setdefault("prs_present", None)
        # State written before backlog tracking existed: whatever was already pending is backlog.
        self.state.setdefault("review_backlog", sorted(self.state["prs_present"] or []))
        self.first_tick = not self.state.get("started")

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

    def error(self, section: str, exc: Exception) -> None:
        sig = f"{section}:{str(exc)[:80]}"
        last = self.state["errors"].get(sig)
        if not last or time.time() - last > 1800:
            self.state["errors"][sig] = time.time()
            emit("error", section=section, message=str(exc)[:400])

    def tick(self) -> None:
        cfg = load_config()
        ledger = ledger_all()
        backlog = self.first_tick
        for section in (self.linear_triggers, self.review_requests, self.liveness):
            try:
                section(cfg, ledger, backlog)
            except Exception as exc:  # one failing source must never kill the poller
                self.error(section.__name__, exc)
        if self.first_tick:
            self.state["started"] = now_iso()
            self.first_tick = False
            emit("poller_started", working=working_count(), max_workers=cfg["limits"]["max_workers"],
                 ledger_open=sum(1 for e in ledger.values() if e.get("status") in ALIVE))
        write_json(poll_state(), self.state)
        heartbeat().write_text(now_iso())

    def linear_triggers(self, cfg: dict, ledger: dict, backlog: bool) -> None:
        labels = cfg["linear"]["labels"]
        modes = cfg["linear"]["modes"]
        by_trigger = {labels[m["trigger"]]["id"]: name for name, m in modes.items()}
        query, variables = triggers_query(cfg["linear"].get("team_key"))
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
        # A ticket that left the trigger query and comes back later should fire at once.
        for mark in [m for m in self.state["emitted"] if "|trigger|" in m or "|retrigger|" in m]:
            if mark.split("|")[0] not in seen:
                del self.state["emitted"][mark]

    def review_requests(self, cfg: dict, ledger: dict, backlog: bool) -> None:
        g = cfg["github"]
        data = gh("api", "graphql", "-f", f"query={REVIEWS_Q}", "-f", f"q={g['review_query']}")
        every = cfg["limits"]["reemit_after_secs"]
        previous = self.state["prs_present"]
        present = {}
        for pr in data["data"]["search"]["nodes"]:
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


def cmd_poll(args) -> None:
    runtime().mkdir(parents=True, exist_ok=True)
    poller = Poller()
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
    def __init__(self, key: str, pr: str | None) -> None:
        self.key = key
        self.path = watch_dir() / f"{key}.json"
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
        for section in (self.issue, self.pull_request):
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
                if issue["state"]["type"] in ("completed", "canceled"):
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


def cmd_watch(args) -> None:
    watcher = Watcher(args.key, args.pr)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        watcher.tick()
        if args.once:
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
    issue = linear(cfg, LABEL_Q, {"id": args.issue})["issue"]
    group = cfg["linear"]["label_group_id"]
    target = labels[args.label]["id"] if args.label != "none" else None
    current = [l for l in issue["labels"]["nodes"] if (l.get("parent") or {}).get("id") == group]
    parts = [f'r{i}: issueRemoveLabel(id: "{issue["id"]}", labelId: "{l["id"]}") {{ success }}'
             for i, l in enumerate(current) if l["id"] != target]
    if target and target not in [l["id"] for l in current]:
        parts.append(f'add: issueAddLabel(id: "{issue["id"]}", labelId: "{target}") {{ success }}')
    if args.state:
        state = next((s for s in issue["team"]["states"]["nodes"] if s["name"].lower() == args.state.lower()), None)
        if not state:
            raise SystemExit(f"no workflow state '{args.state}' on this team")
        parts.append(f'st: issueUpdate(id: "{issue["id"]}", input: {{ stateId: "{state["id"]}" }}) {{ success }}')
    if parts:
        linear(cfg, "mutation {\n" + "\n".join(parts) + "\n}")
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
    tool = f"python3 {CODE_DIR / 'dispatcher.py'} --instance {instance().name}"
    extra = []
    production_mcp = (cfg.get("tools") or {}).get("production_mcp")
    if production_mcp:
        extra.append(f"- Production reads: the `{production_mcp}` MCP, read-only, aggregates and ids only.")
    if mode in ("review", "implement"):
        extra.append("- Review craft: invoke the `review-craft` skill for the house style, the lenses and the linter.")
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


# --------------------------------------------------------------------------- status / doctor

def cmd_ledger(args) -> None:
    if args.action == "list":
        for key, entry in ledger_all().items():
            if args.all or entry.get("status") in ALIVE | {"queued"}:
                print(f"{key:<22} {entry.get('mode', ''):<12} {entry.get('status', ''):<12} {entry.get('session_name') or '-'}")
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
    print(f"poller heartbeat: {age} · working {working_count()}/{cfg['limits']['max_workers']}")
    print(f"{'KEY':<22} {'MODE':<12} {'LEDGER':<12} {'ALLELE':<14} SESSION")
    for key, entry in ledger_all().items():
        if not args.all and entry.get("status") not in ALIVE | {"queued"}:
            continue
        sid = entry.get("session_id")
        allele = (live.get(sid) or {}).get("last_known_status") or ("archived" if sid in archived else ("missing" if sid else "-"))
        print(f"{key:<22} {entry.get('mode', ''):<12} {entry.get('status', ''):<12} {allele:<14} {entry.get('session_name') or '-'}")


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

    check("runtime writable", runtime_writable)
    check("code root", lambda: str(CODE_DIR))
    check("instance root", lambda: str(instance()))
    check("worker briefs", lambda: f"{len(list((CODE_DIR / 'workers').glob('*.md')))} briefs in {CODE_DIR / 'workers'}")
    for ok, name, detail in checks:
        print(f"{'✓' if ok else '✗'} {name}: {detail}")
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
    "todo": "#5e6ad2", "investigate": "#5e6ad2", "decompose": "#5e6ad2",
    "implementing": "#f2c94c", "investigating": "#f2c94c", "decomposing": "#f2c94c",
    "needs-input": "#f2994a", "done": "#4cb782", "failed": "#eb5757",
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


def cmd_init(args) -> None:
    """Create the Agent label group and its labels, and write config.json.

    Every other config value is a string somebody can type. The label ids are not: they are
    minted by the workspace, and without them nothing in this program can claim a ticket.
    That is the whole reason this subcommand exists.

    Safe to re-run, including after a partial failure. Labels are matched by name against the
    workspace rather than against config.json, so a run that created the group and four children
    before dying leaves those four discoverable: the next run reuses them and creates the rest.
    Linear is the source of truth for ids here, which is what makes the interrupted case benign
    — config.json is only ever written once every id is in hand.
    """
    dest = DISPATCHER_HOME / args.instance
    config_path = dest / "config.json"
    existing = read_json(config_path, None)
    if existing:
        cfg = existing
        print(f"reconciling the config already at {config_path}")
    else:
        cfg = json.loads((CODE_DIR / "config.example.json").read_text())
        cfg.pop("_comment", None)

    if args.api_key_env:
        cfg["linear"]["api_key_env"] = args.api_key_env
    if args.workspace:
        cfg["linear"]["mcp_workspace"] = args.workspace
    if args.team_key:
        cfg["linear"]["team_key"] = args.team_key
    if args.github_login:
        cfg["github"]["login"] = args.github_login
    if args.project:
        cfg["allele"]["default_project"] = args.project

    team_key = cfg["linear"].get("team_key")
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
    if not created and not args.dry_run:
        print("nothing changed in the workspace — this run was a no-op, as a re-run should be")
    print(f"\nnext: review {config_path}, then `python3 {Path(__file__).name} "
          f"--instance {args.instance} doctor`")


# --------------------------------------------------------------------------- main

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--instance", help="instance slug under ~/.locus/data/dispatcher "
                                           "(default: $DISPATCHER_INSTANCE, or the only one installed)")
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
    p.set_defaults(fn=cmd_init)

    p = sub.add_parser("poll")
    p.add_argument("--once", action="store_true")
    p.set_defaults(fn=cmd_poll)

    p = sub.add_parser("watch")
    p.add_argument("key")
    p.add_argument("--pr", help="OWNER/REPO#N — otherwise discovered from the ticket's attachments")
    p.add_argument("--once", action="store_true")
    p.set_defaults(fn=cmd_watch)

    p = sub.add_parser("ledger")
    p.add_argument("action", choices=["list", "get", "put"])
    p.add_argument("key", nargs="?")
    p.add_argument("fields", nargs="*", help="k=v (v parsed as JSON when it can be)")
    p.add_argument("--all", action="store_true")
    p.add_argument("--note")
    p.add_argument("--by")
    p.set_defaults(fn=cmd_ledger)

    p = sub.add_parser("label")
    p.add_argument("issue")
    p.add_argument("label")
    p.add_argument("--state", help="also move the ticket to this workflow state")
    p.add_argument("--by")
    p.set_defaults(fn=cmd_label)

    p = sub.add_parser("comment")
    p.add_argument("issue")
    p.add_argument("--key")
    p.add_argument("--mode")
    p.add_argument("--reply-to", dest="reply_to")
    p.set_defaults(fn=cmd_comment)

    p = sub.add_parser("brief")
    p.add_argument("key")
    p.set_defaults(fn=cmd_brief)

    p = sub.add_parser("status")
    p.add_argument("--all", action="store_true")
    p.set_defaults(fn=cmd_status)

    sub.add_parser("doctor").set_defaults(fn=cmd_doctor)

    args = parser.parse_args()
    if args.cmd == "ledger" and args.action in ("get", "put") and not args.key:
        parser.error("ledger get/put need a KEY")
    if args.cmd != "init":
        global _instance
        _instance = resolve_instance(getattr(args, "instance", None))
    args.fn(args)


if __name__ == "__main__":
    main()
