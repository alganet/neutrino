#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-linux.sh - External test verifier for Linux (the GTK lanes and kde)

set -euo pipefail

TIMEOUT=60
POLL_INTERVAL=0.5
SCREENSHOT_DIR="${1:-.}"
FAILURES=0

mkdir -p "$SCREENSHOT_DIR"

# The root window: the whole desktop, with the app somewhere on it. Every
# verifier here frames its pictures that way, so a sheet can be read across
# lanes and so anything sitting on top of the app is in the shot rather than
# cropped out of it. This lane never did anything else; verify-macos.sh and the
# two Windows halves carry the long version of why they stopped.
screenshot() {
    import -window root "$SCREENSHOT_DIR/${1}.png" 2>/dev/null || true
}

# The window manager's own list of managed top-levels first, and `xdotool
# search` only as a fallback -- the same order and the same reason verify-std.sh
# gives at length. xdotool matches any window carrying the name, and GTK gives
# that name to more than the toplevel: on the metacity lane the search returned
# a window whose offset inside its parent was 26,60 while the decoration is
# 0,37. An inner window, measured as though it were the frame.
#
# This file never noticed because its position assertion allowed a hundred
# pixels, which is wider than the disagreement. So the window-finding is fixed
# before the tolerance is touched and not after: a zero asserted against the
# wrong window is a red run about the instrument, and the instrument is what
# this line is.
# Written to a file and not to a variable. Every caller is `WID=$(wait_for_title
# ...)`, which is a subshell, so an assignment inside it is gone before the
# caller reads it -- the first round of this reported `wid_src=?` on every lane
# and would have gone on doing so, which is an instrument reporting on itself
# and getting it wrong.
WID_SRC_FILE="$(mktemp)"
trap 'rm -f "$WID_SRC_FILE"' EXIT
wid_src() { cat "$WID_SRC_FILE" 2>/dev/null || echo "?"; }

# The window manager's own name, because where `moveTo` puts a frame is its
# decision and the two this project runs under decide differently. Measured,
# same request, same probe, one round:
#
#   metacity   moveTo(0,0) -> frame at 0,37   (extents 0,0,37,0)
#   openbox    moveTo(0,0) -> frame at 0,0    (extents 1,1,25,1)
#
# So there is no rule to derive and nothing to be clever about: openbox honours
# the request and metacity offsets it by its own title bar. WEBSTD.md has said
# `moveTo` has no portable meaning and to assert per lane to measured values
# since the round that found it, and this is that.
wm_name() {
    local check
    check=$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | sed -n 's/.*# *\(0x[0-9a-fA-F]*\).*/\1/p' | head -1)
    [ -n "$check" ] || { echo "?"; return; }
    xprop -id "$check" _NET_WM_NAME 2>/dev/null | sed -n 's/.*= *"\(.*\)"/\1/p' | head -1
}

x11_toplevels() {
    xprop -root _NET_CLIENT_LIST 2>/dev/null |
        sed -n 's/.*# *//p' | tr ',' '\n' | tr -d ' ' | grep '^0x'
}

