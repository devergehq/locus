#!/bin/sh
# Unit tests for skills/review-craft/pr_lint.py.
#
# Every case here is a LOCAL draft. That is deliberate: the two checks that need
# GitHub (the real diff size, and whether the working-notes comment exists) are
# the ones a test cannot fake without either a network call or a mock of `gh`
# elaborate enough to be its own bug surface. What is tested is the arithmetic,
# the pattern matching and the exit contract — the parts that decide whether a
# description passes.
#
# The one GitHub-side behaviour that IS covered is the draft's own degradation:
# a draft that links to working notes must warn rather than pass silently,
# because a linter that reports PASS about a check it did not run is worse than
# one that reports nothing.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lint="$root/skills/review-craft/pr_lint.py"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-54s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-54s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

# run <changed-lines> <file>  -> exit code
run () { set +e; python3 "$lint" "$2" --changed-lines "$1" >"$work/out" 2>"$work/err"; c=$?; set -e; echo "$c"; }
# says <text> -> yes/no: is this text anywhere in the last run's output?
says () { grep -q -- "$1" "$work/out" && echo yes || echo no; }
# rule <name> -> yes/no: did the last run RAISE this finding?
#
# `says budget` is not the same question: the header line prints the budget on
# every run, pass or fail, so grepping for the word reports a finding that was
# never raised. The header is the thing this linter exists to make visible, so
# it is not going anywhere - the test has to be the precise one.
rule () { grep -qE "^  (ERROR|WARN ) $1( |\$)" "$work/out" && echo yes || echo no; }

# A description that carries the five things and stops.
cat > "$work/good.md" <<'EOF'
## Why

`ClinicalContributionExemption` compared the exemption against a hard-coded category
name that has not existed since the 2026-03 rename, so every exempt participant was
billed the standard rate.

## What changed

The comparison now resolves the category through `CategoryRepository` rather than a
literal. One line of application code; the rest is the test that fails without it.

## What to look at

Whether `CategoryRepository::byCode` is the right lookup, or whether the exemption
should hold a category id instead of a code.

## Risks

Participants already billed at the wrong rate are not corrected by this change.
A backfill is DAR-561.

## References

DAR-543. Working notes: the comment titled Working notes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF

# The measured worst case: tc-portal #9309, 50 changed lines, 17,638 characters.
{
  printf '## Why\n\n'
  i=0
  while [ "$i" -lt 240 ]; do
    printf 'The census counted every write site in the billing module and recorded the query output below, row by row, with the participant id and the category code.\n'
    i=$((i + 1))
  done
} > "$work/huge.md"

echo "Budget arithmetic"
ok "a small diff with a short body passes"      "$(run 50 "$work/good.md")" 0
ok "50 changed lines budget 800 not 600"        "$(run 50 "$work/good.md" >/dev/null; grep -o 'budget 800' "$work/out")" "budget 800"
ok "300 changed lines budget 3,600"             "$(run 300 "$work/good.md" >/dev/null; grep -o 'budget 3,600' "$work/out")" "budget 3,600"
ok "25,594 changed lines caps at 4,000"         "$(run 25594 "$work/good.md" >/dev/null; grep -o 'budget 4,000' "$work/out")" "budget 4,000"
ok "17k body on a 50-line diff fails"           "$(run 50 "$work/huge.md")" 1
ok "and names the budget rule"                  "$(rule 'budget')" yes
ok "and tells the author where it goes"         "$(says 'Working notes')" yes
ok "the same body on a huge diff still fails"   "$(run 25594 "$work/huge.md")" 1
ok "1.1x over is a warning, not an error"       "$(python3 -c "
import sys; sys.argv=['x']
open('$work/slightly.md','w').write('## Why\n\n' + 'word ' * 176)
")$(run 50 "$work/slightly.md")" 0

echo "Headings"
printf '## Why\n\n%s\n' "$(python3 -c "print('sentence about the change. ' * 70)")" > "$work/headed.md"
python3 -c "print('sentence about the change. ' * 70)" > "$work/flat.md"
ok "long body with headings is quiet"    "$(run 3000 "$work/headed.md" >/dev/null; rule 'headings')" no
ok "long body with none warns"           "$(run 3000 "$work/flat.md" >/dev/null; rule 'headings')" yes
ok "and a warning alone still exits 0"   "$(run 3000 "$work/flat.md")" 0

echo "Template placeholders"
for debris in '<!-- describe the change -->' '*(what changed)*' 'TBD' '<insert ticket>' 'Lorem ipsum' 'XXX'; do
  { cat "$work/good.md"; printf '\n%s\n' "$debris"; } > "$work/debris.md"
  ok "unfilled: $debris" "$(run 50 "$work/debris.md")" 1
done
ok "a filled description has none"       "$(run 50 "$work/good.md" >/dev/null; rule 'placeholder')" no

echo "Rotting date words"
{ cat "$work/good.md"; printf '\nThis is currently the only caller.\n'; } > "$work/rot.md"
ok "'currently' warns"                   "$(run 50 "$work/rot.md" >/dev/null; rule 'rotting-date')" yes
ok "but does not fail the build"         "$(run 50 "$work/rot.md")" 0
{ cat "$work/good.md"; printf '\n```\n# currently\n```\n'; } > "$work/rotfence.md"
ok "inside a code fence it is ignored"   "$(run 50 "$work/rotfence.md" >/dev/null; rule 'rotting-date')" no
{ cat "$work/good.md"; printf '\nAs of 2026-09-18 this is the only caller.\n'; } > "$work/dated.md"
ok "a real date is not a rotting word"   "$(run 50 "$work/dated.md" >/dev/null; rule 'rotting-date')" no

