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

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE"
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0

# Serves $2 as $1.cmd and names the binary after its real pin unless $3 overrides.
spec_for() {
    local name="$1" file="$2" pin="${3:-}"
    cp "$file" "$SERVE/$name.cmd"
    [ -n "$pin" ] || pin="$(nt_pin "$file")"
    echo "$name-com-example-0$pin"
}

run() {
    local spec="$1"; shift
    "$(nt_as "$BIN" "$spec" "$WORK/bin")" "$@"
}

cached_path() {
    echo "$NEUTRINO_HOME/apps/$1/${1%%-*}.cmd"
}

assert_accept() {
    local label="$1" spec="$2"
    if run "$spec" --fetch >/dev/null 2>&1 && [ -f "$(cached_path "$spec")" ]; then
        echo "  PASS: $label accepted and cached"
    else
        nt_fail "$label expected=accepted+cached actual=rejected"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_reject() {
    local label="$1" spec="$2"
    if run "$spec" --fetch >/dev/null 2>&1; then
        nt_fail "$label expected=rejected actual=accepted"
        FAILURES=$((FAILURES + 1))
    elif [ -f "$(cached_path "$spec")" ]; then
        nt_fail "$label expected=nothing-cached actual=cached"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: $label rejected, nothing cached"
    fi
}

echo "=== Fixtures ==="
printf 'echo hello from a neutrino app\n' > "$WORK/good.cmd"
printf 'echo nul\0here\n' > "$WORK/nul.cmd"
printf '\177ELF\002\001\001\000\000\000\000\000' > "$WORK/elf.bin"
"$(nt_python)" -c "open(r'$WORK/huge.cmd','w').write('a' * 17000000)"
echo "  ok"

echo "=== Happy path ==="
GOOD="$(spec_for good "$WORK/good.cmd")"
assert_accept "matching pin" "$GOOD"

echo "=== sha256 agrees with the system tool ==="
EXPECT="$(nt_sha256 "$WORK/good.cmd")"
ACTUAL="$(run "$GOOD" --verify 2>/dev/null | cut -d' ' -f1)"
if [ "$EXPECT" = "$ACTUAL" ]; then
    echo "  PASS: $ACTUAL"
else
    nt_fail "sha256 expected=$EXPECT actual=${ACTUAL:-<none>}"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Rejections ==="
assert_reject "pin mismatch"      "$(spec_for mismatch "$WORK/good.cmd" deadbeefdeadbeef)"
assert_reject "binary payload"    "$(spec_for elf "$WORK/elf.bin")"
assert_reject "embedded nul"      "$(spec_for nul "$WORK/nul.cmd")"
assert_reject "oversized payload" "$(spec_for huge "$WORK/huge.cmd")"
assert_reject "missing file"      "absent-com-example-0a1b2c3d4e5f60718"

echo "=== Cached launch works with the server down ==="
kill $NT_SERVER_PID 2>/dev/null
wait $NT_SERVER_PID 2>/dev/null
if run "$GOOD" --fetch >/dev/null 2>&1; then
    echo "  PASS: second resolve served from cache"
else
    nt_fail "cached resolve expected=offline-ok actual=failed"
    FAILURES=$((FAILURES + 1))
fi

echo "=== A tampered cache is refetched, not trusted ==="
chmod u+w "$(cached_path "$GOOD")"
echo 'echo pwned' > "$(cached_path "$GOOD")"
if run "$GOOD" --fetch >/dev/null 2>&1; then
    nt_fail "tampered cache expected=rejected actual=accepted"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: tampered cache rejected (server down, so refetch fails)"
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
