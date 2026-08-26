#!/bin/bash
# bsdfloor.sh - what FreeBSD and NetBSD actually do with sandbox_bsd.c
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Reports what this platform does, and gates the three answers that are
# findings rather than descriptions: that the branch compiles, which sysctl
# spelling answers "what is running", and whether the no-new-privs floor is a
# floor. Ground rule 6 -- a platform answer that a decision turned on is
# asserted to its measured value, so a change in either direction is a failure
# and not a silence. Everything else here is a `report:` line and scores
# nothing.
#
# PR 11 put the __OpenBSD__ half of sandbox_bsd.c under a lane and found four of
# its rules wrong. The other half -- FreeBSD, NetBSD -- has still never been
# compiled by anything here: build.sh cross-compiles six targets and none of
# them is a BSD, the openbsd lane compiles the branch above this one, and the
# suites have meanwhile grown FreeBSD|NetBSD arms that were written from the
# OpenBSD reading rather than from a measurement. This asks the platform.
#
# Four questions, in the order a round can afford to lose them:
#
#   1. Does the file compile there at all, and does build.sh's decision to drop
#      -D_POSIX_C_SOURCE on the BSDs matter here the way it does on OpenBSD?
#   2. What does --info print, per tier -- which is what the suites' blind arms
#      are asserting against.
#   3. Does a strict build refuse, which is the whole contract of returning -1.
#   4. Is the no-new-privs floor real: not "procctl returned 0" but "a setuid
#      binary executed afterwards does not come back root", with the same exec
#      without the flag as the control.
#
# Readings leave as `report:` lines; the lane's annotate step carries them out.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d /tmp/bsdfloor.XXXXXX)"
. "$HERE/lib.sh"
CC="${NETINSTALL_CC:-cc}"
# The flags build.sh's host path uses on a BSD: everything in CFLAGS except the
# POSIX macro, which it drops on exactly these four systems.
CFLAGS="-std=c99 -Wall -Wextra -Os -fno-strict-aliasing"
# 32 hex, which is the pin floor. Nothing here verifies a pin -- --info prints
# the spec it was invoked under and does not check it -- so a literal keeps this
# section working on a platform where nt_sha256 has nothing to call.
# The host is deliberately under .invalid, which is reserved and resolves
# nowhere: the run below is about whether a strict build refuses before it
# fetches, and a probe that reaches the network to find that out is measuring
# the runner's DNS as much as the confinement.
SPEC="bsdfloor-invalid-nx-00123456789abcdef0123456789abcdef"

# Every reading is echoed for the log and kept in a file, because three of them
# are read back below to be asserted and re-deriving a value is how two
# spellings of one measurement get compared with each other.
report() {
    echo "  report: $*"
    [ -n "${WORK:-}" ] && echo "$*" >> "$WORK/reports.out" 2>/dev/null
    return 0
}

FAILURES=0
check() {   # check <label> <want> <got>
    if [ "$3" = "$2" ]; then
        echo "  PASS: $1 ($3)"
    else
        nt_fail "$1 expected=$2 actual=$3"
        FAILURES=$((FAILURES + 1))
    fi
}
skip() { nt_note "SKIP: $*"; }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# =====================================================================
# 1. The platform, and what a suite would find to run on
# =====================================================================
echo "=== platform ==="
report "platform os=$(uname -s) rel=$(uname -r) arch=$(uname -m) cc=$("$CC" --version 2>/dev/null | head -1 | cut -c1-60)"
report "root=$( [ "$(id -u)" = "0" ] && echo yes || echo no ) user=$(id -un 2>/dev/null)"

have=""; missing=""
for t in bash cc curl wget python3 python timeout perl seq su; do
    if command -v "$t" >/dev/null 2>&1; then have="$have $t"; else missing="$missing $t"; fi
done
report "tools have:$have"
report "tools missing:${missing:- none}"

# lib.sh's nt_sha256 tries sha256sum, then shasum, then sha256(1). OpenBSD has
# the third; whether either of these does is the difference between the suite
# running and the suite exiting 2 on its first fixture, so ask before blaming
# the confinement for it.
digest=""
echo hello > "$WORK/d"
for d in "sha256sum $WORK/d" "shasum -a 256 $WORK/d" "sha256 -q $WORK/d" \
         "cksum -a sha256 $WORK/d" "digest -a sha256 $WORK/d" \
         "openssl dgst -sha256 $WORK/d"; do
    set -- $d
    command -v "$1" >/dev/null 2>&1 || continue
    # The name and the first sixteen characters of whatever it printed. Which
    # tool works matters here; the digest of "hello" does not.
    out="$("$@" 2>/dev/null | head -1 | tr -d "\n" | cut -c1-40)"
    [ -n "$out" ] && digest="$digest [$1 -> $out]"
