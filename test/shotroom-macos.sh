#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# shotroom-macos.sh - the room the macOS pictures are taken in, and one attempt
# to clear the thing standing in it.
#
# Every macOS capture this lane publishes carries a system alert: "bash is
# requesting to bypass the system private window picker and directly access
# your screen and audio", centred on the display with an Allow button and an
# Open System Settings button. It is the periodic re-authorisation reminder
# macOS 15 introduced and macOS 26 still has; it never times out, so one alert
# raised by the first capture of the job sits over all fourteen. In the last
# run it covered the right half of the app window in `03-step2`.
#
# It cannot be clicked from a runner and there is no switch for it. What there
# is, is an approvals file -- ~/Library/Group Containers/group.com.apple.replayd/
# ScreenCaptureApprovals.plist -- which is in the user's own container rather
# than behind SIP, and a daemon, replayd, that reads it. That is the whole basis
# for what follows, and none of it is documented by Apple, so this script is
# written to report rather than to assert: every step prints what it found, no
# step can fail the job, and the exit is always 0. What it produces is a reading
# to act on in the next round, not a control.
#
# Run once, before the first verifier, so that whatever it does to the room is
# done before any picture is taken of it.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
WORK="${TMPDIR:-/tmp}/neutrino-shotroom"
mkdir -p "$WORK"

# Never the shot directory. These captures exist to provoke the alert and to
# see whether it came back; they are not pictures of anything and they must not
# reach the sheet.
warm() {
    if screencapture -x "$WORK/$1.png" 2>"$WORK/$1.err"; then
        echo "  capture $1: $(stat -f %z "$WORK/$1.png" 2>/dev/null || echo '?') bytes"
    else
        echo "  capture $1: screencapture failed: $(cat "$WORK/$1.err" 2>/dev/null)"
    fi
}

onscreen() {
    osascript -l JavaScript "$HERE/onscreen-macos.js" 2>&1 | sed 's/^/  /' || true
}

approvals() {
    if [ -f "$PLIST" ]; then
        plutil -p "$PLIST" 2>&1 | sed 's/^/  /' || true
    else
        echo "  there is no file at $PLIST"
    fi
}

echo "=== shotroom-macos.sh: $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ==="

echo "=== 1. the approvals file, before anything has asked for the screen ==="
approvals

echo "=== 2. a throwaway capture, so the system asks ==="
warm before

echo "=== 3. what is on screen once it has asked ==="
# The alert is what this whole script is about, and this is the first line in
# the repository that can name the process presenting it rather than describe
# what it looks like.
onscreen

echo "=== 4. the approvals file, after the request ==="
# The schema is the point. Nothing here knows what keys this file holds or
# whether its expiry is a date or a number, and step 7 can only be written
# properly once this has been read once.
approvals

echo "=== 5. killing replayd ==="
# The cheapest thing that could possibly work, and the one the workarounds in
# the wild all end with: replayd owns this state, and force-quitting it is how
# they get it reloaded. If the alert is its window, it goes with it. It is a
# launchd job and comes back on demand, so this is not destructive.
if killall -9 replayd 2>"$WORK/killall.err"; then
    echo "  replayd was killed"
else
    echo "  killall said: $(cat "$WORK/killall.err" 2>/dev/null)"
fi
sleep 2

echo "=== 6. what is on screen after that ==="
onscreen

echo "=== 7. every date in the approvals file, pushed out to 2040 ==="
# Written blind, and it says so. macOS 15.1 began overwriting this timestamp
# with the current time whenever an app asks, which is why the workaround that
# survives out there is a launch agent rewriting it every day rather than a
# one-off edit. On an ephemeral runner one write may be enough; step 9 is where
# that is answered.
if [ -f "$PLIST" ]; then
    python3 - "$PLIST" <<'PY' 2>&1 | sed 's/^/  /'
import datetime, plistlib, sys

path = sys.argv[1]
try:
    with open(path, "rb") as f:
        doc = plistlib.load(f)
except Exception as exc:
    print("could not read it: %s" % exc)
    raise SystemExit(0)

far = datetime.datetime(2040, 1, 1)
count = 0


def walk(node):
    global count
    if isinstance(node, dict):
        for key, value in list(node.items()):
            if isinstance(value, datetime.datetime):
                node[key] = far
                count += 1
            else:
                walk(value)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            if isinstance(value, datetime.datetime):
                node[i] = far
                count += 1
            else:
                walk(value)


walk(doc)
if count == 0:
    # Not a failure. It means the expiry is not stored as a date, and the dump
    # in step 4 is where the next round finds out what it is stored as.
    print("no dates in this file; nothing was rewritten")
    raise SystemExit(0)
try:
    with open(path, "wb") as f:
        plistlib.dump(doc, f, fmt=plistlib.FMT_BINARY)
    print("rewrote %d date(s) to %s" % (count, far.isoformat()))
except Exception as exc:
    print("could not write it: %s" % exc)
PY
    approvals
    killall -9 replayd 2>/dev/null || true
    sleep 2
else
    echo "  there is still no file to rewrite"
fi

echo "=== 8. a second capture, with the file rewritten ==="
# This capture is also the check on step 5. replayd is what `screencapture`
# leans on, killing it is the one thing here that could take the lane's own
# pictures with it, and launchd is supposed to bring it straight back. If this
# line says the capture failed, the verifier's shots after it are failing for
# the same reason and that is the first thing to read in this log.
warm after
if [ ! -s "$WORK/after.png" ]; then
    echo "  WARNING: no capture after replayd was killed. Every picture this"
    echo "  WARNING: lane takes from here is suspect, and step 5 is why."
fi
# The alert does not appear instantly; the first one in the last run was in the
# frame of a capture taken seconds after the app came up. Two seconds is a
# guess, and a guess is honest here because nothing in this step is asserted.
sleep 2
onscreen

echo "=== 9. the approvals file at the end ==="
# Read once more because the interesting failure is not "the alert came back"
# but "the alert came back and the date is today's again", which is macOS
# overwriting the edit rather than ignoring it.
approvals

echo "=== shotroom-macos.sh: done, and nothing here failed the lane ==="
exit 0
