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

# The two launch halves, skipped only when a caller has asked for the live one
# alone. That caller is test/qtkde.sh, which supplies a KDE inside a container
# and has no business judging the differential: the launch halves reach Qt
# through the gtk3 plugin and a GTK theme, neither of which a KDE image is
# obliged to carry, so running them there would fail on the apparatus and say
# nothing about the lane.
if [ -n "${NT_FLIP_LIVE_ONLY:-}" ]; then
    note "live half only: the two launch halves were not run"
else

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

fi

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
# It used to be macOS only, and the reason given was that `gtk` and `qt` reach
# their theme through GTK_THEME in the environment, which is read when the
# process starts and cannot be changed underneath one. That is true of
# GTK_THEME and it was never true of the lane: a desktop's own knob is
# gsettings, GTK watches it, and the two halves above use the variable only
# because a launch is all they need to configure.
#
# What the GTK half flips is written here rather than chosen from the machine.
# The change this has to catch is an accent move -- one colour, same canvas,
# same derived scheme -- because that is the shape `style-updated` does not
# report, and a runner has no accent picker to borrow. Two throwaway themes
# whose stylesheets differ in exactly one line give it one, on any machine with
# GTK and with no installed theme family to depend on. Measured on Mint 22 /
# Cinnamon: canvas 383838 across both, accent 8fa876 -> b35a57.
NT_THEME_DIR="$HOME/.themes"

gtk_theme_write() {
    # $1 name, $2 accent. Seven colours because readGtkTheme reads seven and
    # refuses a palette missing one; nothing else in a theme is looked at here.
    local d="$NT_THEME_DIR/$1/gtk-3.0"
    mkdir -p "$d" || return 1
    cat > "$d/gtk.css" <<EOF
@define-color theme_bg_color #383838;
@define-color theme_fg_color #dadada;
@define-color theme_base_color #404040;
@define-color theme_text_color #ffffff;
@define-color theme_selected_bg_color $2;
@define-color theme_selected_fg_color #ffffff;
@define-color borders #292929;
EOF
}

# Two knobs, because a desk and a runner do not have the same one and the
# difference was measured rather than assumed. On a Cinnamon desk the settings
# write reaches GTK. On the runners it does not, and neither does the other
# obvious candidate -- one probe round, both GTK lanes:
#
#   org.gnome.desktop.interface: wrote NeutrinoProbeB (readback NeutrinoProbeB)
#   gsettings route fired 0
#   settings.ini route fired 0
#   direct set_property ok
#   direct route fired 1
#
# The write lands, reads back, and GTK never hears it -- gtk-theme-name was
# Yaru there while gsettings said Adwaita, so GTK is reading settings.ini and
# not GSettings, and settings.ini is loaded at startup rather than watched.
# Only the route no process outside the app can take worked, which is why this
# half stood down on the one machine that runs it.
#
# XSettings is what GTK actually listens to for this, and a HUP to xsettingsd
# moved gtk-theme-name in a separate process on both runners. That is the knob
# here, and it is the same channel Qt's platform theme reads.
NT_KNOB=""
NT_XSETTINGSD_MINE=""

gtk_theme_set() {
    case "$NT_KNOB" in
        xsettings)
            printf 'Net/ThemeName "%s"\n' "$1" > "$HOME/.xsettingsd"
            pkill -HUP -x xsettingsd 2>/dev/null
            return 0
            ;;
        *)
            local ok=1
            for schema in org.gnome.desktop.interface org.cinnamon.desktop.interface; do
                gsettings writable "$schema" gtk-theme >/dev/null 2>&1 || continue
                gsettings set "$schema" gtk-theme "$1" >/dev/null 2>&1 && ok=0
            done
            return "$ok"
            ;;
    esac
}

