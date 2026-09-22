#!/usr/bin/env python3
"""Lint a posted review against house-style.md. Deterministic, read-only.

    python3 review_lint.py <PR> --repo OWNER/REPO                 # agent review, else your latest
    python3 review_lint.py <PR> --repo OWNER/REPO --review-id ID  # exactly this review

Exit 0 when every check passes, 1 otherwise, 2 when there was nothing to lint. Workers run this
before reporting done; the Dispatcher runs it before reporting that a review is ready.

A review posted as the principal carries no `agent:` marker — house-style forbids one — and this
linter used to find only marked reviews, so it printed "no agent review found" and checked nothing
on exactly the reviews posted most. With no marked review it now lints your latest review, and says
which one it chose: a PASS that does not name what it read carries no information.

`--repo` is required and has no default. It carried one for as long as this script lived
beside a single repo's dispatcher, which made it a silent footgun the moment it did not:
run from anywhere else and it lints the wrong repository's PR of the same number, reporting
PASS or FAIL about a pull request nobody asked about.
"""
from __future__ import annotations
import argparse, json, re, subprocess, sys

MARKER = re.compile(r"agent:[A-Za-z0-9-]+/\w+")
SEV = re.compile(r"\*\*(Blocker|Should|Nit|Question)\b", re.I)
ALERT = {"blocker": "caution", "should": "warning", "question": "note"}
PARTS = ("**What**", "**Why it matters**", "**What I'd do**")


def gh_full(path):
    """Ask for body_text/body_html: the linter should judge what GitHub rendered, not what we sent."""
    return gh("api", "-H", "Accept: application/vnd.github.full+json", path, "--paginate")


def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    if r.returncode:
        sys.exit(f"gh {' '.join(args[:3])}: {r.stderr.strip()[:200]}")
    return json.loads(r.stdout) if r.stdout.strip() else None


def die(msg):
    """Nothing to lint is 'could not run' (2), never a verdict on a review nobody read."""
    print(msg, file=sys.stderr)
    sys.exit(2)


MERMAID = re.compile(r"^[ \t>]*```mermaid\b.*?^[ \t>]*```[ \t]*$", re.S | re.M)


def visible(md: str) -> str:
    """Folds and diagrams removed. A mermaid fence is read as a picture, not as prose, and its
    source alone runs ~700 characters for a dozen nodes — a single-finding thread's whole budget.
    Charging it would punish exactly the findings house-style asks to draw."""
    s = re.sub(r"<details>.*?</details>", "", md or "", flags=re.S)
    return MERMAID.sub("", s)


def prose(md: str) -> str:
    """What a reader actually reads: markup, the marker and required provenance don't count.

    Budgeting raw markdown punishes a finding for the blockquote it is required to sit in, which
    pushed one worker to move a call path out of the visible layer to satisfy the gate — the opposite
    of "a specific outranks the budget"."""
    s = visible(md)
    s = re.sub(r"^\s*>\s?", "", s, flags=re.M)            # blockquote markers
    s = re.sub(r"^\s*\[!(CAUTION|WARNING|NOTE|TIP|IMPORTANT)\]\s*$", "", s, flags=re.M)
    s = re.sub(r"<sub>.*?</sub>", "", s, flags=re.S)        # the agent marker
    s = re.sub(r"resolved by the PR author[^.\n]*\.?", "", s, flags=re.I)  # required provenance
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)        # links keep their text, lose the URL
    s = re.sub(r"[*`_#]+", "", s)                           # emphasis, code ticks, headings
    return re.sub(r"\s+", " ", s).strip()


def rows(md: str, heading: str) -> list[str]:
    m = re.search(rf"###\s+{heading}.*?\n(.*?)(?=\n###|\n<details|\Z)", md, re.S | re.I)
    if not m:
        return []
    return [l for l in m.group(1).splitlines()
            if l.strip().startswith("|") and not re.match(r"^\|[\s:|-]+\|$", l.strip())][1:]


