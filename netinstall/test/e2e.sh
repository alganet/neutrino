#!/bin/bash
# e2e.sh - fetch, verify and run a real neutrino polyglot through netinstall
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: e2e.sh <netinstall binary built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0

echo "=== Build the app under test ==="
# netinstall's own app and not test/neutrinotest.js. What this suite asserts
# about the launch is that a fetched, verified and pinned polyglot runs; the
# six-state window contract belongs to neutrino's verifiers, which every lane
# that runs this suite has already run against a standalone launch of its own.
# See nt_app_probe in lib.sh for the whole of that argument.
bash "$ROOT/test/mkapp.sh" --testing "$NT_TESTDIR/alive.js" "$SERVE/alive.cmd"
SPEC="alive-example-com-1$(nt_pin "$SERVE/alive.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
echo "  built and pinned as $SPEC"

echo "=== Resolve ==="
"$APP" --info
nt_note "confine: $("$APP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"

SCRIPT="$NEUTRINO_HOME/apps/$(nt_appkey "$SPEC")/alive.cmd"
APPDIR="$NEUTRINO_HOME/apps/$(nt_appkey "$SPEC")/alive"

echo "=== Fetch and verify ==="
if "$APP" --fetch >/dev/null 2>&1; then
    echo "  PASS: fetched"
else
    nt_fail "fetch expected=ok actual=failed"
    FAILURES=$((FAILURES + 1))
fi

if cmp -s "$SERVE/alive.cmd" "$SCRIPT"; then
    echo "  PASS: cached bytes are identical to what was served"
else
    nt_fail "cached bytes expected=identical actual=differ"
    FAILURES=$((FAILURES + 1))
fi

if [ ! -w "$SCRIPT" ]; then
    echo "  PASS: cached launcher is read-only"
else
    nt_fail "cached launcher expected=read-only actual=writable"
    FAILURES=$((FAILURES + 1))
fi

FULL="$(nt_sha256 "$SERVE/alive.cmd")"
if [ -f "$NEUTRINO_HOME/blobs/$FULL" ]; then
    echo "  PASS: blob is content-addressed as blobs/$FULL"
else
    nt_fail "blob expected=blobs/$FULL actual=missing"
    FAILURES=$((FAILURES + 1))
fi

