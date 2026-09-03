#!/bin/bash
# landlockfloor.sh - which supported linux bases have landlock at all
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# PROBE, not a gate. It measures one number per distribution and asserts
# nothing, and it is expected to come out of SUITES once it has answered.
#
# The question. Today a machine with no Landlock gets a warning on stderr and
# runs anyway; sandbox_linux.c returns -1 with "none (landlock unavailable)" and
# netinstall.c's non-strict arm prints it and continues. Making that refusal the
# only behaviour turns every such machine from "runs, less confined than it
# says" into "does not run", and the size of that blast radius is not something
# to reason about from kernel version tables -- Landlock also has to be compiled
# in and present in the boot-time `lsm=` list, which is a distribution's
# decision and not a version's.
#
# What a container can answer, and what it cannot. This has to be said first
# because the obvious reading of the rows below is the wrong one.
#
# A container shares the host's kernel. Landlock is a kernel feature, its ABI is
# a kernel version, and whether it is available at all is decided by the host's
# CONFIG_SECURITY_LANDLOCK and the host's boot-time `lsm=` list. So running the
# binary in a debian:12 image on an ubuntu host and reading `landlock abi 8` off
# --info says nothing whatever about Debian 12: it is the host's number, printed
# inside somebody else's userland. The first version of this suite did exactly
# that on all seven bases, got the host's ABI seven times, and would have been
# read as "every supported base confines" by anyone who did not already know
# what a container is.
#
# There is no userland half to rescue it, either. netinstall is static musl and
# calls landlock_create_ruleset by number; the image contributes no libc, no
# loader and no policy to the result. The measurement is not weak, it is empty.
#
# So this suite does two things it can actually do, and refuses the third:
#
#   the binary runs on each base's userland  -- a static build meeting an image
#       with no glibc, or a minimal image with no /tmp, is a real failure mode
#       and this is a real control for it. It is not a Landlock reading and is
#       not reported as one;
#   the kernel each base ships              -- read out of the base's own
#       package index, which is a fact about the distribution rather than about
#       whoever is running this. 5.13 is where Landlock lands, and each row
#       prints the version so the comparison is in the log rather than in
#       somebody's memory;
#   whether that kernel has it enabled      -- NOT MEASURED HERE, and the
#       report says so on its own line rather than leaving a reader to infer it
#       from a number that looks like an answer. CONFIG_SECURITY_LANDLOCK and
#       the `lsm=` list are boot-time facts and want a booted kernel: a VM lane
#       per base, the way the BSDs already get one, is what would settle it.
#
# The bases are the ones in support as this is written. A base that drops out of
# support drops out of this list.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

echo "=== landlockfloor: landlock availability across supported bases ==="

if [ "$(uname -s)" != "Linux" ]; then
    echo "=== SKIP: landlock is a linux question ==="
    exit 0
fi
if ! command -v docker >/dev/null 2>&1; then
    # Not a silent pass: the suite exists to produce rows, and a run that
    # produced none should say which of the two reasons it was.
    echo "=== SKIP: no docker here; this probe needs containers to reach other bases ==="
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

