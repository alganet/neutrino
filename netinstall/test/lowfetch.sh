#!/bin/bash
# lowfetch.sh - what a confined fetch child would cost on windows, and what
#               granting it its download directory would widen
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# PROBE, not a gate. Nothing here asserts a shipped behaviour; it measures the
# candidates for one, and it is expected to come out of SUITES the round after
# it has answered -- the same way session.sh and job-ui.sh did.
#
# The question. nt_fetch_confine_win has no tier branch in it, so a tight build
# downloads the payload behind a job object and a stripped token -- a resource
# boundary, not a filesystem one -- while its run phase drops to low integrity.
# phases.sh already asserts the consequence (HOMEJAR_ESCAPED, TMPJAR_ESCAPED,
# both tiers) and it has been parked twice: by PR 10 with a reason, and by PR 17
# once the tight tier was measured rather than inferred.
#
# PR 10's reason is the thing to price: low integrity needs the download
# directory carrying a Low label, "which widens who else on the machine can
# write there". That is a claim with a number behind it, and this is the number.
#
# Four things it has to separate, because three of them can look like the fix
# working when it is not:
#
#   the mechanism can be applied at all  -- CreateProcessAsUser wants a
#       privilege nt_strip_privileges removes, and the runner is an
#       administrator while a user is not, so `strip` is the control that says
#       whether an answer generalises off this machine;
#   the child really is confined       -- a spawn that succeeded says nothing;
#       the child reports its own integrity level and its own restricted bit;
#   the confinement really bites       -- $HOME and %TEMP% have to become
#       refusals, which is exactly what phases.sh measures escaping today;
#   the download still lands           -- and by real curl, not by the probe's
#       own CreateFile: a downloader wants a trust store, a resolver and
#       somewhere to put a temporary file, and low integrity redirects none of
#       them.
#
# And then the price, which is the reason this was parked: with the grant in
# place, what can a process that is nothing to do with netinstall now do?
# Measured with an unrelated child at each level rather than reasoned from the
# label. The two candidates differ exactly here -- a Low label is authority
# every low integrity process on the machine already holds, and the RESTRICTED
# ace is authority nothing holds unless it asked to be restricted.
#
# Readings leave through annotate.sh: ten warnings per step, and this suite
# produces more measurements than that.

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: lowfetch.sh <netinstall binary built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ "$NT_WINDOWS" != "1" ]; then
    echo "=== SKIP: integrity levels and restricted tokens are a windows question ==="
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
HOME_DIR="$WORK/home"
BLOBS="$HOME_DIR/blobs"
APPS="$HOME_DIR/apps/probe"
mkdir -p "$SERVE" "$BLOBS" "$APPS" "$WORK/bin"

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

# =====================================================================
# The instrument
# =====================================================================
NT_CC="${NETINSTALL_CC:-cc}"
PROBE="$WORK/lowfetch-probe$NT_EXE"
PROBE_STATE=BUILT
# shellcheck disable=SC2086
# user32 for the window station and desktop handles the third spawn attempt
# needs; advapi32 for everything else.
$NT_CC -o "$PROBE" "$ROOT/netinstall/test/lowfetch-probe.c" -ladvapi32 -luser32 \
    >"$WORK/cc.log" 2>&1 ||
    PROBE_STATE="FAILED: $(tr '\n' ' ' < "$WORK/cc.log" | cut -c1-200)"
[ -x "$PROBE" ] || PROBE_STATE="${PROBE_STATE%%:*}: no output"
echo "=== lowfetch-probe: $PROBE_STATE ==="
if [ "$PROBE_STATE" != "BUILT" ]; then
    nt_fail "lowfetch-probe did not build: $PROBE_STATE"
    nt_result "report: lowfetch probe=$PROBE_STATE -- nothing else in this suite ran"
    rm -rf "$WORK"
    exit 1
fi
P="$(nt_native "$PROBE")"

