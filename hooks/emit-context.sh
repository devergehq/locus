#!/bin/sh
# Emit hooks/dispatcher.txt as an additionalContext envelope for hook event $1.
#
# Deliberately dependency-free: sh + awk only. The dispatcher is the load-bearing
# half of Locus-as-a-plugin, so it must not be able to fail for want of an
# interpreter. dispatcher.txt is the single source of the payload — nothing is
# generated, so nothing can drift out of sync with it.
set -u

event="$1"
root="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
payload="$root/hooks/dispatcher.txt"

[ -r "$payload" ] || exit 0

ctx=$(awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); printf "%s\\n", $0 }' "$payload")

printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' "$event" "$ctx"
