#!/bin/bash
# names.sh - assert the spec grammar resolves and rejects as documented
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: names.sh <netinstall binary>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export NEUTRINO_HOME="$WORK/home"

FAILURES=0

field() {
    "$WORK/bin/$1$NT_EXE" --info 2>/dev/null | awk -v k="$2" '$1 == k { $1 = ""; sub(/^ +/, ""); print }'
}

as() {
    nt_as "$BIN" "$1" "$WORK/bin" >/dev/null
}

assert_url() {
    local name="$1" expect="$2" actual
    as "$name"
    actual="$(field "$name" url)"
    if [ "$actual" = "$expect" ]; then
        echo "  PASS: $name -> $expect"
    else
        nt_fail "$name expected=$expect actual=${actual:-<none>}"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_field() {
    local name="$1" key="$2" expect="$3" actual
    as "$name"
    actual="$(field "$name" "$key")"
    if [ "$actual" = "$expect" ]; then
        echo "  PASS: $name $key=$expect"
    else
        nt_fail "$name $key expected=$expect actual=${actual:-<none>}"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_reject() {
    local name="$1"
    as "$name"
    if "$WORK/bin/$name$NT_EXE" --info >/dev/null 2>&1; then
        nt_fail "$name expected=rejected actual=accepted"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: $name rejected"
    fi
}

echo "=== Accepted specs, one per shape ==="
assert_url alganet-dev-0a1b2c3d4e5f60718a1b2c3d4e5f60718              "https://alganet.dev/netinstall.cmd"
assert_url calc-alganet-dev-1a1b2c3d4e5f60718a1b2c3d4e5f60718         "https://alganet.dev/calc.cmd"
assert_url demo-alganet-github-io-2a1b2c3d4e5f60718a1b2c3d4e5f60718   "https://alganet.github.io/demo/netinstall.cmd"
assert_url calc-toy-alganet-dev-3a1b2c3d4e5f60718a1b2c3d4e5f60718     "https://alganet.dev/toy/calc.cmd"

echo "=== Accepted specs, the rest of the grammar ==="
assert_url app-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718          "https://example.com/app.cmd"
assert_url app-www-example-co-uk-1a1b2c3d4e5f60718a1b2c3d4e5f60718    "https://www.example.co.uk/app.cmd"
assert_url app-localhost-1a1b2c3d4e5f60718a1b2c3d4e5f60718            "https://localhost/app.cmd"
assert_url localhost-0a1b2c3d4e5f60718a1b2c3d4e5f60718                "https://localhost/netinstall.cmd"
assert_url my_app-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718       "https://example.com/my-app.cmd"
assert_url app-my_site-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718          "https://my-site.com/app.cmd"
assert_url app-my_dir-example-com-3a1b2c3d4e5f60718a1b2c3d4e5f60718   "https://example.com/my-dir/app.cmd"
assert_url app-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718 "https://example.com/app.cmd"

echo "=== Parsed fields ==="
assert_field demo-alganet-github-io-2a1b2c3d4e5f60718a1b2c3d4e5f60718 name  netinstall
assert_field demo-alganet-github-io-2a1b2c3d4e5f60718a1b2c3d4e5f60718 dir   demo
assert_field demo-alganet-github-io-2a1b2c3d4e5f60718a1b2c3d4e5f60718 host  alganet.github.io
assert_field demo-alganet-github-io-2a1b2c3d4e5f60718a1b2c3d4e5f60718 token 2a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_field calc-toy-alganet-dev-3a1b2c3d4e5f60718a1b2c3d4e5f60718   name  calc
assert_field calc-toy-alganet-dev-3a1b2c3d4e5f60718a1b2c3d4e5f60718   dir   toy
assert_field app-www-example-co-uk-1a1b2c3d4e5f60718a1b2c3d4e5f60718  host  www.example.co.uk

echo "=== The cache key keeps the shape and drops the pin ==="
# Two names that differ only in shape resolve to different URLs, so they must
# not share an app directory; two that differ only in pin are one app at a new
# version, and must.
assert_field app-toy-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718 app app-toy-example-com-1
assert_field app-toy-example-com-3a1b2c3d4e5f60718a1b2c3d4e5f60718 app app-toy-example-com-3
assert_field app-toy-example-com-3ffffffffffffffffffffffffffffffff app app-toy-example-com-3

echo "=== Rejected specs ==="
# Each of these has exactly one thing wrong with it. The pins are all at or
# above the floor unless the pin is the point, so a case written to measure the
# shape character or the case of a hex digit cannot start passing because the
# name got short.
assert_reject app-example-com
assert_reject App-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject app-example-com-1A1B2C3D4E5F60718A1B2C3D4E5F60718
assert_reject app.example.com.1a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject app-example-com-xa1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject app-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f6071g
assert_reject app--example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject -example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject netinstall

echo "=== Shapes 4 through f are unassigned, and every one of them refuses ==="
# The reserved range is where a second digest algorithm goes. Until it does,
# a name carrying one of these must refuse rather than resolve somewhere.
for shape in 4 5 6 7 8 9 a b c d e f; do
    assert_reject "app-toy-example-com-${shape}a1b2c3d4e5f60718a1b2c3d4e5f60718"
done

echo "=== A shape that eats the host is refused, not resolved ==="
# The one miscount the parser can catch. The others resolve to a well-formed
# URL that is not the one meant, and the pin is what catches those.
assert_reject calc-2a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject calc-toy-3a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_url    calc-toy-2a1b2c3d4e5f60718a1b2c3d4e5f60718 "https://toy/calc/netinstall.cmd"

echo "=== The pin floor, at both ends ==="
# Measured on all five reporting lanes before the floor moved: 16 through 64
# was accepted and 15 and 65 were not. Asserted to the length it is now, from
# both sides, because a floor nothing tests is a constant somebody lowers.
assert_reject app-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f6071          # 31, short on purpose
assert_url    app-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718      "https://example.com/app.cmd"  # 32
assert_url    app-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718 \
    "https://example.com/app.cmd"                                       # 64
assert_reject app-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a                          # 65
assert_reject app-example-com-1a1b2c3d4e5f60718   # 16, short on purpose, and it used to work
assert_reject app-example-com-1a1b2c3d4e5f6071                          # 15, short on purpose

echo "=== A refusal by length says so ==="
# The person most likely to see this is holding a binary that ran yesterday.
as app-example-com-1a1b2c3d4e5f60718                                    # short on purpose
SHORTERR="$("$WORK/bin/app-example-com-1a1b2c3d4e5f60718$NT_EXE" --info 2>&1 >/dev/null)"  # short on purpose
case "$SHORTERR" in
    *"the pin is 16 hex characters and the minimum is 32"*)
        echo "  PASS: the short-pin refusal names the pin and both numbers" ;;
    *)
        nt_fail "short-pin refusal expected=names-the-pin actual=$(printf '%s' "$SHORTERR" | tr '\n' ' ' | cut -c1-160)"
        FAILURES=$((FAILURES + 1)) ;;
