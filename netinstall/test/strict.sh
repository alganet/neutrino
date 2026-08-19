#!/bin/bash
# strict.sh - does -DNEUTRINO_STRICT_SANDBOX actually refuse to run unconfined?
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: strict.sh <binary built with -DNEUTRINO_STRICT_SANDBOX>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0

printf 'echo PAYLOAD_RAN > "$XDG_DATA_HOME/ran"\necho PAYLOAD_RAN\n' > "$SERVE/strict.cmd"
SPEC="strict-com-example-0$(nt_pin "$SERVE/strict.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
RAN="$NEUTRINO_HOME/apps/$(nt_appkey "$SPEC")/strict/data/ran"

echo "=== With confinement available it runs ==="
OUT="$(nt_timeout 60 "$APP" 2>"$WORK/err")"
if grep -q PAYLOAD_RAN <<<"$OUT"; then
    echo "  PASS: payload ran when confinement was applied"
else
    nt_fail "payload expected=ran actual=$(tr '\n' ' ' <<<"$OUT") err=$(tr '\n' ' ' < "$WORK/err")"
    FAILURES=$((FAILURES + 1))
fi

echo "=== With confinement unavailable it refuses ==="
rm -f "$RAN"
OUT="$(NEUTRINO_TEST_NO_CONFINE=1 nt_timeout 60 "$APP" 2>"$WORK/err")"
RC=$?
if [ "$RC" -eq 0 ]; then
    nt_fail "strict build expected=refuse actual=exit 0"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: refused with exit $RC"
fi
if grep -q PAYLOAD_RAN <<<"$OUT" || [ -f "$RAN" ]; then
    nt_fail "strict build executed the payload despite refusing"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: payload did not execute"
fi
if grep -qi "refusing to run unconfined" "$WORK/err"; then
    echo "  PASS: said why on stderr"
else
    nt_fail "stderr expected=refusing-to-run-unconfined actual=$(tr '\n' ' ' < "$WORK/err")"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
