#!/bin/bash
# crashdump.sh - where a crash puts bytes on windows, and whether the app dir
#                contains them
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# PROBE, not a gate. Nothing here asserts a shipped behaviour; it measures one,
# and it is expected to come out of SUITES the round after it has answered --
# the same way session.sh and lowfetch.sh did.
#
# The question. netinstall's confinement promise is about writes, and a crash
# dump is a write the app causes without performing: the dumping process runs
# outside the sandbox and writes wherever it was configured to. Every POSIX
# platform closes that channel with RLIMIT_CORE (netinstall.c nt_limits), and
# --info prints a `limits` line saying so. On _WIN32 nt_limits returns NULL,
# there is no `limits` line, and nothing anywhere in the tree mentions WER.
#
# That was defensible while windows had no filesystem confinement at all -- a
# dump written to %LOCALAPPDATA% was not a hole in a boundary that did not
# exist. It stops being defensible the moment low integrity becomes the tier,
# because then the sentence "it cannot write to your files" is being made on
# windows too, and a dump outside the app dir is a counterexample to it.
#
# Four things this has to separate, because three of them look like "no dump":
#
#   the drop is real          -- a crash at medium integrity recorded as a
#       crash at low integrity is the one wrong answer available here, so the
#       probe reports the level the kernel gives it and the suite reads it;
#   WER is running at all     -- a runner with error reporting switched off
#       produces no dump from anything, and would report the strongest possible
#       result for the weakest possible reason. UNCONFINED_DUMP is the control:
#       if an unconfined crash writes nothing either, this suite measured
#       nothing and says so rather than passing;
#   the default machine       -- no LocalDumps key, which is what almost every
#       machine is, and what CI is;
#   the configured machine    -- LocalDumps set under HKCU, which is the
#       documented way a user turns local crash dumps on and is common on any
#       machine somebody has ever debugged something on. An app cannot set it
#       itself at low integrity -- HKCU\Software refuses, and writable.sh
#       asserts that -- but it does not have to: the question is whether a
#       machine where it is already set has a hole, not whether the app made
#       one.
#
# What the answer decides. If a low integrity crash with %TEMP% redirected puts
# nothing outside the app dir in either state, the promise holds on windows as
# written. If it puts bytes anywhere else, then either that channel gets closed
# or the promise says so -- and this suite is what tells the difference.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

echo "=== crashdump: the windows crash-write channel ==="

if [ "${NT_WINDOWS:-0}" != "1" ]; then
    # Not a skip that hides anything: the other three platforms answer this
    # with RLIMIT_CORE, which phases.sh already reads off the `limits` line.
    echo "=== SKIP: RLIMIT_CORE closes this channel off windows, and --info says so ==="
    exit 0
fi

WORK="$(mktemp -d)"
APPDIR="$WORK/app"
APPTMP="$APPDIR/tmp"
DUMPDIR="$WORK/dumps"
mkdir -p "$APPDIR" "$APPTMP" "$DUMPDIR"

FAILURES=0

