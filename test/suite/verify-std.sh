#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-std.sh - the instrument outside the page, for the web-standards probes.
#
# Usage: verify-std.sh <geom|doc> [screenshot-dir]
#
# The app under test is launched by the step, not by this: a suite may not start
# a program whose exit it does not control, and the launcher these artifacts
# carry detaches on one platform and holds a pipe open on another.
#
# Two things about its shape are load-bearing.
#
# It records first and asserts afterwards. The apps hold each state for 1500 ms;
# the verifiers beside this one wait for a title, then take a screenshot, then
# wait for the next, and on a loaded runner the gap between their own waits ran
# to three seconds -- so the state was gone before anything looked for it. Four
# PRs read that as a product stall. There is nothing in the loop below but the
# two reads the instrument needs, and every assertion runs on the record after
# the loop has finished.
#
# And it separates what it measures from what the page said. A field the page
# reported arrives in the title marked -SELF or -PAIR: -SELF is printed and
# never asserted, because a document's own account of its state is a diagnostic;
# -PAIR is printed beside the number this script measured, and a pair missing
# its outside half is a failure rather than a quiet degradation into a
# self-report.
#
# Exit status is the count of failed *controls*, never of readings. A reading is
# the point of the run and cannot be wrong; a control saying the window never
# came up, or that the instrument saw nothing change, means the run measured
# nothing and has to be repeated.

set -uo pipefail

PROBE="${1:-geom}"
SHOT_DIR="${2:-$HOME/screenshots}"
# What the picture is called, which is not what the probe is called.
#
# This wrote `std-$PROBE.png` for as long as one probe meant one launch. It has
# not meant that for three rounds: decoflip.sh launches the geometry probe
# decorated and then chromeless, themeflip.sh launches the theme probe on a
# light desktop and then a dark one, and themescheme.sh launches it a third time
# under a theme built to make the media query lie. Every one of those went to
# the same filename, so the suite took four pictures of the frame question and
# shipped the last, and five of the theme question and shipped the last -- and
# the last is the one no reader would guess. No artifact this repository has
# ever published contained a decorated window.
#
# The harness that knows which half it is running names the file; a lone launch
# keeps the old name, because that is the one the sheet and the eye already
# know.
SHOT_NAME="${NT_SHOT_NAME:-std-$PROBE}"
# Round zero. An instrument added in a hurry is code, and it gets run before it
# is pushed -- a one-line reporting call with an unterminated quote once cost a
# whole round. With a record captured from a previous run (or written by hand)
# this exercises every assertion below with no display, no engine and no window,
# which is the only way the analysis half can be tried on a desk that has none.
# It asserts nothing about the apparatus, so it never stands in for a real run.
REPLAY="${3:-}"

# Copied from the suites beside this one rather than invented. A budget that
# disagrees with its neighbours is either a finding about this suite or a flake
# waiting for a busy runner: verify-macos.sh allows 180 for a first window and
# says why, verify-offline.sh allows 90/60.
FIRST_TIMEOUT=180
# Sized to the app rather than copied from the probe beside it: the window probe
# holds thirteen states for 1500 ms each, plus settles and a fullscreen wait,
# which is over twenty seconds before anything slow happens. A budget copied
# from the shortest suite is a flake in the longest one.
RUN_TIMEOUT=90
[ "$PROBE" = win ] && RUN_TIMEOUT=150
POLL=0.05

FAILURES=0
WORK="$(mktemp -d)"
REC="$WORK/rec"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$SHOT_DIR"

fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
note() { echo "report: $*"; }

# The dwell is lifted out of the artifact rather than written here twice. A
# suite that samples something transient has to check its own slowest turn
# against the dwell, and it cannot do that against a number the app might have
# changed underneath it.
APP_JS="test/neutrinostd${PROBE}.js"
DWELL="$(sed -n 's/^var DWELL = \([0-9]*\);.*/\1/p' "$APP_JS" 2>/dev/null | head -1)"
[ -n "$DWELL" ] || DWELL=1500

