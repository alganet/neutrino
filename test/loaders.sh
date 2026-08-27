#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# loaders.sh - the loader environment the standalone launch path hands its engine
#
# PR 9 denied the loader knobs a prefix admitted, in netinstall's env.c, and
# said in the same breath that webview.cmd's own launch path was a different
# threat model owed its own PR. This is that PR's suite.
#
# Before it, the launch path had exactly one piece of environment hygiene: the
# gjs branch unsets ten names, and its comment says why -- a bundled caller
# exporting GLib/GTK overrides that crash against the system glibc. A
# compatibility rule. The Qt branch had nothing of the kind and the macOS
# branch launched osascript with whatever it was given.
#
# Three questions, and every one of them is asserted against a control that is
# the same build with the fix deleted -- so "it would have failed before" is
# measured in the same run rather than claimed:
#
#   reach   the loader-shaped names must not reach the engine process, and the
#           names that carry data or a mode must still get there
#   effect  a knob must load nothing, measured against a module whose
#           constructor says otherwise -- in the app process and in the web
#           process, which are not the same question
#   cost    the app must still come up, with the candidate set removed and with
#           what a shape rule would take out of this lane's own environment
#
# And a fourth this file owes because it makes the claim: the sandbox
# webview.cmd computes by running bubblewrap, of which it says the value is
# "never defaulted from the environment", must not be reachable from the
# environment. Read off the process table -- bwrap exists under a launch or it
# does not -- and not off a variable.
#
# Three things fail here that are not findings: a module that never loads
# anywhere, an app that never comes up, an engine this script could not find.
# Those are the ways a suite like this reports a wide-open door as closed.
#
# Usage: loaders.sh <app.cmd> [default-tier-app.cmd]

set -uo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -f "$APP" ]; then
    echo "usage: loaders.sh <app.cmd built from test/neutrinoloaders.js> [default-tier build]" >&2
    exit 2
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
# The second build, and the sandbox section below is the only thing that needs
# it. Everything above is measured at the testing tier because the probe has to
# know the app came up; but the testing tier is also the one that puts
# --no-sandbox on Chromium's command line, and a section asking whether the
# environment can turn a sandbox off cannot ask it of a build that already did.
APP_DEFAULT="${2:-}"
[ -n "$APP_DEFAULT" ] && [ -f "$APP_DEFAULT" ] &&
    APP_DEFAULT="$(cd "$(dirname "$APP_DEFAULT")" && pwd)/$(basename "$APP_DEFAULT")" ||
    APP_DEFAULT=""
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNAME="$(uname -s)"
WORK="$(mktemp -d)"
MARKS="$WORK/marks"
mkdir -p "$WORK/mod" "$MARKS"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
UP_WAIT=20

