#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# appdir.sh - the program the Qt launch path runs has no name
#
# PR 7 took the macOS seatbelt profile out of a file and put it on
# sandbox-exec's command line. `run_qt` had the same shape and nobody had
# looked: it wrote neutrino.js and window.qml into app_dir -- the one directory
# the sandbox makes writable, and under netinstall the app's own -- and handed
# them to the QML engine as the program to run.
#
# Three things were measured before the fix, each with the window up and the
# launch looking normal from outside:
#
#   - a planted neutrino.js this run could not overwrite ran anyway
#   - a planted window.qml ran as an entirely different program
#   - a file the run *did* write, replaced between the write and the engine's
#     open, ran as well
#
# The third is why checking the write was not the answer. The document is now
# created under `set -C`, unlinked at once and handed over as a descriptor
# path, so there is no name to plant under and nothing to replace.
#
# What this asserts, and each of them fails against the commit before this one:
#
#   nodoc    a launch leaves no document in app_dir, and the engine's own
#            command line names a descriptor
#   plant    a planted neutrino.js and window.qml are not read
#   race     a document rewritten throughout the launch is not read
#   inject   a directory name that used to close the generated string is now
#            a string, and the app comes up in it
#
# Three controls, because each of the four could pass by the app never running
# at all: the shipped build has to come up and drive its own page script -- the
# title only reaches "LOADERS READY" through the preload, the bridge and the
# page script -- the planted payload is proven live by running it directly
# through qml, and every marker is assembled at run time so a parser quoting a
# bad line back cannot be mistaken for code that ran.
#
# Usage: appdir.sh <app.cmd built from test/neutrinoloaders.js>

set -uo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -f "$APP" ]; then
    echo "usage: appdir.sh <app.cmd built from test/neutrinoloaders.js>" >&2
    exit 2
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0
UP_WAIT=25

report() { echo "report: $*"; }
fail()   { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

QML_RUNNER=""
for c in qml6 qml /usr/lib/qt6/bin/qml; do
    if command -v "$c" >/dev/null 2>&1; then QML_RUNNER="$(command -v "$c")"; break; fi
    [ -x "$c" ] && { QML_RUNNER="$c"; break; }
done

# The launcher takes the gjs branch wherever gjs exists, and then none of this
# is being asked of anything. Said out loud rather than reported as a row of
# clean readings.
HAVE_GJS=no
command -v gjs >/dev/null 2>&1 && HAVE_GJS=yes

# =====================================================================
# Running a launch
# =====================================================================
descendants() {
    local pid="$1" child
    echo "$pid"
    for child in $(pgrep -P "$pid" 2>/dev/null); do descendants "$child"; done
}

engine_pid() {
    local p comm
    for p in $(descendants "$1"); do
        comm="$(ps -o comm= -p "$p" 2>/dev/null | tr -d ' ')"
        case "${comm##*/}" in
            qml|qml6|qmlscene*) echo "$p"; return 0 ;;
        esac
    done
    return 1
}

