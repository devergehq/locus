#!/bin/sh
# Unit tests for what `doctor` does with a config.json it cannot read (DEV-979).
#
# `cmd_doctor`'s first line was an unguarded `load_config()`, so an instance whose config.json
# would not parse killed the one command meant to diagnose a broken instance -- a
# `JSONDecodeError` traceback before a single check ran, while `reap --dry-run` read the same file
# and exited clean. What is under test is the four states that file can be in (parses, will not
# parse, cannot be read, is not an object), the two states its directory can be in (resolves,
# does not), and the three states a check can be in (passed, failed, never ran).
#
# Every case runs against a THROWAWAY instance under mktemp, and `DISPATCHER_HOME` is a temporary
# directory too. That is not tidiness twice over: `live_watchers` globs `DISPATCHER_HOME` for the
# sole-instance rule that decides which watcher processes are reapable, and a run that read the
# real one could attribute a LIVE watcher to this fixture.
#
# No test here makes a network call, and that is a property of the fixture rather than of mocking.
# `LINEAR_API_KEY` is unset below, so `linear()` raises before it builds a request and `doctor`
# reports two crosses it never left the machine to earn; `allele.state_file` points at a fixture;
# PATH is narrowed so neither `gh` nor `locus` nor `review-desk` is in reach.
#
# What is NOT covered, and why:
#
#   * A wholly green `doctor`. Three of its sixteen checks need a Linear token and the network,
#     so the exit code of a healthy run is decided by the machine it runs on. The healthy
#     assertions below are about what the change could have broken -- that nothing is reported as
#     skipped, that no config finding is printed, and that all sixteen checks still report -- and
#     the fault runs assert the exit code, where it is the config that decides it.
#   * `all(ok is not False ...)` rather than `all(ok ...)` in the exit line. A skipped check
#     cannot be the only reason a run fails, because a skip exists only when the config fault
#     above it is already a cross, so the two spellings are indistinguishable from outside. There
#     is no assertion for it, and no reversal: a test for a difference nothing can observe would
#     report PASS about nothing.
#
# The reversals at the bottom are the teeth. Each one changes one line back to what it was, re-
# runs the assertion that covers it, and requires a different answer -- so a green run cannot be
# green because the fixture never reached the code under test.
set -eu

# `gh`, `locus` and `review-desk` are deliberately out of reach, so that a developer machine with
# all three installed reads these checks the same way the CI runner does without them.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")"
export PATH

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
disp="$root/skills/dispatcher/dispatcher.py"

