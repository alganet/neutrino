#!/bin/bash
# step.sh - one suite, with the things every step around it was repeating.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: step.sh [--display WM|none] [--qt] [--gtk] [--log NAME]
#                [--timeout SECS] -- <command> [args...]
#
# Two idioms accounted for most of .github/workflows/ci.yml. This is both.
#
# The first, fifty-seven times:
#
#   TEST_EXIT=0
#   bash test/lanes.sh test/neutrinotest.cmd > ~/lanes.log 2>&1 || TEST_EXIT=$?
#   cat ~/lanes.log
#   exit $TEST_EXIT
#
# Four lines to run a suite, keep its log where the sheet step will find it,
# print it into the job log, and still fail the step. It is written that way
# because a bare pipe into `tee` would exit with tee's status and a red suite
# would pass; the redirect-then-cat is the fix, and it was made fifty-seven
# times.
#
# The second, forty-one times: an `export DISPLAY`, an `export GDK_BACKEND` and
# a `pgrep Xvfb || { Xvfb ... & sleep 3; metacity ... & sleep 2; }` -- six of
# them without the pgrep, which is how a lane ends up with two X servers on one
# display and a window on whichever one won.
#
# Neither belongs in a workflow. A step should say what it runs.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

NT_WM=""; NT_QT=0; NT_GTK=0; NT_LOG=""; NT_TIMEOUT=""; NT_APP=""

usage() {
    echo "usage: step.sh [--display WM|none] [--qt] [--gtk] [--log NAME]" >&2
    echo "               [--app ARTIFACT] [--timeout SECS] -- <command> [args...]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --display) NT_WM="${2:-metacity}"; shift 2 ;;
        --display=*) NT_WM="${1#--display=}"; shift ;;
        --qt)  NT_QT=1; shift ;;
        --gtk) NT_GTK=1; shift ;;
        --log) NT_LOG="${2:-}"; shift 2 ;;
        --log=*) NT_LOG="${1#--log=}"; shift ;;
        --app) NT_APP="${2:-}"; shift 2 ;;
        --app=*) NT_APP="${1#--app=}"; shift ;;
        --timeout) NT_TIMEOUT="${2:-}"; shift 2 ;;
        --timeout=*) NT_TIMEOUT="${1#--timeout=}"; shift ;;
        --) shift; break ;;
        -*) echo "step.sh: unknown option $1" >&2; usage ;;
        *)  break ;;
    esac
done
[ $# -gt 0 ] || usage

if [ -n "$NT_WM" ] || [ "$NT_QT" = 1 ] || [ "$NT_GTK" = 1 ]; then
    # shellcheck source=/dev/null
    . "$HERE/lib/display.sh"
    [ "$NT_QT" = 1 ] && nt_qt_env
    [ "$NT_GTK" = 1 ] && nt_gtk_env
    if [ -n "$NT_WM" ]; then
        nt_display_up "$NT_WM" || exit 1
    fi
fi

# Where the log goes. $HOME, because that is where every sheet step already
# looks -- `cp ~/*.log ~/sheetsrc/` -- and moving it would be a change to eight
# lanes for no reason.
NT_LOGFILE=""
if [ -n "$NT_LOG" ]; then
    NT_LOGFILE="$HOME/$NT_LOG.log"
fi

# The app under test, launched and reaped by the thing that watches it.
#
# Twenty-six steps in the workflow did this by hand:
#
#   bash test/neutrinostddoc.cmd > ~/stddoc-app.log 2>&1 &
#   APP_PID=$!
#   ... run the verifier, keep its status ...
#   pkill -P "$APP_PID" 2>/dev/null || true
#   kill "$APP_PID" 2>/dev/null || true
#
# The pkill before the kill is the part worth keeping and the part most often
# left out: the artifact is a shell script that execs an engine, so killing the
# shell leaves the engine holding the window, and the next suite then finds a
# window that is not its own. Four of the twenty-six omit it.
NT_APP_PID=""
nt_app_reap() {
    [ -n "$NT_APP_PID" ] || return 0
    pkill -P "$NT_APP_PID" 2>/dev/null || true
    kill "$NT_APP_PID" 2>/dev/null || true
    NT_APP_PID=""
}

if [ -n "$NT_APP" ]; then
    [ -f "$NT_APP" ] || { echo "  FAIL: no artifact at '$NT_APP'"; exit 1; }
    # Its own log, named after it, beside the suite's. Every lane's sheet step
    # gathers ~/*.log, so the launcher's account of itself lands in the artifact
    # next to the verifier's -- which is where it already went, under this name.
    NT_APP_LOG="$HOME/$(basename "${NT_APP%.cmd}")-app.log"
    bash "$NT_APP" > "$NT_APP_LOG" 2>&1 &
    NT_APP_PID=$!
    # Reaped however this exits, including on the leash firing or a Ctrl-C.
    trap 'nt_app_reap' EXIT INT TERM
fi

# The leash. `timeout` is not on macOS, so this is the same fallback
# netinstall/test/lib.sh makes: run it unbounded rather than not at all, since a
# suite that is not run says less than a suite that might overrun.
run_it() {
    if [ -n "$NT_TIMEOUT" ] && command -v timeout >/dev/null 2>&1; then
        timeout "$NT_TIMEOUT" "$@"
    else
        "$@"
    fi
}

if [ -n "$NT_LOGFILE" ]; then
    run_it "$@" > "$NT_LOGFILE" 2>&1
    RC=$?
    cat "$NT_LOGFILE"
else
    run_it "$@"
    RC=$?
fi

# 124 is what `timeout` exits when it fires, and it is worth saying so: a suite
# that was killed at its leash and a suite that reported 124 failures are
# different problems and the number alone cannot tell them apart.
if [ -n "$NT_TIMEOUT" ] && [ "$RC" = 124 ]; then
    echo "  FAIL: $1 exceeded its ${NT_TIMEOUT}s leash and was killed"
    exit 1
fi
exit "$RC"
