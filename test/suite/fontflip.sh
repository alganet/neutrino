#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# fontflip.sh - the desktop's font moved underneath a running toolkit probe.
#
# Usage: fontflip.sh <gtk|macos|windows> [watch-seconds] [live-artifact]
#
# PROBE. The live half of the round the fontprobe-* files open, and it exists
# for the same reason themeflip.sh does: one reading cannot tell a value that
# followed the desktop from a value that merely looks like it would have. The
# palette round learned that the expensive way -- WebKit's hardcoded `Highlight`
# is within one unit of Adwaita's accent, so on a default desktop an engine
# following nothing reads exactly like an engine following everything.
#
# Two questions, and they are separate:
#
#   - does the *toolkit* emit anything. That is what the fontprobe-* watch
#     argument counts, and it decides whether a `neutrino.fonts` can be live at
#     all on a lane, or whether that lane is launch-only the way Qt's palette is
#     under QGtk3Theme.
#   - does the *engine* re-evaluate. Measured on this desk before the round and
#     the answer on WebKitGTK is no, twice over: a font change moved neither the
#     loaded document's `font: menu` nor a reloaded one's. That half is
#     neutrinostdfont.js's, run either side of a flip.
#
# The desktop is put back where it was found, not set to a default. themeflip.sh
# carries the same rule and the same reason: this is the kind of file a person
# runs on their own machine, and a probe that leaves someone's font at
# `DejaVu Serif Bold 17` has broken their desktop to measure it.

set -uo pipefail

# The window title, by whichever reader this machine has -- the fifth copy of
# that cascade lived here. See lib/title.sh.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/title.sh"
# And the shape this file's live half shares with themeflip.sh's three: launch,
# first reading, settle. The verdicts stay here -- two flips, two findings, and
# a second one whose passing reading is a font name and not `moved=yes`.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/live.sh"

MODE="${1:-gtk}"
WATCH="${2:-8}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

note() { nt_report "$*"; }

# The eight cases this file holds, and the two lists a gate reaches for.
#
# Every gate below says "nothing under here is a reading", and each has to say
# which questions it could not reach -- an unreported case is a hole, and a hole
# is indistinguishable from a suite that never ran.
#
# The two halves are two lists because two manifest rows run them: `fontflip`
# asks what the toolkit emits and `fontlive` whether a running page is told, and
# neither row reaches the other's questions. See NT_FONTFLIP_HALF at the bottom.
skip_probe() {
    nt_skip fontflip.probe.baseline "$1"
    nt_skip fontflip.probe.watched "$1"
    nt_skip fontflip.probe.restored "$1"
}

skip_live() {
    nt_skip fontflip.live.reported "$1"
    nt_skip fontflip.live.ui-knob "$1"
    nt_skip fontflip.live.ui "$1"
    nt_skip fontflip.live.mono "$1"
}

# One probe run, with its output shown whichever way it goes.
#
# The obvious spelling is `timeout N runtime probe 2>&1 | grep '^FONTPROBE'`,
# and it cost this round the whole macOS reading: fontprobe-macos.js raised on
# its first line, the exception did not begin with FONTPROBE, and the grep sent
# it to the same place it sends a launcher's ordinary noise. The step went
# green, the log said `--- macos baseline` and then nothing, and an empty
# reading is indistinguishable from a lane with no fonts.
#
# So the readings are lifted, and if there were none the raw output is printed
# instead. A probe that dies now says how.
# The wall-clock bound is applied here rather than written at each call site,
# and it is guarded, because macOS ships no timeout(1) -- `run_probe timeout 60
# osascript ...` came back exit 127 `timeout: command not found` and took the
# whole macOS reading with it. netinstall/test/lib.sh's nt_timeout already
# carries this rule and its reason: a bound that silently is not there is worse
# than no bound, because the log reads as though every probe were capped.
run_probe() {
    local secs="$1"; shift
    local out rc
    out="$(mktemp)"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@" > "$out" 2>&1
    else
        note "no timeout(1) on this platform; running unbounded: $1"
        "$@" > "$out" 2>&1
    fi
    rc=$?
    # Matched anywhere on the line and then trimmed to it, rather than
    # anchored at column one. Qt's console.warn arrives through the
    # categorised logger as `qml: FONTPROBE ...`, so an anchored match found
    # nothing in either Qt run of the round that added this -- on the Ubuntu
    # lane and on real Plasma both -- and the whole reading came out through
    # the branch below. That branch is why the round was not lost, and this is
    # the fix it pointed at.
    if grep -q 'FONTPROBE' "$out"; then
        sed -n 's/^.*\(FONTPROBE\)/\1/p' "$out"
        rm -f "$out"
        return 0
    fi
    note "the probe printed no FONTPROBE line (exit $rc); its whole output follows"
    sed 's/^/  probe: /' "$out"
    rm -f "$out"
    return 1
}

