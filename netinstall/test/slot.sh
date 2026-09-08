#!/bin/bash
# slot.sh - the build slot: open on the launch that owes a build, shut after it
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# The windows payload compiles itself, and until this it did so on every
# netinstall launch: the launcher keeps its exe beside the script, that
# directory is the shelf, and the shelf is exactly the place this design refuses
# to make writable. So netinstall opens one directory beside the script --
# <name>.build -- on the launch that owes a build, closes it when the .cmd
# returns, and records the digest of everything in it somewhere the app cannot
# reach.
#
# What this asserts, each of which fails against the commit before this one,
# where there is no slot to open and nothing to seal:
#
#   granted   the first launch of a pin can write the slot
#   sealed    the second cannot, and what run one left is still there unchanged
#   record    netinstall wrote <name>.build.stamp, and the app cannot write it
#   shelf     neither launch can write the shelf or the launcher on it
#   tamper    a file in a sealed slot changed from outside makes the next launch
#             owe a build again
#   plant     so does a file the record does not name, which is the same
#             question asked from the other side
#   repin     a new pin owes a build and does not inherit the old slot
#   sentence  --info names the slot on a launch that would grant it and does not
#             on one that would not, and the confine line follows
#
# Controls, because a refusal that renders nothing is not a pass:
#
#   OWN_DIR_WRITABLE on every launch -- a payload that could write nothing at
#   all would make every SLOT_REFUSED below look like a mechanism working, and
#   this is the same control confine.sh uses for the same reason.
#
#   SLOT_WRITABLE on the granted launch is the positive control for `sealed`:
#   without it a netinstall that never granted anything reads identically to one
#   that grants and revokes correctly.
#
# The payload is a batch probe and not neutrino: what is measured here is the
# grant, the revoke and the record. Whether the *launcher* stops compiling is
# e2e.sh's second-launch arm, and what a standalone launcher does with a slot
# beside its script is test/suite/appcache.ps1's.
#
# Every reading is taken by writing a per-run tag and reading it back, never by
# asking whether a file exists. On a sealed launch the file run one wrote is
# still there, so existence answers "yes" to a write that was refused -- which
# is the reassuring direction, and the reason this suite would have passed
# against a netinstall that revoked nothing.

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: slot.sh <netinstall binary built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"
# harness.sh after lib.sh, and the order is the mechanism: both define nt_fail
# and they disagree about arity. nt_note is lib.sh's and is not shadowed.
#
# windows-launch alone, and this file says why in its own skip: everywhere else
# nt_exec execs, so there is no "after" in which to take a grant back, and no
# other platform's launcher compiles anything.
. "$(cd "$(dirname "$0")/../../test/lib" && pwd)/harness.sh"
NT_ANNOTATE=netinstall

if [ "$NT_WINDOWS" != "1" ]; then
    # Not a platform gap. Everywhere else nt_exec execs, so there is no "after"
    # in which to take a grant back, and no other platform's launcher compiles
    # anything -- see NT_SPLASH_OUTLIVES_HANDOFF for the same asymmetry.
    echo "=== SKIP: the build slot is a windows mechanism ==="
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"


