#!/bin/bash
# e2e.sh - fetch, verify and run a real neutrino polyglot through netinstall
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: e2e.sh <netinstall binary built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0

echo "=== Build the app under test ==="
# netinstall's own app and not test/neutrinotest.js. What this suite asserts
# about the launch is that a fetched, verified and pinned polyglot runs; the
# six-state window contract belongs to neutrino's verifiers, which every lane
# that runs this suite has already run against a standalone launch of its own.
# See nt_app_probe in lib.sh for the whole of that argument.
bash "$ROOT/test/mkapp.sh" --tier=testing "$NT_TESTDIR/alive.js" "$SERVE/alive.cmd"
SPEC="alive-example-com-1$(nt_pin "$SERVE/alive.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
echo "  built and pinned as $SPEC"

echo "=== Resolve ==="
"$APP" --info
nt_note "confine: $("$APP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"

SCRIPT="$NEUTRINO_HOME/apps/$(nt_appkey "$SPEC")/alive.cmd"
APPDIR="$NEUTRINO_HOME/apps/$(nt_appkey "$SPEC")/alive"

echo "=== Fetch and verify ==="
if "$APP" --fetch >/dev/null 2>&1; then
    echo "  PASS: fetched"
else
    nt_fail "fetch expected=ok actual=failed"
    FAILURES=$((FAILURES + 1))
fi

if cmp -s "$SERVE/alive.cmd" "$SCRIPT"; then
    echo "  PASS: cached bytes are identical to what was served"
else
    nt_fail "cached bytes expected=identical actual=differ"
    FAILURES=$((FAILURES + 1))
fi

if [ ! -w "$SCRIPT" ]; then
    echo "  PASS: cached launcher is read-only"
else
    nt_fail "cached launcher expected=read-only actual=writable"
    FAILURES=$((FAILURES + 1))
fi

FULL="$(nt_sha256 "$SERVE/alive.cmd")"
if [ -f "$NEUTRINO_HOME/blobs/$FULL" ]; then
    echo "  PASS: blob is content-addressed as blobs/$FULL"
else
    nt_fail "blob expected=blobs/$FULL actual=missing"
    FAILURES=$((FAILURES + 1))
fi

# What a launch has to answer here, and the three answers it can give, are in
# nt_app_probe's header in lib.sh. In one line: this suite asks whether the app
# it installed opens a webview and runs its script, and neutrino's own verifiers
# -- which every lane running this suite has already run against a standalone
# launch a few minutes earlier -- answer a different and much longer question.
STATE=""
if [ "$NT_WINDOWS" = "1" ]; then
    echo "=== Launch through cmd.exe ==="
    "$APP" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    # The exe is kept beside the script now, not inside the app dir. That is the
    # whole of why it can be kept at all: this directory is the one the app
    # cannot write -- the same reason the launcher above is read-only here --
    # and the app dir below it is the one it can. The launcher falls back into
    # the app dir where the script's own directory will not take a stamp, so
    # both are waited for and the reading says which arrived.
    #
    # This loop used to name the app dir alone. When the exe moved it spun its
    # whole 120 seconds and then failed, and by the time the window was looked
    # for there was nothing left to look at.
    KEPT="${SCRIPT%.cmd}.exe"
    FALLBACK="$APPDIR/alive.exe"
    for _ in $(seq 1 120); do
        if [ -f "$KEPT" ] || [ -f "$FALLBACK" ]; then break; fi
        sleep 1
    done
    if [ -f "$KEPT" ]; then
        echo "  PASS: jsc.exe compiled the app beside the script it was verified from"
        if [ -f "${SCRIPT%.cmd}.stamp" ]; then
            echo "  PASS: and stamped it with the source it was built from"
        else
            nt_fail "stamp expected=${SCRIPT%.cmd}.stamp actual=missing"
            FAILURES=$((FAILURES + 1))
        fi
    elif [ -f "$FALLBACK" ]; then
        echo "  PASS: jsc.exe compiled the app into its own dir (stamp refused above it)"
    else
        nt_fail "compiled exe expected=$KEPT or $FALLBACK actual=missing"
        FAILURES=$((FAILURES + 1))
    fi
    STATE="$(nt_app_probe 120)"
    nt_kill_tree $APP_PID
