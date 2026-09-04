#!/bin/bash
# splash.sh - the splash window's lifecycle, and the runs that must not have one
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# The window exists for one stretch of one kind of run: a cache miss, between
# the fetch starting and the payload getting its turn to draw. Everything else
# -- a warm cache, --info, --version, a refusal -- must leave no window and, on
# a platform that cannot draw at all, must say nothing about it.
#
# And not every cache miss. The window is raised only once the download has
# been running NT_SPLASH_DELAY_MS, and once raised it stays NT_SPLASH_HOLD_MS
# at the least, so that a fetch which crosses the first line by a hair is not a
# window that appears and is gone inside a blink. Both numbers are asserted
# here, which needs two kinds of host: nt_serve's loopback, which answers in
# single-digit milliseconds and must therefore get no window, and hostile.py
# with a stall, which holds every truthful response long enough for one to be
# due. Every case about the window itself runs against the second.
#
# What is asserted here is the lifecycle and very nearly not the pixels. That
# split is deliberate: the decision to raise a window is the same on every
# platform and is made in main() and splash.c, while the drawing is five
# different mechanisms. So the markers this reads come from splash.c, which owns
# the decision, and they are already meaningful on a platform whose
# nt_splash_platform_up does nothing but decline. The pictures this suite takes
# go to the lane's sheet, for a reader who wants to see the thing rather than
# read that it existed.
#
# The one exception is the burst at the end, and it is what the window contains
# rather than what it looks like: the indicator moves, so six photographs of it
# are not six copies of one photograph. That much can be asserted without
# reading a pixel, and it is the only part of the drawing that four different
# mechanisms can be held to in the same words.
#
# The positive control is the payload. A netinstall that refused everything
# would trivially pass "no window on a warm cache", so every case that expects
# silence also asserts PAYLOAD-RAN: the silence has to be the silence of a run
# that worked.

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: splash.sh <testing>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"

