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
#   bash test/suite/lanes.sh test/out/neutrinotest.cmd > ~/lanes.log 2>&1 || TEST_EXIT=$?
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
NT_CAT=""; NT_REAP=""; NT_DBUS=0

usage() {
    echo "usage: step.sh [--display WM|none] [--qt] [--gtk] [--log NAME]" >&2
    echo "               [--app ARTIFACT] [--dbus] [--cat NAME]... [--reap PAT[:PREFIX]]" >&2
    echo "               [--timeout SECS] -- <command> [args...]" >&2
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
        --dbus) NT_DBUS=1; shift ;;
        --app) NT_APP="${2:-}"; shift 2 ;;
        --app=*) NT_APP="${1#--app=}"; shift ;;
        --cat) NT_CAT="$NT_CAT ${2:-}"; shift 2 ;;
        --cat=*) NT_CAT="$NT_CAT ${1#--cat=}"; shift ;;
        --reap) NT_REAP="${2:-}"; shift 2 ;;
        --reap=*) NT_REAP="${1#--reap=}"; shift ;;
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
    . "$HERE/display.sh"
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
#   bash test/out/neutrinostddoc.cmd > ~/stddoc-app.log 2>&1 &
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
    # The macOS status file, cleared before the app that writes it starts.
    #
    # Every testing-tier macOS build writes its window title to this one fixed
    # path, and six suites read it. A stale file is the previous suite's last
    # title, which the next verifier reads as its own first state -- so the four
    # macos steps that launch an artifact each carried this line ahead of the
    # launch. It belongs here instead: this is the line that starts the app, and
    # a clear that happens anywhere else is a clear that can be forgotten.
    #
    # Not inside the verifier, which is the one place it must not go: the
    # verifier is already waiting on the file when the app is writing it, and a
    # removal there races the thing it is waiting for.
    rm -f "${TMPDIR:-/tmp}/neutrino-title.txt"
    # Its own log, named after it, beside the suite's. Every lane's sheet step
    # gathers ~/*.log, so the launcher's account of itself lands in the artifact
    # next to the verifier's -- which is where it already went, under this name.
    NT_APP_LOG="$HOME/$(basename "${NT_APP%.cmd}")-app.log"
    # A session bus around the artifact, where the lane asks for one.
    #
    # Only kde does, and it is not a preference: QtWebEngine wants a session bus
    # and the container has no desktop to inherit one from, so the walk there was
    # written `dbus-run-session -- bash test/out/neutrinotest.cmd` in the workflow
    # while the other three lanes launched the same artifact bare. That is a
    # difference between lanes, which is what the setup column is for -- and it
    # cannot go in the command column, because the command is the verifier and
    # the artifact is launched by this file.
    if [ "$NT_DBUS" = 1 ] && command -v dbus-run-session >/dev/null 2>&1; then
        dbus-run-session -- bash "$NT_APP" > "$NT_APP_LOG" 2>&1 &
    else
        bash "$NT_APP" > "$NT_APP_LOG" 2>&1 &
    fi
    NT_APP_PID=$!
    # The pid, to the suite that is about to watch it.
    #
    # verify-macos.sh is the one verifier that asserts something about the
    # *process* rather than the window -- walk.close.process-exits, whether the
    # launcher exits after window.close() -- and it reads $APP_PID. The macos
    # step launched the app itself for that reason alone. It does not have to:
    # the thing that starts the app is the thing that knows its pid.
    export APP_PID="$NT_APP_PID"
    # Reaped however this exits, including on the leash firing or a Ctrl-C.
    trap 'nt_app_reap' EXIT INT TERM
fi

