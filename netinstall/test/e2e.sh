#!/bin/bash
# e2e.sh - fetch, verify and run a real neutrino polyglot through netinstall
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: e2e.sh <netinstall binary built with -DNEUTRINO_TESTING> [screenshot dir]" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
SHOTS="${2:-}"
[ -n "$SHOTS" ] || SHOTS="$WORK/screenshots"
mkdir -p "$SERVE" "$WORK/bin" "$SHOTS"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0

echo "=== Build the app under test ==="
bash "$ROOT/build.sh" --tier=testing "$ROOT/test/neutrinotest.js" "$SERVE/neutrinotest.cmd"
SPEC="neutrinotest-example-com-1$(nt_pin "$SERVE/neutrinotest.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
echo "  built and pinned as $SPEC"

echo "=== Resolve ==="
"$APP" --info
nt_note "confine: $("$APP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"

SCRIPT="$NEUTRINO_HOME/apps/$(nt_appkey "$SPEC")/neutrinotest.cmd"
APPDIR="$NEUTRINO_HOME/apps/$(nt_appkey "$SPEC")/neutrinotest"

echo "=== Fetch and verify ==="
if "$APP" --fetch >/dev/null 2>&1; then
    echo "  PASS: fetched"
else
    nt_fail "fetch expected=ok actual=failed"
    FAILURES=$((FAILURES + 1))
fi

if cmp -s "$SERVE/neutrinotest.cmd" "$SCRIPT"; then
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

FULL="$(nt_sha256 "$SERVE/neutrinotest.cmd")"
if [ -f "$NEUTRINO_HOME/blobs/$FULL" ]; then
    echo "  PASS: blob is content-addressed as blobs/$FULL"
else
    nt_fail "blob expected=blobs/$FULL actual=missing"
    FAILURES=$((FAILURES + 1))
