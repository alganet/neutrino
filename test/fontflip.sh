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

MODE="${1:-gtk}"
WATCH="${2:-8}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

note() { echo "report: $*"; }

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
    else
        note "the probe printed no FONTPROBE line (exit $rc); its whole output follows"
        sed 's/^/  probe: /' "$out"
        FAILURES=$((FAILURES + 1))
    fi
    rm -f "$out"
}

fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

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

run_gtk() {
    command -v gsettings >/dev/null 2>&1 || { note "no gsettings here; nothing to flip"; return 0; }
    local runtime=""
    for c in gjs cjs; do command -v "$c" >/dev/null 2>&1 && { runtime="$c"; break; }; done
    [ -n "$runtime" ] || { note "no gjs or cjs here; the gtk probe cannot run"; return 0; }
    note "gtk runtime=$runtime"

    gtk_save || { note "no writable font-name key in any schema; nothing to flip"; }
    trap gtk_restore EXIT
    note "gtk knob saved: $(printf '%s' "$gtk_saved" | tr '\n' ' ')"

    # Baseline first, with no watch, so the reading of what the desktop *is*
    # cannot be confused with the reading of what it became.
    note "--- gtk baseline"
    run_probe 30 "$runtime" "$ROOT/test/fontprobe-gtk.js"

    note "--- gtk live (${WATCH}s, flipped at 2s)"
    run_probe $((WATCH + 20)) "$runtime" "$ROOT/test/fontprobe-gtk.js" "$WATCH" &
    local probe=$!
    sleep 2
    gtk_set "$FLIP_TO"
    note "flipped to '$FLIP_TO'"
    wait "$probe" 2>/dev/null || true

    gtk_restore
    trap - EXIT

    note "--- gtk after restore"
    timeout 30 "$runtime" "$ROOT/test/fontprobe-gtk.js" 2>&1 |
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
    command -v osascript >/dev/null 2>&1 || { note "no osascript here"; return 0; }
    note "--- macos baseline"
    run_probe 60 osascript -l JavaScript "$ROOT/test/fontprobe-macos.js"
    note "macos has no scriptable UI-font knob; the live half is not run on this lane"
    note "that is the reading, not a gap: see the header"
}

run_windows() {
    note "the windows probe is powershell and is driven from the workflow, not from here"
    note "  powershell -ExecutionPolicy Bypass -File test/fontprobe-windows.ps1 $WATCH"
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

LIVE_ART="${3:-$ROOT/test/neutrinolivefont.cmd}"
LOGDIR="${NT_FLIP_LOGDIR:-$HOME}"

live_title() {
    if command -v xdotool >/dev/null 2>&1; then
        local w
        w="$(xdotool search --name '^STD-LIVEFONT' 2>/dev/null | head -1)"
        [ -n "$w" ] && xdotool getwindowname "$w" 2>/dev/null
        return 0
    fi
    wmctrl -l 2>/dev/null |
        sed -n 's/^[^ ]* *[^ ]* *[^ ]* *\(STD-LIVEFONT .*\)$/\1/p' | tail -1
}

live_stop() {
    [ -n "${LIVE_PID:-}" ] || return 0
    pkill -P "$LIVE_PID" 2>/dev/null || true
    kill "$LIVE_PID" 2>/dev/null || true
    LIVE_PID=""
}

# Wait for a title to say `moved=yes` with at least N readings behind it.
#
# The count matters as much as the word. After the second flip the title
# already says `moved=yes` from the first one, so a wait on the word alone
# would return immediately and report a watcher that never fired as working.
live_await() {
    local want="$1" waited=0 t n
    while [ "$waited" -lt 30 ]; do
        t="$(live_title)"
        n="$(printf '%s' " $t" | sed -n 's/.* n=\([0-9]*\).*/\1/p')"
        case "$t" in
            *moved=yes*) [ -n "$n" ] && [ "$n" -ge "$want" ] && { printf '%s' "$t"; return 0; } ;;
        esac
        sleep 0.5
        waited=$((waited + 1))
    done
    printf '%s' "$(live_title)"
    return 1
}

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
    timeout 30 "$runtime" "$ROOT/test/fontprobe-gtk.js" 2>&1 |
        sed -n 's/.*gtksettings gtk-font-name=\("[^"]*"\).*/\1/p' | head -1
}

