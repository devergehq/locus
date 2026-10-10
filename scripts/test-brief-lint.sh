#!/bin/sh
# Unit tests for skills/review-craft/brief_lint.py.
#
# Every rule gets a case that fails it and a case that passes it. The cases are one
# base brief — invented, written to pass every check — mutated one field at a time,
# so a failure names the field that caused it rather than leaving you to diff two
# documents.
#
# Two things are deliberately NOT touched:
#
#   * `~/.review-desk`. No test runs the real binary. `--review N` is answered by a
#     fake `review-desk` on PATH that prints a fixture, the way test-review-lint.sh
#     fakes `gh`, so the suite passes whether or not the real one is installed and
#     never reads or writes a developer's own store.
#   * `~/.locus/data/dispatcher`. Nothing here goes near the dispatcher at all.
#
# The missing-binary case runs python3 by absolute path with PATH pointing nowhere,
# which is the only way to prove the loud exit 2 on a machine where the real
# `review-desk` IS installed — and this is one of those machines.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lint="$root/skills/review-craft/brief_lint.py"
py=$(command -v python3)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/nowhere"

cat > "$work/bin/review-desk" <<'EOF'
#!/bin/sh
# Answers `review show --review N --json` from $FIX. Anything else is a mistake in the test.
if [ -n "${FAKE_FAIL:-}" ]; then echo "no review 99" >&2; exit 1; fi
case "$*" in
  *"review show"*) cat "$FIX" ;;
  *) echo "fake review-desk: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/review-desk"

pass=0
fail=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-56s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-56s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

# ---- the base brief: invented, and written to pass every check
cat > "$work/base.json" <<'EOF'
{
  "review_id": 7,
  "problem": "Reset links never expire, so a link that has sat in a mailbox for a month still replaces the password. Two support tickets have come from it.",
  "how_it_works_today": "A reset link carries a token the site trusts until somebody uses it.",
  "headline": "Password resets now expire after an hour, so an old link in a mailbox no longer works.",
  "flow_before_caption": "A token the site trusts until it is used",
  "flow_after_caption": "A token with an hour stamped on it",
  "flow_before": [
    [{"title": "Someone asks for a reset", "note": "The form takes an address and nothing else", "problem": null}],
    [{"title": "A link is mailed out", "note": "The token is written down with no expiry", "problem": 1}],
    [{"title": "The link is opened", "note": "Any token the table still holds is accepted", "problem": 1}],
    [{"title": "The password is replaced", "note": "Older links for the account stay usable", "problem": 2}]
  ],
  "flow_after": [
    [{"title": "Someone asks for a reset", "note": "The form takes an address and nothing else", "problem": null}],
    [{"title": "A link is mailed out", "note": "The token is stamped with the hour it dies", "problem": 1}],
    [{"title": "The link is opened", "note": "A token past its hour is refused", "problem": 1}],
    [{"title": "The password is replaced", "note": "The reset is recorded against the account", "problem": null}],
    [{"title": "Every other link is dropped", "note": "Nothing else for that account still opens", "problem": 2}]
  ],
  "problems": [
    {
      "number": 1,
      "was_wrong": "A reset link worked for as long as the mailbox held it.",
      "now_fixed": "A link is refused an hour after it was sent.",
      "detail_title": "The token with no expiry",
      "detail_before": ["PasswordResetToken was written with no expiry column at all, so TokenRepository::find() returned whatever the table still held, and the controller at app/Http/Controllers/ResetController.php trusted it without once asking how old it was, which is the whole of the mechanism and is deliberately far longer than any limit this linter applies to the top layer, because detail behind a click is never length-checked."],
      "detail_after": ["The column is written on issue and read on use."]
    },
    {
      "number": 2,
      "was_wrong": "Replacing a password left every earlier link still usable.",
      "now_fixed": "A reset drops every other link for that account.",
      "detail_title": "The links nobody cleared",
      "detail_before": ["Nothing deleted the rest of the rows."],
      "detail_after": ["The reset clears them in the same statement."]
    }
  ],
  "options": [
    {"key": "A", "title": "Stamp each token with an hour and refuse the rest", "argument_for": "Small.", "argument_against": "Leaves the other links.", "chosen": false, "proposed_by": "ticket", "verdicts": []},
    {"key": "B", "title": "Expire the token and clear the account's other links", "argument_for": "Answers both.", "argument_against": "Two statements.", "chosen": true, "proposed_by": "both", "verdicts": []}
  ],
  "blind_pass_state": "not_run",
  "parts": [],
  "open_choices": [],
  "disagreements": [],
  "confirmed": false,
  "confirmation_required": true,
  "updated_at": "2026-10-10T09:00:00Z"
}
EOF

