#!/bin/bash
# job-ui.sh - which job UI restrictions can a real webview actually survive?
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Two CI rounds established that the answer is neither "all of them" nor
# obvious, so this bisects instead of guessing: every flag is applied on its own
# to a real webview, one launch each, in a single run. The binary takes the set
# by name under -DNEUTRINO_TESTING, which is what makes that affordable.
#
# It reports rather than fails. The per-flag results are the finding; the only
# thing asserted is the baseline, because if a webview cannot start with no
# restrictions at all then nothing below means anything.

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: job-ui.sh <netinstall binary built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ "$NT_WINDOWS" != "1" ]; then
    echo "=== SKIP: job objects are a windows mechanism ==="
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0
PS1_PROBE="$(cygpath -w "$ROOT/netinstall/test/probe-window.ps1")"

# Generous, because a false BREAKS is worse than a slow suite: it would retire a
# flag that works.
NT_FLAG_SECS=60

nt_pwsh() {
    if command -v pwsh >/dev/null 2>&1; then
        pwsh "$@"
    else
        powershell "$@"
    fi
}

# The launcher STARTs the app and exits, so the pid we hold is not the app's.
# Killing by image name is the only way to be sure the previous iteration is
# gone -- and it has to be sure, or a leftover window scores the next flag.
# A signal is not instantaneous either, so this waits for the processes to
# actually leave rather than sleeping a guess.
nt_win_kill() {
    local i
    taskkill //F //T //IM neutrinotest.exe >/dev/null 2>&1
    taskkill //F //T //IM msedgewebview2.exe >/dev/null 2>&1
    for i in $(seq 1 8); do
        if ! tasklist 2>/dev/null | grep -qiE 'neutrinotest\.exe|msedgewebview2\.exe'; then
            sleep 1
            return 0
        fi
        sleep 1
    done
    return 1
}

echo "=== Build the app under test ==="
bash "$ROOT/build.sh" "$ROOT/test/neutrinotest.js" "$SERVE/neutrinotest.cmd"
SPEC="neutrinotest-com-example-0$(nt_pin "$SERVE/neutrinotest.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"

APPDIR="$NEUTRINO_HOME/apps/$(nt_appkey "$SPEC")/neutrinotest"

probe() {
    local flags="$1" secs="$2" tag res
    tag="${flags//,/+}"
    [ -n "$tag" ] || tag="none"

    nt_win_kill || nt_note "warning: processes still alive before the $tag launch"
    # A killed browser leaves its profile locked, and the next launch then puts
    # up a window it can never draw in -- which looks exactly like a flag that
    # broke the renderer. The runtime itself stays put, so this costs nothing
    # but the profile.
    rm -rf "$APPDIR/data/EBWebView" 2>/dev/null

    NEUTRINO_TEST_JOB_UI="$flags" "$APP" > "$WORK/log-$tag" 2>&1 &
    res="$(nt_pwsh -NoProfile -ExecutionPolicy Bypass -File "$PS1_PROBE" \
           -TimeoutSeconds "$secs" 2>/dev/null | tr -d '\r' | tail -1)"
    nt_win_kill
    echo "${res:-NO_RESULT}"
}

# The first launch pays for the WebView2 download and the jsc compile, and every
# later one reuses the app dir, so this is also the warm-up.
echo "=== Baseline: no restrictions at all ==="
BASE="$(probe none 180)"
nt_summary "### netinstall job-ui: which job UI restrictions a webview survives"
nt_summary ""
nt_summary "- baseline, no restrictions, 180s: \`$BASE\`"
if [ "$BASE" != "CONTENT_OK" ]; then
    nt_fail "baseline expected=CONTENT_OK actual=$BASE; the table below would be meaningless"
    nt_note "baseline log: $(tr '\n' ' ' < "$WORK/log-none" 2>/dev/null | tail -c 400)"
    echo "=== Results: 1 failure(s) ==="
    exit 1
fi
echo "  PASS: a webview starts with no restrictions"

# The baseline above is a warm-up, not a control: it had three minutes and a
# clean profile, and the flag runs get neither. A control has to be the same
# procedure with the same clock, or every flag inherits the harness's own
# failures -- which is exactly what happened the first time this ran, when all
# eight came back identical because a relaunch could not finish in the time it
# was given.
echo "=== Control: the same relaunch, on the flags' clock ==="
CONTROL="$(probe none "$NT_FLAG_SECS")"
nt_summary "- control, no restrictions, ${NT_FLAG_SECS}s: \`$CONTROL\`"
if [ "$CONTROL" != "CONTENT_OK" ]; then
    nt_fail "control expected=CONTENT_OK actual=$CONTROL; a relaunch cannot be scored in ${NT_FLAG_SECS}s, so no table is reported"
    nt_note "control log: $(tr '\n' ' ' < "$WORK/log-none" 2>/dev/null | tail -c 400)"
    echo "=== Results: 1 failure(s) ==="
    exit 1
fi
echo "  PASS: an unrestricted relaunch is scored CONTENT_OK on the same clock"

echo "=== One flag at a time ==="
SURVIVED=""
TABLE=""
for flag in handles readclipboard writeclipboard systemparameters \
            displaysettings globalatoms desktop exitwindows; do
    RES="$(probe "$flag" "$NT_FLAG_SECS")"
    TABLE="${TABLE:+$TABLE }$flag=$RES"
    nt_summary "- \`$flag\`: \`$RES\`"
    if [ "$RES" = "CONTENT_OK" ]; then
        echo "  SURVIVES: $flag"
        SURVIVED="${SURVIVED:+$SURVIVED,}$flag"
    else
        echo "  BREAKS:   $flag ($RES)"
    fi
done

# Also as a single annotation, so the headline survives even if the summary is
# not where someone is looking.
nt_note "job ui table: $TABLE"

echo "=== All the survivors together ==="
if [ -n "$SURVIVED" ]; then
    COMBO="$(probe "$SURVIVED" "$NT_FLAG_SECS")"
    if [ "$COMBO" = "CONTENT_OK" ]; then
        echo "  PASS: $SURVIVED can be applied together"
        nt_summary "- **ship this set:** \`$SURVIVED\`"
        nt_note "job ui ship this set: $SURVIVED"
    else
        echo "  NOTE: individually fine but not together ($COMBO)"
        nt_summary "- combined \`$SURVIVED\`: \`$COMBO\` (fine alone, not together)"
    fi
else
    nt_summary "- **nothing survived:** no job ui restriction kept a webview alive"
fi

# A second control, after everything the loop did to this machine. If the first
# passed and this one does not, the table decayed as it went and the later rows
# are not trustworthy.
echo "=== Control again, at the end ==="
CONTROL2="$(probe none "$NT_FLAG_SECS")"
nt_summary "- closing control: \`$CONTROL2\`"
if [ "$CONTROL2" != "CONTENT_OK" ]; then
    nt_note "WARNING: the closing control failed, so treat the table as suspect"
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
