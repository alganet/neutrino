#!/bin/bash
# pinfloor.sh - the pin floor, asserted where it was measured
#
# Round 1 of PR 13 measured this on five lanes with the floor still at sixteen:
# 16 through 64 accepted, 15 and 65 refused, thirteen names in this tree below
# thirty-two, the binary's own --help example one of them, and no pin in any
# path netinstall creates. Every one of those is asserted here to what the
# floor is now, so a change in either direction is a failure and not silence.
#
# It still reports what it found. A green tick says the numbers held; the
# report lines say what the numbers are, which is what the next person to touch
# this constant needs.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: pinfloor.sh <netinstall binary>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"
trap 'kill ${NT_SERVER_PID:-} 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0

# Eighty hex characters, so a pin one past the 64 cap can be asked for too.
PIN="$(printf 'a1b2c3d4e5f60718%.0s' 1 2 3 4 5)"

pin_of() {
    [ "$1" = "0" ] && return 0
    printf '%s' "$PIN" | cut -c1-"$1"
}

as() {
    nt_as "$BIN" "$1" "$WORK/bin" >/dev/null
    echo "$WORK/bin/$1$NT_EXE"
}

# --info is the oracle the grammar suite already uses: it parses the name and
# prints what it resolved to without touching the network.
parses() {
    "$(as "$1")" --info >/dev/null 2>&1
}

# The refusal, not the preamble. Every phase describes its own confinement on
# stderr before it does anything, so the first line of a failed --fetch is a
# landlock or seatbelt description and not the reason it failed. Two lines,
# because a refusal by length is a headline and a reason beneath it. Trimmed as
# well: an annotation carries what fits and drops the rest without saying so.
first_line() {
    tr -d '\r' < "$1" \
        | grep -v '^[[:space:]]*$' \
        | grep -v 'confine:' \
        | head -2 | tr '\n' ' ' | sed -e 's/   */ /g' -e 's/ *$//' \
        | cut -c1-150
}

# Does the refusal name its own cause, or does the person holding the binary
# have to guess? Asked of the text rather than assumed from it.
says() {
    case "$1" in
        *pin*|*Pin*) echo "pin" ;;
        *) echo "no" ;;
    esac
}

echo "=== The floor, at every boundary that matters ==="
# 32 through 64 accepted, everything else refused -- both ends, so a floor that
# went up cannot pass by rejecting more than it was asked to.
ACCEPT=""
REJECT=""
for n in 0 1 8 15 16 17 24 31 32 33 63 64 65 80; do
    spec="p$n-example-com-1$(pin_of "$n")"
    if [ "$n" -ge 32 ] && [ "$n" -le 64 ]; then
        want=accepted
    else
        want=rejected
    fi
    if parses "$spec"; then
        got=accepted
        ACCEPT="$ACCEPT,$n"
    else
        got=rejected
        REJECT="$REJECT,$n"
    fi
    if [ "$got" = "$want" ]; then
        echo "  PASS: n=$n $got"
    else
        nt_fail "pin length $n expected=$want actual=$got"
        FAILURES=$((FAILURES + 1))
    fi
done

echo "=== Controls ==="
# Without these the table above is worthless: a parser that took everything and
# one that took nothing both produce a tidy-looking list.
OK="app-example-com-1$(pin_of 32)"
URL="$("$(as "$OK")" --info 2>/dev/null | awk '$1 == "url" { print $2 }')"
if [ "$URL" = "https://example.com/app.cmd" ]; then
    echo "  PASS: control name resolves (url=$URL)"
else
    nt_fail "control name expected=https://example.com/app.cmd actual=${URL:-<none>}"
    FAILURES=$((FAILURES + 1))
fi
if parses "app-example-com"; then
    nt_fail "control reject expected=rejected actual=accepted (a tokenless name parsed)"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: control reject still rejects"
fi

