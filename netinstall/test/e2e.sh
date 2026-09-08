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
# harness.sh after lib.sh, and the order is the mechanism: both define nt_fail
# and they disagree about arity. nt_note is lib.sh's and is not shadowed.
#
# The sixteenth and last netinstall suite. It runs everywhere the runner runs
# it -- gjs, kde, macos-netinstall, windows-launch -- and asks a different set on
# each: the build slot and its stamp are windows, the launcher's own confinement
# is macOS, and the polyglot's runtime probe is the platforms with no webview at
# all. So the lane lists in test/cases.tsv carry that, the way confine.sh's do,
# and the gates inside a platform are skips.
. "$(cd "$(dirname "$0")/../../test/lib" && pwd)/harness.sh"
NT_ANNOTATE=netinstall
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT


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
    nt_pass e2e.fetch "fetched"
else
    nt_fail e2e.fetch "fetch expected=ok actual=failed"
fi

if cmp -s "$SERVE/alive.cmd" "$SCRIPT"; then
    nt_pass e2e.cache.identical "cached bytes are identical to what was served"
else
    nt_fail e2e.cache.identical "cached bytes expected=identical actual=differ"
fi

if [ ! -w "$SCRIPT" ]; then
    nt_pass e2e.cache.readonly "cached launcher is read-only"
else
    nt_fail e2e.cache.readonly "cached launcher expected=read-only actual=writable"
fi

FULL="$(nt_sha256 "$SERVE/alive.cmd")"
if [ -f "$NEUTRINO_HOME/blobs/$FULL" ]; then
    nt_pass e2e.blob.addressed "blob is content-addressed as blobs/$FULL"
else
    nt_fail e2e.blob.addressed "blob expected=blobs/$FULL actual=missing"
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
        nt_pass e2e.compiled "jsc.exe compiled the app into the build slot"
        nt_skip e2e.compiled.stamped "the slot is where it landed, and a slot carries a record rather than a stamp"
    elif [ -f "$KEPT" ]; then
        nt_pass e2e.compiled "jsc.exe compiled the app beside the script it was verified from"
        if [ -f "${SCRIPT%.cmd}.stamp" ]; then
            nt_pass e2e.compiled.stamped "and stamped it with the source it was built from"
        else
            nt_fail e2e.compiled.stamped "stamp expected=${SCRIPT%.cmd}.stamp actual=missing"
        fi
    elif [ -f "$FALLBACK" ]; then
        nt_pass e2e.compiled "jsc.exe compiled the app into its own dir (stamp refused above it)"
        nt_skip e2e.compiled.stamped "it landed in its own dir, where the stamp was refused"
    else
        nt_fail e2e.compiled "compiled exe expected=$SLOTEXE, $KEPT or $FALLBACK actual=missing"
        nt_skip e2e.compiled.stamped "nothing was compiled, so there is nothing to have stamped"
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
            nt_pass e2e.slot.record "the slot carries a record netinstall wrote"
        else
            nt_fail e2e.slot.record "slot record expected=$SLOT.stamp actual=missing"
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
            nt_fail e2e.slot.reused "slot expected=the second launch reuses the exe actual=it was rebuilt"
        else
            nt_pass e2e.slot.reused "a second launch runs the kept exe and compiles nothing"
        fi
        # And no digest was taken for either of them. The launcher hashes the
        # script only where a stamp can be compared with the answer, and under
        # netinstall there is nowhere to keep one -- the shelf is above the
        # writable directory -- so both the granted launch and the sealed one
        # leave for the compile or for :LAUNCH before any certutil runs.
        # launcher.hash is where that call would write, so its absence is the
        # assertion: a launch that starts a process to answer a question
        # nothing asks would put the file there. test/appcache.ps1 holds the
        # other half, where the digest *is* read and the file must exist.
        if [ -f "$APPDIR/launcher.hash" ]; then
            nt_fail e2e.slot.nodigest "slot expected=no digest is taken where no stamp can be kept actual=$APPDIR/launcher.hash exists"
        else
            nt_pass e2e.slot.nodigest "neither launch ran a certutil nothing would have read"
        fi
        if [ "$STATE2" != "$STATE" ]; then
            nt_fail e2e.slot.secondup "slot expected=the second launch comes up like the first ($STATE) actual=$STATE2"
        else
            nt_pass e2e.slot.secondup "and comes up from it"
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
    # bottom of this file is behind `if [ "$NT_FAILURES" -ne 0 ]`, so on a green run
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
            nt_pass e2e.launcher.confine "the launcher found netinstall's profile already in force and said nothing" ;;
        *"could not build"*)
            nt_fail e2e.launcher.confine "launcher confinement expected=silence actual=could-not-build (a here-document under a profile that denies /tmp)" ;;
        *"rejected"*)
            nt_fail e2e.launcher.confine "launcher confinement expected=silence actual=seatbelt-rejected (the launcher's own profile is bad)" ;;
        *"already inside"*)
            nt_fail e2e.launcher.confine "launcher confinement expected=silence actual=not-nesting (a second profile is no longer accepted after netinstall's; the app has only netinstall's)" ;;
        *)
            nt_fail e2e.launcher.confine "launcher confinement expected=silence actual=$NT_CONFINE_SAID" ;;
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
    NT_POLYGLOT_ASKED=1
    ERR="$(nt_timeout 60 "$APP" 2>&1 >/dev/null)"
    RC=$?
    if [ "$RC" -eq 124 ]; then
        nt_fail e2e.polyglot "polyglot did not exit; a runtime was found that nt_linux_runtime missed"
    elif grep -q "No suitable runtime found" <<<"$ERR"; then
        nt_pass e2e.polyglot "sh executed the polyglot and reached its runtime probe"
    else
        nt_fail e2e.polyglot "polyglot expected=runtime-probe actual=$(tr '\n' ' ' <<<"$ERR")"
    fi
