# walk.sh - the launcher's walk, judged in one place for every lane.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Two ways in, the same two test/lib/analyse.sh has:
#
#   . test/lib/walk.sh            the comparators, for a verifier that is
#                                 watching a live window and has the numbers
#   bash test/lib/walk.sh REC     replay a recorded walk and judge the whole of
#                                 it, which is the Windows path
#
# The walk is neutrinotest.js driving a window through eight states and naming
# each one in its title: neutrino, STEP0, STEP1-Test Title, STEP2, STEP3,
# THEMEOK, FONTOK, TESTS DONE. Three verifiers watch it -- verify-linux.sh on
# X11, verify-macos.sh through a status file, verify-windows.ps1 through
# GetWindowRect -- and cases.tsv has said since it was written that the third
# "asserts the same facts and has not been brought onto these ids yet".
#
# ---------------------------------------------------- what belongs in here
#
# The instrument is per-platform and the judgement is not. That is the same
# split analyse.sh made for the standards probes, and the same argument: two
# copies of a *measurement* can only disagree about a machine, but two copies of
# a *verdict* disagree about meaning, silently, and no mechanical check can tell
# you which one is right.
#
# It was already costing something. verify-linux.sh and verify-macos.sh print
# byte-identical sentences for the title and the geometry -- `title = '%s'`,
# `content = %sx%s (asked ...)` -- because one was copied from the other, and
# the only thing keeping them in step was that nobody had edited one of them.
#
# --------------------------------------------------- what does not belong
#
# The position, on the two unix lanes. It is the one assertion where the
# platforms genuinely disagree about the quantity rather than about how to
# phrase it: X11 derives the frame's corner from xwininfo minus
# _NET_FRAME_EXTENTS and names the window manager it did that under, and macOS
# clamps the expectation into the work area because that is what a move means
# there. Windows needs neither -- GetWindowRect's Left/Top is already the
# frame's outside corner and `move` sets the same corner -- so the exact
# comparison below is the Windows one, and the other two keep their own until
# they can be recorded the same way.
#
# ------------------------------------------------------------- the record
#
# Six columns, and deliberately the ones analyse.sh already reads rather than a
# second format invented for this:
#
#   ms <TAB> title <TAB> inner <TAB> pos <TAB> outer <TAB> tick
#
# `pos` is the frame's outside corner, normalised by whatever wrote the record.
# That is the whole reason the position rule here can be a rule and not a table:
# the platform knowledge is spent on the instrument side, where it lives.

# Sourced by a file that already has the harness, or run on its own and needing
# it. The guard is analyse.sh's, for the same reason: sourcing harness.sh twice
# would reset the counters a live verifier is part-way through filling.
if ! command -v nt_pass >/dev/null 2>&1; then
    NT_WALK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/harness.sh"
    # shellcheck source=/dev/null
    . "$NT_WALK_LIB"
fi

# --------------------------------------------------------------- comparators

# The title, exactly. The spelling is verify-linux.sh's and verify-macos.sh's,
# which were already the same spelling.
nt_walk_title() {
    if [ "$2" = "$3" ]; then
        nt_pass "$1" "title = '$3'"
    else
        nt_fail "$1" "title expected='$3' actual='$2'"
    fi
}

