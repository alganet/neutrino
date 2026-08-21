#!/bin/bash
# privs.sh - what privileges does the confined token on windows actually keep?
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Recording, not asserting. nt_strip_privileges means to remove every privilege
# but SeChangeNotifyPrivilege and to keep that one enabled, because path
# traversal needs it. Whether it does is a question only a process running under
# the adjusted token can answer, and confine.sh does not run payloads here --
# its whole payload is sh and windows launches through cmd.exe. So this is the
# windows half of the same measurement, in the shape windows can answer it.
#
# PR 4 promotes what this prints into two checks.

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: privs.sh <netinstall binary built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"

if [ "$NT_WINDOWS" != "1" ]; then
    echo "=== SKIP: token privileges are a windows question ==="
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0

# whoami /priv is the only tool here that distinguishes the three states this
# needs to tell apart: enabled, disabled, and absent. A removed privilege does
# not appear in the list at all, which is what makes "the list has one entry"
# an answerable question.
#
# By absolute path, and with the same literal C:\Windows fallback nt_exec uses
# for cmd.exe. Bare "whoami" is not the windows one here: the suite runs under
# git-bash and hands cmd.exe a PATH with git's coreutils on it, whose whoami
# takes no arguments and answered nothing at all the first time this ran.
cat > "$SERVE/privs.cmd" <<'BATCH'
@echo off
echo PRIV_BEGIN
set NTWHO=%SystemRoot%\System32\whoami.exe
if not exist "%NTWHO%" set NTWHO=C:\Windows\System32\whoami.exe
"%NTWHO%" /priv
echo PRIV_END
BATCH

SPEC="privs-com-example-0$(nt_pin "$SERVE/privs.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"

# "SeFooPrivilege  Some description  Enabled" becomes "SeFoo=E", so a whole
# privilege set fits in one annotation -- which is the only channel out of CI
# that survives the trip.
nt_priv_list() {
    tr -d '\r' | awk '/Se[A-Za-z]+Privilege/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Se[A-Za-z]+Privilege$/) {
                name = $i
                sub(/Privilege$/, "", name)
                printf "%s=%s ", name, substr($NF, 1, 1)
            }
        }
    }'
}

# What the parse saw, when it saw nothing usable. An empty list has two very
# different causes -- a token with no privileges left, and a whoami that never
# answered -- and the first round of this probe could not tell them apart
# because bash's PATH put git's coreutils whoami ahead of the windows one.
nt_priv_raw() {
    tr -d '\r' | tr '\n' '/' | tr -cd '[:print:]' | cut -c1-220
}

echo "=== The token before netinstall touches it ==="
# Through a file rather than as an argument: MSYS rewrites anything on a
# command line that looks like a path, and "/priv" looks exactly like one.
# A windows path to a batch file is the one thing it leaves alone.
cp "$SERVE/privs.cmd" "$WORK/priv.bat"
CONTROL_RAW="$(cmd //c "$(cygpath -w "$WORK/priv.bat")" 2>&1)"
CONTROL="$(nt_priv_list <<<"$CONTROL_RAW")"
CONTROL_N="$(wc -w <<<"$CONTROL" | tr -d ' ')"
echo "  $CONTROL_N privilege(s): $CONTROL"

echo "=== The token the payload actually runs with ==="
OUT="$(nt_timeout 120 "$APP" 2>"$WORK/err" | tr -d '\r')"
CONFINED="$(sed -n '/^PRIV_BEGIN/,/^PRIV_END/p' <<<"$OUT" | nt_priv_list)"
CONFINED_N="$(wc -w <<<"$CONFINED" | tr -d ' ')"
echo "  $CONFINED_N privilege(s): $CONFINED"

# The one thing this suite does gate on: a payload that never ran measures
# nothing, and an empty privilege list is exactly what that looks like.
if grep -q PRIV_END <<<"$OUT"; then
    echo "  PASS: the payload ran under the adjusted token"
else
    nt_fail "payload expected=ran actual=$(tr '\n' ' ' <<<"$OUT") err=$(tr '\n' ' ' < "$WORK/err")"
    FAILURES=$((FAILURES + 1))
fi
# The control is what makes the confined list mean anything: an empty list
# reads the same whether every privilege was removed or whoami never answered,
# and SeChangeNotify has to have been enabled beforehand for "it is disabled
# now" to be a statement about netinstall rather than about the runner.
if [ "$CONTROL_N" -gt 0 ]; then
    echo "  PASS: the unconfined token had privileges to strip ($CONTROL_N)"
else
    nt_fail "control expected=some privileges actual=none; whoami /priv did not answer"
    FAILURES=$((FAILURES + 1))
fi
if grep -q 'SeChangeNotify=E' <<<"$CONTROL"; then
    echo "  PASS: SeChangeNotifyPrivilege was enabled before netinstall ran"
else
    nt_fail "control expected=SeChangeNotify=E actual=$CONTROL"
    FAILURES=$((FAILURES + 1))
fi

# The second half of finding 4: AdjustTokenPrivileges returns TRUE on
# ERROR_NOT_ALL_ASSIGNED, so --info can claim a stripping that did not happen.
# --info reports the description for enforce=0, where the phrase is a constant,
# so this records what it claims rather than pretending to have caught it.
INFO="$("$APP" --info 2>/dev/null | tr -d '\r' |
    awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
CLAIMS=no
grep -q 'privileges stripped' <<<"$INFO" && CLAIMS=yes

echo "=== Measured for PR 4, not asserted ==="
if [ "$CONTROL_N" -gt 0 ]; then
    nt_result "PR4 before-state control: n=$CONTROL_N [$CONTROL]"
else
    nt_result "PR4 control did not answer; raw: $(nt_priv_raw <<<"$CONTROL_RAW")"
fi
if [ "$CONFINED_N" -gt 0 ]; then
    nt_result "PR4 before-state confined: n=$CONFINED_N [$CONFINED] --info-claims-stripped=$CLAIMS"
else
    nt_result "PR4 confined list is empty (--info-claims-stripped=$CLAIMS); raw: $(nt_priv_raw <<<"$OUT")"
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