cleanup() {
    kill ${NT_SERVER_PID:-} 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# The payload. Three questions and a tag, and the tag is what makes each answer
# this launch's rather than the last one's.
nt_payload() {
    cat > "$1" <<'BATCH'
@echo off
echo PROBE_BEGIN
set "SLOT=%~dp0%~n0.build"
> "%SLOT%\probe.txt" echo %NEUTRINO_TEST_TAG% 2>nul
findstr /C:"%NEUTRINO_TEST_TAG%" "%SLOT%\probe.txt" >nul 2>&1 && echo SLOT_WRITABLE || echo SLOT_REFUSED
> "%SLOT%\%~n0.exe" echo %NEUTRINO_TEST_TAG% 2>nul
> "%SLOT%.stamp" echo %NEUTRINO_TEST_TAG% 2>nul
findstr /C:"%NEUTRINO_TEST_TAG%" "%SLOT%.stamp" >nul 2>&1 && echo RECORD_WRITABLE || echo RECORD_REFUSED
> "%~dp0plant.txt" echo %NEUTRINO_TEST_TAG% 2>nul
findstr /C:"%NEUTRINO_TEST_TAG%" "%~dp0plant.txt" >nul 2>&1 && echo SHELF_WRITABLE || echo SHELF_REFUSED
> "%XDG_DATA_HOME%\ok.txt" echo %NEUTRINO_TEST_TAG% 2>nul
findstr /C:"%NEUTRINO_TEST_TAG%" "%XDG_DATA_HOME%\ok.txt" >nul 2>&1 && echo OWN_DIR_WRITABLE || echo OWN_DIR_REFUSED
echo PROBE_END
BATCH
}

# One launch, and everything it said. The tag is exported rather than baked in
# so that one served file keeps one pin across the launches that share it.
nt_launch() {
    NEUTRINO_TEST_TAG="tag-$1-$RANDOM$RANDOM" \
        "$APP" > "$WORK/out.$1" 2>&1
    tr -d '\r' < "$WORK/out.$1"
}

# Whole lines, with trailing whitespace taken off first.
#
# cmd.exe puts it there and it is not the payload's fault: `... && echo TOKEN
# || echo OTHER` echoes everything up to the `||`, so the granted branch emits
# "TOKEN " and the refused branch, which ends the line, emits "OTHER". Against
# a `grep -qx` that meant every && token could never match and every || token
# always could -- so this suite could report nothing but refusals, and would
# have passed a build whose slot was never writable at all. Which is the one
# thing it exists to prove. Measured on the first Windows runner it ever saw:
# SLOT_WRITABLE and OWN_DIR_WRITABLE red, SHELF_REFUSED and RECORD_REFUSED
# green, from one probe that was behaving correctly.
nt_said() {
    grep -qx "$2" <<<"$(sed 's/[[:space:]]*$//' <<<"$1")"
}

nt_info_slot() {
    "$APP" --info 2>/dev/null | tr -d '\r' |
        awk '$1 == "slot" { $1 = ""; sub(/^ +/, ""); print; exit }'
}

nt_info_confine() {
    "$APP" --info 2>/dev/null | tr -d '\r' |
        awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print; exit }'
}

# assert_eq, with the id first. Named for the shape the registry scan in
# test/lib/selftest.sh knows -- assert_[a-z_]+ -- because this is the helper that
# takes its id through a variable, which is the one thing that scan cannot
# follow by reading the file. envlen.sh's check_eq became the same name.
assert_eq() {
    if [ "$3" = "$4" ]; then
        nt_pass "$1" "$2"
    else
        nt_fail "$1" "$2 expected=$4 actual=$3"
    fi
}

nt_payload "$SERVE/slot.cmd"
nt_serve "$SERVE"
SPEC="slot-example-com-1$(nt_pin "$SERVE/slot.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
APPROOT="$NEUTRINO_HOME/apps/slot-example-com-1"
SLOT="$APPROOT/slot.build"
RECORD="$APPROOT/slot.build.stamp"

# =====================================================================
# sentence: what --info says before anything has been built
# =====================================================================
echo "=== Before the first launch ==="
# The script first, because "before the first launch" is what this arm means
# and not "before the first fetch". nt_slot_owed answers "the script has no
# digest" while there is nothing cached to take a digest of, and "never built"
# -- the sentence below -- only once there is a script and no slot. Asserting
# the second against the first state failed on the runner and was right to:
# --info was describing a machine that had not downloaded anything yet.
"$APP" --fetch >/dev/null 2>&1
BEFORE_SLOT="$(nt_info_slot)"
BEFORE_CONFINE="$(nt_info_confine)"
nt_note "slot before=$BEFORE_SLOT"
assert_eq slot.info.owes "--info owes a build before there is one" \
      "$BEFORE_SLOT" "never built"
if grep -q "for this build" <<<"$BEFORE_CONFINE"; then
    nt_pass slot.confine.names "and the confine line names the slot it would open"
else
    nt_fail slot.confine.names "confine expected=a line naming the slot actual=$BEFORE_CONFINE"
fi

# =====================================================================
# granted: the launch that owes a build can write the slot
# =====================================================================
echo "=== The launch that owes a build ==="
ONE="$(nt_launch 1)"
echo "$ONE" | sed 's/^/  /'
for want in SLOT_WRITABLE OWN_DIR_WRITABLE SHELF_REFUSED RECORD_REFUSED; do
    if nt_said "$ONE" "$want"; then
        nt_pass slot.granted "$want"
    else
        nt_fail slot.granted "granted expected=$want actual=$(tr '\n' '/' <<<"$ONE")"
    fi
done

if [ -f "$RECORD" ]; then
    nt_pass slot.record.written "netinstall wrote the record"
else
    nt_fail slot.record.written "record expected=$RECORD actual=missing"
fi
assert_eq slot.info.sealed "--info says sealed once it is" "$(nt_info_slot)" "sealed"
if grep -q "for this build" <<<"$(nt_info_confine)"; then
    nt_fail slot.confine.quiet "confine expected=no slot clause on a sealed launch actual=$(nt_info_confine)"