FAILURES=0
RESULTS="$WORK/results.log"
: > "$RESULTS"
probe() {
    echo "  $*"
    echo "probe: $*" >> "$RESULTS"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

cleanup() {
    [ -n "${NT_SERVER_PID:-}" ] && kill "$NT_SERVER_PID" 2>/dev/null
    [ -n "${HPID:-}" ] && kill "$HPID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

printf '#!/bin/sh\necho PAYLOAD-RAN\n' > "$SERVE/demo.cmd"
PIN="$(nt_pin "$SERVE/demo.cmd")"

# The quick host. nt_serve exports NEUTRINO_TEST_ORIGIN, so every run below
# that names no origin of its own goes here.
nt_serve "$SERVE" || exit 1

# The slow one: the same directory, every truthful response held for STALL
# milliseconds before its first byte. Three times the delay, so that the
# window is due with room to spare and the download still ends well inside
# the hold -- which is what makes the hold the thing measured, and not the
# download. It also carries the dribble shape the orphan check needs.
STALL=300

# The floor the hold has to reach, read out of the header that defines it
# rather than written here a third time. This file used to say 400 twice, and
# what a copied constant costs is the round where it disagrees with the program
# and nobody can tell which of the two is wrong -- so it is lifted, and a header
# that stops yielding it is a failure rather than a default.
HOLD="$(sed -n 's/^#define NT_SPLASH_HOLD_MS \([0-9]*\)L*.*/\1/p' \
    "$(dirname "$0")/../splash.h" | head -1)"
if [ -z "$HOLD" ]; then
    echo "  FAIL: could not read NT_SPLASH_HOLD_MS out of netinstall/splash.h"
    exit 2
fi

HPORT=$((20000 + RANDOM % 20000))
"$(nt_python)" "$(dirname "$0")/hostile.py" "$HPORT" "$SERVE" "$STALL" >/dev/null 2>&1 &
HPID=$!
SLOW="http://127.0.0.1:$HPORT"
HUP=NO
for i in $(seq 1 100); do
    curl -sS -o /dev/null "$SLOW/ping" 2>/dev/null && { HUP=YES; break; }
    sleep 0.1
done
if [ "$HUP" != "YES" ]; then
    echo "  FAIL: hostile.py never came up on $HPORT; nothing below can run"
    exit 2
fi

SPEC="demo-127-0-0-1-1$PIN"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
export NEUTRINO_HOME="$WORK/home"
# splash.c narrates the lifecycle only when asked. It is off by default because
# stderr is a stream other suites read positionally, and three extra lines on
# every run displaced the message fetchbound compares against.
export NEUTRINO_SPLASH_TRACE=1

# splash.c prints one line per step under NEUTRINO_TESTING: "splash: armed"
# when main decided this run is a download and a window may be wanted;
# "splash: up:" when something was drawn, "splash: none:" when the platform
# declined, "splash: unneeded" when the download ended before the window was
# due; and "splash: down (held Nms)" when it was taken away again. Counting
# armed is counting how many times main decided it needed to think about a
# window; counting up and none together is counting how many times it was
# asked for.
#
# -E, and not the backslash-alternation spelling of the same pattern. That is a
# GNU extension: OpenBSD's grep reads it as a literal and counts zero, which is
# worse than an error because the suite then reports a run that printed the line
# as a run that did not. Measured -- the stderr quoted in the failure said
# "splash: none: none (no DISPLAY)" and the count beside it said 0. FreeBSD and
# NetBSD both matched it and passed, which is how it survived review.
armed()     { grep -ca 'netinstall: splash: armed' "$1" 2>/dev/null || true; }
decisions() { grep -caE 'netinstall: splash: (up|none):' "$1" 2>/dev/null || true; }
ups()       { grep -ca 'netinstall: splash: up:' "$1" 2>/dev/null || true; }
downs()     { grep -ca 'netinstall: splash: down' "$1" 2>/dev/null || true; }
# The number out of "down (held Nms)", or empty when the window never went up.
held()      { sed -n 's/.*netinstall: splash: down (held \([0-9]*\)ms).*/\1/p' "$1" 2>/dev/null | head -1; }
# The description out of the first up or none line: what drew, or what declined.
mech_of()   { grep -aE 'netinstall: splash: (up|none):' "$1" 2>/dev/null | head -1 | sed 's/.*splash: [a-z]*: //'; }
# The first word of a description is the mechanism; the parenthesis after it is
# detail that is allowed to differ between runs -- a geometry, a display number,
# and on macOS the pid of the process holding the window. Comparing whole
# descriptions made a run inert-but-different look like a failure, which is what
# the macOS lane reported: appkit turned into appkit with another pid.
mech_name() { printf '%s' "${1%% *}"; }
errtail()   { tr '\n' ' ' < "$1" | cut -c1-240; }

# --- the slow download: one window, and the payload ran ----------------------
STEP="a slow download raises a window once"
NEUTRINO_TEST_ORIGIN="$SLOW" "$APP" >"$WORK/out1" 2>"$WORK/err1"
RC=$?
A="$(armed "$WORK/err1")"; N="$(decisions "$WORK/err1")"
if [ "$RC" = "0" ] && grep -qa PAYLOAD-RAN "$WORK/out1" && [ "$A" = "1" ] && [ "$N" = "1" ]; then
    echo "  PASS: $STEP"
else
    nt_fail "$STEP: rc=$RC armed=$A decisions=$N payload=$(grep -ca PAYLOAD-RAN "$WORK/out1") err=$(errtail "$WORK/err1")"
    FAILURES=$((FAILURES + 1))
fi
probe "slow download: $(grep -aE 'netinstall: splash: (up|none):' "$WORK/err1" | head -1 | sed 's/^netinstall: //')"

# What this machine draws with, taken from the run above and used by the cases
# below. Read once and asserted against, rather than guessed from uname: a lane
# that gains or loses a mechanism is then a failure here and not a silence.
MECH="$(mech_of "$WORK/err1")"
MECHNAME="$(mech_name "$MECH")"

# --- the mechanism this lane was set up to exercise --------------------------
# Reported everywhere, asserted where the lane says what it expects. The
# failure this closes is the one that looks like success: netinstall's splash
# declines silently on a machine it cannot draw on, by design, so a lane whose
# display server did not start turns every window case below into a skip and
# goes green having measured nothing. A lane that installed a compositor in
# order to exercise one code path should say so, and find out when it stops.
#
# Unset is the ordinary case and stays a report -- a developer's machine, and
# the BSD guests, where what draws is a finding rather than a requirement.
STEP="the mechanism is the one this lane was set up for"
if [ -z "${NEUTRINO_SPLASH_EXPECT:-}" ]; then
    echo "  SKIP: $STEP (NEUTRINO_SPLASH_EXPECT is unset; the mechanism is reported, not asserted)"
elif [ "$MECHNAME" = "$NEUTRINO_SPLASH_EXPECT" ]; then
    echo "  PASS: $STEP ($MECH)"
else
    nt_fail "$STEP: expected $NEUTRINO_SPLASH_EXPECT, drew with '${MECH:-nothing at all}'"
    FAILURES=$((FAILURES + 1))
fi

# --- the quick download: a window was thinkable, and not wanted --------------
# The loopback host answers before the window is due, so the right outcome is
# the "unneeded" line and no decision at all. It is a reading where it is a
# reading: a runner busy enough that forking curl and reading a forty-byte file
# takes over a hundred milliseconds has not found a defect, and the line says
# how long the download actually took so that a lane where this keeps coming
# up slow is a lane with a number beside it.
STEP="a quick download raises nothing"
NEUTRINO_HOME="$WORK/home-quick" "$APP" >"$WORK/out2" 2>"$WORK/err2"
RC=$?
A="$(armed "$WORK/err2")"; N="$(decisions "$WORK/err2")"
TOOK="$(sed -n 's/.*splash: unneeded (the download took \([0-9]*\)ms).*/\1/p' "$WORK/err2" | head -1)"
if [ "$RC" != "0" ] || ! grep -qa PAYLOAD-RAN "$WORK/out2" || [ "$A" != "1" ]; then
    nt_fail "$STEP: rc=$RC armed=$A payload=$(grep -ca PAYLOAD-RAN "$WORK/out2") err=$(errtail "$WORK/err2")"
    FAILURES=$((FAILURES + 1))
elif [ "$N" = "0" ] && [ -n "$TOOK" ]; then
    echo "  PASS: $STEP (the download took ${TOOK}ms)"
elif [ "$N" = "1" ]; then
    echo "  SKIP: $STEP (the loopback download outran the delay on this machine; nothing to assert)"
else
    nt_fail "$STEP: armed=$A decisions=$N and no unneeded line: err=$(errtail "$WORK/err2")"
    FAILURES=$((FAILURES + 1))
fi
probe "quick download: $(grep -aE 'netinstall: splash: (unneeded|up|none)' "$WORK/err2" | head -1 | sed 's/^netinstall: //')"

# --- the warm run: nothing at all --------------------------------------------
# The one most likely to regress silently. main() reaching nt_splash_arm on a
# cached run would still look correct from the outside on every platform --
# there is no download for the delay to measure, so nothing would ever be
# drawn -- and it is exactly the kind of edit a future refactor makes.
STEP="warm cache raises nothing"
"$APP" >"$WORK/out3" 2>"$WORK/err3"
RC=$?
A="$(armed "$WORK/err3")"; N="$(decisions "$WORK/err3")"
if [ "$RC" = "0" ] && grep -qa PAYLOAD-RAN "$WORK/out3" && [ "$A" = "0" ] && [ "$N" = "0" ]; then
    echo "  PASS: $STEP"
else
    nt_fail "$STEP: rc=$RC armed=$A decisions=$N payload=$(grep -ca PAYLOAD-RAN "$WORK/out3") err=$(errtail "$WORK/err3")"
    FAILURES=$((FAILURES + 1))
fi

# --- --info and --version: nothing at all ------------------------------------
for FLAG in --info --version; do
    STEP="$FLAG raises nothing"
    "$APP" "$FLAG" >/dev/null 2>"$WORK/err-flag"
    A="$(armed "$WORK/err-flag")"; N="$(decisions "$WORK/err-flag")"
    if [ "$A" = "0" ] && [ "$N" = "0" ]; then
        echo "  PASS: $STEP"
    else
        nt_fail "$STEP: armed=$A decisions=$N"
        FAILURES=$((FAILURES + 1))
    fi
done

# --- the hold: a window that came up stays long enough to be read ------------
# The stalled download ends about two hundred milliseconds after the window is
# due, which is under the hold -- so the number in the down line is the hold
# doing its work, and a splash that took the window away the moment the bytes
# stopped would report roughly two hundred here. Skipped, and said so, where
# nothing draws: there is no hold on a window that does not exist.
STEP="a window that came up stays for the hold"
if [ "$MECHNAME" = "none" ] || [ -z "$MECHNAME" ]; then
    echo "  SKIP: $STEP (nothing draws here)"
    probe "hold: nothing draws, nothing to hold"
else
    H="$(held "$WORK/err1")"
    if [ -n "$H" ] && [ "$H" -ge "$HOLD" ]; then
        echo "  PASS: $STEP (held ${H}ms)"
    else
        nt_fail "$STEP: held='${H:-none}', wanted at least $HOLD: err=$(errtail "$WORK/err1")"
        FAILURES=$((FAILURES + 1))
    fi
    probe "hold: held ${H:-none}ms against a ${STALL}ms stall"

    # The testing knob, in both directions it can be pushed. Raised, it is
    # honoured -- that is the whole reason it exists, for the picture below
    # and for a person who wants to look at the thing. Lowered, it is ignored:
    # the one thing the knob must not be able to do is put the blink back.
    STEP="NEUTRINO_SPLASH_HOLD_MS lengthens the hold"
    T0=$SECONDS
    NEUTRINO_SPLASH_HOLD_MS=1500 NEUTRINO_TEST_ORIGIN="$SLOW" NEUTRINO_HOME="$WORK/home-hold" \
        "$APP" >"$WORK/out4" 2>"$WORK/err4"
    RC=$?
    WALL=$((SECONDS - T0))
    H="$(held "$WORK/err4")"
    if [ "$RC" = "0" ] && grep -qa PAYLOAD-RAN "$WORK/out4" && [ -n "$H" ] && [ "$H" -ge 1500 ] && [ "$WALL" -ge 1 ]; then
        echo "  PASS: $STEP (held ${H}ms, ${WALL}s on the wall)"
    else
        nt_fail "$STEP: rc=$RC held='${H:-none}' wall=${WALL}s, wanted at least 1500ms: err=$(errtail "$WORK/err4")"
        FAILURES=$((FAILURES + 1))
    fi

    STEP="NEUTRINO_SPLASH_HOLD_MS cannot shorten the hold"
    NEUTRINO_SPLASH_HOLD_MS=1 NEUTRINO_TEST_ORIGIN="$SLOW" NEUTRINO_HOME="$WORK/home-short" \
        "$APP" >"$WORK/out5" 2>"$WORK/err5"
    RC=$?
    H="$(held "$WORK/err5")"
    if [ "$RC" = "0" ] && grep -qa PAYLOAD-RAN "$WORK/out5" && [ -n "$H" ] && [ "$H" -ge "$HOLD" ]; then
        echo "  PASS: $STEP (held ${H}ms)"
    else
        nt_fail "$STEP: rc=$RC held='${H:-none}', wanted at least $HOLD: err=$(errtail "$WORK/err5")"
        FAILURES=$((FAILURES + 1))
    fi
fi

# --- which side of the handoff the window comes down on -----------------------
# The window used to come down when the bytes stopped, and on windows that is
# nowhere near when anything appears: what happens after the download there is
# cmd.exe on the .cmd -- a certutil over the whole script and, on every
# netinstall launch, a full jsc.exe compile -- before an app is even started.
# nt_exec there does not exec. It spawns and waits, so the window can stay up
# across that, and splash.h's NT_SPLASH_OUTLIVES_HANDOFF is the platform half of
# the rule.
#
# Asserted by *order* rather than by a duration, which is what makes it cost
# nothing and depend on no clock. Both streams go to one file, so the payload's
# own output and this program's teardown line are two entries in one sequence:
# where the launcher outlives the handoff, PAYLOAD-RAN is written while the
# window is still up and therefore lands above `splash: down`; everywhere else
# the process has been replaced by the payload and the teardown is necessarily
# above it. One reading, two directions, and each is a failure on the other's
# platform.
#
# NT_WINDOWS and not a fresh uname: lib.sh already owns that question for the
# whole suite. It is the same platform for the same reason -- it is the one
# whose launcher STARTs a detached exe and returns, which is why there is a
# spawn to wait for at all.
STEP="the window covers the launch on the platform that outlives it"
if [ "$MECHNAME" = "none" ] || [ -z "$MECHNAME" ]; then
    echo "  SKIP: $STEP (nothing draws here)"
else
    NEUTRINO_TEST_ORIGIN="$SLOW" NEUTRINO_HOME="$WORK/home-order" \
        "$APP" >"$WORK/both" 2>&1
    RC=$?
    DOWN_AT="$(grep -an 'splash: down' "$WORK/both" | head -1 | cut -d: -f1)"
    RAN_AT="$(grep -an PAYLOAD-RAN "$WORK/both" | head -1 | cut -d: -f1)"
    if [ "$RC" != "0" ] || [ -z "$DOWN_AT" ] || [ -z "$RAN_AT" ]; then
        nt_fail "$STEP: rc=$RC down='${DOWN_AT:-none}' payload='${RAN_AT:-none}'; one of the two markers never arrived and there is no order to read"
        FAILURES=$((FAILURES + 1))
    elif [ "${NT_WINDOWS:-0}" = "1" ]; then
        if [ "$RAN_AT" -lt "$DOWN_AT" ]; then
            echo "  PASS: $STEP (the payload ran at line $RAN_AT, the window went at $DOWN_AT)"
        else
            nt_fail "$STEP: the window went at line $DOWN_AT and the payload ran at $RAN_AT; this platform waits for the .cmd and the window is supposed to cover that wait"
            FAILURES=$((FAILURES + 1))
        fi
    else
        if [ "$DOWN_AT" -lt "$RAN_AT" ]; then
            echo "  PASS: $STEP (the window went at line $DOWN_AT, before the exec at $RAN_AT)"
        else
            nt_fail "$STEP: the window went at line $DOWN_AT and the payload ran at $RAN_AT; this platform execs, so nothing here can take a window down afterwards and one still up is one nobody holds"
            FAILURES=$((FAILURES + 1))
        fi
    fi
    probe "handoff: payload at line ${RAN_AT:-none}, window down at ${DOWN_AT:-none} (outlives=${NT_WINDOWS:-0})"
fi

# --- a refusal mid-branch still tears down -----------------------------------
# A pin that does not match what the host serves. The download succeeds, the
# digest is checked, and main returns from the middle of the branch -- the path
# that has no teardown of its own and relies entirely on the atexit handler
# registered beside nt_splash_arm. Nine returns live between the fetch and the
# exec and this is the one standing furthest from either end.
#
# Against the slow host, so that the window is really up when the refusal
# happens. Against the quick one this was vacuous everywhere -- the download
# ended before the window was due -- and a teardown that is never exercised is
# a teardown that has not been tested.
STEP="a pin mismatch tears the window down"
BADPIN="$(echo "$PIN" | tr '0-9a-f' '1-9a-f0')"
BADAPP="$(nt_as "$BIN" "demo-127-0-0-1-1$BADPIN" "$WORK/bin")"
NEUTRINO_TEST_ORIGIN="$SLOW" NEUTRINO_HOME="$WORK/home-bad" "$BADAPP" >/dev/null 2>"$WORK/err6"
RC=$?
U="$(ups "$WORK/err6")"; D="$(downs "$WORK/err6")"
if [ "$RC" = "0" ]; then
    nt_fail "$STEP: expected a refusal, got rc=0 -- the fixture is not testing anything"
    FAILURES=$((FAILURES + 1))
elif ! grep -qa "pin mismatch" "$WORK/err6"; then
    nt_fail "$STEP: expected=pin-mismatch actual=$(errtail "$WORK/err6")"
    FAILURES=$((FAILURES + 1))
elif [ "$U" = "$D" ]; then
    # Vacuously true where nothing draws, which is why the count is reported
    # rather than only the verdict: a lane silently at 0/0 is a lane this case
    # is not covering, and that has to be visible from the run page.
    echo "  PASS: $STEP (up=$U down=$D)"
else
    nt_fail "$STEP: up=$U down=$D -- a window was raised and not taken away"
    FAILURES=$((FAILURES + 1))
fi
probe "refusal path: up=$U down=$D"

# --- which display server gets asked, and in what order ----------------------
# A session running XWayland sets both variables, so DISPLAY being present says
# nothing about which server is the native one. The order is therefore not a
# preference to be checked loosely: taking the X path on a wayland session draws
# through a compatibility layer to reach the compositor the other path talks to
# directly.
#
# The fallback half runs everywhere and is the one with a regression to catch --
# a dispatch that treats "WAYLAND_DISPLAY is set" as "wayland is usable" leaves
# every X session with no window the moment a stale variable is exported.
STEP="a WAYLAND_DISPLAY that leads nowhere falls back to X11"
NEUTRINO_TEST_ORIGIN="$SLOW" NEUTRINO_HOME="$WORK/home-fb" WAYLAND_DISPLAY="nt-no-such-compositor" \
    "$APP" >/dev/null 2>"$WORK/err7"
MECH7="$(mech_of "$WORK/err7")"
# What counts as correct depends on what this platform draws with, and the
# first version of this case did not ask -- it expected x11 everywhere, and so
# failed macOS and windows for drawing correctly. X11 is the fallback only where
# X11 is a path at all; elsewhere the variable is meaningless and the mechanism
# must simply be unchanged, which is the claim that actually generalises: a
# stale WAYLAND_DISPLAY must not stop the splash.
case "$MECHNAME" in
    x11|wayland)
        # A machine with a display server. The wayland half is unreachable now,
        # so X11 is what is left -- the one case here that tests a real
        # fallback, and the only one where the mechanism is expected to change.
        case "$(mech_name "$MECH7")" in
            x11)
                echo "  PASS: $STEP" ;;
            none)
                # A compositor and no X server at all -- a wayland session with
                # no XWayland. There is genuinely nothing to fall back to, and
                # failing that would be asserting the machine should have an X
                # server rather than asserting anything about this program.
                if [ -z "${DISPLAY:-}" ]; then
                    echo "  SKIP: $STEP (wayland only; no X server to fall back to)"
                    probe "fallback: wayland-only machine, nothing behind it"
                else
                    nt_fail "$STEP: DISPLAY is set to '$DISPLAY' and the fallback still drew nothing"
                    FAILURES=$((FAILURES + 1))
                fi ;;
            *)
                nt_fail "$STEP: expected x11, got '$MECH7'"
                FAILURES=$((FAILURES + 1)) ;;
        esac ;;
    none)
        echo "  SKIP: $STEP (nothing draws here, so there is nothing to fall back to)"
        probe "fallback: nothing to fall back to, got '$MECH7'" ;;
    *)
        if [ "$(mech_name "$MECH7")" = "$MECHNAME" ]; then
            echo "  PASS: $STEP (inert here; still $MECHNAME)"
        else
            nt_fail "$STEP: a meaningless WAYLAND_DISPLAY turned $MECHNAME into '$(mech_name "$MECH7")'"
            FAILURES=$((FAILURES + 1))
        fi ;;
