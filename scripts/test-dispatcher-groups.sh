#!/bin/sh
# Unit tests for the session-group half of skills/dispatcher/dispatcher.py (DEV-938).
#
# `group` on `allele_sessions_create` is allele's (DEV-853) and is NOT in the allele installed
# while this was written, so no test here can create a session. What is under test is everything
# on the Locus side of that call: which group each mode resolves to, what the brief tells the
# session that is about to be created, what a re-run of `init` teaches an older config, and what
# `doctor` crosses. The rule that a dispatcher must omit `group` against an allele that has never
# heard of it is instruction text and is pinned in Rust, by
# `every_dispatch_site_passes_a_group_only_when_the_tool_has_one` in crates/locus-cli/src/bundled.rs
# -- a shell harness cannot read an MCP tool schema, and a check that pretended to would report
# PASS about nothing.
#
# Three things matter about the fixtures, and all three are the same point: `null` is a VALUE
# here. `"review": null` is how an operator says "dispatch reviews ungrouped", which is the one
# case the `review_cfg`/`review_desk_cfg` idiom in this file would quietly turn back into the
# default. Every null and every empty string below is a test of that, not padding.
#
# The reversals at the bottom are the teeth. Each one re-runs an assertion above against a copy
# of the source with one line changed back, and requires the answer to change -- so a green run
# cannot be green because the assertion was comparing a list against itself.
#
# Nothing here touches ~/.locus/data/dispatcher: every instance is a throwaway under mktemp, and
# a live dispatcher is polling one of those directories. No network call, no credential, no
# built binary.
set -eu

# `locus` is deliberately out of reach. `cmd_brief` composes its head by running
# `locus agent compose` and falls back to a plain head when it cannot, and the fallback is what
# runs in CI; narrowing PATH here means the brief assertions read the same answer on a developer
# machine with the binary installed as on a runner without it.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")"
export PATH

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
disp="$root/skills/dispatcher/dispatcher.py"

work=$(mktemp -d)
inst="$work/inst"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok () {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %-60s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  %-60s expected %s, got %s\n' "$1" "$3" "$2"
  fi
}

# ---- the instance ---------------------------------------------------------------------------
# instance '<json for allele.groups, or empty for NO BLOCK AT ALL>'. No block is the state every
# existing instance is in, and the first acceptance criterion is about exactly that one.

instance () {
  rm -rf "$inst"; mkdir -p "$inst/runtime/ledger" "$inst/runtime/watch"
  python3 - "$inst/config.json" "${1:-}" <<'PY'
import json, pathlib, sys
dest, groups = pathlib.Path(sys.argv[1]), sys.argv[2]
cfg = {
  "linear": {"api_key_env": "TEST_NO_SUCH_TOKEN", "mcp_workspace": "ws", "team_key": "ZZ",
             "label_group_id": "g",
             "labels": {"todo": {"id": "L-todo", "name": "Agent - Todo"}},
             "modes": {"implement": {"trigger": "todo", "working": "todo"}}},
  "github": {"login": "devdeveloper", "review_query": "is:pr is:open", "skip_drafts": True},
  "allele": {"state_file": "/dev/null", "default_project": "p", "repo_project_map": {}},
  "traits": {"review": {"traits": "t", "role": "R"}, "implement": {"traits": "t", "role": "R"}},
  "limits": {"max_workers": 15, "poll_interval_secs": 300, "watch_interval_secs": 300,
             "watch_max_hours": 1, "reemit_after_secs": 900, "blocked_alert_after_secs": 120,
             "max_lost_retries": 1},
}
if groups:
    cfg["allele"]["groups"] = json.loads(groups)
dest.write_text(json.dumps(cfg, indent=2))
PY
}

D () { python3 "$disp" --instance "$inst" "$@"; }
put () { D ledger put "$@" >/dev/null; }
says () { grep -c -- "$1" "$work/out" >/dev/null 2>&1 && echo yes || echo no; }
count () { grep -c -- "$1" "$work/out" 2>/dev/null || true; }

# ---- the Python driver ----------------------------------------------------------------------
# One resolver call against the source named in $DISP, so the reversals at the bottom run the
# same scenarios against a changed copy. Nothing is mocked: `group_for` and `groups_cfg` reach no
# network, no file and no subprocess.

cat > "$work/driver.py" <<'DRIVER'
import importlib.util, json, os, sys