elif command -v osascript >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then
    echo "=== Launch through osascript ==="
    # TMPDIR is deliberately not redirected on macOS, so the launcher and the
    # probe agree on where the status file lives. nt_app_gone clears it, so a
    # title left by something earlier cannot be read as this launch's.
    nt_app_gone
    "$APP" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    # The longest budget of the three, and it is the one verify-macos.sh already
    # needed for a first window: osascript starting, the bridge coming up, and
    # WKWebView creating its content process all happen before any title.
    STATE="$(nt_app_probe 180)"
    nt_kill_tree $APP_PID
elif [ -n "${DISPLAY:-}" ] && nt_linux_runtime; then
    echo "=== Launch through the linux runtime ==="
    nt_app_gone
    "$APP" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    STATE="$(nt_app_probe 120)"
    nt_kill_tree $APP_PID
else
    echo "=== No webview runtime here; assert the polyglot's shell path ran ==="
    ERR="$(nt_timeout 60 "$APP" 2>&1 >/dev/null)"
    RC=$?
    if [ "$RC" -eq 124 ]; then
        nt_fail "polyglot did not exit; a runtime was found that nt_linux_runtime missed"
        FAILURES=$((FAILURES + 1))
    elif grep -q "No suitable runtime found" <<<"$ERR"; then
        echo "  PASS: sh executed the polyglot and reached its runtime probe"
    else
        nt_fail "polyglot expected=runtime-probe actual=$(tr '\n' ' ' <<<"$ERR")"
        FAILURES=$((FAILURES + 1))
    fi
fi

case "$STATE" in
    # Empty is the no-runtime branch above, which asserted its own thing and
    # left nothing for this to judge. Every other silence is named.
    "") ;;
    CONTENT_OK)
        echo "  PASS: the installed app opened a webview and its script ran" ;;
    WINDOW_NO_CONTENT)
        # The distinction this probe exists for: the process started and got a
        # window, and the page inside it never ran. A launcher that cannot find
        # its runtime fails differently, and so does a sandbox that kills the
        # renderer -- naming which one is the finding.
        nt_fail "the installed app got a window but its script never ran"
        FAILURES=$((FAILURES + 1)) ;;
    NO_WINDOW)
        nt_fail "the installed app never got a window"
        FAILURES=$((FAILURES + 1)) ;;
    *)
        nt_fail "the webview probe did not report a state ($STATE)"
        FAILURES=$((FAILURES + 1)) ;;
esac

echo "=== A new pin reuses the app dir and replaces the launcher ==="
cp "$SERVE/alive.cmd" "$WORK/v1.cmd"
mkdir -p "$APPDIR"
echo keep > "$APPDIR/carried-over"
printf 'echo v2\n' > "$SERVE/alive.cmd"
SPEC2="alive-example-com-1$(nt_pin "$SERVE/alive.cmd")"
APP2="$(nt_as "$BIN" "$SPEC2" "$WORK/bin")"
if [ "$SPEC" = "$SPEC2" ]; then
    nt_fail "second pin expected=different actual=same"
    FAILURES=$((FAILURES + 1))
elif "$APP2" --fetch >/dev/null 2>&1; then
    if [ -f "$APPDIR/carried-over" ]; then
        echo "  PASS: app dir state survived the version change"
    else
        nt_fail "app dir state expected=preserved actual=lost"
        FAILURES=$((FAILURES + 1))
    fi
    if cmp -s "$SERVE/alive.cmd" "$SCRIPT"; then
        echo "  PASS: launcher replaced by the new pin"
    else
        nt_fail "launcher expected=new-version actual=stale"
        FAILURES=$((FAILURES + 1))
    fi
    if "$APP2" --verify >/dev/null 2>&1 && ! "$APP" --verify >/dev/null 2>&1; then
        echo "  PASS: last pin wins; the old pin no longer verifies"
    else
        nt_fail "pin precedence expected=last-wins actual=both-or-neither"
        FAILURES=$((FAILURES + 1))
    fi