echo "The unit is raw characters, not a stripped 'visible' count"
# The constants were measured from raw stored bodies. A stripped count made the
# effective budget about a quarter looser than anything measured, and cost one
# author the ambiguity this test pins shut: 958 raw vs 797 "visible".
# 780 characters of prose - under the 800 floor - plus a link whose target is 120
# characters. Stripped of its target the body fits; as stored it does not, and as
# stored is what the squash copies.
printf '## Why\n\n[%s](https://example.test/%s)\n' \
  "$(python3 -c "print('x' * 770)")" "$(python3 -c "print('q' * 110)")" > "$work/linky.md"
ok "prose alone would fit the floor"     "$(python3 -c "print(len('x'*770) + len('## Why') + 4)")" 780
ok "but the link target takes it over"   "$(run 1 "$work/linky.md" >/dev/null; rule 'budget')" yes
ok "the attribution footer does not"     "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import pr_lint
b='## Why\n\nbody text here.\n\n\u0001\u0001'.replace('\u0001\u0001','') + '\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
print(len(pr_lint.budgeted(b)))
")" "$(python3 -c "
import sys; sys.path.insert(0,'$root/skills/review-craft'); import pr_lint
print(len(pr_lint.budgeted('## Why\n\nbody text here.')))
")"

echo "Folds render, and the squash copies the tags, so they count"
{
  cat "$work/good.md"
  printf '\n<details><summary>Changed files</summary>\n\n'
  python3 -c "print('app/Billing/SomeLongFileName.php\n' * 120)"
  printf '</details>\n'
} > "$work/folded.md"
ok "a big fold in the body warns"        "$(run 50 "$work/folded.md" >/dev/null; rule 'fold-in-body')" yes
# The opposite of a review body and of a Linear ticket: a fold here is copied into
# the commit message in full, tags and all, so it is charged in full.
ok "folded text IS on the budget"        "$(run 50 "$work/folded.md" >/dev/null; rule 'budget')" yes

echo "Working notes are found by heading, never by position"
ok "a draft linking to them warns"       "$(run 50 "$work/good.md" >/dev/null; rule 'working-notes')" yes
grep -v 'Working notes' "$work/good.md" > "$work/nolink.md"
ok "one that does not is quiet"          "$(run 50 "$work/nolink.md" >/dev/null; rule 'working-notes')" no
# On tc-portal #9309 the working-notes comment is the SEVENTH, three days after the
# other six: the working moves out of the body late. A positional check would have
# failed the one PR written to this convention.
wn () { python3 -c "
import sys, json; sys.path.insert(0,'$root/skills/review-craft'); import pr_lint
body='## Related\nWorking notes: [link](x)'
print(','.join(f.rule for f in pr_lint.check_working_notes(body, json.loads(sys.argv[1]))) or 'none')
" "$1"; }
ok "heading on the newest of seven passes" \
   "$(wn '[{"body":"<!-- linear-linkback -->"},{"body":"a review"},{"body":"another"},{"body":"## Working notes (moved 18 Sep)\n\nthe census"}]')" none
ok "no such comment is an error"          "$(wn '[{"body":"<!-- linear-linkback -->"},{"body":"a review"}]')" working-notes
ok "a comment that merely mentions them does not count" \
   "$(wn '[{"body":"Description moved; the working notes are in a comment now."}]')" working-notes
ok "the heading must be on the first line" \
   "$(wn '[{"body":"Some preamble.\n\n## Working notes\n\nthe census"}]')" working-notes

echo "Exit contract: 0 pass, 1 errors, 2 could not run"
ok "no arguments exits 2"                "$(set +e; python3 "$lint" >/dev/null 2>&1; echo $?)" 2
ok "a draft with no --changed-lines is 2" "$(set +e; python3 "$lint" "$work/good.md" >/dev/null 2>&1; echo $?)" 2
ok "--pr without --repo is 2"            "$(set +e; python3 "$lint" --pr 1 >/dev/null 2>&1; echo $?)" 2
ok "a missing file is 2"                 "$(set +e; python3 "$lint" "$work/absent.md" --changed-lines 1 >/dev/null 2>&1; echo $?)" 2
: > "$work/empty.md"
ok "an empty description is an error"    "$(run 50 "$work/empty.md")" 1
ok "an unclosed code fence is an error"  "$(printf '## Why\n\n```\nnot closed\n' > "$work/fence.md"; run 50 "$work/fence.md")" 1

echo "The house style's own numbers"
ok "floor is 800"     "$(python3 -c "import sys;sys.path.insert(0,'$root/skills/review-craft');import pr_lint;print(pr_lint.budget_for(1))")" 800
ok "slope is 12"      "$(python3 -c "import sys;sys.path.insert(0,'$root/skills/review-craft');import pr_lint;print(pr_lint.budget_for(200))")" 2400
ok "ceiling is 4000"  "$(python3 -c "import sys;sys.path.insert(0,'$root/skills/review-craft');import pr_lint;print(pr_lint.budget_for(99999))")" 4000

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