# `pwd -P`, because on macOS `mktemp -d` hands back a path under /var, which is a symlink to
# /private/var, and `instance_path` resolves what it is given. Without this the fixture and the
# path `doctor` prints are the same directory spelled two ways, and every assertion that names
# the directory would be comparing them.
work=$(CDPATH= cd -- "$(mktemp -d)" && pwd -P)
inst="$work/inst"
export DISPATCHER_HOME="$work/home"
# Belt as well as braces: nothing here asks Review Desk anything, and `review_desk_work` is
# reached only when the command is on PATH, which the line above prevents. Set so that the next
# person to put a stand-in on PATH cannot be the one who opens the live store under ~/.review-desk.
export REVIEW_DESK_DB="$work/review-desk.db"
# A developer's own shell has this set. Left set, the first two checks would leave the machine.
unset LINEAR_API_KEY || true
unset DISPATCHER_INSTANCE || true
cleanup () {
  # The unreadable-config case leaves a mode-000 file behind. `rm -rf` does not care, but a
  # readable tree is easier to inspect when a failure sends someone looking.
  chmod 644 "$inst/config.json" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$inst" "$DISPATCHER_HOME"
printf '{ "sessions": [], "archived_sessions": [] }\n' > "$work/allele-state.json"

pass=0
fail=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-56s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-56s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

# doctor [script] -> exit code, with stdout AND stderr in $work/out. Both streams, because a
# traceback is the thing being tested and it arrives on stderr.
doctor () { set +e; python3 "${1:-$disp}" --instance "$inst" doctor >"$work/out" 2>&1; c=$?; set -e; echo "$c"; }
says () { grep -q -- "$1" "$work/out" && echo yes || echo no; }
count () { grep -c -- "$1" "$work/out" || true; }
# ran -> how many checks actually RAN. Not a count of ✓ and ✗ lines: the fault is itself a
# cross, and counting it as a check that ran would hide one that did not. An alternation of two
# literals rather than a bracket expression, because `[✓✗]` is a set of BYTES to a C-locale GNU
# grep and would match nothing -- every other pattern in this file is a literal multibyte string
# and so cannot be read that way. `: ` on the exclusions, so that `instance root` is not one.
ran () { grep '^✓ \|^✗ ' "$work/out" | grep -vc '^✗ config: \|^✗ instance: ' || true; }
# printed -> check lines in ANY of the three states, for the reversals, which assert that not one
# was printed. Three literal alternatives and no bracket expression, for the reason above, and
# here it matters more than it does in `ran`: all three of those assertions expect ZERO, so a
# set a C-locale grep reads as bytes would have matched nothing and passed every one of them
# without reading the output at all. A reversal that cannot fail is the one thing this section
# exists not to be, and this is the second place in this file that defect was found.
printed () { grep -c '^✓ \|^✗ \|^– ' "$work/out" || true; }
# row -> the marker and the check name on the first line, e.g. "✗ config:". A FIELD range, and
# never a character range: GNU cut counts bytes for `-c`, ✗ is three of them, and a `-c1-9` so
# clipped every one of these comparisons two characters short -- 4 failures on ubuntu-latest
# while macOS passed, because BSD cut counts characters. Field mode splits on a single-byte
# delimiter, and UTF-8 is ASCII-transparent, so no space byte can occur inside the marker and
# field 1 arrives whole under any locale.
row () { head -1 "$work/out" | cut -d' ' -f1,2; }
# healthy -> write a config.json from the shipped template, with the one value that would
# otherwise read a developer's real allele state redirected into $work.
healthy () { python3 - "$root" "$inst" "$work" <<'PY'
import json, pathlib, sys
root, inst, work = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
cfg = json.loads((pathlib.Path(root) / "skills/dispatcher/config.example.json").read_text())
cfg["allele"]["state_file"] = f"{work}/allele-state.json"
(inst / "config.json").write_text(json.dumps(cfg, indent=2))
PY
}

printf 'A config.json that parses: nothing is skipped and nothing is renamed\n'
healthy
rc=$(doctor)
ok "no config fault is reported"                       "$(count '^✗ config:')" 0
ok "  and no check is recorded as skipped"             "$(count '^– ')" 0
ok "  all sixteen checks report"                       "$(ran)" 16
ok "  the config IS read, and by its own value"        "$(says '✓ allele state: 0 sessions')" yes
ok "  the two roots are still printed"                 "$(count '^✓ \(code\|instance\) root: /')" 2
ok "  Review Desk still reports its mode"              "$(says '✓ review desk: auto')" yes
ok "  and no traceback reaches either stream"          "$(count Traceback)" 0

printf '\nA config.json that will not parse is the FIRST finding, not a traceback\n'
# Four lines, so that the reported line number is a fact about the file and not about the error
# being on line 1 whatever happens. The missing comma is after line 3's value.
printf '{\n  "linear": { "team_key": "DEV" }\n  "github": { "login": "octocat" }\n}\n' > "$inst/config.json"
rc=$(doctor)
ok "doctor exits non-zero"                             "$rc" 1
ok "  and never 2 -- nothing in a hook path may block" "$([ "$rc" -eq 2 ] && echo two || echo "not two")" "not two"
ok "  with no traceback"                               "$(count Traceback)" 0
ok "  no JSONDecodeError on either stream"             "$(count JSONDecodeError)" 0
ok "the fault is the first line printed"               "$(row)" '✗ config:'
ok "  it names the file by absolute path"              "$(says "$inst/config.json")" yes
ok "  says the file will not parse"                    "$(says 'will not parse')" yes
ok "  quotes the parser's own message"                 "$(says "Expecting ',' delimiter")" yes
ok "  and the line and column it stopped at"           "$(says 'line 3 column 3')" yes
ok "the eight checks needing the config are skipped"   "$(count '^– ')" 8
ok "  each saying why"                                 "$(count '^– .*skipped — config.json will not parse')" 8
ok "  and none of them claiming to have passed"        "$(count '^✓ linear\|^✓ review desk\|^✓ intervals')" 0
ok "the eight that do not need it still report"        "$(ran)" 8
ok "  the watchers check among them"                   "$(says '✓ watchers:')" yes
ok "  and the cursor check, which reads the runtime"   "$(says '✓ watch cursors:')" yes
ok "  the code root, which needs neither"              "$(says '✓ code root:')" yes
ok "  and the worker briefs beside it"                 "$(says '✓ worker briefs:')" yes

printf '\nA missing config.json says it is missing, and says how to fix it\n'
rm -f "$inst/config.json"
rc=$(doctor)
ok "doctor exits non-zero"                             "$rc" 1
ok "  with no traceback"                               "$(count Traceback)" 0
ok "the fault is still the first line"                 "$(row)" '✗ instance:'
ok "  headed for the instance, not the file"           "$(count '^✗ config: ')" 0
ok "  naming the directory it looked in"               "$(says "no config.json in $inst")" yes
ok "  and the command that creates one"                "$(says 'init --instance')" yes
ok "every check needing the instance is skipped"       "$(count '^– ')" 12
ok "  saying the instance did not resolve"             "$(count 'skipped — the instance did not resolve')" 12
ok "the four needing neither still report"             "$(ran)" 4
ok "  including the briefs this install ships"         "$(says '✓ worker briefs:')" yes

printf '\nNo instance at all is the same fault, reported the same way\n'
# No --instance, and DISPATCHER_HOME is an empty directory: `resolve_instance`'s third branch.
set +e; python3 "$disp" doctor > "$work/out" 2>&1; rc=$?; set -e
ok "doctor exits non-zero"                             "$rc" 1
ok "  with no traceback"                               "$(count Traceback)" 0
ok "  naming the home it searched"                     "$(says "no dispatcher instance under $DISPATCHER_HOME")" yes
ok "  under the instance heading"                      "$(count '^✗ instance: ')" 1
ok "  and still reporting the code root"               "$(says '✓ code root:')" yes

printf '\nA config.json that cannot be read reports the OS error\n'
printf '{}\n' > "$inst/config.json"
chmod 000 "$inst/config.json"
if [ -r "$inst/config.json" ]; then
  # euid 0 reads a mode-000 file, so this case cannot be constructed as root. Reported rather
  # than failed: a harness that fails when run as root teaches people to run it another way.
  printf '  skipped -- this process can read a mode-000 file (running as root?)\n'
else
  rc=$(doctor)
  ok "doctor exits non-zero"                           "$rc" 1
  ok "  with no traceback"                             "$(count Traceback)" 0
  ok "  no PermissionError on either stream"           "$(count PermissionError)" 0
  ok "the fault is the first line"                     "$(row)" '✗ config:'
  ok "  naming the file"                               "$(says "$inst/config.json cannot be read")" yes
  ok "  and the reason the OS gave"                    "$(says 'Permission denied')" yes
  ok "the config checks are skipped with that reason"  "$(count 'skipped — config.json cannot be read')" 8
  ok "  while the instance ones still run"             "$(says '✓ watch cursors:')" yes
fi
chmod 644 "$inst/config.json"

printf '\nA config.json that cannot be DECODED is a finding too, not a traceback\n'
# One latin-1 byte in a value, which is what a hand edit in the wrong editor leaves behind. This
# is the state the first version of the guard still died on: `read_text` decodes, and a decode
# failure is a `ValueError`, so it was neither of the two exceptions the guard caught. No fixture
# above can reach it -- every other one here is ASCII.
printf '{ "linear": { "mcp_workspace": "caf\351" } }\n' > "$inst/config.json"
rc=$(doctor)
ok "doctor exits non-zero"                             "$rc" 1
ok "  with no traceback"                               "$(count Traceback)" 0
ok "  no UnicodeDecodeError on either stream"          "$(count UnicodeDecodeError)" 0
ok "the fault is the first line"                       "$(row)" '✗ config:'
ok "  naming the file"                                 "$(says "$inst/config.json cannot be decoded")" yes
ok "  and the byte it stopped on"                      "$(says 'at byte 35')" yes
ok "  it names the codec, which is the cause"          "$(says 'cannot be decoded as')" yes
ok "  and says the locale is the other cause"          "$(says "process's locale")" yes
ok "the config checks are skipped with that reason"    "$(count 'skipped — config.json cannot be decoded')" 8
ok "  while the instance ones still run"               "$(says '✓ watch cursors:')" yes

printf '\nA config.json that parses to something other than an object is ONE fault\n'
printf '[ "linear", "github" ]\n' > "$inst/config.json"
rc=$(doctor)
ok "doctor exits non-zero"                             "$rc" 1
ok "  with no traceback"                               "$(count Traceback)" 0
ok "the fault names the type it found"                 "$(says 'holds a JSON list, not an object')" yes
ok "  and exactly one cross carries it"                "$(count '^✗ .*not an object')" 1
ok "no check reports a list indexing error"            "$(says 'list indices must be integers')" no
ok "the eight config checks are skipped instead"       "$(count '^– ')" 8

# =============================================================================================
printf '\nThe reversals -- what each assertion above would say about the old code\n'
# Every check above has to be able to FAIL. Each reversal changes one line back to the shape this
# ticket was filed about, re-runs the assertion that covers it, and requires a different answer.

# 1. The guard itself: `doctor` reading its config the way every other command does. This is the
#    defect verbatim -- the traceback the four fault sections above assert is absent.
sed 's|^    root, cfg, fault = config_report(.*$|    _instance = resolve_instance(getattr(args, "instance", None) or args.root_instance); root, cfg, fault = _instance, load_config(), None  # UNGUARDED READ RESTORED|' \
    "$disp" > "$work/unguarded.py"
ok "the unguarded-read reversal changed one line"      "$(grep -c 'UNGUARDED READ RESTORED' "$work/unguarded.py")" 1
printf '{\n  "linear": { "team_key": "DEV" }\n  "github": { "login": "octocat" }\n}\n' > "$inst/config.json"
rc=$(doctor "$work/unguarded.py")
ok "unguarded: a malformed config is a traceback"      "$(says Traceback)" yes
ok "  naming the exception instead of the file"        "$(says JSONDecodeError)" yes
ok "  and not one check is reported"                   "$(printed)" 0

# 2. The gate in `check`. `resolve_instance` raises `SystemExit`, which is a BaseException and so
#    passes straight through `check`'s `except Exception`: without the gate, an instance-dependent
#    check run against an instance that did not resolve ends the process before the checks that
#    DID run are printed -- the same command, useless again, for a different reason.
sed 's|^        if (needs == "config" and fault) or (needs == "instance" and root is None):$|        if False:  # SKIP GATE REMOVED|' \
    "$disp" > "$work/nogate.py"
ok "the skip-gate reversal changed one line"           "$(grep -c 'SKIP GATE REMOVED' "$work/nogate.py")" 1
rm -f "$inst/config.json"
rc=$(doctor "$work/nogate.py")
ok "no gate: a missing config prints no checks at all" "$(printed)" 0
ok "  not even the fault it had already found"         "$(count '^✗ ')" 0
ok "  and nothing is reported as skipped"              "$(count '^– ')" 0

# 3. The object guard. A config that parses but is not a mapping reaches every `.get` and `[]` in
#    turn, so one typo is reported as a wall of crosses with no line naming the file.
sed 's|^    if not isinstance(cfg, dict):$|    if False:  # OBJECT GUARD REMOVED|' "$disp" > "$work/notadict.py"
ok "the object-guard reversal changed one line"        "$(grep -c 'OBJECT GUARD REMOVED' "$work/notadict.py")" 1
printf '[ "linear", "github" ]\n' > "$inst/config.json"
rc=$(doctor "$work/notadict.py")
ok "no guard: the list reaches the checks"             "$(says 'list indices must be integers')" yes
ok "  and no finding names the file"                   "$(count '^✗ config:')" 0
ok "  while every config check reports a cross"        "$(count '^– ')" 0

# 4. The decode guard, which is the one state the first version of this change still died on and
#    which a review caught. `read_text` decodes, so the failure is a `ValueError` and neither of
#    the exceptions either side of it -- a clause that catches the wrong class is indistinguish-
#    able from no clause at all, which is what this puts back.
sed 's|^    except UnicodeDecodeError as exc:$|    except RuntimeError as exc:  # DECODE GUARD REMOVED|' \
    "$disp" > "$work/nodecode.py"
ok "the decode-guard reversal changed one line"        "$(grep -c 'DECODE GUARD REMOVED' "$work/nodecode.py")" 1
printf '{ "linear": { "mcp_workspace": "caf\351" } }\n' > "$inst/config.json"
rc=$(doctor "$work/nodecode.py")
ok "wrong class: a latin-1 byte is a traceback"        "$(says Traceback)" yes
ok "  naming the exception instead of the file"        "$(says UnicodeDecodeError)" yes
ok "  and not one check is reported"                   "$(printed)" 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
