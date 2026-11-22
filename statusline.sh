#!/bin/sh
# Claude Code status line: model, folder, and plan usage (5-hour session and
# 7-day week) with a pace indicator for each. Same output as statusline.ps1.
#
# Reads the JSON Claude Code passes on stdin and uses only its rate_limits
# data. No network, no credentials, no token counting.
#
# Needs only sh, date and awk, which every Mac has (no jq, no Python). The
# fields it reads are flat, so it picks them out of the JSON with patterns.

now=$(date +%s)

out=$(awk -v now="$now" '
function paint(code, text) { return "\033[" code "m" text "\033[0m" }

# "key": "text"  ->  text ("" when absent)
function strval(text, key,   s) {
    if (!match(text, "\"" key "\"[ \t]*:[ \t]*\"([^\"\\\\]|\\\\.)*\"")) return ""
    s = substr(text, RSTART, RLENGTH)
    sub(/^"[^"]*"[ \t]*:[ \t]*"/, "", s)
    sub(/"$/, "", s)
    return s
}

# "key": { ... } with no nested braces  ->  the whole match ("" when absent)
function objval(text, key) {
    if (!match(text, "\"" key "\"[ \t]*:[ \t]*[{][^}]*[}]")) return ""
    return substr(text, RSTART, RLENGTH)
}

# "key": 12.5  ->  12.5 ("" when absent or not a number)
function numval(text, key,   s) {
    if (!match(text, "\"" key "\"[ \t]*:[ \t]*-?[0-9]+([.][0-9]+)?")) return ""
    s = substr(text, RSTART, RLENGTH)
    sub(/^[^:]*:[ \t]*/, "", s)
    return s
}

function rnd(x) { return x < 0 ? -int(-x + 0.5) : int(x + 0.5) }

function repeat(s, n,   i, r) { r = ""; for (i = 0; i < n; i++) r = r s; return r }

function left(secs,   m, d, h, mm) {
    m = int(secs / 60)
    if (m < 1) return "<1m"
    d = int(m / 1440); h = int((m % 1440) / 60); mm = m % 60
    if (d >= 1) return d "d " h "h"
    if (h >= 1) return h "h " mm "m"
    return mm "m"
}

function window(label, o, len,   missing, used, reset, shown, filled, txt, remaining, elapsed, diff, points, colour, pace) {
    missing = paint(GREY, label " -")
    if (o == "") return missing

    used = numval(o, "used_percentage")
    if (used == "") return missing
    used += 0

    reset = numval(o, "resets_at")
    # A window whose reset time has passed holds the numbers of the last window.
    if (reset != "" && reset + 0 <= now) return missing

    shown = used; if (shown < 0) shown = 0; if (shown > 100) shown = 100
    filled = rnd(shown / 100 * CELLS)
    txt = label " " rnd(used) "% " repeat("█", filled) paint(GREY, repeat("░", CELLS - filled))

    if (reset == "") return txt

    remaining = reset - now; if (remaining > len) remaining = len
    elapsed = (len - remaining) / len * 100
    diff = used - elapsed
    points = rnd(diff)

    if (diff <= SLACK && diff >= -SLACK) colour = GREY
    else if (diff < 0) colour = GREEN
    else colour = ORANGE

    pace = (points > 0 ? "+" : "") points "%"

    return txt " " paint(colour, pace) " " paint(GREY, "· " left(remaining) " left")
}

{ text = text " " $0 }

END {
    GREY = "90"; GREEN = "32"; ORANGE = "38;5;208"
    CELLS = 8      # bar width
    SLACK = 3      # points either side that count as "on pace"
    now += 0

    model = strval(objval(text, "model"), "display_name")
    if (model == "") model = "Claude"

    dir = strval(text, "current_dir")
    if (dir == "") dir = strval(text, "cwd")
    gsub(/\\+/, "/", dir)         # Windows paths arrive as C:\\Users\\...
    sub(/\/+$/, "", dir)
    folder = dir
    sub(/^.*\//, "", folder)
    if (folder == "") folder = dir

    head = model
    if (folder != "") head = head " " paint(GREY, "·") " " folder

    bar = paint(GREY, "│")
    printf "%s %s %s %s %s\n", head, bar, \
        window("session", objval(text, "five_hour"), 5 * 3600), bar, \
        window("week", objval(text, "seven_day"), 7 * 86400)
}
' 2>/dev/null)

# Never show an error or a blank line.
[ -n "$out" ] || out='Claude'
printf '%s\n' "$out"
exit 0