# When the record has stopped growing, the app is done -- and that has to be a
# stop condition of its own, because for one probe the announced one cannot
# arrive.
#
# The loop below ends on a `*-END` title. The win probe's last act is
# `win.close()`, and neutrinostdwin.js says why in as many words: "it destroys
# the window every reading above went out through". STD-WIN-END is therefore
# written to a window that no longer exists and never reaches a title, so the
# loop polled a dead window until RUN_TIMEOUT expired -- every run, on every
# lane. Measured on run 33674586566: `turns=2468 transitions=13`, the last
# transition at 19.8 s, the step at 151 s. Five invocations do that per push --
# gjs, kde, linux-engines twice and macos -- which is about eleven minutes of
# CI spent watching a window that is gone. The doc and theme probes reach their
# own -END and finish in ten.
#
# Fifteen dwells of silence, which is deliberately far more than the app has
# ever needed. The widest gap between two consecutive transitions on x11 is
# 2375 ms, measured on the run above, so this is nine times the largest interval
# anything here has actually taken.
#
# Nine and not three because of where the number cannot be checked: macOS has no
# millisecond clock in this file -- every `ms` column in its record is 0, and the
# note beside the sampler says so -- so the one platform whose runner is slowest
# is also the one whose real gaps are unmeasured here. A bound that truncates a
# record turns a passing lane red for a reason that is about this line, and that
# is a worse failure than a slow lane. The floor is twenty seconds for the same
# reason: a dwell small enough to make this tight is a finding about the app,
# not a licence to stop watching sooner.
#
# RUN_TIMEOUT stays exactly as it was. It answers "has this stopped", which is
# a different question from "has this finished", and a run that reaches it is
# still the failure it always was -- the report line below says which of the
# two ended the loop.
IDLE_LIMIT=$(( DWELL * 15 / 1000 ))
[ "$IDLE_LIMIT" -ge 20 ] || IDLE_LIMIT=20

case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    *)      PLATFORM=x11 ;;
esac

# Probe-specific, and not the shared "STD-" it started as. Two probe steps run
# back to back in the same lane against the same display, and the first one's
# app is one written never to close -- so a window the previous step failed to
# reap is a window this one would attach to and report about. A phase may not
# begin while the previous phase's window is still up, and the cheapest way to
# hold that is to make it impossible to match the wrong one.
PREFIX="STD-$(echo "$PROBE" | tr '[:lower:]' '[:upper:]')-"

# GNU date only. On macOS the status file carries a tick counter of its own,
# which is the better clock anyway: 200 ms a tick, written by the thing being
# measured rather than by the thing measuring it.
#
# Probed once, here, and never again. The first spelling of this ran `date`
# twice and a `grep` on every call and was about to be put in the hot loop --
# an instrument that costs more than the thing it is timing measures itself.
HAVE_MS=0
case "$(date +%s%3N 2>/dev/null)" in
    *[!0-9]*|"") HAVE_MS=0 ;;
    *) HAVE_MS=1 ;;
esac
now_ms() { if [ "$HAVE_MS" = 1 ]; then date +%s%3N; else echo 0; fi; }

# ---------------------------------------------------------------- x11 instrument

X11_WID=""
FE_L=0; FE_R=0; FE_T=0; FE_B=0
# The first reading, held so the second one has something to disagree with.
FE_FIRST=""

# The window manager's own list of managed top-levels, and not `xdotool search`.
#
# xdotool matches any window carrying the name, and GTK gives that name to more
# than the toplevel: on the metacity lane the search returned a window whose
# offset inside its parent was 26,60 while the decoration is 0,37 -- an inner
# window, measured as though it were the frame. The kde lane happened to return
# its toplevel, so half the readings were about one kind of window and half
# about another, and the arithmetic could not have told anyone.
#
# _NET_CLIENT_LIST is what the window manager considers a managed toplevel, so
# a match in it is the window with the frame around it by definition. The old
# search stays as a fallback for a bare X server with no compliant WM, and says
# so, because a reading taken that way is not the same reading.
X11_SRC="?"
x11_toplevels() {
    xprop -root _NET_CLIENT_LIST 2>/dev/null |
        sed -n 's/.*# *//p' | tr ',' '\n' | tr -d ' ' | grep '^0x'
}