fi

# The branch not taken says so. Three of the four launch paths above have a
# runtime and so never reach the polyglot's shell fallback, and one has no
# runtime and so never gets a window -- and each of those is a lane that could
# not ask rather than a lane nobody asked, which is a distinction the grid can
# only show if there is a row.
[ "${NT_POLYGLOT_ASKED:-0}" = 1 ] ||
    nt_skip e2e.polyglot "this lane has a webview runtime, so the shell fallback was never the path taken"

case "$STATE" in
    # Empty is the no-runtime branch above, which asserted its own thing and
    # left nothing for this to judge. Every other silence is named.
    "") nt_skip e2e.app.window "no webview runtime here; the polyglot's shell path was asserted instead" ;;
    CONTENT_OK)
        nt_pass e2e.app.window "the installed app opened a webview and its script ran" ;;
    WINDOW_NO_CONTENT)
        # The distinction this probe exists for: the process started and got a
        # window, and the page inside it never ran. A launcher that cannot find
        # its runtime fails differently, and so does a sandbox that kills the
        # renderer -- naming which one is the finding.
        nt_fail e2e.app.window "the installed app got a window but its script never ran" ;;
    NO_WINDOW)
        nt_fail e2e.app.window "the installed app never got a window" ;;
    *)
        nt_fail e2e.app.window "the webview probe did not report a state ($STATE)" ;;
esac

echo "=== A new pin reuses the app dir and replaces the launcher ==="
cp "$SERVE/alive.cmd" "$WORK/v1.cmd"
mkdir -p "$APPDIR"
echo keep > "$APPDIR/carried-over"
printf 'echo v2\n' > "$SERVE/alive.cmd"
SPEC2="alive-example-com-1$(nt_pin "$SERVE/alive.cmd")"
APP2="$(nt_as "$BIN" "$SPEC2" "$WORK/bin")"
# Said either way, both of them, and neither was. e2e.repin.differs spoke only
# when the two pins came out the same and e2e.repin.fetched only when the second
# one would not fetch, so on every good run -- which is every run -- the pair
# filed nothing at all and the grid carried two holes. Found by matrix.py once
# --strict started counting a case missing from some of its lanes; before that
# the cells were drawn as `-` and the run went green.
#
# The three below them have the same shape at one remove: they are asked only on
# the path where the fetch worked, so they say why on the two paths where it
# could not be asked instead of leaving three more.
NT_REPIN_REST="e2e.repin.state e2e.repin.launcher e2e.repin.lastwins"
if [ "$SPEC" = "$SPEC2" ]; then
    nt_fail e2e.repin.differs "second pin expected=different actual=same"
    nt_skip e2e.repin.fetched "the second pin is the same spec, so there is no new fetch to make"
    for c in $NT_REPIN_REST; do
        nt_skip "$c" "the second pin is the same spec, so nothing was replaced"
    done