done
report "digest${digest:- none of the six}"

# =====================================================================
# 2. Whether sandbox_bsd.c compiles, and under which spelling
# =====================================================================
echo "=== compiling sandbox_bsd.c ==="

# The shim exists to ask one question without editing the file: sandbox_bsd.c
# includes <sys/procctl.h> before <sys/types.h>, and procctl(2) is documented
# with types.h first. If the as-is build fails and this one does not, the
# include order is the whole finding.
cat > "$WORK/order.c" <<'EOF'
#include <sys/types.h>
#include "sandbox_bsd.c"
EOF

compile() {
    local label="$1" src="$2"; shift 2
    local log="$WORK/$label.log" rc=0 warns

    ( cd "$ROOT" && $CC $CFLAGS "$@" -I"$ROOT" -c "$src" -o "$WORK/$label.o" ) \
        > "$log" 2>&1 || rc=$?
    warns="$(grep -c 'warning:' "$log" 2>/dev/null)"
    warns="${warns:-0}"
    echo "$rc" > "$WORK/$label.rc"
    report "compile $label rc=$rc warnings=$warns"
    # Only when it went wrong, and only the first two: a diagnostic dump is
    # unbounded by construction and this shares a step with the readings.
    if [ "$rc" != "0" ] || [ "$warns" != "0" ]; then
        grep -E 'error:|warning:' "$log" 2>/dev/null | head -2 |
            while IFS= read -r l; do report "  cc: $(echo "$l" | cut -c1-140)"; done
    fi
    return 0
}

compile asis   "sandbox_bsd.c"
# The one that is a gate: everything else in this PR rests on the branch
# building at all, and nothing in this repository compiled it before this lane.
check "sandbox_bsd.c compiles as written" 0 "$(cat "$WORK/asis.rc" 2>/dev/null)"
compile order  "$WORK/order.c"
# The control for build.sh's exclusion. On OpenBSD this macro hides unveil and
# pledge behind __BSD_VISIBLE and the build either fails or silently compiles
# implicit declarations. Whether it costs anything on these two is unmeasured,
# and build.sh already drops it for them on the strength of the OpenBSD reading.
compile posix  "sandbox_bsd.c" -D_POSIX_C_SOURCE=200809L

# =====================================================================
# 3. The four builds, and what --info says each of them applies
# =====================================================================
echo "=== builds and --info ==="

build() {
    local label="$1" flags="$2" rc=0
    local log="$WORK/build-$label.log"

    ( cd "$ROOT" && NETINSTALL_CFLAGS="$flags" bash build.sh host ) > "$log" 2>&1 || rc=$?
    if [ "$rc" != "0" ]; then
        report "build $label rc=$rc"
        grep -E 'error:' "$log" 2>/dev/null | head -2 |
            while IFS= read -r l; do report "  cc: $(echo "$l" | cut -c1-140)"; done
        return 1
    fi
    mkdir -p "$WORK/bin-$label"
    cp "$ROOT/dist/netinstall" "$WORK/bin-$label/$SPEC" || return 1
    return 0
}

info_line() {   # info_line <label> <field>
    "$WORK/bin-$1/$SPEC" --info 2>/dev/null | grep "^$2 " | sed "s/^$2 *//" | cut -c1-150
}

if build default "-DNEUTRINO_TESTING"; then
    report "info default confine: $(info_line default confine)"
    report "info default fetch:   $(info_line default fetch)"
    report "info default config:  $(info_line default config)"
fi
if build tight "-DNEUTRINO_TESTING -DNEUTRINO_CONFINE_TIGHT"; then
    report "info tight confine:   $(info_line tight confine)"
    report "info tight fetch:     $(info_line tight fetch)"
fi
if build offline "-DNEUTRINO_TESTING -DNEUTRINO_CONFINE_OFFLINE"; then
    report "info offline confine: $(info_line offline confine)"
fi
if build session "-DNEUTRINO_TESTING -DNEUTRINO_CONFINE_NOSESSION"; then
    report "info session confine: $(info_line session confine)"
