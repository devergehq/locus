#!/bin/sh
# UserPromptSubmit — inject the Locus dispatcher next to every prompt.
#
# Compliance decay is a distance problem. Injecting here resets the distance on
# every turn, instead of loading the instruction once at session start and
# hoping it is still salient thirty thousand tokens later.
set -u
root="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
exec "$root/hooks/emit-context.sh" UserPromptSubmit
