#!/bin/bash
# privs.sh - assert what the confined token on windows keeps, and what it buys
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# nt_strip_privileges removes every privilege but SeChangeNotifyPrivilege and
# keeps that one enabled, because path traversal needs it. Whether it does is a
# question only a process running under the adjusted token can answer, and
# confine.sh does not run payloads here -- its whole payload is sh and windows
# launches through cmd.exe. So this is the windows half of that measurement, in
# the shape windows can answer it.
#
# Two assertions and an instrument. The token half is cheap: whoami /priv is the
# only tool here that distinguishes the three states this has to tell apart --
# enabled, disabled, and absent -- because a removed privilege does not appear
# in the list at all. That makes "the list has one entry" an answerable question.
#
# The instrument is the half that matters. A flag being set is not the claim the
# comment makes; the claim is that traversal works. So the payload is pointed at
# a directory the current user is explicitly denied (X) on, with a readable file
# underneath it. Bypass traverse checking is exactly the check that ACE imposes,
# so SeChangeNotifyPrivilege is the only thing that can make that read succeed.
# Before the attribute was fixed this read TRAVERSE_DENIED on a windows-latest
# runner, with everything else about the run identical.

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
mkdir -p "$SERVE" "$WORK/bin" "$WORK/trav/leaf" "$WORK/ctl"
export NEUTRINO_HOME="$WORK/home"

FAILURES=0

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
nt_raw() {
    tr -d '\r' | tr '\n' '/' | tr -cd '[:print:]' | cut -c1-200
}

# =====================================================================
# The instrument: a path the runner's own token cannot walk.
# =====================================================================
echo "TRAVERSE_TARGET" > "$WORK/trav/leaf/target.txt"
echo "CONTROL_TARGET"  > "$WORK/ctl/target.txt"

TRAV_DIR_W="$(cygpath -w "$WORK/trav")"
TRAV_W="$(cygpath -w "$WORK/trav/leaf/target.txt")"
CTL_W="$(cygpath -w "$WORK/ctl/target.txt")"

# Through a batch file: MSYS rewrites anything on a command line that looks like
# a path, and "/deny" looks exactly like one. %USERNAME% resolves inside cmd, so
# the account never has to make the trip through git-bash's whoami either.
#
# (X) is execute/traverse and nothing else, with no inheritance flags, so the
# leaf and the file under it keep the DACL they were created with. The read has
# to fail on the walk or not at all.
cat > "$WORK/lock.bat" <<BATCH
@echo off
icacls "$TRAV_DIR_W" /deny "%USERNAME%:(X)"
echo LOCK_RC=%ERRORLEVEL%
BATCH
cat > "$WORK/unlock.bat" <<BATCH
@echo off
icacls "$TRAV_DIR_W" /remove:d "%USERNAME%" >nul 2>&1
BATCH
LOCK_OUT="$(cmd //c "$(cygpath -w "$WORK/lock.bat")" 2>&1 | tr -d '\r')"