x11_find() {
    local deadline=$((SECONDS + FIRST_TIMEOUT)) wid name dec
    while [ $SECONDS -lt $deadline ]; do
        for wid in $(x11_toplevels); do
            name="$(xdotool getwindowname "$((wid))" 2>/dev/null)"
            case "$name" in
                "$PREFIX"*) X11_WID="$((wid))"; X11_SRC="_NET_CLIENT_LIST"; return 0 ;;
            esac
        done
        wid="$(xdotool search --name "^$PREFIX" 2>/dev/null | head -1)"
        if [ -n "$wid" ]; then
            X11_WID="$wid"; X11_SRC="xdotool-search"
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# Read before the loop and again after it. Frame extents are a property of the
# frame the window manager put around this window and do not change while it is
# up -- but "does not change" is the thing a suite that asserts on the extent
# has to have measured rather than assumed, and reading a constant twice is two
# xprop calls, not a call per turn. The hot path still has none.
#
# Three outcomes and not two. `FE_SRC` carries which one, because a chromeless
# window and a window manager that does not answer produce the same four zeros
# by two completely different routes -- one is the measurement this suite
# exists to take and the other is silence wearing its clothes. A caller that
# asserts an extent of zero has to be able to tell them apart, and the only
# thing that can tell them apart is this variable.
#
#   read     the hint answered, and the four numbers below are what it said
#   absent   nothing answered; the four numbers are a fallback, not a reading
#   moved    it answered twice and disagreed with itself
FE_SRC="absent"
x11_read_extents() {
    local line out=""
    line="$(xprop -id "$X11_WID" _NET_FRAME_EXTENTS 2>/dev/null)"
    case "$line" in
        *=*)
            line="${line#*= }"
            out="$(echo "$line" | cut -d, -f1 | tr -d ' '),$(echo "$line" | cut -d, -f2 | tr -d ' '),$(echo "$line" | cut -d, -f3 | tr -d ' '),$(echo "$line" | cut -d, -f4 | tr -d ' ')"
            ;;
    esac
    case "$out" in
        *[!0-9,]*|""|,,,) echo "" ;;
        *) echo "$out" ;;
    esac
}

# Whether the window manager put this window inside a frame at all, asked of
# the window tree rather than of a hint.
#
# This is the question CI answered on the first round and it is not the one the
# hint answers. metacity, measured: a decorated window carries
# _NET_FRAME_EXTENTS `0,0,37,0`, and an undecorated one **does not carry the
# property at all** -- so a chromeless extent can never be read from it, and
# every zero it produces is the fallback. Reading the tree instead turns that
# absence into a positive reading: a window whose parent is the root window is
# a window nothing framed, and its frame is its client area by observation.
#
# It also fixes the origin. xwininfo reports "Relative upper-left" against the
# parent, so for an unreparented window that is the absolute position and not
# an offset into anything -- `abs - rel` came out `0,0` and the apparatus
# control failed comparing 62,84 against it. A control that cannot pass is not
# a control, and this one could not pass on any window without a frame.
X11_PARENT=""; X11_ROOT=""
x11_reparented() {
    local tree
    tree="$(xwininfo -id "$X11_WID" -tree 2>/dev/null)"
    [ -n "$tree" ] || return 2
    X11_PARENT="$(printf '%s' "$tree" | sed -n 's/.*Parent window id: *\(0x[0-9a-fA-F]*\).*/\1/p' | head -1)"
    X11_ROOT="$(printf '%s' "$tree" | sed -n 's/.*Root window id: *\(0x[0-9a-fA-F]*\).*/\1/p' | head -1)"
    [ -n "$X11_PARENT" ] && [ -n "$X11_ROOT" ] || return 2
    [ "$((X11_PARENT))" != "$((X11_ROOT))" ]
}

