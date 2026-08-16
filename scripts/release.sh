#!/usr/bin/env bash
#
# Cut a Locus release, the standard Rust way (Cargo.toml is the source of truth).
#
#   scripts/release.sh <version> [--push]     # phase 1: prepare the bump
#   scripts/release.sh --tag <version>        # phase 2: tag the merged commit
#
# Two phases, because `master` is protected and cannot be pushed to directly.
#
# Phase 1 — prepare:
#   1. Bumps [workspace.package] version in Cargo.toml to <version>.
#   2. Refreshes Cargo.lock so the workspace crates match the new version.
#   3. Commits the bump as "release: v<version>" on a `chore/release-v<version>`
#      branch, leaving your current branch untouched.
#   4. Pushes that branch (with --push) and tells you to open a PR.
#
# It deliberately does NOT tag here. A squash merge rewrites the commit, so a
# tag created now would point at a commit that never reaches master — and the
# published binaries would be built from something that is not the release.
#
# Phase 2 — tag, after the PR merges:
#   Verifies master carries the expected version, tags master's HEAD, pushes the
#   tag. That push is what triggers .github/workflows/release.yml, which refuses
#   to build if the tag and Cargo.toml disagree.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

# --- args -------------------------------------------------------------------
MODE="prepare"
if [ "${1:-}" = "--tag" ]; then
  MODE="tag"
  shift
fi

VERSION="${1:-}"
PUSH="no"
[ "${2:-}" = "--push" ] && PUSH="yes"

[ -n "$VERSION" ] || die "usage: scripts/release.sh <version> [--push]        (prepare)
       scripts/release.sh --tag <version>         (tag after the PR merges)"
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "version must be semver X.Y.Z (got: $VERSION)"

# Run from repo root regardless of where the script is invoked.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TAG="v$VERSION"

# --- phase 2: tag an already-merged release commit --------------------------
if [ "$MODE" = "tag" ]; then
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"

  DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"

  git fetch --quiet origin "$DEFAULT_BRANCH"
  MERGED="$(git rev-parse "origin/$DEFAULT_BRANCH")"

  # The workflow compares the tag against Cargo.toml at the tagged commit, so
  # check the same thing here rather than trusting the working tree.
  MERGED_VER="$(git show "$MERGED:Cargo.toml" \
    | awk '/^\[workspace.package\]/{f=1} f && /^version[[:space:]]*=/{gsub(/[^0-9.]/,"",$0); print; exit}')"
  [ "$MERGED_VER" = "$VERSION" ] \
    || die "origin/$DEFAULT_BRANCH is at version '$MERGED_VER', not $VERSION — has the release PR merged?"

  git tag -a "$TAG" "$MERGED" -m "$TAG"
  echo "tagged $TAG at $(git rev-parse --short "$MERGED") on $DEFAULT_BRANCH"

  if [ "$PUSH" = "yes" ]; then
    git push origin "$TAG"
    echo "pushed $TAG — watch the release build under the repo's Actions tab."
  else
    echo
    echo "Nothing pushed yet. To trigger the release build:"
    echo
    echo "    git push origin $TAG"
  fi
  exit 0
fi

# --- preconditions ----------------------------------------------------------
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty; commit or stash first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"

CURRENT="$(cargo metadata --no-deps --format-version 1 \
  | python3 -c 'import json,sys; print(next(p["version"] for p in json.load(sys.stdin)["packages"] if p["name"]=="locus-cli"))')"
echo "current version: $CURRENT"
echo "new version:     $VERSION"
[ "$CURRENT" != "$VERSION" ] || die "Cargo.toml is already at $VERSION"

# --- 1. bump Cargo.toml [workspace.package] version -------------------------
python3 - "$VERSION" <<'PY'
import re, sys
version = sys.argv[1]
path = "Cargo.toml"
src = open(path).read()

# Replace the first `version = "..."` that appears inside [workspace.package].
def bump(text):
    out, in_section, done = [], False, False
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_section = (stripped == "[workspace.package]")
        elif in_section and not done and re.match(r'version\s*=', stripped):
            line = re.sub(r'version\s*=\s*"[^"]*"', f'version = "{version}"', line)
            done = True
        out.append(line)
    if not done:
        raise SystemExit("error: could not find version under [workspace.package]")
    return "".join(out)

open(path, "w").write(bump(src))
print(f"Cargo.toml -> version = \"{version}\"")
PY

# --- 2. refresh Cargo.lock --------------------------------------------------
echo "refreshing Cargo.lock ..."
cargo update --workspace --offline >/dev/null 2>&1 || cargo update --workspace >/dev/null

# --- 3. commit on a release branch (master is protected) --------------------
RELEASE_BRANCH="chore/release-$TAG"
git rev-parse -q --verify "refs/heads/$RELEASE_BRANCH" >/dev/null \
  && die "branch $RELEASE_BRANCH already exists"

git checkout -q -b "$RELEASE_BRANCH"
git add Cargo.toml Cargo.lock
git commit -m "release: $TAG" >/dev/null
echo "committed the bump on $RELEASE_BRANCH"

# No tag here — see the header. A squash merge rewrites this commit, so the tag
# has to wait until the release commit is actually on the default branch.

# --- 4. push the branch and explain phase 2 ---------------------------------
if [ "$PUSH" = "yes" ]; then
  git push -q -u origin "$RELEASE_BRANCH"
  echo "pushed $RELEASE_BRANCH"
fi

cat <<EOF

Next:
  1. Open a PR from $RELEASE_BRANCH and merge it.$([ "$PUSH" = "yes" ] || echo "
     (push it first: git push -u origin $RELEASE_BRANCH)")
  2. Tag the merged commit and trigger the build:

         scripts/release.sh --tag $VERSION --push

Nothing is tagged yet, deliberately — the tag must point at the commit that
lands on the default branch, not at this local one.
EOF