# Started only where there is no desktop to already have one. Two XSettings
# managers on one display is one of them losing the selection, which would
# break the session this is running in rather than the test -- and a desk has
# a manager already, which is why the settings route works there at all.
gtk_xsettingsd_start() {
    # `command -v` and not a `have` helper. This file has no such helper --
    # the line was borrowed from a probe that did -- so it exited 127, the
    # `|| return 1` took it, and the XSettings route was never attempted on
    # any machine. It reported as "no knob on this machine", which is the
    # message for the case where every route was tried and none worked. A desk
    # never showed it because the settings route above succeeds there and this
    # function is not reached.
    command -v xsettingsd >/dev/null 2>&1 || return 1
    [ -n "${XDG_CURRENT_DESKTOP:-}" ] && return 1
    # A manager already up is one to use, not a reason to give up. Something
    # else in the job may have started it, and declining then is how this half
    # reported "no knob" on a machine that had one running.
    if pgrep -x xsettingsd >/dev/null 2>&1; then
        note "live half: using the xsettingsd already running"
        return 0
    fi
    printf 'Net/ThemeName "NeutrinoFlipA"\n' > "$HOME/.xsettingsd"
    xsettingsd -c "$HOME/.xsettingsd" >/dev/null 2>&1 &
    NT_XSETTINGSD_MINE=$!
    sleep 2
    note "live half: started xsettingsd pid=$NT_XSETTINGSD_MINE"
    return 0
}

# The control, and it is the difference between an apparatus defect and a
# finding -- the same distinction knob_read draws for the two halves above. It
# asks a GTK of its own whether *this environment* delivers a theme change at
# all. If it does not, the live half has nothing to observe and says so; if it
# does and the app heard nothing, that is the watcher and it is a failure.
# The watcher half of the control: a GTK that connects the same signal the
# driver connects and reports whether it fired. It does not flip anything.
#
# It used to, and that was the defect that kept this half standing down after
# the knob was found. The flip was a gsettings write hardcoded inside this
# script, so selecting the XSettings knob changed what the *app* would be
# offered and not what the control tested -- the control went on writing a
# setting the runner's GTK does not read, failed, and reported "no knob"
# on a machine where the knob beside it had just been measured working.
# Whatever moves the theme has to be the one thing both of them use.
gtk_watch_notify() {
    python3 - <<'EOF' >/dev/null 2>&1
import sys
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib
st = Gtk.Settings.get_default()
if st is None:
    sys.exit(1)
seen = {"n": 0}
st.connect("notify::gtk-theme-name", lambda *a: seen.__setitem__("n", seen["n"] + 1))
GLib.timeout_add_seconds(8, lambda: (Gtk.main_quit(), False)[1])
Gtk.main()
sys.exit(0 if seen["n"] else 1)
EOF
}

# And the control itself, which flips through gtk_theme_set -- the same
# function the live flip below uses, so the knob the control proves is the
# knob the app is tested with.
gtk_change_seen() {
    local pid
    command -v python3 >/dev/null 2>&1 || return 2
    gtk_theme_set NeutrinoFlipA >/dev/null 2>&1
    sleep 1
    gtk_watch_notify &
    pid=$!
    sleep 2
    gtk_theme_set "$1" >/dev/null 2>&1
    wait "$pid"
}

# The GTK live half.
#
# The app is started under theme A and the desktop moves to theme B while it
# holds still, which is the one thing neither launch-and-compare half can see.
# What separates the two themes is a single colour, so `style-updated` -- the
# signal both GTK lanes watched and the only one they watched until this was
# written -- does not fire for it: the window draws itself identically and GTK
# has no reason to mention the change. Measured, three instruments over five
# theme changes on Mint 22: notify::gtk-theme-name 5, style-updated 2, polling
# 5. This half is the guard on the signal that answers 5.
# The probe's title, by whichever of the two readers this machine has --
# xdotool where there is one and wmctrl otherwise, which is the fallback
# verify-attack.sh already keeps so that a suite step is runnable on a desk and
# not only on a runner. Matched on the prefix the probe writes, because the
# rest of that title is the reading being taken.
live_title() {
    if command -v xdotool >/dev/null 2>&1; then
        local w
        w="$(xdotool search --name '^STD-LIVE' 2>/dev/null | head -1)"
        [ -n "$w" ] && xdotool getwindowname "$w" 2>/dev/null
        return 0
    fi
    wmctrl -l 2>/dev/null |
        sed -n 's/^[^ ]* *[^ ]* *[^ ]* *\(STD-LIVE .*\)$/\1/p' | tail -1
}

