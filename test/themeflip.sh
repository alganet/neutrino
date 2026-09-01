#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# themeflip.sh - two launches of the theme probe with the desktop flipped
# between them, and the differential that reads them.
#
# Usage: themeflip.sh <gtk|qt|macos> <artifact> [screenshot-dir]
#
# The sequencing is here rather than in six copies of a workflow step, because
# two things about it are easy to get wrong and neither is visible in YAML.
#
# The knob is cleared before it is set, each half. A section that measures a
# switch cannot take the switch's position from the room it runs in -- the kde
# lane exports Qt and Chromium variables of its own, and a half that inherited
# one would be reporting about the lane's environment rather than about the one
# it set.
#
# And the second half refuses to start while the first half's window is still
# up. Both halves carry the same title prefix, so a window that outlived its
# kill is one the next verifier would attach to and report about -- a stale
# reading that looks exactly like a real one, which is how a whole round was
# once lost to a phase reading the previous phase's title.

set -uo pipefail

MODE="${1:-gtk}"
ART="${2:-test/neutrinostdtheme.cmd}"
SHOTS="${3:-$HOME/screenshots}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${NT_FLIP_LOGDIR:-$HOME}"

note() { echo "report: $*"; }

# Each mode names the two states and how to reach them. Nothing else in this
# file knows which platform it is on.
knob_clear() {
    case "$MODE" in
        gtk|qt) unset GTK_THEME QT_QPA_PLATFORMTHEME ;;
        macos)
            osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' >/dev/null 2>&1
            defaults delete -g AppleInterfaceStyle >/dev/null 2>&1 || true
            ;;
    esac
}

knob_set() {
    case "$MODE" in
        gtk)
            export GTK_THEME="$1"
            ;;
        qt)
            # Qt takes its palette from the platform theme, so the GTK theme is
            # reached through the gtk3 plugin. Whether that plugin is installed
            # on this runner is not assumed: the differential's own control
            # fails if the palette did not move, which is the honest answer for
            # a lane whose knob does not work.
            export QT_QPA_PLATFORMTHEME=gtk3
            export GTK_THEME="$1"
            ;;
        macos)
            # Two spellings, because neither is dependable alone. System Events
            # is the supported switch and the only one that notifies anything,
            # but it is an automation request and a runner that refuses
            # automation refuses it silently. `defaults write` always lands in
            # the plist and is what the app actually reads, but it notifies
            # nobody. So: ask the supported one, then write the default
            # regardless, and let knob_read say what the machine ended up at.
            if [ "$1" = dark ]; then
                osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' >/dev/null 2>&1
                defaults write -g AppleInterfaceStyle Dark >/dev/null 2>&1 || true
            else
                osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' >/dev/null 2>&1
                defaults delete -g AppleInterfaceStyle >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

# What the machine says the knob is at, asked after it was set and from outside
# the app. Without this the two halves report the state they *requested*, and a
# lane where nothing moved cannot say whether the knob failed or the engine
# ignored it -- which is the whole difference between an apparatus defect and a
# finding. A derived number and its input are two readings; this is the input.
knob_read() {
    case "$MODE" in
        gtk|qt) printf '%s' "GTK_THEME=${GTK_THEME:-<unset>} QT_QPA_PLATFORMTHEME=${QT_QPA_PLATFORMTHEME:-<unset>}" ;;
        macos)
            printf 'AppleInterfaceStyle=%s darkmode=%s' \
                "$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo '<absent:light>')" \
                "$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode' 2>/dev/null || echo '<refused>')"
            ;;
    esac
}

# What the two halves are called on this platform, in order.
case "$MODE" in
    gtk|qt) STATE_A="Adwaita"; STATE_B="Adwaita:dark" ;;
    macos)  STATE_A="light";   STATE_B="dark" ;;
    *)      echo "FAIL: themeflip.sh: unknown mode '$MODE'"; exit 1 ;;
esac

# A window carrying this prefix, from anywhere. Between halves it can only be
# the previous half's, which is the thing being waited out.
#
# x11 asks the server. macOS has no window a shell can query, so it asks the
# status file -- and the question there has to be posed the other way round: the
# file is not a window, it is a thing the app *writes*, and a dead app leaves
# its last line behind forever. Removing it and watching whether it comes back
# is what distinguishes an app that has gone from a title that has stopped
# changing. The ticker rewrites every 200 ms, so a second is generous.
STATUS="${TMPDIR:-/tmp}/neutrino-title.txt"

prefix_up() {
    case "$MODE" in
        macos)
            rm -f "$STATUS"
            sleep 1
            sed -n '1p' "$STATUS" 2>/dev/null | grep -q '^STD-THEME-'
            ;;
        *)
            [ -n "$(xdotool search --name '^STD-THEME-' 2>/dev/null | head -1)" ]
            ;;
    esac
}

wait_gone() {
    local n=0 limit=60
    [ "$MODE" = macos ] && limit=30
    while [ "$n" -lt "$limit" ]; do
        prefix_up || return 0
        n=$((n + 1))
        [ "$MODE" = macos ] || sleep 0.5
    done
    return 1
}

# The third argument is what the picture is called. `flip-b` is not a thing a
# reader can check; `theme-dark` is. Both halves wrote one filename until this
# round, so the light half has never appeared in an artifact.
run_half() {
    local state="$1" tag="$2" shot="$3" pid rc=0
    knob_clear
    knob_set "$state"
    note "knob $tag requested='$state' readback=[$(knob_read)]"
    # macOS reads its title through one fixed path, and a line left by the
    # other half is a reading attributed to this one.
    [ "$MODE" = macos ] && rm -f "$STATUS"
    bash "$ART" > "$LOGDIR/flip-$tag-app.log" 2>&1 &
    pid=$!
    NT_SHOT_NAME="theme-$shot" \
        bash "$ROOT/test/verify-std.sh" theme "$SHOTS" > "$LOGDIR/flip-$tag.log" 2>&1 || rc=$?
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    note "half $tag state='$state' verifier=$rc"
    return 0
}

echo "themeflip.sh: mode=$MODE artifact=$ART"

# Asked before anything is launched, because a window left by an earlier step in
# the same lane is exactly as poisonous as one left by the first half.
if prefix_up; then
    echo "FAIL: a STD-THEME- window was already up before the first half started"
    echo "report: totals themeflip failures=1"
    exit 1
fi

run_half "$STATE_A" a light

# The precondition, not a courtesy sleep. Both halves answer to the same
# prefix, so starting the second while the first is still on screen produces a
# reading from the wrong desktop that is indistinguishable from a real one.
if ! wait_gone; then
    echo "FAIL: the first half's window is still up after 30s; the second half would read it"
    echo "report: totals themeflip failures=1"
    exit 1
fi
note "the first half's window is gone; the second may start"

run_half "$STATE_B" b dark
knob_clear

bash "$ROOT/test/themediff.sh" "$LOGDIR/flip-a.log" "$LOGDIR/flip-b.log"
