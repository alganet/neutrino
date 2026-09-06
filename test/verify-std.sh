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

# Every distinct title the loop saw, in order, with what was measured beside it.
field() { awk -F'\t' -v n="$1" -v want="$2" '$2 ~ want { print $n; exit }' "$REC"; }
# State names only. The full titles are in the record dumped at the end; a
# sequence line that repeats a whole -SELF payload says twice what the self line
# beside it already said once.
titles() { awk -F'\t' '{ print $2 }' "$REC" | awk '{ print $1 }' | tr '\n' ' '; }

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

# ------------------------------------------------------------------ assertions

check_apparatus() {
    local rows gap
    rows="$(wc -l < "$REC" | tr -d ' ')"
    gap="$MAX_TURN_GAP"
    note "sampler platform=$PLATFORM turns=${TURNS:-0} transitions=$rows dwell_ms=$DWELL max_turn_gap_ms=$gap stopped_by=$STOPPED_BY idle_limit_s=$IDLE_LIMIT"
    if [ "$PLATFORM" = x11 ]; then
        note "sampler frame_extents l=$FE_L r=$FE_R t=$FE_T b=$FE_B wid=$X11_WID via=$X11_SRC"
        # Two routes to the *client* corner, printed beside each other so the
        # subtraction the loop makes can be checked rather than trusted:
        # xwininfo's absolute upper-left is that corner directly, and xdotool's
        # Position is the same corner with the reparenting offset added to it.
        # They agreeing is what says `xdotool minus rel` is sound -- which is
        # all it ever said. It is not a frame origin and calling it one is what
        # let this file report a client corner as a frame for three rounds; the
        # frame is that corner minus the decoration, and the line below prints
        # both so neither can stand in for the other again.
        local client="" framed=""
        case "$XD_ABS" in
            *[0-9]*,*[0-9]*) client="$(( ${XD_ABS%%,*} - REL_X )),$(( ${XD_ABS##*,} - REL_Y ))" ;;
        esac
        case "$client" in
            *[0-9]*,*[0-9]*) framed="$(( ${client%%,*} - FE_L )),$(( ${client##*,} - FE_T ))" ;;
        esac
        note "sampler origin rel=${XW_REL:-?} src=$REL_SRC xwininfo_abs=${XW_ABS:-?} xdotool_abs=${XD_ABS:-?} client=${client:-?} frame=${framed:-?}"
        if [ -n "$XW_ABS" ] && [ -n "$client" ] && [ "$XW_ABS" != "$client" ]; then
            fail "the client corner differs by route (xwininfo says $XW_ABS, xdotool minus rel says $client); every position below is the second route"
        fi
        if [ "$REL_SRC" = none ]; then
            note "sampler no reparent offset available; positions are raw and underived"
        fi
    fi
    # The decoration, named. It is a difference between two columns this file
    # has recorded on every lane since it was written, and until now nothing
    # said so out loud -- which is how a fifty-pixel tolerance in the suite next
    # door went on standing in for a number that was already being measured
    # three feet away.
    #
    # Every distinct value across the run, not the first: a thickness that
    # changed while the window was up is a finding, and printing one value would
    # hide it. On x11 the pair below has to be read with `via=`, because there
    # the outer column is derived from a hint read once and a zero extent can
    # mean the hint said zero or that nothing answered at all.
    # Only the rows the app had arrived in -- the same gate verify-std.ps1
    # applies, and one rule rather than two. It is a no-op here, because this
    # side finds its window by the prefix and so never records a turn before
    # it; it is written anyway so the two files cannot drift into measuring
    # different sets of rows.
    local extents
    extents="$(awk -F'\t' -v pre="$PREFIX" '
        index($2, pre) != 1 { next }
        $3 ~ /^[0-9]+x[0-9]+$/ && $5 ~ /^[0-9]+x[0-9]+$/ {
            split($3, i, "x"); split($5, o, "x")
            e = (o[1] - i[1]) "x" (o[2] - i[2])
            if (!(e in seen)) { seen[e] = 1; out = out (out == "" ? "" : " ") e }
        }
        END { print out }
    ' "$REC")"
    if [ "$PLATFORM" = x11 ]; then
        note "sampler extent ${extents:-none} via=$FE_SRC"
    else
        note "sampler extent ${extents:-none} via=live"
    fi
    # The frame origin at the probe's *first* state, under one name both
    # platforms emit, so the differential has a position to compare without
    # knowing which instrument took it. It is a frame on all three of them as
    # of this round: macOS reports one, Windows reports one, and x11 now takes
    # the decoration off the client corner instead of handing decodiff.sh a
    # client corner named `framepos`.
    #
    # The first state and not the last, because the probe moves the window on
    # purpose partway through: the only turn where the two halves are answering
    # the same question is the one before either of them was asked to move.
    local firstpos
    firstpos="$(awk -F'\t' -v pre="$PREFIX" 'index($2, pre) == 1 { print $4; exit }' "$REC")"
    note "sampler framepos ${firstpos:-none}"
    if [ "$rows" -lt 2 ]; then
        fail "the instrument recorded $rows transition(s); it saw no window change at all"
    fi
    # The one failure mode this branch has already paid for. On the macOS
    # bridge, String() of an ObjC wrapper is its description and not its
    # contents, so a title read the wrong way arrives as `[id __NSCFString]`.
    # It costs one line to name, and without it the symptom is five suites
    # timing out on a channel that looks like it is being written normally.
    if grep -q "$(printf '\t')\[id " "$REC"; then
        fail "a recorded title is an ObjC wrapper's description, not a title; something wrote it without unwrapping"
    fi
    if [ "$gap" = "-1" ]; then
        note "sampler no millisecond clock here; the completeness of the record below is the control"
    elif [ "$gap" -ge "$DWELL" ]; then
        fail "the slowest turn was ${gap}ms against a ${DWELL}ms dwell; this run sampled, it did not watch"
    fi
}