x11_frame_extents() {
    # Asked first, because its answer decides whether the hint's silence is a
    # reading or a gap.
    x11_reparented
    case "$?" in
        1)  FE_L=0; FE_R=0; FE_T=0; FE_B=0
            FE_FIRST="0,0,0,0"
            FE_SRC="root"
            note "the window manager framed nothing: parent $X11_PARENT is the root window, so the frame is the client area"
            return ;;
        2)  note "could not read the window tree; falling back to the frame-extents hint" ;;
    esac
    FE_FIRST="$(x11_read_extents)"
    if [ -z "$FE_FIRST" ]; then
        FE_L=0; FE_R=0; FE_T=0; FE_B=0
        FE_SRC="absent"
        note "no _NET_FRAME_EXTENTS; outer is reported as inner"
        return
    fi
    FE_L="$(echo "$FE_FIRST" | cut -d, -f1)"
    FE_R="$(echo "$FE_FIRST" | cut -d, -f2)"
    FE_T="$(echo "$FE_FIRST" | cut -d, -f3)"
    FE_B="$(echo "$FE_FIRST" | cut -d, -f4)"
    FE_SRC="read"
}

# The second read, after the loop. What it is for: the extent is derived from a
# value this file reads once, so `extent(A) == extent(B) == extent(C)` across
# the turns is true by construction on this platform and could not have failed
# for any reason. That is an assertion that cannot fail for the reason it
# exists. Reading the hint again at the end is what turns the constant into a
# measured one, and a window that was reframed mid-run now says so.
# Whether the window this script has been reading is still there at all.
# `xprop -id` on a window that has gone answers nothing and exits non-zero,
# which is the same silence a hint that stopped being set would produce.
x11_alive() {
    xprop -id "$X11_WID" WM_CLASS >/dev/null 2>&1
}

x11_recheck_extents() {
    local second
    # A probe that closes its own window is not a frame that changed.
    # Measured on `kde-stdwin`, which ends on STD-WIN-CLOSE-PAIR: the recheck
    # ran after the window was gone, read nothing, and called it `moved` --
    # and `moved` is a control failure in decodiff.sh, so a probe that closes
    # itself would have failed the differential for finishing correctly.
    # Asked before either branch below, because both of them read the same
    # silence and neither can tell what produced it.
    if ! x11_alive; then
        note "the window closed before the extents could be re-read; the reading stands as taken"
        return
    fi
    # A window that was unreparented at the start and framed by the end is the
    # same kind of finding as extents that moved, and it is the one this
    # branch's whole reading rests on -- so it is asked, not skipped.
    if [ "$FE_SRC" = root ]; then
        if x11_reparented; then
            FE_SRC="moved"
            note "the window was unframed at the start of the run and framed by the end"
        fi
        return
    fi
    [ "$FE_SRC" = read ] || return
    second="$(x11_read_extents)"
    if [ -z "$second" ]; then
        FE_SRC="moved"
        note "the frame extents answered at the start and not at the end"
    elif [ "$second" != "$FE_FIRST" ]; then
        FE_SRC="moved"
        note "the frame extents moved under the run: $FE_FIRST then $second"
    fi
}