esac

# The preference half needs a compositor, which a CI runner does not have. It is
# asserted where one exists and reported as absent where it does not, rather
# than quietly not being covered.
STEP="wayland is preferred when both are reachable"
WLSOCK=""
for c in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-*; do
    case "$c" in *.lock) continue ;; esac
    [ -S "$c" ] && { WLSOCK="$(basename "$c")"; break; }
done
if [ -z "$WLSOCK" ]; then
    echo "  SKIP: $STEP (no compositor on this machine)"
    probe "preference: no compositor to check against"
else
    NEUTRINO_TEST_ORIGIN="$SLOW" NEUTRINO_HOME="$WORK/home-wl" WAYLAND_DISPLAY="$WLSOCK" \
        "$APP" >/dev/null 2>"$WORK/err8"
    MECH8="$(mech_of "$WORK/err8")"
    case "$MECH8" in
        wayland*) echo "  PASS: $STEP"; probe "preference: chose $MECH8 with DISPLAY also set" ;;
        *) nt_fail "$STEP: a compositor is up at $WLSOCK and the choice was '$MECH8'"
           FAILURES=$((FAILURES + 1)) ;;
    esac
fi

# --- the picture, and the proof that it moves --------------------------------
# One photograph of the window and then a burst of six, for the lane's sheet.
#
# The single frame is the portrait: it goes on the page at the top of the
# netinstall group, and it is what a reader compares against the other three
# lanes when the question is whether the four windows are the same window. The
# burst is the other question, which one photograph cannot answer at all: the
# indicator steps once every NT_SPLASH_FRAME_MS, and a still of it is
# indistinguishable from an indicator that has stopped. Six frames across most
# of one cycle are enough for the sheet to animate and enough to assert
# against -- see nt_distinct_frames in lib.sh for what that assertion can and
# cannot see.
#
# Neither is an assertion about pixels; nothing here reads a picture back. But
# the shutter has to fire while the window is up, and that part is asserted: a
# picture taken after the down line is a picture of the desktop, captioned as
# the splash.
#
# The hold is what makes it possible, and it is longer than it used to be. The
# window is up for the stall and then the hold, and a screenshot on Windows
# starts a powershell that can take seconds to load System.Drawing -- once for
# the portrait and once for the whole burst. So the run is told to hold for
# twenty seconds, both shutters fire as soon as the up line is seen, and the run
# is then left to finish on its own: the payload still has to run, because a
# picture of a launcher that never launched is not a picture of the feature.
#
# Only where the lane asked for it. NEUTRINO_SPLASH_SHOTS names the directory;
# unset, the case is skipped rather than writing pictures into a developer's
# home, and the skip is on the record.
STEP="the window photographed while it is up"
FRAMES=6
FRAME_GAP_MS=130
DISTINCT=0
BURST=SKIP
if [ -z "${NEUTRINO_SPLASH_SHOTS:-}" ]; then
    echo "  SKIP: $STEP (NEUTRINO_SPLASH_SHOTS is unset; no picture wanted)"
    probe "picture: not asked for"