# What a launch has to answer here, and the three answers it can give, are in
# nt_app_probe's header in lib.sh. In one line: this suite asks whether the app
# it installed opens a webview and runs its script, and neutrino's own verifiers
# -- which every lane running this suite has already run against a standalone
# launch a few minutes earlier -- answer a different and much longer question.
STATE=""
if [ "$NT_WINDOWS" = "1" ]; then
    echo "=== Launch through cmd.exe ==="
    "$APP" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    # Three placements, and under netinstall the first is the one that should
    # arrive. The build slot is the directory this program opens for the launch
    # that owes a compile and closes when the .cmd returns; beside the script is
    # what a standalone launch does and what this used to get; the app dir is
    # the fallback for a launcher with nowhere to keep anything. All three are
    # waited for and the reading says which arrived, because a suite that names
    # one placement is a suite that spins its whole budget the day it moves --
    # which is what happened when the exe left the app dir.
    SLOT="${SCRIPT%.cmd}.build"
    SLOTEXE="$SLOT/alive.exe"
    KEPT="${SCRIPT%.cmd}.exe"
    FALLBACK="$APPDIR/alive.exe"
    for _ in $(seq 1 120); do
        if [ -f "$SLOTEXE" ] || [ -f "$KEPT" ] || [ -f "$FALLBACK" ]; then break; fi
        sleep 1
    done
    if [ -f "$SLOTEXE" ]; then
        echo "  PASS: jsc.exe compiled the app into the build slot"
    elif [ -f "$KEPT" ]; then
        echo "  PASS: jsc.exe compiled the app beside the script it was verified from"
        if [ -f "${SCRIPT%.cmd}.stamp" ]; then
            echo "  PASS: and stamped it with the source it was built from"
        else
            nt_fail "stamp expected=${SCRIPT%.cmd}.stamp actual=missing"
            FAILURES=$((FAILURES + 1))
        fi
    elif [ -f "$FALLBACK" ]; then
        echo "  PASS: jsc.exe compiled the app into its own dir (stamp refused above it)"
    else
        nt_fail "compiled exe expected=$SLOTEXE, $KEPT or $FALLBACK actual=missing"
        FAILURES=$((FAILURES + 1))
    fi
    STATE="$(nt_app_probe 120)"
    nt_kill_tree $APP_PID

    # And the half that would have failed before this existed: a second launch
    # of the same app compiles nothing. The exe is the same file, byte for byte
    # and by modification time, and the record beside the slot is what says the
    # launcher was allowed to trust it. Against the commit before this one the
    # exe is rewritten on every launch, so mtime moves every time.
    #
    # The control is the launch itself: an app that did not come up the second
    # time is not a cache working, and nt_app_probe answers that below.
    if [ -f "$SLOTEXE" ]; then
        echo "=== And a second launch through cmd.exe ==="
        if [ -f "$SLOT.stamp" ]; then
            echo "  PASS: the slot carries a record netinstall wrote"
        else
            nt_fail "slot record expected=$SLOT.stamp actual=missing"
            FAILURES=$((FAILURES + 1))
        fi
        BEFORE="$(nt_sha256 "$SLOTEXE")"
        BEFORE_MT="$(nt_mtime "$SLOTEXE")"
        nt_app_gone
        "$APP" > "$WORK/app2.log" 2>&1 &
        APP2_PID=$!
        STATE2="$(nt_app_probe 120)"
        AFTER="$(nt_sha256 "$SLOTEXE")"
        AFTER_MT="$(nt_mtime "$SLOTEXE")"
        nt_kill_tree $APP2_PID
        nt_note "slot second=$STATE2 same=$([ "$BEFORE" = "$AFTER" ] && echo YES || echo NO) mtime_moved=$([ "$BEFORE_MT" = "$AFTER_MT" ] && echo NO || echo YES)"
        if [ "$BEFORE" != "$AFTER" ] || [ "$BEFORE_MT" != "$AFTER_MT" ]; then
            nt_fail "slot expected=the second launch reuses the exe actual=it was rebuilt"
            FAILURES=$((FAILURES + 1))
        else
            echo "  PASS: a second launch runs the kept exe and compiles nothing"
        fi
        if [ "$STATE2" != "$STATE" ]; then
            nt_fail "slot expected=the second launch comes up like the first ($STATE) actual=$STATE2"
            FAILURES=$((FAILURES + 1))
        else
            echo "  PASS: and comes up from it"
        fi
    fi
elif command -v osascript >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then
    echo "=== Launch through osascript ==="
    # TMPDIR is deliberately not redirected on macOS, so the launcher and the
    # probe agree on where the status file lives. nt_app_gone clears it, so a
    # title left by something earlier cannot be read as this launch's.
    nt_app_gone
    "$APP" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    # The longest budget of the three, and it is the one verify-macos.sh already
    # needed for a first window: osascript starting, the bridge coming up, and
    # WKWebView creating its content process all happen before any title.
    STATE="$(nt_app_probe 180)"
    nt_kill_tree $APP_PID

    # What the launcher said about its own confinement, which until this suite
    # read it was written to app.log and looked at by nobody: the dump at the
    # bottom of this file is behind `if [ "$FAILURES" -ne 0 ]`, so on a green run
    # these lines went nowhere, and two defects lived in that gap.
    #
    # Silence is the pass, and on this platform it now means something more
    # specific than it used to. The launcher no longer applies its profile with
    # sandbox-exec; it hands the text to the driver, which registers with
    # LaunchServices and then applies the profile to itself. Under netinstall
    # there is nothing for it to apply -- a process already inside a profile
    # cannot take a second one, sandbox_init answers -1 -- so the driver asks
    # first whether writes outside the app dir are already refused, finds that
    # they are, and says nothing. That silence is this assertion passing.
    #
    # Each of the four things it could say instead is a failure, and they want
    # different fixes:
    #
    #   could not build            the here-document defect returning. /bin/sh
    #                              here is bash 3.2, its here-documents go to
    #                              /tmp whatever $TMPDIR says, and no profile in
    #                              this stack grants /tmp.
    #   seatbelt refused           sandbox_init was reached, the process was not
    #                              already confined, and the profile did not
    #                              take: the launcher's own profile has gone bad.
    #   could not reach            the bind of sandbox_init_with_parameters
    #                              failed, so nothing was even attempted.
    #   could not register         setActivationPolicy returned false, which is
    #                              the window not appearing -- the whole reason
    #                              the ordering changed. If this fires, the
    #                              LaunchServices denial is back in a profile
    #                              that is applied before AppKit registers.
    NT_CONFINE_SAID="$(grep -oE 'neutrino: (could not build the seatbelt profile|seatbelt refused this process.s own profile|could not reach sandbox_init_with_parameters|could not register as an application)' \
        "$WORK/app.log" 2>/dev/null | head -1)"
    case "${NT_CONFINE_SAID:-}" in
        "")
            echo "  PASS: the launcher found netinstall's profile already in force and said nothing" ;;
        *"could not build"*)
            nt_fail "launcher confinement expected=silence actual=could-not-build (a here-document under a profile that denies /tmp)"
            FAILURES=$((FAILURES + 1)) ;;
        *"rejected"*)
            nt_fail "launcher confinement expected=silence actual=seatbelt-rejected (the launcher's own profile is bad)"
            FAILURES=$((FAILURES + 1)) ;;
        *"already inside"*)
            nt_fail "launcher confinement expected=silence actual=not-nesting (a second profile is no longer accepted after netinstall's; the app has only netinstall's)"
            FAILURES=$((FAILURES + 1)) ;;
        *)
            nt_fail "launcher confinement expected=silence actual=$NT_CONFINE_SAID"
            FAILURES=$((FAILURES + 1)) ;;
    esac