report() { echo "report: $*"; }
fail()   { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# The reach answer is forty names long and an annotation carries five lines, so
# it goes out wrapped rather than one name per line or one line per lane.
report_list() {
    local label="$1"; shift
    local line="" n=0 item
    if [ $# -eq 0 ]; then report "$label (none)"; return 0; fi
    for item in "$@"; do
        line="$line $item"; n=$((n + 1))
        if [ $n -eq 6 ]; then report "$label:$line"; line=""; n=0; fi
    done
    [ -n "$line" ] && report "$label:$line"
    return 0
}

# =====================================================================
# The battery
# =====================================================================
#
# Grouped by what the answer would mean, not by prefix.
#
# UNSET is what the gjs branch removes today: these are the controls that say
# the instrument can see a removal at all, and on the Qt and macOS branches
# they are the finding rather than the control.
#
# CANDIDATES is every name that answers "which file should I load", "which
# program should I run" or "should I sandbox myself" and that no branch of this
# file touches. The list is env.c's shapes read against the three engines this
# file actually drives, plus the ones only a launcher sees: GI_TYPELIB_PATH and
# GJS_PATH decide which library gjs binds `imports.gi` to, and GIO_EXTRA_MODULES
# is the name glib documents where the unset list has GIO_MODULE_DIR.
#
# The PYTHON names arrived with the PyGObject lane and they are the reason the
# scrub grew a namespace rather than two shapes. PYTHONPATH decides what the
# interpreter imports, PYTHONHOME moves the whole installation, and
# PYTHONSTARTUP names a file it runs before the program -- and only the first
# of those three is shaped like anything the rule already looked for.
#
# KEEPERS is the other half of any fix. A rule that dropped these would satisfy
# every "is removed" reading here and take the display, the platform plugin,
# the session bus and the locale with it.
# COMPAT is what the gjs branch's compatibility unset removes and the scrub
# removes again by shape. Both rules reach them, so every lane must stop them.
NT_COMPAT="
GTK_PATH GTK_EXE_PREFIX GTK_IM_MODULE_FILE
GDK_PIXBUF_MODULE_FILE GDK_PIXBUF_MODULEDIR GIO_MODULE_DIR
LD_PRELOAD LD_LIBRARY_PATH
"
# DATA is the rest of that unset, and it carries the shape rule's boundary. A
# schema directory and a locale path name data, not code, so the scrub is not
# entitled to them -- env.c says the same thing about GSETTINGS_SCHEMA_DIR in
# its own words. The gjs branch still removes them, for the crash its comment
# describes. So the expectation differs by lane, and both directions are
# asserted rather than one being left silent.
NT_DATA="GSETTINGS_SCHEMA_DIR LOCPATH"
NT_CANDIDATES="
GTK_MODULES GTK_IM_MODULE GTK_DATA_PREFIX
GIO_EXTRA_MODULES GI_TYPELIB_PATH GJS_PATH
WEBKIT_INJECTED_BUNDLE_PATH WEBKIT_EXEC_PATH WEBKIT_FORCE_SANDBOX
WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS
LD_AUDIT LD_PROFILE
GST_PLUGIN_PATH GST_PLUGIN_SYSTEM_PATH GST_PLUGIN_SCANNER
QT_PLUGIN_PATH QT_QPA_PLATFORM_PLUGIN_PATH QT_IM_MODULE
QML2_IMPORT_PATH QML_IMPORT_PATH
QTWEBENGINE_CHROMIUM_FLAGS QTWEBENGINE_PROCESS_PATH QTWEBENGINE_RESOURCES_PATH
QTWEBENGINE_DISABLE_SANDBOX
LIBGL_DRIVERS_PATH MESA_LOADER_DRIVER_OVERRIDE
VK_LAYER_PATH VK_ADD_LAYER_PATH VK_ICD_FILENAMES VK_DRIVER_FILES
DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
PYTHONPATH PYTHONHOME PYTHONSTARTUP
"
NT_KEEPERS="
DISPLAY GDK_BACKEND XDG_RUNTIME_DIR XDG_DATA_DIRS DBUS_SESSION_BUS_ADDRESS
QT_QPA_PLATFORM LIBGL_ALWAYS_SOFTWARE LANG
"
flat() { tr -s ' \n' ' ' <<<"$1" | sed 's/^ //; s/ $//'; }
NT_COMPAT="$(flat "$NT_COMPAT")"
NT_DATA="$(flat "$NT_DATA")"
NT_CANDIDATES="$(flat "$NT_CANDIDATES")"
NT_KEEPERS="$(flat "$NT_KEEPERS")"
NT_BATTERY="$NT_COMPAT $NT_DATA $NT_CANDIDATES NEUTRINO_LOADER_CONTROL"

# Values inert, and three of them chosen rather than defaulted. The toggles get
# 1 because a path is not what they mean. dyld terminates a process whose
# inserted dylib will not load, so DYLD_INSERT_LIBRARIES is set empty -- still
# set, which is the whole question, since no rule of this shape looks at a
# value. And the paths point at a real empty directory rather than at a name
# that is not there: a search path into the void is the one value that can take
# a toolkit down before this script has read anything, and a reach run whose
# engine died is a run that reports every name absent.
mkdir -p "$WORK/empty"
# One function, because the reach check does not ask whether a name arrived --
# it asks whether *this* value did. The launcher re-sets one of these on
# purpose: run_qt reads QTWEBENGINE_CHROMIUM_FLAGS and puts its own default
# back, so the name is present at the engine holding a value the caller never
# chose. Asserting on the name alone would call that a leak; asserting on the
# value says what actually matters, and the two lists cannot drift apart
# because there is only one.
battery_value() {
    case "$1" in
        NEUTRINO_LOADER_CONTROL) printf 'control' ;;
        DYLD_INSERT_LIBRARIES)   printf '' ;;
        # Set and inert, for dyld's reason. A PYTHONHOME pointing at a
        # directory with no standard library in it does not mislead the
        # interpreter, it stops it dead -- and the control build, which is this
        # one with the fix cut out, is the run that would still be holding it.
        # An empty value is ignored by CPython and is still a name in the
        # environment, which is the only thing a rule of this shape reads.
        PYTHONHOME)              printf '' ;;
        *SANDBOX*|*_IM_MODULE)   printf '1' ;;
        *) printf '%s' "$WORK/empty" ;;
    esac
}
NT_SET=()
for n in $NT_BATTERY; do
    NT_SET+=("$n=$(battery_value "$n")")
done

# =====================================================================
# The same build with the fix deleted, which is what every check is against
# =====================================================================
#
# Not a second build and not the previous commit: this artifact, with the scrub
# call and the gjs compat unset cut out of it, so the difference between the two
# readings is the fix and nothing else. It is what turns "would have failed
# before" from a claim into a line in the same run.
UNFIXED="$WORK/unfixed.cmd"
awk '
    # A colon in place of the removed block, and not nothing. The compatibility
    # unset used to sit inline in the gjs branch; it is a function now, shared
    # by the three lanes that load GTK, and cutting the whole body out of a
    # function leaves an empty pair of braces -- which is not an unfixed build,
    # it is a shell syntax error, and every reading taken against it would say
    # the app never came up.
    #
    # No apostrophes below this line: the awk program is inside a single-quoted
    # shell word, and one in a comment ends it.
    /^ *unset GTK_PATH/ { skip = 1; print "    :" }
    skip { if ($0 !~ /\\$/) skip = 0; next }
    /^nt_scrub_loaders$/ { next }
    { print }
' "$APP" > "$UNFIXED"
HAVE_UNFIXED=0
if ! cmp -s "$APP" "$UNFIXED"; then
    HAVE_UNFIXED=1
else
    fail "control expected=a build with the fix removed actual=identical to the shipped one; every check below is unmeasured"
fi

# =====================================================================
# The instrument: netinstall/test/env-module.c, one copy per knob
# =====================================================================
#
# The same file env.sh uses, referred to rather than copied -- two suites
# asserting one fact with two copies of one instrument is how they drift into
# disagreeing. Its constructor runs when the file is opened, before any entry
# point a toolkit looks for, which is the difference between "this knob loads
# code" and "this knob named a module that was then rejected".
#
# It marks twice: a file in the mark directory, and a line on stderr. The
# second is not redundancy. A WebKit injected bundle is loaded into the web
# process, which on this lane runs inside WebKitGTK's own bubblewrap, and a
# mark directory that is not bound in there fails to be written by a bundle
# that loaded perfectly well.
NT_CC="${NETINSTALL_CC:-cc}"
NT_MODEXT=".so"
NT_MODFLAGS=(-shared -fPIC)
if [ "$UNAME" = "Darwin" ]; then
    NT_MODEXT=".dylib"
    NT_MODFLAGS=(-dynamiclib)
