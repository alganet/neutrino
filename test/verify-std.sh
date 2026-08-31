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
# Round zero. An instrument added in a hurry is code, and it gets run before it
# is pushed -- a one-line annotate call with an unterminated quote once cost a
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

# Read once, before the loop. Frame extents are a property of the frame the
# window manager put around this window and do not change while it is up, so
# reading them per turn would put an xprop in the hot path for a constant.
x11_frame_extents() {
    local line
    line="$(xprop -id "$X11_WID" _NET_FRAME_EXTENTS 2>/dev/null)"
    case "$line" in
        *=*)
            line="${line#*= }"
            FE_L="$(echo "$line" | cut -d, -f1 | tr -d ' ')"
            FE_R="$(echo "$line" | cut -d, -f2 | tr -d ' ')"
            FE_T="$(echo "$line" | cut -d, -f3 | tr -d ' ')"
            FE_B="$(echo "$line" | cut -d, -f4 | tr -d ' ')"
            ;;
    esac
    case "$FE_L$FE_R$FE_T$FE_B" in
        *[!0-9]*|"") FE_L=0; FE_R=0; FE_T=0; FE_B=0; note "no _NET_FRAME_EXTENTS; outer is reported as inner" ;;
    esac
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
# The offset actually used to derive a frame origin, and the evidence for it.
#
# Measured, on a real window manager: `_NET_FRAME_EXTENTS` came back
# `0, 0, 28, 0` while xwininfo's relative upper-left was `10, 36`. They are not
# the same quantity and only one of them is the reparenting offset -- the hint
# describes the decoration's thickness, and the offset is where the client
# actually sits inside its frame. Round 1 derived positions from the extents and
# disagreed with every engine by a constant; the sizes derived from the same
# extents were right, which is the tell, because a size wants the thickness and
# an origin wants the offset.
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
    case "${rx:-x}${ry:-x}" in
        *[!0-9-]*|"") ;;
        *) REL_X="$rx"; REL_Y="$ry"; REL_SRC="xwininfo" ;;
    esac
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
            pos="$((${X:-0} - REL_X)),$((${Y:-0} - REL_Y))"
            outer="$(( ${WIDTH:-0} + FE_L + FE_R ))x$(( ${HEIGHT:-0} + FE_T + FE_B ))"
            # What X actually said, beside what this script made of it. Round 1
            # validated the size arithmetic -- computed outer matched
            # QtWebEngine's own outerWidth to the pixel on that lane -- and did
            # not validate the position arithmetic: the page and this script
            # disagreed by a constant that the frame extents do not explain, on
            # two of three x11 lanes. A derived number and the number it was
            # derived from are two different readings, and only one of them can
            # be wrong; carrying both is how the next round says which.
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
        fi
        case "$t" in *-END) break ;; esac
        sleep "$POLL"
    done
    TURNS="$turns"
    ELAPSED_MS="$ms"
}

# Every distinct title the loop saw, in order, with what was measured beside it.
field() { awk -F'\t' -v n="$1" -v want="$2" '$2 ~ want { print $n; exit }' "$REC"; }
# State names only. The full titles are in the record dumped at the end; a
# sequence line that repeats a whole -SELF payload spends annotation budget
# saying twice what the self line beside it already said once.
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

# ------------------------------------------------------------------ assertions

check_apparatus() {
    local rows gap
    rows="$(wc -l < "$REC" | tr -d ' ')"
    gap="$MAX_TURN_GAP"
    note "sampler platform=$PLATFORM turns=${TURNS:-0} transitions=$rows dwell_ms=$DWELL max_turn_gap_ms=$gap"
    if [ "$PLATFORM" = x11 ]; then
        note "sampler frame_extents l=$FE_L r=$FE_R t=$FE_T b=$FE_B wid=$X11_WID via=$X11_SRC"
        # Printed beside them so the two formulas can be compared rather than
        # one trusted. rel and (l,t) agreeing is what says the derived frame
        # origin below is the conventional one.
        local derived=""
        case "$XD_ABS" in
            *[0-9]*,*[0-9]*) derived="$(( ${XD_ABS%%,*} - REL_X )),$(( ${XD_ABS##*,} - REL_Y ))" ;;
        esac
        note "sampler origin rel=${XW_REL:-?} src=$REL_SRC xwininfo_abs=${XW_ABS:-?} xdotool_abs=${XD_ABS:-?} derived=${derived:-?}"
        if [ -n "$XW_ABS" ] && [ -n "$derived" ] && [ "$XW_ABS" != "$derived" ]; then
            fail "the frame origin differs by route (xwininfo says $XW_ABS, xdotool minus rel says $derived); every position below is the second route"
        fi
        if [ "$REL_SRC" = none ]; then
            note "sampler no reparent offset available; positions are raw and underived"
        fi
    fi
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
    page="$(field 2 '^STD-WIN-END')"
    if [ -n "$(field 2 '^STD-WIN-CLOSE-PAIR')" ]; then
        if [ -n "$page" ]; then
            note "pair CLOSE page=[${page#STD-WIN-END }] native=STILL_UP (a title arrived after the call)"
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

# ----------------------------------------------------------------------- main

echo "verify-std.sh: probe=$PROBE platform=$PLATFORM dwell=${DWELL}ms"

if [ -n "$REPLAY" ]; then
    [ -f "$REPLAY" ] || { echo "FAIL: no record at '$REPLAY'"; exit 1; }
    cp "$REPLAY" "$REC"
    TURNS="$(wc -l < "$REC" | tr -d ' ')"
    echo "verify-std.sh: replaying $REPLAY -- apparatus checks are not a measurement here"
    check_apparatus
    case "$PROBE" in
        geom)  analyse_geom ;;
        doc)   analyse_doc ;;
        win)   analyse_win ;;
        theme) analyse_theme ;;
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

: > "$REC"
record

check_apparatus
case "$PROBE" in
    geom)  analyse_geom ;;
    doc)   analyse_doc ;;
    win)   analyse_win ;;
    theme) analyse_theme ;;
    *)     fail "no analysis for probe '$PROBE'" ;;
esac

# After the loop, never inside it. The full record goes to the log and the
# artifact; only the digest above carries the report: prefix annotate.sh reads.
if [ "$PLATFORM" = x11 ]; then
    import -window root "$SHOT_DIR/std-$PROBE.png" 2>/dev/null || true
else
    screencapture -x "$SHOT_DIR/std-$PROBE.png" 2>/dev/null || true
fi
echo "--- recorded transitions (ms / title / inner / pos / outer / tick / raw) ---"
cat "$REC"

note "totals probe=$PROBE failures=$FAILURES"
exit "$FAILURES"
