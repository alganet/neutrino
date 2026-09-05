#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# demo-local.sh - run the published demo through a real netinstall, locally.
#
# Usage: demo-local.sh [--probe] [--no-confine] [seconds]
#
# The loop this exists to replace: change the launcher, commit to main, let
# pages/build.sh publish, download the netinstall stub, run it, read the one
# line it prints. That is minutes per attempt and it is a publish per attempt,
# and the thing being debugged -- what an app does when netinstall has already
# confined it -- needs neither.
#
# So this builds the artifact pages/build.sh would publish, serves it over
# loopback, pins it the way a download page pins it, and launches it through
# netinstall with confinement on. What comes out is the same process tree a
# download produces.
#
# Two honest differences, both stated rather than papered over:
#
#   - the binary is built -DNEUTRINO_TESTING, because a release binary composes
#     its URL as https://<host> and there is no way to point one at a loopback
#     port. What NEUTRINO_TESTING adds is the origin override, the confinement
#     opt-out and a fake home; nt_confine itself is the same function in both,
#     so the profile this runs under is the profile a download runs under. The
#     opt-out is off unless --no-confine is passed, and the run says which.
#   - there is no Gatekeeper quarantine on the stub, because it was not
#     downloaded. That affects the first-launch prompt and nothing this measures.
#
# What it reports, and why each line is here rather than a screenshot:
#
#   app             whether the launcher's process is still alive
#   policy          NSRunningApplication.activationPolicy, read from *outside*
#                   the app. 0 is Regular -- a Dock icon and windows that show.
#                   -1 is Prohibited: the process runs, NSWindow says isVisible,
#                   and nothing appears on screen. This is the reading that
#                   separates "the app crashed" from "the app is running and you
#                   cannot see it", and it needs no screen-recording permission,
#                   which is what makes it usable from a terminal.
#   title           with --probe, what the page put in its own window title
#                   through test/demoprobe.js -- so "the webview rendered" is
#                   the page's answer and not an inference.
#
# --probe also lays neutrino/build/testing over the app, because the status file
# the title is read from is testing-only. The launcher is the same either way;
# only the artifact differs, and the default is the shape that ships.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

PROBE=0
CONFINE=1
CONTROL=0
SECONDS_TO_WATCH=20
for arg in "$@"; do
    case "$arg" in
        --probe)      PROBE=1 ;;
        --no-confine) CONFINE=0 ;;
        --control)    CONTROL=1 ;;
        [0-9]*)       SECONDS_TO_WATCH="$arg" ;;
        *) echo "usage: demo-local.sh [--probe] [--no-confine] [--control] [seconds]" >&2; exit 2 ;;
    esac
done

if [ "$(uname -s)" != "Darwin" ]; then
    echo "demo-local.sh: written for the macOS lane; nothing here applies" >&2
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"
STATUS="${TMPDIR:-/tmp}/neutrino-title.txt"