# The same list, in the same order, fetch.c resolves from.
nt_downloader() {
    local p
    for p in "/c/Windows/System32/curl.exe" \
             "$(cygpath -u "${SYSTEMROOT:-C:\\Windows}" 2>/dev/null)/System32/curl.exe"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}
CURLBIN="$(nt_downloader)"
if [ -z "$CURLBIN" ]; then
    nt_fail "no curl at the paths fetch.c resolves; the cost half cannot be measured"
    FAILURES=$((FAILURES + 1))
fi

nt_serve "$SERVE" || { rm -rf "$WORK"; exit 2; }
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -f "$HOME/nt-lowfetch-probe.txt"; rm -rf "$WORK"' EXIT
head -c 4096 /dev/urandom > "$SERVE/payload.bin"

W() { nt_native "$1"; }

# Runs the probe and returns its output with the carriage returns gone, so the
# greps below are asking about the text and not about line endings.
run() { "$PROBE" "$@" 2>&1 | tr -d '\r'; }

# =====================================================================
# A -- the token this runner has, and the token each mode produces
# =====================================================================
#
# A spawn that returned OK is not a confined child. Each mode is asked to run
# the probe's own `report`, which prints the integrity level and the restricted
# bit of the process it is actually in -- so "the mechanism applied" and "the
# mechanism was accepted and did nothing" stop being the same reading.
#
# `strip` is the one that decides whether any of this is shippable.
# CreateProcessAsUser is documented to want SeIncreaseQuotaPrivilege;
# nt_strip_privileges removes it before nt_fetch_confine_win returns, and a
# github runner is an administrator while the user this ships to is not. If the
# spawn needs the privileges, the answer measured here is the runner's.
echo "=== A: the parent token, and what each mode hands the child ==="
# The sentence any of this would change, on the record beside the readings that
# would change it. The tight tier is what this suite is handed, and today its
# fetch line is the default tier's word for word.
#
# Through nt_as, because netinstall parses its spec out of argv[0] and a binary
# invoked under its build name never reaches --info at all. Round one read this
# as an empty line and that was the probe, not the platform.
printf 'echo INFO_ONLY\n' > "$SERVE/info.cmd"
INFOAPP="$(nt_as "$BIN" "info-example-com-1$(nt_pin "$SERVE/info.cmd")" "$WORK/bin")"
probe "A tight --info fetch: $("$INFOAPP" --info 2>/dev/null | grep '^fetch' | sed 's/^fetch *//' | cut -c1-160)"
probe "parent: $(run report | tr '\n' ' ')"

# ORDER MATTERS, and not in the way a suite usually means. `opendesk` grants
# S-1-5-33 on this process's window station and desktop, and those are session
# objects: the grant outlives the spawn and every later section's write-restricted
# child inherits it. Round one read wrestricted as NOCHILD throughout; round two
# reads it as a real refusal in B and C, and the difference is this loop, not the
# platform.
#
# Left as it is on purpose. It makes the decline conservative -- section I hands
# write-restricted more than it would ever get and curl still will not start --
# and undoing it means a second process per mode. But a reader comparing the two
# rounds needs to know, and anyone adding a section below here needs to know that
# `wrestricted` down there is not the same token `wrestricted` is up here.
for MODE in plain low wrestricted low,wrestricted low,strip low,strip,job \
            wrestricted,strip wrestricted,opendesk low,wrestricted,opendesk; do
    OUT="$(run spawn "$MODE" "$P" report)"
    SPAWN="$(grep -o 'SPAWN=[A-Z]* *\(stage=[a-z]* gle=[0-9]*\)\?' <<<"$OUT" | head -1)"
    CHILD="$(grep -o 'IL=0x[0-9a-f]* [a-z]* restricted=[a-z]*' <<<"$OUT" | head -1)"
    EXTRA="$(grep -o 'STRIP=[A-Z]*\|JOB=[A-Z]*\|OPENDESK=[A-Z]*\|DESKTOP=[a-z]*\( first_gle=[0-9]*\)\?\( grant=[A-Z]*\)\?' <<<"$OUT" | tr '\n' ' ')"
    # A child that printed nothing still exited, and the code is the whole
    # difference between "the mechanism refused a write" and "the process never
    # reached main". Round one had to read that out of section D.
    RC="$(grep -o 'CHILDRC=[0-9]*' <<<"$OUT" | head -1 | cut -d= -f2)"
    probe "A $MODE: ${SPAWN:-<no spawn line>} ${EXTRA}rc=${RC:-?} child=${CHILD:-<never reported>}"