# The same offset, asked of X a second way. The frame's origin is conventionally
# `absolute upper-left minus relative upper-left`, and _NET_FRAME_EXTENTS is
# the hint that is *supposed* to equal the relative part -- so reading both says
# whether this script's arithmetic is the standard one before any conclusion
# rests on it. Round 1 needed exactly this and did not have it: the page and the
# harness disagreed about where the window was by a constant, and with one
# formula there was no way to tell an arithmetic error from an engine's answer.
#
# Once, before the loop. A reparenting offset does not change while a window is
# up, and putting xwininfo in the hot path would cost a turn per frame for a
# constant.
# The offset, and the evidence that it is not the decoration.
#
# Measured, on a real window manager: `_NET_FRAME_EXTENTS` came back
# `0, 0, 28, 0` while xwininfo's relative upper-left was `10, 36`. They are not
# the same quantity -- the hint describes the decoration a person can see, and
# the offset is where the client sits inside a frame window that can be larger
# than that, because a frame carries invisible resize borders as well as a
# title bar. The same disagreement is on the metacity lane, `0,0,37,0` against
# `26,60`, and 04-step3.png settles which one the picture agrees with: the
# title bar in it measures 37 rows.
#
# So an origin wants both, and wants them in order. The offset undoes xdotool
# and lands on the client corner; the thickness comes off that and lands on the
# frame's. Round 1 subtracted the extents alone from a number that already
# needed the offset taken off it, got a constant wrong, and concluded the
# extents were the wrong quantity for an origin. They were the wrong quantity
# on their own.
REL_X=0; REL_Y=0; REL_SRC="none"
XW_ABS=""; XW_REL=""; XD_ABS=""
x11_reparent_offset() {
    local info ax ay rx ry
    info="$(xwininfo -id "$X11_WID" 2>/dev/null)"
    [ -n "$info" ] || { note "xwininfo said nothing; the frame origin is derived from extents alone"; return; }
    ax="$(printf '%s' "$info" | sed -n 's/.*Absolute upper-left X: *\([0-9-]*\).*/\1/p' | head -1)"
    ay="$(printf '%s' "$info" | sed -n 's/.*Absolute upper-left Y: *\([0-9-]*\).*/\1/p' | head -1)"
    rx="$(printf '%s' "$info" | sed -n 's/.*Relative upper-left X: *\([0-9-]*\).*/\1/p' | head -1)"
    ry="$(printf '%s' "$info" | sed -n 's/.*Relative upper-left Y: *\([0-9-]*\).*/\1/p' | head -1)"
    XW_ABS="${ax:-?},${ay:-?}"
    XW_REL="${rx:-?},${ry:-?}"
    # Only where there is a frame to be offset inside. xwininfo reports the
    # relative upper-left against the *parent*, so on an unreparented window
    # that is the absolute position rather than an offset, and subtracting it
    # puts every origin at 0,0 -- which is what failed the apparatus control on
    # every GTK lane the first time a chromeless window was measured.
    #
    # `root` is not a degraded reading here. A window nothing reparented has an
    # offset of zero inside its frame, and that is the answer, not a default.
    if [ "$FE_SRC" = root ]; then
        REL_X=0; REL_Y=0; REL_SRC="root"
    else
        case "${rx:-x}${ry:-x}" in
            *[!0-9-]*|"") ;;
            *) REL_X="$rx"; REL_Y="$ry"; REL_SRC="xwininfo" ;;
        esac
    fi
    # Two routes to the same corner, so the subtraction below can be checked
    # rather than trusted. xwininfo's absolute upper-left is the frame's outside
    # corner directly; xdotool's position is the client origin, which is that
    # corner plus the reparent offset. So `xdotool - rel` and `xwininfo` are the
    # same point by two different paths, and they agreeing is what says the
    # arithmetic is sound.
    #
    # The first spelling of this compared the two numbers raw and failed every
    # x11 lane in a round: they are not the same quantity and were never going
    # to be equal -- their difference *is* rel. A control that cannot pass is
    # not a control, and it cost exactly what a red control costs.
    X=""; Y=""
    eval "$(xdotool getwindowgeometry --shell "$X11_WID" 2>/dev/null)" 2>/dev/null
    XD_ABS="${X:-?},${Y:-?}"
}

# ------------------------------------------------------------- macos instrument

STATUS_FILE="${TMPDIR:-/tmp}/neutrino-title.txt"

macos_wait() {
    local deadline=$((SECONDS + FIRST_TIMEOUT)) t
    while [ $SECONDS -lt $deadline ]; do
        t="$(sed -n '1p' "$STATUS_FILE" 2>/dev/null)"
        case "$t" in "$PREFIX"*) return 0 ;; esac
        sleep 0.2
    done
    return 1
}

# ------------------------------------------------------------------- the loop