fi

# =====================================================================
# 4. Whether a strict build refuses, which is what returning -1 is for
# =====================================================================
echo "=== the strict build ==="
if build strict "-DNEUTRINO_TESTING -DNEUTRINO_STRICT_SANDBOX"; then
    # --info never confines, so this only says the binary runs at all.
    "$WORK/bin-strict/$SPEC" --info > "$WORK/strict-info.log" 2>&1
    report "strict --info rc=$? confine: $(grep '^confine ' "$WORK/strict-info.log" | sed 's/^confine *//' | cut -c1-110)"
    # The contract of returning -1: a strict build refuses rather than running
    # unconfined. What it must not do is get as far as the downloader. The rc
    # is captured off the binary and not off a pipeline -- `| head` kills it
    # with SIGPIPE and reports 141 for every outcome alike.
    "$WORK/bin-strict/$SPEC" > "$WORK/strict-run.log" 2>&1
    rc=$?
    report "strict run rc=$rc out=$(head -2 "$WORK/strict-run.log" | tr '\n' ' ' | cut -c1-140)"
fi

# =====================================================================
# 5. Which sysctl spelling answers "what is running"
# =====================================================================
# Round 2 read `netinstall: "" is not a valid spec` on NetBSD for every name the
# suite offered, and an empty confine line from --info on all five tiers.
# nt_self_path asks for its own path with FreeBSD's mib layout on all three
# BSDs; NetBSD spells it differently and both constants exist on both, so the
# #ifdef is satisfied and the wrong spelling compiles in silently.
echo "=== self path ==="
sp_rc=0
( cd "$ROOT" && $CC $CFLAGS -o "$WORK/selfpath" "$HERE/selfpath-probe.c" ) \
    > "$WORK/selfpath.log" 2>&1 || sp_rc=$?
if [ "$sp_rc" != "0" ]; then
    report "selfpath compile rc=$sp_rc $(head -1 "$WORK/selfpath.log" | cut -c1-140)"
    # On the two platforms this section exists for, a probe that will not build
    # is a round that measured nothing -- and it must not read as a pass.
    case "$(uname -s)" in
        FreeBSD|NetBSD) check "selfpath-probe.c builds" 0 "$sp_rc" ;;
        *)              skip "no sysctl(3) here; the selfpath spellings are a BSD question" ;;
    esac
else
    # Run it from a name of its own, so a reading that happens to be the shell's
    # path or the compiler's is visible as one.
    cp "$WORK/selfpath" "$WORK/selfpath-under-this-name"
    "$WORK/selfpath-under-this-name" > "$WORK/selfpath.out" 2>&1
    while IFS= read -r l; do
        report "selfpath $(echo "$l" | cut -c1-150)"
    done < "$WORK/selfpath.out"
    sp_field() { awk -v k="$1" '$1 == k { print $2 " " $3 }' "$WORK/selfpath.out"; }
    # Both spellings, on whichever platform this is, asserted to the answer
    # nt_self_path was rewritten around. If NetBSD ever starts answering
    # FreeBSD's question -- or stops answering its own -- this goes red and says
    # which one moved, rather than every name on the platform quietly failing to
    # parse again.
    case "$(uname -s)" in
        FreeBSD)
            check "the shipped mib answers here"     "rc=0" "$(sp_field as-shipped | cut -d' ' -f1)"
            check "and it answers with bytes in it"  "first=byte" "$(awk '$1=="as-shipped"{print $NF}' "$WORK/selfpath.out")"
            check "NetBSD's spelling is refused here" "rc=-1" "$(sp_field netbsd-order | cut -d' ' -f1)" ;;
        NetBSD)
            # len=0 is the finding: a success that wrote nothing, which
            # nt_self_path used to accept. Asserted rather than described.
            check "the shipped mib succeeds writing nothing" "len=0" "$(sp_field as-shipped | cut -d' ' -f2)"
            check "and NetBSD's own spelling answers"        "first=byte" "$(awk '$1=="netbsd-order"{print $NF}' "$WORK/selfpath.out")" ;;
        *)  skip "selfpath spellings are asserted on FreeBSD and NetBSD only" ;;
    esac
fi