elif [ -n "${DISPLAY:-}" ] && nt_linux_runtime; then
    echo "=== Launch through the linux runtime ==="
    nt_app_gone
    "$APP" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    STATE="$(nt_app_probe 120)"
    nt_kill_tree $APP_PID
else
    echo "=== No webview runtime here; assert the polyglot's shell path ran ==="
    ERR="$(nt_timeout 60 "$APP" 2>&1 >/dev/null)"
    RC=$?
    if [ "$RC" -eq 124 ]; then
        nt_fail "polyglot did not exit; a runtime was found that nt_linux_runtime missed"
        FAILURES=$((FAILURES + 1))
    elif grep -q "No suitable runtime found" <<<"$ERR"; then
        echo "  PASS: sh executed the polyglot and reached its runtime probe"
    else
        nt_fail "polyglot expected=runtime-probe actual=$(tr '\n' ' ' <<<"$ERR")"
        FAILURES=$((FAILURES + 1))
    fi
fi

case "$STATE" in
    # Empty is the no-runtime branch above, which asserted its own thing and
    # left nothing for this to judge. Every other silence is named.
    "") ;;
    CONTENT_OK)
        echo "  PASS: the installed app opened a webview and its script ran" ;;
    WINDOW_NO_CONTENT)
        # The distinction this probe exists for: the process started and got a
        # window, and the page inside it never ran. A launcher that cannot find
        # its runtime fails differently, and so does a sandbox that kills the
        # renderer -- naming which one is the finding.
        nt_fail "the installed app got a window but its script never ran"
        FAILURES=$((FAILURES + 1)) ;;
    NO_WINDOW)
        nt_fail "the installed app never got a window"
        FAILURES=$((FAILURES + 1)) ;;
    *)
        nt_fail "the webview probe did not report a state ($STATE)"
        FAILURES=$((FAILURES + 1)) ;;
esac

echo "=== A new pin reuses the app dir and replaces the launcher ==="
cp "$SERVE/alive.cmd" "$WORK/v1.cmd"
mkdir -p "$APPDIR"
echo keep > "$APPDIR/carried-over"
printf 'echo v2\n' > "$SERVE/alive.cmd"
SPEC2="alive-example-com-1$(nt_pin "$SERVE/alive.cmd")"
APP2="$(nt_as "$BIN" "$SPEC2" "$WORK/bin")"
if [ "$SPEC" = "$SPEC2" ]; then
    nt_fail "second pin expected=different actual=same"
    FAILURES=$((FAILURES + 1))
elif "$APP2" --fetch >/dev/null 2>&1; then
    if [ -f "$APPDIR/carried-over" ]; then
        echo "  PASS: app dir state survived the version change"
    else
        nt_fail "app dir state expected=preserved actual=lost"
        FAILURES=$((FAILURES + 1))
    fi
    if cmp -s "$SERVE/alive.cmd" "$SCRIPT"; then
        echo "  PASS: launcher replaced by the new pin"
    else
        nt_fail "launcher expected=new-version actual=stale"
        FAILURES=$((FAILURES + 1))
    fi
    if "$APP2" --verify >/dev/null 2>&1 && ! "$APP" --verify >/dev/null 2>&1; then
        echo "  PASS: last pin wins; the old pin no longer verifies"
    else
        nt_fail "pin precedence expected=last-wins actual=both-or-neither"
        FAILURES=$((FAILURES + 1))
    fi
