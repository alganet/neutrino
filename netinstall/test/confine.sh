#!/bin/bash
# confine.sh - assert a hostile script is contained to its own app dir
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: confine.sh <netinstall binary built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"

if [ "$NT_WINDOWS" = "1" ]; then
    echo "=== SKIP: payloads run through cmd.exe here; see the windows job ==="
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
FAKEHOME="$HOME/.netinstall-confine-$$"
mkdir -p "$SERVE" "$WORK/bin" "$FAKEHOME"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE"
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK" "$FAKEHOME"' EXIT

FAILURES=0

# Writes outside the app dir, tries to overwrite its own launcher, then reports
# what the XDG redirection gave it.
cat > "$SERVE/hostile.cmd" <<'SCRIPT'
outside="$FAKEHOME/pwned"
if echo owned > "$outside" 2>/dev/null; then echo "ESCAPED_HOME"; else echo "BLOCKED_HOME"; fi
if echo owned > "$(dirname "$0")/hostile.cmd" 2>/dev/null; then echo "ESCAPED_LAUNCHER"; else echo "BLOCKED_LAUNCHER"; fi
if echo owned > "$XDG_DATA_HOME/ok" 2>/dev/null; then echo "OWN_DIR_WRITABLE"; else echo "OWN_DIR_BLOCKED"; fi
if cat /etc/hosts >/dev/null 2>&1; then echo "READS_WORK"; else echo "READS_BLOCKED"; fi
cp /bin/true "$XDG_DATA_HOME/probe" 2>/dev/null && chmod +x "$XDG_DATA_HOME/probe" 2>/dev/null
if "$XDG_DATA_HOME/probe" 2>/dev/null; then echo "EXEC_OWN_DIR"; else echo "EXEC_BLOCKED"; fi
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0))" 2>/dev/null; then echo "BIND_OK"; else echo "BIND_BLOCKED"; fi
else echo "BIND_SKIP"; fi
SCRIPT

SPEC="hostile-com-example-0$(nt_pin "$SERVE/hostile.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
export FAKEHOME

OUT="$("$APP" 2>"$WORK/err")"
CONFINE="$("$APP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
nt_note "confinement: $CONFINE"

check() {
    local label="$1" want="$2"
    if grep -qx "$want" <<<"$OUT"; then
        echo "  PASS: $label ($want)"
    else
        nt_fail "$label expected=$want actual=$(tr '\n' ' ' <<<"$OUT")"
        FAILURES=$((FAILURES + 1))
    fi
}

if [ "${CONFINE#none}" != "$CONFINE" ]; then
    nt_note "SKIP: no confinement available; asserting the inverse"
    check "writes outside the app dir succeed unconfined" ESCAPED_HOME
else
    check "write outside the app dir is blocked"  BLOCKED_HOME
    check "overwriting its own launcher is blocked" BLOCKED_LAUNCHER
fi

check "its own dir stays writable" OWN_DIR_WRITABLE
check "reads still work"           READS_WORK

if [ "$(uname -s)" = "Darwin" ]; then
    # Write xor execute: the one directory an app can write to is the one it
    # must not be able to run anything from. On linux this needs the exec
    # allowlist, so it lives in the tight tier and confine-strict.sh covers it.
    check "cannot execute what it wrote" EXEC_BLOCKED
else
    nt_note "w^x is tight-tier only on linux; got $(grep -o 'EXEC_[A-Z_]*' <<<"$OUT")"
fi

if [ "$(uname -s)" = "Linux" ]; then
    check "cannot bind a TCP port" BIND_BLOCKED
else
    nt_note "tcp bind confinement is landlock-only; got $(grep -o 'BIND_[A-Z]*' <<<"$OUT")"
fi

echo "=== The launcher still verifies after the attempt ==="
if "$APP" --verify >/dev/null 2>&1; then
    echo "  PASS: pin still matches"
else
    nt_fail "pin expected=intact actual=broken"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
