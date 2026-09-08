#!/bin/bash
# verify.sh - assert the pin and payload checks accept and reject correctly
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: verify.sh <netinstall binary built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"
# harness.sh after lib.sh, and the order is the mechanism rather than a style.
# Both define nt_fail and they do not agree: lib.sh's takes a message, harness.sh's
# takes a case id and a detail, counts, and files a row. This file speaks the
# second, so it is sourced second -- and every call below carries an id, because
# one that did not would file its message as the name of a case.
#
# splash.sh is the worked example and this is the second suite through it. The
# conversion goes one file at a time on purpose, which is why this is a source
# here rather than a change to lib.sh: the other suites in this directory still
# speak lib.sh's nt_fail and must keep working while they do.
. "$(cd "$(dirname "$0")/../../test/lib" && pwd)/harness.sh"
# The annotation lib.sh's nt_fail emitted, kept by name so a red netinstall check
# still says so on the run page.
NT_ANNOTATE=netinstall

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

# Serves $2 as $1.cmd and names the binary after its real pin unless $3 overrides.
spec_for() {
    local name="$1" file="$2" pin="${3:-}"
    cp "$file" "$SERVE/$name.cmd"
    [ -n "$pin" ] || pin="$(nt_pin "$file")"
    echo "$name-example-com-1$pin"
}

run() {
    local spec="$1"; shift
    "$(nt_as "$BIN" "$spec" "$WORK/bin")" "$@"
}

cached_path() {
    echo "$NEUTRINO_HOME/apps/$(nt_appkey "$1")/${1%%-*}.cmd"
}

# The id first and the sentence after it, in both helpers. Four of the five
# rejections below differ only in their fixture, so the sentence was the only
# thing telling them apart -- and a sentence is what the grid could not use.
assert_accept() {
    local id="$1" label="$2" spec="$3"
    if run "$spec" --fetch >/dev/null 2>&1 && [ -f "$(cached_path "$spec")" ]; then
        nt_pass "$id" "$label accepted and cached"
    else
        nt_fail "$id" "$label expected=accepted+cached actual=rejected"
    fi
}

assert_reject() {
    local id="$1" label="$2" spec="$3"
    if run "$spec" --fetch >/dev/null 2>&1; then
        nt_fail "$id" "$label expected=rejected actual=accepted"
    elif [ -f "$(cached_path "$spec")" ]; then
        nt_fail "$id" "$label expected=nothing-cached actual=cached"
    else
        nt_pass "$id" "$label rejected, nothing cached"
    fi
}

echo "=== Fixtures ==="
printf 'echo hello from a neutrino app\n' > "$WORK/good.cmd"
printf 'echo nul\0here\n' > "$WORK/nul.cmd"
printf '\177ELF\002\001\001\000\000\000\000\000' > "$WORK/elf.bin"
# Not python: on windows nt_python is the native interpreter, which cannot open
# an MSYS /tmp path, so this fixture was never created there and the oversized
# payload assertion below passed against a file that did not exist.
dd if=/dev/zero bs=1000000 count=17 2>/dev/null | tr '\0' 'a' > "$WORK/huge.cmd"
# Said either way, and it did not used to be. This spoke only on a failure, so
# the run where the fixture was missing and the run where it was fine printed
# the same `  ok` -- and the grid, which reads rows, saw neither. A guard nobody
# can see the result of is the shape of the defect it was written about.
if [ -s "$WORK/huge.cmd" ]; then
    nt_pass verify.fixture.oversized "the oversized fixture is $(wc -c < "$WORK/huge.cmd" | tr -d ' ') bytes"
else
    nt_fail verify.fixture.oversized "oversized fixture was not created; that assertion would be vacuous"
fi

echo "=== Happy path ==="
GOOD="$(spec_for good "$WORK/good.cmd")"
assert_accept verify.pin.accept "matching pin" "$GOOD"

echo "=== sha256 agrees with the system tool ==="
EXPECT="$(nt_sha256 "$WORK/good.cmd")"
ACTUAL="$(run "$GOOD" --verify 2>/dev/null | cut -d' ' -f1)"
if [ "$EXPECT" = "$ACTUAL" ]; then
    nt_pass verify.sha256.agrees "$ACTUAL"
else
    nt_fail verify.sha256.agrees "sha256 expected=$EXPECT actual=${ACTUAL:-<none>}"
fi

echo "=== Rejections ==="
MISMATCH="$(spec_for mismatch "$WORK/good.cmd" deadbeefdeadbeefdeadbeefdeadbeef)"
assert_reject verify.pin.reject       "pin mismatch"      "$MISMATCH"
assert_reject verify.payload.binary   "binary payload"    "$(spec_for elf "$WORK/elf.bin")"
assert_reject verify.payload.nul      "embedded nul"      "$(spec_for nul "$WORK/nul.cmd")"
assert_reject verify.payload.oversized "oversized payload" "$(spec_for huge "$WORK/huge.cmd")"
assert_reject verify.name.missing     "missing file"      "absent-example-com-1a1b2c3d4e5f60718a1b2c3d4e5f60718"

echo "=== The mismatch is refused for being a mismatch ==="
# Both literals above used to be sixteen characters, which the parser now
# refuses on sight. assert_reject only asks whether the exit code was non-zero,
# so this case would have gone on passing while never reaching the comparison
# it exists to make. Asserting the message is what keeps it honest.
MISERR="$(run "$MISMATCH" --fetch 2>&1 >/dev/null)"
case "$MISERR" in
    *"pin mismatch"*)
        nt_pass verify.pin.reason "refused as a pin mismatch, not as a name" ;;
    *)
        nt_fail verify.pin.reason "mismatch cause expected=pin-mismatch actual=$(printf '%s' "$MISERR" | tr '\n' ' ' | cut -c1-200)" ;;
esac

echo "=== Cached launch works with the server down ==="
kill $NT_SERVER_PID 2>/dev/null
wait $NT_SERVER_PID 2>/dev/null
if run "$GOOD" --fetch >/dev/null 2>&1; then
    nt_pass verify.cache.offline "second resolve served from cache"
else
    nt_fail verify.cache.offline "cached resolve expected=offline-ok actual=failed"
fi

echo "=== A tampered cache is refetched, not trusted ==="
chmod u+w "$(cached_path "$GOOD")"
echo 'echo pwned' > "$(cached_path "$GOOD")"
if run "$GOOD" --fetch >/dev/null 2>&1; then
    nt_fail verify.cache.tampered "tampered cache expected=rejected actual=accepted"
else
    nt_pass verify.cache.tampered "tampered cache rejected (server down, so refetch fails)"
fi

# $NT_FAILURES rather than a counter of this file's own: nt_fail counts, so the
# nine `FAILURES=$((FAILURES + 1))` lines that used to follow every call are
# gone. The sentence and the exit status are the ones this suite has always had.
echo "=== Results: $NT_FAILURES failure(s) ==="
exit $NT_FAILURES