# The font the flip moves to, chosen so that every field a probe reports moves
# with it: a different family, a different size, and a weight that is not 400.
# A flip that only changed the size would leave a probe reporting the family
# correctly by accident.
FLIP_TO="DejaVu Serif Bold 17"
# And the family the second flip moves the monospace role to. A different
# name and a different size, so a reading that moved cannot have moved by
# half -- and one that is certainly not the ui font, so the two roles
# cannot be confused for each other in a title.
MONO_FLIP_TO="Liberation Mono 14"

# ---------------------------------------------------------------- the gtk knob
#
# gsettings and not the environment. `GTK_THEME` has an equivalent here only for
# themes; there is no environment variable a running GTK re-reads its font from,
# so the desktop's own key is the only knob that moves a live process -- which
# is the thing being measured, so a knob that did not would make the whole run
# meaningless.
#
# Every schema this desktop carries is written, not the first one found. A
# Cinnamon box carries the GNOME schemas as well and GTK follows exactly one of
# them; themeflip.sh recorded the same disagreement for gtk-theme, where the
# two schemas held different values and only one moved the toolkit. Writing
# both means the flip cannot fail on the guess.
GTK_SCHEMAS="org.gnome.desktop.interface org.cinnamon.desktop.interface org.mate.interface"

gtk_saved=""
gtk_save() {
    gtk_saved=""
    for s in $GTK_SCHEMAS; do
        gsettings writable "$s" font-name >/dev/null 2>&1 || continue
        v="$(gsettings get "$s" font-name 2>/dev/null)" || continue
        [ -n "$v" ] || continue
        gtk_saved="$gtk_saved$s=$v"$'\n'
    done
    [ -n "$gtk_saved" ]
}

gtk_restore() {
    [ -n "$gtk_saved" ] || return 0
    printf '%s' "$gtk_saved" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        s="${line%%=*}"; v="${line#*=}"
        gsettings set "$s" font-name "$v" >/dev/null 2>&1 || true
    done
    note "gtk knob restored: $(gsettings get org.gnome.desktop.interface font-name 2>/dev/null)"
}

gtk_set() {
    for s in $GTK_SCHEMAS; do
        gsettings writable "$s" font-name >/dev/null 2>&1 || continue
        gsettings set "$s" font-name "$1" >/dev/null 2>&1 || true
    done
}

# -------------------------------------------------------------- the macos knob
#
# There isn't one, and saying so is the measurement rather than a gap in this
# file. macOS has no user setting for the UI font at all -- the nearest thing is
# the accessibility text size, which is per-app and has no scripting interface
# a runner can reach. So the macOS half takes a baseline and reports that it
# could not flip, which is what the round needs to hear before anyone designs a
# watcher for that lane.

# ------------------------------------------------------------ the windows knob
#
# HKCU\Software\Microsoft\Accessibility TextScaleFactor, which is what the
# Windows text size slider writes. Driven from the probe's own side rather than
# here, because this file is bash and that lane's harness is not.

# Every schema gtk_save recorded, read back after gtk_restore ran.
#
# The header's promise is that a desktop this file moved is a desktop it put
# back, and until now nothing checked it: gtk_restore wrote the values and
# reported the first schema's, which is the value it had just written. A person
# who runs this on their own machine is owed better than a report of the write.
#
# Read with a here-document and not `printf | while`, because the loop's
# findings have to survive it: a `while` on the right of a pipe is a subshell,
# which is why gtk_restore itself can only ever call gsettings from in there.
gtk_restored() {
    local line s v now
    NT_RESTORE_BAD=""
    [ -n "$gtk_saved" ] || return 2
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        s="${line%%=*}"; v="${line#*=}"
        now="$(gsettings get "$s" font-name 2>/dev/null)"
        [ "$now" = "$v" ] || NT_RESTORE_BAD="$NT_RESTORE_BAD $s=$now(wanted $v)"
    done <<EOF
$gtk_saved
EOF
    [ -z "$NT_RESTORE_BAD" ]
}

