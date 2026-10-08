# `pr-lint` — the PR description check, as a GitHub Action

This packages [`skills/review-craft/pr_lint.py`](../../../skills/review-craft/pr_lint.py) so
the description check runs on every pull request instead of being raised by hand in a review.

It checks **mechanics only**: the body's character budget for that diff, headings, template
debris, words that rot in a commit message, squash noise, and whether the comment its working
notes link to actually exists. A clean run means nothing is broken. It says nothing about
whether the description is worth reading.

## Using it from another repository

```yaml
name: PR lint

on:
  pull_request:
    types: [opened, reopened, synchronize, edited]
  issue_comment:
    types: [created, edited, deleted]

permissions:
  contents: read
  pull-requests: read
  issues: read

concurrency:
  group: pr-lint-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: true

jobs:
  description:
    if: >-
      github.event_name == 'pull_request' ||
      (github.event.issue.pull_request != null && github.event.issue.state == 'open')
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: devergehq/locus/.github/actions/pr-lint@PINNED_SHA
```

That is the whole snippet. There is **no `actions/checkout` step**, and it is not an omission:
the action reads the description, the diff size and the comments through `gh api`, so it never
needs the code under review on the runner. Add a checkout only if you pass `template`, which
is a path.

**Pin a commit SHA, not a branch and not a tag.** A composite action runs arbitrary steps with
your workflow's token; a tag can be moved and `master` changes under you. A release tag
(`v0.5.6` or later — the first release that carries this action) is acceptable if your
organisation prefers tags, and `git tag --contains PINNED_SHA` in this repository names it.
Never `@master`.

`devergehq/locus` is public, so this works from a private repository.

## Inputs

| Input | Default | What it does |
| -- | -- | -- |
| `template` | *(none)* | A markdown file, or a directory of them, that a description here is expected to match. Passed as `--template`. Supplying it is an **assertion**, so drift from it is an **error**; a template the linter discovers on a conventional path is an inference, and drift is a **warning**. It is a path, so the repository must be checked out first. |
| `exempt-sections` | *(none)* | Headings whose content the budget does not charge for, one per line or comma-separated. Each becomes a `--exempt-section` flag, **adding** to the linter's defaults (`related`, `reference`, `link`, `security impact`, `security`, `deployment`, `rollback`). |
| `github-token` | `${{ github.token }}` | The token `gh` reads the pull request with. Override it to read a pull request in another repository. |

```yaml
      - uses: devergehq/locus/.github/actions/pr-lint@PINNED_SHA
        with:
          template: .github/PULL_REQUEST_TEMPLATE.md
          exempt-sections: |
            On-call runbook
            Metrics
```

## What the check reports

| Linter exit | The check | What you see |
| -- | -- | -- |
| 0, no warnings | **pass** | The findings block, and `PASS` |
| 0, with warnings | **pass** | The warnings, shown but not blocking — the budget is a target under 2× |
| 1 | **fail** | The errors, named, in the job summary |
| 2 | **fail**, with its own message | *Could not run* — the linter reached no verdict |

Exit 2 is deliberately **not** a pass. A check that reports green without having run carries
no information, so a missing `gh`, an expired token or a 403 fails the job and says which it
was, rather than quietly reporting that nothing is wrong.

The linter's output goes to the job summary verbatim, inside a fenced block. The fence is what
makes it verbatim: findings quote headings out of an author-controlled description, and
unfenced they would render as summary markdown.

## Permissions, and one that is easy to get wrong

All three reads in the snippet are load-bearing:

* **`contents: read`** — template discovery walks `repos/{repo}/contents/…`. Without it those
  probes return 403, and the linter cannot distinguish a 403 from the 404 it expects in a
  repository that has no template. **Template checking then finds nothing and the run still
  reports pass.** Grant it even if you think you have no template.
* **`pull-requests: read`** — the description and the diff size.
* **`issues: read`** — `repos/{repo}/issues/{n}/comments`, which is the issues API even for a
  pull request. The linter exits 2 if that call fails, so omitting this is a red check on
  every pull request rather than a silent one.

## Triggers, and what the comment trigger cannot do

The three triggers exist because **the failure this check catches moves without a commit**: a
description is edited in the web UI, and by house style the working notes are moved out of the
body late, so their comment is the newest thing on the pull request rather than the first.

`issue_comment` has two limits, both GitHub's and neither fixable from a workflow file:

1. GitHub runs an `issue_comment` workflow **only from the default branch**. A change to the
   workflow or to this action cannot be exercised through the comment path until it is merged.
2. The comment-triggered run's `GITHUB_SHA` is the default branch's, so its result **does not
   attach to the pull request head** and does not appear in the pull request's check list. It
   is in the job summary and the Actions tab. The status a branch-protection rule keys on comes
   from the `pull_request` triggers.

## Pull requests from forks

Use `pull_request`, as the snippet does — **never `pull_request_target`**. The lint only reads,
so the read-only `GITHUB_TOKEN` that a fork's pull request receives is sufficient.
`pull_request_target` would hand a write token to a check that needs no writes.

Note the trust boundary where the action is referenced **by local path** (as Locus's own
workflow does, so that a change to the action is tested by the pull request that makes it): a
fork's pull request supplies its own copy of the action and the linter, and so can make the
check pass. That is the same model `cargo test` already runs under on a fork's pull request,
and the same control applies — the replacement is in the diff a human reads. An external
caller pinning a SHA does not inherit this.

## Testing it

* `scripts/test-pr-lint.sh` — the linter's own rules and thresholds (local drafts).
* `scripts/test-pr-lint-action.sh` — this action's exit-code mapping and the argv it builds
  from its inputs, against a stub linter. The exit-code mapping is where this check could
  report a wrong answer rather than fail, so it is tested rather than assumed.

Both are run by `ci.yml`'s test job.
