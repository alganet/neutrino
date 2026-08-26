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

# What this platform has to confine with, read off the sentence rather than a
# list of platforms. Where it is "none" the two halves of this suite swap: the
# contract of a strict build there is that it refuses *without* being told to,
# and the refusal names the fetch phase, because that is the phase it stops in.
# FreeBSD and NetBSD are the first platforms in this matrix with nothing, and
# the suite read their kept contract as two failures for four rounds.
CONFINE="$("$APP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
case "$CONFINE" in
    none*) NT_CONFINES=0 ;;
    *)     NT_CONFINES=1 ;;
esac

if [ "$NT_CONFINES" = "1" ]; then
    echo "=== With confinement available it runs ==="
    OUT="$(nt_timeout 60 "$APP" 2>"$WORK/err")"
    if grep -q PAYLOAD_RAN <<<"$OUT"; then
        echo "  PASS: payload ran when confinement was applied"
    else
        nt_fail "payload expected=ran actual=$(tr '\n' ' ' <<<"$OUT") err=$(tr '\n' ' ' < "$WORK/err")"
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "=== With nothing to confine with, it refuses unasked ==="
    nt_note "no confinement on this platform ($CONFINE); asserting the inverse"
    rm -f "$RAN"
    OUT="$(nt_timeout 60 "$APP" 2>"$WORK/err")"
    RC=$?
    if [ "$RC" -ne 0 ] && ! grep -q PAYLOAD_RAN <<<"$OUT" && [ ! -f "$RAN" ]; then
        echo "  PASS: refused with exit $RC and ran nothing, with no knob set"
    else
        nt_fail "strict build with nothing to confine it expected=refuse actual=exit $RC $(tr '\n' ' ' <<<"$OUT")"
        FAILURES=$((FAILURES + 1))
    fi
    if grep -qa "refusing to fetch unconfined" "$WORK/err"; then
        echo "  PASS: and named the fetch phase, which is where it stopped"
    else
        nt_fail "stderr expected=refusing-to-fetch-unconfined actual=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        FAILURES=$((FAILURES + 1))
    fi
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
# The run phase is only reached where the fetch phase was confined. Where it was
# not, the refusal above already happened one phase earlier and naming the run
# would be asserting a sentence the program is right not to print.
if [ "$NT_CONFINES" = "0" ]; then
    NT_WANT_REFUSAL="refusing to fetch unconfined"
else
    NT_WANT_REFUSAL="refusing to run unconfined"
fi
if grep -qi "$NT_WANT_REFUSAL" "$WORK/err"; then
    echo "  PASS: said why on stderr ($NT_WANT_REFUSAL)"
else
    nt_fail "stderr expected=$NT_WANT_REFUSAL actual=$(tr '\n' ' ' < "$WORK/err")"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
