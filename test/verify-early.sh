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

# The six words. Twelve prose assertions reached nothing, and the file ended on
# `[ "$FAILURES" -eq 0 ]` -- so three failures and one were the same 1 to the
# lane, and three of its four exits left with no verdict counted at all.
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
# And the reader, which was three branches here and the same three in four other
# suites; verify-attack.sh's copy is the one this was taken from.
. "$(cd "$(dirname "$0")" && pwd)/lib/title.sh"

# What this run has left to answer. Its three early exits each left the cases
# below them unreported, and an unreported case is a hole the grid cannot tell
# from a suite that never ran.
skip_rest() {
    nt_skip early.reported "$1"
    nt_skip early.load.pending "$1"
    nt_skip early.held "$1"
}

TIMEOUT=90
POLL_INTERVAL=0.5
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
    nt_pass early.target.served "control the target answers at $TARGET_URL"
else
    nt_fail early.target.served "nothing is serving $TARGET_URL"
    echo "        the page under test cannot navigate anywhere, so a guard that"
    echo "        does nothing would pass this run -- which is the reason this"
    echo "        target stopped being a host that never resolves"
    skip_rest "there was nothing to navigate at, so nothing below was measured"
    nt_finish
fi

if [ "$NT_TITLE_HOW" = none ]; then
    nt_skip early.target.served "no xdotool or wmctrl here to read a window title with"
    skip_rest "there is no way to read a window title on this machine"
    nt_finish
fi

echo "=== Waiting for the early-navigation app to report ==="
deadline=$((SECONDS + TIMEOUT))
TITLE=""
while [ $SECONDS -lt $deadline ]; do
    TITLE="$(nt_title "EARLY ")"
    case "$TITLE" in *"EARLY "*) break ;; esac
    TITLE=""
    sleep $POLL_INTERVAL
done

if [ -z "$TITLE" ]; then
    nt_fail early.reported "the app never reported: a build that renders nothing refuses this navigation by doing nothing at all, so no report is a failure and not a pass"
    nt_skip early.load.pending "nothing reported, so there were no fields to read"
    nt_skip early.held "nothing reported, so there were no fields to read"
    nt_finish
fi

nt_pass early.reported "the app reported a title"

echo "  report: $TITLE"

field() { nt_field "$1" "$TITLE"; }


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
        nt_fail early.load.pending "the document had finished loading when it reported (ready=$READY); the stall did not hold, so the navigation met an armed guard for a reason this test exists to rule out"
    else
        nt_pass early.load.pending "the load was still pending (ready=$READY)"
    fi
else
    # A NOTE, which is prose nothing reads. It is this platform saying it cannot
    # ask the question -- Qt's guard arms on the first navigation and the macOS
    # one at the commit of this document, so a completed load says nothing
    # either way there -- and that is what a skip is for.
    nt_skip early.load.pending "ready = $READY, and this guard does not key on the load finishing, so a completed load says nothing either way"
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
nt_eq early.held "the page kept out of the window" "$(field at)" "held"

nt_finish
