#!/bin/bash
# envlen.sh - the allowlist, held to what it delivers rather than what it counts
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# nt_env_drop used to copy a variable's name into a 256-byte buffer and truncate
# anything longer, and the POSIX nt_env_scrub used to remove names by restarting
# its walk after every removal, bounded by the number of entries it counted:
#
#     for (i = 0; i <= seen; i++) {
#         ... find the first entry nt_env_keep says no to ...
#         if (found < 0) break;
#         nt_env_drop(environ[found], ...);
#     }
#
# A name the drop could not express was a name the next pass found in exactly
# the same place, and the pass after that, until the bound ran out. The walk did
# not skip what it could not remove; it stopped at it, and everything the
# allowlist was going to drop after that point went to the app -- while the
# count it returned was unchanged, because that count is a prediction.
#
# Measured on all four POSIX lanes before the fix, with one 300-character name
# in front of the battery: nine markers including SSH_AUTH_SOCK reached the
# payload, and --info reported 116 of 131 variables dropped while nothing at all
# had been. An entry whose name is empty did the same thing with no length in
# it. And a truncated name is not always a name that does not exist -- QT_ plus
# 252 characters is a name the allowlist keeps, and it is what the 259-character
# name beside it truncates to, so the drop removed the keeper: keep255=GONE on
# every POSIX lane.
#
# Every one of those readings is asserted here to its value after the fix, so a
# change in either direction is a failure and not silence:
#
#   ceiling     the length of a name this platform delivers across execv. Every
#               lane delivered 65536; the suite needs 300 and asserts that much,
#               because below 256 the finding could not be reproduced at all and
#               a green tick would mean nothing.
#   scrub       nine markers dropped with the undroppable name in front of them
#               and behind them, and the name itself dropped too. Was 0/9 (1/9
#               on macOS, where the runner's own SSH_AUTH_SOCK sat ahead of it)
#               with the name surviving.
#   truncation  keep255 arrives and drop259 does not, which is the pair the
#               other way round from what round 1 measured. Windows has no
#               prefix that admits a long keeper -- nt_env_prefixes is
#               #ifndef _WIN32 -- so it asserts that instead, off its control.
#   own prefix  NEUTRINO_ padded to 255 and the same name with PATH on the end
#               both arrive, on every lane. An own prefix is kept without the
#               loader test, which is why nothing under one can be the victim.
#   unsetlen    the name goes away at 8 through 4096 characters. Windows still
#               removes by name and this is what its heap-built name rests on.
#   emptyname   the entry no shell can build, dropped like any other.
#   setafter    the fix's one dependency: setenv still works on an environ this
#               program allocated rather than the libc. main() scrubs and then
#               sets five XDG directories, and a libc that refused would lose
#               all five silently.
#
# The controls are what keep the rest honest, because a scrub that dropped
# *everything* would satisfy every GONE above: the keeper has to arrive, the
# plain prefix-admitted name has to arrive, and the own-prefix pair has to
# arrive. env.sh's whole keeper battery is the same assertion at more length.

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: envlen.sh <netinstall built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"
trap 'kill ${NT_SERVER_PID:-} 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0

# A name of exactly $2 characters, starting with $1 and padded with $3. Doubled
# rather than appended one at a time: the ceiling probe asks for 65536 and a
# shell loop that long is the slowest thing in this suite.
nt_pad() {
    local pre="$1" total="$2" ch="$3" fill=""

    if [ "$total" -le "${#pre}" ]; then
        printf '%s' "${pre:0:$total}"
        return
    fi
    while [ "${#fill}" -lt "$((total - ${#pre}))" ]; do
        fill="$fill$fill$ch"
    done
    printf '%s%s' "$pre" "${fill:0:$((total - ${#pre}))}"
}

# =====================================================================
# The instrument
# =====================================================================
NT_CC="${NETINSTALL_CC:-cc}"
PROBE="$WORK/envlen-probe$NT_EXE"
PROBE_STATE=BUILT
# shellcheck disable=SC2086
$NT_CC -o "$PROBE" "$ROOT/netinstall/test/envlen-probe.c" >"$WORK/cc.log" 2>&1 ||
    PROBE_STATE="FAILED: $(tr '\n' ' ' < "$WORK/cc.log" | cut -c1-160)"
