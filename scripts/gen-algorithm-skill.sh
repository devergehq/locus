#!/bin/sh
# Regenerate skills/locus-algorithm/SKILL.md from algorithm/v2.0.md.
#
# The Algorithm has one source of truth: algorithm/v2.0.md, which the binary
# install path embeds via include_str!. The skill is that file plus skill
# frontmatter. Generating it means the plugin and the binary can never ship
# different Algorithms; the Rust test `locus_algorithm_skill_body_matches_the_algorithm`
# fails the build if this script has not been re-run.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$root/algorithm/v2.0.md"
dst="$root/skills/locus-algorithm/SKILL.md"

mkdir -p "$(dirname "$dst")"
{
  cat <<'FRONTMATTER'
---
name: locus-algorithm
description: The Locus Algorithm — seven-phase structured decomposition (OBSERVE, THINK, PLAN, BUILD, EXECUTE, VERIFY, LEARN) with effort tiers, ISC floors, the Splitting Test and the Phantom Capability Rule. Invoke this whenever a request has been classified non-trivial; do not reconstruct the phases from memory.
---

<!-- GENERATED FILE — edit algorithm/v2.0.md and run scripts/gen-algorithm-skill.sh -->

FRONTMATTER
  cat "$src"
} > "$dst"

echo "wrote $dst ($(wc -c < "$dst") bytes)"
