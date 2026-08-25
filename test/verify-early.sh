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
TARGET_URL="http://127.0.0.1:8098/early-target.html"

# The control, and it comes before everything because everything depends on it.
#
# The target used to be a host that never resolves, and that made `held` free:
# a driver with no navigation guard at all reports it, because the provisional
# load fails on its own. Measured on macOS, which is why the target is now
# served over loopback -- and a server that is not up puts the test straight
# back where it was, passing every lane by refusing a navigation nobody could
# have made. Written without a pipe on purpose: `curl | grep -q` under
# `set -o pipefail` reports failure when grep exits early on a match, which is
# a control that reads DOWN whatever happens.
echo "=== Checking the navigation target is being served ==="
TARGET_BODY="$(mktemp)"
trap 'rm -f "$TARGET_BODY"' EXIT
if curl -fsS -m 5 "$TARGET_URL" -o "$TARGET_BODY" 2>/dev/null &&
   grep -q "EARLY-TARGET" "$TARGET_BODY"; then
    echo "  PASS: control the target answers at $TARGET_URL"
else
    echo "  FAIL: nothing is serving $TARGET_URL"
    echo "        the page under test cannot navigate anywhere, so a guard that"
    echo "        does nothing would pass this run -- which is the reason this"
    echo "        target stopped being a host that never resolves"
    exit 1
fi

case "$(uname -s)" in
    Darwin)
        # No window the shell can query, so the title arrives through the same
        # status file every other macOS check uses.
        read_title() { sed -n '1p' "${TMPDIR:-/tmp}/neutrino-title.txt" 2>/dev/null || true; }
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
    if [ "$actual" = "$expected" ]; then
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
# WebKitGTK driver and only it: Qt's arms on the first navigation and the macOS
# one at the commit of the document this file loaded, so on those a completed
# load says nothing either way about the answer beside it. Keyed off the
# transport the build reports rather than off the platform, so it follows the
# code: the day another driver starts keying on the load, this starts demanding
# the control from it too.
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

# The result, and every platform is asserted to it now. "escaped" means the
# page navigated to a remote origin and the document that arrived was handed
# the channel to the native window.
#
# macOS was recorded rather than asserted until this PR, because that driver
# had no navigation guard to assert against. It has one now -- not a policy
# decision, since WKNavigationDelegate takes a block for that and JXA cannot
# call one, but -stopLoading from didStartProvisionalNavigation:, measured to
# abandon the navigation and leave the app's own document standing.
#
# What the failure looks like there is worth knowing, because it is not
# `at=escaped`: the navigation succeeds, the app's document is destroyed with
# its pending report, and the page that arrives is refused by the origin check
# when it tries to set the title. So no report arrives and the run fails above
# instead. Both are failures; only `held` is a pass.
#
# This line has no control behind it and cannot have one -- it reads a single
# build. `held` was also the reading while the macOS guard was announcing its
# own failure on every launch, which is how PR 23's finding survived four PRs
# of this suite passing. test/navrefuse.sh is where that build is compared
# against itself with the refusal deleted; this stays the end-to-end reading.
assert "the page kept out of the window" "held" "$(field at)"

echo "=== Results: $FAILURES failure(s) ==="
[ "$FAILURES" -eq 0 ]