live_half_gtk() {
    local before after n rc=0 waited=0 was_gnome="" was_cinnamon=""

    command -v gsettings >/dev/null 2>&1 || {
        note "live half: no gsettings here; nothing to flip live"
        return 0
    }
    command -v xdotool >/dev/null 2>&1 || command -v wmctrl >/dev/null 2>&1 || {
        note "live half: neither xdotool nor wmctrl is here, so nothing can read a title"
        return 0
    }

    was_gnome="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null)"
    was_cinnamon="$(gsettings get org.cinnamon.desktop.interface gtk-theme 2>/dev/null)"
    gtk_live_restore() {
        [ -n "$was_gnome" ] && gsettings set org.gnome.desktop.interface gtk-theme "$was_gnome" >/dev/null 2>&1
        [ -n "$was_cinnamon" ] && gsettings set org.cinnamon.desktop.interface gtk-theme "$was_cinnamon" >/dev/null 2>&1
        rm -rf "$NT_THEME_DIR/NeutrinoFlipA" "$NT_THEME_DIR/NeutrinoFlipB"
        [ -n "$NT_XSETTINGSD_MINE" ] && { kill "$NT_XSETTINGSD_MINE" 2>/dev/null; rm -f "$HOME/.xsettingsd"; }
        [ -n "${LIVE_PID:-}" ] && { pkill -P "$LIVE_PID" 2>/dev/null; kill "$LIVE_PID" 2>/dev/null; }
        return 0
    }

    gtk_theme_write NeutrinoFlipA "#8fa876" || {
        note "live half: could not write a theme under $NT_THEME_DIR"
        return 0
    }
    gtk_theme_write NeutrinoFlipB "#b35a57" || { gtk_live_restore; return 0; }

    # Before anything is launched, because a control that runs after the app
    # has already missed its chance is not a control. Each knob is offered to
    # it in turn and the one that moves a GTK of this suite's own is the one
    # the app is then asked about -- so "no knob here" and "the watcher did
    # not fire" stay two different readings.
    NT_KNOB=gsettings
    gtk_change_seen NeutrinoFlipB
    case $? in
        0) note "live control: the gsettings knob moved a GTK of this suite's own" ;;
        2) note "live half: no python3 with gi to control against; nothing to observe"
           gtk_live_restore; return 0 ;;
        *)
            NT_KNOB=xsettings
            if gtk_xsettingsd_start && gtk_change_seen NeutrinoFlipB; then
                note "live control: the xsettings knob moved a GTK of this suite's own"
            else
                note "live half: no knob on this machine delivers a theme change to GTK; no live flip to observe"
                gtk_live_restore; return 0
            fi
            ;;
    esac

    if [ ! -f "$LIVE_ART" ]; then
        note "live half: building $LIVE_ART"
        bash "$ROOT/test/mkapp.sh" --testing \
            "$ROOT/test/neutrinolivetheme.js" "$LIVE_ART" || {
            echo "FAIL: live half: could not build the live probe"
            gtk_live_restore; return 1
        }
    fi

    knob_clear
    gtk_theme_set NeutrinoFlipA
    sleep 2
    bash "$LIVE_ART" > "$LOGDIR/flip-live-app.log" 2>&1 &
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
        echo "FAIL: live half: no STD-LIVE window in 90s; the probe never came up"
        gtk_live_restore; return 1
    }
    note "live before: $before"
    case "$before" in
        *src=null*)
            echo "FAIL: live half: the probe read no toolkit, so a flip would prove nothing"
            gtk_live_restore; return 1 ;;
    esac

    gtk_theme_set NeutrinoFlipB
    case "$NT_KNOB" in
        xsettings) note "live knob after the flip: $(cat "$HOME/.xsettingsd" 2>/dev/null)" ;;
        *) note "live knob after the flip: $(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null)" ;;
    esac

    waited=0
    while [ "$waited" -lt 30 ]; do
        after="$(live_title)"
        case "$after" in *"moved=yes"*) break ;; esac
        sleep 0.5
        waited=$((waited + 1))
    done
    after="$(live_title)"
    note "live after: ${after:-<nothing>}"

    n="$(printf '%s' " $after" | sed -n 's/.* n=\([0-9]*\).*/\1/p')"
    case "$after" in
        *"moved=yes"*)
            echo "PASS: the running app was handed a new palette when the desktop's accent moved"
            note "live readings n=${n:-?}" ;;
        STD-LIVE*)
            echo "FAIL: the accent moved under a running app and it was handed nothing (n=${n:-?}); the theme watcher did not fire"
            rc=1 ;;
        *)
            echo "FAIL: live half: the probe stopped writing its title after the flip"
            rc=1 ;;
    esac

    gtk_live_restore
    return "$rc"
}