probe() {
    echo "  $*"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# =====================================================================
# The instrument
# =====================================================================
# The static musl build, because a host binary is linked against the host's libc
# and would fail to start on half the images below for a reason that has nothing
# to do with Landlock -- which is exactly the kind of null result this probe
# must not produce.
BIN="$ROOT/netinstall/dist/neutrino-netinstall-linux-$(uname -m)"
if [ ! -x "$BIN" ] && command -v zig >/dev/null 2>&1; then
    echo "  building the static musl binary"
    bash "$ROOT/netinstall/build.sh" >"$WORK/build.log" 2>&1 ||
        nt_note "the cross build failed: $(tail -3 "$WORK/build.log" | tr '\n' ' ')"
fi

# The binary is optional, and this used to be a skip that took the whole suite
# with it. run.sh builds host binaries into dist/netinstall-*; it does not
# cross-compile, and no CI lane running this has zig -- so on CI the entire
# probe exited before it had asked anything, including the half that needs no
# binary at all.
#
# The kernel each base ships is a question for that base's package index and
# nothing else. Only the userland control needs something to run, and it wants
# the static musl build specifically: a host binary is linked against the host's
# libc and would fail on alpine for a reason that has nothing to do with
# netinstall, which is the null result this suite exists to avoid reporting.
# So the control is skipped by name when there is no musl build, rather than
# faked with a binary that cannot answer it.
APP=""
if [ -x "$BIN" ]; then
    # netinstall reads its own filename, so it has to be installed under a spec
    # before it will do anything -- including print --info.
    SPEC="floor-example-com-1$(nt_pin "$BIN")"
    APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
else
    nt_note "no static musl binary here; the userland control is not run and the kernel rows below are unaffected"
fi

# Reads the one field this suite is about out of the confine line.
#
#   "landlock abi 6 + seccomp, writes confined to ..."  -> 6
#   "none (landlock unavailable)"                       -> 0
#   anything else                                       -> ?
abi_from() {
    local line="$1"
    case "$line" in
        *"landlock abi "*)
            echo "$line" | sed -n 's/.*landlock abi \([0-9][0-9]*\).*/\1/p' ;;
        *"landlock unavailable"*) echo 0 ;;
        *) echo "?" ;;
    esac
}

confine_line() {
    sed -n 's/^confine  *//p' "$1" | head -1
}

# The kernel version a base ships, asked of that base's own package index. One
# command per family, kept in a function rather than in the table below because
# every one of them contains a pipe and the table is pipe-separated.
kernel_cmd_for() {
    case "$1" in
        debian-*)
            echo 'apt-get update -qq >/dev/null 2>&1; apt-cache policy "linux-image-$(dpkg --print-architecture)" 2>/dev/null | sed -n "s/.*Candidate: *//p" | head -1' ;;
        ubuntu-*)
            echo 'apt-get update -qq >/dev/null 2>&1; apt-cache policy linux-image-generic 2>/dev/null | sed -n "s/.*Candidate: *//p" | head -1' ;;
        rhel-*)
            # UBI's repositories do not carry the kernel package -- it needs an
            # entitlement these images do not have -- so there is no version to
            # read here at any effort. Measured: `dnf info kernel` on ubi9
            # answers "No matching Packages to list" after refreshing all three
            # repos. The release string is what the image will say, and saying
            # that plus the reason beats a bare UNREAD that looks like a
            # transient failure somebody should retry.
            echo 'echo "NOT-IN-UBI-REPO($(sed -n "s/.*release \([0-9.]*\).*/\1/p" /etc/redhat-release 2>/dev/null))"' ;;
        alpine)
            echo 'apk update -q >/dev/null 2>&1; apk policy linux-lts 2>/dev/null | sed -n "s/^ *\([0-9][^:]*\):.*/\1/p" | head -1' ;;
        *)  echo 'echo unknown' ;;
    esac
}

# =====================================================================
# The control -- the host
# =====================================================================
# This one row IS a Landlock reading, because it is the machine the binary is
# actually running on and the one confine.sh has just finished proving enforces.
# Every container row below is a reading of this same kernel and is reported as
# a userland result, not as a Landlock result.
if [ -n "$APP" ]; then
    "$APP" --info > "$WORK/host.info" 2>&1
    HOST_LINE="$(confine_line "$WORK/host.info")"
    HOST_ABI="$(abi_from "$HOST_LINE")"
    probe "report: landlockfloor host kernel=$(uname -r) abi=$HOST_ABI"
    if [ "$HOST_ABI" = "?" ] || [ -z "$HOST_ABI" ]; then
        nt_fail "could not read a confine line from --info on the host; the userland rows below are unreadable the same way"
    fi