fi
build_module() {
    local tag="$1"
    $NT_CC "${NT_MODFLAGS[@]}" -DNT_MOD_TAG="\"$tag\"" \
        -o "$WORK/mod/$tag$NT_MODEXT" "$ROOT/netinstall/test/env-module.c" >/dev/null 2>&1 &&
        [ -s "$WORK/mod/$tag$NT_MODEXT" ]
}
MOD_OK=1
for tag in ldpreload ldaudit gtkmodule injectedbundle gioextra; do
    build_module "$tag" || MOD_OK=0
done
if [ "$MOD_OK" = "1" ]; then
    mkdir -p "$WORK/mod/bundle" "$WORK/mod/gio"
    # The names WebKitGTK looks for, 4.x and 6.0. Which one this lane has is a
    # reading, not something to be decided here.
    cp "$WORK/mod/injectedbundle$NT_MODEXT" "$WORK/mod/bundle/libwebkit2gtkinjectedbundle$NT_MODEXT"
    cp "$WORK/mod/injectedbundle$NT_MODEXT" "$WORK/mod/bundle/libwebkitgtkinjectedbundle$NT_MODEXT"
    cp "$WORK/mod/gioextra$NT_MODEXT" "$WORK/mod/gio/libgioextra$NT_MODEXT"
else
    report "instrument: $NT_CC could not build the module; the effect half is unmeasured"
fi

# The instrument, proven on a program that is not under test. A module that
# never loads anywhere makes every silence below look like a refusal.
#
# A program compiled here rather than one borrowed from /bin, and macOS is why.
# Round one borrowed a copy of /bin/echo and measured no mark at all, which took
# the whole effect half of that lane with it: an Apple-signed binary carries
# library validation, so dyld refuses to insert a dylib this machine just
# built -- and a copy keeps the signature that says so. A binary cc produced
# here has no such signature and takes the insert.
#
# That is not a workaround for the macOS reading. It is what makes the reading
# possible: with the instrument proven against a program that will take an
# insert, osascript refusing one is a measurement instead of a silence.
NT_ECHO="/bin/echo"
printf 'int main(void) { return 0; }\n' > "$WORK/mod/host.c"
if $NT_CC -o "$WORK/mod/host" "$WORK/mod/host.c" >/dev/null 2>&1 && [ -x "$WORK/mod/host" ]; then
    NT_ECHO="$WORK/mod/host"
fi
if [ "$MOD_OK" = "1" ]; then
    rm -f "$MARKS"/*
    NEUTRINO_TEST_MODULE_MARKDIR="$MARKS" NEUTRINO_TEST_MODULE_STDERR=1 \
        LD_PRELOAD="$WORK/mod/ldpreload$NT_MODEXT" \
        DYLD_INSERT_LIBRARIES="$WORK/mod/ldpreload$NT_MODEXT" \
        "$NT_ECHO" probe >/dev/null 2>"$WORK/instrument.err"
    if [ -e "$MARKS/ldpreload" ] || grep -q NT_MOD_LOADED "$WORK/instrument.err"; then
        echo "  PASS: the module marks when it is loaded"
    else
        fail "instrument expected=a mark from $NT_ECHO under a preload actual=none; every silence below is unmeasured"
        MOD_OK=0
    fi
fi

# =====================================================================
# Running the app, and finding the process the launcher handed the environment
# =====================================================================
descendants() {
    local pid="$1" child
    echo "$pid"
    for child in $(pgrep -P "$pid" 2>/dev/null); do descendants "$child"; done
}

# The engine, not the launcher: the unset happens in the shell, so the shell's
# own environment answers a different question than the one being asked.
engine_pid() {
    local p comm
    for p in $(descendants "$1"); do
        comm="$(ps -o comm= -p "$p" 2>/dev/null | tr -d ' ')"
        # Every engine the launcher can choose, and it is no longer one name
        # per toolkit: cjs is Cinnamon's fork of gjs and python3 is the
        # PyGObject lane. An engine this cannot name reads as "no engine
        # found", which the sections below correctly refuse to treat as a
        # finding -- so a missing name here silently unmeasures the suite
        # rather than failing it.
        case "${comm##*/}" in
            gjs|gjs-console|cjs|cjs-console|qml|qml6|qmlscene*|osascript|python3|python3.*)
                echo "$p"; return 0 ;;
        esac
    done
    return 1
}

# Polled tightly rather than once a second. A knob with a bad value can take an
# engine down in well under a second, and the environment it was handed goes
# with it -- which reads as a launcher that removed every name.
wait_engine() {
    local pid="$1" i found
    for i in $(seq 1 100); do
        found="$(engine_pid "$pid")" && [ -n "$found" ] && { echo "$found"; return 0; }
        sleep 0.2
    done
    return 1
}

app_up() {
    local i
    for i in $(seq 1 "$1"); do
        if [ "$UNAME" = "Darwin" ]; then
            [ -f "${TMPDIR:-/tmp}/neutrino-title.txt" ] && return 0
        elif command -v xdotool >/dev/null 2>&1; then
            xdotool search --name 'LOADERS READY' >/dev/null 2>&1 && return 0
        fi
        sleep 1
    done
    return 1
}