app_up() {
    local i
    for i in $(seq 1 "$1"); do
        xdotool search --name 'LOADERS READY' >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

app_down() {
    local i
    for i in $(seq 1 20); do
        xdotool search --name 'LOADERS READY' >/dev/null 2>&1 || return 0
        sleep 1
    done
    report "note: a LOADERS window outlived its launch; the next reading may be the old one"
    return 1
}

kill_tree() {
    local pid="$1" child
    [ -n "$pid" ] || return 0
    for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
    kill "$pid" 2>/dev/null
    return 0
}

# One lane per question, so a file planted for one cannot be read by the next.
# The app is copied rather than launched where it was built: app_dir is derived
# from the script's own directory, so the directory *is* the fixture.
lane() {
    local name="$1"
    local dir="$WORK/$name"
    mkdir -p "$dir" || return 1
    cp "$APP" "$dir/app.cmd"
    printf '%s\n' "$dir"
}

LAST_LOG=""
LAST_WINDOW=""
LAST_ARGV=""
run_app() {
    local dir="$1"
    local log="$WORK/log-$RANDOM.txt"
    local pid engine i
    app_down
    ( exec bash "$dir/app.cmd" ) >"$log" 2>&1 &
    pid=$!
    # The command line is read as soon as there is an engine to read it from,
    # and not after the window: a launch that ends early still has to say what
    # it was handed, and after the kill there is nothing left to ask.
    LAST_ARGV=""
    for i in $(seq 1 150); do
        engine="$(engine_pid "$pid")" || engine=""
        if [ -n "$engine" ] && [ -r "/proc/$engine/cmdline" ]; then
            LAST_ARGV="$(tr '\0' ' ' < "/proc/$engine/cmdline")"
            break
        fi
        sleep 0.2
    done
    if app_up "$UP_WAIT"; then LAST_WINDOW=UP; else LAST_WINDOW=DOWN; fi
    sleep 1
    kill_tree "$pid"
    wait "$pid" 2>/dev/null
    LAST_LOG="$(cat "$log" 2>/dev/null)"
    rm -f "$log"
    return 0
}

marked() { grep -qa -- "$1" <<<"$LAST_LOG" && echo YES || echo NO; }

# =====================================================================
# The payloads, and the proof that they are live
# =====================================================================
#
# A whole program rather than a marker glued to something: this is what an
# attacker leaves behind, and it has to look like a normal launch from outside,
# title and all. The marker is assembled at run time so the token never appears
# in the text a parser could quote back.
write_planted_qml() {
    cat > "$1" <<'PLANTED'
import QtQuick
Window {
    visible: true
    width: 480
    height: 320
    title: "LOADERS READY"
    Component.onCompleted: console.warn("__APPDIR_PLAN" + "TED_QML__")
}
PLANTED
}

write_planted_js() {
    cat > "$1" <<'PLANTED'
.pragma library
console.warn("__APPDIR_PLAN" + "TED_JS__")
PLANTED
}

echo "=== appdir: the Qt document has no name ==="
report "lane qml=${QML_RUNNER:-none} gjs=$HAVE_GJS display=${DISPLAY:-none}"
[ -z "$QML_RUNNER" ] && fail "no qml runtime on this lane; nothing below is a reading"
[ "$HAVE_GJS" = yes ] &&
    report "note: gjs is present, so the launcher takes the gjs branch and run_qt never runs"

# The planted document, run by the engine directly. If this does not announce
# itself the payload is dead and every refusal below means nothing.
if [ -n "$QML_RUNNER" ]; then
    app_down
    write_planted_qml "$WORK/live.qml"
    ( "$QML_RUNNER" "$WORK/live.qml" ) >"$WORK/live.log" 2>&1 &
    LIVE_PID=$!
    LIVE=DOWN; app_up 15 && LIVE=UP
    sleep 1
    kill_tree "$LIVE_PID"; wait "$LIVE_PID" 2>/dev/null
    LIVE_RAN=NO
    grep -qa __APPDIR_PLANTED_QML__ "$WORK/live.log" && LIVE_RAN=YES
    report "control payload live=$LIVE_RAN window=$LIVE"
    [ "$LIVE_RAN" = YES ] ||
        fail "control expected=the planted document announces itself when the engine runs it actual=silent; every refusal below is unmeasured"
fi

# =====================================================================
# nodoc: nothing to plant, and the engine says so itself
# =====================================================================
CTL="$(lane control)"
run_app "$CTL"
CTL_FILES="$(ls -1a "$CTL/app" 2>/dev/null | grep -v '^\.\{1,2\}$' | tr '\n' ',' | sed 's/,$//')"
report "nodoc window=$LAST_WINDOW left=${CTL_FILES:-none} argv=$(sed -e 's/ *$//' -e 's/.* //' <<<"$LAST_ARGV")"
if [ "$LAST_WINDOW" != UP ]; then
    fail "the shipped build did not come up; every reading below is unmeasured"
    report "nodoc tail: $(tail -c 400 <<<"$LAST_LOG" | tr '\n' ' ')"
fi
[ -z "$CTL_FILES" ] ||
    fail "nodoc expected=app_dir empty after a launch actual=$CTL_FILES"
case "$LAST_ARGV" in
    "") fail "nodoc expected=an engine to read a command line from actual=none was ever seen" ;;
    */fd/[0-9]*) ;;
    *) fail "nodoc expected=the engine's argument names a descriptor actual=$LAST_ARGV" ;;
esac

