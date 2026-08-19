#!/bin/bash
# confine-strict.sh - does the tight tier hold, and can a webview still start?
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: confine-strict.sh <binary built with -DNEUTRINO_CONFINE_TIGHT>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
OUTSIDE="$HOME/.netinstall-outside-$$"
mkdir -p "$SERVE" "$WORK/bin" "$OUTSIDE"
export NEUTRINO_HOME="$WORK/home"
echo "top secret" > "$OUTSIDE/secret"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK" "$OUTSIDE"' EXIT

FAILURES=0

if [ "$NT_WINDOWS" = "1" ]; then
    export NT_OUTSIDE="$(cygpath -w "$OUTSIDE")"
    cat > "$SERVE/nosy.cmd" <<'BATCH'
@echo off
> "%NT_OUTSIDE%\pwned" echo owned 2>nul
if exist "%NT_OUTSIDE%\pwned" (echo ESCAPED_OUTSIDE) else (echo OUTSIDE_BLOCKED)
> "%XDG_DATA_HOME%\ok" echo x 2>nul
if exist "%XDG_DATA_HOME%\ok" (echo OWN_DIR_OK) else (echo OWN_DIR_BLOCKED)
copy "%NT_OUTSIDE%\secret" nul >nul 2>&1
if errorlevel 1 (echo SECRET_BLOCKED) else (echo READ_SECRET)
BATCH
else
    export NT_OUTSIDE="$OUTSIDE"
    cat > "$SERVE/nosy.cmd" <<'SCRIPT'
if echo owned > "$NT_OUTSIDE/pwned" 2>/dev/null; then echo "ESCAPED_OUTSIDE"; else echo "OUTSIDE_BLOCKED"; fi
if echo x > "$XDG_DATA_HOME/ok" 2>/dev/null; then echo "OWN_DIR_OK"; else echo "OWN_DIR_BLOCKED"; fi
if cat "$NT_OUTSIDE/secret" >/dev/null 2>&1; then echo "READ_SECRET"; else echo "SECRET_BLOCKED"; fi
if cat /etc/hosts >/dev/null 2>&1; then echo "ETC_OK"; else echo "ETC_BLOCKED"; fi
if ls /usr/share >/dev/null 2>&1; then echo "USR_OK"; else echo "USR_BLOCKED"; fi
cp /bin/true "$XDG_DATA_HOME/probe" 2>/dev/null && chmod +x "$XDG_DATA_HOME/probe" 2>/dev/null
if "$XDG_DATA_HOME/probe" 2>/dev/null; then echo "EXEC_OWN_DIR"; else echo "EXEC_BLOCKED"; fi
SCRIPT
fi

SPEC="nosy-com-example-0$(nt_pin "$SERVE/nosy.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"

OUT="$(nt_timeout 60 "$APP" 2>"$WORK/err" | tr -d "\r")"
CONFINE="$("$APP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
nt_note "confinement: $CONFINE"

case "$CONFINE" in
    *"reads and writes"*|*"low integrity"*) ;;
    *)  nt_note "SKIP: this binary has no tight confinement ($CONFINE)"
        exit 0 ;;
esac

check() {
    local label="$1" want="$2"
    if grep -qx "$want" <<<"$OUT"; then
        echo "  PASS: $label ($want)"
    else
        nt_fail "$label expected=$want actual=$(tr '\n' ' ' <<<"$OUT")"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== The tight tier holds ==="
check "writes outside the app dir are blocked" OUTSIDE_BLOCKED
check "its own dir stays writable"             OWN_DIR_OK

if [ "$NT_WINDOWS" = "1" ]; then
    # Low integrity is a no-write-up rule, not a no-read-up one. Asserting the
    # limitation keeps the README honest rather than implying reads are covered.
    check "reads are NOT confined at low integrity" READ_SECRET
else
    check "a secret outside is unreadable" SECRET_BLOCKED
    check "system config stays readable"   ETC_OK
    check "system data stays readable"     USR_OK
    check "cannot execute what it wrote"   EXEC_BLOCKED
fi

# The open question this suite exists to answer: the tier has to keep a real
# webview alive, or it is not worth having.
echo "=== Can a real webview still start under it? ==="
bash "$ROOT/build.sh" "$ROOT/test/neutrinotest.js" "$SERVE/neutrinotest.cmd"
GSPEC="neutrinotest-com-example-0$(nt_pin "$SERVE/neutrinotest.cmd")"
GAPP="$(nt_as "$BIN" "$GSPEC" "$WORK/bin")"
GAPPDIR="$NEUTRINO_HOME/apps/$GSPEC/neutrinotest"
RC=0

if [ "$NT_WINDOWS" = "1" ]; then
    "$GAPP" > "$WORK/app.log" 2>&1 &
    GPID=$!
    for _ in $(seq 1 120); do
        [ -f "$GAPPDIR/neutrinotest.exe" ] && break
        sleep 1
    done
    if [ -f "$GAPPDIR/neutrinotest.exe" ]; then
        echo "  PASS: jsc.exe still compiles at low integrity"
    else
        nt_fail "jsc.exe did not compile at low integrity"
        FAILURES=$((FAILURES + 1))
    fi
    nt_timeout 240 pwsh -NoProfile -ExecutionPolicy Bypass \
        -File "$(cygpath -w "$ROOT/test/verify-windows.ps1")" \
        -ScreenshotDir "$(cygpath -w "$WORK/shots")"
    RC=$?
    nt_kill_tree $GPID
elif [ "$(uname -s)" = "Darwin" ]; then
    "$GAPP" > "$WORK/app.log" 2>&1 &
    GPID=$!
    APP_PID=$GPID nt_timeout 240 bash "$ROOT/test/verify-macos.sh" "$WORK/shots"
    RC=$?
    nt_kill_tree $GPID
elif [ -n "${DISPLAY:-}" ] && nt_linux_runtime; then
    "$GAPP" > "$WORK/app.log" 2>&1 &
    GPID=$!
    nt_timeout 240 bash "$ROOT/test/verify-linux.sh" "$WORK/shots"
    RC=$?
    nt_kill_tree $GPID
else
    nt_note "SKIP: no webview runtime here; viability untested"
    RC=-1
fi

if [ "$RC" -eq 0 ]; then
    nt_note "webview started under tight confinement"
    echo "  PASS: webview works under the tight tier"
elif [ "$RC" -eq -1 ]; then
    :
elif [ "$NT_WINDOWS" = "1" ]; then
    # Measured, not assumed: WebView2 does not render in a low integrity host,
    # which is what Microsoft documents. Recorded rather than failed, so the
    # suite still reports it if that ever changes.
    nt_note "known limitation: WebView2 does not render at low integrity (rc=$RC)"
    echo "  NOTE: webview does not start under the tight tier on windows"
else
    nt_fail "webview failed under tight confinement (rc=$RC); this tier is not viable as written"
    nt_note "app log: $(tr '\n' ' ' < "$WORK/app.log" 2>/dev/null | tail -c 400)"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