cleanup() {
    pkill -f "$NEUTRINO_HOME/apps/" >/dev/null 2>&1
    pkill -f "$SERVE/demo.cmd" >/dev/null 2>&1
    kill "${NT_SERVER_PID:-0}" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== Build ==="
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING" bash "$ROOT/netinstall/build.sh" host >/dev/null || exit 2
BIN="$ROOT/netinstall/dist/netinstall"
echo "  netinstall: $(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

APPSRC="$WORK/app"
mkdir -p "$APPSRC"
cp "$ROOT"/pages/demo/* "$APPSRC/"
OVERLAYS=(--overlay "$APPSRC")
if [ "$PROBE" = 1 ]; then
    cat "$ROOT/test/demoprobe.js" >> "$APPSRC/app.js"
    OVERLAYS+=(--overlay "$ROOT/neutrino/build/testing")
    echo "  artifact:   pages/demo + test/demoprobe.js + build/testing"
else
    echo "  artifact:   pages/demo, as published"
fi
bash "$ROOT/neutrino/assemble.sh" "${OVERLAYS[@]}" "$SERVE/demo.cmd" >/dev/null || exit 2

echo ""
echo "=== Serve and pin ==="
nt_serve "$SERVE" || exit 2
SPEC="demo-example-com-1$(nt_pin "$SERVE/demo.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
echo "  pinned as $SPEC"
"$APP" --info 2>/dev/null | awk '$1 == "confine" || $1 == "url" { print "  " $0 }'

echo ""
echo "=== Launch ==="
rm -f "$STATUS"
if [ "$CONTROL" = 1 ]; then
    # The same artifact with no profile on it at all: not through netinstall,
    # and not through run_macos's sandbox-exec either -- straight to the
    # interpreter, which is what run_macos does minus the confinement. It is
    # here so "not registered as an application" has something to be read
    # against; without a control that line is a fact about macOS and not a
    # finding about this profile.
    echo "  confinement: NONE (control: osascript directly, no netinstall, no profile)"
    NEUTRINO_SCRIPT_PATH="$SERVE/demo.cmd" osascript -l JavaScript "$SERVE/demo.cmd" \
        > "$WORK/app.log" 2>&1 &
elif [ "$CONFINE" = 1 ]; then
    echo "  confinement: on (as a download)"
    "$APP" > "$WORK/app.log" 2>&1 &
else
    echo "  confinement: off (NEUTRINO_TEST_NO_CONFINE=1) -- the control"
    NEUTRINO_TEST_NO_CONFINE=1 "$APP" > "$WORK/app.log" 2>&1 &
fi
APP_PID=$!

# Read from outside the app, so nothing here depends on the app cooperating.
# NSRunningApplication is public API and needs no permission; the window
# server's own list needs screen recording, which a terminal does not have.
cat > "$WORK/apps.js" <<'JS'
ObjC.import("Cocoa");
var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
var out = [];
for (var i = 0; i < apps.count; i++) {
    var a = apps.objectAtIndex(i);
    var name = String(ObjC.unwrap(a.localizedName) || "?");
    if (name !== "osascript") { continue; }
    out.push("pid=" + a.processIdentifier + " policy=" + a.activationPolicy +
             " active=" + a.isActive + " launched=" + a.isFinishedLaunching);
}
console.log(out.length ? out.join(" | ") : "(no osascript app registered)");
JS

waited=0
while [ "$waited" -lt "$SECONDS_TO_WATCH" ]; do
    sleep 2
    waited=$((waited + 2))
done

echo ""
echo "=== What is running ==="
if pgrep -f "$NEUTRINO_HOME/apps/" >/dev/null 2>&1 || \
   { [ "$CONTROL" = 1 ] && pgrep -f "$SERVE/demo.cmd" >/dev/null 2>&1; }; then
    echo "  app:    alive"
else
    echo "  app:    gone"
fi
# 2>&1, because JXA's console.log writes to stderr. Discarding it discards the
# reading, and the discarded reading looks exactly like a reader that failed.
STATE="$(osascript -l JavaScript "$WORK/apps.js" 2>&1 | grep -v 'LSModify')"
echo "  app rec: ${STATE:-<the reader itself failed>}"
case "$STATE" in
    *"policy=0"*)
        echo "           -> Regular. Dock icon, and the window is on screen." ;;
    *"policy=1"*)
        echo "           -> Accessory. No Dock icon; a main window may not show." ;;
    *"policy=-1"*)
        echo "           -> Prohibited. The process runs and shows nothing." ;;
    *"no osascript app registered"*)
        echo "           -> NOT REGISTERED AS AN APPLICATION."
        echo "              The process is alive and, with --probe, its page has"
        echo "              rendered -- but it never became an app, so there is no"
        echo "              Dock icon and no window on screen. This is what a"
        echo "              denied com.apple.coreservices.launchservicesd does:"
        echo "              NSApp.setActivationPolicy(Regular) returns false and"
        echo "              the process stays out of the application list." ;;
esac
if [ "$PROBE" = 1 ]; then
    echo "  title:  $(sed -n '1p' "$STATUS" 2>/dev/null || echo '<no status file>')"
fi

echo ""
echo "=== The launcher's own output ==="
grep -v 'LSModifyNotification' "$WORK/app.log" 2>/dev/null | sed 's/^/  /'
[ -s "$WORK/app.log" ] || echo "  (nothing)"