# One turn writes one line: title, inner WxH, position X,Y, outer WxH, tick.
# Nothing else happens in here. Screenshots, arithmetic and every assertion are
# after it, off the record.
record() {
    local deadline=$((SECONDS + RUN_TIMEOUT))
    local idle_deadline=$((SECONDS + IDLE_LIMIT))
    local turns=0 last="" t inner pos outer tick raw start ms prev gap
    local l1 l2 l3 l4 l5 l6 l7
    start="$(now_ms)"; prev="$start"; ms=0
    while [ $SECONDS -lt $deadline ]; do
        turns=$((turns + 1))
        if [ "$PLATFORM" = x11 ]; then
            t="$(xdotool getwindowname "$X11_WID" 2>/dev/null)"
            # Cleared before the eval, not after it. xdotool writes nothing when
            # the window has gone, and the shell would then keep answering with
            # the last live geometry -- a window that vanished and a window that
            # stopped moving are different readings.
            X=""; Y=""; WIDTH=""; HEIGHT=""
            eval "$(xdotool getwindowgeometry --shell "$X11_WID" 2>/dev/null)" 2>/dev/null
            inner="${WIDTH:-0}x${HEIGHT:-0}"
            # Two subtractions and they take away different things. The first
            # undoes xdotool, whose Position carries the reparenting offset
            # already -- `88,181` where xwininfo's absolute says `62,121` under
            # metacity, `63,104` against `62,84` under openbox -- and lands on
            # the *client* corner. The second takes the decoration off it and
            # lands on the frame's, which is the corner the other two platforms
            # report and the one `framepos` hands to decodiff.sh.
            #
            # Only the first was here until this round, and the page said so:
            # this loop and QtWebEngine disagreed by a constant "that the frame
            # extents do not explain" on two of three x11 lanes. The extents
            # explain it exactly. The engine was reporting the frame and this
            # was reporting the client, and the constant between them was the
            # title bar.
            pos="$((${X:-0} - REL_X - FE_L)),$((${Y:-0} - REL_Y - FE_T))"
            outer="$(( ${WIDTH:-0} + FE_L + FE_R ))x$(( ${HEIGHT:-0} + FE_T + FE_B ))"
            # What X actually said, beside what this script made of it. Round 1
            # validated the size arithmetic -- computed outer matched
            # QtWebEngine's own outerWidth to the pixel on that lane -- and did
            # not validate the position arithmetic. A derived number and the
            # number it was derived from are two different readings, and only
            # one of them can be wrong; carrying both is how the next round
            # says which.
            raw="${X:-0},${Y:-0}"
            tick="$turns"
        else
            l1=""; l2=""; l3=""; l4=""; l5=""; l6=""; l7=""
            { read -r l1; read -r l2; read -r l3; read -r l4; read -r l5; read -r l6; read -r l7; } \
                < "$STATUS_FILE" 2>/dev/null
            # Line 3 is already the frame's top-left, converted by the driver
            # from AppKit's bottom-left origin. Nothing is derived here, so raw
            # and pos are the same number and the field says so rather than
            # being left empty for a reader to interpret.
            t="$l1"; outer="$l2"; pos="$l3"; inner="$l4"; tick="${l7:-0}"; raw="$l3"
        fi
        [ -n "$t" ] || t="<none>"
        if [ "$HAVE_MS" = 1 ]; then
            now="$(now_ms)"
            ms=$((now - start))
            gap=$((now - prev))
            [ "$gap" -gt "$MAX_TURN_GAP" ] && MAX_TURN_GAP="$gap"
            prev="$now"
        fi
        if [ "$t" != "$last" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ms" "$t" "$inner" "$pos" "$outer" "$tick" "$raw" >> "$REC"
            last="$t"
            idle_deadline=$((SECONDS + IDLE_LIMIT))
        fi
        case "$t" in *-END) STOPPED_BY=end; break ;; esac
        if [ $SECONDS -ge $idle_deadline ]; then
            STOPPED_BY=idle
            break
        fi
        sleep "$POLL"
    done
    TURNS="$turns"
    ELAPSED_MS="$ms"
}

# field(), titles(), the apparatus check and the five analysers moved to
# test/lib/analyse.sh, which the Windows lane now runs too. Sourced rather
# than shelled out to here: this file still has a sampling loop above it that
# sets MAX_TURN_GAP and STOPPED_BY, and those are inputs the analysers read.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/analyse.sh"

# The gap between two recorded transitions is what says whether this loop was
# watching or sampling. On x11 that is milliseconds; on macOS it is the app's
# own tick counter, which is the honest one -- 200 ms a tick, and the file is
# written by the thing being measured rather than by the thing measuring it.
# Set by record(), which is the only place it can be: the record holds
# transitions, and transitions are a dwell apart on purpose. What says whether
# this loop was watching is the interval between two consecutive *polls*, and
# nothing after the loop can reconstruct it.
MAX_TURN_GAP=-1

