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

LONG_BODY_WORDS = 300      # past this, a body with no headings has no hierarchy
UNFOLDED_BODY_WORDS = 800  # past this, a body with no folds has probably not demoted its evidence
TITLE_MAX_WORDS = 20

# Sections that must stay visible. A fold whose title matches one of these has hidden
# something the reader needs in order to decide.
MUST_BE_VISIBLE = re.compile(
    r"\b(acceptance|criteria|done when|definition of done|out of scope|scope|decision|question|blocked|blocker)\b",
    re.I,
)

# An ask - something needed from a person. It belongs under its own heading, with the owner.
ASK_HEADING = re.compile(r"\b(decision|question|blocked|blocker|sign-?off|needs?)\b", re.I)
ASK_LINE = re.compile(
    r"\b(decision (needed|required)|open question|one question|owner:|needs? a decision|decided,)\b",
    re.I,
)

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


def strip_code_fences(text: str) -> tuple[list[tuple[int, str]], int | None]:
    """Return (lines outside fenced code blocks, line of an unclosed fence or None)."""
    out: list[tuple[int, str]] = []
    in_fence = False
    opened_at: int | None = None
    for n, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            opened_at = n if in_fence else None
            continue
        if not in_fence:
            out.append((n, line))
    return out, opened_at


def is_heading(line: str) -> bool:
    return bool(re.match(r"^\s{0,3}#{1,4}\s+\S", line))


def fold_depth_by_line(lines: list[tuple[int, str]]) -> dict[int, str | None]:
    """Map each line number to the title of the fold it sits inside, or None."""
    inside: dict[int, str | None] = {}
    stack: list[str] = []
    for n, line in lines:
        stripped = line.strip()
        if stripped.startswith("+++"):
            rest = stripped[3:].strip()
            if rest:
                stack.append(rest)
            elif stack:
                stack.pop()
            inside[n] = stack[-1] if stack else None
            continue
        inside[n] = stack[-1] if stack else None
    return inside


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


def check_summary(lines: list[tuple[int, str]]) -> list[Finding]:
    """The body must open with prose - the summary - not with a fold or a heading."""
    for _n, line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("+++") or is_heading(stripped):
            level = "ERROR" if stripped.startswith("+++") else "WARN"
            return [
                Finding(
                    level,
                    _n,
                    "no summary - the ticket opens on a fold or a heading; a paragraph of prose "
                    "above the first heading lets a reader decide without reading a section",
                )
            ]
        return []
    return []


def check_hierarchy(lines: list[tuple[int, str]]) -> list[Finding]:
    """Headings are the skeleton. A long body without them has no hierarchy, whatever it folds."""
    total = sum(len(line.split()) for _n, line in lines)
    has_heading = any(is_heading(line) for _n, line in lines)
    has_fold = any(line.strip().startswith("+++") for _n, line in lines)
    found: list[Finding] = []
    if total > LONG_BODY_WORDS and not has_heading:
        found.append(
            Finding(
                "WARN",
                None,
                f"{total} words and no headings - the reader cannot find anything; "
                "give each answer its own `##`",
            )
        )
    if total > UNFOLDED_BODY_WORDS and not has_fold:
        found.append(
            Finding(
                "WARN",
                None,
                f"{total} words and nothing is folded - raw evidence and query output belong "
                "in `+++` sections under the answer they support",
            )
        )
    return found


def check_folded_sections(lines: list[tuple[int, str]]) -> list[Finding]:
    """The acceptance criteria, the scope and the ask are never folded."""
    found: list[Finding] = []
    for n, line in lines:
        stripped = line.strip()
        if stripped.startswith("+++") and stripped[3:].strip():
            title = stripped[3:].strip()
            if MUST_BE_VISIBLE.search(title):
                found.append(
                    Finding(
                        "WARN",
                        n,
                        f"fold `{title}` hides a section the reader needs in order to decide - "
                        "keep it visible under a heading and fold only the bulk beneath it",
                    )
                )
    return found


def check_ask(lines: list[tuple[int, str]]) -> list[Finding]:
    """An ask gets its own heading with the owner. Not a trailing sentence, not a fold."""
    has_ask_heading = any(is_heading(line) and ASK_HEADING.search(line) for _n, line in lines)
    inside = fold_depth_by_line(lines)
    found: list[Finding] = []
    for n, line in lines:
        stripped = line.strip()
        if not stripped or is_heading(stripped) or stripped.startswith("+++"):
            continue
        fold = inside.get(n)
        if ASK_LINE.search(stripped):
            if fold:
                found.append(
                    Finding(
                        "WARN",
                        n,
                        f"an ask is inside fold `{fold}` - nobody will see it; give it "
                        "`## Decision needed - <owner>` near the top",
                    )
                )
            elif not has_ask_heading:
                found.append(
                    Finding(
                        "WARN",
                        n,
                        "an ask is buried in prose - give it its own heading near the top, "
                        "with the owner named",
                    )
                )
        elif fold and stripped.endswith("?") and not has_ask_heading:
            found.append(
                Finding(
                    "WARN",
                    n,
                    f"a question inside fold `{fold}` and no ask heading anywhere - if this "
                    "needs an answer, surface it",
                )
            )
    return found


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
    if len(words) > TITLE_MAX_WORDS:
        found.append(
            Finding(
                "WARN",
                None,
                f"title is {len(words)} words - that is the summary, not the claim; "
                "keep the claim and move the rest into the body",
            )
        )
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
    lines, unclosed_fence = strip_code_fences(description)
    findings: list[Finding] = []
    if unclosed_fence:
        findings.append(
            Finding("ERROR", unclosed_fence, "code fence is never closed - everything below it renders as code")
        )
    findings += check_title(title)
    findings += check_folds(lines)
    findings += check_summary(lines)
    findings += check_hierarchy(lines)
    findings += check_folded_sections(lines)
    findings += check_ask(lines)
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