elif [ "$MECHNAME" = "none" ] || [ -z "$MECHNAME" ]; then
    echo "  SKIP: $STEP (nothing draws here; nothing to photograph)"
    probe "picture: nothing draws, nothing to photograph"
else
    SHOT="$NEUTRINO_SPLASH_SHOTS/splash-$MECHNAME.png"
    # Started in this shell and not a subshell, unlike the orphan check below:
    # this run is waited for, and a pid started under parentheses is not one
    # `wait` knows.
    NEUTRINO_SPLASH_HOLD_MS=20000 NEUTRINO_TEST_ORIGIN="$SLOW" NEUTRINO_HOME="$WORK/home-shot" \
        "$APP" >"$WORK/out9" 2>"$WORK/err9" &
    SHOTPID=$!
    RAISED=NO
    for i in $(seq 1 100); do
        grep -qa 'netinstall: splash: up:' "$WORK/err9" 2>/dev/null && { RAISED=YES; break; }
        grep -qa 'netinstall: splash: none:' "$WORK/err9" 2>/dev/null && break
        sleep 0.1
    done
    TAKEN=NO
    if [ "$RAISED" = "YES" ]; then
        T0=$SECONDS
        nt_screenshot "$SHOT" && TAKEN=YES
        BURST=NO
        nt_screenshot_burst "$NEUTRINO_SPLASH_SHOTS" "splash-$MECHNAME" \
            "$FRAMES" "$FRAME_GAP_MS" && BURST=YES
        DISTINCT="$(nt_distinct_frames "$NEUTRINO_SPLASH_SHOTS/splash-$MECHNAME"-anim-*.png)"
        SHUTTER=$((SECONDS - T0))
    fi
    wait "$SHOTPID" 2>/dev/null
    RC=$?
    D="$(downs "$WORK/err9")"
    if [ "$RAISED" != "YES" ]; then
        nt_fail "$STEP: the window that came up for every case above did not come up for this one: err=$(errtail "$WORK/err9")"
        FAILURES=$((FAILURES + 1))
    elif [ "$TAKEN" != "YES" ]; then
        nt_fail "$STEP: the capture wrote nothing to $SHOT"
        FAILURES=$((FAILURES + 1))
    elif [ "$RC" != "0" ] || ! grep -qa PAYLOAD-RAN "$WORK/out9"; then
        nt_fail "$STEP: the run behind the picture did not finish: rc=$RC err=$(errtail "$WORK/err9")"
        FAILURES=$((FAILURES + 1))
    else
        # Whether both shutters beat the teardown. The down line is written when
        # the window goes; the captures returned before this check, so a hold
        # that had already run out means the pictures may be of nothing.
        # Re-read after the wait, so the check is against the held number rather
        # than a race with the file.
        H="$(held "$WORK/err9")"
        if [ -n "$H" ] && [ "$H" -ge 20000 ] && [ "$SHUTTER" -lt 20 ]; then
            echo "  PASS: $STEP ($(wc -c < "$SHOT" | tr -d ' ') bytes, shutter and burst ${SHUTTER}s into an ${H}ms hold)"
        else
            nt_fail "$STEP: the shutter took ${SHUTTER}s against a hold of ${H:-none}ms -- the pictures may be of an empty desktop"
            FAILURES=$((FAILURES + 1))
        fi
    fi
    probe "picture: raised=$RAISED taken=$TAKEN burst=$BURST frames=$FRAMES distinct=$DISTINCT down=$D at $SHOT"
