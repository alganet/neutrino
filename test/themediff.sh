#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# themediff.sh - the differential that says where a colour came from.
#
# Usage: themediff.sh <log-from-run-A> <log-from-run-B>
#
# One launch of the theme probe cannot tell a hardcoded value from a desktop
# value that happens to look like one, and this is not hypothetical: WebKit's
# hardcoded `Highlight` is within one unit of Adwaita's accent, so on a default
# GNOME desktop it reads exactly like an engine following the palette. It is
# not. Flipping the desktop between two launches is what separates them, and
# nothing cheaper does.
#
# So this takes the two logs verify-std.sh wrote either side of a flip and asks
# one question of each value: did it move. What moved with the desktop is the
# desktop's; what did not is the engine's own constant, whatever it resembles.
#
# Four controls, and none of them is optional. Both runs must have read a
# toolkit, or there is nothing to compare against. The two palettes must
# differ, or the flip did not take and every "did not move" below is the
# apparatus rather than the engine -- this is the one that fails a lane where
# the knob is wrong, which is the correct outcome and why the step is last and
# gated. The unknown-keyword control must have refused in both, or an "UNSUP"
# is the instrument talking. And each half's `prefers-color-scheme` must agree
# with the scheme the launcher derived from the palette that half was handed:
# the two are read from different places in one instant, so a disagreement is
# never a coincidence the way a colour can be -- `qt` excepted by name, for the
# reason recorded where that assertion's twin lives.

set -uo pipefail

A="${1:-}"
B="${2:-}"
FAILURES=0

fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
note() { echo "report: $*"; }

for f in "$A" "$B"; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        fail "no log at '${f:-<none>}'; the differential has one side"
        note "totals themediff failures=$FAILURES"
        exit "$FAILURES"
    fi
done

# The two lines each run contributes. Taken by their report: prefix rather than
# by position: a run that failed a control of its own still wrote them, and a
# run that never came up wrote neither, which is a different reading.
line() { sed -n "s/^report: self $2 //p" "$1" | head -1; }

# One `key=value` out of a line, by name. Anchored on the space before it so
# `AccentColor` cannot be matched inside `AccentColorText`.
val() { printf '%s' " $1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }

PA="$(line "$A" palette)"; PB="$(line "$B" palette)"
CA="$(line "$A" cssnames)"; CB="$(line "$B" cssnames)"

if [ -z "$PA" ] || [ -z "$PB" ]; then
    fail "one run reported no palette line at all; that run never got as far as reading one"
    note "totals themediff failures=$FAILURES"
    exit "$FAILURES"
fi

NT_KEYS="background foreground base text accent accentText border"
CSS_KEYS="Canvas CanvasText ButtonFace ButtonText ButtonBorder AccentColor AccentColorText Highlight HighlightText SelectedItem SelectedItemText Field FieldText GrayText LinkText"

# --- controls ---------------------------------------------------------------

for pair in "A:$PA" "B:$PB"; do
    tag="${pair%%:*}"; body="${pair#*:}"
    case "$body" in
        *nsrc=null*) fail "control run $tag read no toolkit; nothing here can be compared" ;;
        *nsrc=*)     : ;;
        *)           fail "control run $tag reported no source" ;;
    esac
done

for pair in "A:$CA" "B:$CB"; do
    tag="${pair%%:*}"; body="${pair#*:}"
    case "$body" in
        *control=UNSUP*) : ;;
        *)               fail "control run $tag: the unknown keyword resolved; every UNSUP in that run is the instrument" ;;
    esac
done

# --- the flip itself --------------------------------------------------------

moved_nt=0; moved_nt_names=""
for k in $NT_KEYS; do
    va="$(val "$PA" "n:$k")"; vb="$(val "$PB" "n:$k")"
    if [ -n "$va" ] && [ "$va" != "$vb" ]; then
        moved_nt=$((moved_nt + 1)); moved_nt_names="$moved_nt_names $k"
    fi
done

if [ "$moved_nt" -eq 0 ]; then
    # The `report: knob` lines the flip wrote are what tells the two apart:
    # a readback that shows the state it asked for makes this the engine's
    # read, and one that does not makes it the knob's. Named here because the
    # verdict and its cause are annotated separately and the reader has to be
    # sent from one to the other.
    fail "control the flip did not take: the toolkit palette is identical either side of it, so nothing below distinguishes an engine constant from a desktop value -- compare the 'report: knob' readbacks: if they moved, the engine did not read the desktop; if they did not, the knob is what failed"