run_gtk() {
    command -v gsettings >/dev/null 2>&1 || {
        note "no gsettings here; nothing to flip"
        skip_probe "no gsettings here, so there is no knob to move and nothing to read"
        return 0
    }
    local runtime=""
    for c in gjs cjs; do command -v "$c" >/dev/null 2>&1 && { runtime="$c"; break; }; done
    [ -n "$runtime" ] || {
        note "no gjs or cjs here; the gtk probe cannot run"
        skip_probe "neither gjs nor cjs is here, so the probe that takes these readings cannot run"
        return 0
    }
    note "gtk runtime=$runtime"

    gtk_save || { note "no writable font-name key in any schema; nothing to flip"; }
    trap gtk_restore EXIT
    note "gtk knob saved: $(printf '%s' "$gtk_saved" | tr '\n' ' ')"

    # Baseline first, with no watch, so the reading of what the desktop *is*
    # cannot be confused with the reading of what it became.
    note "--- gtk baseline"
    if run_probe 30 "$runtime" "$ROOT/test/probe/fontprobe-gtk.js"; then
        nt_pass fontflip.probe.baseline "the probe read the desktop's fonts before anything moved"
    else
        nt_fail fontflip.probe.baseline "the probe printed no reading at all; a lane with no fonts and a probe that died look identical from here"
    fi

    # Its output and its status go to files, and both are read after the wait.
    #
    # This probe is backgrounded so the flip can happen underneath it, and until
    # now that put its verdict in a subshell: run_probe counted its own failure
    # into a $FAILURES the parent never saw, so a probe that died during the
    # watch was a step that passed. A row filed from in there would have been
    # worse -- red in the grid and zero in the exit code.
    note "--- gtk live (${WATCH}s, flipped at 2s)"
    local watchlog watchrc
    watchlog="$(mktemp)"; watchrc="$(mktemp)"
    ( run_probe $((WATCH + 20)) "$runtime" "$ROOT/test/probe/fontprobe-gtk.js" "$WATCH" \
        > "$watchlog" 2>&1; echo $? > "$watchrc" ) &
    local probe=$!
    sleep 2
    gtk_set "$FLIP_TO"
    note "flipped to '$FLIP_TO'"
    wait "$probe" 2>/dev/null || true
    cat "$watchlog"
    if [ "$(cat "$watchrc" 2>/dev/null)" = 0 ]; then
        nt_pass fontflip.probe.watched "the probe read the desktop's fonts while they moved under it"
    else
        nt_fail fontflip.probe.watched "the probe printed no reading while the font moved under it; whether this toolkit emits anything is what this lane runs to find out, and a dead probe cannot say"
    fi
    rm -f "$watchlog" "$watchrc"

    gtk_restore
    trap - EXIT
    local restored=0
    gtk_restored || restored=$?
    if [ "$restored" = 0 ]; then
        nt_pass fontflip.probe.restored "every font-name key this run moved is back where it was found"
    elif [ "$restored" = 2 ]; then
        nt_skip fontflip.probe.restored "no writable font-name key was saved, so nothing here was moved and nothing had to be put back"
    else
        nt_fail fontflip.probe.restored "the desktop was left flipped:$NT_RESTORE_BAD -- this file is one a person runs on their own machine"
    fi

    note "--- gtk after restore"
    timeout 30 "$runtime" "$ROOT/test/probe/fontprobe-gtk.js" 2>&1 |
        grep '^FONTPROBE gtksettings gtk-font-name' || true
}