esac

echo "=== A refusal by shape says which shape ==="
as app-toy-example-com-7a1b2c3d4e5f60718a1b2c3d4e5f60718
SHAPEERR="$("$WORK/bin/app-toy-example-com-7a1b2c3d4e5f60718a1b2c3d4e5f60718$NT_EXE" --info 2>&1 >/dev/null)"
case "$SHAPEERR" in
    *"shape '7' is not one this build knows"*)
        echo "  PASS: the unassigned-shape refusal names the shape" ;;
    *)
        nt_fail "shape refusal expected=names-the-shape actual=$(printf '%s' "$SHAPEERR" | tr '\n' ' ' | cut -c1-160)"
        FAILURES=$((FAILURES + 1)) ;;
esac

echo "=== .exe suffix is stripped ==="
if [ "$NT_WINDOWS" = "1" ]; then
    echo "  SKIP: every binary already carries .exe here"
else
    assert_url app-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718.exe "https://example.com/app.cmd"
fi

# --- a downloader's suffix on an already-present name ------------------------
# The name is the spec, so a browser's "(1)" lands inside the pin and the file
# refuses to run. The copy that is inert is always the *new* one, so a user who
# re-downloads after a release keeps launching the old binary and is told
# nothing -- which is how a splash that had shipped went unnoticed for a day.
#
# What needs asserting is not the rescue, it is everything the rescue must not
# reach. The first rule tried here was "the pin ends where hex ends, discard the
# rest", and it passed every case in the first block below while quietly
# enforcing 60 characters of a 64 character pin whose typo was 'ABCD' -- because
# a mistyped pin also ends where hex ends. Narrowing the cut to characters
# outside the spec charset did not help; 'A' and '+' are outside it too. So the
# refusals below are the point of this block, and the case classes are the ones
# that actually broke it: lowercase, uppercase, and punctuation.
P32="a1b2c3d4e5f60718a1b2c3d4e5f60718"
P60="$(printf 'a%.0s' $(seq 1 60))"
P40="$(printf 'a%.0s' $(seq 1 40))"

echo "=== A second download runs, under the name without the suffix ==="
assert_url "app-example-com-1$P32(1)"       "https://example.com/app.cmd"  # firefox
assert_url "app-example-com-1$P32 (1)"      "https://example.com/app.cmd"  # chrome
assert_url "app-example-com-1$P32 2"        "https://example.com/app.cmd"  # finder
assert_url "app-example-com-1$P32 copy"     "https://example.com/app.cmd"  # finder
assert_url "app-example-com-1$P32 copy 2"   "https://example.com/app.cmd"  # finder
assert_url "app-example-com-1$P32.1"        "https://example.com/app.cmd"  # wget
# The suffix must not reach the cache key, or one app gets two app dirs and the
# second download re-fetches what the first already holds.
assert_field "app-example-com-1$P32(1)" token "1$P32"

