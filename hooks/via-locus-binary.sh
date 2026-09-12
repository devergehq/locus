#!/bin/sh
# Bridge a plugin hook event to the `locus` binary's existing handler.
#
#   usage: via-locus-binary.sh <locus hook subcommand>
#
# Three of Locus's seven hooks — PreToolUse, PostToolUse and PreCompact — are
# already implemented in Rust and covered by the crate's tests. The plugin does
# not reimplement them; it invokes them. Reimplementing would duplicate tested
# logic in a second language for no behavioural gain, and the two copies would
# drift the first time either changed.
#
# Fails open in every direction. `locus` not installed, not yet built, or not on
# PATH all end the event normally. PreToolUse in particular is deny-capable, so a
# wrapper that failed closed would block legitimate tool calls in any session
# where the binary happens to be missing — strictly worse than not running.
set -u

event="${1:-}"
[ -n "$event" ] || exit 0

# Honour the same kill switch the Stop verifier uses, so one variable disables
# every Locus hook rather than leaving a session half-governed.
[ "${LOCUS_HOOKS:-on}" = "off" ] && exit 0

command -v locus >/dev/null 2>&1 || exit 0

exec locus hook "$event"
