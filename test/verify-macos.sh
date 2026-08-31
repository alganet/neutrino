#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-macos.sh - External test verifier for macOS
# Reads status from $TMPDIR/neutrino-title.txt written by macOS driver.
# a title write: title (1 line)
# resize/move writes: title\nWxH\nX,Y (3 lines)

set -euo pipefail

# Two budgets, because the first window is not like the ones after it. This is
# the app's first launch on the runner: osascript starting, the bridge coming
# up, WKWebView creating its content process, all of it before the first title
# is written. Every wait after that is a scripted step a second behind the last.
# 60 seconds covered both, and the merge run of PR 26 went red here having
# produced no screenshot at all -- while verify-offline.sh, on this same
# platform, already allows 90 for its first title and 60 for the settled one.
FIRST_TIMEOUT=180
TIMEOUT=60
POLL_INTERVAL=0.2
SCREENSHOT_DIR="${1:-.}"
FAILURES=0
STATUS_FILE="${TMPDIR:-/tmp}/neutrino-title.txt"

mkdir -p "$SCREENSHOT_DIR"

screenshot() {
    screencapture -x "$SCREENSHOT_DIR/${1}.png" 2>/dev/null || true
}

read_status_title() { sed -n '1p' "$STATUS_FILE" 2>/dev/null || echo ""; }

# Whether anything is still running when a wait gives up. Every failure so far
# has been a wait ending at its bound and saying nothing else, and an app that
# died and an app that stalled want opposite fixes.
report_launcher() {
    if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
        echo "report: the launcher process $APP_PID is still alive"
    else
        echo "report: the launcher process ${APP_PID:-<unset>} is gone"
    fi
    echo "report: osascript running: $(pgrep -x osascript 2>/dev/null | tr '\n' ' ' || true)"
}
# Line 4, the content size, and not line 2, the frame.
#
# `resizeTo` sizes the content on every lane, so the content is what an
# assertion about it has to read. While this read line 2 the numbers it
# compared were a frame against a content request, and the fifty-pixel
# tolerance below was what let the two look equal -- a 32 px title bar fits
# inside fifty with room to spare, so this assertion passed both before and
# after the driver changed which one it sets, and would have gone on passing if
# the driver had got it backwards.
#
# Line 2 is still written and still read by the frame reporter above; nothing
# here says the frame is uninteresting, only that it is not what `resizeTo`
# was asked for.
read_status_geometry() { sed -n '4p' "$STATUS_FILE" 2>/dev/null || echo ""; }
read_status_position() { sed -n '3p' "$STATUS_FILE" 2>/dev/null || echo ""; }
# Line 5, `WxH+X+Y`: the work area, with its top-left corner converted out of
# AppKit's bottom-left coordinates by the driver, where the flip already lives.
read_status_workarea() { sed -n '5p' "$STATUS_FILE" 2>/dev/null || echo ""; }

wait_for_title() {
    local expected="$1"
    local budget="${2:-$TIMEOUT}"
    local deadline=$((SECONDS + budget))
    while [ $SECONDS -lt $deadline ]; do
        local found
        found=$(read_status_title)
        if [ "$found" = "$expected" ]; then return 0; fi
        sleep $POLL_INTERVAL
    done
    echo "TIMEOUT after ${budget}s waiting for title: $expected" >&2
    # What the app was actually saying when the wait gave up. A bare timeout
    # cannot tell an app that stalled from an app that is one step ahead, and
    # those want opposite fixes.
    echo "report: the status file held: '$(read_status_title)'"
    report_launcher
    return 1
}