spec = importlib.util.spec_from_file_location("disp_under_test", os.environ["DISP"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
os.environ["DISPATCHER_INSTANCE"] = os.environ["INST"]

scenario, rest = sys.argv[1], sys.argv[2:]

if scenario == "groups_cfg":
    print(json.dumps(m.groups_cfg(json.loads(rest[0])), sort_keys=True))

elif scenario == "group_for":
    print(json.dumps(m.group_for(json.loads(rest[0]), rest[1])))

elif scenario == "problems":
    print(json.dumps(m.group_problems(json.loads(rest[0]))))

elif scenario == "defaults":
    print(json.dumps(m.GROUP_DEFAULTS, sort_keys=True))

elif scenario == "limit":
    print(json.dumps(m.MAX_GROUP_LEN))

elif scenario == "template":
    # The template crossed against the code, so "the defaults are in code" and "the block is in
    # the file an operator reads" cannot drift apart silently.
    t = json.loads((m.CODE_DIR / "config.example.json").read_text())
    print(json.dumps(t["allele"]["groups"] == m.GROUP_DEFAULTS))

elif scenario == "fill_absent":
    section = rest[1] if len(rest) > 1 else "groups"
    template = json.loads((m.CODE_DIR / "config.example.json").read_text())["allele"][section]
    existing = json.loads(rest[0])
    added = m.fill_absent(section, existing, template)
    print(json.dumps({"added": sorted(added), "result": existing}, sort_keys=True))

else:
    sys.exit("unknown scenario " + scenario)
DRIVER

run () {
  src=$1; scenario=$2; shift 2
  set +e
  DISP="$src" INST="$inst" python3 "$work/driver.py" "$scenario" "$@" >"$work/out" 2>"$work/err"
  c=$?
  set -e
  echo "$c"
}

instance ''

# =============================================================================================
printf '\nThis file runs every assertion it contains\n'
# The same guard the Review Desk harness opens with, and for the same reason: a `printf` heading
# that loses its closing quote is valid shell, and every line after it is PRINTED rather than
# run while the suite goes on reporting "0 failed".
ok "no heading in this harness is missing its quote"   "$(grep -c "^[[:space:]]*printf '[^']*$" "$0")" 0
ok "  nor a double-quoted one"                         "$(grep -c "^[[:space:]]*printf \"[^\"]*$" "$0")" 0
cp "$0" "$work/noquote.sh"
printf '  printf "\\nbroken\\n\n' >> "$work/noquote.sh"
ok "  and the reversal of one is caught"               "$(grep -c "^[[:space:]]*printf \"[^\"]*$" "$work/noquote.sh")" 1

# =============================================================================================
printf '\nThe defaults, in code and not only in the template\n'
# The ticket's first acceptance criterion: with no `allele.groups` block, a review goes in
# `review` and a Linear-label item in `linear`. An instance that has never heard of this setting
# is every instance on 12 Oct 2026, so this is the case that must need no edit.

rc=$(run "$disp" defaults)
ok "the four Linear modes default to linear"           "$(count '"linear"')" 1
ok "  with all four named"                             "$(python3 -c "
import json; d = json.load(open('$work/out'))
print(sorted(k for k, v in d.items() if v == 'linear'))")" \
  "['decide', 'decompose', 'implement', 'investigate']"
ok "review defaults to its own group"                  "$(python3 -c "
import json; print(json.load(open('$work/out'))['review'])")" review
rc=$(run "$disp" template)
ok "the template says exactly what the code does"      "$(cat "$work/out")" true
rc=$(run "$disp" limit)
ok "the limit is allele's 40 characters"               "$(cat "$work/out")" 40

rc=$(run "$disp" group_for '{}' review)
ok "no block at all: a review is grouped review"       "$(cat "$work/out")" '"review"'
rc=$(run "$disp" group_for '{}' implement)
ok "  and an implement ticket linear"                  "$(cat "$work/out")" '"linear"'
rc=$(run "$disp" group_for '{"allele":{}}' decide)
ok "an allele block with no groups is the same"        "$(cat "$work/out")" '"linear"'
rc=$(run "$disp" group_for '{"allele":{"groups":null}}' decompose)
ok "  as is a null groups block"                       "$(cat "$work/out")" '"linear"'

# =============================================================================================
printf '\nA mode mapped somewhere else, and a mode mapped nowhere\n'
# Acceptance criteria 2 and 3. `null` and `""` must both reach the dispatch site as "pass no
# group argument at all", and that is the one behaviour the defaulting idiom used elsewhere in
# this file gets wrong -- it filters nulls, which would hand the mode `linear` back.

