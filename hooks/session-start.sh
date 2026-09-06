#!/bin/sh
# SessionStart — re-land the dispatcher after a compaction.
#
# Only fires for source="compact". On "startup", "resume" and "clear" the next
# UserPromptSubmit carries the dispatcher anyway, so injecting here as well
# would just pay for the same context twice.
#
# The field is `source`, not `session_start_reason` — verified against
# claude 2.1.263, which contains no such string.
set -u
root="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"

input=$(cat)
case "$input" in
  *'"source"'*'"compact"'*) ;;
  *) exit 0 ;;
esac

exec "$root/hooks/emit-context.sh" SessionStart