else
    nt_fail "second pin expected=fetched actual=failed"
    FAILURES=$((FAILURES + 1))
fi
cp "$WORK/v1.cmd" "$SERVE/alive.cmd"

echo "=== A shape with a directory fetches from the subdirectory ==="
# The shapes are the only thing that knows a subdirectory exists, and a parser
# test cannot tell a URL that was built from one that was fetched. This one is
# served from a real subdirectory, which is what a project GitHub Pages site is.
# It is an even shape, so nothing in the name says netinstall.cmd and that is
# still the file the server has to be asked for.
mkdir -p "$SERVE/demo"
cp "$SERVE/alive.cmd" "$SERVE/demo/netinstall.cmd"
DSPEC="demo-127_0_0_1-2$(nt_pin "$SERVE/demo/netinstall.cmd")"
DAPP="$(nt_as "$BIN" "$DSPEC" "$WORK/bin")"
DURL="$("$DAPP" --info 2>/dev/null | awk '$1 == "url" { print $2 }')"
if [ "$DURL" = "$NEUTRINO_TEST_ORIGIN/demo/netinstall.cmd" ]; then
    echo "  PASS: shape 2 resolved to $DURL"
else
    nt_fail "shape 2 url expected=$NEUTRINO_TEST_ORIGIN/demo/netinstall.cmd actual=${DURL:-<none>}"
    FAILURES=$((FAILURES + 1))
fi
DSCRIPT="$NEUTRINO_HOME/apps/$(nt_appkey "$DSPEC")/netinstall.cmd"
if "$DAPP" --fetch >/dev/null 2>&1 && cmp -s "$SERVE/demo/netinstall.cmd" "$DSCRIPT"; then
    echo "  PASS: fetched and verified through the subdirectory"
else
    nt_fail "shape 2 fetch expected=ok actual=failed ($DSCRIPT)"
    FAILURES=$((FAILURES + 1))
fi
echo "=== A shape that names both file and directory ==="
mkdir -p "$SERVE/toy"
cp "$SERVE/alive.cmd" "$SERVE/toy/calc.cmd"
TSPEC="calc-toy-127_0_0_1-3$(nt_pin "$SERVE/toy/calc.cmd")"
TAPP="$(nt_as "$BIN" "$TSPEC" "$WORK/bin")"
TSCRIPT="$NEUTRINO_HOME/apps/$(nt_appkey "$TSPEC")/calc.cmd"
if "$TAPP" --fetch >/dev/null 2>&1 && cmp -s "$SERVE/toy/calc.cmd" "$TSCRIPT"; then
    echo "  PASS: shape 3 fetched $(nt_appkey "$TSPEC")/calc.cmd"
else
    nt_fail "shape 3 fetch expected=ok actual=failed ($TSCRIPT)"
    FAILURES=$((FAILURES + 1))
fi
# Same segments, same pin, different shape: different URL, so the app dirs must
# not be the same one. This is what keeping the shape in the cache key buys.
if [ "$(nt_appkey "$DSPEC")" != "$(nt_appkey "$TSPEC")" ] && [ -f "$DSCRIPT" ] && [ -f "$TSCRIPT" ]; then
    echo "  PASS: the two shapes kept separate app directories"
else
    nt_fail "app dirs expected=distinct actual=$(nt_appkey "$DSPEC") vs $(nt_appkey "$TSPEC")"
    FAILURES=$((FAILURES + 1))
fi

echo "=== neutrino's own app dir landed inside the writable dir ==="
if [ -d "$APPDIR" ]; then
    echo "  PASS: $APPDIR"
else
    nt_fail "appdir expected=$APPDIR actual=missing"
    FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -ne 0 ] && [ -s "$WORK/app.log" ]; then
    echo "=== App output ==="
    tail -40 "$WORK/app.log"
    nt_note "app log: $(tr '\n' ' ' < "$WORK/app.log" | tail -c 400)"
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