# There is no run_qt any more, and its absence is a reading.
#
# It drove fontprobe.qml, which asked whether Qt could be told about a font
# change. It cannot: `Qt.application.font` carries no NOTIFY that QML can reach,
# and the value held still through a `kwriteconfig6 --notify` write on real
# Plasma 6 with KDEPlasmaPlatformTheme6 loaded. The lane is launch-only for
# fonts, window.qml says so where someone would go to add a watcher, and there
# is nothing left here for a flip to measure.
run_macos() {
    command -v osascript >/dev/null 2>&1 || {
        note "no osascript here"
        skip_probe "no osascript here, so the probe that takes these readings cannot run"
        return 0
    }
    note "--- macos baseline"
    if run_probe 60 osascript -l JavaScript "$ROOT/test/probe/fontprobe-macos.js"; then
        nt_pass fontflip.probe.baseline "the probe read the desktop's fonts before anything moved"
    else
        nt_fail fontflip.probe.baseline "the probe printed no reading at all; a lane with no fonts and a probe that died look identical from here"
    fi
    # Skipped and not passed, and the difference is the header's whole argument:
    # macOS has no user setting for the UI font, so there is no knob to move and
    # nothing to watch move. That is a reading about the platform and not a gap
    # in this file -- but it is also not this lane answering the question, and a
    # pass here would say it was.
    note "macos has no scriptable UI-font knob; the live half is not run on this lane"
    note "that is the reading, not a gap: see the header"
    nt_skip fontflip.probe.watched "macOS has no scriptable UI-font knob, so there is nothing that could move under a running probe"
    nt_skip fontflip.probe.restored "nothing was flipped on this lane, so nothing had to be put back"
}

run_windows() {
    note "the windows probe is powershell and is driven from the workflow, not from here"
    note "  powershell -ExecutionPolicy Bypass -File test/probe/fontprobe-windows.ps1 $WATCH"
}

# ------------------------------------------------------------------ the live half
#
# A running app, and the desktop's fonts moved underneath it.
#
# run_gtk above asks what the *toolkit* emits. This asks the question that
# actually matters to an app: does a page that was already open get told. Those
# are not the same, and the palette lane has paid for the difference once
# already -- a macOS observer that registered successfully, raised nothing, and
# never fired, invisible to every suite in the tree until neutrinolivetheme.js
# existed.
#
# **Two flips, because the two roles move by different knobs.** `font-name`
# moves `ui` through GtkSettings; `monospace-font-name` moves `monospace`
# through GSettings alone, and GtkSettings has no key for it.
#
# What the second flip is *not* is a test that the `changed::` connections
# exist. Measured on a desk with a settings daemon, with each path silenced in
# turn: with only `changed::` connected the first flip does not arrive and the
# second does; with `changed::` silenced entirely both arrive. So on such a
# desktop `style-updated` carries a GSettings-only change as well, because the
# daemon touches something the window's style notices and readFonts re-reads
# GSettings from scratch.
#
# What it does test is the thing an app actually cares about: that a monospace
# change reaches the page at all, by whichever path this desktop has. That is
# worth a flip of its own precisely because the path differs between a desktop
# with a settings daemon and one without.
#
# The desktop is put back where it was found, on every exit path.

# Empty when the caller names none. The live half is the only reader, and the
# probe half's rows do not pass it -- so a default here was a path that existed
# on two lanes of the five that reach this line.
LIVE_ART="${3:-}"
LOGDIR="${NT_FLIP_LOGDIR:-$HOME}"

# What GTK is actually drawing with, asked of the toolkit rather than of the
# key that was written.
#
# This is the control the first flip cannot do without, and its absence cost a
# CI round. `gtk_set` writes a GSettings key; whether that reaches GtkSettings
# is a fact about the desktop, not about the launcher. On a machine with a
# settings daemon it does. On this suite's own runner there is none, and
# `gtk-font-name` was measured holding "Sans 10" through a `font-name` write
# that GNOME's key took -- so the *rendered* ui font never moved, the launcher
# correctly delivered nothing, and asserting a delivery there blames a lane for
# a knob that did nothing.
#
# themeflip.sh's live half carries the same shape under `gtk_change_seen`, and
# for the same reason: prove the knob before reporting the watcher.
#
# Through fontprobe-gtk.js rather than a second reader of its own, so the
# control and the launcher cannot come to disagree about what GtkSettings says.
gtk_toolkit_font() {
    local runtime=""
    for c in gjs cjs; do command -v "$c" >/dev/null 2>&1 && { runtime="$c"; break; }; done
    [ -n "$runtime" ] || { printf '%s' "<no runtime>"; return 0; }
    timeout 30 "$runtime" "$ROOT/test/probe/fontprobe-gtk.js" 2>&1 |
        sed -n 's/.*gtksettings gtk-font-name=\("[^"]*"\).*/\1/p' | head -1
}