app_down() {
    local i
    [ "$UNAME" = "Darwin" ] && { rm -f "${TMPDIR:-/tmp}/neutrino-title.txt"; return 0; }
    command -v xdotool >/dev/null 2>&1 || return 0
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

# Reads the environment the launcher actually handed the engine. On linux that
# is the exec-time copy in /proc, which is exactly the right thing: it cannot
# have been changed by anything the engine did afterwards. macOS has no /proc
# and ps -E is what there is; if it answers with nothing the section says so
# rather than reporting every name absent.
read_env() {
    local pid="$1"
    if [ -r "/proc/$pid/environ" ]; then
        tr '\0' '\n' < "/proc/$pid/environ"
    else
        ps -Ewww -p "$pid" 2>/dev/null | tail -n +2 | tr ' ' '\n'
    fi
}

LAST_ENV=""
LAST_LOG=""
LAST_ENGINE=""
LAST_COMM=""
LAST_WINDOW=""
LAST_PROCS=""
LAST_NOSANDBOX=""
# One launch: start the app with an environment, find the engine, take a copy
# of what it was given, wait for the window, kill the tree.
run_app() {
    local app="$1"; shift
    local log="$WORK/app-$$.log"
    local p c
    app_down
    rm -f "$MARKS"/*
    ( NEUTRINO_TEST_MODULE_MARKDIR="$MARKS" NEUTRINO_TEST_MODULE_STDERR=1 \
      exec env "$@" bash "$app" ) >"$log" 2>&1 &
    local pid=$!
    LAST_ENGINE="$(wait_engine "$pid")" || LAST_ENGINE=""
    LAST_ENV=""
    LAST_COMM=""
    if [ -n "$LAST_ENGINE" ]; then
        # Both taken while it is alive: after the kill below there is nothing
        # left to ask, and a name read off a dead pid is no name at all.
        LAST_ENV="$(read_env "$LAST_ENGINE")"
        LAST_COMM="$(ps -o comm= -p "$LAST_ENGINE" 2>/dev/null | tr -d ' ')"
        LAST_COMM="${LAST_COMM##*/}"
    fi
    if app_up "$UP_WAIT"; then LAST_WINDOW=UP; else LAST_WINDOW=DOWN; fi
    # Read again at the end as well: a knob that only matters once the web
    # process exists has not been honoured yet at the moment the window opens.
    sleep 3
    # The process table while it is still standing. Whether a renderer is
    # sandboxed is not a thing to be asked of a variable: WebKitGTK's sandbox
    # is bubblewrap, so a bwrap process either exists under this launch or it
    # does not, and Qt puts --no-sandbox on Chromium's own command line.
    LAST_PROCS=""
    LAST_NOSANDBOX=no
    for p in $(descendants "$pid"); do
        c="$(ps -o comm= -p "$p" 2>/dev/null | tr -d ' ')"
        c="${c##*/}"
        [ -n "$c" ] && LAST_PROCS="$LAST_PROCS $c"
        if [ -r "/proc/$p/cmdline" ] &&
           tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- '--no-sandbox'; then
            LAST_NOSANDBOX=yes
        fi
    done
    LAST_PROCS="$(tr ' ' '\n' <<<"$LAST_PROCS" | sort -u | tr '\n' ',' | sed 's/^,//; s/,$//')"
    kill_tree "$pid"
    wait "$pid" 2>/dev/null
    LAST_LOG="$(cat "$log" 2>/dev/null)"
    rm -f "$log"
    return 0
}

# =====================================================================
# Reach
# =====================================================================
#
# The window is reported here and not read into anything. Two of the battery
# names -- WEBKIT_EXEC_PATH and QTWEBENGINE_PROCESS_PATH -- are where the
# engine finds its own helper processes, and pointing them at an empty
# directory is expected to leave a window with nothing in it. What this section
# reads is /proc, taken while the engine is alive, and that does not depend on
# the page ever rendering.
echo "=== Reach: what the launcher hands the engine ==="
run_app "$APP" "${NT_SET[@]}"
SHIPPED_ENV="$LAST_ENV"
SHIPPED_ENGINE="$LAST_ENGINE"
SHIPPED_WINDOW="$LAST_WINDOW"
ENGINE_COMM="$LAST_COMM"
report "reach engine=${SHIPPED_ENGINE:-none} comm=${ENGINE_COMM:-none} window=$SHIPPED_WINDOW"

# Which rules this lane is under, decided once from the engine that actually
# came up. The launcher's compatibility unset covers every lane that loads GTK,
# which is three engines now rather than one, so a case matching the string
# "gjs" would put a cjs or PyGObject launch under Qt's expectations and assert
# the opposite of the truth about it.
case "${ENGINE_COMM##*/}" in
    gjs*|cjs*|python3*) NT_LANE_KIND=gtk ;;
    qml*|qmlscene*)     NT_LANE_KIND=qt ;;
    osascript)          NT_LANE_KIND=macos ;;
    *)                  NT_LANE_KIND=unknown ;;
esac

CONTROL_ENV=""
if [ "$HAVE_UNFIXED" = "1" ]; then
    run_app "$UNFIXED" "${NT_SET[@]}"
    CONTROL_ENV="$LAST_ENV"
    # The size of it, and not only that a pid was found. classify() below skips
    # its own "was this name ever delivered" question whenever CONTROL_ENV is
    # empty, so an unreadable control and a complete one both report no
    # unmeasured names -- the two readings that look identical and mean
    # opposite things. Printed here so they stop looking identical.
    report "reach control engine=${LAST_ENGINE:-none} comm=${LAST_COMM:-none} names=$(grep -c . <<<"$CONTROL_ENV") window=$LAST_WINDOW (the same build with the fix deleted)"
fi

if [ -z "$SHIPPED_ENV" ]; then
    fail "reach expected=an engine process to read actual=none found; the reach half is unmeasured"