else
    nt_fail "second pin expected=fetched actual=failed"
    FAILURES=$((FAILURES + 1))
fi
cp "$WORK/v1.cmd" "$SERVE/alive.cmd"

echo "=== A shape with a directory fetches from the subdirectory ==="
# The shapes are the only thing that knows a subdirectory exists, and a parser
# test cannot tell a URL that was built from one that was fetched. This one is
# served from a real subdirectory, which is what a project GitHub Pages site is.
# It is an even shape, so nothing in the name says netinstall.cmd and that is
# still the file the server has to be asked for.
mkdir -p "$SERVE/demo"
cp "$SERVE/alive.cmd" "$SERVE/demo/netinstall.cmd"
DSPEC="demo-127_0_0_1-2$(nt_pin "$SERVE/demo/netinstall.cmd")"
DAPP="$(nt_as "$BIN" "$DSPEC" "$WORK/bin")"
DURL="$("$DAPP" --info 2>/dev/null | awk '$1 == "url" { print $2 }')"
if [ "$DURL" = "$NEUTRINO_TEST_ORIGIN/demo/netinstall.cmd" ]; then
    echo "  PASS: shape 2 resolved to $DURL"
else
    nt_fail "shape 2 url expected=$NEUTRINO_TEST_ORIGIN/demo/netinstall.cmd actual=${DURL:-<none>}"
    FAILURES=$((FAILURES + 1))
fi
DSCRIPT="$NEUTRINO_HOME/apps/$(nt_appkey "$DSPEC")/netinstall.cmd"
if "$DAPP" --fetch >/dev/null 2>&1 && cmp -s "$SERVE/demo/netinstall.cmd" "$DSCRIPT"; then
    echo "  PASS: fetched and verified through the subdirectory"
else
    nt_fail "shape 2 fetch expected=ok actual=failed ($DSCRIPT)"
    FAILURES=$((FAILURES + 1))
fi
echo "=== A shape that names both file and directory ==="
mkdir -p "$SERVE/toy"
cp "$SERVE/alive.cmd" "$SERVE/toy/calc.cmd"
TSPEC="calc-toy-127_0_0_1-3$(nt_pin "$SERVE/toy/calc.cmd")"
TAPP="$(nt_as "$BIN" "$TSPEC" "$WORK/bin")"
TSCRIPT="$NEUTRINO_HOME/apps/$(nt_appkey "$TSPEC")/calc.cmd"
if "$TAPP" --fetch >/dev/null 2>&1 && cmp -s "$SERVE/toy/calc.cmd" "$TSCRIPT"; then
    echo "  PASS: shape 3 fetched $(nt_appkey "$TSPEC")/calc.cmd"
else
    nt_fail "shape 3 fetch expected=ok actual=failed ($TSCRIPT)"
    FAILURES=$((FAILURES + 1))
fi
# Same segments, same pin, different shape: different URL, so the app dirs must
# not be the same one. This is what keeping the shape in the cache key buys.
if [ "$(nt_appkey "$DSPEC")" != "$(nt_appkey "$TSPEC")" ] && [ -f "$DSCRIPT" ] && [ -f "$TSCRIPT" ]; then
    echo "  PASS: the two shapes kept separate app directories"
else
    nt_fail "app dirs expected=distinct actual=$(nt_appkey "$DSPEC") vs $(nt_appkey "$TSPEC")"
    FAILURES=$((FAILURES + 1))
fi

echo "=== neutrino's own app dir landed inside the writable dir ==="
if [ -d "$APPDIR" ]; then
    echo "  PASS: $APPDIR"
else
    nt_fail "appdir expected=$APPDIR actual=missing"
    FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -ne 0 ] && [ -s "$WORK/app.log" ]; then
    echo "=== App output ==="
    tail -40 "$WORK/app.log"
    nt_note "app log: $(tr '\n' ' ' < "$WORK/app.log" | tail -c 400)"
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