fi

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
    # whole 120 seconds and then failed, and the cost was not the failure: the
    # app runs a sixteen-second sequence and exits, so by the time
    # verify-windows started there was no process left and it spent its own 240
    # against one that had already finished.
    KEPT="${SCRIPT%.cmd}.exe"
    FALLBACK="$APPDIR/neutrinotest.exe"
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
    # PowerShell cannot read an MSYS path, so hand it a native one.
    PS1="$(cygpath -w "$ROOT/test/verify-windows.ps1")"
    SHOTS_WIN="$(cygpath -w "$SHOTS")"
    # verify-windows defaults its app dir to its own test/ tree, where the
    # standalone lane runs neutrinotest.cmd. Here the app is installed and run
    # from the netinstall HOME, so the WebView2 package sits beside *that* exe
    # -- point the verifier at it, or it checks an empty repo path and fails
    # "no package directory". The single windows lane masked this: its earlier
    # standalone neutrinotest step had populated test/neutrinotest first.
    APPDIR_WIN="$(cygpath -w "$APPDIR")"
    SCRIPT_WIN="$(cygpath -w "$SCRIPT")"
    PSEXE=powershell
    command -v pwsh >/dev/null 2>&1 && PSEXE=pwsh
    # `-Command ... *>&1`, not `-File`: verify-windows.ps1 speaks in Write-Host,
    # which is the information stream, and a plain `> log 2>&1` catches stdout
    # and stderr and not that -- so the log would be empty of every PASS and
    # FAIL. The webview lanes merge with `*>&1` for the same reason; this is the
    # same merge, one level out, so the exit code still carries the count.
    "$PSEXE" -NoProfile -ExecutionPolicy Bypass \
        -Command "& '$PS1' -ScreenshotDir '$SHOTS_WIN' -AppDir '$APPDIR_WIN' -Artifact '$SCRIPT_WIN' *>&1" \
        > "$WORK/verify-windows.log" 2>&1
    RC=$?
    cat "$WORK/verify-windows.log"
    if [ "$RC" -ne 0 ]; then
        # The verifier's own account, not just its count. e2e used to surface
        # only the number, so a red here named nothing and the detail -- which
        # half stalled, the WebView2 package or the window -- was left behind.
        # Emitted as errors, not notices:
        # the whole netinstall suite shares one step, its ten-notice bucket is
        # full of findings long before e2e runs, and these lines were dropped.
        # The error bucket is near empty -- only actual failures reach it.
        #
        # The failures first, and that is the repair. This was one grep for
        # `FAIL:|report:` with `head -8` on the end, and verify-windows.ps1
        # prints a `report:` line per recorded state before it asserts anything
        # -- so eight lines of a run that reported seven states was seven states
        # and a watch line, and the sentence naming what failed was the ninth.
        # A red round surfaced a complete, correct sequence and no reason,
        # which is worse than surfacing nothing: it reads like the app was fine.
        #
        # The per-state `seq` lines go, because a failing assertion prints its
        # own detail and the full log is in the artifact. What is kept beside
        # the failures is the apparatus: the sampler's turn count and its widest
        # gap, which is the reading half of these controls fire on.
        while IFS= read -r line; do
            echo "  verify-windows: $line"
            [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=netinstall::e2e verify-windows: $line"
        done < <({ grep -aE '^[[:space:]]*FAIL:' "$WORK/verify-windows.log"
                   grep -aE '^[[:space:]]*report: (sampler|watch)' "$WORK/verify-windows.log"
                 } | tr -d '\r' | sed 's/^[[:space:]]*//' | head -10)
        nt_fail "verify-windows.ps1 reported $RC failure(s)"
    fi
    FAILURES=$((FAILURES + RC))
    nt_kill_tree $APP_PID
elif command -v osascript >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then
    echo "=== Launch through osascript ==="
    "$APP" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    # TMPDIR is deliberately not redirected on macOS, so the driver and the
    # verifier agree on where the status file lives.
    APP_PID=$APP_PID nt_timeout 240 bash "$ROOT/test/verify-macos.sh" "$SHOTS"
    RC=$?
    [ "$RC" -eq 124 ] && nt_fail "verify-macos.sh timed out"
    if [ "$RC" -ne 0 ]; then
        nt_note "status file search: $(find "$APPDIR" "${TMPDIR:-/tmp}" -name 'neutrino-title*' 2>/dev/null | tr '\n' ' ')"
    fi
    [ "$RC" -eq 0 ] || nt_fail "verify-macos.sh reported $RC failure(s)"
    FAILURES=$((FAILURES + RC))
    nt_kill_tree $APP_PID
elif [ -n "${DISPLAY:-}" ] && nt_linux_runtime; then
    echo "=== Launch through the linux runtime ==="
    "$APP" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    nt_timeout 240 bash "$ROOT/test/verify-linux.sh" "$SHOTS"
    RC=$?
    [ "$RC" -eq 124 ] && nt_fail "verify-linux.sh timed out"
    [ "$RC" -eq 0 ] || nt_fail "verify-linux.sh reported $RC failure(s)"
    FAILURES=$((FAILURES + RC))
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

echo "=== A new pin reuses the app dir and replaces the launcher ==="
cp "$SERVE/neutrinotest.cmd" "$WORK/v1.cmd"
mkdir -p "$APPDIR"
echo keep > "$APPDIR/carried-over"
printf 'echo v2\n' > "$SERVE/neutrinotest.cmd"
SPEC2="neutrinotest-example-com-1$(nt_pin "$SERVE/neutrinotest.cmd")"
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
    if cmp -s "$SERVE/neutrinotest.cmd" "$SCRIPT"; then
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
cp "$WORK/v1.cmd" "$SERVE/neutrinotest.cmd"

echo "=== A shape with a directory fetches from the subdirectory ==="
# The shapes are the only thing that knows a subdirectory exists, and a parser
# test cannot tell a URL that was built from one that was fetched. This one is
# served from a real subdirectory, which is what a project GitHub Pages site is.
# It is an even shape, so nothing in the name says netinstall.cmd and that is
# still the file the server has to be asked for.
mkdir -p "$SERVE/demo"
cp "$SERVE/neutrinotest.cmd" "$SERVE/demo/netinstall.cmd"
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
cp "$SERVE/neutrinotest.cmd" "$SERVE/toy/calc.cmd"
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