done

# =====================================================================
# B -- does the confinement bite where phases.sh measures an escape
# =====================================================================
#
# The two targets phases.sh uses, asked of the child directly rather than
# through curl's cookie jar: $HOME is what every platform but this one refuses,
# and the user temp dir is the second target that keeps "denied" and "allowed on
# purpose" from looking alike. `plain` is the control -- if it cannot write
# them either, every REFUSED below is unearned.
echo "=== B: what a child at each level can write ==="
HOMEJAR="$(W "$HOME/nt-lowfetch-probe.txt")"
TMPJAR="$(W "$WORK/nt-lowfetch-tmp.txt")"
BLOBJAR="$(W "$BLOBS/nt-lowfetch-blob.txt")"
for MODE in plain low wrestricted low,strip; do
    LINE=""
    for T in "$HOMEJAR:HOME" "$TMPJAR:TMP" "$BLOBJAR:BLOBS"; do
        PATHW="${T%:*}"; NAME="${T##*:}"
        OUT="$(run spawn "$MODE" "$P" write "$PATHW")"
        case "$OUT" in
            *"WRITE=OK"*)      LINE="$LINE $NAME=ESCAPED" ;;
            *"WRITE=REFUSED"*) LINE="$LINE $NAME=BLOCKED(gle=$(grep -o 'gle=[0-9]*' <<<"$OUT" | head -1 | cut -d= -f2))" ;;
            *)                 LINE="$LINE $NAME=NOCHILD($(grep -o 'SPAWN=FAIL.*' <<<"$OUT" | head -1))" ;;
        esac
    done
    probe "B $MODE:$LINE"
done
rm -f "$HOME/nt-lowfetch-probe.txt"

# =====================================================================
# C -- what has to be granted before the download can land
# =====================================================================
#
# The write the fetch child has to be allowed to make is exactly one: the
# tmpfile netinstall names before it calls nt_fetch, inside the blobs
# directory. Five grants, from the narrowest up:
#
#   none            the floor, and the reading that says the grant is needed
#   labelfile       a Low label on that one file, created by the launcher first
#   label           a Low label on the whole blobs directory, inheritable --
#                   this is the shape PR 10 costed and declined
#   grantwr-file    a RESTRICTED ace on that one file
#   grantwr-dir     a RESTRICTED ace on the directory
#
# The two directory forms are what get compared in E: whether the thing granted
# is authority the rest of the machine already has.
echo "=== C: the narrowest grant each mechanism needs ==="
grant_case() {
    local mode="$1" grant="$2" tmp dir line
    dir="$BLOBS/c-$grant-${mode//,/-}"
    rm -rf "$dir"; mkdir -p "$dir"
    tmp="$dir/.tmp-1"
    case "$grant" in
        none)        : ;;
        labelfile)   : > "$tmp"; run labelfile "$(W "$tmp")" >/dev/null ;;
        label)       run label "$(W "$dir")" >/dev/null ;;
        grantwr-file) : > "$tmp"; run grantwr "$(W "$tmp")" >/dev/null ;;
        grantwr-dir) run grantwr "$(W "$dir")" >/dev/null ;;
    esac
    line="$(run spawn "$mode" "$P" write "$(W "$tmp")")"
    case "$line" in
        *"WRITE=OK"*)      echo "LANDS" ;;
        *"WRITE=REFUSED"*) echo "REFUSED(gle=$(grep -o 'gle=[0-9]*' <<<"$line" | head -1 | cut -d= -f2))" ;;
        *)                 echo "NOCHILD" ;;
    esac
}
for MODE in low wrestricted; do
    LINE=""
    for G in none labelfile label grantwr-file grantwr-dir; do
        LINE="$LINE $G=$(grant_case "$MODE" "$G")"
    done
    probe "C $MODE:$LINE"