[ -x "$PROBE" ] || PROBE_STATE="${PROBE_STATE%%:*}: no output"
echo "=== envlen-probe: $PROBE_STATE ==="
if [ "$PROBE_STATE" != "BUILT" ]; then
    # Every section below reads through it. A suite that cannot build its own
    # instrument has measured nothing and must not report a shape of silence
    # that looks like an answer.
    nt_fail "envlen-probe did not build: $PROBE_STATE"
    nt_result "report: envlen probe=$PROBE_STATE -- nothing else in this suite ran"
    exit 1
fi

# =====================================================================
# A -- how long a name this platform delivers across execv
# =====================================================================
#
# 255 is the last length nt_env_drop can express and 256 is the first it
# cannot, so those two are the whole question; the rest are there to say
# whether the ceiling is the kernel's, the shell's or nobody's.
echo "=== A: the length of a name that survives exec ==="
CEIL_OK=""
CEIL_NO=""
CEIL_MAX=0
for n in 8 64 200 255 256 257 512 1024 4096 16384 65536; do
    NAME="$(nt_pad NT_EL_C "$n" C)"
    OUT="$(env "$NAME=1" "$PROBE" emit 2>"$WORK/ceil.err")"
    RC=$?
    if [ "$RC" = 0 ] && awk -v n="$n" '$2 == "name" && $3 == n && $4 ~ /^NT_EL_C/ { f = 1 }
                                       END { exit !f }' <<<"$OUT"; then
        CEIL_OK="$CEIL_OK $n"
        [ "$n" -gt "$CEIL_MAX" ] && CEIL_MAX="$n"
    else
        CEIL_NO="$CEIL_NO $n(rc=$RC)"
    fi
done
echo "  delivered:$CEIL_OK"
echo "  refused:$CEIL_NO"
nt_result "report: envlen ceiling delivered=[${CEIL_OK# }] refused=[${CEIL_NO# }] max=$CEIL_MAX"
# Not the whole list -- 65536 is where the probe stopped asking, not a platform
# promise. 300 is what the rest of this suite spends, and 256 is the first
# length the old buffer could not express: below that there is nothing here to
# measure and a green tick would be one earned by a name that never arrived.
if [ "$CEIL_MAX" -ge 300 ]; then
    echo "  PASS: this platform delivers the 300-character name the suite uses"
else
    nt_fail "ceiling expected=>=300 actual=$CEIL_MAX; the rest of this suite cannot run"
    FAILURES=$((FAILURES + 1))
fi

# The length everything below uses for "a name the drop cannot express". 300 if
# the platform delivers it; otherwise the largest it does, and if that is at or
# under 255 the finding does not exist here and the sections below say so
# instead of inventing a reading.
LONG_LEN=300
[ "$CEIL_MAX" -lt 300 ] && LONG_LEN="$CEIL_MAX"
LONG_REACHABLE=1
[ "$LONG_LEN" -le 255 ] && LONG_REACHABLE=0
LONG="$(nt_pad NT_EL_LONG_ "$LONG_LEN" L)"

# =====================================================================
# The battery and the payload
# =====================================================================
#
# Eight markers outside the allowlist and one inside it. SSH_AUTH_SOCK is in
# there by name because it is the example env.c's own header gives for the
# thing an allowlist exists to remove -- a live agent that will sign anything,
# living nowhere but in a variable.
NT_MARKS="NT_EL_M1 NT_EL_M2 NT_EL_M3 NT_EL_M4 NT_EL_M5 NT_EL_M6 NT_EL_M7 NT_EL_M8 SSH_AUTH_SOCK"
NT_KEEP="NEUTRINO_EL_KEPT"

nt_serve_payload() {
    if [ "$NT_WINDOWS" = "1" ]; then
        # cmd.exe, for the same reason privs.sh uses it: sh payloads do not run
        # here, and this is the one suite that wants a reading from the platform
        # whose scrub is written differently.
        cat > "$SERVE/envlen.cmd" <<'BATCH'
@echo off
echo PROBE_BEGIN
for %%V in (%NEUTRINO_TEST_BATTERY%) do (if defined %%V (echo env %%V SEEN) else (echo env %%V GONE))
echo PROBE_END
BATCH
    else
        cat > "$SERVE/envlen.cmd" <<'SH'
echo PROBE_BEGIN
for n in $NEUTRINO_TEST_BATTERY; do
    eval "v=\${$n+SEEN}"
    echo "env $n ${v:-GONE}"
done
echo PROBE_END
SH
    fi
}
nt_serve_payload
nt_serve "$SERVE" || exit 2
SPEC="envlen-com-example-0$(nt_pin "$SERVE/envlen.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"

