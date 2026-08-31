#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# decodiff.sh - the differential over decoflip.sh's two halves.
#
# Usage: decodiff.sh <decorated.log> <chromeless.log>
#
# What this is for, in one sentence: a chromeless window's frame is its client
# area, so the extent is zero by construction -- and four different failures
# produce that same zero. The window manager not implementing
# _NET_FRAME_EXTENTS; xwininfo answering nothing; no window manager at all; and
# the app never coming up while the reader defaults. Every one of them is
# "nothing measured" wearing the answer's clothes.
#
# The guard is not a wider assertion, it is the other half. A decorated run in
# the same job on the same display reporting a *non-zero* extent is what says
# the instrument can see a frame at all -- and it is the only thing that can
# say it. That is what makes this pair a calibration rather than two runs.
#
# The second guard is `via=`. verify-std.sh reports whether the extents hint
# was read, was absent, or moved under the run, and a zero reported `via=absent`
# is refused here rather than counted. A reading and a silence are not two
# spellings of the same number.

set -uo pipefail

A="${1:-}"
B="${2:-}"
FAILURES=0

fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
note() { echo "report: $*"; }

for f in "$A" "$B"; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        fail "no log at '${f:-<none>}'; the differential has one side"
        note "totals decodiff failures=$FAILURES"
        exit "$FAILURES"
    fi
done

# By its report: prefix and not by position, for themediff.sh's reason: a run
# that failed a control of its own still wrote the line, and a run that never
# came up wrote none -- which is a different reading and has to stay different.
sampler() { sed -n "s/^report: sampler $2 //p" "$1" | head -1; }
val() { printf '%s' " $1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }

EA="$(sampler "$A" extent)"
EB="$(sampler "$B" extent)"

if [ -z "$EA" ] || [ -z "$EB" ]; then
    fail "one half reported no extent line at all; that half never got as far as a window"
    note "totals decodiff failures=$FAILURES"
    exit "$FAILURES"
fi

# The first token is the list of distinct extents; via= is the last field.
VIA_A="$(val "$EA" via)"; VIA_B="$(val "$EB" via)"
SET_A="${EA%% via=*}"; SET_B="${EB%% via=*}"

note "decorated extent=[$SET_A] via=$VIA_A"
note "chromeless extent=[$SET_B] via=$VIA_B"

# --- controls ---------------------------------------------------------------

# A run whose extent changed while the window was up is measuring two frames,
# and which of them any assertion below is about is not knowable.
for pair in "decorated:$SET_A:$VIA_A" "chromeless:$SET_B:$VIA_B"; do
    tag="${pair%%:*}"; rest="${pair#*:}"; set_v="${rest%%:*}"; via_v="${rest##*:}"
    case "$via_v" in
        moved) fail "control the $tag half's frame extents moved under the run; both readings are about different frames" ;;
        replay) fail "control the $tag half is a replay; it has no apparatus and cannot calibrate anything" ;;
    esac
    case "$set_v" in
        *" "*) fail "control the $tag half recorded more than one extent ($set_v); the frame changed mid-run" ;;
        none)  fail "control the $tag half recorded no extent at all" ;;
    esac
done

# The control this whole file turns on. Without it every zero below is
# unattributable, so it is a failure and not a note.
case "$SET_A" in
    0x0) fail "control the decorated half measured an extent of zero, so this display puts no frame on a window the launcher asked to be framed -- every reading below would be the instrument agreeing with itself, and none of them is evidence about the chromeless build" ;;
    ""|none) : ;;
    *) note "control the decorated half sees a frame: extent $SET_A" ;;
esac

# --- the reading ------------------------------------------------------------

if [ "$VIA_B" = absent ]; then
    fail "the chromeless half reports extent $SET_B with no reading behind it: nothing answered for the frame, so that zero is the fallback talking and not the window"
elif [ "$SET_B" != "0x0" ]; then
    fail "the chromeless half asked for no decorations and kept an extent of $SET_B"
else
    # Two ways to be right, and they are different measurements rather than two
    # spellings of one. `root` is the window manager having framed nothing at
    # all, read off the window tree; `read` is a frame that exists and is zero
    # thick, read off the hint. Both are answers. Which one a lane gives is a
    # fact about its window manager and is worth carrying in the log.
    case "$VIA_B" in
        root) note "the chromeless window was never framed: its parent is the root window, extent 0x0" ;;
        read) note "the chromeless window has a frame of zero thickness: extent 0x0, read from the hint" ;;
        *)    note "the chromeless window reports extent 0x0 via=$VIA_B" ;;
    esac
fi

# --- what the pair says about position --------------------------------------
#
# Not about decorations, and that is the point of asking it here. Two position
# tolerances survive in the app verifiers -- ten pixels on Windows and fifty on
# macOS -- and both compare a frame origin against a frame origin, so a
# decoration cannot move either. This is the reading that says so or does not:
# if the two halves put the window in the same place, position is
# decoration-independent and those numbers are paying for something else. It is
# a note this round because nothing has measured it before and a first reading
# is not an assertion.
# `framepos` and not the x11 origin line this first read: that line is written
# by one instrument and named for it (`xdotool_abs`), so the comparison could
# only ever run on the lanes that have xdotool. Both verifiers emit `framepos`
# and both mean the same thing by it -- the frame's outside corner at the
# probe's first state, before it moves anything.
PA="$(sampler "$A" framepos)"; PB="$(sampler "$B" framepos)"
if [ -n "$PA" ] && [ "$PA" != none ] && [ -n "$PB" ] && [ "$PB" != none ]; then
    if [ "$PA" = "$PB" ]; then
        note "position is decoration-independent: both halves launched at $PA"
    else
        note "position moved with the frame: decorated $PA, chromeless $PB"
    fi
else
    note "position not compared: framepos decorated=${PA:-none} chromeless=${PB:-none}"
fi

note "totals decodiff failures=$FAILURES"
exit "$FAILURES"
