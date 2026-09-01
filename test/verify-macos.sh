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

# What is on this screen, and who owns it -- one line per window, named by the
# process that owns it. The x11 verifiers have had this since the round that
# turned three stray windows from a suspicion into names; this lane has been
# reading its own pictures instead. Costs one osascript per shot, which is a few
# hundred milliseconds spent outside the app's own clock.
ONSCREEN_JS="$(dirname "$0")/onscreen-macos.js"
onscreen_line() {
    osascript -l JavaScript "$ONSCREEN_JS" 2>/dev/null |
        sed 's/^/[/; s/$/]/' | tr '\n' ' '
}

# The whole display, and not just the app's window.
#
# `screencapture -l` composites a single window, which makes a tighter picture
# and a much smaller file, and it is not what these sheets are for. What a
# reader wants out of a CI screenshot is the machine: what else was on the
# desktop, what was sitting on top of the app, whether something opened behind
# it. A frame cropped to the window cannot answer any of that, and that answer
# is usually the reason somebody opened the sheet in the first place.
#
# The known cost is back in the frame: the system consent sheet -- "bash is
# requesting to bypass the system private window picker" -- a periodic macOS
# reminder shown to any process that captures the screen, which cannot be
# switched off and cannot be clicked from a runner. It is a thing on the
# desktop, and photographing the desktop means photographing it too.
#
# What survives from the cropped version is its wait, which was the better half
# of it. `screencapture -l` fails while a window has a number but is not yet
# composited, and this verifier calls that moment "Window found" because the
# launcher writes a title from its clock tick, before the window is on screen:
# `00-initial` reported "window 30 could not be captured" on both macOS lanes in
# the run that found this, while every later shot in the same lane succeeded.
# So the `-l` call stays, as a probe rather than as the photograph -- it
# composites the window into a scratch file nobody keeps, and the display shot
# is taken once that has worked. The thing waited for and the thing measured
# are still one event, and the picture is now of the whole machine.
#
# Says which it did, and how long it waited. A window that takes seconds to
# appear is a finding about the app rather than about the shutter, and a
# display shot taken with no window on it should not read like one taken with.
screenshot() {
    local wid probe n how
    wid="$(sed -n '8p' "$STATUS_FILE" 2>/dev/null)"
    probe="${TMPDIR:-/tmp}/neutrino-shot-probe.png"
    case "$wid" in
        ''|*[!0-9]*)
            how="the whole display; no window number yet, so nothing was waited for" ;;
        *)
            n=0
            how="the whole display; window $wid never became capturable"
            while [ "$n" -lt "${NT_SHOT_TRIES:-24}" ]; do
                if screencapture -x -o -l "$wid" "$probe" 2>/dev/null &&
                   [ -s "$probe" ]; then
                    how="the whole display, with the app's window (CGWindowID $wid) on it after $((n * 250))ms"
                    break
                fi
                n=$((n + 1))
                sleep 0.25
            done
            rm -f "$probe" ;;
    esac
    # One shutter, at the end, whatever the wait decided. Three of them is how
    # the cropped version was written and it is one more place for the two
    # halves -- the picture and the sentence describing it -- to disagree.
    screencapture -x "$SCREENSHOT_DIR/${1}.png" 2>/dev/null || true
    echo "  shot ${1}: $how"
    # After the capture and not before it. On x11 this line is printed first,
    # but there the shutter fires immediately; here it can wait seconds for a
    # window, and the room at the end of that wait is the room in the picture.
    echo "  onscreen at capture: $(onscreen_line)"
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