done

# =====================================================================
# D -- and by a real downloader, which wants more than one file
# =====================================================================
#
# The probe's CreateFile asks for one handle. curl wants a trust store, a
# resolver, and on some paths a temporary file -- and low integrity redirects
# none of those, which is the failure mode sandbox_win.c already records for
# jsc.exe. So the same matrix again with the program that actually has to
# survive it, reporting curl's own exit code and the bytes on disk.
if [ -n "$CURLBIN" ]; then
    echo "=== D: curl itself, under each mechanism ==="
    CURLW="$(W "$CURLBIN")"
    curl_case() {
        local mode="$1" grant="$2" dir tmp out rc bytes
        dir="$BLOBS/d-$grant-${mode//,/-}"
        rm -rf "$dir"; mkdir -p "$dir"
        tmp="$dir/.tmp-1"
        case "$grant" in
            labelfile)    : > "$tmp"; run labelfile "$(W "$tmp")" >/dev/null ;;
            label)        run label "$(W "$dir")" >/dev/null ;;
            grantwr-file) : > "$tmp"; run grantwr "$(W "$tmp")" >/dev/null ;;
            grantwr-dir)  run grantwr "$(W "$dir")" >/dev/null ;;
        esac
        out="$(run spawn "$mode" "$CURLW" -fsS --max-filesize 1048576 \
              --max-time 30 "$NEUTRINO_TEST_ORIGIN/payload.bin" -o "$(W "$tmp")")"
        rc="$(grep -o 'CHILDRC=[0-9]*' <<<"$out" | head -1 | cut -d= -f2)"
        bytes=0
        [ -f "$tmp" ] && bytes="$(wc -c < "$tmp" | tr -d ' ')"
        if [ "$bytes" = "4096" ]; then
            echo "$grant=OK"
        else
            echo "$grant=FAIL(rc=${rc:-?},bytes=$bytes)"
        fi
    }
    for MODE in plain low wrestricted low,strip; do
        LINE=""
        for G in none labelfile label grantwr-file grantwr-dir; do
            LINE="$LINE $(curl_case "$MODE" "$G")"
        done
        probe "D $MODE:$LINE"
    done
fi

# =====================================================================
# E -- the price: what the grant handed everyone else
# =====================================================================
#
# This is PR 10's sentence, measured. An intruder that is nothing to do with
# netinstall: a low integrity process, which is what a sandboxed browser tab and
# a protected mode renderer already are, and which no user had to arrange.
#
# Against a Low label it should get in, and that is the widening. Against the
# RESTRICTED ace it should not, because it carries no restricted sid -- an ace
# for S-1-5-33 is authority that only a process which asked to be write
# restricted can spend, so granting it costs nothing to anyone who did not ask.
# If that reading holds, the mechanism PR 10 declined is not the only one on
# offer and its reason does not carry to the other.
echo "=== E: what an unrelated low integrity process gained ==="
intruder() {
    local grant="$1" dir out
    dir="$BLOBS/e-$grant"
    rm -rf "$dir"; mkdir -p "$dir"
    local target="$dir/intruder.txt"
    case "$grant" in
        none)        : ;;
        label)       run label "$(W "$dir")" >/dev/null ;;
        grantwr-dir) run grantwr "$(W "$dir")" >/dev/null ;;
        # The narrow form's own widening, which is the one the decision turns
        # on: what a label on a single file hands an intruder is that file.
        labelfile)   : > "$target"; run labelfile "$(W "$target")" >/dev/null ;;
    esac
    out="$(run spawn low "$P" write "$(W "$target")")"
    case "$out" in
        *"WRITE=OK"*) echo "$grant=WIDENED" ;;
        *"WRITE=REFUSED"*) echo "$grant=still-refused" ;;
        *) echo "$grant=NOCHILD" ;;
    esac
}
probe "E low-integrity intruder: $(intruder none) $(intruder label) $(intruder labelfile) $(intruder grantwr-dir)"

