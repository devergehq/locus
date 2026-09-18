#!/usr/bin/env python3
"""Deterministic, read-only checks on a PR description written to the review-craft house style.

    python3 pr_lint.py --repo OWNER/REPO --pr 9309      # lint the OPEN PR (needs gh)
    python3 pr_lint.py draft.md --changed-lines 50      # lint a local draft
    python3 pr_lint.py - --changed-lines 50             # lint stdin

Prefer `--pr`. Two of the checks cannot run on a draft at all: the diff size has to be
guessed, and the comment the description links its working notes to does not exist yet.
A budget checked against a guessed denominator reports PASS about nothing, so a local
draft must state `--changed-lines` rather than have one inferred for it.

The failure this exists to catch is not silent, it is invisible: in a repo that
squash-merges with `PR_BODY` as the commit message, an over-long description is not a
long page, it is a permanent commit. Eleven agent-authored PRs on Trilogy-Care/tc-portal
reached 9,000-39,000 characters before a human noticed.

This checks MECHANICS ONLY. It cannot tell a good description from a bad one. A clean run
means nothing is broken, not that anything is worth reading.

Exit codes: 0 pass (warnings included), 1 errors, 2 could not run.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

# min(CEILING, max(FLOOR, PER_LINE * changed lines)) - argued in house-style.md against a
# census of 5,557 tc-portal PR bodies and 45 recent human-authored ones, 18 September 2026.
BUDGET_FLOOR = 800
BUDGET_PER_LINE = 12
BUDGET_CEILING = 4000

# Past this (raw characters), a body with no headings has no hierarchy whatever else is true of it.
LONG_BODY_CHARS = 1200

# One line in the body pointing at the comment that holds the working. The heading is what
# ties the two together, and what this linter goes looking for on the PR.
#
# BY HEADING, NOT BY POSITION. The working is moved out of the body after the PR has been
# open a while, so its comment is the newest, not the first: on tc-portal #9309 it is the
# seventh comment, three days after the other six. A linter that checked position would
# have failed the one PR written to this convention.
WORKING_LINK = re.compile(
    r"^.*\b(working notes?|evidence and method|method and evidence)\b.*$",
    re.I | re.M,
)
# The comment's FIRST LINE must be a heading that starts with the phrase. Scanning a whole
# comment body matches the comment that merely *announces* the move, and a linter that
# passes on the wrong comment is worse than one that fails.
WORKING_HEADING = re.compile(
    r"\A\s*#{1,4}\s*(working notes?|evidence and method|method and evidence)\b", re.I
)

# Boilerplate the author does not control and cannot remove. It lands in the commit message
# like everything else, but charging it to the author's budget is charging them for a tool.
ATTRIBUTION = re.compile(
    r"\n*(?:🤖\s*)?Generated with \[Claude Code\]\([^)]*\)\s*\Z", re.I
)

# Words that rot. A commit message is read years later, with no "today" to anchor them.
ROTTING = re.compile(
    r"\b(currently|right now|at the moment|recently|nowadays|as of today|"
    r"the latest|at present|today|yesterday|last week|this week|just now)\b",
    re.I,
)

# Template debris that means the PR was opened half-written.
PLACEHOLDERS = [
    (re.compile(r"<!--.*?-->", re.S), "HTML comment from the PR template left in the body"),
    (re.compile(r"\*\([^)]{3,}\)\*"), "italic placeholder left unfilled"),
    (re.compile(r"\bTBD\b"), "TBD left in a published description"),
    (re.compile(r"<(?:add|insert|your|link|name|todo|describe|ticket)[^>]*>", re.I),
     "angle-bracket placeholder"),
    (re.compile(r"^\s*-\s*\[\s*\]\s*$", re.M), "empty checkbox with no item"),
    (re.compile(r"\[\s*\]\(\s*\)"), "empty link"),
    (re.compile(r"\bLorem ipsum\b", re.I), "lorem ipsum"),
    (re.compile(r"\bXXX+\b"), "XXX placeholder"),
]


def budget_for(changed_lines: int) -> int:
    return min(BUDGET_CEILING, max(BUDGET_FLOOR, BUDGET_PER_LINE * changed_lines))


class Finding:
    __slots__ = ("level", "rule", "msg")

    def __init__(self, level: str, rule: str, msg: str) -> None:
        self.level, self.rule, self.msg = level, rule, msg

    def render(self, width: int) -> str:
        return f"  {self.level:<5} {self.rule.ljust(width)}  {self.msg}"


def gh(*args: str):
    """Run gh and parse JSON. Exits 2 - a linter that cannot reach the PR has not found a fault."""
    try:
        r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        sys.exit(2)
    except subprocess.TimeoutExpired:
        sys.exit(2)
    if r.returncode:
        print(f"gh {' '.join(args[:3])}: {r.stderr.strip()[:200]}", file=sys.stderr)
        sys.exit(2)
    return json.loads(r.stdout) if r.stdout.strip() else None


def fetch_pr(repo: str, number: int) -> tuple[str, int, list[dict]]:
    """Return (body, changed lines, issue comments) for a PR."""
    pr = gh("api", f"repos/{repo}/pulls/{number}")
    comments = gh("api", f"repos/{repo}/issues/{number}/comments", "--paginate") or []
    body = pr.get("body") or ""
    changed = int(pr.get("additions") or 0) + int(pr.get("deletions") or 0)
    return body, changed, comments


def strip_code_fences(text: str) -> tuple[str, int | None]:
    """Return (text outside fenced code blocks, line of an unclosed fence or None)."""
    out: list[str] = []
    in_fence = False
    opened_at: int | None = None
    for n, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            opened_at = n if in_fence else None
            continue
        if not in_fence:
            out.append(line)
    return "\n".join(out), opened_at


def folds(md: str) -> list[str]:
    """The contents of every <details> block, folded or not."""
    return re.findall(r"<details\b.*?>(.*?)</details>", md or "", flags=re.S | re.I)


def unfolded(md: str) -> str:
    return re.sub(r"<details\b.*?>.*?</details>", "", md or "", flags=re.S | re.I)


def budgeted(md: str) -> str:
    """The body as stored, minus the attribution footer. RAW characters, markup included.

    Not a "visible" count, and the distinction is not pedantry - it is the whole reason the
    budget exists. A squash commit message is the body verbatim: every table pipe, every link
    target, every `<details>` tag and everything folded inside it is copied into the commit,
    where nothing renders and nothing collapses. A budget that discounted markup would be
    budgeting a page nobody is worried about.

    It is also the unit the three constants were measured in. The floor, the slope and the
    ceiling all come from `(.body|length)` over tc-portal's PRs - raw stored characters.
    Checking them against a stripped count made the effective budget about a quarter looser
    than anything that was ever measured.

    The one exclusion is the Claude Code attribution footer: ~64 characters of boilerplate an
    author is required to carry and cannot remove.

    `review_lint.py` strips markup for review bodies and is right to - a review body is read
    on a page, not copied into a commit. Different artefact, different unit.
    """
    return ATTRIBUTION.sub("", (md or "").rstrip()).rstrip()


def check_budget(body: str, changed: int) -> list[Finding]:
    n = len(budgeted(body))
    budget = budget_for(changed)
    if n <= budget:
        return []
    over = n / budget
    level = "ERROR" if over >= 1.25 else "WARN"
    return [
        Finding(
            level,
            "budget",
            f"{n:,} raw characters against a budget of {budget:,} for {changed:,} changed "
            f"lines ({over:.1f}x). This body becomes the squash commit message. Move the "
            f"evidence, the queries and the method into a PR comment headed "
            f"`## Working notes`, verbatim, and link to it from the body in one line.",
        )
    ]


def check_headings(body: str) -> list[Finding]:
    n = len(budgeted(body))
    if n <= LONG_BODY_CHARS:
        return []
    if re.search(r"^\s{0,3}#{1,4}\s+\S", body, re.M) or re.search(r"^\s*\*\*[^*]+\*\*\s*$", body, re.M):
        return []
    return [
        Finding(
            "WARN",
            "headings",
            f"{n:,} raw characters and no headings - a reader scrolling `git log` has no way "
            f"in; give each of why / what changed / what to look at / risks its own heading",
        )
    ]


def check_placeholders(body: str) -> list[Finding]:
    found = []
    for rx, msg in PLACEHOLDERS:
        if rx.search(body):
            found.append(Finding("ERROR", "placeholder", msg))
    return found


def check_rotting(body: str) -> list[Finding]:
    stripped, _ = strip_code_fences(body)
    hits = sorted({m.group(0).lower() for m in ROTTING.finditer(unfolded(stripped))})
    if not hits:
        return []
    return [
        Finding(
            "WARN",
            "rotting-date",
            f"relative time word(s) {', '.join(repr(h) for h in hits)} - this text becomes a "
            f"commit message with no 'today' to anchor it; name the date and the version",
        )
    ]


def check_squash_noise(body: str) -> list[Finding]:
    blocks = folds(body)
    if not blocks:
        return []
    total = sum(len(b) for b in blocks)
    if total <= 1500:
        return []
    return [
        Finding(
            "WARN",
            "fold-in-body",
            f"{len(blocks)} <details> block(s) holding {total:,} characters - folds do render in "
            f"a PR body, but a squash copies the raw tags into the commit message where nothing "
            f"collapses them, and they count against the budget for exactly that reason. Folds in "
            f"the body are for reviewer aids; the working goes in a `## Working notes` comment",
        )
    ]


def check_working_notes(body: str, comments: list[dict] | None) -> list[Finding]:
    """If the body links to working notes, the comment holding them must exist."""
    link = WORKING_LINK.search(unfolded(body))
    if not link:
        return []
    if comments is None:
        return [
            Finding(
                "WARN",
                "working-notes",
                "the body points at working notes, but a local draft cannot check the comment "
                "exists - re-run with --repo/--pr once the PR is open",
            )
        ]
    for c in comments:
        if WORKING_HEADING.match(c.get("body") or ""):
            return []
    return [
        Finding(
            "ERROR",
            "working-notes",
            f"the body points at working notes ({link.group(0).strip()[:70]!r}) but no comment on "
            f"this PR opens with a `## Working notes` heading - the link is dead and the working "
            f"is lost. The check is by heading, not position: the comment is usually the newest",
        )
    ]


def check_fences(body: str) -> list[Finding]:
    _, unclosed = strip_code_fences(body)
    if unclosed:
        return [
            Finding("ERROR", "code-fence", f"code fence opened on line {unclosed} is never closed")
        ]
    return []


def lint(body: str, changed: int, comments: list[dict] | None) -> list[Finding]:
    if not body.strip():
        return [Finding("ERROR", "empty", "the description is empty")]
    findings: list[Finding] = []
    findings += check_fences(body)
    findings += check_budget(body, changed)
    findings += check_headings(body)
    findings += check_placeholders(body)
    findings += check_rotting(body)
    findings += check_squash_noise(body)
    findings += check_working_notes(body, comments)
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("path", nargs="?", help="local markdown draft, or - for stdin")
    ap.add_argument("--repo", metavar="OWNER/REPO",
                    help="the repository the PR belongs to; no default, deliberately")
    ap.add_argument("--pr", type=int, help="PR number to lint")
    ap.add_argument("--changed-lines", type=int,
                    help="additions + deletions, required when linting a local draft")
    a = ap.parse_args()

    if a.pr is not None:
        if not a.repo:
            print("--pr needs --repo OWNER/REPO. It has no default, deliberately: run it "
                  "anywhere else and it lints a different repository's PR of the same number, "
                  "then reports PASS.", file=sys.stderr)
            return 2
        body, changed, comments = fetch_pr(a.repo, a.pr)
        if a.changed_lines is not None:
            changed = a.changed_lines
        source = f"{a.repo}#{a.pr}"
    elif a.path:
        if a.changed_lines is None:
            print("a local draft needs --changed-lines N (additions + deletions). The budget is "
                  "a ratio; checked against a guessed denominator it reports PASS about nothing.",
                  file=sys.stderr)
            return 2
        if a.path == "-":
            body, source = sys.stdin.read(), "stdin"
        else:
            try:
                body = open(a.path, encoding="utf-8").read()
            except OSError as exc:
                print(f"Could not read {a.path}: {exc}", file=sys.stderr)
                return 2
            source = a.path
        changed, comments = a.changed_lines, None
    else:
        ap.print_help()
        return 2

    findings = lint(body, changed, comments)
    errors = [f for f in findings if f.level == "ERROR"]
    warns = [f for f in findings if f.level == "WARN"]

    print(f"pr-craft lint: {source}  ({changed:,} changed lines, "
          f"budget {budget_for(changed):,} raw chars, body {len(budgeted(body)):,})")
    if not findings:
        print("  PASS - no mechanical problems found.")
        print("\n  Mechanics only. This says nothing about whether the description is the record "
              "of a decision or a transcript in disguise.")
        return 0

    width = max(len(f.rule) for f in findings)
    for f in findings:
        print(f.render(width))
    print(f"\n  {len(errors)} error(s), {len(warns)} warning(s).")
    if errors:
        print("  FAIL - fix the errors and run again.")
    else:
        print("  PASS with warnings - each is a judgement call, not a rule.")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