def count_findings(row_lines: list[str]) -> int:
    """A grouped row must declare how many it holds as '×N'; that is what makes the counts auditable."""
    n = 0
    for line in row_lines:
        mult = re.search(r"[×x]\s*(\d+)", line)
        n += int(mult.group(1)) if mult else 1
    return n


# A finding written in the body rather than on a thread: a heading carrying a severity word.
# Case-sensitive on purpose — "what should change" is a heading, "Should" is a severity.
FINDING_HEAD = re.compile(r"^#{2,6}[ \t]+.*\b(Blocker|Should|Nit|Question)\b.*$", re.M)
HEADING = re.compile(r"^#{1,6}[ \t]+.*$", re.M)
FENCE = re.compile(r"^[ \t>]*```.*?^[ \t>]*```[ \t]*$", re.S | re.M)


def headings(md: str) -> list[re.Match]:
    """Headings outside code fences — a `# comment` in a shell block is not a section."""
    fences = [m.span() for m in FENCE.finditer(md)]
    return [m for m in HEADING.finditer(md) if not any(a <= m.start() < b for a, b in fences)]


def sections(md: str) -> list[tuple[str, str]]:
    """(heading, whole section) for each finding written in the body — the sectioned layout."""
    md = md or ""
    heads = headings(md)
    return [(m.group(0), md[m.start():heads[i + 1].start() if i + 1 < len(heads) else len(md)])
            for i, m in enumerate(heads) if FINDING_HEAD.fullmatch(m.group(0))]


# GitHub renders a body in a ~760px column. A table wider than that is not scrolled: its cells
# are squeezed, and long words are broken between letters ("Que stio n"). Two things cause it —
# a prose cell that claims the width, and a token too long to wrap. Thresholds are set to catch
# those and nothing a house index carries. Calibrated on live reviews: one-sentence claims ran to
# 131 characters and read fine; the cells that broke were quoted passages of 160+ carrying paths.
# A `basename.ts:NN` link stays under 30; a full path is what crosses 40.
CELL_PROSE, CELL_TOKEN = 140, 40


def cells(md: str) -> list[str]:
    s = FENCE.sub("", md or "")
    out = []
    for line in s.splitlines():
        line = re.sub(r"^[ \t>]*", "", line).strip()
        if not line.startswith("|") or re.match(r"^\|[\s:|-]+\|?$", line):
            continue
        # split on pipes outside code spans
        parts, buf, code = [], "", False
        for ch in line.strip("|"):
            if ch == "`":
                code = not code
            if ch == "|" and not code:
                parts.append(buf); buf = ""
            else:
                buf += ch
        parts.append(buf)
        out += [p.strip() for p in parts if p.strip()]
    return out


def shown(cell: str) -> str:
    """What the cell renders as: link text without its target, no emphasis or code ticks."""
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", cell)
    return re.sub(r"[*`_]+", "", s).strip()


def layout(md: str) -> tuple[list[str], list[str]]:
    prose_cells, long_tokens = [], []
    for c in cells(md):
        t = shown(c)
        if len(t) > CELL_PROSE:
            prose_cells.append(f"{len(t)} chars: {t[:40]}…")
        long_tokens += [f"{len(w)} chars: {w[:40]}…" for w in t.split() if len(w) > CELL_TOKEN]
    return prose_cells, long_tokens


def unhomed_diagrams(md: str) -> int:
    """Mermaid blocks whose nearest heading is neither a finding nor Problem fit, with no finding
    title between them — a diagram floating free of the thing it explains."""
    n = 0
    for m in MERMAID.finditer(md or ""):
        before = md[:m.start()]
        heads = headings(before)
        head = heads[-1] if heads else None
        since = before[head.end():] if head else before
        if head and (FINDING_HEAD.fullmatch(head.group(0)) or re.search(r"problem fit", head.group(0), re.I)):
            continue
        if SEV.search(since):
            continue
        n += 1
    return n


