#!/usr/bin/env bash
#
# The body of the pr-lint composite action. It lives in its own file rather than inline in
# action.yml for one reason: a `run:` block cannot be executed by a test, and the exit-code
# mapping below is the whole point of this action. scripts/test-pr-lint-action.sh drives
# this file directly against a stub linter.
#
# Everything here is read-only. It reads the pull request through `gh api` and never checks
# out, builds or executes the code under review.

set -uo pipefail

# --- where the linter is -------------------------------------------------------------------
#
# GITHUB_ACTION_PATH is <repo root>/.github/actions/pr-lint, so the repository root is three
# levels up. The linter is NOT copied here and NOT symlinked: a copy drifts from the skill it
# came from, and nothing in this repo would regenerate it. The traversal is explicit, and
# missing is loud (see `die`) rather than silently skipped.
action_path="${GITHUB_ACTION_PATH:-$(cd -- "$(dirname -- "$0")" && pwd)}"
root="$(cd -- "$action_path/../../.." 2>/dev/null && pwd)" || root=""
lint="${PR_LINT_SCRIPT:-$root/skills/review-craft/pr_lint.py}"

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat >>"$GITHUB_STEP_SUMMARY"
  else
    cat
  fi
}

# A could-not-run is LOUD and NON-ZERO. It is never a pass and never a neutral: this
# repository's rule is that a check which passes without running carries no information.
die() {
  printf '::error title=PR description lint could not run::%s\n' "$1"
  {
    printf '## PR description lint\n\n'
    printf '**Could not run.** %s\n\n' "$1"
    printf 'This is a failure, not a pass. A check that reports green without having run carries no information.\n'
  } | summary
  exit 2
}

[ -n "$root" ] || die "could not resolve the repository root from GITHUB_ACTION_PATH=${GITHUB_ACTION_PATH:-unset}"
[ -f "$lint" ] || die "the linter is not at $lint (GITHUB_ACTION_PATH=${GITHUB_ACTION_PATH:-unset})"
command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH"
command -v gh >/dev/null 2>&1 || die "gh is not on PATH"
[ -n "${PR_LINT_REPO:-}" ] || die "no repository in the event context"
if [ -z "${PR_LINT_PR:-}" ]; then
  die "this event carries no pull request number (both github.event.pull_request.number and github.event.issue.number are empty). The action supports pull_request and issue_comment events on a pull request."
fi
[ -n "${GH_TOKEN:-}" ] || die "no token. Pass one as the action's github-token input; the default is \${{ github.token }}."

# --- argv ----------------------------------------------------------------------------------
args=("$lint" --repo "$PR_LINT_REPO" --pr "$PR_LINT_PR")

if [ -n "${PR_LINT_TEMPLATE:-}" ]; then
  args+=(--template "$PR_LINT_TEMPLATE")
fi

# exempt-sections arrives as one string. Newline- or comma-separated, because a YAML author
# reaches for either: `exempt-sections: |` and `exempt-sections: a, b` both work.
if [ -n "${PR_LINT_EXEMPT:-}" ]; then
  while IFS= read -r section; do
    section="${section#"${section%%[![:space:]]*}"}"
    section="${section%"${section##*[![:space:]]}"}"
    if [ -n "$section" ]; then
      args+=(--exempt-section "$section")
    fi
  done <<<"$(printf '%s' "$PR_LINT_EXEMPT" | tr ',' '\n')"
fi

# Printed so the inputs are checkable from the run log. An input that is silently dropped is
# the other way this check reports a wrong answer.
printf 'pr-lint: python3'
printf ' %q' "${args[@]}"
printf '\n\n'

# --- run -----------------------------------------------------------------------------------
out="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$out" "$err"' EXIT

# NOT piped. `python3 ... | tee -a "$GITHUB_STEP_SUMMARY"` takes tee's exit code, which is
# always 0, so every run would report green -- including the exit-2 runs this check exists to
# make visible. The code is captured first and the summary written from the file afterwards.
code=0
python3 "${args[@]}" >"$out" 2>"$err" || code=$?

cat "$out"
if [ -s "$err" ]; then
  cat "$err" >&2
fi

# The linter writes its findings to stdout and its could-not-run reasons to STDERR, and on a
# missing `gh` it exits 2 having printed nothing at all. A summary built from stdout alone
# would render an empty block for exactly the cases that matter most.
emit_summary() {
  local verdict="$1"
  {
    printf '## PR description lint\n\n'
    printf '%s\n\n' "$verdict"
    # Four backticks, and a fenced block rather than loose markdown. The issue asks for the
    # findings verbatim, and a fence is what makes them verbatim: a finding quotes headings
    # and section names out of an author-controlled description, which would otherwise render
    # as summary markdown and could forge a line under this check's own name.
    printf '````text\n'
    if [ -s "$out" ]; then
      cat "$out"
    else
      printf '(the linter wrote nothing to stdout)\n'
    fi
    if [ -s "$err" ]; then
      printf '\n---- stderr ----\n'
      cat "$err"
    fi
    printf '````\n'
  } | summary
}

case "$code" in
  0)
    if grep -q 'PASS with warnings' "$out"; then
      emit_summary '**Pass, with warnings.** The budget is a target under 2x, so each warning is a judgement call rather than a rule.'
    else
      emit_summary '**Pass.** Mechanics only -- this says nothing about whether the description is worth reading.'
    fi
    ;;
  1)
    printf '::error title=PR description lint failed::The description carries errors. See the job summary for the findings.\n'
    emit_summary '**Fail.** The description carries errors. Fix what is named below and push, edit the description, or add the comment it asks for -- the check re-runs on all three.'
    ;;
  *)
    # Exit 2, and anything else, is a could-not-run: the linter reached no verdict. Reported
    # with its own message so nobody goes looking for a finding that was never produced.
    printf '::error title=PR description lint could not run::The linter exited %s without reaching a verdict. This is not a findings failure -- there are no findings. See the job summary.\n' "$code"
    emit_summary "$(printf '**Could not run.** The linter exited %s without reaching a verdict, so there are no findings to read. This is a failure rather than a pass, because a check that reports green without having run carries no information.' "$code")"
    ;;
esac

exit "$code"