cleanup() {
    kill ${NT_SERVER_PID:-} 2>/dev/null
    cmd //c "$(cygpath -w "$WORK/unlock.bat")" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== Denying traverse on $TRAV_DIR_W ==="
echo "$LOCK_OUT" | sed 's/^/  /'
if grep -q 'LOCK_RC=0' <<<"$LOCK_OUT"; then
    echo "  PASS: the deny ACE was applied"
else
    nt_fail "icacls /deny expected=LOCK_RC=0 actual=$(nt_raw <<<"$LOCK_OUT")"
    FAILURES=$((FAILURES + 1))
fi

# =====================================================================
# The payload: what token am I, and can I walk that path?
# =====================================================================
#
# By absolute path, and with the same literal C:\Windows fallback nt_exec uses
# for cmd.exe. Bare "whoami" is not the windows one here: the suite runs under
# git-bash and hands cmd.exe a PATH with git's coreutils on it, whose whoami
# takes no arguments and answered nothing at all the first time this ran.
# =====================================================================
# The windows half of PR 9's reach question
# =====================================================================
#
# env.c's windows allowlist is names plus one prefix (PROCESSOR_), so unlike the
# unix side it admits no toolkit namespace at all -- and the loader knobs that
# matter here are not toolkit-shaped anyway. WEBVIEW2_BROWSER_EXECUTABLE_FOLDER
# names the folder the WebView2 browser process is loaded from,
# WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS is appended to that process's command
# line, and the COR_/DOTNET_ family injects into the .NET runtime jsc.exe
# compiles with. If any of them arrives, the allowlist admits on windows exactly
# what env.sh is measuring on the other two platforms.
#
# Measured before anything was written, and the answer was that none of them
# arrive: windows admits one prefix and it is PROCESSOR_. So PR 9 changes no
# windows behaviour and this is a regression assertion rather than a fix --
# a prefix added here later would have to answer for it.
#
# PATH is in the battery because it is kept out of necessity and windows
# resolves DLLs along it. That one is asserted to *arrive*, so the pair reads
# as what it is: the one loader-shaped name this platform cannot drop.
export NEUTRINO_TEST_BATTERY="WEBVIEW2_BROWSER_EXECUTABLE_FOLDER \
WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS WEBVIEW2_USER_DATA_FOLDER \
WEBVIEW2_RELEASE_CHANNEL_PREFERENCE COR_ENABLE_PROFILING COR_PROFILER \
COR_PROFILER_PATH COMPlus_ZapDisable DOTNET_STARTUP_HOOKS __COMPAT_LAYER \
PATH PROCESSOR_ARCHITECTURE NT_ENV_CONTROL_DROPPED NEUTRINO_ENV_CONTROL_KEPT"

# Inert values on purpose: the enable flag is 0 and the CLSID is the null one,
# so nothing is loaded by setting these -- the question is whether the name
# arrives, not what it would have done.
NT_ENV_SET=(
    "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER=C:\\nonexistent\\neutrino-probe"
    "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox"
    "WEBVIEW2_USER_DATA_FOLDER=C:\\nonexistent\\neutrino-probe"
    "WEBVIEW2_RELEASE_CHANNEL_PREFERENCE=1"
    "COR_ENABLE_PROFILING=0"
    "COR_PROFILER={00000000-0000-0000-0000-000000000000}"
    "COR_PROFILER_PATH=C:\\nonexistent\\neutrino-probe.dll"
    "COMPlus_ZapDisable=0"
    "DOTNET_STARTUP_HOOKS=C:\\nonexistent\\neutrino-probe.dll"
    "__COMPAT_LAYER=RunAsInvoker"
    "NT_ENV_CONTROL_DROPPED=dropped-control"
    "NEUTRINO_ENV_CONTROL_KEPT=kept-control"
)

cat > "$SERVE/privs.cmd" <<BATCH
@echo off
echo PRIV_BEGIN
set NTWHO=%SystemRoot%\\System32\\whoami.exe
if not exist "%NTWHO%" set NTWHO=C:\\Windows\\System32\\whoami.exe
"%NTWHO%" /priv
echo PRIV_END
type "$CTL_W" >nul 2>&1
if errorlevel 1 (echo CONTROL_DENIED) else (echo CONTROL_OK)
type "$TRAV_W" >nul 2>&1
if errorlevel 1 (echo TRAVERSE_DENIED) else (echo TRAVERSE_OK)
for %%V in (%NEUTRINO_TEST_BATTERY%) do (if defined %%V (echo env %%V SEEN) else (echo env %%V GONE))
echo PROBE_END
BATCH

nt_serve "$SERVE" || exit 2
SPEC="privs-com-example-0$(nt_pin "$SERVE/privs.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"

# =====================================================================
# The control: the same payload, no netinstall in the way.
# =====================================================================
echo "=== The token before netinstall touches it ==="
cp "$SERVE/privs.cmd" "$WORK/control.bat"
CONTROL_RAW="$(env "${NT_ENV_SET[@]}" cmd //c "$(cygpath -w "$WORK/control.bat")" 2>&1 | tr -d '\r')"
CONTROL="$(sed -n '/^PRIV_BEGIN/,/^PRIV_END/p' <<<"$CONTROL_RAW" | nt_priv_list)"
CONTROL_N="$(wc -w <<<"$CONTROL" | tr -d ' ')"
CONTROL_TRAV="$(grep -o 'TRAVERSE_[A-Z]*' <<<"$CONTROL_RAW" | head -1)"
CONTROL_CTL="$(grep -o 'CONTROL_[A-Z]*' <<<"$CONTROL_RAW" | head -1)"
echo "  $CONTROL_N privilege(s): $CONTROL"
echo "  $CONTROL_CTL $CONTROL_TRAV"

# =====================================================================
# The measurement.
# =====================================================================
echo "=== The token the payload actually runs with ==="
OUT="$(nt_timeout 180 env "${NT_ENV_SET[@]}" "$APP" 2>"$WORK/err" | tr -d '\r')"
CONFINED="$(sed -n '/^PRIV_BEGIN/,/^PRIV_END/p' <<<"$OUT" | nt_priv_list)"
CONFINED_N="$(wc -w <<<"$CONFINED" | tr -d ' ')"
CONFINED_TRAV="$(grep -o 'TRAVERSE_[A-Z]*' <<<"$OUT" | head -1)"
CONFINED_CTL="$(grep -o 'CONTROL_[A-Z]*' <<<"$OUT" | head -1)"
echo "  $CONFINED_N privilege(s): $CONFINED"
echo "  $CONFINED_CTL $CONFINED_TRAV"

pass() { echo "  PASS: $1"; }
fail() { nt_fail "$1"; FAILURES=$((FAILURES + 1)); }

# --- the controls, first: nothing below means anything without them ---
#
# A payload that never ran measures nothing, and an empty privilege list is
# exactly what that looks like.
if grep -q PROBE_END <<<"$OUT"; then
    pass "the payload ran under the adjusted token"
else
    fail "payload expected=ran actual=$(nt_raw <<<"$OUT") err=$(nt_raw < "$WORK/err")"
fi
# An empty list reads the same whether every privilege was removed or whoami
# never answered, and SeChangeNotify has to have been enabled beforehand for
# anything said about it afterwards to be about netinstall rather than the
# runner.
if [ "$CONTROL_N" -gt 0 ]; then
    pass "the unconfined token had privileges to strip ($CONTROL_N)"
else
    fail "control expected=some privileges actual=none; whoami /priv did not answer"
fi
if grep -q 'SeChangeNotify=E' <<<"$CONTROL"; then
    pass "SeChangeNotifyPrivilege was enabled before netinstall ran"
else
    fail "control expected=SeChangeNotify=E actual=$CONTROL"
fi
# The instrument's own two controls. Without the first, a blanket TRAVERSE_DENIED
# could be "type" failing for reasons of its own; without the second, it could be
# an ACE that denies more than traverse, and either way the assertion below would
# be measuring something other than the privilege.
if [ "$CONFINED_CTL" = "CONTROL_OK" ]; then
    pass "the confined payload can read a file nothing denies"
else
    fail "control read expected=CONTROL_OK actual=$CONFINED_CTL"
fi
if [ "$CONTROL_TRAV" = "TRAVERSE_OK" ]; then
    pass "the unconfined token walks the denied path"
else
    fail "instrument expected=TRAVERSE_OK unconfined actual=$CONTROL_TRAV; \
the ACE denies more than traverse and the assertion below is void"
fi

# --- what PR 4 changed ---
#
# Both of these read the other way before the attribute was fixed: the privilege
# came out Disabled, and the walk was refused.
if grep -q 'SeChangeNotify=E' <<<"$CONFINED"; then
    pass "SeChangeNotifyPrivilege survives and stays enabled (CHANGENOTIFY_ENABLED)"
else
    fail "CHANGENOTIFY_ENABLED expected=SeChangeNotify=E actual=$CONFINED"
fi
if [ "$CONFINED_N" = "1" ]; then
    pass "every other privilege is removed (OTHERS_REMOVED)"
else
    fail "OTHERS_REMOVED expected=1 privilege actual=$CONFINED_N [$CONFINED]"
fi
if [ "$CONFINED_TRAV" = "TRAVERSE_OK" ]; then
    pass "the kept privilege still bypasses traverse checking"
else
    fail "traverse expected=TRAVERSE_OK actual=$CONFINED_TRAV; \
SeChangeNotifyPrivilege is present but not doing what it is kept for"
fi

# --- and what --info says about it ---
#
# The phrase used to be a constant inside the format string, so --info promised
# a stripping whatever the token turned out to be. It is now built from the same
# call the enforcing path uses, with the adjustment skipped, so the two have to
# agree: if the token could not be read the phrase is absent, and if it could
# then the confined run below removed the other privileges.
INFO="$("$APP" --info 2>/dev/null | tr -d '\r' |
    awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
CLAIMS=no
grep -q 'privileges stripped' <<<"$INFO" && CLAIMS=yes
WANT=no
[ "$CONFINED_N" = "1" ] && WANT=yes
if [ "$CLAIMS" = "$WANT" ]; then
    pass "--info claims a stripping exactly when one happened ($CLAIMS)"
else
    fail "--info claims-stripped=$CLAIMS but OTHERS_REMOVED=$WANT; desc=$INFO"
fi

nt_result "PR4 token: control n=$CONTROL_N -> confined n=$CONFINED_N \
[$CONFINED] $CONFINED_CTL $CONFINED_TRAV --info-claims-stripped=$CLAIMS"

# --- PR 9's reach, on the platform confine.sh cannot ask ---
#
# The control run says which of these the runner had in the first place: a name
# nobody set reads GONE for a reason that has nothing to do with the allowlist,
# and that is the shape a reassuring wrong answer takes here.
NT_ENV_REACHED=""
NT_ENV_STOPPED=""
NT_ENV_UNSET_BEFORE=""
for n in $NEUTRINO_TEST_BATTERY; do
    if ! grep -qx "env $n SEEN" <<<"$CONTROL_RAW"; then
        NT_ENV_UNSET_BEFORE="$NT_ENV_UNSET_BEFORE $n"
    elif grep -qx "env $n SEEN" <<<"$OUT"; then
        NT_ENV_REACHED="$NT_ENV_REACHED $n"
    else
        NT_ENV_STOPPED="$NT_ENV_STOPPED $n"
    fi
done
if grep -qx "env NEUTRINO_ENV_CONTROL_KEPT SEEN" <<<"$OUT"; then
    pass "the battery reached the payload (NEUTRINO_ENV_CONTROL_KEPT)"
else
    fail "battery control expected=NEUTRINO_ENV_CONTROL_KEPT SEEN actual=$(nt_raw <<<"$OUT")"
fi
if grep -qx "env NT_ENV_CONTROL_DROPPED GONE" <<<"$OUT"; then
    pass "a name outside the allowlist is dropped (NT_ENV_CONTROL_DROPPED)"
else
    fail "battery control expected=NT_ENV_CONTROL_DROPPED GONE actual=$(nt_raw <<<"$OUT")"
fi

# The names themselves. A run where the control never set one of these says so
# instead of passing: a name nobody set is absent for a reason that has nothing
# to do with the allowlist.
for n in WEBVIEW2_BROWSER_EXECUTABLE_FOLDER WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS \
         WEBVIEW2_USER_DATA_FOLDER WEBVIEW2_RELEASE_CHANNEL_PREFERENCE \
         COR_ENABLE_PROFILING COR_PROFILER COR_PROFILER_PATH COMPlus_ZapDisable \
         DOTNET_STARTUP_HOOKS __COMPAT_LAYER; do
    if ! grep -qx "env $n SEEN" <<<"$CONTROL_RAW"; then
        nt_note "$n was never set on this runner; unmeasured here"
    elif grep -qx "env $n GONE" <<<"$OUT"; then
        pass "$n does not reach the app"
    else
        fail "$n expected=GONE actual=reached the app"
    fi
done
for n in PATH PROCESSOR_ARCHITECTURE; do
    if grep -qx "env $n SEEN" <<<"$OUT"; then
        pass "$n still arrives"
    else
        fail "$n expected=SEEN actual=dropped; cmd.exe and the CRT need it"
    fi
done
nt_result "env reach [windows]: reached:$NT_ENV_REACHED | stopped:$NT_ENV_STOPPED | \
never set on this runner:$NT_ENV_UNSET_BEFORE | --info says: \
$("$APP" --info 2>/dev/null | tr -d '\r' | awk '$1 == "env" { $1 = ""; sub(/^ +/, ""); print }')"

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
