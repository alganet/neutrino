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

screenshot() {
    import -window root "$SCREENSHOT_DIR/${1}.png" 2>/dev/null || true
}

wait_for_title() {
    local expected="$1"
    local deadline=$((SECONDS + TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        local wid
        wid=$(xdotool search --name "$expected" 2>/dev/null | head -1) || true
        if [ -n "$wid" ]; then
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

assert_geometry() {
    local wid="$1" expected_w="$2" expected_h="$3" tolerance="${4:-50}"
    local info size actual_w actual_h
    info=$(xdotool getwindowgeometry "$wid" 2>/dev/null) || true
    size=$(echo "$info" | grep -oP 'Geometry: \K[0-9]+x[0-9]+') || true
    actual_w="${size%x*}"; actual_h="${size#*x}"
    local dw=$(( actual_w - expected_w )); dw=${dw#-}
    local dh=$(( actual_h - expected_h )); dh=${dh#-}
    if [ "$dw" -le "$tolerance" ] && [ "$dh" -le "$tolerance" ]; then
        echo "  PASS: geometry ~= ${expected_w}x${expected_h} (actual: ${actual_w}x${actual_h})"
    else
        echo "  FAIL: geometry expected ~= ${expected_w}x${expected_h} actual=${actual_w}x${actual_h}"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_position() {
    local wid="$1" expected_x="$2" expected_y="$3" tolerance="${4:-50}"
    local info pos actual_x actual_y
    info=$(xdotool getwindowgeometry "$wid" 2>/dev/null) || true
    pos=$(echo "$info" | grep -oP 'Position: \K[0-9]+,[0-9]+') || true
    actual_x="${pos%,*}"; actual_y="${pos#*,}"
    local dx=$(( actual_x - expected_x )); dx=${dx#-}
    local dy=$(( actual_y - expected_y )); dy=${dy#-}
    if [ "$dx" -le "$tolerance" ] && [ "$dy" -le "$tolerance" ]; then
        echo "  PASS: position ~= ${expected_x},${expected_y} (actual: ${actual_x},${actual_y})"
    else
        echo "  FAIL: position expected ~= ${expected_x},${expected_y} actual=${actual_x},${actual_y}"
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

echo "=== Step 1: setTitle ==="
WID=$(wait_for_title "STEP1-Test Title") || { echo "FAIL: STEP1 never reached"; exit 1; }
assert_title "$WID" "STEP1-Test Title"
screenshot "02-step1"

echo "=== Step 2: resize ==="
WID=$(wait_for_title "STEP2") || { echo "FAIL: STEP2 never reached"; exit 1; }
assert_geometry "$WID" 500 400
screenshot "03-step2"

echo "=== Step 3: move ==="
WID=$(wait_for_title "STEP3") || { echo "FAIL: STEP3 never reached"; exit 1; }
assert_position "$WID" 0 0 100
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