else
    probe "report: landlockfloor host kernel=$(uname -r) abi=NOT-RUN (no musl build)"
fi

# =====================================================================
# The bases
# =====================================================================
# name|image. Kept as one list so adding a base is one line and the report and
# the run cannot disagree about which images were tried.
BASES="
debian-12|debian:12-slim
debian-13|debian:13-slim
ubuntu-24.04|ubuntu:24.04
ubuntu-26.04|ubuntu:26.04
rhel-9|registry.access.redhat.com/ubi9/ubi-minimal
rhel-10|registry.access.redhat.com/ubi10/ubi-minimal
alpine|alpine:latest
"


RUNS_OK=""
RUNS_BAD=""
TOO_OLD=""

for entry in $BASES; do
    name="${entry%%|*}"
    image="${entry#*|}"

    if ! docker pull "$image" >"$WORK/pull.log" 2>&1; then
        probe "report: landlockfloor $name runs=UNREACHED kernel=UNREACHED (pull failed)"
        RUNS_BAD="$RUNS_BAD $name"
        continue
    fi

    # Does the static binary run on this base's userland at all? That is the
    # whole of what the container arm is for -- a static musl build meeting an
    # image with no /tmp, or a minimal image missing something it assumed, is a
    # real failure mode and this is a real control for it.
    #
    # --security-opt seccomp=unconfined because the default profile has
    # historically returned EPERM for landlock_create_ruleset, which would turn
    # a userland question into a syscall-filter one. HOME because these images
    # do not agree on it -- some leave it unset -- and netinstall resolves the
    # cache directory under it before it prints anything.
    if [ -n "$APP" ]; then
        docker run --rm --security-opt seccomp=unconfined -e HOME=/tmp \
            -v "$WORK/bin:/probe:ro" "$image" /probe/"$(basename "$APP")" --info \
            > "$WORK/$name.info" 2>&1
        if grep -q '^appdir ' "$WORK/$name.info"; then
            runs=yes
            RUNS_OK="$RUNS_OK $name"
        else
            runs=no
            RUNS_BAD="$RUNS_BAD $name"
        fi
    else
        runs=NOT-RUN
    fi

    # And what kernel does it ship? Asked of the base's own package index, so
    # this one is a fact about the distribution rather than about whatever host
    # happens to be underneath the container.
    kern="$(docker run --rm "$image" sh -c "$(kernel_cmd_for "$name")" \
        2>/dev/null | tr -d '\r' | head -1)"
    [ -n "$kern" ] || kern=UNREAD

    # 5.13 is where Landlock lands. Compared on the first two components with
    # sort -V, which is the shape every one of these version strings agrees on.
    verdict=unknown
    short="$(echo "$kern" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
    if [ -n "$short" ]; then
        if [ "$(printf '5.13\n%s\n' "$short" | sort -V | head -1)" = "5.13" ]; then
            verdict=kernel-has-landlock
        else
            verdict=KERNEL-TOO-OLD
            TOO_OLD="$TOO_OLD $name"
        fi
    fi

    probe "report: landlockfloor $name runs=$runs kernel=$kern $verdict"
done

# =====================================================================
# What this settled, and what it did not
# =====================================================================
probe "report: landlockfloor USERLAND_OK=${RUNS_OK:- none}"
probe "report: landlockfloor USERLAND_FAILED=${RUNS_BAD:- none}"
probe "report: landlockfloor KERNEL_TOO_OLD=${TOO_OLD:- none}"
# Printed every run rather than left in a comment at the top. The lines above
# look enough like an answer that a reader who stops at them will reach the
# wrong conclusion confidently, and this is the sentence that stops that.
probe "report: landlockfloor ENABLED_AT_BOOT=UNMEASURED -- CONFIG_SECURITY_LANDLOCK and the boot lsm= list decide this, and a container shares the host kernel; only a VM per base can answer it"

echo "=== landlockfloor: reported ==="
exit 0