assert_title() {
    local expected="$1"
    local actual
    actual=$(read_status_title)
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: title = '$expected'"
    else
        echo "  FAIL: title expected='$expected' actual='$actual'"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_geometry() {
    local expected_w="$1" expected_h="$2" tolerance="${3:-0}"
    local geom actual_w actual_h
    geom=$(read_status_geometry)
    actual_w="${geom%x*}"; actual_h="${geom#*x}"
    if [ -z "$actual_w" ] || [ -z "$actual_h" ]; then
        echo "  FAIL: could not read geometry"
        FAILURES=$((FAILURES + 1))
        return
    fi
    local dw=$(( actual_w - expected_w )); dw=${dw#-}
    local dh=$(( actual_h - expected_h )); dh=${dh#-}
    if [ "$dw" -le "$tolerance" ] && [ "$dh" -le "$tolerance" ]; then
        echo "  PASS: content = ${actual_w}x${actual_h} (asked ${expected_w}x${expected_h}, tolerance ${tolerance})"
    else
        echo "  FAIL: content expected ${expected_w}x${expected_h} actual=${actual_w}x${actual_h}, off by ${dw}x${dh} (tolerance ${tolerance})"
        FAILURES=$((FAILURES + 1))
    fi
}

# The requested position, clamped to the work area, exactly.
#
# The fifty pixels this allowed were never paying for a decoration: line 3 is
# the frame's top-left and `move` sets the frame, so the two sides were the same
# quantity all along. What they were paying for is the menu bar. macOS will not
# place a window above it, so `moveTo(0,0)` lands at the top of
# `NSScreen.visibleFrame` and not at zero, and fifty is wide enough to swallow
# a menu bar of any height anyone has shipped.
#
# So the expectation is derived rather than guessed: a window goes where it was
# asked or to the edge of the work area, whichever is further in. That is a rule
# and not a constant, which is why it can be asserted at zero on a runner whose
# menu bar and Dock this file has never seen.
#
# Where the work area cannot be read the tolerance comes back, and the reason is
# printed. A clamp that cannot be computed is not a clamp of zero.
assert_position() {
    local expected_x="$1" expected_y="$2" tolerance="${3:-}"
    local pos actual_x actual_y work wx wy
    pos=$(read_status_position)
    actual_x="${pos%,*}"; actual_y="${pos#*,}"
    if [ -z "$actual_x" ] || [ -z "$actual_y" ]; then
        echo "  FAIL: could not read position"
        FAILURES=$((FAILURES + 1))
        return
    fi
    work=$(read_status_workarea)
    case "$work" in
        *x*+*+*)
            wx="${work#*+}"; wx="${wx%+*}"
            wy="${work##*+}"
            ;;
        *) wx=""; wy="" ;;
    esac
    echo "report: position actual=${actual_x},${actual_y} asked=${expected_x},${expected_y} workarea=${work:-?}"
    if [ -z "$wx" ] || [ -z "$wy" ] || [ -n "${wx//[0-9-]/}" ] || [ -n "${wy//[0-9-]/}" ]; then
        tolerance="${tolerance:-50}"
        echo "report: no work area on line 5; the clamp cannot be derived and the tolerance stands"
    else
        [ "$expected_x" -lt "$wx" ] && expected_x="$wx"
        [ "$expected_y" -lt "$wy" ] && expected_y="$wy"
        tolerance="${tolerance:-0}"
    fi
    local dx=$(( actual_x - expected_x )); dx=${dx#-}
    local dy=$(( actual_y - expected_y )); dy=${dy#-}
    if [ "$dx" -le "$tolerance" ] && [ "$dy" -le "$tolerance" ]; then
        echo "  PASS: position = ${expected_x},${expected_y} (actual: ${actual_x},${actual_y}, tolerance ${tolerance})"
    else
        echo "  FAIL: position expected ${expected_x},${expected_y} actual=${actual_x},${actual_y} (tolerance ${tolerance}); if the work area above is right, this is what moveTo means on this lane and the definition is what needs writing down"
        FAILURES=$((FAILURES + 1))
    fi
}

# Clean stale status file
rm -f "$STATUS_FILE"

# --- Test steps ---
# Each step: action fires, then 1s later the app names the window.
# When we see the title, the action has already happened.
# resize/move also write geometry+position to the status file.

echo "=== Waiting for window ==="
deadline=$((SECONDS + FIRST_TIMEOUT))
while [ $SECONDS -lt $deadline ] && [ -z "$(read_status_title)" ]; do sleep $POLL_INTERVAL; done
if [ -z "$(read_status_title)" ]; then
    # This verifier cannot see a window. It sees a status file that the macOS
    # driver writes, and the driver only writes one when the app was built with
    # --tier=testing. A build without it looks exactly like an app that never
    # started, so say which of the two this is rather than making the next
    # person find out from a stack of green assertions and one red one.
    if [ ! -e "$STATUS_FILE" ]; then
        echo "FAIL: no status file at $STATUS_FILE"
        echo "      the app writes one only when built with --tier=testing;"
        echo "      a release build is silent here and looks identical to a crash"
    else
        echo "FAIL: window never appeared"
    fi
    report_launcher
    exit 1
fi
echo "Window found"
screenshot "00-initial"

echo "=== Step 0: Ready ==="
# The long budget once more. The window exists from the wait above, but the
# document and the page script behind it may not, and that stretch is the one
# that has been slow.
wait_for_title "STEP0" "$FIRST_TIMEOUT" || { echo "FAIL: STEP0 never reached"; exit 1; }
assert_title "STEP0"
screenshot "01-step0"

echo "=== Step 1: title ==="
wait_for_title "STEP1-Test Title" || { echo "FAIL: STEP1 never reached"; exit 1; }
assert_title "STEP1-Test Title"
screenshot "02-step1"

echo "=== Step 2: resize ==="
wait_for_title "STEP2" || { echo "FAIL: STEP2 never reached"; exit 1; }
assert_geometry 500 400
screenshot "03-step2"

echo "=== Step 3: move ==="
wait_for_title "STEP3" || { echo "FAIL: STEP3 never reached"; exit 1; }
assert_position 0 0
screenshot "04-step3"

echo "=== Step 4: the desktop's palette ==="
# The app does the checking -- it is the only side that can see the palette --
# and this waits on its verdict. A lane that reached no toolkit reports null and
# never sets THEMEOK, so the timeout here is the failure rather than a pass with
# nothing behind it. The reading itself is on screen in the shot below.
wait_for_title "THEMEOK" || {
    echo "  FAIL: the palette was not readable on this lane (see 05-theme.png)"
    FAILURES=$((FAILURES + 1))
}
screenshot "05-theme"

echo "=== Waiting for TESTS DONE ==="
wait_for_title "TESTS DONE" || { echo "FAIL: tests never completed"; exit 1; }
screenshot "06-done"

echo "=== Step 4: close fires window delegate, terminates osascript ==="
if [ -n "${APP_PID:-}" ]; then
    exit_deadline=$((SECONDS + 10))
    while [ $SECONDS -lt $exit_deadline ]; do
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep $POLL_INTERVAL
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
        echo "  FAIL: process $APP_PID still running 10s after window.close()"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: process $APP_PID exited after window.close()"
    fi
else
    echo "  SKIP: APP_PID not provided"
fi

echo ""
echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
