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
long page, it is a permanent commit. Eleven agent-authored PRs in the repository these
constants were measured on reached 9,000-39,000 characters before a human noticed.

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
# census of 5,557 PR bodies and 45 recent human-authored ones, 18 September 2026. The
# repository is described in house-style.md and deliberately not named: this script installs
# anywhere, and the numbers travel where the provenance must not. Re-measure on your own.
BUDGET_FLOOR = 800
BUDGET_PER_LINE = 12
BUDGET_CEILING = 4000

# The budget is a target, not a gate. Under this multiple the finding is advisory - the
# author is told where the description should gravitate and left to keep their specifics.
# At or above it, the body is carrying its working and the move is named.
#
# Two is not a round number chosen for looking reasonable. It is the lowest threshold that
# still catches everything the rule was built for and nothing a careful author does:
#   - The twelve-PR census in house-style.md that forced the budget runs 3x to 22x. Every
#     one is still an ERROR at 2x, with margin. Nothing real was ever measured between
#     1.25x and 3x.
#   - The reference description lands at 1.1x, and a 29-line fixture fix rewritten to this
#     rule lands at 1.2x. Both were ERRORs away from being shaved, and what an author
#     shaves at that range is a path, a count or a date - the specifics the budget exists
#     to make room for.
#   - It was 1.25x until 20 September 2026, which put an ERROR below the level the people
#     using the rule call acceptable: a 1,200-character body for a small diff (1.5x), or a
#     5,000-character description that earned its place (1.25x of the ceiling). Both are
#     fine by the standard this skill is trying to encode, and both failed the check.
BUDGET_ERROR_MULTIPLE = 2.0

# Past this (raw characters), a body with no headings has no hierarchy whatever else is true of it.
LONG_BODY_CHARS = 1200

# One line in the body pointing at the comment that holds the working. The heading is what
# ties the two together, and what this linter goes looking for on the PR.
#
# BY HEADING, NOT BY POSITION. The working is moved out of the body after the PR has been
# open a while, so its comment is the newest, not the first: on the first PR written to this
# convention it is the seventh comment, three days after the other six. A linter that checked position would
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


# Sections whose content is short by nature and expensive to lose: the references, the
# security sentence, the rollback line someone reads during an incident. Their content is NOT
# budgeted. The budget exists to contain the sections that actually explode - the summary, the
# reviewer notes, the testing narrative - and an author shaving a ticket link or a rollback
# step to reach a character count is the rule doing harm.
#
# This default list is the intersection of what PR templates commonly ask for. It will not fit
# every template, so it is a starting point rather than a closed set: --exempt-section adds to
# it and --no-default-exempt replaces it. A caller who knows the template should say so.
DEFAULT_EXEMPT_SECTIONS = (
    "related", "reference", "link", "security impact", "security", "deployment", "rollback",
)

# But the exemption is for fixed overhead, not a hiding place. Past this many raw characters
# a single exempt section starts counting again, so "## Related" cannot become the new body.
#
# 750 is p90 of 226 such sections measured across 99 live PR bodies in the reference repository
# on 20 September 2026 (p50 263, p75 473, p90 728, p95 1,018, max 1,634), rounded up. Nine in
# ten real ones pass through free; the outliers are carrying something that is not a reference.
EXEMPT_SECTION_CAP = 750

# Where PR templates live. Tried in order, first hit wins. The three GitHub auto-fill paths
# are here because most repos use them - but a repo that wants a new PR body to arrive EMPTY
# has to keep its templates somewhere GitHub does not recognise, and those repos are exactly
# the ones with a considered template convention. So the list looks past GitHub's conventions
# rather than assuming they are the whole story. --template covers anywhere else.
TEMPLATE_PATHS = (
    ".github/PULL_REQUEST_TEMPLATE",
    "docs/pr-templates",
    "docs/pr_templates",
    ".github/pr-templates",
    ".github/pull_request_template.md",
    "pull_request_template.md",
    "docs/pull_request_template.md",
    ".github/PULL_REQUEST_TEMPLATE.md",
)

HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.+?)\s*$", re.M)


def norm_heading(text: str) -> str:
    """Fold a heading to something two templates can be compared on."""
    t = re.sub(r"[^a-z0-9 ]+", " ", text.lower())
    return re.sub(r"\s+", " ", t).strip()


def sections(body: str) -> list[tuple[str, int, int]]:
    """(normalised heading, start offset, end offset) for every heading in the body."""
    marks = [(m.start(), norm_heading(m.group(2))) for m in HEADING.finditer(body)]
    out = []
    for i, (pos, name) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(body)
        out.append((name, pos, end))
    return out


def exempt_credit(
    body: str, exempt: tuple[str, ...] = DEFAULT_EXEMPT_SECTIONS, cap: int = EXEMPT_SECTION_CAP
) -> tuple[int, list[tuple[str, int, int]]]:
    """Characters the budget does not charge for, and the per-section workings."""
    credit, per = 0, []
    for name, start, end in sections(body):
        if any(e in name for e in exempt):
            n = end - start
            free = min(n, cap)
            credit += free
            per.append((name, n, free))
    return credit, per


def counted_chars(
    body: str, exempt: tuple[str, ...] = DEFAULT_EXEMPT_SECTIONS, cap: int = EXEMPT_SECTION_CAP
) -> int:
    """What the budget actually charges: raw, less the attribution, less exempt sections."""
    b = budgeted(body)
    return max(0, len(b) - exempt_credit(b, exempt, cap)[0])


def fetch_templates(repo: str | None, root: str = ".") -> dict[str, str]:
    """Discover the repo's PR templates. Empty dict when it has none - this skill is
    cross-repo, and a repo with no templates must not be nagged about matching one."""
    import os

    found: dict[str, str] = {}
    for path in TEMPLATE_PATHS:
        if repo:
            data = gh_soft("api", f"repos/{repo}/contents/{path}")
            if data is None:
                continue
            entries = data if isinstance(data, list) else [data]
            for e in entries:
                name = e.get("name", "")
                if not name.lower().endswith(".md") or name.lower() == "readme.md":
                    continue
                blob = gh_soft("api", f"repos/{repo}/contents/{e['path']}")
                if blob and blob.get("content"):
                    import base64
                    found[name] = base64.b64decode(blob["content"]).decode("utf-8", "replace")
        else:
            full = os.path.join(root, path)
            if os.path.isdir(full):
                for name in sorted(os.listdir(full)):
                    if name.lower().endswith(".md") and name.lower() != "readme.md":
                        found[name] = open(os.path.join(full, name), encoding="utf-8").read()
            elif os.path.isfile(full):
                found[os.path.basename(full)] = open(full, encoding="utf-8").read()
        if found:
            break
    return found


def gh_soft(*args: str):
    """gh, but a 404 is an answer rather than a failure. Template discovery probes paths
    that are SUPPOSED to be absent in most repos; exiting 2 on the first miss would make
    the linter unrunnable everywhere except the one repo it was written in."""
    try:
        r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if r.returncode or not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def match_template(body: str, templates: dict[str, str]) -> tuple[str, list[str], int]:
    """Best-matching template, the headings it asks for that the body does not carry, and
    how many it does. Extra headings are never a fault: a template is a floor, not a cage."""
    body_heads = [n for n, _, _ in sections(body)]
    best = ("", [], -1)
    for name, text in sorted(templates.items()):
        wanted = [norm_heading(m.group(2)) for m in HEADING.finditer(text)
                  if len(m.group(1)) >= 2]
        if not wanted:
            continue
        missing, hit = [], 0
        for w in wanted:
            if any(w in b or b in w for b in body_heads):
                hit += 1
            else:
                missing.append(w)
        if hit > best[2]:
            best = (name, missing, hit)
    return best