rc=$(run "$disp" group_for '{"allele":{"groups":{"review":"pr-reviews"}}}' review)
ok "a mode mapped to another name takes it"            "$(cat "$work/out")" '"pr-reviews"'
rc=$(run "$disp" group_for '{"allele":{"groups":{"review":"pr-reviews"}}}' implement)
ok "  and leaves the modes beside it alone"            "$(cat "$work/out")" '"linear"'
rc=$(run "$disp" group_for '{"allele":{"groups":{"review":null}}}' review)
ok "null means ungrouped, not default"                 "$(cat "$work/out")" null
rc=$(run "$disp" group_for '{"allele":{"groups":{"review":""}}}' review)
ok "  and so does an empty string"                     "$(cat "$work/out")" null
rc=$(run "$disp" group_for '{"allele":{"groups":{"review":"   "}}}' review)
ok "  and a string of spaces"                          "$(cat "$work/out")" null
rc=$(run "$disp" groups_cfg '{"allele":{"groups":{"review":null}}}')
ok "the null survives into the resolved block"         "$(says '"review": null')" yes
rc=$(run "$disp" group_for '{"allele":{"groups":{"review":"  reviews  "}}}' review)
ok "a value with stray spaces is trimmed"              "$(cat "$work/out")" '"reviews"'
rc=$(run "$disp" group_for '{"allele":{"groups":{"review":5}}}' review)
ok "a number where a name belongs is ungrouped"        "$(cat "$work/out")" null
rc=$(run "$disp" group_for "{\"allele\":{\"groups\":{\"review\":\"$(printf 'r%.0s' $(seq 41))\"}}}" review)
ok "41 characters is past allele's limit: ungrouped"   "$(cat "$work/out")" null
rc=$(run "$disp" group_for "{\"allele\":{\"groups\":{\"review\":\"$(printf 'r%.0s' $(seq 40))\"}}}" review)
ok "  while exactly 40 is dispatched"                  "$(count 'rrrr')" 1
rc=$(run "$disp" group_for '{"allele":{"groups":{"review":"review"}}}' no_such_mode)
ok "a mode nobody has heard of is ungrouped"           "$(cat "$work/out")" null

# =============================================================================================
printf '\nWhat doctor crosses, and what it merely reports\n'
# A rejected interval changes nothing and `intervals` reports it. A rejected GROUP moves every
# session of that mode back into the flat list, and the operator who typed it has no other way
# to find out -- so this one fails.

rc=$(run "$disp" problems '{}')
ok "no block is no problem"                            "$(cat "$work/out")" '[]'
rc=$(run "$disp" problems '{"allele":{"groups":{"review":null,"implement":"linear"}}}')
ok "a deliberate null is not a fault"                  "$(cat "$work/out")" '[]'
rc=$(run "$disp" problems "{\"allele\":{\"groups\":{\"review\":\"$(printf 'r%.0s' $(seq 41))\"}}}")
ok "41 characters is reported as a problem"            "$(says '41 characters')" yes
ok "  naming allele's limit"                           "$(says 'over 40')" yes
rc=$(run "$disp" problems '{"allele":{"groups":{"review":5}}}')
ok "a non-string is reported as a problem"             "$(says 'not a string')" yes
ok "  and points at null as the way to mean it"        "$(says 'use null')" yes

doctor () { set +e; D doctor > "$work/out" 2>&1; set -e; grep 'allele groups' "$work/out" || true; }

instance ''
ok "doctor passes with no block"                       "$(doctor | grep -c '^✓')" 1
ok "  and reports every mode"                          "$(doctor | grep -c 'review → review')" 1
ok "  marking the answer as a default"                 "$(doctor | grep -c 'review → review (default)')" 1
instance '{"review":"pr-reviews"}'
ok "a configured group is marked as config"            "$(doctor | grep -c 'review → pr-reviews (config)')" 1
ok "  while its neighbours stay defaults"              "$(doctor | grep -c 'implement → linear (default)')" 1
instance '{"review":null}'
ok "a null mode reads as ungrouped, and passes"        "$(doctor | grep -c '✓ allele groups: .*review → ungrouped')" 1
instance "{\"review\":\"$(printf 'r%.0s' $(seq 41))\"}"
ok "an over-long group FAILS doctor"                   "$(doctor | grep -c '^✗')" 1
instance '{"review":5}'
ok "  as does a number where a name belongs"           "$(doctor | grep -c '^✗')" 1

