#!/usr/bin/env python3
"""Lint an agent review against house-style.md. Deterministic, read-only.

    python3 review_lint.py <PR> --repo OWNER/REPO

Exit 0 when every check passes, 1 otherwise. Workers run this before reporting done;
the Dispatcher runs it before reporting that a review is ready.

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
    a = ap.parse_args()
    L = Lint()

    reviews = gh("api", f"repos/{a.repo}/pulls/{a.pr}/reviews", "--paginate") or []
    me = gh("api", "user")["login"]
    bodies = [r for r in reviews if r["user"]["login"] == me and MARKER.search(r["body"] or "")]
    if not bodies:
        sys.exit("no agent review found on this PR")
    index = max(bodies, key=lambda r: len(r["body"]))
    b = index["body"]
    vis = visible(b)

    # ---- index
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
    L.check(open_rows or done_rows, "index.tables", f"{len(open_rows)} open rows, {len(done_rows)} resolved rows")
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
            n = count_findings(open_rows)
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
        all_rows = open_rows + done_rows
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
    mine = [c for c in comments if MARKER.search(c["body"] or "") and not c.get("in_reply_to_id")]
    L.check(mine, "threads.exist", f"{len(mine)} agent threads")
    bad_marker = [c for c in mine if not MARKER.search(c["body"].strip().splitlines()[-1])]
    L.check(not bad_marker, "threads.marker_last", f"{len(bad_marker)} thread(s) not ending with the marker")
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

    # An unpaired backtick is the signature of a mis-paired span; a backtick *surviving into the
    # rendered text* is not — ``code with a `tick` inside`` is legitimate and renders correctly.
    rendered = gh_full(f"repos/{a.repo}/pulls/{a.pr}/comments?per_page=100") or []
    broken = []
    for c in rendered:
        if not MARKER.search(c.get("body") or ""):
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