# =====================================================================
# plant: a document left where the launcher used to look
# =====================================================================
L="$(lane plant)"
mkdir -p "$L/app"
write_planted_qml "$L/app/window.qml"
write_planted_js "$L/app/neutrino.js"
chmod 0444 "$L/app/window.qml" "$L/app/neutrino.js"
BEFORE="$(cat "$L/app/window.qml" "$L/app/neutrino.js" | cksum)"
run_app "$L"
AFTER="$(cat "$L/app/window.qml" "$L/app/neutrino.js" 2>/dev/null | cksum)"
QML_RAN="$(marked __APPDIR_PLANTED_QML__)"
JS_RAN="$(marked __APPDIR_PLANTED_JS__)"
report "plant qml_ran=$QML_RAN js_ran=$JS_RAN window=$LAST_WINDOW untouched=$([ "$BEFORE" = "$AFTER" ] && echo YES || echo NO)"
[ "$QML_RAN" = NO ] || fail "plant expected=the planted window.qml is not read actual=it ran"
[ "$JS_RAN" = NO ] || fail "plant expected=the planted neutrino.js is not read actual=it ran"
[ "$LAST_WINDOW" = UP ] || fail "plant expected=the app comes up beside a planted document actual=DOWN"
chmod u+w "$L/app/window.qml" "$L/app/neutrino.js" 2>/dev/null

# =====================================================================
# race: rewritten throughout the launch
# =====================================================================
#
# Renamed into place rather than written through, because a reader that catches
# a half-written file reports a syntax error and not a poisoning -- an attacker
# would use rename too. The loop runs for the whole launch and rewrites every
# name the old code used as well as anything else that turns up, so this is not
# a question of timing.
L="$(lane race)"
mkdir -p "$L/app"
write_planted_qml "$WORK/race-qml.qml"
write_planted_js "$WORK/race-js.js"
(
    end=$((SECONDS + 40))
    while [ $SECONDS -lt $end ]; do
        cp "$WORK/race-qml.qml" "$L/app/.r1" 2>/dev/null &&
            mv -f "$L/app/.r1" "$L/app/window.qml" 2>/dev/null
        cp "$WORK/race-js.js" "$L/app/.r2" 2>/dev/null &&
            mv -f "$L/app/.r2" "$L/app/neutrino.js" 2>/dev/null
        for f in "$L/app"/.window.*; do
            [ -f "$f" ] || continue
            cp "$WORK/race-qml.qml" "$L/app/.r3" 2>/dev/null &&
                mv -f "$L/app/.r3" "$f" 2>/dev/null
        done
    done
) &
RACER=$!
run_app "$L"
kill "$RACER" 2>/dev/null; wait "$RACER" 2>/dev/null
RACE_QML="$(marked __APPDIR_PLANTED_QML__)"
RACE_JS="$(marked __APPDIR_PLANTED_JS__)"
report "race qml_ran=$RACE_QML js_ran=$RACE_JS window=$LAST_WINDOW"
{ [ "$RACE_QML" = NO ] && [ "$RACE_JS" = NO ]; } ||
    fail "race expected=a rewritten document is not read actual=qml=$RACE_QML js=$RACE_JS"
[ "$LAST_WINDOW" = UP ] || fail "race expected=the app comes up under a rewriter actual=DOWN"

# =====================================================================
# inject: the path is a string and not program text
# =====================================================================
#
# The generated line was `xhr.open("GET", "file://$script_path", false)` inside
# an unquoted here-document, and a directory name closing that string ended the
# call and started a statement -- no slash needed, so it is a name a filesystem
# accepts. Standalone, the directory an app is unpacked into is not this
# program's to choose. nt_qmlquote is what makes it a string; the app coming up
# here is what says the quoting did not simply break the document instead.
INJ_DIR="$WORK/A\");console.warn(\"__APPDIR_INJ\"+\"ECTED__"
if mkdir -p "$INJ_DIR" 2>/dev/null; then
    cp "$APP" "$INJ_DIR/app.cmd"
    run_app "$INJ_DIR"
    INJ_RAN="$(marked __APPDIR_INJECTED__)"
    report "inject ran=$INJ_RAN window=$LAST_WINDOW"
    [ "$INJ_RAN" = NO ] || fail "inject expected=the path is a string actual=the statement in it ran"
    [ "$LAST_WINDOW" = UP ] ||
        fail "inject expected=the app comes up from a directory with a quote in its name actual=DOWN"
else
    report "inject: this filesystem would not take the directory name; unmeasured"
fi

app_down
echo "=== appdir: $FAILURES failure(s) ==="
[ "$FAILURES" -eq 0 ] || exit 1
exit 0