# The Qt live half.
#
# What this measures is the platform theme, not Qt. Qt asks its platform theme
# for the palette, and the two that matter answer differently: QGtk3Theme --
# what a bare Qt install picks up off a non-KDE desktop, and what this suite's
# own runner has -- never rebuilds a palette once the process is up, so there
# is nothing there for a probe to be handed. KDE's KDEPlasmaPlatformTheme6
# pushes a new palette into the running QGuiApplication, and SystemPalette's
# bindings carry it to the window, the view and the page with no signal
# connected anywhere. So this half runs where that plugin is and says which
# machine it was on where it is not.
#
# Measured in a Fedora 42 container, Qt 6.10.2, plasma-integration 6.6.4:
#
#   before  STD-LIVE n=1 moved=no  src=qt scheme=light canvas=eff0f1
#   after   STD-LIVE n=2 moved=yes src=qt scheme=dark  canvas=202326
#
# test/qtkde.sh is the container that provides that desktop; this function is
# what it runs inside it.
qt_qmlbin() {
    local c p
    for c in qml6 qml; do
        command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
    done
    for p in /usr/lib64/qt6/bin/qml /usr/lib/qt6/bin/qml /usr/lib/*/qt6/bin/qml; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# The window colour a fresh Qt process is handed, which is the control's
# reading and never the app's. QT_FORCE_STDERR_LOGGING because Fedora builds
# Qt against journald: without it qWarning leaves stderr entirely, the probe
# exits 0 and prints nothing, and an empty reading looks like a palette that
# did not move.
qt_start_window() {
    QT_FORCE_STDERR_LOGGING=1 XDG_CURRENT_DESKTOP=KDE \
        timeout 60 "$NT_QMLBIN" "$ROOT/test/qtpalette.qml" 2 2>&1 |
        sed -n 's/.*QTPROBE start window=\([^ ]*\).*/\1/p' | head -1
}