# mut <python statements over `b`> : write $work/case.json
mut () { python3 -c '
import json, sys
b = json.load(open(sys.argv[1]))
exec(sys.argv[2])
json.dump(b, open(sys.argv[3], "w"))
' "$work/base.json" "$1" "$work/case.json"; }

# run <args...> -> exit code; stdout in $work/out, stderr in $work/err
run () { set +e; python3 "$lint" "$@" >"$work/out" 2>"$work/err"; c=$?; set -e; echo "$c"; }
case_run () { run "$work/case.json"; }
says () { grep -q -- "$1" "$work/out" && echo yes || echo no; }
shouts () { grep -q -- "$1" "$work/err" && echo yes || echo no; }
# rule <name> -> yes/no: did the last run FAIL this rule?
rule () { grep -qE "^FAIL  $1( |\$)" "$work/out" && echo yes || echo no; }
ran () { grep -qE "^(PASS|FAIL)  $1( |\$)" "$work/out" && echo yes || echo no; }

echo "The base brief"
ok "a brief written to the slots passes"          "$(run "$work/base.json")" 0
ok "and no rule is reported as failing"           "$(grep -c '^FAIL' "$work/out" || true)" 0
ok "16 checks ran"                                "$(grep -c '^PASS' "$work/out" || true)" 16
ok "the header counts the problems and the rows"  "$(says '2 numbered problems, 4 before rows, 5 after rows')" yes
ok "and names the top-layer budget it measured"   "$(says 'top-layer words of 150')" yes
ok "stdin is the same document"                   "$(set +e; python3 "$lint" - <"$work/base.json" >"$work/out" 2>&1; echo $?; set -e)" 0
ok "a whole review document is unwrapped"         "$(python3 -c '
import json; json.dump({"review": {"id": 7}, "brief": json.load(open("'"$work/base.json"'"))}, open("'"$work/case.json"'", "w"))'; case_run)" 0

echo "A headline exists"
ok "a brief with no headline fails"               "$(mut 'b.pop("headline")'; case_run)" 1
ok "naming the slot to write it into"             "$(says 'write it into `headline`')" yes
ok "two sentences fail"                           "$(mut 'b["headline"]="The link expires. An hour after it was sent."'; case_run)" 1
ok "as the one-sentence rule"                     "$(rule headline.one_sentence)" yes
ok "one sentence with a decimal point is one"     "$(mut 'b["headline"]="A reset link now lives 1.5 hours instead of forever, so an old mailbox link fails."'; case_run)" 0

echo "The headline's length"
ok "20 words fails against the limit of 19"       "$(mut 'b["headline"]=" ".join(["word"]*19)+" twenty."'; case_run)" 1
ok "and the failure names both numbers"           "$(says 'runs 20 words against 19')" yes
ok "19 words passes"                              "$(mut 'b["headline"]=" ".join(["word"]*18)+" nineteen."'; case_run)" 0

echo "There is a picture"
ok "no before flow fails"                         "$(mut 'b["flow_before"]=[]'; case_run)" 1
ok "and says to draw it"                          "$(says 'there is no before flow')" yes
ok "three before rows fail the floor of four"     "$(mut 'b["flow_before"]=b["flow_before"][:3]'; case_run)" 1
ok "naming the range"                             "$(says 'holds 3 rows against 4 to 6')" yes
ok "seven before rows fail the ceiling of six"    "$(mut 'b["flow_before"]=b["flow_before"]+[[{"title":"A step","note":"A note","problem":None}]]*3'; case_run)" 1
ok "no after flow fails"                          "$(mut 'b["flow_after"]=[]'; case_run)" 1
ok "eight after rows fail the ceiling of seven"   "$(mut 'b["flow_after"]=b["flow_after"]+[[{"title":"A step","note":"A note","problem":None}]]*3'; case_run)" 1
ok "as the after flow, not the before one"        "$(rule picture.after)" yes
ok "a row of three boxes is one row"              "$(mut 'b["flow_before"][0]=[{"title":"One","note":"A note","problem":None},{"title":"Two","note":"A note","problem":None},{"title":"Three","note":"A note","problem":None}]'; case_run)" 0

echo "Problems are tied to the picture"
ok "a problem marking no before box fails"        "$(mut '
for row in b["flow_before"]:
    for box in row: box["problem"] = None'; case_run)" 1
ok "naming the problems and the flow"             "$(says 'problems 1, 2 mark no box in the before flow')" yes
ok "and telling you which field to set"           "$(says 'Set `problem` on the before box')" yes
ok "a problem marking no after box fails"         "$(mut '
for row in b["flow_after"]:
    for box in row: box["problem"] = None'; case_run)" 1
ok "as the after flow"                            "$(rule problems.marked_after)" yes
ok "one unmarked problem of two is named alone"   "$(mut '
for row in b["flow_before"]:
    for box in row:
        if box.get("problem") == 2: box["problem"] = None'; case_run)" 1
ok "in the singular"                              "$(says 'problem 2 marks no box')" yes

echo "The count of problems"
ok "one problem fails the floor of two"           "$(mut 'b["problems"]=b["problems"][:1]'; case_run)" 1
ok "five fail the ceiling of four"                "$(mut '
import copy
b["problems"] = [dict(p, number=n) for n, p in enumerate(b["problems"] * 3, 1)][:5]
b["flow_before"][1][0]["problem"] = 3
b["flow_before"][2][0]["problem"] = 4
b["flow_before"][3][0]["problem"] = 5
b["flow_after"][1][0]["problem"] = 3
b["flow_after"][2][0]["problem"] = 4
b["flow_after"][4][0]["problem"] = 5'; case_run)" 1
ok "naming the range"                             "$(says '5 numbered problems against 2 to 4')" yes
ok "four problems pass"                           "$(mut '
b["problems"] = [dict(p, number=n) for n, p in enumerate(b["problems"] * 2, 1)][:4]
b["flow_before"][2][0]["problem"] = 3
b["flow_before"][0][0]["problem"] = 4
b["flow_after"][2][0]["problem"] = 3
b["flow_after"][3][0]["problem"] = 4'; case_run)" 0

echo "Every problem carries its now line"
ok "a null now line fails"                        "$(mut 'b["problems"][1]["now_fixed"]=None'; case_run)" 1
ok "naming the problem and the field"             "$(says 'problem 2 carries no `now_fixed`')" yes

echo "The top layer stays plain"
ok "a class name in a was-wrong line fails"       "$(mut 'b["problems"][0]["was_wrong"]="ImportRun wrapped the folder in one transaction."'; case_run)" 1
ok "naming the slot and the name"                 "$(says 'carries ImportRun')" yes
ok "and saying where the names go"                "$(says 'Move the class names')" yes
ok "a :: in a now line fails"                     "$(mut 'b["problems"][0]["now_fixed"]="Each file gets its own DB::transaction now."'; case_run)" 1
ok "a file path in the headline fails"            "$(mut 'b["headline"]="The reset now expires, handled in app/Http/Controllers/ResetController.php."'; case_run)" 1
ok "a call in a now line fails"                   "$(mut 'b["problems"][1]["now_fixed"]="The reset calls clearOthers() for the account."'; case_run)" 1
ok "humped English is not a class name"           "$(mut 'b["problems"][0]["was_wrong"]="The GitHub and OAuth sign-ins both trusted an old link."'; case_run)" 0
ok "a date is not a file path"                     "$(mut 'b["problems"][0]["was_wrong"]="A link mailed on 10/10/2026 still worked a month later."'; case_run)" 0
ok "and a slash in and/or is not a path"          "$(mut 'b["problems"][0]["was_wrong"]="A link was accepted whether it was fresh and/or stale."'; case_run)" 0
ok "a class name in the detail is allowed"        "$(run "$work/base.json")" 0
ok "and the detail may be any length"             "$(mut 'b["problems"][0]["detail_before"] += [" ".join(["word"]*400)]'; case_run)" 0
ok "as may an option argument, or a part"         "$(mut '
b["options"][0]["argument_for"] = " ".join(["word"]*300)
b["parts"] = [{"title": "A part", "summary": " ".join(["word"]*300), "fixes": [1],
               "files": [{"path": "app/Thing.php", "lines_added": 9000, "lines_removed": 9000,
                          "in_diff": True}], "lines_added": 9000, "lines_removed": 9000}]'; case_run)" 0

echo "Parallel things are not a sentence"
ok "two semicolons in a top-layer line fail"      "$(mut 'b["problems"][0]["was_wrong"]="A link never died; a reset kept the others; nothing was logged."'; case_run)" 1
ok "naming the count and the fix"                 "$(says 'joins clauses with 2 semicolons')" yes
ok "one semicolon passes"                         "$(mut 'b["problems"][0]["was_wrong"]="A link never died; nothing cleared it."'; case_run)" 0
ok "and a semicolon in the detail passes"         "$(mut 'b["problems"][0]["detail_before"]=["One; two; three; four; five."]'; case_run)" 0

echo "Lengths"
ok "a 21-word was-wrong line fails"               "$(mut 'b["problems"][0]["was_wrong"]=" ".join(["word"]*20)+" twentyone."'; case_run)" 1
ok "naming the slot, the count and the limit"     "$(says 'problem 1'"'"'s "was wrong" line runs 21 words')" yes
ok "20 words passes"                              "$(mut 'b["problems"][0]["was_wrong"]=" ".join(["word"]*19)+" twenty."'; case_run)" 0
ok "the top layer over 150 words in total fails"  "$(mut '
b["problems"] = [dict(p, number=n, was_wrong=" ".join(["word"]*19)+" twenty.",
                      now_fixed=" ".join(["word"]*19)+" twenty.")
                 for n, p in enumerate(b["problems"] * 2, 1)][:4]
b["flow_before"][2][0]["problem"] = 3
b["flow_before"][0][0]["problem"] = 4
b["flow_after"][2][0]["problem"] = 3
b["flow_after"][3][0]["problem"] = 4'; case_run)" 1
ok "on the total, not on any one line"            "$(rule top.length)$(rule line.length)" yesno
ok "and the failure names the total"              "$(says 'top layer runs 177 words against 150')" yes
ok "a 13-word box title fails"                    "$(mut 'b["flow_before"][0][0]["title"]=" ".join(["word"]*13)'; case_run)" 1
ok "naming the row, the box and the count"        "$(says 'before row 1 box 1 title runs 13 words')" yes
ok "12 words passes"                              "$(mut 'b["flow_before"][0][0]["title"]=" ".join(["word"]*12)'; case_run)" 0
ok "a 15-word box note fails"                     "$(mut 'b["flow_after"][0][0]["note"]=" ".join(["word"]*15)'; case_run)" 1
ok "naming the after flow"                        "$(says 'after row 1 box 1 note runs 15 words')" yes
ok "14 words passes"                              "$(mut 'b["flow_after"][0][0]["note"]=" ".join(["word"]*14)'; case_run)" 0

echo "The problem half is blind-safe"
ok "an option title in the problem half fails"    "$(mut 'b["problem"]="Links never expire. The ticket asks us to expire the token and clear the account'"'"'s other links."'; case_run)" 1
ok "naming the option and its key"                "$(says "option B's title")" yes
ok "an after-only box title in it fails"          "$(mut 'b["how_it_works_today"]="A token is trusted until used, and every other link is dropped by nothing at all."'; case_run)" 1
ok "naming it as after-only"                      "$(says 'the after-only box')" yes
ok "a before box title in it is not a leak"       "$(mut 'b["problem"]="Someone asks for a reset and the link is opened a month later."'; case_run)" 0
ok "a two-word after-only title is not checked"   "$(mut '
b["flow_after"][4][0]["title"] = "One statement"
b["problem"] = "Links never expire, and clearing them would be one statement nobody wrote."'; case_run)" 0
ok "a title is not matched inside a longer word"   "$(mut '
b["flow_after"][4][0]["title"] = "Other link dropping"
b["problem"] = "Nothing expires a link, and other link droppings are left behind by every reset."'; case_run)" 0
ok "a was-wrong line leaking an option fails"     "$(mut 'b["problems"][0]["was_wrong"]="Nothing would expire the token and clear the account'"'"'s other links."'; case_run)" 1
ok "a now line is not the problem half"           "$(mut 'b["problems"][0]["now_fixed"]="A reset expires the token and clears the account'"'"'s other links."'; case_run)" 0

echo "A brief written the old way"
cat > "$work/old.json" <<'EOF'
{
  "review_id": 3,
  "problem": "Webhook deliveries are tried once and lost. The ticket asks for retries over 24 hours.",
  "diagram": "flowchart LR\n  A[Event] --> B[Delivery fails]",
  "options": [{"key": "A", "title": "Retry inside the request", "argument_for": "Small.", "argument_against": "Cannot span a day.", "chosen": false, "proposed_by": "ticket", "verdicts": []}],
  "approach_verdict": "B is the right shape.",
  "provenance": "from the ticket and the code",
  "headline": null,
  "how_it_works_today": null,
  "flow_before": [],
  "flow_after": [],
  "problems": [],
  "blind_pass_state": "not_run",
  "parts": [],
  "open_choices": [],
  "disagreements": [],
  "confirmed": false,
  "confirmation_required": true,
  "updated_at": "2026-10-01T09:00:00Z"
}
EOF
ok "it exits 1, not 2"                            "$(run "$work/old.json")" 1
ok "and says it is not structured"                "$(says 'not structured')" yes
ok "once, not once per rule"                      "$(grep -c 'not structured' "$work/out" || true)" 1
ok "with no rule lines at all"                    "$(grep -c '^\(PASS\|FAIL\)' "$work/out" || true)" 0
ok "pointing at the file that has the slots"      "$(says 'understand.md')" yes
ok "a half-written brief is linted, not excused"  "$(mut 'b["flow_after"]=[]; b["problems"]=[]'; case_run)" 1
ok "and that one does report its rules"           "$(ran picture.before)" yes

echo "--review N, through review-desk"
python3 -c '
import json; json.dump({"review": {"id": 7}, "brief": json.load(open("'"$work/base.json"'"))},
                       open("'"$work/show.json"'", "w"))'
ok "the saved brief is read and passes"           "$(FIX="$work/show.json" PATH="$work/bin:$PATH" run --review 7)" 0
ok "and the header names the review"              "$(says 'brief-craft lint: review 7')" yes
ok "a review holding no brief is 2, not 1"        "$(echo '{"review":{"id":9},"brief":null}' > "$work/none.json"; FIX="$work/none.json" PATH="$work/bin:$PATH" run --review 9)" 2
ok "review-desk failing is 2, not 1"              "$(FAKE_FAIL=1 FIX="$work/show.json" PATH="$work/bin:$PATH" run --review 99)" 2
ok "and its own words are passed on"              "$(shouts 'no review 99')" yes

echo "review-desk missing from PATH"
set +e
PATH="$work/nowhere" "$py" "$lint" --review 7 >"$work/out" 2>"$work/err"; c=$?
set -e
ok "it exits 2, never 1"                          "$c" 2
ok "loudly: it says nothing was checked"          "$(shouts 'NOTHING was checked')" yes
ok "it says this is not a pass"                   "$(shouts 'not a pass')" yes
ok "and it names the way that needs no binary"    "$(shouts 'brief_lint.py brief.json')" yes
set +e
PATH="$work/nowhere" "$py" "$lint" "$work/base.json" >"$work/out" 2>"$work/err"; c=$?
set -e
ok "a file argument needs no review-desk at all"  "$c" 0

echo "Could not run (2) is not a verdict (1)"
ok "no argument at all prints help and exits 2"   "$(run)" 2
ok "a file that is not there is 2"                "$(run "$work/missing.json")" 2
ok "a file that is not JSON is 2"                 "$(printf 'not json' > "$work/case.json"; case_run)" 2
ok "a JSON array is 2"                            "$(printf '[]' > "$work/case.json"; case_run)" 2
ok "a document that is not a brief is 2"          "$(printf '{"hello": 1}' > "$work/case.json"; case_run)" 2
ok "a malformed flow is 2, not a bad brief"       "$(mut 'b["flow_before"]="four rows of boxes"'; case_run)" 2
ok "and names the field that is malformed"        "$(shouts 'flow_before')" yes
ok "problems as an object is 2"                   "$(mut 'b["problems"]={"1": "was wrong"}'; case_run)" 2
ok "a file and --review together is 2"            "$(FIX="$work/show.json" PATH="$work/bin:$PATH" run "$work/base.json" --review 7)" 2

echo "The limits table"
ok "--limits prints it and exits 0"               "$(run --limits)" 0
ok "every limit names where it came from"         "$(grep -c 'understand.md\|DEV-884\|Not a budget' "$work/out" || true)" 10
ok "and no limit is keyed on the diff"            "$(grep -ci 'changed line\|diff size\|lines added' "$work/out" || true)" 0

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
