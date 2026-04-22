#!/usr/bin/env bash
# Locus statusline for Claude Code.
#
# Two-line layout. Reads the Claude Code status JSON from stdin and prints:
#
#   <cwd-basename>  [<git-branch><dirty>]   <model>
#   ctx <bar> <pct>%   5h <bar> <pct>% (resets in <ttl>)   [PRD: <slug> <done>/<total>]
#
# Data sources:
#   - stdin JSON from Claude Code                  (cwd, model, context %)
#   - local git state                              (branch, dirty)
#   - Anthropic OAuth usage API (cached)           (5-hour window)
#   - ~/.locus/data/memory/state/work.json         (active PRD — written by
#                                                   `locus hook post-tool-use`)
#
# Usage cache: ~/.locus/data/memory/state/usage-cache.json (TTL 60s, refreshed
# in the background so the statusline never blocks).

set -o pipefail

LOCUS_HOME="${LOCUS_HOME:-$HOME/.locus}"
STATE_DIR="$LOCUS_HOME/data/memory/state"
WORK_JSON="$STATE_DIR/work.json"
USAGE_CACHE="$STATE_DIR/usage-cache.json"
USAGE_TTL=60

mkdir -p "$STATE_DIR" 2>/dev/null

input=$(cat)

# ─── Parse stdin JSON ────────────────────────────────────────────────────────
eval "$(printf '%s' "$input" | jq -r '
  "cwd=" + (.workspace.current_dir // .cwd // "." | @sh) + "\n" +
  "model=" + (.model.display_name // "claude" | @sh) + "\n" +
  "ctx_pct=" + (.context_window.used_percentage // 0 | tostring)
' 2>/dev/null)"

cwd="${cwd:-.}"
model="${model:-claude}"
ctx_pct="${ctx_pct:-0}"
dir_name=$(basename "$cwd")

# ─── Git branch + dirty ──────────────────────────────────────────────────────
branch=""
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
             || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    if ! git -C "$cwd" diff --quiet 2>/dev/null \
       || ! git -C "$cwd" diff --cached --quiet 2>/dev/null; then
        branch="${branch}*"
    fi
fi

# ─── Bar helpers ─────────────────────────────────────────────────────────────
# 10-cell block-graphics bar.
render_bar() {
    local pct="$1"
    local fill
    fill=$(awk -v p="$pct" 'BEGIN{printf "%d", (p/10)+0.5}')
    [ "$fill" -gt 10 ] && fill=10
    [ "$fill" -lt 0 ] && fill=0
    local bar=""
    for i in $(seq 1 10); do
        if [ "$i" -le "$fill" ]; then bar="${bar}█"; else bar="${bar}░"; fi
    done
    printf '%s' "$bar"
}

# ANSI colour by utilisation: green < 50%, yellow < 80%, red ≥ 80%.
bar_colour() {
    local pct="$1"
    local v
    v=$(awk -v p="$pct" 'BEGIN{printf "%d", p}')
    if   [ "$v" -ge 80 ]; then printf '\033[0;31m'
    elif [ "$v" -ge 50 ]; then printf '\033[0;33m'
    else                       printf '\033[0;32m'
    fi
}

ctx_bar=$(render_bar "$ctx_pct")
ctx_display=$(awk -v p="$ctx_pct" 'BEGIN{printf "%d", p}')
ctx_colour=$(bar_colour "$ctx_pct")

# ─── 5-hour usage window (cache-first, refresh in background) ────────────────
get_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

refresh_usage_async() {
    (
        token=""
        if command -v security >/dev/null 2>&1; then
            keychain_data=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
            token=$(printf '%s' "$keychain_data" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('claudeAiOauth',{}).get('accessToken',''))
except Exception:
    pass
" 2>/dev/null)
        fi
        [ -z "$token" ] && exit 0

        usage_json=$(curl -s --max-time 3 \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -H "anthropic-beta: oauth-2025-04-20" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

        if [ -n "$usage_json" ] && printf '%s' "$usage_json" | jq -e '.five_hour' >/dev/null 2>&1; then
            printf '%s' "$usage_json" | jq '.' > "$USAGE_CACHE.tmp" 2>/dev/null \
                && mv "$USAGE_CACHE.tmp" "$USAGE_CACHE"
        fi
    ) </dev/null >/dev/null 2>&1 &
}

now=$(date +%s)
cache_age=999999
[ -f "$USAGE_CACHE" ] && cache_age=$((now - $(get_mtime "$USAGE_CACHE")))
[ "$cache_age" -gt "$USAGE_TTL" ] && refresh_usage_async

usage_seg=""
if [ -f "$USAGE_CACHE" ]; then
    eval "$(jq -r '
        "u_pct=" + (.five_hour.utilization // 0 | tostring) + "\n" +
        "u_reset=" + (.five_hour.resets_at // "" | @sh)
    ' "$USAGE_CACHE" 2>/dev/null)"
    u_pct="${u_pct:-0}"
    u_bar=$(render_bar "$u_pct")
    u_display=$(awk -v p="$u_pct" 'BEGIN{printf "%d", p}')
    u_colour=$(bar_colour "$u_pct")
    reset_hm=""
    if [ -n "$u_reset" ]; then
        reset_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${u_reset%.*}Z" +%s 2>/dev/null \
                      || date -u -d "$u_reset" +%s 2>/dev/null)
        if [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt "$now" ]; then
            secs=$((reset_epoch - now))
            h=$((secs / 3600))
            m=$(((secs % 3600) / 60))
            if [ "$h" -gt 0 ]; then reset_hm="${h}h${m}m"; else reset_hm="${m}m"; fi
        fi
    fi
    if [ -n "$reset_hm" ]; then
        usage_seg="5h ${u_colour}${u_bar}\033[0m ${u_display}% (resets in ${reset_hm})"
    else
        usage_seg="5h ${u_colour}${u_bar}\033[0m ${u_display}%"
    fi
fi

# ─── Active PRD (if one matches this cwd) ────────────────────────────────────
prd_seg=""
if [ -f "$WORK_JSON" ]; then
    prd_seg=$(jq -r --arg cwd "$cwd" '
        [.sessions // {} | to_entries[] | select(.value.path | startswith($cwd))]
        | sort_by(.value.updated) | reverse | .[0]
        | if . == null then "" else "PRD: " + .value.slug + " " + .value.progress end
    ' "$WORK_JSON" 2>/dev/null)
fi

# ─── Compose two lines ───────────────────────────────────────────────────────
# Line 1: location + model
line1="\033[1;36m${dir_name}\033[0m"
[ -n "$branch" ] && line1+="  \033[0;33m[${branch}]\033[0m"
line1+="   \033[0;37m${model}\033[0m"

# Line 2: metrics
line2="\033[0;37mctx\033[0m ${ctx_colour}${ctx_bar}\033[0m ${ctx_display}%"
[ -n "$usage_seg" ] && line2+="   \033[0;37m${usage_seg}\033[0m"
[ -n "$prd_seg" ]   && line2+="   \033[0;36m${prd_seg}\033[0m"

printf "%b\n%b" "$line1" "$line2"