analyse_geom() {
    local a b c r
    a="$(field 2 '^STD-GEOM-A-PAIR')"
    b="$(field 2 '^STD-GEOM-B-PAIR')"
    c="$(field 2 '^STD-GEOM-C-PAIR')"
    r="$(field 2 '^STD-GEOM-R-SELF')"

    local ai ao ap bi bo bp ci co cp
    ai="$(field 3 '^STD-GEOM-A-PAIR')"; ao="$(field 5 '^STD-GEOM-A-PAIR')"; ap="$(field 4 '^STD-GEOM-A-PAIR')"
    bi="$(field 3 '^STD-GEOM-B-PAIR')"; bo="$(field 5 '^STD-GEOM-B-PAIR')"; bp="$(field 4 '^STD-GEOM-B-PAIR')"
    ci="$(field 3 '^STD-GEOM-C-PAIR')"; co="$(field 5 '^STD-GEOM-C-PAIR')"; cp="$(field 4 '^STD-GEOM-C-PAIR')"

    [ -n "$a" ] || fail "STD-GEOM-A-PAIR was never observed"
    [ -n "$b" ] || fail "STD-GEOM-B-PAIR was never observed"
    [ -n "$c" ] || fail "STD-GEOM-C-PAIR was never observed"

    local ar br cr
    ar="$(field 7 '^STD-GEOM-A-PAIR')"; br="$(field 7 '^STD-GEOM-B-PAIR')"; cr="$(field 7 '^STD-GEOM-C-PAIR')"
    [ -n "$a" ] && note "pair A page=[${a#STD-GEOM-A-PAIR }] native inner=$ai outer=$ao pos=$ap raw=$ar"
    [ -n "$b" ] && note "pair B page=[${b#STD-GEOM-B-PAIR }] native inner=$bi outer=$bo pos=$bp raw=$br"
    [ -n "$c" ] && note "pair C page=[${c#STD-GEOM-C-PAIR }] native inner=$ci outer=$co pos=$cp raw=$cr"
    [ -n "$r" ] && note "self ${r#STD-GEOM-R-SELF }"

    # The one -SELF reading in this file that is asserted, and the exception
    # earns its lines. The rule everywhere else is that a document's account of
    # itself is a diagnostic and the instrument outside it is the reading --
    # sound, because the window is the thing in question and the page's view of
    # it can be wrong. Here the question is whether the API was in scope when
    # the app's own first statement ran, and no instrument outside the document
    # can see that. The page is not the best witness, it is the only one.
    #
    # Asserted rather than printed because `pages/demo.js` stopped polling for
    # the API on the strength of it, and a guarantee nothing checks is a
    # comment. A lane that starts registering the API later fails here instead
    # of in the sample app, which nothing in CI builds.
    case "$r" in
        "")        fail "control STD-GEOM-R-SELF was never observed; readiness went unmeasured this run" ;;
        *nt0=yes*) note "control the API was in scope at the app's first statement (nt0=yes)" ;;
        *)         fail "control nt0=$(printf '%s' "$r" | sed -n 's/.*nt0=\([^ ]*\).*/\1/p'); window.neutrino was not in scope at the app's first statement, and pages/demo.js no longer waits for it" ;;
    esac

    # The number four drivers have been disagreeing about. resize(640,480) means
    # ClientSize on Windows, the outer frame on macOS and the toplevel size on
    # the two GTK lanes; verify-linux.sh has been hiding the difference behind a
    # fifty-pixel tolerance since it was written.
    if [ -n "$bi" ] && [ -n "$bo" ]; then
        note "sizing req=640x480 native_inner=$bi native_outer=$bo"
    fi
    if [ -n "$cp" ]; then
        note "moving req=120,90 native_frame=$cp native_raw=$cr rel=${XW_REL:-?} extents=l$FE_L,t$FE_T"
    fi

    # The positive control, and the reason the two mutations above go through the
    # API that already works. Every "the page's number is wrong" reading in this
    # file is unattributable without it: a window that never moved and an
    # instrument pointed at the wrong one produce identical readings.
    if [ -n "$ai" ] && [ -n "$bi" ] && [ "$ai" != "$bi" ]; then
        note "control resize A->B inner $ai -> $bi verdict=MOVED"
    else
        fail "control resize A->B inner $ai -> $bi; the instrument saw no size change"
    fi
    if [ -n "$bp" ] && [ -n "$cp" ] && [ "$bp" != "$cp" ]; then
        note "control move B->C pos $bp -> $cp verdict=MOVED"
    else
        fail "control move B->C pos $bp -> $cp; the instrument saw no position change"
    fi
}