fi

# --- the indicator is an indicator -------------------------------------------
# The one case here that is about what the window contains rather than about
# whether it exists. Six frames of a moving indicator are not all the same
# picture; six frames of one that has stopped are. A third of them differing is
# the floor: the frames are a hundred and thirty milliseconds apart against a
# cycle of NT_SPLASH_CELLS * NT_SPLASH_FRAME_MS, so a healthy window gives five
# or six distinct, and asking for three leaves room for a runner whose captures
# are slow enough to land twice on the same phase.
#
# What this cannot tell apart is a splash that is moving from a desktop that is
# moving behind it. The four lanes that reach this are a bare Xvfb, a headless
# sway and two runners with nothing else on screen, which is why the reading is
# worth having; it is a floor and not a proof, and it is reported with its own
# count so a lane where it starts passing for the wrong reason can be seen.
STEP="the indicator moved while it was photographed"
if [ "$BURST" = "SKIP" ]; then
    echo "  SKIP: $STEP (no burst was taken)"
elif [ "$BURST" != "YES" ]; then
    nt_fail "$STEP: the burst wrote fewer than $FRAMES frames"
    FAILURES=$((FAILURES + 1))
elif [ "$DISTINCT" -ge 3 ]; then
    echo "  PASS: $STEP ($DISTINCT of $FRAMES frames differ)"