# Ran once here so every reading below is about the scrub and not about a
# download; the pin is re-checked on every launch either way.
if ! env NEUTRINO_TEST_BATTERY="$NT_KEEP" "$APP" >/dev/null 2>"$WORK/warm.err"; then
    nt_fail "the payload did not run at all: $(tr '\n' ' ' < "$WORK/warm.err" | cut -c1-300)"
    FAILURES=$((FAILURES + 1))
fi

# Runs the payload with a battery and an environment, and answers with the
# SEEN/GONE lines. $1 is the battery, the rest are NAME=VALUE.
run_payload() {
    local battery="$1"; shift
    nt_timeout 120 env "$@" NEUTRINO_TEST_BATTERY="$battery" "$APP" 2>/dev/null
}

# How many of $2 are GONE in the output $1, and whether the keeper arrived.
count_gone() {
    local out="$1" n gone=0 total=0
    for n in $2; do
        total=$((total + 1))
        grep -qx "env $n GONE" <<<"$out" && gone=$((gone + 1))
    done
    printf '%d/%d' "$gone" "$total"
}
# String equality, line by line, and no pattern anywhere. These names are up to
# 259 characters of data and they were being handed to grep as *regexes*: the
# netbsd lane read own259=UNREPORTED for a name its own payload had reported
# SEEN -- proved by the namelens line below, which is byte-identical to
# FreeBSD's. Whatever that grep does with a pattern that long is not worth
# knowing, because a name is data and comparing it as a pattern was the bug.
# -F would have been enough; this needs no external program at all.
seen_state() {
    local line
    while IFS= read -r line; do
        # The windows payload is cmd.exe and its echo writes CRLF. grep is an
        # MSYS program and strips that on the way in; `read` is a bash builtin
        # and does not -- so swapping one for the other changed what the
        # comparison was looking at, and seven readings on that lane went
        # UNREPORTED for a payload that had reported every one of them. The
        # translation was never this suite's to rely on; strip it here, where
        # it can be seen.
        line="${line%$'\r'}"
        if [ "$line" = "env $2 SEEN" ]; then printf SEEN; return; fi
        if [ "$line" = "env $2 GONE" ]; then printf GONE; return; fi
    done <<<"$1"
    printf UNREPORTED
}
ran() { grep -qx PROBE_END <<<"$1"; }

# Every reading below was measured before the fix and is asserted to its value
# after it, so each of these would have failed on the commit before this one.
check_eq() {
    local label="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        echo "  PASS: $label ($got)"
    else
        nt_fail "$label expected=$want actual=$got"
        FAILURES=$((FAILURES + 1))
    fi
}

# =====================================================================
# B -- the scrub, end to end, with an undroppable name in the way
# =====================================================================
echo "=== B: the scrub, with and without a name the drop cannot express ==="
BATTERY="$NT_MARKS $NT_KEEP $LONG"
MARKSET=()
for n in $NT_MARKS; do
    MARKSET+=("$n=/nonexistent/neutrino-envlen")
done
MARKSET+=("$NT_KEEP=kept-control")

CTL_OUT="$(run_payload "$NT_MARKS $NT_KEEP" "${MARKSET[@]}")"
FIRST_OUT=""
LAST_OUT=""
if [ "$LONG_REACHABLE" = 1 ]; then
    # env(1) appends new names in the order it is given them, so this is the
    # only handle there is on where the undroppable entry sits relative to the
    # ones the walk is supposed to reach after it.
    FIRST_OUT="$(run_payload "$BATTERY" "$LONG=1" "${MARKSET[@]}")"
    LAST_OUT="$(run_payload "$BATTERY" "${MARKSET[@]}" "$LONG=1")"
fi

for label in ctl first last; do
    case "$label" in
        ctl) o="$CTL_OUT" ;; first) o="$FIRST_OUT" ;; last) o="$LAST_OUT" ;;
    esac
    [ "$label" != ctl ] && [ "$LONG_REACHABLE" != 1 ] && continue
    if ran "$o"; then
        echo "  $label: the payload ran"
    else
        nt_fail "the $label run's payload never finished: $(tr '\n' ' ' <<<"$o" | cut -c1-200)"
        FAILURES=$((FAILURES + 1))
    fi