# Which of the three ways out of the record loop was taken: the app's own -END,
# the record going quiet, or RUN_TIMEOUT. Only the last of those is a lane that
# stopped rather than finished, and until this was printed the three were
# indistinguishable from outside.
STOPPED_BY=deadline


# The picture, and when to take it.
#
# `win` is photographed as soon as its window is up and settled; every other
# probe after the record loop. That is not a preference, it is what the probes
# do: the window probe's last state is `STD-WIN-CLOSE-PAIR`, where it closes its
# own window on purpose, because `close()` is one of the standard verbs under
# test. A shutter that fires after the analysis therefore photographs an empty
# desktop, and `std-win.png` has been a 1024x768 black rectangle in every
# artifact on every lane since that probe landed. It survived because nobody
# opens a directory of PNGs to look at one they did not come for.
#
# The others end on an `-END` state with the window still up, which the
# `onscreen at capture` line beside each of them now says out loud.
shoot() {
    # Declared local, and not for tidiness. $PROBE is this script's probe name --
    # geom, doc, win, theme -- and the shutter here briefly had a variable of its
    # own by that name holding a path to a scratch PNG. The `win` lane is the one
    # photographed before the record loop rather than after it, so everything
    # downstream read the shutter's value: it failed its own analysis with "no
    # analysis for probe '/var/.../neutrino-shot-probe.png'", then took a second
    # picture -- of the desktop after the probe had closed its window -- over the
    # first. A function called once can still be what breaks every line after it.
    local ONSCREEN w WID SHOT_PROBE SHOT_HOW N
    if [ "$PLATFORM" = x11 ]; then
        ONSCREEN=""
        for w in $(x11_toplevels); do
            ONSCREEN="$ONSCREEN[$(xdotool getwindowname "$((w))" 2>/dev/null)] "
        done
        # Plain echo and not note(): `report:` marks the lines a reader scans
        # for a result, and this is a diagnostic about the room rather than a
        # reading from the probe.
        echo "  onscreen at capture: ${ONSCREEN:-<none>}"
        case "$ONSCREEN" in
            "") echo "  onscreen: nothing is on screen" ;;
            *"]"*"]"*) echo "  onscreen: this desktop has more than one window on it" ;;
        esac
        # The whole root window, and not the probe's own.
        #
        # This lane cropped to the window for a while, and the reason was real:
        # the desktop is not this lane's to control, and `gjs` reported "Google
        # Chrome and ChromeOS Additional Terms of Service" on seven of its eight
        # captures in the first run that asked -- the offline probe's
        # openExternal control hands a url to the machine's browser, which is
        # the point of that control, and Chrome's first-run dialog then sits
        # over every picture the lane takes afterwards.
        #
        # Those windows have not gone anywhere; cropping only moved them out of
        # the frame. A sheet is read to find out what the machine was doing, so
        # the dialog belongs in the picture, where a reader can see it and name
        # it -- and the `onscreen at capture` line above names it too, so no
        # reader has to mistake the top window for the subject.
        #
        # The frame comes along for free: a root capture holds the title bar and
        # border that the decoration pair exists to compare, which is what
        # `-frame` was buying before.
        import -window root "$SHOT_DIR/$SHOT_NAME.png" 2>/dev/null || true
        echo "  shot: the whole root window"
    else
        # The whole display, and not just the probe's own window.
        #
        # Same rule as the x11 half above and as verify-macos.sh, whose own copy
        # of this carries the long version: a sheet is read to see the machine,
        # and `screencapture -l` composites one window and shows nothing else.
        # The system consent sheet -- "bash is requesting to bypass the system
        # private window picker" -- is back in these frames with everything
        # else on the desktop, which is the cost of photographing the desktop.
        #
        # The `-l` call survives as the shutter's wait, not as the picture. A
        # window has a CGWindowID before it is composited, and compositing it is
        # the one thing that can tell the difference; the probe writes to a
        # scratch file nobody keeps and the display shot follows it. The number
        # is line 8 of the status file the launcher writes under the testing
        # tier, and a lane whose app never came up has none -- so the display
        # shot is taken anyway, saying that nothing was waited for. The window
        # probe closes its own window on purpose, which is that case too.
        WID="$(sed -n '8p' "$STATUS_FILE" 2>/dev/null)"
        SHOT_PROBE="${TMPDIR:-/tmp}/neutrino-shot-probe.png"
        case "$WID" in
            ''|*[!0-9]*)
                SHOT_HOW="the whole display; the launcher reported no window number, so nothing was waited for" ;;
            *)
                N=0
                SHOT_HOW="the whole display; window $WID never became capturable"
                while [ "$N" -lt "${NT_SHOT_TRIES:-24}" ]; do
                    if screencapture -x -o -l "$WID" "$SHOT_PROBE" 2>/dev/null &&
                       [ -s "$SHOT_PROBE" ]; then
                        SHOT_HOW="the whole display, with the probe's window (CGWindowID $WID) on it after $((N * 250))ms"
                        break
                    fi
                    N=$((N + 1))
                    sleep 0.25
                done
                rm -f "$SHOT_PROBE" ;;
        esac
        screencapture -x "$SHOT_DIR/$SHOT_NAME.png" 2>/dev/null || true
        echo "  shot: $SHOT_HOW"
        # No `onscreen at capture` line on this half. The x11 branch above gets
        # one from xdotool, which answers; the macOS probe is blind unless the
        # asking process holds the screen recording permission, and it printed
        # "nothing is on screen" beside fourteen pictures with windows in them.
        # A diagnostic that is wrong in the same direction every time is worse
        # than none, and shotroom-macos.sh keeps the probe where the answer can
        # be checked against the file it prints beside it.
    fi
}

