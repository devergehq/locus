#!/bin/sh
# Stop — verify the turn actually classified, and block once if it did not.
#
# Fails open in every direction it can: no python3, verifier off, or any
# unhandled error inside the verifier all end the turn normally. A verifier
# that can wedge a session is worse than no verifier at all.
set -u
root="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"

[ "${LOCUS_VERIFY:-on}" = "off" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

exec python3 "$root/hooks/lib/verify_stop.py"
