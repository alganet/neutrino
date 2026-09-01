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

# The window manager's own name. It used to decide what `assert_position` was
# allowed to expect, against a table that said metacity offsets a move by its
# own title bar and openbox honours it exactly. Neither of those was ever a
# fact about a window manager -- see `assert_position`, which now asserts one
# rule on both -- so what this is for is the report line: a lane meeting a
# window manager nobody here has run says which one it was.
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

# The decoration's thickness, as the window manager publishes it: left, right,
# top, bottom. It is the quantity the pictures agree with -- metacity's frame
# reads `0,0,37,0` and its title bar measures 37 rows in 04-step3.png, openbox's
# reads `1,1,20,5` and its border is one column wide.
frame_extents() {
    local wid="$1" line out=""
    line="$(xprop -id "$wid" _NET_FRAME_EXTENTS 2>/dev/null)"
    case "$line" in
        *=*)
            line="${line#*= }"
            out="$(echo "$line" | cut -d, -f1 | tr -d ' '),$(echo "$line" | cut -d, -f2 | tr -d ' '),$(echo "$line" | cut -d, -f3 | tr -d ' '),$(echo "$line" | cut -d, -f4 | tr -d ' ')"
            ;;
    esac
    case "$out" in
        *[!0-9,]*|""|,,,) echo "" ;;
        *) echo "$out" ;;
    esac
}

# Whether anything framed this window at all, asked of the tree rather than of
# the hint -- the same question verify-std.sh asks, for the same reason: a
# missing hint is a reading only once something else says the window has no
# frame. 0 framed, 1 nothing framed it, 2 the tree could not be read.
framed() {
    local wid="$1" tree parent rootw
    tree="$(xwininfo -id "$wid" -tree 2>/dev/null)"
    [ -n "$tree" ] || return 2
    parent="$(printf '%s' "$tree" | sed -n 's/.*Parent window id: *\(0x[0-9a-fA-F]*\).*/\1/p' | head -1)"
    rootw="$(printf '%s' "$tree" | sed -n 's/.*Root window id: *\(0x[0-9a-fA-F]*\).*/\1/p' | head -1)"
    [ -n "$parent" ] && [ -n "$rootw" ] || return 2
    [ "$((parent))" != "$((rootw))" ]
}

# The frame's outside corner -- the corner a person can see -- against the
# position the app asked for. One rule, both window managers, no table.
#
# The table this replaces said metacity offsets a move by its own title bar and
# openbox honours it exactly, and it was derived as `xdotool's Position minus
# xwininfo's Relative upper-left`. Every piece of that is the client corner
# wearing a frame's name, and both sheets from run 33484835636 say so:
#
#   gjs, metacity, 04-step3.png -- decoration at 0,0, content at 0,37.
#     raw=26,97 rel=26,60, so the old formula printed `frame origin = 0,37` and
#     the table called that 37 metacity adding its title bar to the request.
#     The frame is at 0,0, where the app asked for it. 0,37 is the client.
#
#   kde, openbox, 04-step3.png -- content at 0,0 and the decoration nowhere on
#     the display. raw=1,20 rel=1,20, so the old formula printed `frame origin
#     = 0,0` and passed a window whose title bar and left border are off the
#     top-left of the screen. Extents `1,1,20,5` put that frame at -1,-20.
#
# xdotool's Position already carries the reparenting offset -- measured beside
# xwininfo's absolute on both lanes, `88,181` against `62,121` under metacity
# and `63,104` against `62,84` under openbox -- so subtracting the offset from
# it lands back on the client corner every time. The two window managers were
# never disagreeing about what a move means. The two *drivers* were, and the
# table wrote one lane's defect down as a property of the other lane's window
# manager, which is why this file passed the picture the fix was needed for.
#
# So: the client corner from xwininfo, the decoration's thickness from the
# hint, and the frame is the first minus the second. Both routes are printed,
# because the next round deserves the numbers and not the conclusion.
assert_position() {
    local wid="$1" expected_x="$2" expected_y="$3"
    local info pos raw="?" xw ax ay rx ry ext ext_src l t frame="?" wm fr
    info=$(xdotool getwindowgeometry "$wid" 2>/dev/null) || true
    pos=$(echo "$info" | grep -oP 'Position: \K-?[0-9]+,-?[0-9]+') || true
    [ -n "$pos" ] && raw="$pos"
    xw=$(xwininfo -id "$wid" 2>/dev/null) || true
    ax=$(printf '%s' "$xw" | sed -n 's/.*Absolute upper-left X: *\([0-9-]*\).*/\1/p' | head -1)
    ay=$(printf '%s' "$xw" | sed -n 's/.*Absolute upper-left Y: *\([0-9-]*\).*/\1/p' | head -1)
    rx=$(printf '%s' "$xw" | sed -n 's/.*Relative upper-left X: *\([0-9-]*\).*/\1/p' | head -1)
    ry=$(printf '%s' "$xw" | sed -n 's/.*Relative upper-left Y: *\([0-9-]*\).*/\1/p' | head -1)

    fr=0; framed "$wid" || fr=$?
    case "$fr" in
        1) ext="0,0,0,0"; ext_src="root" ;;
        *)
            ext="$(frame_extents "$wid")"
            if [ -n "$ext" ]; then ext_src="hint"; else ext_src="absent"; fi
            [ "$fr" = 2 ] && ext_src="${ext_src}-untreed"
            ;;
    esac

    l=""; t=""
    case "$ext" in
        ?*) l="$(echo "$ext" | cut -d, -f1)"; t="$(echo "$ext" | cut -d, -f3)" ;;
    esac
    case "${ax:-x}${ay:-x}${l:-x}${t:-x}" in
        *[!0-9-]*|"") ;;
        *) frame="$(( ax - l )),$(( ay - t ))" ;;
    esac

    wm="$(wm_name)"
    echo "report: position frame=${frame} client=${ax:-?},${ay:-?} extents=${ext:-none} via=${ext_src} rel=${rx:-?},${ry:-?} xdotool=${raw} wm=${wm} wid_src=$(wid_src)"

    if [ "$frame" = "?" ]; then
        echo "  FAIL: the frame's corner cannot be derived on this lane -- client=${ax:-?},${ay:-?} extents=${ext:-none} via=${ext_src}; every number below would be about a window nothing measured"
        FAILURES=$((FAILURES + 1))
        return
    fi

    local want="${expected_x},${expected_y}"
    if [ "$frame" = "$want" ]; then
        echo "  PASS: frame origin = ${frame} (asked ${expected_x},${expected_y}; ${wm}, decoration ${l} left and ${t} above the content at ${ax},${ay})"
    else
        echo "  FAIL: frame origin expected ${want} actual=${frame} under ${wm} (asked ${expected_x},${expected_y}); the content is at ${ax},${ay} with ${l} of decoration to its left and ${t} above it, so this move placed the content and not the window"
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