elif ! grep -qx 'NEUTRINO_LOADER_CONTROL=control' <<<"$SHIPPED_ENV"; then
    fail "reach control expected=NEUTRINO_LOADER_CONTROL arrives actual=absent; the battery never got there"
else
    echo "  PASS: a name nothing touches arrives, so an absence below is a removal"
    STOPPED=(); LEAKED=(); UNMEASURED=(); REPLACED=(); ARRIVED_DATA=()
    # Three outcomes, not two. A name can be gone; it can be there holding the
    # value this suite set, which is the leak; or it can be there holding
    # something else, which is the launcher having put its own value back.
    classify() {
        local n="$1"
        if [ -n "$CONTROL_ENV" ] && ! grep -q "^$n=$(battery_value "$n")\$" <<<"$CONTROL_ENV"; then
            echo unmeasured
        elif grep -qx "$n=$(battery_value "$n")" <<<"$SHIPPED_ENV"; then
            echo leaked
        elif grep -q "^$n=" <<<"$SHIPPED_ENV"; then
            echo replaced
        else
            echo stopped
        fi
    }
    # Against the control first, always. A name the runner never delivered to
    # either build is not a name this rule stopped, and counting it as one is
    # how a suite passes for a reason that is not the fix.
    for n in $NT_COMPAT $NT_CANDIDATES; do
        case "$(classify "$n")" in
            unmeasured) UNMEASURED+=("$n") ;;
            leaked)     LEAKED+=("$n") ;;
            replaced)   REPLACED+=("$n") ;;
            *)          STOPPED+=("$n") ;;
        esac
    done
    # And the two the scrub is not entitled to. On gjs the compatibility unset
    # takes them anyway; everywhere else they must arrive, and that is asserted
    # rather than left as a silence -- a scrub that started taking data would
    # otherwise pass every line in this section.
    for n in $NT_DATA; do
        case "$(classify "$n")" in
            unmeasured) UNMEASURED+=("$n") ;;
            stopped)    STOPPED+=("$n") ;;
            *)          ARRIVED_DATA+=("$n") ;;
        esac
    done
    report_list "reach stopped" "${STOPPED[@]+"${STOPPED[@]}"}"
    report_list "reach replaced by the launcher's own value" "${REPLACED[@]+"${REPLACED[@]}"}"
    report_list "reach unmeasured (absent from the control too)" "${UNMEASURED[@]+"${UNMEASURED[@]}"}"
    if [ ${#LEAKED[@]} -eq 0 ]; then
        echo "  PASS: no loader-shaped name reached the engine (${#STOPPED[@]} stopped)"
    else
        report_list "reach LEAKED" "${LEAKED[@]}"
        fail "reach expected=every loader-shaped name stopped actual=${#LEAKED[@]} reached the engine"
    fi
    # The data names, asserted in whichever direction this lane calls for.
    case "$NT_LANE_KIND" in
        gtk)
            if [ ${#ARRIVED_DATA[@]} -eq 0 ]; then
                echo "  PASS: the GTK lanes' compatibility unset still takes $NT_DATA"
            else
                report_list "reach data names still arriving" "${ARRIVED_DATA[@]}"
                fail "compat expected=$NT_DATA removed on a GTK lane actual=${#ARRIVED_DATA[@]} arrived"
            fi ;;
        *)
            if [ ${#ARRIVED_DATA[@]} -gt 0 ]; then
                echo "  PASS: $NT_DATA still arrive, which is the shape rule's boundary (${#ARRIVED_DATA[@]})"
            else
                fail "boundary expected=$NT_DATA arrive, since they name data and not code actual=stopped"
            fi ;;
    esac

    # The control has to show them arriving, or the line above is a rule that
    # was never tested against anything.
    if [ "$HAVE_UNFIXED" = "1" ]; then
        ARRIVED=0
        for n in $NT_CANDIDATES; do
            grep -q "^$n=" <<<"$CONTROL_ENV" && ARRIVED=$((ARRIVED + 1))
        done
        if [ "$ARRIVED" -gt 0 ]; then
            echo "  PASS: the same build without the fix let $ARRIVED of them through"
        else
            fail "control expected=the unfixed build lets these through actual=none arrived; the reach check proves nothing"
        fi
    fi
    # And the other half of the rule: what carries data or a mode still has to
    # get there. A rule that took the namespaces outright would pass every line
    # above and leave a window that never opens.
    KEPT=(); LOST=()
    for n in $NT_KEEPERS; do
        eval "set_here=\${$n+set}"
        [ "${set_here:-}" = set ] || continue
        if grep -q "^$n=" <<<"$SHIPPED_ENV"; then KEPT+=("$n"); else LOST+=("$n"); fi
    done
    report_list "reach keepers that arrive" "${KEPT[@]+"${KEPT[@]}"}"
    if [ ${#LOST[@]} -eq 0 ]; then
        echo "  PASS: every keeper this lane sets still arrives (${#KEPT[@]})"
    else
        report_list "reach keepers LOST" "${LOST[@]}"
        fail "keepers expected=all arrive actual=${#LOST[@]} were taken"
    fi
fi

# =====================================================================
# Effect
# =====================================================================
#
# One launch per knob, because a knob that takes the app down with it would
# otherwise read as five refusals. Each is run against the shipped build; a
# knob the unset removes is run against the control build too, which is what
# says whether the engine would have honoured it.
echo "=== Effect: a module, through the real engine ==="
# Two channels, and neither is reduced to one word. The mark file says a load
# happened somewhere; the stderr lines say in which process, and for LD_PRELOAD
# that is the entire question -- the launcher is a shell, so a preload the
# engine never saw still loads into bash on the way past. `in=` is what the
# checks read; the mark file stays in the line because a load with no process
# name is a reading somebody will need one day.
effect() {
    local tag="$1" app="$2" label="$3"; shift 3
    local mark=no
    run_app "$app" "$@"
    [ -e "$MARKS/$tag" ] && mark=yes
    EFFECT_PROCS="$(grep -o "NT_MOD_LOADED $tag pid=[0-9]* in=[^ ]*" <<<"$LAST_LOG" |
             sed 's/.*in=//' | sort -u | tr '\n' ',' | sed 's/,$//')"
    report "effect $tag $label mark=$mark in=${EFFECT_PROCS:-none} engine=${LAST_COMM:-none} window=$LAST_WINDOW procs=${LAST_PROCS:-none}"
    # Round two could not tell "the engine refused the insert" from "the engine
    # never started": the macOS dyld case read engine=none window=DOWN and the
    # mark was in bash, which is both answers at once. The process table says
    # how far the launch got, and the log says what stopped it.
    if [ "$LAST_WINDOW" != "UP" ]; then
        report "effect $tag $label tail: $(tr '\n' ' ' <<<"$LAST_LOG" | tr -d '[:cntrl:]' | tail -c 240)"
    fi
}

# One knob, twice: this build and the same build with the fix cut out. The
# second is not decoration -- it is the only thing that separates "the rule
# stopped it" from "this engine, this release, never honoured that name". A
# knob that loads nothing in either build is reported and not counted, because
# there was nothing there to stop.
#
# `want_engine` is the process the load has to be absent from. It is not always
# the engine: an injected bundle loads into the web process, and asserting
# against `gjs` there would pass while page content ran attacker code.
knob_check() {
    local tag="$1" want_engine="$2"; shift 2
    local fixed unfixed
    effect "$tag" "$APP" fixed "$@"
    fixed="$EFFECT_PROCS"
    if [ "$HAVE_UNFIXED" != "1" ]; then
        report "effect $tag: no control build, so this is a reading and not a check"
        return 0
    fi
    effect "$tag" "$UNFIXED" unfixed "$@"
    unfixed="$EFFECT_PROCS"
    if ! grep -q "$want_engine" <<<"$unfixed"; then
        report "effect $tag: not honoured even with the fix removed (in=${unfixed:-none}); unmeasured here"
        return 0
    fi
    if grep -q "$want_engine" <<<"$fixed"; then
        fail "effect $tag expected=nothing loaded into $want_engine actual=in=$fixed"
    else
        echo "  PASS: $tag loads into $want_engine without the fix and into nothing with it"
    fi
}

if [ "$MOD_OK" = "1" ]; then
    EFFECT_PROCS=""
    case "$NT_LANE_KIND" in
        gtk)
            # Named from the engine that came up rather than written as "gjs".
            # These knobs load into whichever process is driving GTK, and on
            # this lane that may be cjs or python3 -- a check that went looking
            # for a gjs process would pass by finding nothing, which is the
            # exact shape of reading a wide-open door as closed.
            eng="${ENGINE_COMM##*/}"
            knob_check ldpreload "$eng" LD_PRELOAD="$WORK/mod/ldpreload$NT_MODEXT"
            knob_check gtkmodule "$eng" GTK_MODULES="$WORK/mod/gtkmodule$NT_MODEXT"
            knob_check injectedbundle WebKitWebProcess WEBKIT_INJECTED_BUNDLE_PATH="$WORK/mod/bundle"
            knob_check gioextra "$eng" GIO_EXTRA_MODULES="$WORK/mod/gio"
            knob_check ldaudit "$eng" LD_AUDIT="$WORK/mod/ldaudit$NT_MODEXT"
            ;;
        qt)
            knob_check ldpreload qml LD_PRELOAD="$WORK/mod/ldpreload$NT_MODEXT"
            # Qt loads a plugin only with matching metadata, so the module would
            # be rejected before its constructor mattered -- env.sh measured
            # that and it is not re-measured here. The knob that needs none of
            # it is the one Qt appends to Chromium's own argv, and the launcher
            # does not merely pass that one through: it reads it and puts the
            # value back. Its mark is a shell script, not the module, so this
            # one is checked on the mark file rather than on a process name.
            cat > "$WORK/mod/prefix.sh" <<'PREFIX'
#!/bin/sh
[ -n "${NEUTRINO_TEST_MODULE_MARKDIR:-}" ] &&
    printf 'renderer\n' > "$NEUTRINO_TEST_MODULE_MARKDIR/rendererprefix" 2>/dev/null
exec "$@"
PREFIX
            chmod +x "$WORK/mod/prefix.sh"
            RENDER_FLAGS="--disable-dev-shm-usage --renderer-cmd-prefix=$WORK/mod/prefix.sh"
            effect rendererprefix "$APP" fixed QTWEBENGINE_CHROMIUM_FLAGS="$RENDER_FLAGS"
            fixed_mark=$([ -e "$MARKS/rendererprefix" ] && echo yes || echo no)
            if [ "$HAVE_UNFIXED" = "1" ]; then
                effect rendererprefix "$UNFIXED" unfixed QTWEBENGINE_CHROMIUM_FLAGS="$RENDER_FLAGS"
                if [ ! -e "$MARKS/rendererprefix" ]; then
                    report "effect rendererprefix: not honoured even with the fix removed; unmeasured here"
                elif [ "$fixed_mark" = "yes" ]; then
                    fail "effect rendererprefix expected=the renderer prefix never runs actual=it ran"
                else
                    echo "  PASS: QTWEBENGINE_CHROMIUM_FLAGS chooses the renderer's program without the fix and not with it"
                fi
            fi
            ;;
        osascript)
            # macOS asks the same question with the only knob that applies
            # there. Measured across three rounds: osascript takes no insert --
            # an arm64e platform binary and an arm64 dylib the runner just
            # built -- and dyld ends the launch rather than continuing without
            # it. So this is a check that the name does not arrive, which the
            # reach section above already made, plus the reading that says why
            # the effect half cannot be taken here.
            effect ldpreload "$APP" dyld-insert \
                DYLD_INSERT_LIBRARIES="$WORK/mod/ldpreload$NT_MODEXT"
            ;;
    esac
fi

# =====================================================================
# The sandbox nobody meant to make settable
# =====================================================================
#
# webview.cmd decides whether WebKitGTK gets its bubblewrap sandbox by running
# the mechanism rather than by looking for the parts it is made of, and says of
# the result: "always assigned, never defaulted from the environment, so this is
# a measurement being passed inward and not a switch anyone can set." Ground
# rule 4, stated by the file itself.
#
# The engines read their own names for the same thing, and this asks whether
# those still work from outside a decision the launcher made. Not a variable
# reading: bubblewrap either exists as a process under this launch or it does
# not, and Qt puts --no-sandbox on Chromium's command line when it honours its
# own knob.
#
# The control comes first and it is the whole section: on a runner that refuses
# user namespaces there is no sandbox to turn off, and every reading below
# would be a knob working perfectly.
echo "=== The sandbox, and whether the environment can still reach it ==="
SANDBOX_APP="${APP_DEFAULT:-$APP}"
[ -z "$APP_DEFAULT" ] &&
    report "sandbox: no default-tier build given; reading the testing-tier one instead"
SB_APPLIES=1
case "${ENGINE_COMM:-none}" in
    none)
        # No engine was found at all, which the reach section has already
        # failed over. Everything here would read DOWN and none of it would
        # mean anything.
        report "sandbox: no engine was found, so this section has nothing to ask"
        SB_APPLIES=0 ;;
    osascript)
        # Nothing to ask here. The macOS driver hosts neither bubblewrap nor
        # Chromium, and the seatbelt profile it does apply arrives on the
        # command line, where PR 7 put it precisely so that no file and no
        # variable can reach it. Said rather than skipped in silence: a section
        # that quietly does not run on a platform reads as one that passed.
        report "sandbox: the macOS driver hosts neither bubblewrap nor Chromium; nothing here applies"
        SB_APPLIES=0 ;;