# The leash.
#
# `timeout` is not on macOS. The fallback used to be to run unbounded -- the
# same one netinstall/test/lib.sh makes -- on the reasoning that a suite that is
# not run says less than a suite that might overrun. That reasoning held while
# nothing passed --timeout: every lane was leashed by the step's own
# `timeout-minutes` and this function was dormant, so the platform without
# `timeout` was no worse off than the platform with it.
#
# test/run.sh ends that. A lane is one step now, so `timeout-minutes` bounds the
# whole list rather than any suite in it, and the leash a row declares is the
# only one that suite has. On macOS that leash would have been a number in a file
# with nothing behind it -- which is the failure netinstall/test/lib.sh names in
# its own words: a bound that silently is not there is worse than no bound.
#
# So the fallback is a watchdog rather than a shrug. It costs one background
# subshell per suite and it reports the same way `timeout` does: 124, which the
# caller below already knows how to read.
nt_watchdog() {
    "$@" &
    local pid=$! dog rc
    (
        # Not `sleep $NT_TIMEOUT; kill` in one breath: the suite usually wins,
        # and a watchdog that cannot be told the race is over leaves a sleeping
        # process per suite for the length of its own leash.
        sleep "$NT_TIMEOUT"
        kill -0 "$pid" 2>/dev/null || exit 0
        # The process tree, not the process. Same reason nt_app_reap above pkills
        # before it kills: the thing being run is a shell that execs an engine,
        # and killing the shell leaves the engine holding the window.
        pkill -P "$pid" 2>/dev/null || true
        kill -TERM "$pid" 2>/dev/null || true
        # A verifier killed mid-report is the one whose report you want, so it
        # gets a moment to finish writing before the second signal.
        sleep 5
        kill -0 "$pid" 2>/dev/null || exit 0
        pkill -9 -P "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
    ) &
    dog=$!
    wait "$pid"; rc=$?
    kill "$dog" 2>/dev/null || true
    wait "$dog" 2>/dev/null || true
    # bash reports a signalled child as 128+signal. Both of the watchdog's
    # signals are reported as 124 instead, so that a suite killed at its leash
    # says the same number here as it would where `timeout` exists -- the whole
    # point of the fallback is that the caller cannot tell which one ran.
    case "$rc" in
        143|137) rc=124 ;;
    esac
    return "$rc"
}

run_it() {
    if [ -z "$NT_TIMEOUT" ]; then
        "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$NT_TIMEOUT" "$@"
    else
        nt_watchdog "$@"
    fi
}

if [ -n "$NT_LOGFILE" ]; then
    run_it "$@" > "$NT_LOGFILE" 2>&1
    RC=$?
else
    run_it "$@"
    RC=$?
fi

# The window, gone before the next suite starts looking for one.
#
# `pkill` returns when the signal is delivered, not when the process has gone,
# and a webview takes longer to tear a window down than a shell takes to run its
# next line -- so on kde the attack probe's window was on the display for every
# capture the lane took afterwards. test/lib/reap.sh waits and then escalates; six
# steps called it by hand and this is the same call.
#
# Before the logs, so that anything it says about a window that needed SIGKILL
# lands next to the suite that left it.
if [ -n "$NT_REAP" ]; then
    bash "$HERE/reap.sh" "${NT_REAP%%:*}" "$(printf '%s' "$NT_REAP" | awk -F: 'NF>1{print $2}')"
fi

# The logs a suite wrote besides its own, in front of its own.
#
# decoflip and themeflip each launch a probe twice and leave a log per half --
# `deco-a`/`deco-b`, `flip-a`/`flip-b` -- and the differential they print only
# means something beside them. Eight steps ended `cat ~/flip-a.log ~/flip-b.log
# ~/themediff.log`, in that order, and the order is the point: the halves are
# the evidence and the differential is the reading.
for c in $NT_CAT; do
    cat "$HOME/$c.log" 2>/dev/null || true
done

[ -n "$NT_LOGFILE" ] && cat "$NT_LOGFILE"

# 124 is what `timeout` exits when it fires, and it is worth saying so: a suite
# that was killed at its leash and a suite that reported 124 failures are
# different problems and the number alone cannot tell them apart.
if [ -n "$NT_TIMEOUT" ] && [ "$RC" = 124 ]; then
    echo "  FAIL: $1 exceeded its ${NT_TIMEOUT}s leash and was killed"
    exit 1
fi
exit "$RC"