# =====================================================================
# 6. The floor: not the flag, the consequence
# =====================================================================
echo "=== no-new-privs ==="
nnp_rc=0
( cd "$ROOT" && $CC $CFLAGS -o "$WORK/nnp" "$HERE/nnp-probe.c" ) > "$WORK/nnp.log" 2>&1 || nnp_rc=$?
if [ "$nnp_rc" != "0" ]; then
    report "nnp compile rc=$nnp_rc $(head -1 "$WORK/nnp.log" | cut -c1-140)"
else
    report "nnp flag $("$WORK/nnp" flag)"
    if [ "$(id -u)" != "0" ]; then
        # Not a silence: only root can create the setuid file this measures
        # against, so on an unprivileged runner the section has no experiment.
        report "nnp exec skipped: not root, cannot create a setuid file"
    else
        # Two filesystems, because round 2's control failed on FreeBSD and
        # passed on NetBSD with the same code: the setuid file was under /tmp,
        # and a nosuid mount refuses a set-user-ID bit without saying so
        # anywhere the probe could see. The mount options go in the reading, and
        # the experiment is repeated somewhere else, so "no-new-privs blocked
        # it" and "the filesystem did" stop looking alike.
        suid_at() {
            local dir="$1" label="$2" mp opts
            mkdir -p "$dir" 2>/dev/null || {
                report "nnp $label: cannot create $dir"; return 0; }
            # $WORK is a mktemp directory, which is 0700, and the process that
            # execs this has already dropped to nobody -- so without opening the
            # path the exec fails EACCES on traversal and reads exactly like a
            # nosuid mount. Round 3 read errno=13 on both platforms' /tmp arm
            # for that reason and not for the one it was asking about.
            chmod 755 "$dir" "$(dirname "$dir")" 2>/dev/null || true
            cp "$WORK/nnp" "$dir/nnp-suid" 2>/dev/null || {
                report "nnp $label: cannot place a binary in $dir"; return 0; }
            chown 0 "$dir/nnp-suid" 2>/dev/null
            chmod 4755 "$dir/nnp-suid"
            mp="$(df -P "$dir" 2>/dev/null | tail -1 | awk '{print $NF}')"
            opts="$(mount 2>/dev/null | grep " on ${mp:-/nowhere} " | head -1 |
                    sed -e 's/.*(\(.*\)).*/\1/' | cut -c1-70)"
            report "nnp $label dir=$dir fs=${mp:-?} opts=${opts:-?} mode=$(ls -l "$dir/nnp-suid" | cut -c1-10)"
            # The control first. If this does not come back euid=0 the platform
            # refused the setuid for a reason of its own and the reading below
            # would be a pass by accident.
            report "nnp $label control (no flag): $("$WORK/nnp" run 0 "$dir/nnp-suid" 2>&1 | head -1)"
            report "nnp $label with flag:         $("$WORK/nnp" run 1 "$dir/nnp-suid" 2>&1 | head -1)"
            rm -f "$dir/nnp-suid"
        }
        # /tmp is reported and never scored: whether it carries nosuid is the
        # runner image's business and not this program's. The /root arm is the
        # experiment, because that is where the control passes.
        suid_at "$WORK/suid" tmp
        suid_at "${HOME:-/root}/bsdfloor-suid" home

        NT_CTL="$(sed -n 's/.*nnp home control (no flag): //p' "$WORK/reports.out")"
        NT_FLAG="$(sed -n 's/.*nnp home with flag: *//p' "$WORK/reports.out")"
        case "$NT_CTL" in
            "euid=0 "*)
                # Ground rule 3: the refusal is only worth reading because the
                # same exec without the flag came back root.
                echo "  PASS: the control gained root, so the reading below is about the flag"
                case "$(uname -s)" in
                    FreeBSD)
                        check "no-new-privs stops a setuid gain" \
                            "blocked" "$(case "$NT_FLAG" in "euid=0 "*) echo gained ;; euid=*) echo blocked ;; *) echo "$NT_FLAG" ;; esac)" ;;
                    NetBSD)
                        # The honest answer here is that there is no mechanism,
                        # asserted so that gaining one is a failure and not a
                        # silence.
                        check "there is no such control on this platform" \
                            "ctl-absent" "$NT_FLAG" ;;
                    *)  skip "the floor is asserted on FreeBSD and NetBSD only" ;;
                esac ;;
            *)  skip "the setuid control did not gain root ($NT_CTL); the flag reading below would be a pass by accident" ;;
        esac
    fi
fi

echo "=== bsdfloor: $FAILURES failure(s) ==="
exit "$FAILURES"