analyse_doc() {
    local ctl end rb dom1 dom2 after opened
    ctl="$(field 2 '^STD-DOC-CTL')"
    end="$(field 2 '^STD-DOC-END')"
    rb="$(field 2 '^STD-DOC-RB-SELF')"
    dom1="$(field 2 '^STD-DOC-DOM1')"
    dom2="$(field 2 '^STD-DOC-DOM2')"

    note "doc sequence: $(titles)"
    [ -n "$rb" ] && note "self ${rb#STD-DOC-RB-SELF }"

    # The early shell, asked for at the app's first statement.
    #
    # An app's markup is included into the document by the assembler so that it
    # is in the first paint, and the whole point of that is an app that can read
    # it. Four lanes get that from their engine and Windows did not: its one
    # pre-navigation hook runs before the parser has produced anything, so
    # getElementById answered null on the first line and an app written the way
    # the other four allow failed silently there. It shipped in the sample app on
    # the download page, where the Close button did nothing on Windows. So this
    # is an assertion on every lane and not a note -- including the four that
    # have always kept it, because a promise only one verifier checks is a
    # promise the other lanes can lose quietly.
    local body0
    body0="$(printf '%s' "$rb" | sed -n 's/.* body0=\([^ ]*\).*/\1/p')"
    if [ "$body0" = "yes" ]; then
        note "control the early shell was on the page at the app's first statement (body0=yes)"
    else
        fail "control body0=${body0:-<absent>}; document.body was not there when the app's first statement ran, so an app cannot read its own markup on this lane"
    fi

    # The name the window came up wearing, before the app wrote anything. The
    # launcher puts the build's title into the document, so this is also the
    # first title-changed signal of the launch and it has to be a no-op. A note
    # and not an assertion: this loop starts when the window appears, and a lane
    # that is slow to hand the recorder its first read would be reporting its
    # own scheduling.
    opened="$(awk -F'\t' 'NR == 1 { print $2; exit }' "$REC")"
    note "opened native=[${opened:-<nothing recorded>}]"

    # The change this suite exists for. Both writes are plain assignments to
    # document.title and both have to reach the native window; a lane where they
    # do not is a lane whose title hook is not connected, which is the whole of
    # the finding.
    if [ -n "$dom1" ]; then note "pair dom1 native=seen"; else fail "pair dom1 native=absent; an assignment to document.title did not reach the window"; fi
    if [ -n "$dom2" ]; then note "pair dom2 native=seen"; else fail "pair dom2 native=absent; an assignment to document.title did not reach the window"; fi

    # And the two the gate refuses, asked as one question: what the window was
    # showing after them. DOM2 is the last title that may reach it, so the next
    # recorded state has to be the report at the end of the sequence. An empty
    # title reaching the window would take the app's name away; a marked one
    # reaching it would put a record in the channel every verifier here reads.
    after="$(awk -F'\t' '/STD-DOC-DOM2/ { found=1; next } found { print $2; exit }' "$REC")"
    if [ -z "$dom2" ]; then
        note "pair refused not_asked: no DOM write reached the window to hold"
    else
        case "$after" in
            "STD-DOC-RB-SELF"*)
                note "pair refused after_dom2_native=[held DOM2 through both]" ;;
            "")
                fail "pair refused after_dom2_native=[nothing recorded]; the sequence stopped at DOM2" ;;
            *)
                fail "pair refused after_dom2_native=[$after]; the window took a title the gate refuses" ;;
        esac
    fi

    # The brackets. A run where the hook did nothing and a run where no window
    # ever came up are the same empty reading without them.
    if [ -n "$ctl" ]; then note "control ctl observed=YES"; else fail "control ctl was never observed; the instrument read no window"; fi
    if [ -n "$end" ]; then note "control end observed=YES"; else fail "control end was never observed; the app did not finish its sequence"; fi
}