# The content size, within a tolerance the caller names.
#
# Zero everywhere today, and the long comment on verify-linux.sh's caller says
# why: the fifty pixels this used to allow were not covering a difference
# between toolkits, they were covering the fact that nothing had measured either
# side -- and fifty admits a whole title bar, which is exactly the difference
# macOS carried unnoticed while its driver sized the frame.
nt_walk_geometry() {
    local case="$1" aw="$2" ah="$3" ew="$4" eh="$5" tol="${6:-0}" dw dh
    dw=$((aw - ew)); dw=${dw#-}
    dh=$((ah - eh)); dh=${dh#-}
    if [ "$dw" -le "$tol" ] && [ "$dh" -le "$tol" ]; then
        nt_pass "$case" "content = ${aw}x${ah} (asked ${ew}x${eh}, tolerance ${tol})"
    else
        nt_fail "$case" "content expected ${ew}x${eh} actual=${aw}x${ah}, off by ${dw}x${dh} (tolerance ${tol})"
    fi
}

# The frame's corner, exactly, for a platform that honours the request.
#
# Measured across three runs of the Windows suite in one job -- the core launch
# and both load replicas -- moveTo(0,0) put the frame at 0,0 every time.
nt_walk_position_exact() {
    local case="$1" ax="$2" ay="$3" ex="$4" ey="$5"
    if [ "$ax" = "$ex" ] && [ "$ay" = "$ey" ]; then
        nt_pass "$case" "frame origin = ${ax},${ay} (asked ${ex},${ey})"
    else
        nt_fail "$case" "frame origin expected ${ex},${ey} actual=${ax},${ay}"
    fi
}

# A state the app said it reached. THEMEOK and FONTOK are verdicts the app
# reports about itself, because it is the only side that can see a palette or a
# font list: a lane that reached no toolkit reports null and titles itself
# THEMEBAD, which is not this title and so is not found.
nt_walk_reached() {
    if [ -n "$2" ]; then
        nt_pass "$1" "$3"
    else
        nt_fail "$1" "$4"
    fi
}

# ------------------------------------------------------------------- replay

# One field of the first row whose title matches, or empty.
nt_walk_field() {
    awk -F'\t' -v n="$1" -v want="$2" '$2 == want { print $n; exit }' "$NT_WALK_REC"
}

nt_walk_replay() {
    local first step0 step1 step2 step3 theme fonts done_ inner pos aw ah ax ay

    first="$(awk -F'\t' 'NR == 1 { print $2; exit }' "$NT_WALK_REC")"
    nt_walk_reached walk.window.appeared "$first" \
        "the app opened a window" "window never appeared"
    [ -n "$first" ] || return 0

    step0="$(nt_walk_field 2 STEP0)"
    nt_walk_reached walk.step0.reached "$step0" \
        "the app started and reported in" "STEP0 never reached"

    # The title case asserts the title rather than only its arrival: this is the
    # state where document.title is supposed to have reached the native window.
    step1="$(nt_walk_field 2 "STEP1-Test Title")"
    if [ -n "$step1" ]; then
        nt_walk_title walk.title "$step1" "STEP1-Test Title"
    else
        nt_fail walk.title "STEP1 never reached"
    fi

    step2="$(nt_walk_field 2 STEP2)"
    if [ -n "$step2" ]; then
        inner="$(nt_walk_field 3 STEP2)"
        aw="${inner%x*}"; ah="${inner#*x}"
        nt_walk_geometry walk.resize "$aw" "$ah" 500 400 0
    else
        nt_fail walk.resize "STEP2 never reached"
    fi

    step3="$(nt_walk_field 2 STEP3)"
    if [ -n "$step3" ]; then
        pos="$(nt_walk_field 4 STEP3)"
        ax="${pos%,*}"; ay="${pos#*,}"
        nt_walk_position_exact walk.move "$ax" "$ay" 0 0
    else
        nt_fail walk.move "STEP3 never reached"
    fi

    theme="$(nt_walk_field 2 THEMEOK)"
    nt_walk_reached walk.theme.readable "$theme" \
        "the lane read the desktop palette" \
        "the palette was not readable on this lane (see 05-theme.png)"

    fonts="$(nt_walk_field 2 FONTOK)"
    nt_walk_reached walk.fonts.readable "$fonts" \
        "the lane read the desktop fonts" \
        "the fonts were not readable on this lane"

    done_="$(nt_walk_field 2 "TESTS DONE")"
    nt_walk_reached walk.done "$done_" \
        "the walk ran to the end" "tests never completed"
}

# Run, not sourced.
#
# Told apart by BASH_SOURCE rather than by whether an argument arrived, which is
# what this tried first and is wrong in the one way that matters: a sourced file
# sees the *caller's* positional parameters, and verify-linux.sh is called with a
# screenshots directory. So `$1` was set, the replay ran against a directory, and
# every walk case on that lane failed with "no record at .../shots". The offline
# stub-instrument run caught it on the first try.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    NT_WALK_REC="${1:-}"
    if [ -z "$NT_WALK_REC" ]; then
        echo "usage: walk.sh <record.tsv>" >&2
        exit 2
    fi
    if [ ! -f "$NT_WALK_REC" ]; then
        nt_fail walk.window.appeared "no record at '$NT_WALK_REC'"
        exit 1
    fi
    nt_walk_replay
    exit "$NT_FAILURES"
fi