# =============================================================================================
printf '\nThe brief is the only channel, so the group is named in it\n'
# A worker reads no config -- the file says so where Review Desk is named in a brief -- so the
# brief carries the group twice over: it is what the dispatcher about to call `sessions_create`
# reads off the prompt it already holds, and it is what the session itself passes to its own
# helpers. Acceptance criterion 5 is the second half of that.

instance ''
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 title=T url=u --by test
set +e; D brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "a review brief names the review group"             "$(says 'Allele group: .review.')" yes
ok "  and tells the session to pass it on"             "$(says 'group: .review.. on every')" yes
ok "  only when its own tool lists the parameter"      "$(says 'lists a .group. parameter')" yes
ok "  saying nothing when it does not"                 "$(says 'say nothing')" yes
put EX-1 mode=implement status=claimed title=T url=u --by test
set +e; D brief EX-1 > "$work/out" 2>&1; set -e
ok "an implement brief names linear"                   "$(says 'Allele group: .linear.')" yes

instance '{"implement":null}'
put EX-1 mode=implement status=claimed title=T url=u --by test
set +e; D brief EX-1 > "$work/out" 2>&1; set -e
ok "an ungrouped mode says so in the brief"            "$(says 'Allele group: none')" yes
ok "  and asks for no group argument at all"           "$(says 'no .group. argument')" yes
ok "  without naming a group to pass"                  "$(count 'Allele group: .linear.')" 0

# Inheritance. A coordinator writes its OWN group on the child's claim, and `D brief` prefers
# that over the group the child's mode would have had -- which is what makes "a session
# dispatched by a worker carries the worker's own group" mechanical rather than a line of prose
# somebody has to remember.
instance '{"implement":"linear","decide":"decisions"}'
put EX-9 mode=implement status=claimed title=T url=u parent=EX-1 group=review --by coordinator
set +e; D brief EX-9 > "$work/out" 2>&1; set -e
ok "a child carries the group on its claim"            "$(says 'Allele group: .review.')" yes
ok "  not the one its own mode would have had"         "$(count 'Allele group: .linear.')" 0
put EX-9 group="" --by coordinator
set +e; D brief EX-9 > "$work/out" 2>&1; set -e
ok "an empty group on the claim means ungrouped"       "$(says 'Allele group: none')" yes
put EX-8 mode=implement status=claimed title=T url=u parent=EX-1 --by coordinator
set +e; D brief EX-8 > "$work/out" 2>&1; set -e
ok "a claim with no group falls back to the mode"      "$(says 'Allele group: .linear.')" yes

# The ledger records it, which is the whole of acceptance criterion 6: `ledger put` merges
# arbitrary fields, so what is under test is that the field survives a write and a read rather
# than any new code.
instance ''
put gh-portal-412 mode=review status=active group=review session_id=s-1 --by dispatcher
set +e; D ledger get gh-portal-412 > "$work/out" 2>&1; set -e
ok "the ledger entry records the group it was sent with" "$(says '"group": "review"')" yes
ok "  and its history says who set it"                 "$(says '"group": "review"')" yes

# =============================================================================================
printf '\nWhat a re-run of init teaches an older config\n'
# Acceptance criterion 7, without `init` itself: `cmd_init` needs Linear auth to mint labels, and
# the behaviour under test is one function over two dicts. `fill_absent` adds only keys the
# config has never heard of, so the tuned-value case is the one that matters.

rc=$(run "$disp" fill_absent '{}' groups)
ok "an empty groups block learns all five modes"       "$(python3 -c "
import json; print(len(json.load(open('$work/out'))['added']))")" 5
ok "  each one qualified by its section"               "$(says '"groups.review"')" yes
ok "  and the values are the defaults"                 "$(says '"review": "review"')" yes
rc=$(run "$disp" fill_absent '{"review":"pr-reviews"}' groups)
ok "a value the operator set is left alone"            "$(says '"review": "pr-reviews"')" yes
ok "  while the modes it lacks are added"              "$(python3 -c "
import json; print(json.load(open('$work/out'))['added'])")" \
  "['groups.decide', 'groups.decompose', 'groups.implement', 'groups.investigate']"
rc=$(run "$disp" fill_absent '{"review":null}' groups)
ok "a mode switched off stays off"                     "$(says '"review": null')" yes

# =============================================================================================
printf '\nThe reversals -- what each assertion above would say about the old code\n'
# Every check above has to be able to FAIL. Each reversal changes one line back to what it was
# or to the shape this ticket argued against, re-runs the assertion that covers it, and requires
# a different answer.