# The row before a named one. Every native-call verdict below is a comparison
# against the state immediately preceding it, not against the window's opening
# geometry -- four calls in a row each need their own before-picture, and the
# one the last call left is it.
prev_field() { awk -F'\t' -v n="$1" -v want="$2" '$2 ~ want { print p; exit } { p = $n }' "$REC"; }

# What one native call did, said in the two words that matter. "The call
# returned without throwing" is the page's half and is already in the title;
# this is the other one.
verdict() {
    local before="$1" after="$2"
    if [ -z "$after" ]; then echo "UNOBSERVED"
    elif [ "$before" = "$after" ]; then echo "NOOP"
    else echo "EFFECTIVE"; fi
}

analyse_win() {
    local st page inner pos pinner ppos v moved_any on ov
    note "win sequence: $(titles)"

    for st in EXIST DESC OVR OPEN APPREGION GONE; do
        page="$(field 2 "^STD-WIN-$st-SELF")"
        [ -n "$page" ] && note "self $st ${page#STD-WIN-$st-SELF }"
    done

    # window.open, and the one shape of it the page can answer for.
    #
    # What an external url does is not askable from inside the document: it
    # becomes a record, the host decides, and the desktop's URI handler acts.
    # parse.sh asserts that half against the built preload with no engine. What
    # is here is the no-argument call, which the launcher answers itself -- the
    # platform's reply is a new about:blank window and this file does nothing
    # until there is a second window to open. QtWebEngine's own `open` returns
    # an object, so on that lane this is the difference between the launcher's
    # no-op and the engine's answer.
    #
    # And every shape must leave the document where it was. No url in the phase
    # can reach a browser, so a CHANGED here is this window having been
    # navigated away by a call that was meant to open a different one.
    page="$(field 2 '^STD-WIN-OPEN-SELF')"
    if [ -z "$page" ]; then
        fail "control open: STD-WIN-OPEN-SELF was never observed"
    else
        on="$(echo "$page" | sed -n 's/.* noargs=\([^ ]*\).*/\1/p')"
        case "$on" in
            null/same) note "control open noargs=$on verdict=NOOP" ;;
            "")        fail "control open: STD-WIN-OPEN-SELF carried no noargs reading" ;;
            *)         fail "control open noargs=$on, wanted null/same; window.open() is not the launcher's on this lane" ;;
        esac
        for v in blank self; do
            ov="$(echo "$page" | sed -n "s/.* $v=\([^ ]*\).*/\1/p")"
            case "$ov" in
                */CHANGED) fail "control open $v=$ov; a call meant to open a window took this document somewhere" ;;
                "")        : ;;
                *)         note "control open $v=$ov (the engine's own, left alone)" ;;
            esac
        done
    fi

    # The four. Each prints what the page said, what the window did, and the
    # word that separates a refusal from a no-op -- which are the same reading
    # from inside the document and different ones from out here.
    #
    # Before the launcher wrote over these, all four read NOOP on all four
    # engines. They are the shipped API now, so a NOOP here is a regression and
    # the control below says so.
    moved_any=0
    for st in RT RZ MT MV; do
        page="$(field 2 "^STD-WIN-$st-PAIR")"
        if [ -z "$page" ]; then
            fail "STD-WIN-$st-PAIR was never observed"
            continue
        fi
        inner="$(field 3 "^STD-WIN-$st-PAIR")"; pos="$(field 4 "^STD-WIN-$st-PAIR")"
        pinner="$(prev_field 3 "^STD-WIN-$st-PAIR")"; ppos="$(prev_field 4 "^STD-WIN-$st-PAIR")"
        case "$st" in
            RT|RZ) v="$(verdict "$pinner" "$inner")" ;;
            *)     v="$(verdict "$ppos" "$pos")" ;;
        esac
        [ "$v" = EFFECTIVE ] && moved_any=$((moved_any + 1))
        note "pair $st page=[${page#STD-WIN-$st-PAIR }] native $pinner@$ppos -> $inner@$pos verdict=$v"
    done

    page="$(field 2 '^STD-WIN-FS1-PAIR')"
    if [ -n "$page" ]; then
        inner="$(field 3 '^STD-WIN-FS1-PAIR')"; pinner="$(prev_field 3 '^STD-WIN-FS1-PAIR')"
        note "pair FS1 page=[${page#STD-WIN-FS1-PAIR }] native $pinner -> $inner verdict=$(verdict "$pinner" "$inner")"
    else
        fail "STD-WIN-FS1-PAIR was never observed"
    fi

    # close is the one phase whose answer is an absence. The page's `closed`
    # flag is its own account and the engine may set it optimistically; what
    # says the window went is the record ending, and the two are printed side
    # by side rather than one standing in for the other.
    #
    # STILL_UP is a failure and used to be a note. The probe waits 1200 ms after
    # the call before it writes STD-WIN-END, so a title that arrives is a window
    # that was still there more than a second after being told to go -- not a
    # race, and not something a slow lane produces. It was a note while nothing
    # had ever been seen to survive the call, and what that cost is the reading
    # nobody took: close() is in the README as one of the six verbs an app drives
    # its window with, and a lane where it did nothing would have passed green.
    page="$(field 2 '^STD-WIN-END')"
    if [ -n "$(field 2 '^STD-WIN-CLOSE-PAIR')" ]; then
        if [ -n "$page" ]; then
            fail "pair CLOSE page=[${page#STD-WIN-END }] native=STILL_UP; the window was still up 1200ms after close() and reported through itself to say so"
        else
            note "pair CLOSE page=[no title after the call] native=GONE"
        fi
    else
        fail "STD-WIN-CLOSE-PAIR was never observed"
    fi

    # Control one, and it moved with the thing it is about. It used to be a
    # separate call known to work -- `neutrino.window.resize`, which no longer
    # exists -- there to tell "the engine refused" from "the window is dead".
    # Those are now one call, so the question is asked of it directly: a run in
    # which none of the four moved the window is a dead window or an override
    # that did not take, and both are regressions rather than readings.
    if [ "${moved_any:-0}" -gt 0 ]; then
        note "control the standard spellings move the window: $moved_any/4 EFFECTIVE"
    else
        fail "control none of resizeTo/resizeBy/moveTo/moveBy moved the window; either the override did not take or the window is dead, and this run measured neither"
    fi

    # Control two: the descriptors mean something. A reader that answers the
    # same for a property this file defined and for one the spec makes
    # unforgeable is a reader whose every other answer is void.
    page="$(field 2 '^STD-WIN-DESC-SELF')"
    local own forged
    own="$(printf '%s' "$page" | sed -n 's/.*CTLown=\([^ ]*\).*/\1/p')"
    forged="$(printf '%s' "$page" | sed -n 's/.*CTLforged=\([^ ]*\).*/\1/p')"
    if [ -n "$own" ] && [ -n "$forged" ] && [ "$own" != "$forged" ]; then
        note "control descriptors own=$own forged=$forged verdict=DISTINGUISHED"
    else
        fail "control descriptors own=${own:-<none>} forged=${forged:-<none>}; the reader cannot tell them apart"
    fi
}

