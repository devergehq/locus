#!/bin/sh
# The plugin's only hook entry point. Every event runs through here.
#
#   usage: via-locus-binary.sh <locus hook subcommand>
#
# All six hooks are implemented in the `locus` binary. This script exists for
# exactly one reason that the binary cannot serve: detecting that the binary is
# missing. It must therefore stay dependency-free — sh only, no python3, no jq —
# because the whole point of DEV-610 was removing an interpreter dependency that
# could silently disable the gate.
#
# Two absences, deliberately different:
#
#   LOCUS_HOOKS=off    deliberate opt-out   -> silent, exit 0
#   locus not on PATH  broken install       -> LOUD, exit 0
#
# The plugin ships the binary in bin/ and cannot function without it, so a
# missing binary is not a supported configuration. Silently degrading would make
# "the Algorithm never ran" indistinguishable from "the Algorithm was never
# needed" — the defect this project has now hit eight times.
#
# Loud is not blocking. Never exit 2 here: PreToolUse would block legitimate
# tool calls and Stop would deadlock the session. Surface it, do not wedge it.
set -u

event="${1:-}"
[ -n "$event" ] || exit 0

# Deliberate opt-out stays completely quiet.
[ "${LOCUS_HOOKS:-on}" = "off" ] && exit 0

if command -v locus >/dev/null 2>&1; then
  exec locus hook "$event"
fi

# ---------------------------------------------------------------- degraded --

fix="The Locus plugin is installed but the \`locus\` binary is not on PATH, so \
every Locus hook is inert: the Algorithm is not being enforced, the Stop gate is \
not running, and the activation log is not being written. Install the binary \
(\`cargo install --path .\` from the Locus repo, or a release build onto your \
PATH) and restart Claude Code. Set LOCUS_HOOKS=off to silence this deliberately."

# Say it once per session, not once per turn. Keyed off CLAUDE_CODE_SESSION_ID
# rather than the event's JSON, because parsing stdin would need the interpreter
# this script exists to do without.
said=0
marker_dir="${CLAUDE_PLUGIN_DATA:-}"
if [ -n "$marker_dir" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  marker_dir="$marker_dir/pending"
  marker="$marker_dir/missing-binary-$CLAUDE_CODE_SESSION_ID"
  if [ -e "$marker" ]; then
    said=1
  else
    mkdir -p "$marker_dir" 2>/dev/null && : > "$marker" 2>/dev/null
  fi
fi

if [ "$said" -eq 1 ]; then
  exit 0
fi

# SessionStart is the one event that can tell the model itself, so it gets
# additionalContext as well as a transcript message. Everything else gets
# systemMessage, with stderr as the floor if the event ignores it.
if [ "$event" = "session-start" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"},"systemMessage":"%s"}' \
    "Locus is DEGRADED. $fix Tell the user this, plainly, before doing anything else." \
    "Locus: binary not found on PATH — hooks are inert."
else
  printf '{"systemMessage":"%s"}' "Locus: binary not found on PATH — hooks are inert."
fi

echo "locus: $fix" >&2
exit 0