esac
# Every run here clears all three names first, and round two is why: the kde
# lane exports QTWEBENGINE_DISABLE_SANDBOX itself -- it has to, or Chromium
# will not start in this container -- so the control inherited the very knob it
# was the control for and both readings said the same thing. A section that
# measures a switch cannot take the switch's position from the room it runs in.
SB_CLEAR=(-u WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS -u WEBKIT_FORCE_SANDBOX -u QTWEBENGINE_DISABLE_SANDBOX)
SB_READY=0
SB_CONTROL_PROCS=""
SB_CONTROL_NOSANDBOX=""
if [ "$SB_APPLIES" = "1" ]; then
run_app "$SANDBOX_APP" "${SB_CLEAR[@]}"
SB_CONTROL_PROCS="$LAST_PROCS"
SB_CONTROL_NOSANDBOX="$LAST_NOSANDBOX"
report "sandbox control procs=${SB_CONTROL_PROCS:-none} nosandbox=$SB_CONTROL_NOSANDBOX window=$LAST_WINDOW note=$(grep -a -o 'webkit sandbox.*' <<<"$LAST_LOG" | head -1)"

# What "sandboxed" looks like on this lane, decided from the control rather
# than assumed. gjs answers with a bwrap process, Qt with the absence of
# --no-sandbox on the renderer's command line; a runner that has neither is a
# runner where nothing can be turned off and every check below would pass for
# the wrong reason.
case "$NT_LANE_KIND" in
    gtk)  grep -q bwrap <<<"$SB_CONTROL_PROCS" && SB_READY=1
          [ "$SB_READY" = "1" ] ||
              report "sandbox: no bwrap under the control launch, so this lane cannot host this check" ;;
    *)    [ "$SB_CONTROL_NOSANDBOX" = "no" ] && SB_READY=1
          [ "$SB_READY" = "1" ] ||
              report "sandbox: the control launch already runs unsandboxed here; the check is unmeasured" ;;
