#!/usr/bin/env python3
"""Deterministic, read-only checks on a review's brief, written to `understand.md`.

    python3 brief_lint.py brief.json        # a brief before it is written
    python3 brief_lint.py -                 # the same, from standard input
    python3 brief_lint.py --review 41       # the brief already saved, through `review-desk`
    python3 brief_lint.py --limits          # print the limits table and stop

The failure this exists to catch is not a wrong brief, it is an unreadable one. On the review
that forced it, the session recorded 310 words of prose and a 50-line typed sketch for what the
board Patrick approved on 10 October 2026 carries in 85 words and one picture. The house target
for a draft was 150 words and the session wrote 1,381, so asking in prose does not hold.

This checks MECHANICS ONLY. It cannot tell a brief that is right from one that is wrong — it
catches the shapes that are unreadable whatever they say.

**The top layer is what is budgeted**: the headline, and each problem's "was wrong" and "now"
line. Detail behind a click — `problems[].detail_before`, `.detail_after`, an option's arguments,
a part's summary, the blind pass's answer — is never length-checked, here or anywhere. Depth is
allowed. It is the top that is budgeted.

**There is no limit keyed on the size of the diff**, and there is not to be one: Patrick ruled on
9 October 2026 that the brief gate is `never | always` and not a function of how many lines a pull
request changes. Nothing below reads `parts[].lines_added`, `lines_removed`, or any count of files.

Exit codes: 0 pass, 1 the brief has a fault, 2 could not run.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys

# ── The limits ───────────────────────────────────────────────────────────────────────────────
#
# One table, at the top, each row carrying what it limits, the number, and where the number
# comes from — so a limit can be tuned without reading a line of code.
#
# **`understand.md` owns every per-slot limit.** DEV-884 proposed its own table and three rows
# disagreed with that file; the file won each time, and the disagreement is named in the source
# so nobody has to re-derive which way it went. These are one board's numbers, measured on
# 10 October 2026, and provisional in exactly the way that file says they are.
#
# A range is (lowest, highest) and both ends fail. A single number is a ceiling.
#
# **A slot limit is a cap; the total is a budget, and the budget is deliberately tighter than the
# sum of the caps.** At understand.md's four problems, eight lines at the 20-word cap plus a
# 20-word headline would be 180 against a 150-word total — and that is the design rather than an
# oversight: a cap stops one line running away, and the budget stops the top layer doing it
# collectively. A brief cannot spend every cap at once. `top.length` therefore names the longest
# lines it found, instead of telling an author to shorten everything.
LIMITS: tuple[tuple[str, str, object, str], ...] = (
    ("headline.words", "The headline", 20,
     "understand.md, Understand: 'One sentence, at most 20 words'. The slot read 'under 20' and "
     "DEV-884's table said 25; Patrick ruled 'at most 20' on 10 Oct 2026. The approved board ran "
     "19, and Review Desk's real-length brief runs 20"),
    ("line.words", 'A problem\'s "was wrong" or "now" line', 20,
     "understand.md, Understand: 'Was wrong / now ... at most 20 words a line'. DEV-884 "
     "measured it from the approved board of 10 Oct 2026, where the longest ran 16, and the "
     "slot carries the number now rather than only the two lines"),
    ("box.title.words", "A flow box title", 12,
     "DEV-884, from the approved board of 10 Oct 2026, where the longest ran 10"),
    ("box.note.words", "A flow box note", 14,
     "DEV-884, from the approved board of 10 Oct 2026, where the longest ran 11"),
    ("flow.before.rows", "Rows in the before flow", (4, 6),
     "understand.md, Understand: 'Before ... 4–6 rows'. DEV-884's table said 8 rows and a "
     "floor of 3; understand.md owns the slot. The approved board ran 6"),
    ("flow.after.rows", "Rows in the after flow", (4, 7),
     "understand.md, Understand: 'After ... 4–7 rows'. DEV-884's table said 8 rows and a "
     "floor of 3; understand.md owns the slot. The approved board ran 6"),
    ("problems.count", "Numbered problems", (2, 4),
     "understand.md, Understand: 'Problems ... 2–4, numbered'. DEV-884's table said 5; "
     "understand.md owns the slot. The approved board ran 3"),
    ("top.words", "The top layer in total, headline plus every was-wrong and now line", 150,
     "understand.md, the paragraph 'The whole top layer ... is 150 words'. DEV-884 brought the "
     "number -- the house target for a draft, against which the live session wrote 1,381 -- and "
     "put it in that file, which is where it is changed. The approved board of 10 Oct 2026 ran "
     "85 of the 150"),
    ("top.semicolons", "Semicolons in one top-layer line", 1,
     "understand.md, rule 3: parallel things are a table, and the characteristic failure is "
     "one sentence of three clauses joined by semicolons. Two semicolons are three clauses"),
    ("option.title.words", "An option's title", 12,
     "understand.md, Alternatives: 'Options ... a title of at most 12 words', an inclusive cap "
     "the way the headline is, per Patrick's ruling of 10 Oct 2026. No board measurement for "
     "this slot; Review Desk's real-length brief runs 11 across eight options"),
    ("support.rows", "Rows in the supporting table", (3, 4),
     "understand.md, Understand: 'Supporting table ... 3–4 rows' — the board's three questions, "
     "each with one owner. It was 'How it works today' until DEV-883 split that slot in two, "
     "because the name covered both a paragraph of plain words and this table and they are "
     "different fields. Checked only when the brief holds a table: the contract serves null "
     "when it holds none. The approved board ran 3"),
    ("leak.title.words", "Shortest title checked against the problem half", 3,
     "Not a budget. A title of one or two words — 'Web export' — appears in any honest problem "
     "statement, so checking it would make the leak rule untrustworthy rather than strict"),
)
LIMIT: dict[str, object] = {key: value for key, _, value, _ in LIMITS}

# Humped English. The plain-top-layer rule reads an interior lowercase-to-uppercase hump as a
# class name, which is what `ExportContext` and `ImportRun` are and what these are not.
#
# A name whose hump is all-caps — `DBTransaction`, `SQLWriter` — is NOT caught, and that is a
# stated limit rather than an oversight: the pattern that catches it also catches "IDs".
HUMPED_ENGLISH = {
    "github", "gitlab", "bitbucket", "oauth", "openapi", "openid", "javascript", "typescript",
    "postgresql", "mysql", "sqlite", "graphql", "nodejs", "ios", "ipados", "macos", "iphone",
    "ipad", "youtube", "paypal", "wordpress", "mongodb", "dynamodb", "redis", "kubernetes",
    "webhook", "webhooks", "linkedin", "powershell", "mermaid", "jsonapi", "deverge",
}

# A file path: two or more separators, or a leaf carrying a known extension. One separator alone
# is not enough — "and/or" is a word, and a rule that failed on it would be ignored within a day.
EXTENSIONS = (
    "php|ts|tsx|js|jsx|mjs|cjs|py|rs|go|rb|java|kt|swift|cs|c|h|cpp|hpp|sql|json|ya?ml|toml|"
    "vue|svelte|css|scss|html|md|sh|bash|zsh|tf|ini|env|lock"
)
PATH = re.compile(rf"[\w.@~-]+/[\w.@~-]+/[\w./@~-]*|[\w/.@~-]*[\w-]\.(?:{EXTENSIONS})\b")
CAMEL = re.compile(r"\b[A-Za-z]*[a-z][A-Z][A-Za-z]*\b")
CALL = re.compile(r"\b\w+\(\s*\)")
SCOPE = "::"


def die(msg: str) -> None:
    """Could not run (2). A brief nobody read gets no verdict, the way review_lint.py has it."""
    print(msg, file=sys.stderr)
    sys.exit(2)


def words(text: str) -> int:
    return len((text or "").split())


def sentences(text: str) -> list[str]:
    """Sentences, by terminator followed by a space. '1.5' and 'e.g. x' stay one sentence."""
    return [s for s in re.split(r"(?<=[.!?])\s+", (text or "").strip()) if s.strip()]


def flat(text: str) -> str:
    """Words only, lowercased — what a substring comparison between two human lines may use."""
    return " " + re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip() + " "


def code_names(text: str) -> list[str]:
    """What reads as code on a line that is meant to read as plain English."""
    hits: list[str] = []
    if SCOPE in (text or ""):
        hits.append(SCOPE)
    hits += [h for h in PATH.findall(text or "") if re.search(r"[A-Za-z]", h)]
    hits += CALL.findall(text or "")
    hits += [w for w in CAMEL.findall(text or "") if w.lower() not in HUMPED_ENGLISH]
    seen, out = set(), []
    for h in hits:
        if h not in seen:
            seen.add(h)
            out.append(h)
    return out


def boxes(flow) -> list[tuple[int, int, dict]]:
    """(row, slot, box) for every box of a flow, numbered from one as the page draws them."""
    out = []
    for r, row in enumerate(flow or [], 1):
        for c, box in enumerate(row or [], 1):
            out.append((r, c, box))
    return out


def top_layer(brief: dict) -> list[tuple[str, str]]:
    """(slot, line) for every line the budget and the plain rule apply to, and no others.

    This function IS the definition of "the top layer". Nothing reads detail, arguments, notes
    or summaries for length, so there is one place to look to see what is budgeted."""
    out = [("the headline", brief.get("headline") or "")]
    for p in brief.get("problems") or []:
        n = p.get("number")
        out.append((f'problem {n}\'s "was wrong" line', p.get("was_wrong") or ""))
        out.append((f'problem {n}\'s "now" line', p.get("now_fixed") or ""))
    return [(slot, line) for slot, line in out if line.strip()]


def problem_half(brief: dict) -> str:
    """What `review-desk brief problem-statement` serves, and what a blind pass may be shown.

    Built by naming what belongs in it, never by removing what does not — the same argument
    `ProblemStatement` makes in Review Desk's own contract. A read that subtracts grows a leak
    every time the brief grows a field."""
    bits = [brief.get("problem") or "", brief.get("how_it_works_today") or "",
            brief.get("flow_before_caption") or ""]
    for _, _, box in boxes(brief.get("flow_before")):
        bits += [box.get("title") or "", box.get("note") or ""]
    for p in brief.get("problems") or []:
        bits.append(p.get("was_wrong") or "")
    return flat(" ".join(bits))


class Lint:
    """One line per rule. A failure carries the slot, the limit, the measured value and the fix.

    A pass carries what it measured, which is the same argument `review_lint.py` makes for
    naming the review it read: a PASS that does not say what it looked at carries nothing."""

    def __init__(self) -> None:
        self.results: list[tuple[bool, str, str]] = []

    def check(self, ok, rule: str, fail: str = "", measure: str = "") -> None:
        self.results.append((bool(ok), rule, measure if ok else fail))

    def report(self) -> int:
        width = max(len(r) for _, r, _ in self.results)
        for ok, rule, detail in self.results:
            print(f"{'PASS' if ok else 'FAIL'}  {rule.ljust(width)}  {detail}".rstrip())
        bad = [r for ok, r, _ in self.results if not ok]
        print(f"\n{len(self.results) - len(bad)}/{len(self.results)} checks passed")
        print("FAIL — each failure names the slot, the limit, what it measured and what to do."
              if bad else
              "Mechanics only. A clean run means the brief is readable at a glance, not that it "
              "is right.")
        return 1 if bad else 0


def lint(brief: dict) -> int:
    L = Lint()
    problems = brief.get("problems") or []
    before, after = brief.get("flow_before") or [], brief.get("flow_after") or []

    # ---- a headline exists, is one sentence, and is short enough to read at a glance
    headline = (brief.get("headline") or "").strip()
    L.check(headline, "headline.present",
            "no headline. The Understand page opens with one sentence saying what the change "
            "does and what it buys — write it into `headline`")
    if headline:
        n = len(sentences(headline))
        L.check(n == 1, "headline.one_sentence",
                f"the headline is {n} sentences, and the slot takes 1. Keep the first and move "
                "the rest into `how_it_works_today`, or into the problem it belongs to",
                measure="1 sentence")
        L.check(words(headline) <= LIMIT["headline.words"], "headline.length",
                f"the headline runs {words(headline)} words against {LIMIT['headline.words']}. "
                "Say what the change does and what it buys; the mechanism belongs in the "
                "problems' detail",
                measure=f"{words(headline)} words of {LIMIT['headline.words']}")

    # ---- there is a picture, and each flow holds the rows the page is drawn for
    for name, flow, key in (("before", before, "flow.before.rows"), ("after", after, "flow.after.rows")):
        low, high = LIMIT[key]
        if not flow:
            L.check(False, f"picture.{name}",
                    f"there is no {name} flow. Draw it as rows of one to three boxes in "
                    f"`flow_{name}` — {low} to {high} rows, one step each. A brief with no "
                    "picture is the prose this linter exists to replace")
            continue
        blank = [f"row {r} box {c}" for r, c, box in boxes(flow)
                 if not (box.get("title") or "").strip()]
        if blank:
            L.check(False, f"picture.{name}",
                    f"{len(blank)} box of the {name} flow carries no title ({', '.join(blank[:3])}"
                    "). A box with nothing in it is a flow that is not drawn, whatever the row "
                    "count says. Write the step, in a caption of "
                    f"{LIMIT['box.title.words']} words or fewer")
            continue
        L.check(low <= len(flow) <= high, f"picture.{name}",
                f"the {name} flow holds {len(flow)} rows against {low} to {high}. "
                + (f"Below {low} it is not a flow, it is a sentence in boxes — split the step "
                   "that hides two things" if len(flow) < low else
                   f"Past {high} the page scrolls — merge the steps nothing is wrong with, or "
                   "put the ones that split side by side in one row of two"),
                measure=f"{len(flow)} rows of {low}-{high}, {len(boxes(flow))} boxes")

    # ---- the problems are the spine: numbered, few, and marked on both flows
    low, high = LIMIT["problems.count"]
    L.check(low <= len(problems) <= high, "problems.count",
            f"{len(problems)} numbered problems against {low} to {high}. "
            + (f"Below {low}, a brief with one problem does not need numbers and a brief with "
               "none has nothing for an option or a part to answer" if len(problems) < low else
               f"Past {high} the matrix on the Alternatives page stops being readable — fold the "
               "ones that are one problem seen twice into a single number, with the rest in "
               "its detail"),
            measure=f"{len(problems)} of {low}-{high}")
    for key, flow, name in (("marked_before", before, "before"), ("marked_after", after, "after")):
        marked = {b.get("problem") for _, _, b in boxes(flow) if b.get("problem") is not None}
        missing = [p.get("number") for p in problems if p.get("number") not in marked]
        L.check(not missing, f"problems.{key}",
                f"problem{'s' if len(missing) > 1 else ''} "
                f"{', '.join(str(m) for m in missing)} mark{'' if len(missing) > 1 else 's'} no "
                f"box in the {name} flow. Set `problem` on the {name} box "
                + ("where it goes wrong" if name == "before" else "that fixes it")
                + ", or drop the number — a problem the picture does not show is one the reader "
                  "has to take on trust",
                measure=f"{len(problems)} problem(s), {len(marked)} number(s) marked on the "
                        f"{name} flow")
    no_now = [p.get("number") for p in problems if not (p.get("now_fixed") or "").strip()]
    L.check(not no_now, "problems.now_line",
            f"problem{'s' if len(no_now) > 1 else ''} {', '.join(str(n) for n in no_now)} "
            "carr" + ("y" if len(no_now) > 1 else "ies") + " no `now_fixed`. The slot is two "
            "lines, one each way: write what it is now, or the Understand page draws a problem "
            "with an empty Now column",
            measure=f"{len(problems) - len(no_now)} of {len(problems)} problem(s) carry one")

    # ---- the top layer stays plain, stays parallel, and stays inside the budget
    unplain = [(slot, code_names(line)) for slot, line in top_layer(brief) if code_names(line)]
    L.check(not unplain, "top.plain",
            "; ".join(f"{slot} carries {', '.join(names)}" for slot, names in unplain[:3])
            + ". Move the class names, the paths and the `::` behind the problem's detail — "
              "`detail_before` and `detail_after` are what the fold on the page holds, and they "
              "are never length-checked. The top layer is read by someone who has never opened "
              "the repository",
            measure=f"{len(top_layer(brief))} top-layer line(s), no class name, path or `::`")
    talky = [(slot, line.count(";")) for slot, line in top_layer(brief)
             if line.count(";") > LIMIT["top.semicolons"]]
    L.check(not talky, "top.parallel",
            "; ".join(f"{slot} joins clauses with {n} semicolons" for slot, n in talky[:3])
            + ". Parallel things are a table, not a sentence: a reader cannot see that there "
              "are three, and cannot refer to the second one later. Make them separate "
              "numbered problems, or separate lines of the problem's detail",
            measure=f"{len(top_layer(brief))} top-layer line(s), at most "
                    f"{LIMIT['top.semicolons']} semicolon each")
    total = sum(words(line) for _, line in top_layer(brief))
    # Every line here can be inside its own cap and the total still over: the caps stop one line
    # running away and this stops the top layer doing it collectively. So the failure names the
    # lines to tighten. "Shorten it" over a brief whose every line already passes is not an
    # instruction, it is a shrug — the author cannot tell which line the budget is objecting to.
    worst = sorted(top_layer(brief), key=lambda sl: -words(sl[1]))[:3]
    L.check(total <= LIMIT["top.words"], "top.length",
            f"the top layer runs {total} words against {LIMIT['top.words']} — the headline plus "
            f"{len(problems)} problems' was-wrong and now lines. Every line may be inside its own "
            f"{LIMIT['line.words']}-word cap and the total still over: the caps stop one line "
            "running away, the budget stops the top layer doing it collectively. Tighten the "
            "longest — "
            + "; ".join(f"{slot} ({words(line)} words)" for slot, line in worst)
            + " — and move the mechanism into `detail_before` and `detail_after`, which are behind "
              "a click and never counted; the board this limit was measured from ran 85",
            measure=f"{total} words of {LIMIT['top.words']}")
    lines = [(slot, line) for slot, line in top_layer(brief) if slot != "the headline"]
    long_lines = [(slot, words(line)) for slot, line in lines if words(line) > LIMIT["line.words"]]
    L.check(not long_lines, "line.length",
            "; ".join(f"{slot} runs {n} words" for slot, n in long_lines[:3])
            + f" against {LIMIT['line.words']}. One line each way is the whole slot — the "
              "mechanism, the incident and the evidence go in that problem's detail",
            measure=f"longest of {len(lines)} line(s): "
                    f"{max([words(l) for _, l in lines] or [0])} words of {LIMIT['line.words']}")

    # ---- the boxes are captions, not paragraphs
    for key, field, label in (("box.title.words", "title", "title"),
                              ("box.note.words", "note", "note")):
        over = []
        for name, flow in (("before", before), ("after", after)):
            for r, c, box in boxes(flow):
                if words(box.get(field) or "") > LIMIT[key]:
                    over.append(f"{name} row {r} box {c} {label} runs {words(box.get(field) or '')} words")
        L.check(not over, f"box.{label}s",
                "; ".join(over[:3]) + f" against {LIMIT[key]}. A box is a caption the eye takes "
                "in whole; say the step, and put why it is wrong in the problem's detail",
                measure=f"longest of {len(boxes(before)) + len(boxes(after))} boxes: "
                        f"{max([words(b.get(field) or '') for _, _, b in boxes(before) + boxes(after)] or [0])}"
                        f" words of {LIMIT[key]}")

    # ---- an option's title is a row of a matrix, read beside every other option's
    over_opts = [f"option {o.get('key')} runs {words(o.get('title') or '')} words"
                 for o in brief.get("options") or []
                 if words(o.get("title") or "") > LIMIT["option.title.words"]]
    L.check(not over_opts, "options.titles",
            "; ".join(over_opts[:3]) + f" against {LIMIT['option.title.words']}. A title is read "
            "beside every other option's, across a row of verdicts: name the approach, and leave "
            "the mechanism to `argument_for` and `argument_against`, which are never "
            "length-checked",
            measure=f"longest of {len(brief.get('options') or [])} option(s): "
                    f"{max([words(o.get('title') or '') for o in brief.get('options') or []] or [0])}"
                    f" words of {LIMIT['option.title.words']}")

    # ---- the one small supporting table, when the brief holds one
    #
    # Only when it holds one. The contract serves `support_table` null for a brief with no table
    # and `how_it_works_today` carries the same ground in prose, so a missing table is a brief
    # that answered the question another way — not a fault this can see.
    table = brief.get("support_table")
    low, high = LIMIT["support.rows"]
    rows = (table or {}).get("rows") or []
    L.check(table is None or low <= len(rows) <= high, "support.rows",
            f"the supporting table holds {len(rows)} rows against {low} to {high}. "
            + (f"Below {low} it is not a table, it is a sentence: ask the system another question "
               "it answers, or drop the table and put it in `how_it_works_today`"
               if len(rows) < low else
               f"Past {high} it stops being the one small table beside the flows — keep the "
               "questions whose answer the change moves, and leave the rest"),
            measure=f"{len(rows)} of {low}-{high}" if table is not None else "no supporting table")

    # ---- the problem half is blind-safe
    #
    # It is the one part of a brief that may be handed to an independent pass, and the leak that
    # matters is not a name but the answer: an option's title, or a box that only the after flow
    # draws. Both say what was decided, and a session shown either is no longer independent.
    half = problem_half(brief)
    # The two tests here MUST match the same way. "After-only" by exact equality and "appears in
    # the problem half" by substring is not one rule, it is two that disagree: an after box whose
    # caption is a shortened form of a before box's — the normal way to draw the same step twice —
    # counted as after-only, and then found in the problem half inside the very before title it
    # came from. Both are substring tests now, so a caption the before flow already carries can
    # never be read as the answer.
    before_titles = " ".join(flat(b.get("title") or "") for _, _, b in boxes(before))
    leaks = []
    for _, _, box in boxes(after):
        t = flat(box.get("title") or "")
        if t not in before_titles and words(t) >= LIMIT["leak.title.words"] and t in half:
            leaks.append(f'the after-only box "{(box.get("title") or "").strip()}"')
    for opt in brief.get("options") or []:
        t = flat(opt.get("title") or "")
        if words(t) >= LIMIT["leak.title.words"] and t in half:
            leaks.append(f'option {opt.get("key")}\'s title "{(opt.get("title") or "").strip()}"')
    L.check(not leaks, "problem_half.blind_safe",
            "; ".join(leaks[:3]) + " appears in the problem half. That half is what a blind pass "
            "is shown, and it now states the answer: say what is wrong in the words of the "
            "system as it stands today, and leave the after flow and the options to say what "
            "was decided",
            measure=f"{len(brief.get('options') or [])} option title(s) and "
                    f"{len([1 for _, _, b in boxes(after) if flat(b.get('title') or '') not in before_titles])}"
                    " after-only box title(s) checked")

    return L.report()


STRUCTURE = ("headline", "flow_before", "flow_after", "problems")
BRIEF_KEYS = STRUCTURE + ("problem", "diagram", "options", "review_id")


def structured(brief: dict) -> bool:
    """Whether this brief records any of what the three approved pages draw.

    A brief written the old way — `problem`, `diagram`, `provenance` and options with a
    paragraph each way — serves every new array empty and every new string null, by Review
    Desk's contract. That is one fault, said once — never the four that `lint()` would otherwise
    report (no headline, no before flow, no after flow, no numbered problems), each telling the
    author to fill a slot the document they are holding has never had."""
    return any(brief.get(k) for k in STRUCTURE)


def shaped(brief: dict) -> None:
    """Die (2) on a document the checks cannot run over. A malformed brief is not a bad brief.

    Exit 1 means "this brief has a fault" and exit 2 means "nothing was checked". A traceback
    says the second and exits with the first, which is the one outcome a worker must not be
    handed — and the file-argument mode exists to be pointed at hand-written JSON, where a
    string in place of an object is the commonest mistake there is. So every leaf a check
    reads is typed here, and the message names the field rather than the line of Python.
    """
    def whole(value, where: str) -> None:
        """An integer, and not a bool: `True` is an `int` in Python and is not a problem number."""
        if value is not None and not (isinstance(value, int) and not isinstance(value, bool)):
            die(f"`{where}` is {type(value).__name__}, not a whole number. Nothing was checked.")

    def text(value, where: str) -> None:
        if value is not None and not isinstance(value, str):
            die(f"`{where}` is {type(value).__name__}, not text. Nothing was checked.")

    for key in ("options", "problems", "parts"):
        if brief.get(key) is not None and not isinstance(brief[key], list):
            die(f"`{key}` is {type(brief[key]).__name__}, not a list. This is not a brief "
                f"Review Desk would store; nothing was checked.")
    for key in ("headline", "problem", "how_it_works_today", "flow_before_caption",
                "flow_after_caption"):
        text(brief.get(key), key)

    for key in ("flow_before", "flow_after"):
        flow = brief.get(key)
        if flow is None:
            continue
        if not isinstance(flow, list):
            die(f"`{key}` is not a list of rows of boxes — `[[{{\"title\": \"...\"}}]]`. "
                "Nothing was checked.")
        for r, row in enumerate(flow, 1):
            if not isinstance(row, list):
                die(f"`{key}` row {r} is not a list of boxes. A row holds one to three of them, "
                    "which is what carries the layout. Nothing was checked.")
            for c, box in enumerate(row, 1):
                if not isinstance(box, dict):
                    die(f"`{key}` row {r} box {c} is {type(box).__name__}, not a box with a "
                        "`title`. Nothing was checked.")
                text(box.get("title"), f"{key} row {r} box {c} title")
                text(box.get("note"), f"{key} row {r} box {c} note")
                whole(box.get("problem"), f"{key} row {r} box {c} problem")

    for i, p in enumerate(brief.get("problems") or [], 1):
        if not isinstance(p, dict):
            die(f"`problems[{i}]` is {type(p).__name__}, not an object with a `number` and a "
                "`was_wrong`. Nothing was checked.")
        if p.get("number") is None:
            die(f"`problems[{i}]` carries no `number`. The number is the brief's one internal "
                "identity — a flow box marks it, an option is judged against it and a part "
                "fixes it — so there is nothing to check it against. Nothing was checked.")
        whole(p.get("number"), f"problems[{i}].number")
        text(p.get("was_wrong"), f"problems[{i}].was_wrong")
        text(p.get("now_fixed"), f"problems[{i}].now_fixed")

    table = brief.get("support_table")
    if table is not None:
        if not isinstance(table, dict):
            die(f"`support_table` is {type(table).__name__}, not an object with `columns` and "
                "`rows`. Nothing was checked.")
        for key in ("columns", "rows"):
            if table.get(key) is not None and not isinstance(table[key], list):
                die(f"`support_table.{key}` is {type(table[key]).__name__}, not a list. "
                    "Nothing was checked.")
        text(table.get("title"), "support_table.title")

    for i, o in enumerate(brief.get("options") or [], 1):
        if not isinstance(o, dict):
            die(f"`options[{i}]` is {type(o).__name__}, not an object with a `title`. An option "
                "is a row of the Alternatives matrix. Nothing was checked.")
        text(o.get("title"), f"options[{i}].title")


def read_file(path: str) -> dict:
    """A brief from a document on disk or standard input. Needs no `review-desk` at all."""
    try:
        raw = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as exc:
        die(f"Could not read {path}: {exc}")
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        die(f"{path}: not JSON — {exc}")
    if not isinstance(doc, dict):
        die(f"{path}: the document is a {type(doc).__name__}, not a brief.")
    if isinstance(doc.get("brief"), dict):
        return doc["brief"]          # a whole `review show` or `getReview` document
    if "brief" in doc and doc["brief"] is None:
        die(f"{path}: that review holds no brief. Nothing to lint.")
    if not any(k in doc for k in BRIEF_KEYS):
        die(f"{path}: this does not look like a brief — no `problem`, `headline`, `flow_before` "
            "or `problems`. Nothing was checked.")
    return doc


def read_review(review_id: int) -> dict:
    """The saved brief, through `review-desk`. A missing binary is loud and could-not-run (2).

    Loud, because silence here is indistinguishable from a pass: a worker that ran this in a
    pipeline and saw nothing would report a brief checked by nothing at all. Never 1 — exit 1
    is a verdict on a brief, and no brief was read."""
    missing = (
        "`review-desk` is not on PATH, so the saved brief could not be read and NOTHING was "
        "checked.\n"
        "This is not a pass and not a fault in the brief.\n"
        "Install it, or lint the document instead — with a file argument this linter needs no "
        "`review-desk` at all:\n"
        "    python3 brief_lint.py brief.json"
    )
    if shutil.which("review-desk") is None:
        die(missing)
    cmd = ["review-desk", "review", "show", "--review", str(review_id), "--json"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        die(missing)
    except subprocess.TimeoutExpired:
        die(f"`{' '.join(cmd)}` did not answer in 60 seconds. Nothing was checked.")
    if r.returncode:
        die(f"review-desk review show --review {review_id}: "
            f"{(r.stderr or r.stdout).strip()[:300]}")
    try:
        doc = json.loads(r.stdout)
    except json.JSONDecodeError as exc:
        die(f"`{' '.join(cmd)}` did not print JSON — {exc}")
    brief = doc.get("brief") if isinstance(doc, dict) else None
    if not isinstance(brief, dict):
        die(f"review {review_id} holds no brief. Nothing to lint.")
    return brief


def print_limits() -> None:
    w = max(len(slot) for _, slot, _, _ in LIMITS)
    print("The limits, and where each one comes from. Provisional, measured from one board.\n")
    for _, slot, value, source in LIMITS:
        shown = f"{value[0]}-{value[1]}" if isinstance(value, tuple) else str(value)
        print(f"{slot.ljust(w)}  {shown.rjust(5)}  {source}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?", help="a brief as JSON, or - for standard input")
    ap.add_argument("--review", type=int, metavar="N",
                    help="lint the brief review N already holds, read through `review-desk`")
    ap.add_argument("--limits", action="store_true",
                    help="print the limits table with its provenance, and stop")
    a = ap.parse_args()

    if a.limits:
        print_limits()
        return 0
    if a.path and a.review is not None:
        print("Give a file or --review N, not both: they are two different briefs.",
              file=sys.stderr)
        return 2
    if a.review is not None:
        brief, source = read_review(a.review), f"review {a.review}"
    elif a.path:
        brief, source = read_file(a.path), a.path
    else:
        ap.print_help()
        return 2

    shaped(brief)
    if not structured(brief):
        print(f"not structured: {source} records a problem, a diagram and options, and none of "
              "the twelve things the three approved pages draw.")
        print("A brief is structured when it carries a headline, the two flows as rows of "
              "boxes, and the numbered problems the rest of the review refers to. "
              "`understand.md`, under \"Understand\", has the slots; `review-desk brief put "
              "--help` has the document. Nothing else was checked: there is one fault here, not "
              "the four it would otherwise report about slots this brief has never had.")
        return 1

    problems, before, after = (brief.get("problems") or [], brief.get("flow_before") or [],
                               brief.get("flow_after") or [])
    print(f"brief-craft lint: {source}  ({len(problems)} numbered problem"
          f"{'' if len(problems) == 1 else 's'}, {len(before)} before rows, {len(after)} after "
          f"rows, {sum(words(l) for _, l in top_layer(brief))} top-layer words of "
          f"{LIMIT['top.words']})\n")
    try:
        return lint(brief)
    except Exception as exc:                                   # noqa: BLE001 - see below
        # A shape `shaped()` did not anticipate. Python exits 1 on an uncaught exception, and 1
        # is this linter's verdict that the brief has a fault — so a crash would report a fault
        # in a brief nothing read. It is named rather than swallowed: an exception here is a bug
        # in a check, and the type and message are what gets it fixed.
        die(f"{type(exc).__name__} while checking {source}: {exc}. That is a defect in a check, "
            "not a finding about the brief — nothing was checked.")


if __name__ == "__main__":
    raise SystemExit(main())