done

CTL_GONE="$(count_gone "$CTL_OUT" "$NT_MARKS")"
CTL_KEEP="$(seen_state "$CTL_OUT" "$NT_KEEP")"
if [ "$CTL_GONE" = "9/9" ]; then
    echo "  PASS: with nothing in the way the scrub removes all nine markers"
else
    # The positive control. Without it every reading below is satisfied by a
    # scrub that never ran, and by a payload that reported GONE for names the
    # runner never set.
    nt_fail "control expected=9/9 markers dropped actual=$CTL_GONE"
    FAILURES=$((FAILURES + 1))
fi
if [ "$CTL_KEEP" = SEEN ]; then
    echo "  PASS: the keeper arrived, so the payload can tell SEEN from GONE"
else
    nt_fail "keeper control expected=SEEN actual=$CTL_KEEP"
    FAILURES=$((FAILURES + 1))
fi

if [ "$LONG_REACHABLE" = 1 ]; then
    FIRST_GONE="$(count_gone "$FIRST_OUT" "$NT_MARKS")"
    LAST_GONE="$(count_gone "$LAST_OUT" "$NT_MARKS")"
    FIRST_LONG="$(seen_state "$FIRST_OUT" "$LONG")"
    LAST_LONG="$(seen_state "$LAST_OUT" "$LONG")"
    # Which markers survived, and in which run, so "the walk stopped here" can
    # be told from "the walk skipped some".
    SURV_F=""
    SURV_L=""
    for n in $NT_MARKS; do
        [ "$(seen_state "$FIRST_OUT" "$n")" = SEEN ] && SURV_F="$SURV_F $n"
        [ "$(seen_state "$LAST_OUT" "$n")" = SEEN ] && SURV_L="$SURV_L $n"
    done
    nt_result "report: envlen scrub len=$LONG_LEN ctl=$CTL_GONE keeper=$CTL_KEEP \
first=$FIRST_GONE(long=$FIRST_LONG survivors=[${SURV_F# }]) \
last=$LAST_GONE(long=$LAST_LONG survivors=[${SURV_L# }])"
    # Was 0/9 on gjs, kde and openbsd and 1/9 on macOS, with the name itself
    # surviving on all six. The walk it stopped at is gone.
    check_eq "the markers are dropped with the long name in front" 9/9 "$FIRST_GONE"
    check_eq "the markers are dropped with the long name behind"   9/9 "$LAST_GONE"
    check_eq "the long name is dropped too, in front" GONE "$FIRST_LONG"
    check_eq "the long name is dropped too, behind"   GONE "$LAST_LONG"
else
    nt_result "report: envlen scrub len=$LONG_LEN UNREACHABLE ctl=$CTL_GONE keeper=$CTL_KEEP \
-- no name over 255 characters reaches a child here"
fi

# The order the entries were actually in before netinstall touched them, which
# is what makes the first/last pair mean anything: the walk stops at the first
# entry it cannot drop, so what survives is what sits after it. SSH_AUTH_SOCK is
# in here as well as the markers because it is the one name a runner may have
# set for itself, and where it happened to sit decides whether it is in the
# survivors or not.
nt_positions() {
    awk -v L="$LONG_LEN" '$2 == "name" { i++ }
         $2 == "name" && $3 == L { l = i }
         $2 == "name" && $4 == "NT_EL_M1" { m = i }
         $2 == "name" && $4 == "SSH_AUTH_SOCK" { s = i }
         END { printf "long=%s m1=%s ssh=%s of=%s", l ? l : "none", m ? m : "none",
                      s ? s : "none", i }'
}
ORD_LINE="not measured"
if [ "$LONG_REACHABLE" = 1 ]; then
    ORD_FIRST="$(env "$LONG=1" "${MARKSET[@]}" "$PROBE" emit | nt_positions)"
    ORD_LAST="$(env "${MARKSET[@]}" "$LONG=1" "$PROBE" emit | nt_positions)"
    ORD_LINE="first-run[$ORD_FIRST] last-run[$ORD_LAST]"
    # Windows hands back a block sorted by name, so the order env(1) was given
    # does not survive and the first/last pair is one reading there rather than
    # two. Said out loud, because two identical numbers otherwise read as a
    # measurement that happened to agree.
    [ "$ORD_FIRST" = "$ORD_LAST" ] &&
        ORD_LINE="$ORD_LINE(identical: this platform did not keep the order it was given)"