esac
fi

sandbox_check() {
    local knob="$1" name="${1%%=*}"
    local fixed_off unfixed_off
    run_app "$SANDBOX_APP" "${SB_CLEAR[@]}" "$knob"
    fixed_off="$(sandbox_off)"
    report "sandbox $name fixed procs=${LAST_PROCS:-none} nosandbox=$LAST_NOSANDBOX window=$LAST_WINDOW off=$fixed_off"
    if [ "$HAVE_UNFIXED" != "1" ] || [ -z "$UNFIXED_SANDBOX_APP" ]; then
        report "sandbox $name: no control build, so this is a reading and not a check"
        return 0
    fi
    run_app "$UNFIXED_SANDBOX_APP" "${SB_CLEAR[@]}" "$knob"
    unfixed_off="$(sandbox_off)"
    report "sandbox $name unfixed procs=${LAST_PROCS:-none} nosandbox=$LAST_NOSANDBOX window=$LAST_WINDOW off=$unfixed_off"
    if [ "$unfixed_off" != "yes" ]; then
        report "sandbox $name: the engine does not honour it even with the fix removed; unmeasured here"
    elif [ "$fixed_off" = "yes" ]; then
        fail "sandbox $name expected=the sandbox stays on actual=it was turned off from the environment"
    else
        echo "  PASS: $name turns the sandbox off without the fix and cannot reach it with it"
    fi
}

