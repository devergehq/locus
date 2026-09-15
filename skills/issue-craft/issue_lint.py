#!/usr/bin/env python3
"""Deterministic, read-only checks on a Linear issue written to the issue-craft house style.

    python3 issue_lint.py --key DEV-123     # lint the SAVED issue (needs LINEAR_API_KEY)
    python3 issue_lint.py draft.md          # lint a local draft
    python3 issue_lint.py -                 # lint stdin

Prefer --key. The failure this exists to catch is silent: an unpaired `+++` swallows the
entire rest of the ticket into a collapsed section, the write returns success, and the
ticket looks fine until somebody opens it. Linting your draft cannot see what Linear
actually stored.

This checks MECHANICS ONLY. It cannot tell a good ticket from a bad one. A clean run means
nothing is broken, not that anything is worth reading.

Exit codes: 0 pass, 1 findings, 2 could not run.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

LINEAR_API = "https://api.linear.app/graphql"

FIRST_SCREEN_WORDS = 80
FIRST_SCREEN_CEILING = 150
LONG_BODY_WORDS = 300

# Words that make a durable record rot. A ticket is consulted for years.
ROTTING = re.compile(
    r"\b(currently|right now|at the moment|recently|nowadays|as of today|the latest|at present)\b",
    re.I,
)

# Template debris that means the ticket was saved half-written.
PLACEHOLDERS = [
    (re.compile(r"\*\([^)]*\)\*"), "italic placeholder left unfilled"),
    (re.compile(r"\bTBD\b"), "TBD left in a saved ticket"),
    (re.compile(r"<(?:add|insert|your|link|name|todo)[^>]*>", re.I), "angle-bracket placeholder"),
    (re.compile(r"^\s*-\s*\[\s*\]\s*$", re.M), "empty checkbox with no criterion"),
    (re.compile(r"\bLorem ipsum\b", re.I), "lorem ipsum"),
]

# Markup Linear accepts without complaint and then does not render.
DROPPED = [
    (re.compile(r"<details\b", re.I), "<details> does not render in Linear - use `+++ Title` ... `+++`"),
    (re.compile(r"<summary\b", re.I), "<summary> does not render in Linear"),
    (re.compile(r">\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]"), "GitHub alert syntax renders as a plain blockquote in Linear"),
    (re.compile(r"<br\s*/?>", re.I), "raw <br> does not render in Linear"),
]

# A markdown-emoji severity scale competing with Linear's own priority field.
SEVERITY_EMOJI = re.compile(r"[\U0001F534\U0001F7E0\U0001F7E1\U0001F535⚪]")


class Finding:
    __slots__ = ("level", "line", "msg")

    def __init__(self, level: str, line: int | None, msg: str) -> None:
        self.level, self.line, self.msg = level, line, msg

    def render(self) -> str:
        where = f"line {self.line}" if self.line else "ticket"
        return f"  {self.level:<5} {where:>9}  {self.msg}"


def fetch_issue(key: str) -> tuple[str, str]:
    """Return (title, description) for a Linear issue key. Raises SystemExit on failure."""
    token = os.environ.get("LINEAR_API_KEY")
    if not token:
        sys.exit("LINEAR_API_KEY is not set. Export it, or lint a local file instead.")

    query = "query($id:String!){ issue(id:$id){ title description } }"
    payload = json.dumps({"query": query, "variables": {"id": key}}).encode()
    req = urllib.request.Request(
        LINEAR_API,
        data=payload,
        headers={"Authorization": token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as exc:  # pragma: no cover - network
        sys.exit(f"Linear API returned HTTP {exc.code} for {key}.")
    except urllib.error.URLError as exc:  # pragma: no cover - network
        sys.exit(f"Could not reach the Linear API: {exc.reason}")

    if body.get("errors"):
        sys.exit(f"Linear API error: {body['errors'][0].get('message', body['errors'])}")
    issue = (body.get("data") or {}).get("issue")
    if not issue:
        sys.exit(f"No issue found for {key}.")
    return issue.get("title") or "", issue.get("description") or ""


def strip_code_fences(text: str) -> list[tuple[int, str]]:
    """Yield (line_number, line) for lines outside fenced code blocks."""
    out: list[tuple[int, str]] = []
    in_fence = False
    for n, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append((n, line))
    return out


def check_folds(lines: list[tuple[int, str]]) -> list[Finding]:
    """`+++ Title` opens, bare `+++` closes. Unpaired openers swallow the document."""
    found: list[Finding] = []
    stack: list[tuple[int, str]] = []
    for n, line in lines:
        stripped = line.strip()
        if not stripped.startswith("+++"):
            continue
        rest = stripped[3:].strip()
        if rest:
            stack.append((n, rest))
        elif stack:
            stack.pop()
        else:
            found.append(Finding("ERROR", n, "closing `+++` with no matching opener"))
    for n, title in stack:
        found.append(
            Finding(
                "ERROR",
                n,
                f"fold `{title}` is never closed - everything below it is swallowed into it",
            )
        )
    return found


def check_first_screen(lines: list[tuple[int, str]]) -> list[Finding]:
    """Everything before the first fold or the first heading is the budgeted region."""
    words = 0
    counted_any = False
    for _n, line in lines:
        stripped = line.strip()
        if stripped.startswith("+++") or stripped.startswith("#"):
            break
        if stripped:
            counted_any = True
            words += len(stripped.split())
    if not counted_any:
        return [Finding("ERROR", 1, "no first screen - the ticket opens on a fold or a heading")]
    if words > FIRST_SCREEN_CEILING:
        return [
            Finding(
                "ERROR",
                1,
                f"first screen is {words} words, over the {FIRST_SCREEN_CEILING} ceiling - fold something",
            )
        ]
    if words > FIRST_SCREEN_WORDS:
        return [
            Finding(
                "WARN",
                1,
                f"first screen is {words} words, over the {FIRST_SCREEN_WORDS} target "
                "(fine if the overage is a path, a count or a figure)",
            )
        ]
    return []


def check_nothing_folded(lines: list[tuple[int, str]]) -> list[Finding]:
    """A long ticket with no folds has not demoted anything. It is the wall this style exists to stop."""
    total = sum(len(line.split()) for _n, line in lines)
    has_fold = any(line.strip().startswith("+++") for _n, line in lines)
    if total > LONG_BODY_WORDS and not has_fold:
        return [
            Finding(
                "WARN",
                None,
                f"{total} words and nothing is folded - demote the evidence into `+++` sections "
                "so the first screen carries the decision",
            )
        ]
    return []


def check_backticks(lines: list[tuple[int, str]]) -> list[Finding]:
    return [
        Finding("WARN", n, "odd number of backticks on this line - inline code is probably unclosed")
        for n, line in lines
        if line.count("`") % 2
    ]


def check_patterns(lines: list[tuple[int, str]]) -> list[Finding]:
    found: list[Finding] = []
    for n, line in lines:
        for rx, msg in PLACEHOLDERS:
            if rx.search(line):
                found.append(Finding("ERROR", n, msg))
        for rx, msg in DROPPED:
            if rx.search(line):
                found.append(Finding("ERROR", n, msg))
        if ROTTING.search(line):
            found.append(
                Finding("WARN", n, "relative time word - name the date and version instead")
            )
        if SEVERITY_EMOJI.search(line):
            found.append(
                Finding(
                    "WARN",
                    n,
                    "severity emoji - use Linear's priority field, not a second scale in markdown",
                )
            )
    return found


def check_title(title: str) -> list[Finding]:
    if not title:
        return []
    words = title.split()
    found: list[Finding] = []
    if len(words) < 4:
        found.append(Finding("WARN", None, f"title is {len(words)} words - a claim usually needs more"))
    lead = re.match(r"^\s*(fix|update|improve|investigate|refactor|add|change|review|check)\b", title, re.I)
    if lead and not re.search(r"\d", title):
        found.append(
            Finding(
                "WARN",
                None,
                f"title opens with '{lead.group(1)}' and carries no number - it names a topic, not a claim",
            )
        )
    return found


def lint(title: str, description: str) -> list[Finding]:
    if not description.strip():
        return [Finding("ERROR", None, "description is empty")]
    lines = strip_code_fences(description)
    findings: list[Finding] = []
    findings += check_title(title)
    findings += check_folds(lines)
    findings += check_first_screen(lines)
    findings += check_nothing_folded(lines)
    findings += check_backticks(lines)
    findings += check_patterns(lines)
    findings.sort(key=lambda f: (f.line or 0))
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?", help="local markdown file, or - for stdin")
    ap.add_argument("--key", help="Linear issue key, e.g. DEV-123 (needs LINEAR_API_KEY)")
    ap.add_argument("--title", default="", help="title to lint alongside a local file")
    args = ap.parse_args()

    if args.key:
        title, description = fetch_issue(args.key)
        source = args.key
    elif args.path == "-":
        title, description, source = args.title, sys.stdin.read(), "stdin"
    elif args.path:
        try:
            description = open(args.path, encoding="utf-8").read()
        except OSError as exc:
            sys.exit(f"Could not read {args.path}: {exc}")
        title, source = args.title, args.path
    else:
        ap.print_help()
        return 2

    findings = lint(title, description)
    errors = [f for f in findings if f.level == "ERROR"]
    warns = [f for f in findings if f.level == "WARN"]

    print(f"issue-craft lint: {source}")
    if not findings:
        print("  PASS - no mechanical problems found.")
        print("\n  Mechanics only. This says nothing about whether the ticket is worth reading.")
        return 0

    for f in findings:
        print(f.render())
    print(f"\n  {len(errors)} error(s), {len(warns)} warning(s).")
    if errors:
        print("  FAIL - fix the errors and run again.")
    else:
        print("  PASS with warnings - each is a judgement call, not a rule.")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
