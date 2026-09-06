#!/bin/sh
# Assemble the distributable Locus plugin into dist/plugin/.
#
# Why this exists rather than just shipping the repo root:
#
# The repo root can be loaded directly (`claude --plugin-dir .`) and that is the
# right thing during development. It cannot be the *published* artifact, for two
# reasons that only show up when you check:
#
#   1. `claude plugin validate --strict` warns on a CLAUDE.md at the plugin root
#      — ours is contributor guidance, correctly not plugin context, but strict
#      treats the warning as an error.
#   2. The published plugin would otherwise drag crates/, target/ and Cargo.lock
#      along with it.
#
# Both alternatives to copying were tested against claude 2.1.263 and rejected:
# a plugin root above the content (`"skills": ["../skills"]`) is refused as path
# traversal, and symlinked component directories are not followed by the
# validator. So: copy.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="${1:-$root/dist/plugin}"

rm -rf "$out"
mkdir -p "$out"

# Components Claude Code loads.
cp -R "$root/.claude-plugin" "$out/.claude-plugin"
cp -R "$root/hooks"          "$out/hooks"
cp -R "$root/skills"         "$out/skills"
cp -R "$root/agents"         "$out/agents"

# Data our own code reads through ${CLAUDE_PLUGIN_ROOT}.
cp -R "$root/protocols"      "$out/protocols"
cp -R "$root/algorithm"      "$out/algorithm"

cp "$root/LICENSE"   "$out/LICENSE"
cp "$root/README.md" "$out/README.md"

# cp -R does not preserve the executable bit on every platform's cp.
chmod +x "$out"/hooks/*.sh

echo "built $out"
echo "  skills:  $(find "$out/skills" -name SKILL.md | wc -l | tr -d ' ')"
echo "  agents:  $(find "$out/agents" -name '*.md' | wc -l | tr -d ' ')"
echo "  hooks:   $(find "$out/hooks" -name '*.sh' | wc -l | tr -d ' ')"
