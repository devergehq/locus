#!/usr/bin/env bash
#
# Cut a Locus release, the standard Rust way (Cargo.toml is the source of truth).
#
#   scripts/release.sh <version> [--push]
#
# Example:
#   scripts/release.sh 0.2.0
#
# What it does:
#   1. Bumps [workspace.package] version in Cargo.toml to <version>.
#   2. Refreshes Cargo.lock so the workspace crates match the new version.
#   3. Commits the bump as "release: v<version>".
#   4. Creates an annotated git tag "v<version>" on that commit.
#   5. Prints the push command (or pushes for you with --push).
#
# Pushing the tag is what triggers .github/workflows/release.yml to build the
# binaries and publish the GitHub Release. The version you pass here MUST be the
# version the tag carries — the release workflow refuses to build on a mismatch.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

# --- args -------------------------------------------------------------------
VERSION="${1:-}"
PUSH="no"
[ "${2:-}" = "--push" ] && PUSH="yes"

[ -n "$VERSION" ] || die "usage: scripts/release.sh <version> [--push]  (e.g. 0.2.0)"
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "version must be semver X.Y.Z (got: $VERSION)"

# Run from repo root regardless of where the script is invoked.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TAG="v$VERSION"

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

# --- 3. commit + 4. tag -----------------------------------------------------
git add Cargo.toml Cargo.lock
git commit -m "release: $TAG" >/dev/null
git tag -a "$TAG" -m "$TAG"
echo "committed and tagged $TAG"

# --- 5. push (or tell the user how) -----------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$PUSH" = "yes" ]; then
  echo "pushing branch $BRANCH and tag $TAG ..."
  git push origin "$BRANCH"
  git push origin "$TAG"
  echo "done — watch the release build under the repo's Actions tab."
else
  cat <<EOF

Created commit + tag locally. Nothing has been pushed yet.
To trigger the release build, push both the branch and the tag:

    git push origin $BRANCH
    git push origin $TAG

(or re-run with --push to do that automatically next time.)
EOF
fi