fi

# =====================================================================
# C -- what --info claims while that is going on
# =====================================================================
echo "=== C: what --info says was dropped ==="
info_env() {
    env "$@" "$APP" --info 2>/dev/null |
        awk '$1 == "env" { $1 = ""; sub(/^ +/, ""); print }'
}
INFO_CTL="$(info_env "${MARKSET[@]}")"
INFO_LONG="not measured"
[ "$LONG_REACHABLE" = 1 ] && INFO_LONG="$(info_env "$LONG=1" "${MARKSET[@]}")"
echo "  ctl:  $INFO_CTL"
echo "  long: $INFO_LONG"
nt_result "report: envlen info ctl='$INFO_CTL' with-long='$INFO_LONG' order=$ORD_LINE"

# =====================================================================
# D -- a truncated name is the name of something else
# =====================================================================
#
# nt_env_drop truncates to 255 characters. QT_ + 252 padding is a name the
# allowlist keeps -- prefix-admitted, no loader shape in it -- and the same
# string with PATH on the end is one it drops. Truncating the second produces
# the first exactly, so the question is not whether the drop fails; it is
# whether it removes a variable the allowlist was told to keep.
#
# Which decides the fix: if it does, a larger buffer moves the accident rather
# than removing it, and only never truncating will do.
#
# The hazard needs a namespace that is admitted by prefix and then loader-tested
# by name, because that is the only shape where one name is kept and a longer
# name starting with it is dropped. Two of the allowlist's three mechanisms
# cannot produce it: exact names are all short, and an own prefix -- NEUTRINO_,
# PROCESSOR_ -- is kept *without* the loader test, so nothing under it is ever
# dropped. Round 1 read keep255=GONE on windows and it was not this finding:
# nt_env_prefixes is #ifndef _WIN32, so QT_ is not admitted there at all and the
# name was dropped for never having been a keeper. The control said so --
# control-keep255 came back GONE too -- and that is now what the reading says
# instead of leaving it to be inferred.
echo "=== D: what a truncated name names ==="
D_KEEP="$(nt_pad QT_ 255 K)"
D_DROP="${D_KEEP}PATH"
D_CTLKEEP="QT_EL_CTLKEEP"
# The own-prefix pair, measured on every lane because it is the same claim on
# all of them: NEUTRINO_ is an own prefix everywhere, and PATH in the middle of
# an own-prefixed name does not make it a loader knob.
D_OWN="$(nt_pad NEUTRINO_ 255 K)"
D_OWNDROP="${D_OWN}PATH"
D_STATE="not measured"
if [ "$CEIL_MAX" -ge 259 ]; then
    D_BATTERY="$D_KEEP $D_DROP $D_CTLKEEP $D_OWN $D_OWNDROP $NT_KEEP"
    D_OUT="$(run_payload "$D_BATTERY" "$D_KEEP=1" "$D_DROP=1" "$D_CTLKEEP=1" \
        "$D_OWN=1" "$D_OWNDROP=1" "$NT_KEEP=kept-control")"
    # The control run: the keeper on its own, with nothing to truncate onto it.
    # It is what tells "the drop removed it" from "this platform never kept it".
    D_CTL_OUT="$(run_payload "$D_BATTERY" "$D_KEEP=1" "$D_CTLKEEP=1" \
        "$D_OWN=1" "$NT_KEEP=kept-control")"
    D_CTL255="$(seen_state "$D_CTL_OUT" "$D_KEEP")"
    D_255="$(seen_state "$D_OUT" "$D_KEEP")"
    D_259="$(seen_state "$D_OUT" "$D_DROP")"
    D_OWN255="$(seen_state "$D_OUT" "$D_OWN")"
    D_OWN259="$(seen_state "$D_OUT" "$D_OWNDROP")"
    D_OWNPAIR="own255=$D_OWN255 own259=$D_OWN259"
    if [ "$D_CTL255" != SEEN ]; then
        D_STATE="UNMEASURABLE no prefix here admits a long keeper \
(control-keep255=$D_CTL255, plainkeeper=$(seen_state "$D_CTL_OUT" "$D_CTLKEEP")) \
drop259=$D_259 $D_OWNPAIR"
    else
        D_STATE="keep255=$D_255 drop259=$D_259 \
plainkeeper=$(seen_state "$D_OUT" "$D_CTLKEEP") control-keep255=$D_CTL255 $D_OWNPAIR"
    fi
    if ran "$D_OUT" && ran "$D_CTL_OUT"; then
        echo "  $D_STATE"
    else
        nt_fail "the truncation run's payload never finished"
        FAILURES=$((FAILURES + 1))
    fi
    # The 259-character name is dropped everywhere, and it is the one thing this
    # section can assert on a platform that keeps no long name.
    check_eq "the 259-character loader name is dropped" GONE "$D_259"
    if [ "$D_CTL255" = SEEN ]; then
        # Was keep255=GONE drop259=SEEN on all four POSIX lanes: exactly this
        # pair, the other way round.
        check_eq "the 255-character keeper is not truncated away" SEEN "$D_255"
        check_eq "and it still arrives with nothing to truncate onto it" \
            SEEN "$D_CTL255"
    else
        # Windows: nt_env_prefixes is #ifndef _WIN32, so QT_ is not admitted and
        # there is no long keeper to lose. Asserted so a prefix added there
        # later has to answer for it.
        check_eq "no prefix here admits a long keeper, so neither name is one" \
            GONE "$D_255"
    fi
    # An own prefix is kept without the loader test, which is why nothing under
    # one can ever be a truncation's victim. True on every lane, PATH and all.
    check_eq "an own-prefixed 255-character name arrives" SEEN "$D_OWN255"
    check_eq "so does the same name with a loader shape in it" SEEN "$D_OWN259"
