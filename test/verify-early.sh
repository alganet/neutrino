#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-early.sh - Asserts what neutrinoearly.js measured.
#
# One question: did a page that navigated before its own load finished take the
# window with it? Two things have to hold for the answer to mean anything, and
# both are asserted rather than assumed -- that the report arrived at all, and
# that the document really was still loading when it navigated. A build that
# renders nothing refuses everything, and a stall that did not stall refuses
# this navigation for a reason that has nothing to do with the guard.

set -euo pipefail

TIMEOUT=90
POLL_INTERVAL=0.5
FAILURES=0

case "$(uname -s)" in
    Darwin)
        # No window the shell can query, so the title arrives through the same
        # status file every other macOS check uses.
        read_title() { sed -n '1p' "${TMPDIR:-/tmp}/neutrino-title.txt" 2>/dev/null || true; }
        # This driver has no navigation delegate at all -- there is nothing
        # here to arm early or late, and giving it one is the next PR. So the
        # result is recorded rather than asserted, and the number is on the
        # table when that PR opens. What is still asserted here is that a
        # report arrives at all: a page that navigates out from under this
        # driver must not take the window with it.
        EXPECT_AT="any"
        ;;
    *)
        if command -v xdotool >/dev/null 2>&1; then
            read_title() {
                local wid
                wid=$(xdotool search --name "^EARLY " 2>/dev/null | head -1) || true
                [ -n "$wid" ] && xdotool getwindowname "$wid" 2>/dev/null || true
            }
        elif command -v wmctrl >/dev/null 2>&1; then
            read_title() {
                wmctrl -l 2>/dev/null | sed -n 's/^[^ ]* *[^ ]* *[^ ]* *\(EARLY .*\)$/\1/p' | tail -1
            }
        else
            echo "verify-early.sh: need xdotool or wmctrl to read a window title" >&2
            exit 1
        fi
        EXPECT_AT="held"
        ;;
esac

echo "=== Waiting for the early-navigation app to report ==="
deadline=$((SECONDS + TIMEOUT))
TITLE=""
while [ $SECONDS -lt $deadline ]; do
    TITLE="$(read_title)"
    case "$TITLE" in *"EARLY "*) break ;; esac
    TITLE=""
    sleep $POLL_INTERVAL
done

if [ -z "$TITLE" ]; then
    echo "FAIL: the app never reported"
    echo "      a build that renders nothing refuses this navigation by doing"
    echo "      nothing at all, so no report is a failure and not a pass"
    exit 1
fi

echo "  report: $TITLE"

field() { echo "$TITLE" | sed -n "s/.* $1=\([A-Za-z]*\).*/\1/p"; }

assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "any" ]; then
        echo "  NOTE: $name = $actual (recorded, not asserted on this platform)"
    elif [ "$actual" = "$expected" ]; then
        echo "  PASS: $name = $actual"
    else
        echo "  FAIL: $name expected=$expected actual=$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

TRANSPORT="$(field tx)"
echo "  transport: $TRANSPORT"

# The control, and it comes first because the result is worthless without it.
# "complete" means the load had finished before the navigation was decided, so
# the guard armed in time on its own and this run never put it under any
# pressure -- a pass that proves nothing.
#
# It only means that where the guard keys on the load finishing, which is the
# WebKitGTK driver and only it: Qt's arms on the first navigation and macOS has
# no guard at all, so on those a completed load says nothing either way about
# the answer beside it. Keyed off the transport the build reports rather than
# off the platform, so it follows the code: the day another driver starts
# keying on the load, this starts demanding the control from it too.
READY="$(field ready)"
if [ "$TRANSPORT" = "scriptmessage" ]; then
    if [ "$READY" = "complete" ]; then
        echo "  FAIL: the document had finished loading when it reported (ready=$READY)"
        echo "        the stall did not hold, so the navigation met an armed"
        echo "        guard for a reason this test exists to rule out"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: the load was still pending (ready=$READY)"
    fi
else
    echo "  NOTE: ready = $READY (this guard does not key on the load finishing)"
fi

# The result. "escaped" means the page navigated to a remote origin and the
# document that arrived was handed the channel to the native window.
assert "the page kept out of the window" "$EXPECT_AT" "$(field at)"

echo "=== Results: $FAILURES failure(s) ==="
[ "$FAILURES" -eq 0 ]