# ----------------------------------------------------------------------- main

echo "verify-std.sh: probe=$PROBE platform=$PLATFORM dwell=${DWELL}ms"

if [ -n "$REPLAY" ]; then
    [ -f "$REPLAY" ] || { echo "FAIL: no record at '$REPLAY'"; exit 1; }
    cp "$REPLAY" "$REC"
    TURNS="$(wc -l < "$REC" | tr -d ' ')"
    # Same reason as FE_SRC below: no loop ran here, so naming one of the three
    # ways out of it would be this file reporting a measurement it never took.
    STOPPED_BY="replay"
    echo "verify-std.sh: replaying $REPLAY -- apparatus checks are not a measurement here"
    # A fourth value, and it is not one of the three the reader can return: no
    # window was opened here, so the hint was neither read nor missing. Saying
    # `absent` would be this file reporting a window manager it never asked.
    FE_SRC="replay"
    check_apparatus
    nt_analyse "$PROBE"
    echo "--- recorded transitions (ms / title / inner / pos / outer / tick) ---"
    cat "$REC"
    note "totals probe=$PROBE failures=$FAILURES"
    exit "$FAILURES"
fi

if [ "$PLATFORM" = x11 ]; then
    if ! x11_find; then
        fail "no window named /^$PREFIX/ appeared within ${FIRST_TIMEOUT}s"
        note "totals failures=$FAILURES"
        exit "$FAILURES"
    fi
    x11_frame_extents
    x11_reparent_offset
else
    if ! macos_wait; then
        fail "no $PREFIX title appeared in $STATUS_FILE within ${FIRST_TIMEOUT}s"
        note "totals failures=$FAILURES"
        exit "$FAILURES"
    fi
fi

[ "$PROBE" = win ] && shoot

: > "$REC"
record

# After the loop, before anything is asserted. The extent every assertion below
# reads was taken before the first turn; this is what says it was still true at
# the last one.
[ "$PLATFORM" = x11 ] && x11_recheck_extents

check_apparatus
nt_analyse "$PROBE"

# After the loop, never inside it -- a full-screen PNG encode is exactly the
# slow thing this file's header forbids in the sampling loop. The full record
# goes to the log and the artifact; the digest above is what carries the
# `report:` prefix a reader scans for.
[ "$PROBE" = win ] || shoot
echo "--- recorded transitions (ms / title / inner / pos / outer / tick / raw) ---"
cat "$REC"

note "totals probe=$PROBE failures=$FAILURES"
exit "$FAILURES"