else
    nt_fail "$STEP: $DISTINCT of $FRAMES frames differ -- the window is on screen and not moving"
    FAILURES=$((FAILURES + 1))
fi

# --- the parent dies without tearing down ------------------------------------
# The window is held by a separate process, so every way this program can stop
# without running any code of its own -- a crash, a SIGKILL, an OOM -- is a way
# to leave a window on someone's screen with nothing left that knows its pid.
# Nothing in netinstall can run at that moment by definition, so the guarantee
# has to come from the kernel; on linux that is PR_SET_PDEATHSIG, set by the
# child on itself immediately after the fork.
#
# hostile.py's dribble shape is what makes the case reachable: one byte a
# second, forever, so the fetch is still running and the window still up when
# the parent is killed. The pin never matches and never gets the chance to.
STEP="a killed parent leaves no window behind"
SLOWAPP="$(nt_as "$BIN" "dribble-127-0-0-1-1$PIN" "$WORK/bin")"
( NEUTRINO_TEST_ORIGIN="$SLOW" NEUTRINO_HOME="$WORK/home-slow" \
    "$SLOWAPP" >/dev/null 2>"$WORK/err10" & echo $! > "$WORK/slow.pid" )
SLOWPID="$(cat "$WORK/slow.pid")"
# Wait for the window rather than for a fixed interval: on a lane with no
# display this never arrives, and the case says so instead of timing out.
RAISED=NO
for i in $(seq 1 100); do
    grep -qa 'netinstall: splash: up:' "$WORK/err10" 2>/dev/null && { RAISED=YES; break; }
    grep -qa 'netinstall: splash: none:' "$WORK/err10" 2>/dev/null && break
    sleep 0.1
