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

echo "=== Accepted specs ==="
assert_url neutrino-io-github-alganet-0a1b2c3d4e5f60718a1b2c3d4e5f60718 "https://alganet.github.io/neutrino.cmd"
assert_url app-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718           "https://example.com/app.cmd"
assert_url app-uk-co-example-www-0a1b2c3d4e5f60718a1b2c3d4e5f60718     "https://www.example.co.uk/app.cmd"
assert_url app-localhost-0a1b2c3d4e5f60718a1b2c3d4e5f60718             "https://localhost/app.cmd"
assert_url my_app-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718        "https://example.com/my-app.cmd"
assert_url app-com-my_site-0a1b2c3d4e5f60718a1b2c3d4e5f60718           "https://my-site.com/app.cmd"
assert_url app-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718 "https://example.com/app.cmd"

echo "=== Parsed fields ==="
assert_field neutrino-io-github-alganet-0a1b2c3d4e5f60718a1b2c3d4e5f60718 name  neutrino
assert_field neutrino-io-github-alganet-0a1b2c3d4e5f60718a1b2c3d4e5f60718 host  alganet.github.io
assert_field neutrino-io-github-alganet-0a1b2c3d4e5f60718a1b2c3d4e5f60718 token 0a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_field app-uk-co-example-www-0a1b2c3d4e5f60718a1b2c3d4e5f60718     host  www.example.co.uk

echo "=== Rejected specs ==="
# Each of these has exactly one thing wrong with it. The pins are all at or
# above the floor unless the pin is the point, so a case written to measure the
# version character or the case of a hex digit cannot start passing because the
# name got short.
assert_reject app-0a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject app-com-example
assert_reject App-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject app-com-example-0A1B2C3D4E5F60718A1B2C3D4E5F60718
assert_reject app.com.example.0a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject app-com-example-1a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject app-com-example-xa1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject app-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f6071g
assert_reject app--com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject -com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718
assert_reject netinstall

echo "=== The pin floor, at both ends ==="
# Measured on all five reporting lanes before the floor moved: 16 through 64
# was accepted and 15 and 65 were not. Asserted to the length it is now, from
# both sides, because a floor nothing tests is a constant somebody lowers.
assert_reject app-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f6071          # 31, short on purpose
assert_url    app-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718      "https://example.com/app.cmd"  # 32
assert_url    app-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718 \
    "https://example.com/app.cmd"                                       # 64
assert_reject app-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a                          # 65
assert_reject app-com-example-0a1b2c3d4e5f60718   # 16, short on purpose, and it used to work
assert_reject app-com-example-0a1b2c3d4e5f6071                          # 15, short on purpose

echo "=== A refusal by length says so ==="
# The person most likely to see this is holding a binary that ran yesterday.
as app-com-example-0a1b2c3d4e5f60718                                    # short on purpose
SHORTERR="$("$WORK/bin/app-com-example-0a1b2c3d4e5f60718$NT_EXE" --info 2>&1 >/dev/null)"  # short on purpose
case "$SHORTERR" in
    *"the pin is 16 hex characters and the minimum is 32"*)
        echo "  PASS: the short-pin refusal names the pin and both numbers" ;;
    *)
        nt_fail "short-pin refusal expected=names-the-pin actual=$(printf '%s' "$SHORTERR" | tr '\n' ' ' | cut -c1-160)"
        FAILURES=$((FAILURES + 1)) ;;
esac

echo "=== .exe suffix is stripped ==="
if [ "$NT_WINDOWS" = "1" ]; then
    echo "  SKIP: every binary already carries .exe here"
else
    assert_url app-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718.exe "https://example.com/app.cmd"
fi

echo "=== Symlinks resolve to the real name, never the link ==="
if [ "$NT_WINDOWS" = "1" ]; then
    echo "  SKIP: symlinks need privilege on windows"
else
    as real-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718
    ln -sf "$WORK/bin/real-com-example-0a1b2c3d4e5f60718a1b2c3d4e5f60718" "$WORK/bin/fake-com-evil-0a1b2c3d4e5f60718a1b2c3d4e5f60718"
    actual="$("$WORK/bin/fake-com-evil-0a1b2c3d4e5f60718a1b2c3d4e5f60718" --info 2>/dev/null | awk '$1 == "url" { print $2 }')"
    if [ "$actual" = "https://example.com/real.cmd" ]; then
        echo "  PASS: symlink resolved to real.cmd, not the link name"
    else
        nt_fail "symlink expected=https://example.com/real.cmd actual=${actual:-<none>}"
        FAILURES=$((FAILURES + 1))
    fi
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
