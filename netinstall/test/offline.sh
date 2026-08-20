#!/bin/bash
# offline.sh - does -DNEUTRINO_CONFINE_OFFLINE actually keep the app off the network?
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: offline.sh <binary built with -DNEUTRINO_CONFINE_OFFLINE>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"

if [ "$NT_WINDOWS" = "1" ]; then
    echo "=== SKIP: no unprivileged way to deny an app the network on windows ==="
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "=== SKIP: no python3 to make an outbound connection with ==="
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0

# The fixture server is the target: it is definitely listening, so a refusal is
# the tier and not a dead port. The fetch reached it moments earlier through the
# same binary, which is the other half of what this asserts.
cat > "$SERVE/offline.cmd" <<'SCRIPT'
echo "APP_RAN"
NEUTRINO_TEST_PORT="${NEUTRINO_TEST_ORIGIN##*:}"
export NEUTRINO_TEST_PORT
python3 -c "
import os, socket
s = socket.socket()
s.settimeout(5)
try:
    s.connect(('127.0.0.1', int(os.environ['NEUTRINO_TEST_PORT'])))
    print('NET_OK')
except PermissionError:
    print('NET_BLOCKED')
except OSError:
    print('NET_ERR')
" 2>/dev/null || echo "NET_ERR"
SCRIPT

SPEC="offline-com-example-0$(nt_pin "$SERVE/offline.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"

OUT="$(nt_timeout 60 "$APP" 2>"$WORK/err")"
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

case "$CONFINE" in
    *"offline tier unavailable"*)
        nt_note "SKIP: the offline tier does not exist on this platform"
        exit 0 ;;
    *offline*) ;;
    *)  nt_note "SKIP: this binary has no offline tier ($CONFINE)"
        exit 0 ;;
esac

echo "=== The fetch still reached the network ==="
# It got here at all, which means the download and pin check both happened
# under the same binary. The tier is applied to the run phase only, by design.
if [ -n "$OUT" ]; then
    echo "  PASS: fetched and launched"
else
    nt_fail "launch expected=output actual=nothing err=$(tr '\n' ' ' < "$WORK/err")"
    FAILURES=$((FAILURES + 1))
fi

echo "=== The app did not ==="
check "the payload ran"                    APP_RAN
check "outbound TCP is refused"            NET_BLOCKED

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