done
if [ "$RAISED" != "YES" ]; then
    # Not a failure. It is the same "nothing draws here" this whole suite
    # reports rather than asserts, and it is said out loud so a lane that
    # silently stopped covering this is visible.
    probe "orphan check: skipped, nothing draws on this display"
    echo "  SKIP: $STEP (no window on this display)"
    kill -9 "$SLOWPID" 2>/dev/null
else
    # The holder is the child that is not the downloader. There are two now:
    # the window is raised from inside the fetch's wait, so curl is forked
    # first and has the lower pid, and the first child by number is the one
    # process here that is supposed to outlive its parent -- a reparented
    # curl keeps dribbling until its own deadline. Taking it for the holder
    # reported the kernel's guarantee as broken while the window was long
    # gone. Measured, the round this suite moved to the stalled host.
    #
    # The basename, and not what ps prints. The two platforms disagree about
    # what `comm` is: linux gives the name alone, macOS gives the whole path,
    # so a pattern anchored at `curl` matched on one and not the other -- and
    # the one it missed is the one where the holder is a separate process, so
    # macOS picked curl for the holder and failed a control that was working.
    # Measured on run 33750772253: "splash process 9954 outlived a SIGKILLed
    # parent", with the window itself long gone.
    HELD=""
    HELDNAME=""
    KIDS=""
    for p in $(pgrep -P "$SLOWPID" 2>/dev/null); do
        C="$(ps -o comm= -p "$p" 2>/dev/null)"
        C="${C##*/}"
        KIDS="$KIDS $p:${C:-?}"
        case "$C" in
            curl*|wget*) ;;
            *) [ -n "$HELD" ] || { HELD="$p"; HELDNAME="${C:-?}"; } ;;
        esac
    done
    if [ -z "$HELD" ] && [ "$MECHNAME" = "win32" ]; then
        # Windows draws on a thread of the launcher's own process, so there
        # is no child to orphan and nothing for this case to catch: the
        # window cannot outlive the process because it is inside it. Said
        # out loud rather than passed quietly, so that a platform which
        # stops using a child is visible instead of silently uncovered.
        echo "  SKIP: $STEP (the window is in-process here, so it cannot be orphaned)"
        probe "orphan check: skipped, $MECHNAME holds the window in-process"
        kill -9 "$SLOWPID" 2>/dev/null
    elif [ -z "$HELD" ]; then
        nt_fail "$STEP: a window is up but no child is holding it -- the control is broken, not the case; children were${KIDS:- none}"
        FAILURES=$((FAILURES + 1))
        kill -9 "$SLOWPID" 2>/dev/null
    else
        kill -9 "$SLOWPID" 2>/dev/null
        GONE=NO
        for i in $(seq 1 50); do
            kill -0 "$HELD" 2>/dev/null || { GONE=YES; break; }
            sleep 0.1
        done
        if [ "$GONE" = "YES" ]; then
            echo "  PASS: $STEP"
        else
            nt_fail "$STEP: splash process $HELD ($HELDNAME) outlived a SIGKILLed parent; children were$KIDS"
            FAILURES=$((FAILURES + 1))
            kill -9 "$HELD" 2>/dev/null
        fi
        probe "orphan check: parent killed, holder $HELD ($HELDNAME) gone=$GONE, children were$KIDS"
    fi
fi
wait "$SLOWPID" 2>/dev/null

# --- what this platform can actually draw ------------------------------------
# Asserted to the measured value rather than to a hope, per SANDBOX ground rule
# 6: a platform that gains or loses a splash mechanism is a failure here and not
# a silence.
probe "mechanism: ${MECH:-<none reported>}"

cat "$RESULTS"
echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