def check_template(
    body: str, templates: dict[str, str], declared: bool, override: str | None = None
) -> list[Finding]:
    """Severity follows the strength of the claim, not any repo's policy.

    A template the CALLER SUPPLIED is an assertion: this is the shape a description here
    takes. Drift from it is an error. A template this script DISCOVERED by walking
    conventional paths is an inference - the repo never said it was mandatory, and it may not
    be - so drift from it is a warning. `--require-template` and `--template-advisory` move
    the line when the caller knows better than either default.

    A repo with no templates produces no finding at all. This linter runs across
    repositories and must not invent a convention for one that has none.
    """
    if not templates:
        return []
    level = override or ("ERROR" if declared else "WARN")
    how = "supplied" if declared else "discovered"
    name, missing, hit = match_template(body, templates)
    if hit <= 0:
        return [Finding(
            level, "template",
            f"the description matches none of the {len(templates)} {how} PR template(s) "
            f"({', '.join(sorted(templates))}). A template encodes what a description here has "
            f"to carry - the rollback line, the security sentence, the references someone will "
            f"need later. A description that is SHORTER than its template is fine; one that is "
            f"UNRECOGNISABLE from it is not shorter, it is different.",
        )]
    if not missing:
        return []
    return [Finding(
        level, "template",
        f"closest {how} template is `{name}` ({hit} of {hit + len(missing)} headings present); "
        f"missing: {', '.join(missing)}. Keep the template's shape and make the prose inside it "
        f"tighter - that is what the budget is for. Cut a section only when it genuinely does "
        f"not apply, and say so in a line rather than deleting the heading. Exempt sections are "
        f"not budgeted, so keeping them costs you nothing.",
    )]


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
    ceiling all come from `(.body|length)` over real PR bodies - raw stored characters.
    Checking them against a stripped count made the effective budget about a quarter looser
    than anything that was ever measured.

    The one exclusion is the Claude Code attribution footer: ~64 characters of boilerplate an
    author is required to carry and cannot remove.

    `review_lint.py` strips markup for review bodies and is right to - a review body is read
    on a page, not copied into a commit. Different artefact, different unit.
    """
    return ATTRIBUTION.sub("", (md or "").rstrip()).rstrip()


def check_budget(body: str, changed: int, exempt: tuple[str, ...] = DEFAULT_EXEMPT_SECTIONS,
                 cap: int = EXEMPT_SECTION_CAP) -> list[Finding]:
    n = counted_chars(body, exempt, cap)
    budget = budget_for(changed)
    if n <= budget:
        return []
    over = n / budget
    head = (
        f"{n:,} budgeted characters against a target of {budget:,} for {changed:,} changed "
        f"lines ({over:.1f}x)."
    )
    if over < BUDGET_ERROR_MULTIPLE:
        return [
            Finding(
                "WARN",
                "budget",
                f"{head} Advisory below {BUDGET_ERROR_MULTIPLE:g}x - the target is where a "
                f"description should gravitate, not a line to shave specifics against. If "
                f"the overage is a path, a line range, a count or a date, keep it and say "
                f"why in the body.",
            )
        ]
    return [
        Finding(
            "ERROR",
            "budget",
            f"{head} At {BUDGET_ERROR_MULTIPLE:g}x or more the body is carrying its working. "
            f"This body becomes the squash commit message, verbatim. Move the evidence, the "
            f"queries and the method into a PR comment headed `## Working notes`, and link "
            f"to it from the body in one line.",
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


def lint(body: str, changed: int, comments: list[dict] | None,
         templates: dict[str, str] | None = None, declared: bool = False,
         template_level: str | None = None,
         exempt: tuple[str, ...] = DEFAULT_EXEMPT_SECTIONS,
         cap: int = EXEMPT_SECTION_CAP) -> list[Finding]:
    if not body.strip():
        return [Finding("ERROR", "empty", "the description is empty")]
    findings: list[Finding] = []
    findings += check_fences(body)
    findings += check_template(body, templates or {}, declared, template_level)
    findings += check_budget(body, changed, exempt, cap)
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
    ap.add_argument("--template", "--templates", dest="template", metavar="PATH",
                    help="the template a description here is expected to take - a markdown "
                         "file, or a directory of them. Supplying it is an assertion, so "
                         "drift from it is an ERROR; a template merely DISCOVERED on a "
                         "conventional path is an inference, and drift is a WARN")
    ap.add_argument("--require-template", action="store_true",
                    help="treat a discovered template as if it were supplied: drift is an ERROR")
    ap.add_argument("--template-advisory", action="store_true",
                    help="treat a supplied template as guidance: drift is a WARN")
    ap.add_argument("--no-templates", action="store_true",
                    help="skip template discovery and template checking entirely")
    ap.add_argument("--exempt-section", metavar="NAME", action="append", default=[],
                    help="a heading whose content the budget does not charge for, matched as "
                         "a substring, case-insensitive. Repeatable. ADDS to the defaults "
                         f"({', '.join(DEFAULT_EXEMPT_SECTIONS)}) - use it for the sections "
                         "your template asks for that this list does not name")
    ap.add_argument("--no-default-exempt", action="store_true",
                    help="use only the --exempt-section values, discarding the defaults")
    ap.add_argument("--exempt-cap", type=int, default=EXEMPT_SECTION_CAP, metavar="N",
                    help=f"per-section ceiling on the exemption (default {EXEMPT_SECTION_CAP}); "
                         "past it a section is charged again, so an exempt heading cannot "
                         "quietly become the body")
    a = ap.parse_args()

    # Fold the caller's names the same way headings are folded, or "on-call runbook" would
    # never match the heading "On-call runbook" (which normalises to "on call runbook").
    exempt = tuple(norm_heading(x) for x in a.exempt_section if norm_heading(x))
    if not a.no_default_exempt:
        exempt = DEFAULT_EXEMPT_SECTIONS + exempt
    if not exempt:
        exempt = ()
    if a.require_template and a.template_advisory:
        print("--require-template and --template-advisory contradict each other.",
              file=sys.stderr)
        return 2
    template_level = ("ERROR" if a.require_template else
                      "WARN" if a.template_advisory else None)

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

    templates: dict[str, str] = {}
    declared = False
    if not a.no_templates:
        if a.template:
            import os
            declared = True
            if os.path.isdir(a.template):
                templates = {n: open(os.path.join(a.template, n), encoding="utf-8").read()
                             for n in sorted(os.listdir(a.template))
                             if n.lower().endswith(".md") and n.lower() != "readme.md"}
            elif os.path.isfile(a.template):
                templates = {os.path.basename(a.template):
                             open(a.template, encoding="utf-8").read()}
            else:
                print(f"--template: no such file or directory: {a.template}", file=sys.stderr)
                return 2
            if not templates:
                print(f"--template: no .md templates found in {a.template}", file=sys.stderr)
                return 2
        else:
            templates = fetch_templates(a.repo if a.pr is not None else None)

    findings = lint(body, changed, comments, templates, declared, template_level,
                    exempt, a.exempt_cap)
    errors = [f for f in findings if f.level == "ERROR"]
    warns = [f for f in findings if f.level == "WARN"]

    credit, per = exempt_credit(budgeted(body), exempt, a.exempt_cap)
    tmpl = ""
    if templates:
        name, _, hit = match_template(body, templates)
        how = "supplied" if declared else "discovered"
        tmpl = (f", {how} template {name}" if hit > 0
                else f", {len(templates)} {how} templates, none matched")
    print(f"pr-craft lint: {source}  ({changed:,} changed lines, "
          f"target {budget_for(changed):,} chars, body {len(budgeted(body)):,} raw, "
          f"{counted_chars(body, exempt, a.exempt_cap):,} budgeted{tmpl})")
    if credit:
        detail = ", ".join(f"{n} {f}{'' if f == raw else f' of {raw}'}" for n, raw, f in per)
        print(f"  {credit:,} characters not budgeted - {detail}")
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