else
    D_STATE="UNREACHABLE -- this platform delivers at most $CEIL_MAX characters"
fi
nt_result "report: envlen truncation $D_STATE"
# UNREPORTED means the payload said nothing about a name either way, and the two
# ways that happens look identical from here: the name never arrived at all, or
# it arrived under a different spelling because something truncated it -- in
# which case two of these are the same length and one of them is a name the
# battery never sent. NetBSD read own259=UNREPORTED where every other lane reads
# SEEN, so say what did arrive and how long each one was.
if [ "$D_STATE" != "not measured" ]; then
    nt_result "report: envlen namelens $(printf '%s\n' "$D_OUT" |
        awk '$1 == "env" { printf "%s:%s ", length($2), $3 }')"
fi

# =====================================================================
# E -- can a fix that stops truncating hand this libc the name at all
# =====================================================================
echo "=== E: setenv and unsetenv against a long name ==="
E_LINE=""
for n in 8 255 256 300 4096; do
    E_ONE="$("$PROBE" unsetlen "$n" |
        awk '{ for (i = 4; i <= 7; i++) { sub(/^[a-z]+=/, "", $i) }
               printf "%s=%s/%s/%s/%s", $3, $4, $5, $6, $7 }')"
    E_LINE="$E_LINE $E_ONE"
    # Windows still removes a variable by name, and its heap-built name is only
    # a fix if the platform accepts it. The POSIX lanes no longer depend on
    # this; they are asserted anyway, because it is what says the finding was
    # about the buffer and never about the libc.
    check_eq "a ${n}-character name can be set and removed" "$n=0/yes/0/gone" "$E_ONE"
done
echo " $E_LINE"
nt_result "report: envlen unsetlen(len=setrc/present/unsetrc/after)$E_LINE"

# =====================================================================
# F -- the entry whose name is empty
# =====================================================================
#
# No shell can build this one: env(1) refuses an assignment with nothing on the
# left of the '='. nt_env_scrub splits at the first '=' and hands the drop a
# length of zero, so the finding has a second trigger that needs no long name --
# and the windows scrub, which skips these by hand, does not share it.
echo "=== F: an environ entry with no name ==="
if [ "$NT_WINDOWS" = "1" ]; then
    F_STATE="SKIP the windows scrub skips '=' entries by name"
