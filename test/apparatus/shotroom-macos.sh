#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# shotroom-macos.sh - the room the macOS pictures are taken in, and the two
# moves that clear it.
#
# Every macOS capture this lane published carried a system alert: "bash is
# requesting to bypass the system private window picker and directly access
# your screen and audio", centred on the display, over the app. It is the
# periodic re-authorisation reminder macOS 15 introduced and macOS 26 still has;
# it never times out, so one alert raised by the first capture of the job sat in
# all fourteen frames and covered the right half of the app window in
# `03-step2`. It cannot be clicked from a runner and there is no switch for it.
#
# The first run of this script answered what it was written to ask. The state
# lives in a plist in the user's own container -- not behind SIP -- keyed by the
# responsible process, which on a hosted runner is not bash at all:
#
#     "/opt/hca/hosted-compute-agent" => {
#       "kScreenCaptureAlertableUsageCount" => 1
#       "kScreenCaptureApprovalLastAlerted" => 2026-09-01 07:17:57 +0000
#       "kScreenCaptureApprovalLastUsed"    => 2026-09-01 07:17:57 +0000
#       "kScreenCapturePrivacyHintDate"     => 2026-10-01 07:17:57 +0000
#       "kScreenCapturePrivacyHintPolicy"   => 2592000
#     }
#
# 2592000 is thirty days in seconds and the hint date is the alert date plus
# exactly that. Push the dates out to 2040, restart the daemon that reads them,
# and the alert goes: every picture the lane took after that run was of a clean
# desktop. The netinstall lane, which does not run this, still has the alert in
# its frames -- which is the control nobody had to arrange.
#
# What that first run also found is the cost, and the order here is the answer
# to it. `killall -9 replayd` took `screencapture` down with it -- "could not
# create image from display" -- and it came back on its own a moment later, but
# a moment later is inside the lane's own shots if this returns too early. So
# the file is rewritten first, the daemon is killed once, and nothing returns
# until a capture works again.
#
# It still reports rather than asserts: every step prints what it found, no step
# can fail the job, and the exit is 0 whatever happens.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
WORK="${TMPDIR:-/tmp}/neutrino-shotroom"
mkdir -p "$WORK"

# Never the shot directory. These captures exist to provoke the alert and to
# prove the shutter still works; they are not pictures of anything and they must
# not reach the sheet.
warm() {
    if screencapture -x "$WORK/$1.png" 2>"$WORK/$1.err" && [ -s "$WORK/$1.png" ]; then
        echo "  capture $1: $(stat -f %z "$WORK/$1.png" 2>/dev/null || echo '?') bytes"
        return 0
    fi
    echo "  capture $1: failed: $(tr -d '\n' < "$WORK/$1.err" 2>/dev/null)"
    return 1
}

# Blind on this lane, and kept anyway. It answers about the process that asks,
# not about the desktop -- see onscreen-macos.js for the measurement -- so what
# it is here for is the day that changes, and to sit beside the plist dumps as
# the one thing that would notice a window nobody expected.
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
# Cold, this does not exist. The first capture of the job creates it, which is
# also the capture that raises the alert.
approvals

echo "=== 2. a throwaway capture, so the system asks ==="
warm before

echo "=== 3. what is on screen once it has asked ==="
onscreen

echo "=== 4. the approvals file, after the request ==="
approvals

echo "=== 5. every date in the approvals file, pushed out to 2040 ==="
# Every date and not the one that looks like the expiry, because the three move
# together and the policy that spaces them is a duration rather than a date.
# macOS 15.1 began rewriting these when an app asks, which is why the workaround
# that survives in the wild is a launch agent rewriting them daily rather than a
# one-off edit; on a runner that lives half an hour, one write is the whole job.
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
else
    echo "  there is no file to rewrite, which means the capture above did not happen"
fi

echo "=== 6. killing replayd, once, so it reads the file again ==="
if killall -9 replayd 2>"$WORK/killall.err"; then
    echo "  replayd was killed"
else
    echo "  killall said: $(tr -d '\n' < "$WORK/killall.err" 2>/dev/null)"
fi

echo "=== 7. waiting for the shutter to come back ==="
# The whole reason this step exists. Killing replayd takes `screencapture` with
# it for a moment -- measured, "could not create image from display" -- and
# launchd brings it back on demand. Nothing here returns while that is still
# true, because the next thing to use the shutter is the lane.
tries=0
while [ "$tries" -lt 30 ]; do
    if warm after; then
        echo "  the shutter works again after $((tries))s"
        break
    fi
    tries=$((tries + 1))
    sleep 1
done
if [ "$tries" -ge 30 ]; then
    echo "  WARNING: thirty seconds and no capture. Every picture this lane"
    echo "  WARNING: takes from here is suspect, and step 6 is why."
fi

echo "=== 8. what is on screen at the end ==="
onscreen

echo "=== 9. the approvals file at the end ==="
# The interesting failure is not "the alert came back" but "the alert came back
# and the dates are today's again", which is macOS overwriting the edit rather
# than ignoring it.
approvals

echo "=== shotroom-macos.sh: done, and nothing here failed the lane ==="
exit 0
