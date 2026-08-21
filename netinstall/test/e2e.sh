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
SPEC="neutrinotest-com-example-0$(nt_pin "$SERVE/neutrinotest.cmd")"
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
    for _ in $(seq 1 120); do
        [ -f "$APPDIR/neutrinotest.exe" ] && break
        sleep 1
    done
    if [ -f "$APPDIR/neutrinotest.exe" ]; then
        echo "  PASS: jsc.exe compiled the app into its own dir"
    else
        nt_fail "compiled exe expected=$APPDIR/neutrinotest.exe actual=missing"
        FAILURES=$((FAILURES + 1))
    fi
    # PowerShell cannot read an MSYS path, so hand it a native one.
    PS1="$(cygpath -w "$ROOT/test/verify-windows.ps1")"
    SHOTS_WIN="$(cygpath -w "$SHOTS")"
    if command -v pwsh >/dev/null 2>&1; then
        pwsh -NoProfile -ExecutionPolicy Bypass -File "$PS1" -ScreenshotDir "$SHOTS_WIN"
    else
        powershell -NoProfile -ExecutionPolicy Bypass -File "$PS1" -ScreenshotDir "$SHOTS_WIN"
    fi
    RC=$?
    [ "$RC" -eq 0 ] || nt_fail "verify-windows.ps1 reported $RC failure(s)"
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
SPEC2="neutrinotest-com-example-0$(nt_pin "$SERVE/neutrinotest.cmd")"
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