analyse_theme() {
    local a b v pp f fbv cav mqv scv srv
    note "theme sequence: $(titles)"
    a="$(field 2 '^STD-THEME-A-SELF')"
    b="$(field 2 '^STD-THEME-B-SELF')"
    v="$(field 2 '^STD-THEME-V-SELF')"
    pp="$(field 2 '^STD-THEME-P-SELF')"
    f="$(field 2 '^STD-THEME-F-SELF')"

    [ -n "$a" ] && note "self palette ${a#STD-THEME-A-SELF }"
    [ -n "$b" ] && note "self cssnames ${b#STD-THEME-B-SELF }"
    [ -n "$v" ] && note "self delivery ${v#STD-THEME-V-SELF }"
    [ -n "$pp" ] && note "self customprops ${pp#STD-THEME-P-SELF }"
    [ -n "$f" ] && note "self fonts ${f#STD-THEME-F-SELF }"

    # Everything this probe reports is the document's own account -- there is
    # no window property that carries a computed colour, so there is no outside
    # half to pair with and none is pretended. What keeps it from being a page
    # marking its own homework is the two controls below and, in the round
    # after this, a second launch with the desktop's palette flipped: a value
    # that moves with the desktop is the desktop's, and one that does not is
    # the engine's. One launch cannot tell those apart and does not claim to.
    case "$a" in
        *nsrc=null*) fail "control palette: this lane read no toolkit, so every comparison here is void" ;;
        *nsrc=*)     note "control palette read=YES" ;;
        *)           fail "control palette: STD-THEME-A-SELF was never observed" ;;
    esac

    # The scheme, read twice on one launch: `prefers-color-scheme` is the
    # engine's answer and `neutrino.theme.scheme` is the launcher's, taken from
    # the luminance of the palette the toolkit actually handed over. An app is
    # entitled to branch on either -- 3a gave it `var(--neutrino-Canvas)` beside
    # the media query it already had -- and a desktop where the two disagree is
    # one where it gets a dark palette under a light media query.
    #
    # One launch is enough for this one, unlike every colour above it. The two
    # readings come from different places in the same instant, so a disagreement
    # is a disagreement; there is no constant here that could be agreeing by
    # accident, because neither side is a constant.
    #
    # An engine with no matchMedia, or one that matches neither, is not asked.
    # There is nothing to disagree with and nothing to force, and saying so with
    # the value in it is what keeps this from going quiet on a lane that stopped
    # answering.
    # One lane is exempt, by name, with a reason and a way out. QtWebEngine does
    # not follow the toolkit palette here: measured across the flip, Qt's
    # palette moved efefef -> 323232 with the knob read back on both halves and
    # the query stayed light. It is the same defect the GTK lanes have and there
    # is nothing to set -- `QStyleHints::colorScheme` is readable from Qt 6.5
    # and settable from 6.8, and the runner this lane exists on is 6.4.2. A knob
    # written for a version nothing here can run is a guarantee about an API and
    # not about a document, which is how the last three rounds went wrong.
    #
    # So it is a note, and the note is the record: it prints the disagreement in
    # full every run rather than going quiet, and it says what retires it. This
    # is not a widened tolerance -- the exemption is one named toolkit, the other
    # five lanes still fail, and a `qt` that starts agreeing is told to come back
    # and delete this.
    #
    # Keyed on `nsrc`, the launcher's own answer about which toolkit it read,
    # and not on the engine string: the engine is what the page can see and the
    # source is what the reading came from.
    #
    # Nothing is said on the agreeing path about the exemption, and that is a
    # correction this file needed before it shipped: a light runner agrees
    # trivially -- both readings are "light" because there is nothing to be
    # wrong about -- so a `qt` lane here would have printed "the exemption is no
    # longer needed" on every green run it ever had. Agreement is only evidence
    # where the desktop was dark, and the only place that knows a desktop went
    # dark is themediff.sh, which is where that note lives.
    mqv="$(echo "$a" | sed -n 's/.*mq=\([^ ]*\).*/\1/p')"
    scv="$(echo "$a" | sed -n 's/.*nscheme=\([^ ]*\).*/\1/p')"
    srv="$(echo "$a" | sed -n 's/.*nsrc=\([^ ]*\).*/\1/p')"
    if [ -z "$mqv" ] || [ "$scv" = null ]; then
        :
    elif [ "$mqv" = unsupported ] || [ "$mqv" = threw ] || [ "$mqv" = none ]; then
        note "control scheme not_asked mq=$mqv; this engine states no preference"
    elif [ "$mqv" = "$scv" ]; then
        note "control scheme mq=$mqv neutrino=$scv verdict=AGREED"
    elif [ "$srv" = qt ]; then
        note "control scheme KNOWN qt mq=$mqv against neutrino=$scv; QtWebEngine does not follow the toolkit palette and QStyleHints::colorScheme is Qt 6.8+, so this lane has no knob -- delete this exemption when a runner has one"
    else
        fail "control scheme mq=$mqv against neutrino=$scv; the page's media query and the palette it was handed disagree about this desktop"
    fi

    case "$b" in
        *control=UNSUP*) note "control unknown-keyword=UNSUP verdict=DISTINGUISHED" ;;
        *control=*)      fail "control unknown-keyword resolved to a colour; every UNSUP below it is the instrument, not the engine" ;;
        *)               fail "control unknown-keyword: STD-THEME-B-SELF was never observed" ;;
    esac
    # The delivery. Two page readings, and the assertion is that they agree:
    # the palette an app gets from `neutrino.theme` came through the preload,
    # and the palette it gets from `var(--neutrino-Canvas)` came through a
    # stylesheet the launcher put in the document. Different mechanisms, one
    # measurement, and an app is entitled to either.
    case "$v" in
        *" match=7/7 "*) note "control delivery match=7/7 verdict=DELIVERED" ;;
        *" pal=null "*)  note "control delivery not_asked: this lane read no toolkit" ;;
        *match=*)        fail "control delivery ${v#*match=}; the properties and neutrino.theme disagree" ;;
        *)               fail "control delivery: STD-THEME-V-SELF was never observed" ;;
    esac

    # And the reason the properties are named for the keywords. A name the
    # launcher never sets has to fall through to the engine's own system
    # colour; a keyword the engine cannot resolve would leave the declaration
    # alone instead, and the page would style itself from whatever it inherited.
    fbv="$(echo "$v" | sed -n 's/.* fallback=\([^ ]*\).*/\1/p')"
    cav="$(echo "$v" | sed -n 's/.* canvas=\([^ ]*\).*/\1/p')"
    if [ -z "$fbv" ]; then
        :
    elif [ "$fbv" = "$cav" ] && [ "$fbv" != "UNSUP" ] && [ "$fbv" != "threw" ]; then
        note "control fallback var(--neutrino-absent, Canvas)=$fbv Canvas=$cav verdict=RESOLVED"
    else
        fail "control fallback var(--neutrino-absent, Canvas)=$fbv against Canvas=$cav; an absent property does not reach the engine's own colour on this lane"
    fi

    [ -n "$(field 2 '^STD-THEME-CTL')" ] || fail "control ctl was never observed; the instrument read no window"
    [ -n "$(field 2 '^STD-THEME-END')" ] || fail "control end was never observed; the app did not finish its sequence"
}