elif "$APP2" --fetch >/dev/null 2>&1; then
    nt_pass e2e.repin.differs "the second pin is a different spec"
    nt_pass e2e.repin.fetched "and it fetches"
    if [ -f "$APPDIR/carried-over" ]; then
        nt_pass e2e.repin.state "app dir state survived the version change"
    else
        nt_fail e2e.repin.state "app dir state expected=preserved actual=lost"
    fi
    if cmp -s "$SERVE/alive.cmd" "$SCRIPT"; then
        nt_pass e2e.repin.launcher "launcher replaced by the new pin"
    else
        nt_fail e2e.repin.launcher "launcher expected=new-version actual=stale"
    fi
    if "$APP2" --verify >/dev/null 2>&1 && ! "$APP" --verify >/dev/null 2>&1; then
        nt_pass e2e.repin.lastwins "last pin wins; the old pin no longer verifies"
    else
        nt_fail e2e.repin.lastwins "pin precedence expected=last-wins actual=both-or-neither"
    fi
else
    nt_pass e2e.repin.differs "the second pin is a different spec"
    nt_fail e2e.repin.fetched "second pin expected=fetched actual=failed"
    for c in $NT_REPIN_REST; do
        nt_skip "$c" "the second pin did not fetch, so nothing below it was replaced"
    done
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
    nt_pass e2e.shape2.url "shape 2 resolved to $DURL"
else
    nt_fail e2e.shape2.url "shape 2 url expected=$NEUTRINO_TEST_ORIGIN/demo/netinstall.cmd actual=${DURL:-<none>}"
fi
DSCRIPT="$NEUTRINO_HOME/apps/$(nt_appkey "$DSPEC")/netinstall.cmd"
if "$DAPP" --fetch >/dev/null 2>&1 && cmp -s "$SERVE/demo/netinstall.cmd" "$DSCRIPT"; then
    nt_pass e2e.shape2.fetch "fetched and verified through the subdirectory"
else
    nt_fail e2e.shape2.fetch "shape 2 fetch expected=ok actual=failed ($DSCRIPT)"
fi
echo "=== A shape that names both file and directory ==="
mkdir -p "$SERVE/toy"
cp "$SERVE/alive.cmd" "$SERVE/toy/calc.cmd"
TSPEC="calc-toy-127_0_0_1-3$(nt_pin "$SERVE/toy/calc.cmd")"
TAPP="$(nt_as "$BIN" "$TSPEC" "$WORK/bin")"
TSCRIPT="$NEUTRINO_HOME/apps/$(nt_appkey "$TSPEC")/calc.cmd"
if "$TAPP" --fetch >/dev/null 2>&1 && cmp -s "$SERVE/toy/calc.cmd" "$TSCRIPT"; then
    nt_pass e2e.shape3.fetch "shape 3 fetched $(nt_appkey "$TSPEC")/calc.cmd"
else
    nt_fail e2e.shape3.fetch "shape 3 fetch expected=ok actual=failed ($TSCRIPT)"
fi
# Same segments, same pin, different shape: different URL, so the app dirs must
# not be the same one. This is what keeping the shape in the cache key buys.
if [ "$(nt_appkey "$DSPEC")" != "$(nt_appkey "$TSPEC")" ] && [ -f "$DSCRIPT" ] && [ -f "$TSCRIPT" ]; then
    nt_pass e2e.shapes.distinct "the two shapes kept separate app directories"
else
    nt_fail e2e.shapes.distinct "app dirs expected=distinct actual=$(nt_appkey "$DSPEC") vs $(nt_appkey "$TSPEC")"
fi

echo "=== neutrino's own app dir landed inside the writable dir ==="
if [ -d "$APPDIR" ]; then
    nt_pass e2e.appdir.inside "$APPDIR"
else
    nt_fail e2e.appdir.inside "appdir expected=$APPDIR actual=missing"
fi

if [ "$NT_FAILURES" -ne 0 ] && [ -s "$WORK/app.log" ]; then
    echo "=== App output ==="
    tail -40 "$WORK/app.log"
    nt_note "app log: $(tr '\n' ' ' < "$WORK/app.log" | tail -c 400)"
fi

# $NT_FAILURES rather than a counter of this file's own: nt_fail counts.
echo "=== Results: $NT_FAILURES failure(s) ==="
exit $NT_FAILURES
