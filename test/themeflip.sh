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
# The live half's probe, which is a different app asking a different question --
# see live_half at the bottom. Defaulted rather than required, so a caller that
# predates this half runs it instead of silently not running it; CI names it
# anyway, so the artifact goes through parse.sh with the others.
LIVE_ART="${4:-$ROOT/test/neutrinolivetheme.cmd}"

note() { echo "report: $*"; }

# Put the desktop back where it was found.
#
# This file has always ended on knob_clear, which is not "restore" -- it is
# "set light", and on a runner the difference does not arise because nothing
# ever looks again. It arises everywhere else: the live half below is the first
# thing here that a person has a reason to run on their own machine, and a
# suite that leaves somebody's appearance setting flipped is one they run once.
#
# macOS only, because it is the only mode whose knob is machine state rather
# than a variable in this shell.
if [ "${1:-gtk}" = macos ]; then
    NT_KNOB_WAS="$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo light)"
    nt_knob_restore() {
        if [ "$NT_KNOB_WAS" = light ]; then
            osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' >/dev/null 2>&1
            defaults delete -g AppleInterfaceStyle >/dev/null 2>&1 || true
        else
            osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' >/dev/null 2>&1
            defaults write -g AppleInterfaceStyle "$NT_KNOB_WAS" >/dev/null 2>&1 || true
        fi
    }
    trap nt_knob_restore EXIT
fi

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

# The third half, and the one the two above cannot stand in for.
#
# Everything before this line flips the desktop and then *starts* an app. The
# palette is read at startup on every platform, so both halves pass with the
# theme watcher dead -- and on macOS it was. Both of that driver's notification
# registrations passed `null` where ObjC wanted nil, JXA turned it into NSNull,
# and the two failed differently: the distributed centre raised
# "-[NSNull length]: unrecognized selector" and the local one took the NSNull
# quietly and used it as an object filter nothing could ever match. It never
# raised and it never fired. The differential above was green through all of it,
# because it never had a running app to flip underneath.
#
# So this half starts the app first and moves the desktop after. What it asserts
# is one thing the other two cannot see: that a launcher which is already up
# hands its page a new palette.
#
# macOS only, and that is the knob's doing rather than a decision. `gtk` and
# `qt` reach their theme through GTK_THEME in the environment, which is read
# when the process starts and cannot be changed underneath one. There is no
# live flip to perform on those lanes, so there is nothing here to skip.
live_half() {
    local before after n rc=0 waited=0

    if [ "$MODE" != macos ]; then
        note "live half: the knob on $MODE is an environment variable; nothing to flip live"
        return 0
    fi

    # Built here when it was not handed in, so a caller that has not been
    # taught about this probe still runs the half rather than silently not
    # running it. CI builds and parse-checks it beside the other artifacts.
    if [ ! -f "$LIVE_ART" ]; then
        note "live half: building $LIVE_ART"
        bash "$ROOT/test/mkapp.sh" --testing \
            "$ROOT/test/neutrinolivetheme.js" "$LIVE_ART" || {
            echo "FAIL: live half: could not build the live probe"
            return 1
        }
    fi

    knob_clear
    rm -f "$STATUS"
    bash "$LIVE_ART" > "$LOGDIR/flip-live-app.log" 2>&1 &
    LIVE_PID=$!
    # Every way out of this function goes through here, including the two that
    # give up before the flip. A half that returns leaving its app on screen
    # hands the next thing to read a title the same shape as its own -- which
    # is the hazard the whole wait_gone dance above this exists for, arriving
    # from the one direction that dance cannot see.
    live_stop() {
        pkill -P "$LIVE_PID" 2>/dev/null || true
        kill "$LIVE_PID" 2>/dev/null || true
    }

    # The first reading, and the app is not asked to hurry. This is the same
    # budget the other halves' verifier allows for a first window on this
    # platform: osascript starting, the bridge coming up, WKWebView creating
    # its content process.
    while [ "$waited" -lt 180 ]; do
        before="$(sed -n '1p' "$STATUS" 2>/dev/null)"
        case "$before" in STD-LIVE*) break ;; esac
        sleep 1
        waited=$((waited + 1))
    done
    case "${before:-}" in
        STD-LIVE*) note "live before: $before" ;;
        *)
            echo "FAIL: live half: no STD-LIVE title in 180s; the probe never came up"
            live_stop
            return 1 ;;
    esac
    case "$before" in
        *src=null*)
            echo "FAIL: live half: the probe read no toolkit, so a flip would prove nothing"
            live_stop
            return 1 ;;
    esac

    # System Events and not `defaults write`, and this half is the reason the
    # comment in knob_set says which of the two notifies. `defaults write` lands
    # in the plist and tells nobody, so an app already running never hears it --
    # which is exactly the reading this half must not produce by accident. The
    # supported switch is the only one that posts
    # AppleInterfaceThemeChangedNotification, so it is the only one used here.
    osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' \
        >/dev/null 2>&1
    note "live knob after the flip: [$(knob_read)]"

    # And whether it moved at all, asked of the machine rather than assumed
    # from the request. A runner that refuses automation refuses that line
    # silently, and a half that then waited for a theme change would report the
    # watcher broken when what failed was the switch.
    if [ "$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode' 2>/dev/null)" != "true" ]; then
        note "live half: the appearance switch did not take (automation refused?); no live flip to observe"
        live_stop
        return 0
    fi

    # Ten seconds against a notification that arrives in one. The palette is
    # delivered by evaluating into the page, so what is being waited for is a
    # notification, a re-read, a diff and one script evaluation.
    waited=0
    while [ "$waited" -lt 20 ]; do
        after="$(sed -n '1p' "$STATUS" 2>/dev/null)"
        case "$after" in *"moved=yes"*) break ;; esac
        sleep 0.5
        waited=$((waited + 1))
    done
    after="$(sed -n '1p' "$STATUS" 2>/dev/null)"
    note "live after: ${after:-<nothing>}"

    n="$(printf '%s' " $after" | sed -n 's/.* n=\([0-9]*\).*/\1/p')"
    case "$after" in
        *"moved=yes"*)
            echo "PASS: the running app was handed a new palette when the desktop flipped"
            note "live readings n=${n:-?}" ;;
        STD-LIVE*)
            echo "FAIL: the desktop flipped under a running app and it was handed nothing (n=${n:-?}); the theme watcher did not fire"
            rc=1 ;;
        *)
            echo "FAIL: live half: the probe stopped writing its title after the flip"
            rc=1 ;;
    esac

    live_stop
    return "$rc"
}

LIVE_RC=0
live_half || LIVE_RC=$?
knob_clear

bash "$ROOT/test/themediff.sh" "$LOGDIR/flip-a.log" "$LOGDIR/flip-b.log"
DIFF_RC=$?

# The live half is not part of the differential -- it asks a different question
# of a different probe -- so its result is carried out here rather than folded
# into a count that means "colours that did not move".
exit $((DIFF_RC + LIVE_RC))