live_half_gtk() {
    local rc=0 after

    command -v gsettings >/dev/null 2>&1 || {
        note "live half: no gsettings here; nothing to flip live"
        skip_live "no gsettings here, so there is no knob a running app could be told about"
        return 0
    }
    [ "$NT_TITLE_HOW" = none ] && {
        note "live half: neither xdotool nor wmctrl is here, so nothing can read a title"
        skip_live "nothing here can read a window title, so the probe's readings cannot be reached"
        return 0
    }
    gtk_save || note "live half: no writable font-name key; the flip may not take"
    # Saved before the app starts and restored on every path out, including the
    # two failures below -- this is a file a person runs on their own desktop.
    trap 'nt_live_stop; gtk_restore' EXIT

    nt_live_start "$ROOT/test/probe/neutrinolivefont.js" "$LIVE_ART" \
        "$LOGDIR/fontflip-live-app.log" || {
        nt_fail fontflip.live.reported "the live probe could not be built, so it never ran"
        skip_live "there was no probe to run, so nothing below was measured"
        nt_live_stop; gtk_restore; trap - EXIT; return 1
    }
    assert_live_up fontflip.live.reported 'STD-LIVEFONT' 90 || {
        skip_live "the probe reported nothing usable, so no flip below could be judged"
        nt_live_stop; gtk_restore; trap - EXIT; return 1
    }

    # --- flip one: the ui role, through GtkSettings ---------------------------
    #
    # Controlled before it is asserted. `ui` is read off GtkSettings, so a
    # GSettings write that does not reach GtkSettings moves nothing the page
    # could be told about -- see gtk_toolkit_font.
    local expect=1 toolkit_before toolkit_after
    toolkit_before="$(gtk_toolkit_font)"
    gtk_set "$FLIP_TO"
    note "live flip 1: font-name -> '$FLIP_TO'"
    toolkit_after="$(gtk_toolkit_font)"
    note "toolkit ui font: ${toolkit_before:-<none>} -> ${toolkit_after:-<none>}"
    if [ "$toolkit_before" = "<no runtime>" ] || [ -z "$toolkit_before" ]; then
        # Distinct from the branch below, and the distinction is the point: a
        # control that could not be taken is not a finding about the desktop.
        # This lane's PyGObject half has neither gjs nor cjs -- the launcher
        # reaches GTK through python3 there -- so the reading is unavailable
        # rather than negative. Saying "the knob did not reach GtkSettings"
        # here would be this file reporting a measurement it never took.
        note "could not read what GTK is drawing with on this lane, so whether the"
        note "  ui knob took cannot be told. Flip one is not asserted; flip two is."
        nt_skip fontflip.live.ui-knob "neither gjs nor cjs is here to read what GTK is drawing with, so whether the knob reached GtkSettings was never measured"
        nt_skip fontflip.live.ui "the ui knob could not be controlled, so a delivery that did not arrive would be unreadable"
    elif [ "$toolkit_before" = "$toolkit_after" ]; then
        note "the ui knob did not reach GtkSettings on this desktop, so the rendered"
        note "  ui font never moved and there was nothing to deliver. Flip one is a"
        note "  reading about this machine and is not asserted; flip two still is."
        nt_skip fontflip.live.ui-knob "the ui knob did not reach GtkSettings on this desktop (${toolkit_before:-<none>} held), which is a fact about the machine and not about the watcher"
        nt_skip fontflip.live.ui "the rendered ui font never moved, so there was nothing for the page to be told about"
    else
        nt_pass fontflip.live.ui-knob "control the ui knob reached GtkSettings: ${toolkit_before:-<none>} -> ${toolkit_after:-<none>}"
        expect=$((expect + 1))
        nt_live_settle 'STD-LIVEFONT' 15 "$expect" || true
        after="$NT_LIVE_TITLE"
        note "live after 1: ${after:-<nothing>}"
        case "$after" in
            *moved=yes*)
                nt_pass fontflip.live.ui "the running app was handed new fonts when the desktop's ui font moved" ;;
            STD-LIVEFONT*)
                nt_fail fontflip.live.ui "the ui font moved under a running app and it was handed nothing; notify::gtk-font-name and style-updated both did not deliver"
                rc=1 ;;
            *)
                nt_fail fontflip.live.ui "live half: the probe stopped writing its title after the first flip"
                rc=1 ;;
        esac
    fi

    # --- flip two: the monospace role, through GSettings alone ----------------
    #
    # The one this file exists for. `monospace-font-name` moves neither
    # `gtk-font-name` nor the window's computed style, so nothing the first
    # flip exercised can carry it.
    local was_mono="" mono_schema=""
    for s in $GTK_SCHEMAS; do
        gsettings writable "$s" monospace-font-name >/dev/null 2>&1 || continue
        was_mono="$(gsettings get "$s" monospace-font-name 2>/dev/null)" || continue
        mono_schema="$s"
        break
    done
    if [ -z "$mono_schema" ]; then
        note "live half: no writable monospace-font-name on this desktop; the second flip is not run"
        note "that is a reading about this machine and not about the watcher"
        nt_skip fontflip.live.mono "no writable monospace-font-name on this desktop, so the one knob this half exists for cannot be moved"
    else
        gsettings set "$mono_schema" monospace-font-name "$MONO_FLIP_TO" >/dev/null 2>&1 || true
        note "live flip 2: $mono_schema monospace-font-name -> '$MONO_FLIP_TO'"
        # One more than whatever the first flip actually delivered, which is
        # not always two: a desktop where the ui knob did not reach the toolkit
        # has delivered nothing yet.
        expect=$((expect + 1))
        nt_live_settle 'STD-LIVEFONT' 15 "$expect" || true
        after="$NT_LIVE_TITLE"
        note "live after 2: ${after:-<nothing>}"
        case "$after" in
            *mono=LiberationMono*|*mono=DejaVuSerif*)
                nt_pass fontflip.live.mono "and again when only the monospace font moved" ;;
            STD-LIVEFONT*)
                nt_fail fontflip.live.mono "the monospace font moved under a running app and it was handed nothing; the changed:: watchers on the GSettings keys did not deliver"
                rc=1 ;;
            *)
                nt_fail fontflip.live.mono "live half: the probe stopped writing its title after the second flip"
                rc=1 ;;
        esac
        gsettings set "$mono_schema" monospace-font-name "$was_mono" >/dev/null 2>&1 || true
        note "monospace knob restored: $(gsettings get "$mono_schema" monospace-font-name 2>/dev/null)"
    fi

    nt_live_stop
    gtk_restore
    trap - EXIT
    return "$rc"
}