class Lint:
    def __init__(self):
        self.results: list[tuple[bool, str, str]] = []

    def check(self, ok, rule, detail="", warn_only=False):
        self.results.append((bool(ok) or warn_only and "warn", rule, detail) if not ok and warn_only
                            else (bool(ok), rule, detail))

    def report(self) -> int:
        width = max(len(r) for _, r, _ in self.results)
        for ok, rule, detail in self.results:
            label = {True: "PASS", False: "FAIL", "warn": "WARN"}[ok]
            shown = detail if (ok is not True or re.search(r"\d", detail)) else ""
            print(f"{label}  {rule.ljust(width)}  {shown}".rstrip())
        bad = [r for ok, r, _ in self.results if ok is False]
        warned = [r for ok, r, _ in self.results if ok == "warn"]
        passed = len(self.results) - len(bad) - len(warned)
        print(f"\n{passed}/{len(self.results)} checks passed" + (f", {len(warned)} warning(s)" if warned else ""))
        return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pr", type=int)
    ap.add_argument("--repo", required=True, metavar="OWNER/REPO",
                    help="the repository the PR belongs to; no default, deliberately")
    ap.add_argument("--review-id", type=int, metavar="ID",
                    help="lint exactly this review, marker or not, whoever posted it")
    a = ap.parse_args()
    L = Lint()

    reviews = gh("api", f"repos/{a.repo}/pulls/{a.pr}/reviews", "--paginate") or []
    me = gh("api", "user")["login"]
    bodies = [r for r in reviews if r["user"]["login"] == me and MARKER.search(r["body"] or "")]
    if a.review_id:
        index = next((r for r in reviews if r["id"] == a.review_id), None)
        if not index:
            die(f"review {a.review_id} is not on {a.repo}#{a.pr}")
    elif bodies:
        index = max(bodies, key=lambda r: len(r["body"]))
    else:
        # A principal's review: no marker, by house style. Reviews come back oldest first.
        mine = [r for r in reviews if r["user"]["login"] == me and (r["body"] or "").strip()]
        if not mine:
            die(f"no review by {me} with a body on {a.repo}#{a.pr} — pass --review-id to lint another")
        index = mine[-1]
    agent = bool(MARKER.search(index["body"] or ""))
    author = index["user"]["login"]
    print(f"review {index['id']} by {author} · " + ("agent review" if agent else "principal review, no marker")
          + f" · submitted {index.get('submitted_at') or '?'}\n")
    b = index["body"]
    found = sections(b)
    rest = b
    for _, sec in found:          # a finding in the body is budgeted as a thread, not as index prose
        rest = rest.replace(sec, "")
    vis = visible(rest)

    # ---- index
    if agent:
        # A principal's review is one of their reviews on the PR, not the only one; and it
        # carries neither the header nor the marker, deliberately. Those checks are the agent's.
        L.check(len([x for x in bodies if len(x["body"]) > 600]) == 1, "index.single",
                f"{len(bodies)} agent bodies, {len([x for x in bodies if len(x['body']) > 600])} substantial")
        L.check(b.lstrip().startswith("🤖"), "index.header")
        L.check(MARKER.search(b), "index.marker")
    method = next((l for l in b.splitlines() if l.startswith("**Method")), "")
    L.check(method and re.search(r"not (reviewed|checked)", method, re.I), "method.coverage",
            "the Method line must name what was NOT reviewed, as a count or a list")
    verdict = re.search(r"\*\*(?P<v>[^*]*?(Blocker|Should|Nit)[^*]*?)\*\*", b)
    L.check(verdict, "index.verdict")
    L.check(re.search(r"\*\*Method\*\*|^\*\*Method", b, re.M), "index.method",
            "method line under the verdict")
    L.check("### Problem fit" in b, "index.problem_fit")
    open_rows, done_rows = rows(b, "Open"), rows(b, "Resolved")
    L.check(open_rows or done_rows or found, "index.tables",
            f"{len(open_rows)} open rows, {len(done_rows)} resolved rows, {len(found)} body sections")
    L.check(re.search(r"Suppressed", b), "index.suppressed")
    L.check("](#" not in b, "index.no_dead_anchors", "anchors never resolve in a review body")
    words = len(re.sub(r"^\|.*\|$", "", vis, flags=re.M).split())
    L.check(words <= 400, "index.length", f"{words} visible prose words (<=400)")
    unlinked = [r for r in open_rows + done_rows if "](http" not in r]
    L.check(not unlinked, "index.rows_linked", f"{len(unlinked)} row(s) with no link")

    # verdict arithmetic — the trap: a grouped row is several findings
    if verdict:
        claimed_open = re.search(r"(\d+)\s+open", verdict.group("v"))
        claimed_fixed = re.search(r"(\d+)\s+fixed", verdict.group("v"))
        if claimed_open:
            n = count_findings(open_rows) if open_rows or done_rows else count_findings([h for h, _ in found])
            L.check(int(claimed_open.group(1)) == n, "verdict.open_count",
                    f"says {claimed_open.group(1)} open, tables hold {n}")
        if not claimed_fixed and re.search(r"all fixed", verdict.group("v"), re.I):
            raised = re.search(r"(\d+)\s+raised during development", verdict.group("v"))
            if raised:
                n = count_findings(done_rows)
                L.check(int(raised.group(1)) == n, "verdict.fixed_count",
                        f"says {raised.group(1)} raised and all fixed, tables hold {n}")
        if claimed_fixed:
            n = count_findings(done_rows)
            L.check(int(claimed_fixed.group(1)) == n, "verdict.fixed_count",
                    f"says {claimed_fixed.group(1)} fixed, tables hold {n}")

    if verdict:
        all_rows = open_rows + done_rows + [h for h, _ in found]
        for word, plural in (("Blocker", "Blockers"), ("Should", "Should"), ("Nit", "Nits")):
            claimed = re.search(rf"(\d+)\s+{plural}\b", verdict.group("v"))
            if not claimed:
                continue
            actual = count_findings([r for r in all_rows if re.search(rf"\b{word}\b", r)])
            L.check(int(claimed.group(1)) == actual, f"verdict.{word.lower()}_split",
                    f"says {claimed.group(1)} {plural}, rows hold {actual}")

    # ---- threads
    comments = gh("api", f"repos/{a.repo}/pulls/{a.pr}/comments?per_page=100", "--paginate") or []
    # replies (moved proof, answers to the author) are not findings and carry no shape rules
    if agent:
        mine = [c for c in comments if MARKER.search(c["body"] or "") and not c.get("in_reply_to_id")]
        L.check(mine, "threads.exist", f"{len(mine)} agent threads")
        bad_marker = [c for c in mine if not MARKER.search(c["body"].strip().splitlines()[-1])]
        L.check(not bad_marker, "threads.marker_last", f"{len(bad_marker)} thread(s) not ending with the marker")
    else:
        # No marker to find them by: the threads this review carries, and the author's
        # finding-shaped threads from earlier rounds. Their casual comments are not ours to grade.
        mine = [c for c in comments if not c.get("in_reply_to_id") and (
                c.get("pull_request_review_id") == index["id"]
                or c["user"]["login"] == author and SEV.search(c["body"] or ""))]
        L.check(mine or found, "threads.exist", f"{len(mine)} threads, {len(found)} body sections")
    # read the title (the line carrying the severity), not line 0 — an alert marker sits above it,
    # and a check that depends on layout tests the wrong thing
    def title_of(c):
        return next((l for l in c["body"].splitlines() if SEV.search(l)), "")
    GROUPED = re.compile(
        r"\bgrouped\b|\b(two|three|four|five|six|seven|eight|nine|ten)\s+"
        r"(findings?|nits?|issues?|corrections?|items?|sites?|cases?|inconsistencies|problems?)\b", re.I)
    ungrouped = [c for c in mine if GROUPED.search(title_of(c)) and not re.search(r"[×x]\s*\d", title_of(c))]
    L.check(not ungrouped, "threads.grouped_declared",
            f"{len(ungrouped)} grouped thread(s) not declaring ×N in the title")

    bad_alert, bad_parts, over, no_disp = [], [], [], []
    for c in mine:
        body, v = c["body"], visible(c["body"])
        sev = SEV.search(body)
        sev = sev.group(1).lower() if sev else ""
        wants = ALERT.get(sev)
        has = re.search(r"\[!(CAUTION|WARNING|NOTE)\]", body)
        if wants and (not has or has.group(1).lower() != wants):
            bad_alert.append(f"#{c['id']} {sev}")
        if sev == "nit" and has:
            bad_alert.append(f"#{c['id']} nit has a rail")
        if wants:
            if not all(p in body for p in PARTS):
                bad_parts.append(str(c["id"]))
            title = next((l for l in body.splitlines() if SEV.search(l)), "")
            if not re.search(r"·\s*`[^`]+`", title):
                no_disp.append(str(c["id"]))
        held = count_findings([body])
        budget = 700 if held == 1 else 250 * held
        n = len(prose(body))
        if n > budget:
            over.append(f"#{c['id']} {n}>{budget}")
    heavy_nits = [str(c["id"]) for c in mine
                  if (SEV.search(c["body"]) or [None]) and (SEV.search(c["body"]).group(1).lower() if SEV.search(c["body"]) else "") == "nit"
                  and all(p in c["body"] for p in PARTS)]
    L.check(not heavy_nits, "threads.nit_light",
            f"{len(heavy_nits)} nit(s) carrying the full four labels — weight should track severity",
            warn_only=True)
    L.check(not bad_alert, "threads.severity_rail", "; ".join(bad_alert[:3]))
    L.check(not bad_parts, "threads.four_parts", f"{len(bad_parts)} missing What/Why/What I'd do")
    L.check(not no_disp, "threads.disposition_top", f"{len(no_disp)} without a disposition chip")
    L.check(not over, "threads.budget", "; ".join(over[:3]))
    over_sec = []
    for head, sec in found:
        held = count_findings([head])
        budget, n = (700 if held == 1 else 250 * held), len(prose(sec))
        if n > budget:
            over_sec.append(f"{prose(head)[:40]} {n}>{budget}")
    if found:
        L.check(not over_sec, "sections.budget", "; ".join(over_sec[:3]))

    # ---- layout at GitHub's width
    wide, long_tok = [], []
    for md in [b] + [c["body"] for c in mine]:
        p, t = layout(md)
        wide += p; long_tok += t
    L.check(not wide, "layout.table_prose",
            f"{len(wide)} table cell(s) over {CELL_PROSE} characters — prose goes under a heading; "
            + "; ".join(wide[:2]))
    L.check(not long_tok, "layout.table_tokens",
            f"{len(long_tok)} unbroken token(s) over {CELL_TOKEN} characters in a table cell — "
            "GitHub breaks them between letters; " + "; ".join(long_tok[:2]))
    floating = unhomed_diagrams(b)
    L.check(not floating, "layout.diagram_homed",
            f"{floating} diagram(s) in the body not under a finding or Problem fit", warn_only=True)

    # An unpaired backtick is the signature of a mis-paired span; a backtick *surviving into the
    # rendered text* is not — ``code with a `tick` inside`` is legitimate and renders correctly.
    rendered = gh_full(f"repos/{a.repo}/pulls/{a.pr}/comments?per_page=100") or []
    broken = []
    ids = {c["id"] for c in mine}
    for c in rendered:
        if not (MARKER.search(c.get("body") or "") if agent else c["id"] in ids):
            continue
        raw = re.sub(r"```.*?```", "", c["body"], flags=re.S)   # fenced blocks pair by definition
        if raw.count("`") % 2:
            broken.append(str(c["id"]))
    L.check(not broken, "threads.renders_clean",
            f"{len(broken)} comment(s) with an unpaired backtick — a mis-paired span swallows words")

    # The PR description is not checked here. It once was, on the premise that descriptions were
    # out of scope and a `<details>` or mermaid block in one meant the review style had leaked in.
    # Both are now house style for descriptions, and `pr_lint.py` owns that artefact - its budget
    # counts folds and fences raw, and `fold-in-body` warns on bulk. A review linter that failed
    # on the author's description graded the reviewer for something they did not write.

    sys.exit(L.report())


if __name__ == "__main__":
    main()