# One reading of the last launch, in whichever way this lane can say it.
sandbox_off() {
    case "$NT_LANE_KIND" in
        gtk)  grep -q bwrap <<<"$LAST_PROCS" && echo no || echo yes ;;
        *)    [ "$LAST_NOSANDBOX" = "yes" ] && echo yes || echo no ;;
    esac
}

# The unfixed build of whichever artifact this section is using. The reach and
# effect sections patch the testing-tier build; this one may be running the
# default-tier one, and patching the wrong file would compare two different
# things and call the difference a fix.
UNFIXED_SANDBOX_APP=""
if [ "$HAVE_UNFIXED" = "1" ]; then
    UNFIXED_SANDBOX_APP="$WORK/unfixed-sandbox.cmd"
    awk '
        /^ *unset GTK_PATH/ { skip = 1; print "    :" }
        skip { if ($0 !~ /\\$/) skip = 0; next }
        /^nt_scrub_loaders$/ { next }
        { print }
    ' "$SANDBOX_APP" > "$UNFIXED_SANDBOX_APP"
    cmp -s "$SANDBOX_APP" "$UNFIXED_SANDBOX_APP" && UNFIXED_SANDBOX_APP=""
fi

if [ "$SB_APPLIES" = "1" ] && [ "$SB_READY" = "1" ]; then
    case "$NT_LANE_KIND" in
        gtk)  sandbox_check WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 ;;
        *)    sandbox_check QTWEBENGINE_DISABLE_SANDBOX=1 ;;
    esac
fi

# =====================================================================
# Cost
# =====================================================================
#
# The maximal rule: every candidate name gone before the launcher starts. If
# the app comes up without all of them then every narrower rule is free, and if
# it does not this says so before the fix is written rather than after.
echo "=== Cost: the app with the whole candidate set removed ==="
UNSET_ARGS=()
for n in $NT_CANDIDATES; do UNSET_ARGS+=(-u "$n"); done
run_app "$APP" "${UNSET_ARGS[@]}"
report "cost strip-candidates window=$LAST_WINDOW names=$(wc -w <<<"$NT_CANDIDATES" | tr -d ' ')"
if [ "$LAST_WINDOW" = "UP" ]; then
    echo "  PASS: the app comes up with every candidate name taken away first"
else
    report "cost tail: $(tr '\n' ' ' <<<"$LAST_LOG" | tr -d '[:cntrl:]' | tail -c 300)"
    fail "cost expected=the app still comes up actual=no window; the rule is not free on this lane"
fi

# And the same question asked the way a rule would ask it. A fixed list is not
# what env.c does and not what this file should do either: it tests a shape
# against a name a namespace admitted, so a knob invented after the rule was
# written is denied before anyone hears about it. This computes that set out of
# the environment the lane really has and takes it away -- which is also the
# only thing that can price the rule on a desktop that is not this runner.
# The same two lists webview.cmd applies, and deliberately the same shape: a
# namespace a toolkit owns, tested against a shape, with LD_ and DYLD_ taken
# wholesale. XDG_ is not among them there and is not here -- a session sets
# XDG_SESSION_PATH and XDG_SEAT_PATH, both of which match "PATH" and neither of
# which names code. If this list and the file's ever disagree, this reading
# stops describing what ships.
NT_NAMESPACES="GTK_ GDK_ GIO_ GSETTINGS_ GI_ GJS_ GST_ QT_ QTWEBENGINE_ QML_ QML2_ WEBKIT_ LIBGL_ MESA_ EGL_ VK_"
NT_SHAPES="MODULE PLUGIN PRELOAD LIBRAR LAYER DRIVER ICD BUNDLE SANDBOX EXEC LAUNCH PROFIL FLAGS ARGS PATH PREFIX AUDIT"
SHAPED=()
while IFS='=' read -r name _; do
    case "$name" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    case "$name" in
        LD_*|DYLD_*) SHAPED+=("$name"); continue ;;
    esac
    for ns in $NT_NAMESPACES; do
        case "$name" in
            "$ns"*)
                for sh in $NT_SHAPES; do
                    case "$name" in *"$sh"*) SHAPED+=("$name"); break ;; esac
                done
                break ;;
        esac
    done
done < <(env)
# What the lane holds in those namespaces at all, shaped or not. Round two read
# "the shape rule would take (none)" on gjs, which is true and says nothing: a
# rule cannot be priced against an environment that has nothing for it to take.
# This is the denominator that reading was missing.
NAMESPACED=()
while IFS='=' read -r name _; do
    case "$name" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    case "$name" in LD_*|DYLD_*) NAMESPACED+=("$name"); continue ;; esac
    for ns in $NT_NAMESPACES; do
        case "$name" in "$ns"*) NAMESPACED+=("$name"); break ;; esac
    done
done < <(env)
report_list "cost the namespaces hold" "${NAMESPACED[@]+"${NAMESPACED[@]}"}"
report_list "cost the shape rule would take" "${SHAPED[@]+"${SHAPED[@]}"}"
if [ ${#SHAPED[@]} -gt 0 ]; then
    SHAPE_ARGS=()
    for n in "${SHAPED[@]}"; do SHAPE_ARGS+=(-u "$n"); done
    run_app "$APP" "${SHAPE_ARGS[@]}"
    report "cost strip-shaped window=$LAST_WINDOW names=${#SHAPED[@]}"
    [ "$LAST_WINDOW" = "UP" ] ||
        fail "cost expected=the app comes up without what the shape rule takes actual=no window"
fi

echo "=== $FAILURES failure(s) ==="
exit $((FAILURES > 0))