live_half_qt() {
    local before after n rc=0 waited=0 was="" lit="" drk="" qt_kde_p qt_kde_plugin

    command -v plasma-apply-colorscheme >/dev/null 2>&1 || {
        note "live half: no plasma-apply-colorscheme here; this is not a KDE and the GTK plugin delivers nothing live (see qml/window.qml)"
        return 0
    }
    # One path at a time. `ls a b c` reports failure when any single one of
    # them is missing, so a list here is a guard that never passes -- which is
    # how a whole branch once ran green without running at all.
    qt_kde_plugin=""
    for qt_kde_p in /usr/lib64/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so \
                    /usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so \
                    /usr/lib/*/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so; do
        [ -e "$qt_kde_p" ] && { qt_kde_plugin="$qt_kde_p"; break; }
    done
    [ -n "$qt_kde_plugin" ] || {
        note "live half: no Qt 6 KDE platform theme here; Qt would load QGtk3Theme, which delivers nothing live (see qml/window.qml)"
        return 0
    }
    note "live half: KDE platform theme at $qt_kde_plugin"
    NT_QMLBIN="$(qt_qmlbin)" || {
        note "live half: no qml runtime here to take a control reading with"
        return 0
    }
    command -v xdotool >/dev/null 2>&1 || command -v wmctrl >/dev/null 2>&1 || {
        note "live half: neither xdotool nor wmctrl is here, so nothing can read a title"
        return 0
    }

    # Put the desktop back where it was found. This half is one a person has a
    # reason to run on their own machine, and their colour scheme is theirs.
    was="$(kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null)"
    qt_live_restore() {
        plasma-apply-colorscheme "${was:-BreezeLight}" >/dev/null 2>&1
        [ -n "${LIVE_PID:-}" ] && {
            pkill -P "$LIVE_PID" 2>/dev/null
            kill "$LIVE_PID" 2>/dev/null
        }
        return 0
    }

    # The control, before anything is launched. Two schemes each set *before*
    # a process starts: if the two readings come back equal then the knob never
    # reached Qt, and a flip that then changed nothing would be unreadable --
    # "Qt does not re-read" and "the knob never arrived" look identical from
    # the far side. This is the step the Ubuntu runner could never pass.
    plasma-apply-colorscheme BreezeLight >/dev/null 2>&1
    lit="$(qt_start_window)"
    plasma-apply-colorscheme BreezeDark >/dev/null 2>&1
    drk="$(qt_start_window)"
    note "live control: BreezeLight window=${lit:-<nothing>} BreezeDark window=${drk:-<nothing>}"
    if [ -z "$lit" ] || [ -z "$drk" ]; then
        note "live half: the control read no palette at all, so the knob cannot be judged; nothing to observe"
        qt_live_restore
        return 0
    fi
    if [ "$lit" = "$drk" ]; then
        note "live half: a scheme set before launch does not reach SystemPalette here, so a flip under a running process would prove nothing"
        qt_live_restore
        return 0
    fi
    note "live control: the colour scheme knob moves a Qt palette across launches"

    if [ ! -f "$LIVE_ART" ]; then
        note "live half: building $LIVE_ART"
        bash "$ROOT/test/mkapp.sh" --testing \
            "$ROOT/test/neutrinolivetheme.js" "$LIVE_ART" || {
            echo "FAIL: live half: could not build the live probe"
            qt_live_restore; return 1
        }
    fi

    plasma-apply-colorscheme BreezeLight >/dev/null 2>&1
    sleep 2
    bash "$LIVE_ART" > "$LOGDIR/flip-live-app.log" 2>&1 &
    LIVE_PID=$!

    # By title and not by pid: the .cmd execs an interpreter, so the process
    # holding the window is a child whose pid this shell never learns.
    while [ "$waited" -lt 180 ]; do
        [ -n "$(live_title)" ] && break
        sleep 1
        waited=$((waited + 1))
    done
    before="$(live_title)"
    [ -z "$before" ] && {
        echo "FAIL: live half: no STD-LIVE window in 180s; the probe never came up"
        qt_live_restore; return 1
    }
    note "live before: $before"
    case "$before" in
        *src=null*)
            echo "FAIL: live half: the probe read no toolkit, so a flip would prove nothing"
            qt_live_restore; return 1 ;;
        *src=qt*) ;;
        *)
            note "live half: the probe came up on $(printf '%s' "$before" | sed -n 's/.* src=\([^ ]*\).*/\1/p') and not qt; nothing here to judge the Qt lane by"
            qt_live_restore; return 0 ;;
    esac

    # plasma-apply-colorscheme and not a kdeglobals edit, and the difference is
    # the whole reading: KDE delivers this over a DBus change notification, so
    # writing the file with kwriteconfig6 and no --notify moves the file and
    # fires nothing. A half knobbed that way reports a dead watcher on a
    # desktop where it works.
    plasma-apply-colorscheme BreezeDark >/dev/null 2>&1
    note "live knob after the flip: ColorScheme=$(kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null)"

    waited=0
    while [ "$waited" -lt 30 ]; do
        after="$(live_title)"
        case "$after" in *"moved=yes"*) break ;; esac
        sleep 0.5
        waited=$((waited + 1))
    done
    after="$(live_title)"
    note "live after: ${after:-<nothing>}"

    n="$(printf '%s' " $after" | sed -n 's/.* n=\([0-9]*\).*/\1/p')"
    case "$after" in
        *"moved=yes"*)
            echo "PASS: the running app was handed a new palette when the desktop's colour scheme moved"
            note "live readings n=${n:-?}" ;;
        STD-LIVE*)
            echo "FAIL: the colour scheme moved under a running app and it was handed nothing (n=${n:-?}); the theme watcher did not fire"
            rc=1 ;;
        *)
            echo "FAIL: live half: the probe stopped writing its title after the flip"
            rc=1 ;;
    esac

    qt_live_restore
    return "$rc"
}

live_half() {
    local before after n rc=0 waited=0

    # Two of the three modes have a knob that is desktop state rather than a
    # variable in this shell, and each carries its own half above.
    if [ "$MODE" = qt ]; then
        live_half_qt
        return $?
    fi

    if [ "$MODE" = gtk ]; then
        live_half_gtk
        return $?
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

if [ -n "${NT_FLIP_LIVE_ONLY:-}" ]; then
    DIFF_RC=0
else
    bash "$ROOT/test/themediff.sh" "$LOGDIR/flip-a.log" "$LOGDIR/flip-b.log"
    DIFF_RC=$?
fi

# The live half is not part of the differential -- it asks a different question
# of a different probe -- so its result is carried out here rather than folded
# into a count that means "colours that did not move".
exit $((DIFF_RC + LIVE_RC))