# =====================================================================
# F -- the hazard a directory grant carries and a file grant does not
# =====================================================================
#
# netinstall commits a verified payload with CreateHardLink, and a hard link is
# a second name for one file object -- the security descriptor is the file's,
# not the name's. So a blob that inherited Low from a labelled blobs directory
# hands that label to <home>/apps/<app>/<name>.cmd, which is the file nt_exec
# runs, and the digest was checked before the link rather than after.
#
# Both descriptors are printed rather than summarised: this is the reading that
# decides whether the directory form is admissible at all, and a yes/no would
# not survive being wrong.
echo "=== F: does the label follow the hard link to the script ==="
LDIR="$BLOBS/f-label"
rm -rf "$LDIR"; mkdir -p "$LDIR"
run label "$(W "$LDIR")" >/dev/null
BLOB="$LDIR/deadbeef"
run spawn low "$P" write "$(W "$BLOB")" >/dev/null
if [ ! -f "$BLOB" ]; then
    : > "$BLOB"
fi
LINK="$APPS/probe.cmd"
rm -f "$LINK"
HL="$(run hardlink "$(W "$BLOB")" "$(W "$LINK")")"
probe "F $(grep -o 'HARDLINK=[A-Z]*' <<<"$HL" | head -1) $(grep -o 'SDDL_BLOB=.*' <<<"$HL" | head -1)"
probe "F $(grep -o 'SDDL_LINK=.*' <<<"$HL" | head -1)"
OUT="$(run spawn low "$P" write "$(W "$LINK")")"
case "$OUT" in
    *"WRITE=OK"*) probe "F intruder rewrote the linked script: SCRIPT_WRITABLE" ;;
    *"WRITE=REFUSED"*) probe "F the linked script stayed refused: SCRIPT_PROTECTED" ;;
    *) probe "F the linked script: NOCHILD" ;;
esac

# =====================================================================
# G -- the descriptors, once, for the record
# =====================================================================
echo "=== G: the two grants as the kernel stores them ==="
GDIR="$BLOBS/g"
rm -rf "$GDIR"; mkdir -p "$GDIR"
probe "G before: $(run sddl "$(W "$GDIR")" | head -1)"
run label "$(W "$GDIR")" >/dev/null
probe "G after label: $(run sddl "$(W "$GDIR")" | head -1)"
GDIR2="$BLOBS/g2"
rm -rf "$GDIR2"; mkdir -p "$GDIR2"
run grantwr "$(W "$GDIR2")" >/dev/null
probe "G after grantwr: $(run sddl "$(W "$GDIR2")" | head -1)"