# Which half this run is, and it is one knob now rather than the absence of one.
#
# This was `NT_FONTFLIP_LIVE_ONLY=1` on the row that wanted only the live half,
# and nothing on the row that wanted only the probe -- which meant that row ran
# the live half too. Two rows on gjs and on linux-engines each ran it, so one
# lane asked the same question twice, and once these halves carry case ids that
# stops being merely wasteful: matrix.py folds two verdicts on one lane
# FAIL-over-PASS, so a cell would answer for two runs of a question that is only
# asked once.
#
# So the manifest names the half. `probe` is what the toolkit emits, `live` is
# whether a page that was already open is told, and `both` is what a person
# running this file by hand gets, because on a desk there is no reason to pick.
NT_FONTFLIP_HALF="${NT_FONTFLIP_HALF:-both}"

run_gtk_all() {
    local rc=0
    case "$NT_FONTFLIP_HALF" in
        probe|both) run_gtk || rc=$? ;;
        *) skip_probe "this row runs the live half; the probe half is the fontflip row's" ;;
    esac
    case "$NT_FONTFLIP_HALF" in
        live|both)
            # An empty $LIVE_ART is a row that named no live artifact, which is
            # a skip with a reason rather than a launch of a path that is not
            # there. It reads the same way in the grid as the branch below.
            if [ -z "$LIVE_ART" ]; then
                skip_live "this row named no live artifact to watch"
            else
                live_half_gtk || rc=$?
            fi ;;
        *) skip_live "this row runs the probe half; the live half is the fontlive row's" ;;
    esac
    return "$rc"
}

case "$MODE" in
    gtk)     run_gtk_all || true ;;
    qt)      note "the qt lane is launch-only for fonts; there is nothing to flip" ;;
    macos)
        run_macos
        # No live half here and none possible, so the four it would have filed
        # are skipped rather than left as holes -- except that the registry does
        # not name this lane for them at all, which is the other way to say the
        # same thing and the one that keeps the grid honest. See cases.tsv.
        ;;
    windows) run_windows ;;
    *)       echo "fontflip.sh: unknown mode '$MODE'"; exit 2 ;;
esac

# The count, and the exit. This file ended on a $FAILURES of its own that
# run_probe incremented from inside a background subshell, so the one probe that
# could plausibly die -- the one watching a live flip -- could never be counted.
nt_finish
