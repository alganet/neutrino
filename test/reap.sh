#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# reap.sh - kill an app, then wait until its window is actually gone.
#
# Usage: reap.sh <process-pattern> [<window-title-prefix>]
#
# `pkill -f neutrinoattack` returns as soon as the signal is delivered, not when
# the process has gone, and a webview takes a moment more to tear its window
# down than a shell takes to run its next line. So the step after it starts
# while the window is still mapped, and on `kde` the attack probe's window --
# `ATTACK tx=console wire=LIVE forge=REFUSED ...` -- was on the display for every
# capture the lane took afterwards.
#
# The flip harnesses already knew this: decoflip.sh and themeflip.sh both refuse
# to start their second half until the first half's window is gone, and both
# carry a comment about the round it cost them. This is that rule, made
# available to the steps that were not written with it.
#
# It waits and then escalates, and says which of the two ended it. A window that
# needed SIGKILL is a finding about the app rather than about the lane, and
# silently sending SIGKILL first would delete it.

set -uo pipefail

PATTERN="${1:?usage: reap.sh <process-pattern> [<window-title-prefix>]}"
PREFIX="${2:-}"
LIMIT="${NT_REAP_LIMIT:-20}"

# Every process matching the pattern except this script and its parent.
#
# `pkill -f` cannot be used here and the first version of this file was killed
# by it on its first run: the pattern arrives as an argument, so it is in this
# script's own command line, and `-f` matches command lines. The step that this
# replaces got away with the same call because its pattern was a literal in a
# script body, where no argv can see it -- which is luck, and stops being luck
# the moment anyone parameterises it.
# Excluded by name and not by pid, which is the second version of this. `$$` is
# not enough: every command substitution and every pipeline stage forks a copy
# of this script with the same command line and a pid of its own, so the list
# came back holding three of us and the wait never ended. Anything whose command
# line is this script is not the thing being reaped.
targets() {
    pgrep -f "$PATTERN" 2>/dev/null | while read -r pid; do
        case "$(ps -o args= -p "$pid" 2>/dev/null)" in
            *reap.sh*) continue ;;
        esac
        echo "$pid"
    done
}

# The process that owns a window carrying the prefix, which on one lane is not
# the process the pattern finds.
#
# `kde` runs the app under `qml6`, and `qml6`'s command line does not carry the
# artifact's name -- so `neutrinoattack` matched the wrapper, the wrapper died,
# and the window stayed. That lane reported `ATTACK tx=console wire=LIVE ...` in
# seven of seven captures the round this file was added, with reap.sh correctly
# saying it had failed and why.
#
# Found by title and killed by pid, which is the safe half of each: a title is
# the only handle a stray window offers, and a pid is the only thing precise
# enough to act on. Scoped to the prefix the caller named, so nothing this
# suite did not start is ever a candidate.
window_pids() {
    [ -n "$PREFIX" ] || return 0
    command -v xdotool >/dev/null 2>&1 || return 0
    local wid pid
    for wid in $(xdotool search --name "^$PREFIX" 2>/dev/null); do
        pid="$(xdotool getwindowpid "$wid" 2>/dev/null)" || continue
        case "$pid" in
            ''|*[!0-9]*) continue ;;
            *) [ "$pid" = "$$" ] || echo "$pid" ;;
        esac
    done
}

signal() {
    local sig="$1" pid
    for pid in $(targets; window_pids); do
        kill "$sig" "$pid" 2>/dev/null || true
    done
}

gone() {
    [ -z "$(targets)" ] || return 1
    [ -z "$(window_pids)" ] || return 1
    if [ -n "$PREFIX" ] && command -v xdotool >/dev/null 2>&1; then
        [ -z "$(xdotool search --name "^$PREFIX" 2>/dev/null | head -1)" ] || return 1
    fi
    return 0
}

signal -TERM

n=0
while [ "$n" -lt "$LIMIT" ]; do
    if gone; then
        echo "  reap: '$PATTERN' is gone after $((n * 100))ms of waiting"
        exit 0
    fi
    n=$((n + 1))
    sleep 0.1
done

# Still there. Say so before escalating, because "it needed a KILL" and "it went
# on its own" are different facts about the app and only one of them is normal.
echo "  reap: '$PATTERN' outlived SIGTERM by $((LIMIT))00ms; sending SIGKILL"
signal -KILL

n=0
while [ "$n" -lt "$LIMIT" ]; do
    if gone; then
        echo "  reap: '$PATTERN' is gone after SIGKILL"
        exit 0
    fi
    n=$((n + 1))
    sleep 0.1
done

# Not a failure. This runs in cleanup position, after the reading the step
# exists for has already been taken, and turning a leaked window into a red lane
# would throw away a good measurement to report a bad tidy-up. It is loud
# instead, so the next capture's `onscreen` line has something to be read
# against.
echo "  reap: '$PATTERN' is STILL up after SIGKILL; later captures may carry it"
exit 0