# The engine half of the fonts delivery.
#
# Five controls, mirroring analyse_theme's six one for one: the lane read a
# toolkit, the two deliveries agree, an unset property reaches its generic, the
# launcher and the engine read the same desktop the same way, and the probe ran
# to the end.
#
# The keyword and generic readings it prints are reports and stay that way. They
# are the standing evidence for why the delivery is spelled with a separate
# `generic` field -- `system-ui` resolves on one WebKit and not the other -- and
# asserting them would fail a lane for a fact about its engine.
analyse_font() {
    local ctl kwa kwb gen unit nta ntb
    note "font sequence: $(titles)"
    ctl="$(field 2 '^STD-FONT-CTL')"
    kwa="$(field 2 '^STD-FONT-KW-A')"
    kwb="$(field 2 '^STD-FONT-KW-B')"
    gen="$(field 2 '^STD-FONT-GEN')"
    unit="$(field 2 '^STD-FONT-UNIT')"
    nta="$(field 2 '^STD-FONT-NT-A')"
    ntb="$(field 2 '^STD-FONT-NT-B')"

    [ -n "$ctl" ]  && note "self engine ${ctl#STD-FONT-CTL }"
    [ -n "$kwa" ]  && note "self keywords-a ${kwa#STD-FONT-KW-A }"
    [ -n "$kwb" ]  && note "self keywords-b ${kwb#STD-FONT-KW-B }"
    [ -n "$gen" ]  && note "self generics ${gen#STD-FONT-GEN }"
    [ -n "$unit" ] && note "self units ${unit#STD-FONT-UNIT }"
    [ -n "$nta" ]  && note "self delivered ${nta#STD-FONT-NT-A }"
    [ -n "$ntb" ]  && note "self agreement ${ntb#STD-FONT-NT-B }"

    # The apparatus control every probe here carries: a run that never got as
    # far as reporting is not a lane with no fonts, and the difference has to
    # be visible in the log rather than inferred from a line that is missing.
    case "$ctl" in
        *eng=*) note "control font: the probe ran and named its engine" ;;
        *)      fail "control font: STD-FONT-CTL was never observed, so nothing below is a reading" ;;
    esac

    # Whether the lane read a toolkit at all. Every comparison under this is
    # void on a lane that did not, so it is asked first and said out loud --
    # the same shape analyse_theme's `nsrc=null` control has.
    case "$nta" in
        *fonts=null*) fail "control fonts: this lane read no toolkit, so every comparison here is void" ;;
        *source=*)    note "control fonts read=YES" ;;
        *)            fail "control fonts: STD-FONT-NT-A was never observed" ;;
    esac

    # The delivery, both ways. `neutrino.fonts` is what the preload handed the
    # page and the custom properties are what the launcher wrote into this
    # document's stylesheet: two mechanisms, one measurement, and an app is
    # entitled to either. A lane where they disagree is a window whose two
    # accounts of one desktop differ -- which on macOS is exactly what would
    # happen if the page composed its own family lists.
    case "$ntb" in
        *fonts=null*)  note "control delivery not_asked: this lane read no fonts" ;;
        *match=15/15*) note "control delivery match=15/15 verdict=DELIVERED" ;;
        *match=*)      fail "control delivery: the custom properties and neutrino.fonts disagree -- $(printf '%s' " $ntb" | sed -n 's/.* \(match=[^ ]*\).*/\1/p') $(printf '%s' " $ntb" | sed -n 's/.* \(first=[^ ]*\).*/\1/p')" ;;
        *)             fail "control delivery: STD-FONT-NT-B was never observed" ;;
    esac

    # And the documented idiom on a lane that read nothing: a property the
    # launcher never sets must reach the generic named beside it. The twin of
    # the palette's `var(--neutrino-absent, Canvas)` control.
    local fb
    fb="$(printf '%s' " $ntb" | sed -n 's/.* fallback=\([^ ]*\).*/\1/p')"
    case "$fb" in
        monospace)      note "control fallback var(--neutrino-font-nosuchrole, monospace)=monospace verdict=RESOLVED" ;;
        notasked|"")    note "control fallback not_asked" ;;
        *)              fail "control fallback: an unset property reached '$fb' rather than the generic beside it" ;;
    esac

    # The engine's own reading of the same desktop, where it has one.
    #
    # Gated by lane and not skipped quietly, the way analyse_theme exempts `qt`
    # by name: on WebKitGTK the CSS2 `font: menu` keyword *is* the desktop's
    # font, so the engine has read independently what the launcher read and the
    # two numbers can be compared. On QtWebEngine those keywords are Chromium's
    # constants -- 16px Arial against a toolkit saying 12px -- and on WKWebView
    # they are per-role, so neither can be asked this question. A unit bug is a
    # third off; the tolerance is the pixel WebKit truncates and the launcher
    # does not.
    local agree delta src
    src="$(printf '%s' " $nta" | sed -n 's/.* source=\([^ ]*\).*/\1/p')"
    agree="$(printf '%s' " $ntb" | sed -n 's/.* agree=\([^ ]*\).*/\1/p')"
    delta="$(printf '%s' "$agree" | sed -n 's/.*delta:\([0-9.]*\).*/\1/p')"
    if [ "$src" != "gtk" ]; then
        note "control agree not_asked: this engine's system font keywords are not the desktop's"
    elif [ -z "$delta" ]; then
        fail "control agree: no reading on a lane that has one -- got '$agree'"
    elif awk -v d="$delta" 'BEGIN { exit !(d <= 1) }'; then
        note "control agree $agree verdict=AGREED"
    else
        fail "control agree: the launcher and the engine read different sizes off one desktop -- $agree"
    fi

    # Whether the six keywords are one font or six is the question that decides
    # whether CSS has any notion of a role at all, so it is lifted out of the
    # line rather than left for a reader to find inside it. Reported, never
    # asserted: it is a fact about an engine.
    case "$kwb" in
        *identical=*) note "self roles $(printf '%s' " $kwb" | sed -n 's/.* \(identical=[^ ]*\).*/\1/p')" ;;
        *)            note "self roles unread" ;;
    esac

    [ -n "$(field 2 '^STD-FONT-END')" ] ||
        fail "control font: STD-FONT-END was never observed, so the probe stopped early"
}

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
    case "$PROBE" in
        geom)  analyse_geom ;;
        doc)   analyse_doc ;;
        win)   analyse_win ;;
        theme) analyse_theme ;;
        font)  analyse_font ;;
        *)     fail "no analysis for probe '$PROBE'" ;;
    esac
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
case "$PROBE" in
    geom)  analyse_geom ;;
    doc)   analyse_doc ;;
    win)   analyse_win ;;
    theme) analyse_theme ;;
    font)  analyse_font ;;
    *)     fail "no analysis for probe '$PROBE'" ;;
esac

# After the loop, never inside it -- a full-screen PNG encode is exactly the
# slow thing this file's header forbids in the sampling loop. The full record
# goes to the log and the artifact; the digest above is what carries the
# `report:` prefix a reader scans for.
[ "$PROBE" = win ] || shoot
echo "--- recorded transitions (ms / title / inner / pos / outer / tick / raw) ---"
cat "$REC"

note "totals probe=$PROBE failures=$FAILURES"
exit "$FAILURES"