probe() {
    echo "  $*"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# =====================================================================
# The instrument
# =====================================================================
NT_CC="${NETINSTALL_CC:-cc}"
PROBE="$WORK/crash-probe$NT_EXE"
PROBE_STATE=BUILT
# shellcheck disable=SC2086
$NT_CC -o "$PROBE" "$ROOT/netinstall/test/crash-probe.c" -ladvapi32 \
    >"$WORK/cc.log" 2>&1 ||
    PROBE_STATE="FAILED: $(tr '\n' ' ' < "$WORK/cc.log" | cut -c1-200)"
[ -x "$PROBE" ] || PROBE_STATE="${PROBE_STATE%%:*}: no output"
echo "=== crash-probe: $PROBE_STATE ==="
if [ "$PROBE_STATE" != "BUILT" ]; then
    nt_fail "crash-probe did not build: $PROBE_STATE"
    probe "report: crashdump probe=$PROBE_STATE -- nothing else in this suite ran"
    rm -rf "$WORK"
    exit 1
fi

# The app dir carries the same Low label nt_label_low applies, or a lowered
# process cannot write its own redirected %TEMP% and the measurement below is of
# a crash that could not have written there whatever WER decided.
icacls "$(nt_native "$APPDIR")" /setintegritylevel "(OI)(CI)"Low >/dev/null 2>&1 ||
    nt_note "icacls could not label the app dir Low; the redirect half is weaker than the tier"

# =====================================================================
# The registry state, saved and put back
# =====================================================================
WERKEY='HKCU\Software\Microsoft\Windows\Windows Error Reporting\LocalDumps'
WERSAVE="$WORK/wer.reg"
WERHAD=0
if reg query "$WERKEY" >/dev/null 2>&1; then
    WERHAD=1
    reg export "$WERKEY" "$(nt_native "$WERSAVE")" /y >/dev/null 2>&1 ||
        nt_note "could not export the existing LocalDumps key; it will be removed, not restored"
fi

restore_wer() {
    reg delete "$WERKEY" /f >/dev/null 2>&1
    if [ "$WERHAD" = "1" ] && [ -f "$WERSAVE" ]; then
        reg import "$(nt_native "$WERSAVE")" >/dev/null 2>&1
    fi
}
trap 'restore_wer; rm -rf "$WORK"' EXIT

# =====================================================================
# What is watched
# =====================================================================
# The environment hands these back in windows form -- C:\Users\... -- and
# everything below is find(1) and a -d test, which want the posix spelling. This
# is nt_native in reverse; it is local rather than in lib.sh because nothing
# else has needed it yet, and one copy that is used is better than a shared one
# that is not.
to_posix() {
    [ -n "$1" ] || { echo ""; return 0; }
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1" 2>/dev/null
    else
        printf '%s\n' "$1"
    fi
}

# Every location a dump has been documented to land in, plus the app dir, which
# is the only one that would not be a counterexample.
watched_dirs() {
    local progdata="${ProgramData:-${PROGRAMDATA:-}}"
    printf '%s\n' \
        "localappdata-crashdumps|$(to_posix "${LOCALAPPDATA:-}")/CrashDumps" \
        "localappdata-temp|$(to_posix "${LOCALAPPDATA:-}")/Temp" \
        "appdata|$(to_posix "${APPDATA:-}")" \
        "programdata-wer|$(to_posix "$progdata")/Microsoft/Windows/WER" \
        "configured-dumpdir|$DUMPDIR" \
        "appdir|$APPDIR"
}

# Counts files, not directories, and counts them recursively: WER writes into
# subdirectories under ReportQueue and a top-level count would miss it.
count_under() {
    local d="$1"
    [ -n "$d" ] && [ -d "$d" ] || { echo 0; return 0; }
    find "$d" -type f 2>/dev/null | wc -l | tr -d ' '
}

snapshot() {
    local out="$1" line name dir
    : > "$out"
    while IFS= read -r line; do
        name="${line%%|*}"
        dir="${line#*|}"
        echo "$name $(count_under "$dir")" >> "$out"
    done < <(watched_dirs)
}

# Names every watched location that gained a file, or `none`.
grew() {
    local before="$1" after="$2" name b a out=""
    while read -r name b; do
        a="$(awk -v n="$name" '$1 == n { print $2 }' "$after")"
        [ -n "$a" ] || a=0
        if [ "$a" -gt "$b" ]; then
            out="$out $name(+$((a - b)))"
        fi
    done < "$before"
    [ -n "$out" ] && echo "${out# }" || echo "none"
}

# Runs one crash and says what grew. Bounded, because a machine that puts a
# fault dialog up would otherwise hang the lane rather than report a timeout.
run_crash() {
    local label="$1" redirect="$2"; shift 2
    local before="$WORK/$label.before" after="$WORK/$label.after"

    snapshot "$before"
    if [ "$redirect" = "redirect" ]; then
        TEMP="$(nt_native "$APPTMP")" TMP="$(nt_native "$APPTMP")" \
            nt_timeout 60 "$PROBE" "$@" > "$WORK/$label.out" 2>&1
    else
        nt_timeout 60 "$PROBE" "$@" > "$WORK/$label.out" 2>&1
    fi
    # WER is asynchronous: the faulting process is gone before the report is
    # written. Two seconds was enough on every run that produced one; a probe
    # that reads the directory immediately reads it too early and reports the
    # answer this suite exists to distrust.
    sleep 2
    snapshot "$after"
    grew "$before" "$after"
}

il_of() {
    grep -o 'il=[^ ]*' "$WORK/$1.out" 2>/dev/null | head -1 | cut -d= -f2
}

# =====================================================================
# Control 1 -- the drop is real
# =====================================================================
nt_timeout 30 "$PROBE" report > "$WORK/plain.out" 2>&1
nt_timeout 30 "$PROBE" low report > "$WORK/lowrep.out" 2>&1
PLAIN_IL="$(il_of plain)"
LOW_IL="$(il_of lowrep)"
probe "report: crashdump default_il=${PLAIN_IL:-NONE} lowered_il=${LOW_IL:-NONE}"

if [ "$LOW_IL" != "0x1000" ]; then
    nt_fail "the probe did not reach low integrity (got ${LOW_IL:-nothing}); every reading below is of a process that was never lowered"
    FAILURES=$((FAILURES + 1))
fi

# =====================================================================
# The default machine -- no LocalDumps key
# =====================================================================
reg delete "$WERKEY" /f >/dev/null 2>&1

DEFAULT_UNCONFINED="$(run_crash default-unconfined plain crash)"
DEFAULT_LOW="$(run_crash default-low redirect low crash)"
DEFAULT_JOB="$(run_crash default-job plain job crash)"
DEFAULT_SHIP="$(run_crash default-ship redirect low job crash)"
probe "report: crashdump default unconfined=$DEFAULT_UNCONFINED low+redirect=$DEFAULT_LOW job=$DEFAULT_JOB shipping=$DEFAULT_SHIP"

# =====================================================================
# The configured machine -- LocalDumps under HKCU
# =====================================================================
reg add "$WERKEY" /v DumpFolder /t REG_EXPAND_SZ /d "$(nt_native "$DUMPDIR")" /f \
    >/dev/null 2>&1
reg add "$WERKEY" /v DumpType /t REG_DWORD /d 2 /f >/dev/null 2>&1
reg add "$WERKEY" /v DumpCount /t REG_DWORD /d 8 /f >/dev/null 2>&1

CONFIGURED_UNCONFINED="$(run_crash configured-unconfined plain crash)"
CONFIGURED_LOW="$(run_crash configured-low redirect low crash)"
CONFIGURED_SHIP="$(run_crash configured-ship redirect low job crash)"
probe "report: crashdump localdumps unconfined=$CONFIGURED_UNCONFINED low+redirect=$CONFIGURED_LOW shipping=$CONFIGURED_SHIP"

# =====================================================================
# Control 2 -- WER wrote something for somebody
# =====================================================================
# Ground rule 3: a refusal that renders nothing is not a pass. If neither
# unconfined crash produced a file anywhere, error reporting is off on this
# machine and the two low integrity readings are worth nothing.
if [ "$DEFAULT_UNCONFINED" = "none" ] && [ "$CONFIGURED_UNCONFINED" = "none" ]; then
    probe "report: crashdump control=UNMEASURED -- no unconfined crash wrote anywhere watched; WER is off on this machine and the low integrity readings above say nothing"
else
    probe "report: crashdump control=LIVE -- an unconfined crash does write here"
fi

# =====================================================================
# The reading the promise depends on
# =====================================================================
# Stated as one line somebody can grep out of a log, because this is the thing
# the wording turns on: OUTSIDE means a crash puts bytes somewhere the app dir
# does not contain, in a state a real machine can be in.
#
# Read off the two shipping cells only. The four-cell grid above is there to say
# which mechanism does the work -- the Low label, the job object, or neither --
# and that is worth having in the log, but the promise is a claim about the
# process netinstall actually launches, which is lowered AND in the job.
OUTSIDE=no
case "$DEFAULT_SHIP$CONFIGURED_SHIP" in
    *localappdata*|*appdata*|*programdata*|*configured-dumpdir*) OUTSIDE=yes ;;
esac
probe "report: crashdump WRITES_OUTSIDE_APPDIR=$OUTSIDE"
# And which of the two closed it, when it is closed, because "the job object
# does this" and "the label does this" have different consequences for anyone
# who later changes either.
case "$DEFAULT_LOW" in
    none) ;;
    *) case "$DEFAULT_JOB" in
           none) probe "report: crashdump CLOSED_BY=job-object (the label alone does not)" ;;
           *)    probe "report: crashdump CLOSED_BY=${DEFAULT_SHIP:-none} -- neither alone was enough" ;;
       esac ;;
esac

echo "=== crashdump: $FAILURES failure(s) ==="
exit $((FAILURES > 0))