echo "=== What the shipped help offers as an example ==="
# From the binary, not from a file: the question is whether what a user is told
# to type is something this parser will take.
HELP="$("$(as "$OK")" --help 2>&1)"
HELPNAME="$(printf '%s\n' "$HELP" | grep -oE '[a-z][a-z0-9_]*(-[a-z0-9_]+){1,}-[0-3][0-9a-f]{32,}' | head -1)"
HELPTOK="${HELPNAME##*-}"
HELPLEN=$(( ${#HELPTOK} - 1 ))
[ -n "$HELPNAME" ] || HELPLEN=-1
if [ -n "$HELPNAME" ] && parses "$HELPNAME"; then
    HELPSTATE=PARSES
else
    HELPSTATE=REJECTED
fi
echo "  help example: ${HELPNAME:-<none>} pin=$HELPLEN $HELPSTATE"
# The example was sixteen characters when the floor was sixteen, so raising the
# floor made this binary ship a name it refuses. Whatever the help says next has
# to be something the parser beside it will take.
if [ "$HELPSTATE" = "PARSES" ]; then
    echo "  PASS: the name in --help is one this binary accepts"
else
    nt_fail "help example expected=PARSES actual=$HELPSTATE (${HELPNAME:-<none>}, pin=$HELPLEN)"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Every spec-shaped name written down in this tree ==="
# The blast radius of raising the floor, counted rather than guessed: each of
# these is a name some file hands to this parser, and one carrying a pin the
# new floor rejects is either a doc that lies or a test that passes for the
# wrong reason.
SHORT=0
TOTAL=0
WHERE=""
for f in "$HERE"/*.sh "$HERE"/../README.md "$HERE"/../*.c; do
    [ -f "$f" ] || continue
    # A line that says "short on purpose" is a case about the floor rather than
    # a name written at it -- names.sh has to be able to refuse a short pin
    # without that refusal reading as a fixture nobody updated.
    hits="$(grep -v 'short on purpose' "$f" 2>/dev/null \
        | grep -ohE '[a-z][a-z0-9_]*(-[a-z0-9_]+){2,}-0[0-9a-z]{8,}' | sort -u)"
    [ -n "$hits" ] || continue
    for name in $hits; do
        tok="${name##*-}"
        # The token is matched loosely above so that a case about a non-hex
        # digit comes out whole rather than as its own shorter prefix -- which
        # is what a strict pattern did, and it counted `...6071g` as a 31.
        # Anything that is not a pin is not this suite's business.
        case "$tok" in
            0*) ;;
            *) continue ;;
        esac
        case "${tok#0}" in
            *[!0-9a-f]*) continue ;;
        esac
        len=$(( ${#tok} - 1 ))
        TOTAL=$((TOTAL + 1))
        if [ "$len" -lt 32 ]; then
            SHORT=$((SHORT + 1))
            case ",$WHERE," in
                *",$(basename "$f"),"*) ;;
                *) WHERE="${WHERE:+$WHERE,}$(basename "$f")" ;;
            esac
            echo "  below 32: $name ($len) in $(basename "$f")"
        fi
    done
done
# Thirteen when this was first measured. Zero is not tidiness: a fixture below
# the floor is an assertion that stopped meaning what it says, and a doc below
# it is an instruction that does not work.
if [ "$SHORT" -eq 0 ]; then
    echo "  PASS: none of the $TOTAL names written down here is below the floor"
else
    nt_fail "names below the floor expected=0 actual=$SHORT of $TOTAL in [$WHERE]"
    FAILURES=$((FAILURES + 1))
fi

echo "=== What a refusal says, and whether the cause is in it ==="
# Two refusals a user can hit and one the suite depends on telling apart: a
# name the floor would reject, and a pin that is long enough but wrong. Today
# verify.sh reads both as "did not exit 0".
printf 'echo hello\n' > "$SERVE/cause.cmd"
nt_serve "$SERVE" || exit 2

SHORTSPEC="cause-example-com-1$(pin_of 16)"
"$(as "$SHORTSPEC")" --fetch >"$WORK/short.out" 2>"$WORK/short.err"
SHORTRC=$?
SHORTMSG="$(first_line "$WORK/short.err")"

MISMATCH="cause-example-com-1$(printf 'deadbeef%.0s' 1 2 3 4)"
"$(as "$MISMATCH")" --fetch >"$WORK/mis.out" 2>"$WORK/mis.err"
MISRC=$?
MISMSG="$(first_line "$WORK/mis.err")"

BADNAME="cause-example-com-1$(pin_of 15)"
"$(as "$BADNAME")" --fetch >"$WORK/bad.out" 2>"$WORK/bad.err"
BADRC=$?
BADMSG="$(first_line "$WORK/bad.err")"

echo "  short(16) rc=$SHORTRC names-the-cause=$(says "$SHORTMSG"): $SHORTMSG"
echo "  mismatch  rc=$MISRC names-the-cause=$(says "$MISMSG"): $MISMSG"
echo "  bad(15)   rc=$BADRC names-the-cause=$(says "$BADMSG"): $BADMSG"

# Before the floor moved, the first two of these were the same sentence: a pin
# below the floor was fetched and then failed the comparison, exactly as a
# wrong pin does. They have to be told apart now, or a suite that asserts a
# refusal cannot say which refusal it got.
case "$SHORTMSG" in
    *"minimum is 32"*) echo "  PASS: a below-floor pin is refused by length, and told which" ;;
    *)
        nt_fail "short pin expected=refused-by-length actual='$SHORTMSG'"
        FAILURES=$((FAILURES + 1)) ;;
esac
case "$MISMSG" in
    *"pin mismatch"*) echo "  PASS: a wrong pin is still refused by comparison" ;;
    *)
        nt_fail "wrong pin expected=pin-mismatch actual='$MISMSG'"
        FAILURES=$((FAILURES + 1)) ;;
esac
if [ "$SHORTRC" = "$MISRC" ] && [ "$SHORTMSG" = "$MISMSG" ]; then
    nt_fail "the two refusals are still one refusal: rc=$SHORTRC '$SHORTMSG'"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Where a pin does and does not appear in a path ==="
INFO="$("$(as "$OK")" --info 2>/dev/null)"
IAPP="$(printf '%s\n' "$INFO" | awk '$1 == "app" { print $2 }')"
ISCRIPT="$(printf '%s\n' "$INFO" | awk '$1 == "script" { print $2 }')"
case "$ISCRIPT" in
    *"$(pin_of 32)"*) INPATH=YES ;;
    *) INPATH=NO ;;
esac
echo "  app=$IAPP"
echo "  script=$ISCRIPT"
echo "  pin in the script path: $INPATH"
# Measured NO on three filesystems, which is why raising the floor needed no
# migration and why the README's front block no longer draws one there.
if [ "$INPATH" = "NO" ]; then
    echo "  PASS: no pin in the path, so a longer one moves nothing"
else
    nt_fail "pin in path expected=NO actual=$INPATH ($ISCRIPT)"
    FAILURES=$((FAILURES + 1))
fi

# Six lines out. They go first in the suite order for a reason: GitHub keeps
# ten annotations per level per step and the netinstall step already emits more
# results than that, so what is measured last is what is silently dropped.
nt_result "report: pinfloor accept=[${ACCEPT#,}] reject=[${REJECT#,}] exe=$NT_WINDOWS"
nt_result "report: pinfloor docs help=${HELPNAME:-<none>}/$HELPLEN/$HELPSTATE names=$TOTAL below32=$SHORT in=[${WHERE:-none}]"
nt_result "report: pinfloor cause short16=$SHORTRC/$(says "$SHORTMSG")/'$SHORTMSG'"
nt_result "report: pinfloor cause mismatch=$MISRC/$(says "$MISMSG")/'$MISMSG'"
nt_result "report: pinfloor cause bad15=$BADRC/$(says "$BADMSG")/'$BADMSG'"
nt_result "report: pinfloor paths app=$IAPP script=$ISCRIPT pin-in-path=$INPATH"

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
