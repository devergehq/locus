#!/bin/sh
# Unit tests for .github/actions/pr-lint/lint.sh -- the body of the pr-lint composite action.
#
# What is tested is the part of the action that decides whether a pull request passes: the
# mapping from the linter's exit code to the step's, and the argv the action builds from its
# inputs. Both are the places this check can report a WRONG ANSWER rather than fail:
#
#   * an exit code swallowed (piping into tee, or -e collapsing 1 and 2) reports green for a
#     run that never reached a verdict;
#   * an input silently dropped reports green for a check that ran with the wrong rules.
#
# The real linter is never called. Each case points PR_LINT_SCRIPT at a stub that prints its
# argv and exits with a chosen code, which is the only way to exercise exit 2 and the
# no-output case without a broken network. skills/review-craft/pr_lint.py has its own suite in
# scripts/test-pr-lint.sh; this file asserts nothing about what it checks.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sut="$root/.github/actions/pr-lint/lint.sh"

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

# stub <exit code> <stdout text> <stderr text>  -> a fake pr_lint.py
#
# The texts go to files and the code to the environment rather than into the Python
# source. Interpolating them into the heredoc made the stub itself a syntax error, which
# every case then "passed" through -- a stub that cannot run is the same failure the thing
# under test exists to catch.
stub () {
  printf '%s' "$2" > "$work/stub.out"
  printf '%s' "$3" > "$work/stub.err"
  STUB_CODE="$1"
  cat > "$work/stub.py" <<'STUB'
import os, sys

print("argv:", " ".join(sys.argv[1:]))
d = os.environ["STUB_DIR"]
out = open(os.path.join(d, "stub.out")).read()
err = open(os.path.join(d, "stub.err")).read()
if out.strip():
    print(out)
if err.strip():
    print(err, file=sys.stderr)
raise SystemExit(int(os.environ["STUB_CODE"]))
STUB
}

# run  -> exit code of lint.sh, with stdout in $work/out and the summary in $work/summary
run () {
  : > "$work/summary"
  set +e
  env \
    GITHUB_ACTION_PATH="$root/.github/actions/pr-lint" \
    GITHUB_STEP_SUMMARY="$work/summary" \
    PR_LINT_SCRIPT="$work/stub.py" \
    STUB_DIR="$work" \
    STUB_CODE="${STUB_CODE-0}" \
    PR_LINT_REPO="${REPO-owner/repo}" \
    PR_LINT_PR="${PRNUM-7}" \
    PR_LINT_TEMPLATE="${TMPL-}" \
    PR_LINT_EXEMPT="${EXEMPT-}" \
    GH_TOKEN="${TOKEN-stub-token}" \
    bash "$sut" >"$work/out" 2>"$work/err"
  c=$?
  set -e
  echo "$c"
}

says ()    { grep -q -- "$1" "$work/out" && echo yes || echo no; }
summary () { grep -q -- "$1" "$work/summary" && echo yes || echo no; }

printf '\n== exit code mapping (the check must never be green without a verdict)\n'

stub 0 "  PASS - no mechanical problems found." ""
ok "exit 0 passes the step"                           "$(run)" 0
ok "exit 0 summary says Pass"                         "$(summary '\*\*Pass\.\*\*')" yes

stub 0 "  PASS with warnings - each is a judgement call." ""
ok "exit 0 with warnings passes the step"             "$(run)" 0
ok "warning-only run is named as such in the summary" "$(summary 'Pass, with warnings')" yes
ok "the warning text itself reaches the summary"      "$(summary 'judgement call')" yes

stub 1 "  ERROR budget  the description is over budget." ""
ok "exit 1 fails the step"                            "$(run)" 1
ok "exit 1 summary says Fail"                         "$(summary '\*\*Fail\.\*\*')" yes
ok "exit 1 emits a failure annotation"                "$(says '::error title=PR description lint failed')" yes
ok "exit 1 is NOT reported as could-not-run"          "$(summary 'Could not run')" no

stub 2 "" "gh api: HTTP 403"
ok "exit 2 fails the step"                            "$(run)" 2
ok "exit 2 summary says Could not run"                "$(summary 'Could not run')" yes
ok "exit 2 annotation is distinct from a failure"     "$(says '::error title=PR description lint could not run')" yes
ok "exit 2 is NOT reported as a findings failure"     "$(summary '\*\*Fail\.\*\*')" no
ok "the stderr reason is carried into the summary"    "$(summary 'HTTP 403')" yes

# The case the real linter produces on a missing `gh`: sys.exit(2) having printed nothing.
# A summary built from stdout alone renders an empty block for exactly this run.
stub 2 "" ""
ok "silent exit 2 still fails"                        "$(run)" 2
ok "silent exit 2 still names itself in the summary"  "$(summary 'Could not run')" yes

# Any other non-zero code is a could-not-run too, not a pass.
stub 3 "" ""
ok "an unexpected exit code fails"                    "$(run)" 3
ok "an unexpected exit code is a could-not-run"       "$(summary 'Could not run')" yes

printf '\n== argv built from the action inputs\n'

stub 0 "  PASS - no mechanical problems found." ""
ok "repo and pr are always passed"                    "$(run)" 0
ok "--repo carries the repository"                    "$(says 'argv: --repo owner/repo')" yes
ok "--pr carries the number"                          "$(says '--pr 7')" yes
ok "no --template when the input is empty"            "$(says '--template')" no
ok "no --exempt-section when the input is empty"      "$(says '--exempt-section')" no

TMPL=".github/PULL_REQUEST_TEMPLATE.md" ; export TMPL
ok "template input is passed through"                 "$(run)" 0
ok "--template carries the path"                      "$(says '--template .github/PULL_REQUEST_TEMPLATE.md')" yes
unset TMPL

EXEMPT="On-call runbook
Metrics" ; export EXEMPT
ok "newline-separated exempt-sections run"            "$(run)" 0
ok "first newline-separated section is passed"        "$(says '--exempt-section On-call runbook')" yes
ok "second newline-separated section is passed"       "$(says '--exempt-section Metrics')" yes
unset EXEMPT

EXEMPT="On-call runbook, Metrics ,, Appendix" ; export EXEMPT
ok "comma-separated exempt-sections run"              "$(run)" 0
ok "comma-separated sections are trimmed"             "$(says '--exempt-section On-call runbook --exempt-section Metrics')" yes
ok "an empty item between commas is dropped"          "$(says '--exempt-section Appendix')" yes
unset EXEMPT

printf '\n== could-not-run guards (each must be LOUD and non-zero, never skipped)\n'

stub 0 "  PASS" ""
PRNUM="" ; export PRNUM
ok "an event with no PR number cannot run"            "$(run)" 2
ok "the missing PR number is named"                   "$(summary 'no pull request number')" yes
unset PRNUM

TOKEN="" ; export TOKEN
ok "a missing token cannot run"                       "$(run)" 2
ok "the missing token is named"                        "$(summary 'no token')" yes
unset TOKEN

REPO="" ; export REPO
ok "a missing repository cannot run"                  "$(run)" 2
unset REPO

# A missing linter is the broken-install case. Loud, non-zero, and it names the path it
# looked at -- the same distinction the hook guardrail draws in CLAUDE.md.
rm -f "$work/stub.py"
ok "a missing linter cannot run"                      "$(run)" 2
ok "the path it looked at is named"                   "$(summary 'is not at')" yes

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