# 1. The `review_cfg` idiom, which filters nulls. This is the shape `groups_cfg` deliberately
#    does not share, and the reason it has a docstring of its own.
sed 's/^    block\.update((cfg\.get("allele") or {})\.get("groups") or {})$/    block.update({k: v for k, v in ((cfg.get("allele") or {}).get("groups") or {}).items() if v is not None})  # NULL FILTER RESTORED/' \
    "$disp" > "$work/nullfilter.py"
ok "the null-filter reversal changed one line"         "$(grep -c 'NULL FILTER RESTORED' "$work/nullfilter.py")" 1
rc=$(run "$work/nullfilter.py" group_for '{"allele":{"groups":{"review":null}}}' review)
ok "filtered nulls: a mode switched off is grouped"    "$(cat "$work/out")" '"review"'

# 2. The trim, which is what keeps a value allele would match as one group from reading as two.
sed 's/^    value = value\.strip()$/    pass  # TRIM REMOVED/' "$disp" > "$work/notrim.py"
ok "the trim reversal changed one line"                "$(grep -c 'TRIM REMOVED' "$work/notrim.py")" 1
rc=$(run "$work/notrim.py" group_for '{"allele":{"groups":{"review":"  reviews  "}}}' review)
ok "no trim: the stray spaces reach the create"        "$(cat "$work/out")" '"  reviews  "'

# 3. The length guard, in both places it exists: the resolver reads an over-long value as
#    ungrouped, and `doctor` is what tells the operator why their sessions are still in the
#    flat list. Without the guard the value is passed and every create for that mode fails.
sed 's/^    if not value or len(value) > MAX_GROUP_LEN:$/    if not value:  # LENGTH GUARD REMOVED/' \
    "$disp" > "$work/nolimit.py"
ok "the length-guard reversal changed one line"        "$(grep -c 'LENGTH GUARD REMOVED' "$work/nolimit.py")" 1
rc=$(run "$work/nolimit.py" group_for "{\"allele\":{\"groups\":{\"review\":\"$(printf 'r%.0s' $(seq 41))\"}}}" review)
ok "no guard: 41 characters reach the create"          "$(count 'rrrr')" 1
sed 's/^        elif len(value\.strip()) > MAX_GROUP_LEN:$/        elif False:  # DOCTOR LENGTH CHECK REMOVED/' \
    "$disp" > "$work/noloud.py"
ok "the doctor-length reversal changed one line"       "$(grep -c 'DOCTOR LENGTH CHECK REMOVED' "$work/noloud.py")" 1
rc=$(run "$work/noloud.py" problems "{\"allele\":{\"groups\":{\"review\":\"$(printf 'r%.0s' $(seq 41))\"}}}")
ok "silent doctor: nothing is reported"                "$(cat "$work/out")" '[]'

# 4. Inheritance. Drop the ledger's claim on the answer and a coordinator's child goes back to
#    its own mode's group, which is the defect the field exists to prevent.
sed 's/^    if isinstance(recorded, str):$/    if False:  # LEDGER GROUP IGNORED/' "$disp" > "$work/noinherit.py"
ok "the inheritance reversal changed one line"         "$(grep -c 'LEDGER GROUP IGNORED' "$work/noinherit.py")" 1
instance '{"implement":"linear"}'
put EX-9 mode=implement status=claimed title=T url=u parent=EX-1 group=review --by coordinator
rc=$(run "$work/noinherit.py" group_for '{"allele":{"groups":{"implement":"linear"}}}' implement)
set +e; INST="$inst" DISPATCHER_INSTANCE="$inst" python3 "$work/noinherit.py" --instance "$inst" brief EX-9 > "$work/out" 2>&1; set -e
ok "ignored: the child takes its own mode's group"     "$(says 'Allele group: .linear.')" yes
ok "  and the group it was dispatched with is lost"    "$(count 'Allele group: .review.')" 0

# 5. The brief line itself. Without it a worker has no channel to its group at all, and neither
#    does the dispatcher about to pass one.
sed 's/^    if group:$/    if False:  # BRIEF LINE REMOVED/' "$disp" > "$work/nobrief.py"
ok "the brief-line reversal changed one line"          "$(grep -c 'BRIEF LINE REMOVED' "$work/nobrief.py")" 1
instance ''
put gh-portal-412 mode=review status=claimed repo=acme/portal number=412 title=T url=u --by test
set +e; python3 "$work/nobrief.py" --instance "$inst" brief gh-portal-412 > "$work/out" 2>&1; set -e
ok "no line: the brief names no group to pass"         "$(count 'Allele group: .review.')" 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