else
    F_OUT="$(nt_timeout 120 env "${MARKSET[@]}" NEUTRINO_TEST_BATTERY="$NT_MARKS $NT_KEEP" \
        "$PROBE" craft empty "$APP" 2>/dev/null)"
    F_CTL="$(nt_timeout 120 env "${MARKSET[@]}" NEUTRINO_TEST_BATTERY="$NT_MARKS $NT_KEEP" \
        "$PROBE" craft none "$APP" 2>/dev/null)"
    F_EMPTY="$(count_gone "$F_OUT" "$NT_MARKS")"
    F_CTLN="$(count_gone "$F_CTL" "$NT_MARKS")"
    F_STATE="empty=$F_EMPTY control=$F_CTLN"
    ran "$F_OUT" || F_STATE="$F_STATE (empty run did not finish)"
    ran "$F_CTL" || F_STATE="$F_STATE (control run did not finish)"
    echo "  $F_STATE"
    # Was 0/9 on all four POSIX lanes: unsetenv("") is EINVAL and the walk
    # arrived back at the same entry every pass. There is no walk now.
    check_eq "an entry with no name does not stop the scrub" 9/9 "$F_EMPTY"
    check_eq "and the same run without it is still the control" 9/9 "$F_CTLN"
fi

# =====================================================================
# G -- the other shape of fix: assign environ, unset nothing
# =====================================================================
#
# Two candidate fixes, and this section is what chooses between them.
#
#   replace   build the array the child should have and point environ at it.
#             No name buffer, so nothing to truncate; one pass, so nothing to
#             livelock; the empty-name entry is simply not copied. It has one
#             dependency, and it is not small: main() scrubs and then calls
#             setenv five times for the XDG directories, so a libc that will
#             not grow an environ it did not allocate would lose all five and
#             the app would come up with the caller's cache directory.
#
#   advance   keep unsetenv, stop truncating, and walk from an offset that only
#             ever moves forward past what could not be removed. That offset is
#             a count of leading entries, which means something only if a
#             removal further along leaves what is in front of it alone.
#
# Neither claim is one to reason about on four libcs.
echo "=== G: the two candidate fixes ==="
if [ "$NT_WINDOWS" = "1" ]; then
    G_STATE="SKIP no environ to assign; the windows scrub edits the block"
else
    G_RAW="$(env NT_EL_CONTROL_DROPPED=1 "$PROBE" replace "$PROBE" emit 2>&1)"
    G_SELF="$(grep -o 'getenv-sees=[a-z]* dropped-still-visible=[a-z]*' <<<"$G_RAW")"
    G_CHILD="$(awk '$2 == "name" { printf "%s ", $4 }' <<<"$G_RAW")"
    # The decisive one: four setenv calls on top of the assigned array, and
    # then a child that says which of them survived execv.
    G_AFT_RAW="$(env NT_EL_CONTROL_DROPPED=1 "$PROBE" setafter "$PROBE" emit 2>&1)"
    G_AFT="$(grep -o 'setenv=[-0-9/]* getenv-all=[a-z]* base-still=[a-z]*' <<<"$G_AFT_RAW")"
    G_AFT_CHILD="$(awk '$2 == "name" { printf "%s ", $4 }' <<<"$G_AFT_RAW")"
    # stability measured the fix that was not taken -- keep unsetenv, walk from
    # an offset that only advances -- and is kept as a reading rather than an
    # assertion for the next person who has to choose between them.
    G_STAB="$("$PROBE" stability | sed 's/^envlen stability //')"
    G_STATE="replace[$G_SELF child=[${G_CHILD% }]] \
setafter[${G_AFT:-unreported} child=[${G_AFT_CHILD% }]] stability[$G_STAB]"
    echo "  $G_STATE"
    # This is not a candidate any more; it is what nt_env_scrub does. main()
    # scrubs and then calls setenv_dir five times, so a libc that would not grow
    # an environ this program allocated would cost the app all five XDG
    # directories -- silently, and with the scrub still reporting success.
    check_eq "setenv works on an environ this program allocated" \
        "setenv=0/0/0/0 getenv-all=yes base-still=yes" "$G_AFT"
    for n in NT_EL_REPLACED NT_EL_AFTER1 NT_EL_AFTER2 NT_EL_AFTER3 NT_EL_AFTER4; do
        case " $G_AFT_CHILD " in
            *" $n "*) echo "  PASS: $n survived the exec" ;;
            *) nt_fail "$n expected=survived the exec actual=absent from the child"
               FAILURES=$((FAILURES + 1)) ;;
        esac
    done
fi
nt_result "report: envlen emptyname $F_STATE | $G_STATE"

echo
echo "=== envlen: $FAILURES failure(s) ==="
exit "$FAILURES"
