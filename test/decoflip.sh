#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# decoflip.sh - the geometry probe launched twice, once framed and once not,
# and the differential that reads the pair.
#
# Usage: decoflip.sh <decorated.cmd> <chromeless.cmd> [screenshot-dir]
#
# The knob here is not an environment variable, it is which artifact is
# launched: `decorations` is stamped at assembly and there is no runtime
# spelling of it, which is the whole point of the key. So this flip has no
# knob to clear and no readback to take -- the two builds *are* the two states,
# and build.sh's own read-back has already asserted that each carries the value
# it was asked for.
#
# What it does share with themeflip.sh is the sequencing, and for the identical
# reason: both halves carry the STD-GEOM- prefix, so a window that outlived its
# kill is one the second verifier would attach to and report about. That is a
# reading from the wrong build which looks exactly like a real one -- and here
# it looks like the frame vanishing or refusing to, which is the reading this
# file exists to take.
#
# The decorated half runs first, and that is not arbitrary. It is the control:
# a chromeless extent of zero means nothing without a non-zero one beside it,
# because four different failures produce the same zero. If the chromeless half
# ran first and wedged, the step would die having published the reading and
# never the thing that says the instrument could see anything at all.

set -uo pipefail

DEC="${1:-test/neutrinostdgeom.cmd}"
NONE="${2:-test/neutrinostdgeom-none.cmd}"
SHOTS="${3:-$HOME/screenshots}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${NT_FLIP_LOGDIR:-$HOME}"

note() { echo "report: $*"; }

# Each half's own verifier exit, carried and added to the differential's at the
# end. themeflip.sh does not do this and is right not to: the theme step it
# runs beside still launches the probe standalone, so the probe's own controls
# already gate something. This file *replaces* the standalone geom run rather
# than running beside it, so dropping the halves' exits here would be the geom
# probe's controls quietly ceasing to fail the step -- the whole suite reduced
# to whatever the differential happens to ask.
HALF_FAILURES=0

case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    *)      PLATFORM=x11 ;;
esac

STATUS="${TMPDIR:-/tmp}/neutrino-title.txt"

# Lifted from themeflip.sh unchanged in meaning: x11 asks the server, macOS
# asks the status file the other way round, because a dead app leaves its last
# line behind forever and only a line that comes *back* means a live window.
prefix_up() {
    case "$PLATFORM" in
        macos)
            rm -f "$STATUS"
            sleep 1
            sed -n '1p' "$STATUS" 2>/dev/null | grep -q '^STD-GEOM-'
            ;;
        *)
            [ -n "$(xdotool search --name '^STD-GEOM-' 2>/dev/null | head -1)" ]
            ;;
    esac
}

wait_gone() {
    local n=0 limit=60
    [ "$PLATFORM" = macos ] && limit=30
    while [ "$n" -lt "$limit" ]; do
        prefix_up || return 0
        n=$((n + 1))
        [ "$PLATFORM" = macos ] || sleep 0.5
    done
    return 1
}

run_half() {
    local art="$1" tag="$2" pid rc=0
    if [ ! -f "$art" ]; then
        echo "FAIL: no artifact at '$art'; the $tag half cannot run"
        return 1
    fi
    [ "$PLATFORM" = macos ] && rm -f "$STATUS"
    bash "$art" > "$LOGDIR/deco-$tag-app.log" 2>&1 &
    pid=$!
    bash "$ROOT/test/verify-std.sh" geom "$SHOTS" > "$LOGDIR/deco-$tag.log" 2>&1 || rc=$?
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    note "half $tag artifact=$art verifier=$rc"
    HALF_FAILURES=$((HALF_FAILURES + rc))
    return 0
}

echo "decoflip.sh: decorated=$DEC chromeless=$NONE platform=$PLATFORM"

# Before anything is launched. A window left by an earlier step in this lane is
# exactly as poisonous as one left by the first half, and rather more likely:
# the geom step this runs inside has already had a window up under this prefix.
if prefix_up; then
    echo "FAIL: a STD-GEOM- window was already up before the first half started"
    echo "report: totals decoflip failures=1"
    exit 1
fi

run_half "$DEC" a || { echo "report: totals decoflip failures=1"; exit 1; }

if ! wait_gone; then
    echo "FAIL: the decorated half's window is still up; the chromeless half would read it"
    echo "report: totals decoflip failures=1"
    exit 1
fi
note "the decorated half's window is gone; the chromeless half may start"

run_half "$NONE" b || { echo "report: totals decoflip failures=1"; exit 1; }

DIFF_FAILURES=0
bash "$ROOT/test/decodiff.sh" "$LOGDIR/deco-a.log" "$LOGDIR/deco-b.log" || DIFF_FAILURES=$?

note "totals decoflip halves=$HALF_FAILURES differential=$DIFF_FAILURES"
exit $((HALF_FAILURES + DIFF_FAILURES))