wait_for_title() {
    local expected="$1"
    local deadline=$((SECONDS + TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        local wid name
        for wid in $(x11_toplevels); do
            name=$(xdotool getwindowname "$((wid))" 2>/dev/null) || true
            case "$name" in
                *"$expected"*) echo "_NET_CLIENT_LIST" > "$WID_SRC_FILE"; echo "$((wid))"; return 0 ;;
            esac
        done
        wid=$(xdotool search --name "$expected" 2>/dev/null | head -1) || true
        if [ -n "$wid" ]; then
            echo "xdotool-search" > "$WID_SRC_FILE"
            echo "$wid"
            return 0
        fi
        sleep $POLL_INTERVAL
    done
    echo "TIMEOUT waiting for title: $expected" >&2
    return 1
}

assert_title() {
    local wid="$1" expected="$2"
    local actual
    actual=$(xdotool getwindowname "$wid" 2>/dev/null) || true
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: title = '$expected'"
    else
        echo "  FAIL: title expected='$expected' actual='$actual'"
        FAILURES=$((FAILURES + 1))
    fi
}

# The requested size, exactly, unless a caller asks for slack.
#
# xdotool's WIDTH/HEIGHT is the client size -- the same quantity the standards
# probe calls `inner`, read with the same tool on these same four lanes -- and
# every driver they run sizes the content: the probe asked for 640x480 and the
# window reported native inner 640x480 on GTK and on Qt, to the pixel.
#
# So the fifty pixels this allowed were never covering a difference between
# toolkits. They were covering the fact that nothing had measured either side,
# and fifty admits a whole title bar -- which is exactly the difference macOS
# carried, unnoticed, for as long as its driver sized the frame while every
# other sized the content. Zero is what turns a drift in either direction into
# a failure instead of a shrug.
assert_geometry() {
    local wid="$1" expected_w="$2" expected_h="$3" tolerance="${4:-0}"
    local info size actual_w actual_h
    info=$(xdotool getwindowgeometry "$wid" 2>/dev/null) || true
    size=$(echo "$info" | grep -oP 'Geometry: \K[0-9]+x[0-9]+') || true
    actual_w="${size%x*}"; actual_h="${size#*x}"
    local dw=$(( actual_w - expected_w )); dw=${dw#-}
    local dh=$(( actual_h - expected_h )); dh=${dh#-}
    if [ "$dw" -le "$tolerance" ] && [ "$dh" -le "$tolerance" ]; then
        echo "  PASS: content = ${actual_w}x${actual_h} (asked ${expected_w}x${expected_h}, tolerance ${tolerance})"
    else
        echo "  FAIL: content expected ${expected_w}x${expected_h} actual=${actual_w}x${actual_h}, off by ${dw}x${dh} (tolerance ${tolerance})"
        FAILURES=$((FAILURES + 1))
    fi
}

# The frame origin, exactly, against what this window manager was measured to do.
#
# `gtk_window_move` positions the *frame*; xdotool's Position is the *client*
# origin, and their difference is the reparenting offset -- 26,60 under metacity
# and 1,20 under openbox. That difference is what the hundred pixels here were
# paying for. The frame origin is derived from it, the way verify-std.sh has
# derived it all along, and the derivation is what gets asserted.
#
# An unmeasured window manager is a failure and not a default. It is the one
# outcome this file cannot have an answer for: guessing 0,0 would pass silently
# under openbox and fail confusingly under anything metacity-like. The reading
# is printed either way, so the round that meets a new one can add its row.
assert_position() {
    local wid="$1" expected_x="$2" expected_y="$3"
    local info pos actual_x actual_y rx ry derived="?"
    info=$(xdotool getwindowgeometry "$wid" 2>/dev/null) || true
    pos=$(echo "$info" | grep -oP 'Position: \K[0-9]+,[0-9]+') || true
    actual_x="${pos%,*}"; actual_y="${pos#*,}"
    local xw
    xw=$(xwininfo -id "$wid" 2>/dev/null) || true
    rx=$(printf '%s' "$xw" | sed -n 's/.*Relative upper-left X: *\([0-9-]*\).*/\1/p' | head -1)
    ry=$(printf '%s' "$xw" | sed -n 's/.*Relative upper-left Y: *\([0-9-]*\).*/\1/p' | head -1)
    case "${rx:-x}${ry:-x}" in
        *[!0-9-]*|"") ;;
        *) derived="$(( actual_x - rx )),$(( actual_y - ry ))" ;;
    esac
    local wm; wm="$(wm_name)"
    echo "report: position raw=${actual_x},${actual_y} rel=${rx:-?},${ry:-?} derived=${derived} wm=${wm} wid_src=$(wid_src)"

    if [ "$derived" = "?" ]; then
        echo "  FAIL: no reparent offset, so the frame origin cannot be derived; the raw client origin is ${actual_x},${actual_y}"
        FAILURES=$((FAILURES + 1))
        return
    fi

    # The offset each window manager applies to a move request, measured. The
    # request is added to it, so a probe that moves somewhere other than 0,0
    # still reads off this table.
    local off_x off_y
    case "$wm" in
        Metacity|metacity) off_x=0; off_y=37 ;;
        Openbox|openbox)   off_x=0; off_y=0  ;;
        *)
            echo "  FAIL: window manager '${wm}' has not been measured here; moveTo(${expected_x},${expected_y}) put the frame at ${derived} -- add the row once that is confirmed to be what it always does"
            FAILURES=$((FAILURES + 1))
            return
            ;;
    esac

    local want="$(( expected_x + off_x )),$(( expected_y + off_y ))"
    if [ "$derived" = "$want" ]; then
        echo "  PASS: frame origin = ${derived} (asked ${expected_x},${expected_y}; ${wm} offsets by ${off_x},${off_y})"
    else
        echo "  FAIL: frame origin expected ${want} actual=${derived} under ${wm} (asked ${expected_x},${expected_y}); raw client origin ${actual_x},${actual_y}, reparent offset ${rx},${ry}"
        FAILURES=$((FAILURES + 1))
    fi
}

# --- Test steps ---

echo "=== Waiting for window ==="
WID=$(wait_for_title "neutrino") || { echo "FAIL: window never appeared"; exit 1; }
echo "Window found: $WID"
screenshot "00-initial"

echo "=== Step 0: Ready ==="
WID=$(wait_for_title "STEP0") || { echo "FAIL: STEP0 never reached"; exit 1; }
assert_title "$WID" "STEP0"
screenshot "01-step0"

echo "=== Step 1: title ==="
WID=$(wait_for_title "STEP1-Test Title") || { echo "FAIL: STEP1 never reached"; exit 1; }
assert_title "$WID" "STEP1-Test Title"
screenshot "02-step1"

echo "=== Step 2: resize ==="
WID=$(wait_for_title "STEP2") || { echo "FAIL: STEP2 never reached"; exit 1; }
assert_geometry "$WID" 500 400
screenshot "03-step2"

echo "=== Step 3: move ==="
WID=$(wait_for_title "STEP3") || { echo "FAIL: STEP3 never reached"; exit 1; }
assert_position "$WID" 0 0
screenshot "04-step3"

echo "=== Step 4: the desktop's palette ==="
# The app does the checking -- it is the only side that can see the palette --
# and this waits on its verdict. A lane that reached no toolkit reports null and
# never sets THEMEOK, so the timeout here is the failure rather than a pass with
# nothing behind it. The reading itself is on screen in the shot below.
WID=$(wait_for_title "THEMEOK") || {
    echo "  FAIL: the palette was not readable on this lane (see 05-theme.png)"
    FAILURES=$((FAILURES + 1))
}
screenshot "05-theme"

echo "=== Waiting for TESTS DONE ==="
WID=$(wait_for_title "TESTS DONE") || { echo "FAIL: tests never completed"; exit 1; }
screenshot "06-done"

echo ""
echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
