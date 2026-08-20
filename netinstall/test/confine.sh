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
NEUTRINO_TEST_FAKEHOME="$HOME/.netinstall-confine-$$"
mkdir -p "$SERVE" "$WORK/bin" "$NEUTRINO_TEST_FAKEHOME"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK" "$NEUTRINO_TEST_FAKEHOME"' EXIT

FAILURES=0

# Writes outside the app dir, tries to overwrite its own launcher, then reports
# what the XDG redirection gave it.
cat > "$SERVE/hostile.cmd" <<'SCRIPT'
outside="$NEUTRINO_TEST_FAKEHOME/pwned"
if echo owned > "$outside" 2>/dev/null; then echo "ESCAPED_HOME"; else echo "BLOCKED_HOME"; fi
if echo owned > "$(dirname "$0")/hostile.cmd" 2>/dev/null; then echo "ESCAPED_LAUNCHER"; else echo "BLOCKED_LAUNCHER"; fi
if echo owned > "$XDG_DATA_HOME/ok" 2>/dev/null; then echo "OWN_DIR_WRITABLE"; else echo "OWN_DIR_BLOCKED"; fi
if cat /etc/hosts >/dev/null 2>&1; then echo "READS_WORK"; else echo "READS_BLOCKED"; fi
cp /bin/true "$XDG_DATA_HOME/probe" 2>/dev/null && chmod +x "$XDG_DATA_HOME/probe" 2>/dev/null
if "$XDG_DATA_HOME/probe" 2>/dev/null; then echo "EXEC_OWN_DIR"; else echo "EXEC_BLOCKED"; fi
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0))" 2>/dev/null; then echo "BIND_OK"; else echo "BIND_BLOCKED"; fi
else echo "BIND_SKIP"; fi
if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import ctypes, os
class Iov(ctypes.Structure):
    _fields_ = [(\"base\", ctypes.c_void_p), (\"len\", ctypes.c_size_t)]
libc = ctypes.CDLL(None, use_errno=True)
libc.process_vm_readv.restype = ctypes.c_ssize_t
libc.process_vm_readv.argtypes = [ctypes.c_int, ctypes.POINTER(Iov), ctypes.c_ulong,
                                  ctypes.POINTER(Iov), ctypes.c_ulong, ctypes.c_ulong]
dst = ctypes.create_string_buffer(8)
src = ctypes.create_string_buffer(b\"12345678\", 8)
a = Iov(ctypes.cast(dst, ctypes.c_void_p).value, 8)
b = Iov(ctypes.cast(src, ctypes.c_void_p).value, 8)
n = libc.process_vm_readv(os.getpid(), ctypes.byref(a), 1, ctypes.byref(b), 1, 0)
print(\"PEEK_OK\" if n == 8 else \"PEEK_BLOCKED\")
" 2>/dev/null || echo "PEEK_BLOCKED"
else echo "PEEK_SKIP"; fi
if [ -n "${NETINSTALL_FAKE_TOKEN:-}" ]; then echo "SECRET_INHERITED"; else echo "SECRET_SCRUBBED"; fi
if [ -n "${SSH_AUTH_SOCK:-}" ]; then echo "AGENT_INHERITED"; else echo "AGENT_SCRUBBED"; fi
if [ -n "${PATH:-}" ] && [ -n "${HOME:-}" ]; then echo "BASICS_KEPT"; else echo "BASICS_LOST"; fi
SCRIPT

SPEC="hostile-com-example-0$(nt_pin "$SERVE/hostile.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
export NEUTRINO_TEST_FAKEHOME
# Two things a filesystem sandbox cannot reach: a token that exists only as a
# variable, and a live agent socket. Both have to be gone by the time sh starts.
export NETINSTALL_FAKE_TOKEN="a-secret-that-only-lives-in-the-environment"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-/nonexistent/agent.sock}"

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

echo "=== The environment is an allowlist ==="
check "a token that lives only in the env is dropped" SECRET_SCRUBBED
check "the ssh agent socket is dropped"               AGENT_SCRUBBED
check "what a toolkit needs survives"                 BASICS_KEPT

if [ "$(uname -s)" = "Darwin" ]; then
    # Write xor execute: the one directory an app can write to is the one it
    # must not be able to run anything from. On linux this needs the exec
    # allowlist, so it lives in the tight tier and confine-strict.sh covers it.
    check "cannot execute what it wrote" EXEC_BLOCKED
else
    nt_note "w^x is tight-tier only on linux; got $(grep -o 'EXEC_[A-Z_]*' <<<"$OUT")"
fi

echo "=== Syscalls that reach across process boundaries ==="
case "$CONFINE" in
    *seccomp*)
        # process_vm_readv on your own memory always succeeds unfiltered, so a
        # refusal here is the filter and nothing else.
        check "cannot read another process's memory" PEEK_BLOCKED ;;
    *)
        nt_note "no seccomp filter here; got $(grep -o 'PEEK_[A-Z]*' <<<"$OUT")" ;;
esac

NT_ABI="$(grep -o 'abi [0-9]*' <<<"$CONFINE" | awk '{print $2}')"
if [ "$(uname -s)" = "Linux" ] && [ -n "$NT_ABI" ] && [ "$NT_ABI" -ge 4 ]; then
    check "cannot bind a TCP port" BIND_BLOCKED
elif [ "$(uname -s)" = "Linux" ]; then
    nt_note "tcp bind mediation needs landlock abi 4; this kernel reports ${NT_ABI:-none}"
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