else
    note "control the flip took: $moved_nt/7 toolkit colours moved"
fi

# --- the reading ------------------------------------------------------------

moved_css=0; moved_css_names=""; unsup=0
for k in $CSS_KEYS; do
    va="$(val "$CA" "$k")"; vb="$(val "$CB" "$k")"
    if [ "$va" = "UNSUP" ] && [ "$vb" = "UNSUP" ]; then
        unsup=$((unsup + 1))
    elif [ -n "$va" ] && [ "$va" != "$vb" ]; then
        moved_css=$((moved_css + 1)); moved_css_names="$moved_css_names $k=$va->$vb"
    fi
done

MQA="$(val "$PA" mq)"; MQB="$(val "$PB" mq)"
SCA="$(val "$PA" nscheme)"; SCB="$(val "$PB" nscheme)"
SRC="$(val "$PA" nsrc)"

note "themediff source=$SRC toolkit_moved=$moved_nt/7 css_moved=$moved_css/15 css_unsupported=$unsup"
note "themediff toolkit moved:$moved_nt_names"
note "themediff css moved:${moved_css_names:- none}"
note "themediff scheme mq=$MQA->$MQB neutrino=$SCA->$SCB"

# And that is an assertion here, not the note it was until the round that
# forced the scheme.
#
# verify-std.sh already asks each half whether its media query and its palette
# agree, so what this adds is the pair across a desktop that moved. A lane whose
# engine answers a constant -- always light, whatever the toolkit did -- passes
# the single-launch check on whichever half happens to be light and fails here,
# because the two halves cannot both be right about a desktop that changed.
#
# Both halves are named in the failure. Which one moved wrongly is the whole
# diagnosis, and a verdict that says only "they disagree" sends the reader back
# to the log to work out which.
#
# One lane is exempt by name, and verify-std.sh's analyse_theme carries the
# reason: QtWebEngine does not follow the toolkit palette and has no knob before
# Qt 6.8. This is where that was measured -- the readings under `themediff B`
# below are the ones the exemption is written from -- so the note here prints
# the disagreement rather than swallowing it.
SRA="$(val "$PA" nsrc)"; SRB="$(val "$PB" nsrc)"
for half in "A:$MQA:$SCA:$SRA" "B:$MQB:$SCB:$SRB"; do
    tag="${half%%:*}"; rest="${half#*:}"
    mq="${rest%%:*}"; rest="${rest#*:}"
    sc="${rest%%:*}"; sr="${rest#*:}"
    if [ -z "$mq" ] || [ "$sc" = null ] || [ -z "$sc" ]; then
        continue
    fi
    case "$mq" in
        unsupported|threw|none)
            note "control scheme half $tag not_asked mq=$mq; this engine states no preference" ;;
        "$sc")
            # Only where the desktop was dark. A light half agrees because
            # neither reading has anything to be wrong about, and saying "the
            # exemption can go" on that would be a standing instruction printed
            # on every green run.
            if [ "$sr" = qt ] && [ "$sc" = dark ]; then
                note "control scheme half $tag: qt agreed on a dark desktop; the exemption named in verify-std.sh can go"
            fi ;;
        *)
            if [ "$sr" = qt ]; then
                note "control scheme half $tag KNOWN qt: mq=$mq against neutrino=$sc -- QtWebEngine does not follow the toolkit palette and QStyleHints::colorScheme is Qt 6.8+, so this lane has no knob"
            else
                fail "control scheme half $tag: mq=$mq against neutrino=$sc -- on this half of the flip the engine's media query and the palette the toolkit handed over disagree about the desktop"
            fi ;;
    esac
done

# Said as a sentence, because the number alone has been misread once already:
# a keyword sitting one unit from the desktop's value is not following it.
if [ "$moved_css" -eq 0 ]; then
    note "themediff verdict: no CSS system colour followed the desktop; every value this engine reports is its own constant"
else
    note "themediff verdict: $moved_css CSS system colour(s) followed the desktop and the rest are constants"
fi

note "themediff A: $PA"
note "themediff B: $PB"
note "totals themediff failures=$FAILURES"
exit "$FAILURES"