# =====================================================================
# H -- the narrow form, end to end, including the window it opens
# =====================================================================
#
# Round one settled which grant is needed: a Low label on the one file, not on
# the directory. What it did not settle is the window that grant leaves open,
# and the window is the whole reason the directory form was inadmissible.
#
# netinstall names the tmpfile, fetches into it, hashes it, checks the pin,
# checks it is text, renames it to the blob and hard links the blob to the
# script it then runs. If the label is still on that file when the hash is
# taken, an intruder at low integrity can swap the content between the hash and
# the rename -- and nothing re-reads it before nt_exec. The launcher is at
# medium integrity throughout, so it can take the label back off the moment the
# child exits, which closes the window before the hash rather than arguing that
# the race is narrow.
#
# So this walks the real sequence and asks at each step who else can write:
# after the label, after the fetch, after the label comes off, and after the
# hard link -- which is where the directory form put a writable file under the
# name nt_exec runs.
echo "=== H: the file-only grant through netinstall's own sequence ==="
HDIR="$BLOBS/h"
rm -rf "$HDIR"; mkdir -p "$HDIR"
HTMP="$HDIR/.tmp-1"
HLINK="$APPS/h-probe.cmd"
rm -f "$HLINK"
: > "$HTMP"
run labelfile "$(W "$HTMP")" >/dev/null
h_intruder() {
    case "$(run spawn low "$P" write "$1")" in
        *"WRITE=OK"*)      echo "WIDENED" ;;
        *"WRITE=REFUSED"*) echo "refused" ;;
        *)                 echo "NOCHILD" ;;
    esac
}
H_AFTER_LABEL="$(h_intruder "$(W "$HTMP")")"
if [ -n "$CURLBIN" ]; then
    run spawn low,strip "$(W "$CURLBIN")" -fsS --max-filesize 1048576 \
        --max-time 30 "$NEUTRINO_TEST_ORIGIN/payload.bin" -o "$(W "$HTMP")" >/dev/null
fi
H_BYTES="$(wc -c < "$HTMP" 2>/dev/null | tr -d ' ')"
H_AFTER_FETCH="$(h_intruder "$(W "$HTMP")")"
run unlabel "$(W "$HTMP")" >/dev/null
H_AFTER_UNLABEL="$(h_intruder "$(W "$HTMP")")"
probe "H tmpfile: bytes=$H_BYTES labelled=$H_AFTER_LABEL fetched=$H_AFTER_FETCH unlabelled=$H_AFTER_UNLABEL"
probe "H tmpfile sddl after unlabel: $(run sddl "$(W "$HTMP")" | head -1)"
# And the step the directory form failed: the hard link that becomes the script.
HL="$(run hardlink "$(W "$HTMP")" "$(W "$HLINK")")"
probe "H $(grep -o 'HARDLINK=[A-Z]*' <<<"$HL" | head -1) link=$(h_intruder "$(W "$HLINK")") $(grep -o 'SDDL_LINK=.*' <<<"$HL" | head -1 | cut -c1-110)"

# =====================================================================
# I -- the second candidate, declined with a number
# =====================================================================
#
# Round one: a write-restricted child returns 0xC0000142 -- STATUS_DLL_INIT_
# FAILED -- under every grant, so nothing it measured about the filesystem meant
# anything. That is a process that never reached main, and the documented cause
# is the objects touched on the way in rather than any file: the window station,
# the desktop, and the session's named object directory.
#
# Two of those three are reachable without ntdll and section A now opens them.
# This is the reading that turns "declined" into a measurement: if the child
# still will not start with them open, the remaining one is the object
# namespace, and that is a great deal more machinery than a mechanism which low
# integrity already delivers.
if [ -n "$CURLBIN" ]; then
    echo "=== I: write-restricted, with the objects it dies on opened ==="
    IDIR="$BLOBS/i"
    rm -rf "$IDIR"; mkdir -p "$IDIR"
    ITMP="$IDIR/.tmp-1"
    : > "$ITMP"
    run grantwr "$(W "$ITMP")" >/dev/null
    IOUT="$(run spawn wrestricted,opendesk "$(W "$CURLBIN")" -fsS \
        --max-filesize 1048576 --max-time 30 \
        "$NEUTRINO_TEST_ORIGIN/payload.bin" -o "$(W "$ITMP")")"
    IBYTES=0
    [ -f "$ITMP" ] && IBYTES="$(wc -c < "$ITMP" | tr -d ' ')"
    probe "I wrestricted+opendesk: $(grep -o 'OPENDESK=[A-Z]*\|SPAWN=[A-Z]*\|CHILDRC=[0-9]*' <<<"$IOUT" | tr '\n' ' ')bytes=$IBYTES"
fi

bash "$ROOT/test/annotate.sh" lowfetch "$RESULTS" 'probe:'
echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