else
    nt_pass slot.confine.quiet "and the confine line stops naming it"
fi

KEPT="$(nt_sha256 "$SLOT/slot.exe")"

# =====================================================================
# sealed: the next launch cannot, and what is there is untouched
# =====================================================================
echo "=== The launch that does not ==="
TWO="$(nt_launch 2)"
echo "$TWO" | sed 's/^/  /'
for want in SLOT_REFUSED OWN_DIR_WRITABLE SHELF_REFUSED RECORD_REFUSED; do
    if nt_said "$TWO" "$want"; then
        nt_pass slot.sealed.state "$want"
    else
        nt_fail slot.sealed.state "sealed expected=$want actual=$(tr '\n' '/' <<<"$TWO")"
    fi
done
assert_eq slot.sealed.unchanged "what the first launch left is unchanged" \
      "$(nt_sha256 "$SLOT/slot.exe")" "$KEPT"

# =====================================================================
# tamper: a sealed slot changed from outside owes a build again
# =====================================================================
#
# From out here, not from the payload: the payload cannot write a sealed slot,
# which is the point of the arm above. This is the same-user process at this
# program's own integrity level that the record exists for.
echo "=== A sealed slot changed from outside ==="
echo "tampered" >> "$SLOT/slot.exe"
assert_eq slot.tamper.owes "--info owes a build after a file changed" \
      "$(nt_info_slot)" "the slot does not match its record"

# The wipe is the other half: the next launch does not merely rebuild, it
# rebuilds into a directory the tampered file is gone from.
THREE="$(nt_launch 3)"
if nt_said "$THREE" "SLOT_WRITABLE"; then
    nt_pass slot.tamper.granted "and the launch after it is granted again"
else
    nt_fail slot.tamper.granted "tamper expected=SLOT_WRITABLE actual=$(tr '\n' '/' <<<"$THREE")"
fi
if grep -q tampered "$SLOT/slot.exe" 2>/dev/null; then
    nt_fail slot.tamper.wiped "tamper expected=the tampered file is wiped actual=it survived"
else
    nt_pass slot.tamper.wiped "and the tampered file did not survive the wipe"
fi

# =====================================================================
# plant: a file the record does not name is the same question, reversed
# =====================================================================
echo "=== A file in a sealed slot that nobody vouched for ==="
echo "planted" > "$SLOT/planted.exe"
assert_eq slot.plant.owes "--info owes a build for a file the record does not name" \
      "$(nt_info_slot)" "the slot holds something the record does not name"
nt_launch 4 >/dev/null
if [ -f "$SLOT/planted.exe" ]; then
    nt_fail slot.plant.wiped "plant expected=the planted file is wiped actual=it survived"
else
    nt_pass slot.plant.wiped "and it did not survive the wipe"
fi

# =====================================================================
# repin: a new pin owes a build and inherits nothing
# =====================================================================
#
# Same name, same host, same shape, so it is the same app directory and the same
# slot -- which is exactly the case the record has to catch, because the path
# does not change and only the digest does.
echo "=== A new pin of the same app ==="
printf '@echo off\r\nrem a second version\r\n' >> "$SERVE/slot.cmd"
nt_payload "$WORK/keep.cmd"
cat "$WORK/keep.cmd" > "$SERVE/slot.cmd"
printf 'rem v2\r\n' >> "$SERVE/slot.cmd"
SPEC2="slot-example-com-1$(nt_pin "$SERVE/slot.cmd")"
APP="$(nt_as "$BIN" "$SPEC2" "$WORK/bin")"
assert_eq slot.repin.owes "--info owes a build for a pin it has not seen" \
      "$(nt_info_slot)" "the script changed"
FIVE="$(nt_launch 5)"
if nt_said "$FIVE" "SLOT_WRITABLE"; then
    nt_pass slot.repin.granted "and the launch is granted"
else
    nt_fail slot.repin.granted "repin expected=SLOT_WRITABLE actual=$(tr '\n' '/' <<<"$FIVE")"
fi
assert_eq slot.repin.sealed "--info seals the new pin" "$(nt_info_slot)" "sealed"

nt_note "slot record=$(wc -l < "$RECORD" | tr -d ' ') lines"
# $NT_FAILURES rather than a counter of this file's own: nt_fail counts.
echo "=== Results: $NT_FAILURES failure(s) ==="
[ "$NT_FAILURES" -eq 0 ] || exit 1
exit 0