live_half_gtk() {
    local rc=0 waited=0 before after

    command -v gsettings >/dev/null 2>&1 || {
        note "live half: no gsettings here; nothing to flip live"
        return 0
    }
    command -v xdotool >/dev/null 2>&1 || command -v wmctrl >/dev/null 2>&1 || {
        note "live half: neither xdotool nor wmctrl is here, so nothing can read a title"
        return 0
    }
    if [ ! -r "$LIVE_ART" ]; then
        bash "$ROOT/test/mkapp.sh" --testing "$ROOT/test/neutrinolivefont.js" "$LIVE_ART" || {
            echo "FAIL: live half: could not build the live probe"
            return 1
        }
    fi

    gtk_save || note "live half: no writable font-name key; the flip may not take"
    # Saved before the app starts and restored on every path out, including the
    # two failures below -- this is a file a person runs on their own desktop.
    trap 'live_stop; gtk_restore' EXIT

    bash "$LIVE_ART" > "$LOGDIR/fontflip-live-app.log" 2>&1 &
    LIVE_PID=$!

    # By title and not by pid: the .cmd execs an interpreter, so the process
    # holding the window is a child whose pid this shell never learns.
    while [ "$waited" -lt 90 ]; do
        [ -n "$(live_title)" ] && break
        sleep 1
        waited=$((waited + 1))
    done
    before="$(live_title)"
    [ -z "$before" ] && {
        echo "FAIL: live half: no STD-LIVEFONT window in 90s; the probe never came up"
        live_stop; gtk_restore; trap - EXIT; return 1
    }
    note "live before: $before"
    case "$before" in
        *src=null*)
            echo "FAIL: live half: the probe read no toolkit, so a flip would prove nothing"
            live_stop; gtk_restore; trap - EXIT; return 1 ;;
    esac

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
    elif [ "$toolkit_before" = "$toolkit_after" ]; then
        note "the ui knob did not reach GtkSettings on this desktop, so the rendered"
        note "  ui font never moved and there was nothing to deliver. Flip one is a"
        note "  reading about this machine and is not asserted; flip two still is."
    else
        expect=$((expect + 1))
        after="$(live_await "$expect")" || true
        note "live after 1: ${after:-<nothing>}"
        case "$after" in
            *moved=yes*)
                echo "PASS: the running app was handed new fonts when the desktop's ui font moved" ;;
            STD-LIVEFONT*)
                echo "FAIL: the ui font moved under a running app and it was handed nothing; notify::gtk-font-name and style-updated both did not deliver"
                rc=1 ;;
            *)
                echo "FAIL: live half: the probe stopped writing its title after the first flip"
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
    else
        gsettings set "$mono_schema" monospace-font-name "$MONO_FLIP_TO" >/dev/null 2>&1 || true
        note "live flip 2: $mono_schema monospace-font-name -> '$MONO_FLIP_TO'"
        # One more than whatever the first flip actually delivered, which is
        # not always two: a desktop where the ui knob did not reach the toolkit
        # has delivered nothing yet.
        expect=$((expect + 1))
        after="$(live_await "$expect")" || true
        note "live after 2: ${after:-<nothing>}"
        case "$after" in
            *mono=LiberationMono*|*mono=DejaVuSerif*)
                echo "PASS: and again when only the monospace font moved" ;;
            STD-LIVEFONT*)
                echo "FAIL: the monospace font moved under a running app and it was handed nothing; the changed:: watchers on the GSettings keys did not deliver"
                rc=1 ;;
            *)
                echo "FAIL: live half: the probe stopped writing its title after the second flip"
                rc=1 ;;
        esac
        gsettings set "$mono_schema" monospace-font-name "$was_mono" >/dev/null 2>&1 || true
        note "monospace knob restored: $(gsettings get "$mono_schema" monospace-font-name 2>/dev/null)"
    fi

    live_stop
    gtk_restore
    trap - EXIT
    return "$rc"
}

# Both halves by default, and the probe half skippable.
#
# themeflip.sh carries the same knob under the same reasoning: the container
# that supplies a real desktop has one question to ask and no reason to pay for
# the other. Here it is the reverse of that lane -- the probe half is the cheap
# one and the live half needs a display -- but the shape is the one a reader of
# this tree already knows.
run_gtk_all() {
    local rc=0
    if [ "${NT_FONTFLIP_LIVE_ONLY:-}" != "1" ]; then
        run_gtk || rc=$?
    fi
    live_half_gtk || rc=$?
    return "$rc"
}

case "$MODE" in
    gtk)     run_gtk_all || FAILURES=$((FAILURES + 1)) ;;
    qt)      note "the qt lane is launch-only for fonts; there is nothing to flip" ;;
    macos)   run_macos ;;
    windows) run_windows ;;
    *)       echo "fontflip.sh: unknown mode '$MODE'"; exit 2 ;;
esac

note "totals fontflip failures=$FAILURES"
exit "$FAILURES"
