#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# early.sh - the apparatus test/suite/verify-early.sh has always needed, and the
# order it has to be brought up in.
#
# Usage: early.sh <app.cmd built from test/probe/neutrinoearly.js>
#
# The suite is one verifier and three things around it, and until now the three
# things were written out in .github/workflows/ci.yml three times -- once on
# gjs, once on kde, once on macos -- as twelve near-identical lines each. They
# were not identical. macos cleared the status file and cat'd the app's log
# afterwards; the other two did neither. That difference is real on macos and
# meaningless on the others, but nothing in the file said which of the two it
# was, and a reader comparing the blocks could not tell a deliberate divergence
# from a paste that had drifted.
#
# The three things, and none of them is scaffolding:
#
#   stall.py    holds a subresource open so the document's load stays pending.
#               Without it the load finishes first, the guard arms on its own,
#               and the run measures a race it never entered. stall.py's own
#               header is the long version.
#
#   the target  has to answer. It used to be a host that never resolves, and
#               that made the reading free: a driver with no guard at all
#               reports `held`, because the provisional load fails by itself.
#               Measured on macOS.
#
#   the order   the app must not be launched until the target is up. This is
#               why serve-target.sh blocks rather than backgrounding and
#               carrying on -- the lane that got there first found nothing
#               listening -- and it is the reason this sequence cannot be
#               expressed as test/lib/step.sh's `--app`. step.sh launches the
#               artifact before it runs the command, which is right for every
#               other suite and exactly backwards for this one: here the
#               command is what brings up the port the artifact navigates into.
#
# So the launch lives here, with the two servers it depends on, and the row in
# test/suites.tsv is one line per lane again.

set -uo pipefail

# The six words, for the one verdict this wrapper files itself. Everything else
# here is apparatus -- two servers and a launch -- and the readings belong to
# test/suite/verify-early.sh, which this runs and whose exit status it returns.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/harness.sh"

APP="${1:-}"
if [ -z "$APP" ] || [ ! -f "$APP" ]; then
    echo "usage: early.sh <app.cmd built from test/probe/neutrinoearly.js>" >&2
    exit 2
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
HERE="$(cd "$(dirname "$0")" && pwd)"
# The two rooms this suite reaches into. The apparatus is what it stands up --
# a stall socket and a server for the page to navigate at -- and lib is where
# the reaper lives; neither is a suite, and neither is in here with it.
APPARATUS="$(cd "$HERE/../apparatus" && pwd)"
LIB="$(cd "$HERE/../lib" && pwd)"

# $HOME and not a mktemp dir: every lane's sheet step gathers `~/*.log`, and
# these three logs went there under these three names before this file existed.
# Moving them would be a change to three sheet steps for no reading gained.
STALL_LOG="$HOME/stall.log"
PAGES_LOG="$HOME/pages.log"
# Named the way test/lib/step.sh names the log of an app it launches itself --
# `<artifact>-app.log` -- so a row that wants it in the job log asks for it with
# the same `cat=` directive as every other suite, and the macos row does.
APP_LOG="$HOME/$(basename "${APP%.cmd}")-app.log"

STALL_PID=""
PAGES_PID=""
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ]; then
        # The tree, not the process: the artifact is a shell that execs an
        # engine, so killing the shell leaves the engine holding the window and
        # the next suite finds a window that is not its own.
        pkill -P "$APP_PID" 2>/dev/null || true
        kill "$APP_PID" 2>/dev/null || true
    fi
    [ -n "$STALL_PID" ] && kill "$STALL_PID" 2>/dev/null
    [ -n "$PAGES_PID" ] && kill "$PAGES_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

echo "=== Bringing up the stall socket and the navigation target ==="
python3 "$APPARATUS/stall.py" 8099 > "$STALL_LOG" 2>&1 &
STALL_PID=$!
# Does not return until the target answers, and fails loudly when it never
# does. Its diagnostic goes to stderr, which is this suite's stdout by the time
# step.sh has it.
if ! PAGES_PID="$(bash "$APPARATUS/serve-target.sh" "$PAGES_LOG")"; then
    # The verifier never runs from here, so it files nothing -- and four cases
    # that file nothing are four holes the grid cannot tell from a lane that
    # never ran this suite. The control it would have filed is filed here
    # instead, and the three behind it are skipped by name.
    nt_fail early.target.served "nothing is serving the navigation target"
    echo "        the page under test cannot navigate anywhere, so a guard that"
    echo "        does nothing would pass this run"
    nt_skip early.reported "the target never came up, so the app was never launched"
    nt_skip early.load.pending "the target never came up, so the app was never launched"
    nt_skip early.held "the target never came up, so the app was never launched"
    nt_finish
fi

# The macOS status file, cleared before the app that writes it starts.
#
# Every testing-tier macOS build writes its window title to this one fixed path.
# A stale file is the previous suite's last title, which verify-early.sh reads
# as its own first report -- and it would read it immediately, before this app
# had rendered anything, which is a pass that measured the suite before it.
# test/lib/step.sh clears it for the artifacts it launches; this is the same line
# for the one artifact it does not.
#
# Not inside the verifier: that is already waiting on the file while the app is
# writing it, and a removal there races the thing it is waiting for.
rm -f "$NT_STATUS_FILE"

echo "=== Launching $(basename "$APP") ==="
bash "$APP" > "$APP_LOG" 2>&1 &
APP_PID=$!

bash "$HERE/verify-early.sh"
RC=$?

# The window, gone before the next suite goes looking for one. reap.sh waits and
# then escalates rather than sending SIGKILL first, because a window that needed
# SIGKILL is a finding about the app.
#
# Safe to call with this pattern from here even though the artifact's path is in
# this script's own argv: reap.sh excludes its whole ancestor chain, which it
# learned by SIGKILLing test/lib/step.sh and having the lane read the 137 as a
# failure count.
bash "$LIB/reap.sh" neutrinoearly EARLY

exit "$RC"