echo "=== ...and it says so, rather than running as if it were the only copy ==="
as "app-example-com-1$P32(1)"
if "$WORK/bin/app-example-com-1$P32(1)$NT_EXE" --info 2>&1 >/dev/null | grep -qa "duplicate"; then
    echo "  PASS: the duplicate names itself on stderr"
else
    nt_fail "a decorated name ran without saying it was a duplicate"
    FAILURES=$((FAILURES + 1))
fi

echo "=== A mistyped pin is refused, whatever the typo is made of ==="
# Each of these is a 64-character pin with the last four characters wrong. A
# rule that trims at the end of the hex run accepts all three, enforces 60
# characters, and says nothing.
assert_reject "app-example-com-1${P60}gbbb"     # lowercase: a spec character
assert_reject "app-example-com-1${P60}ABCD"     # uppercase: measured at 60
assert_reject "app-example-com-1${P60}+ext"     # punctuation: measured at 32
assert_reject "app-example-com-1${P40}gbbb"
assert_reject "app-example-com-1${P32}+extra"

echo "=== A refusal in this area says which character and what to do ==="
# Everything the duplicate grammar declines to recognise lands in the charset
# loop, and that loop used to refuse with nothing under it. Explorer's " - Copy"
# is the shape that gets there most often.
as "app-example-com-1$P32 - Copy"
COPYERR="$("$WORK/bin/app-example-com-1$P32 - Copy$NT_EXE" --info 2>&1 >/dev/null)"
case "$COPYERR" in
    *"the name has a ' ' in it"*"rename the file"*)
        echo "  PASS: an unrecognised suffix names the character and the fix" ;;
    *)
        nt_fail "explorer-copy refusal expected=names-the-character actual=$(printf '%s' "$COPYERR" | tr '\n' ' ' | cut -c1-160)"
        FAILURES=$((FAILURES + 1)) ;;
esac

# Safari's "-1" cannot be trimmed -- the dash makes it a segment, so the segment
# becomes the token. The refusal must not then blame the publisher's digest for
# being too short, which is where it pointed before.
as "app-example-com-1$P32-1"
SAFARIERR="$("$WORK/bin/app-example-com-1$P32-1$NT_EXE" --info 2>&1 >/dev/null)"
case "$SAFARIERR" in
    *"a shape with no pin behind it"*"second download"*)
        echo "  PASS: a \"-1\" refusal blames the suffix, not the digest" ;;
    *)
        nt_fail "safari refusal expected=blames-the-suffix actual=$(printf '%s' "$SAFARIERR" | tr '\n' ' ' | cut -c1-160)"
        FAILURES=$((FAILURES + 1)) ;;
esac

echo "=== The sibling it points at is a file that could exist ==="
# The name on disk keeps the extension the parse stripped, so the "is still
# beside it" line has to put it back or it sends a windows user after a file
# nobody has.
as "app-example-com-1$P32(1).exe"
EXEMSG="$("$WORK/bin/app-example-com-1$P32(1).exe$NT_EXE" --info 2>&1 >/dev/null)"
case "$EXEMSG" in
    *"named \"app-example-com-1$P32.exe\" is still beside it"*)
        echo "  PASS: the sibling keeps the extension" ;;
    *)
        nt_fail "sibling expected=keeps-.exe actual=$(printf '%s' "$EXEMSG" | tr '\n' ' ' | cut -c1-200)"
        FAILURES=$((FAILURES + 1)) ;;
esac

echo "=== A tail that is not a downloader's marker is left to be refused ==="
# .bak is a person renaming a file, not a downloader keeping two. The narrow
# grammar is what makes the refusals above hold, so its edges are asserted
# rather than assumed.
assert_reject "app-example-com-1$P32.bak"
assert_reject "app-example-com-1$P32 backup"
assert_reject "app-example-com-1$P32()"
assert_reject "app-example-com-1$P32(x)"
assert_reject "app-example-com-1$P32-1"                                  # safari
assert_reject "app-example-com-1$(printf 'a%.0s' $(seq 1 31))(1)"        # short pin

echo "=== Symlinks resolve to the real name, never the link ==="
if [ "$NT_WINDOWS" = "1" ]; then
    echo "  SKIP: symlinks need privilege on windows"
else
    as real-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718
    ln -sf "$WORK/bin/real-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718" "$WORK/bin/fake-evil-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718"
    actual="$("$WORK/bin/fake-evil-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718" --info 2>/dev/null | awk '$1 == "url" { print $2 }')"
    if [ "$actual" = "https://example.com/real.cmd" ]; then
        echo "  PASS: symlink resolved to real.cmd, not the link name"
    else
        nt_fail "symlink expected=https://example.com/real.cmd actual=${actual:-<none>}"
        FAILURES=$((FAILURES + 1))
    fi
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
