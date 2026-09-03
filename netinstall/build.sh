#!/bin/bash
# build.sh - cross-compile netinstall for every supported os/arch
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/dist"
SRC=(netinstall.c env.c fetch.c sha256.c sandbox_linux.c sandbox_bsd.c sandbox_macos.c sandbox_win.c splash.c splash_posix.c splash_x11.c splash_wayland.c splash_win.c splash_macos.c splash_none.c)
CFLAGS=(-std=c99 -Wall -Wextra -Os -fno-strict-aliasing -D_POSIX_C_SOURCE=200809L)

TARGETS=(
    "linux-x86_64:x86_64-linux-musl:"
    "linux-aarch64:aarch64-linux-musl:"
    "macos-x86_64:x86_64-macos:"
    "macos-arm64:aarch64-macos:"
    "windows-x86_64:x86_64-windows:.exe"
    "windows-aarch64:aarch64-windows:.exe"
)

mkdir -p "$OUT"
cd "$HERE"

# The subsystem byte out of a PE optional header: the 4-byte offset at 0x3c
# names the PE signature, and Subsystem sits 92 bytes past it in both PE32 and
# PE32+. 2 is GUI, 3 is CONSOLE. od because this has to run wherever the rest
# of this script does, and that includes runners with no python.
nt_pe_subsystem() {
    local f="$1" pe
    pe="$(od -An -tu4 -j 60 -N 4 "$f" | tr -d ' \n')"
    od -An -tu2 -j "$((pe + 92))" -N 2 "$f" | tr -d ' \n'
}

if [ "${1:-}" = "host" ] || ! command -v zig >/dev/null 2>&1; then
    if [ "${1:-}" != "host" ]; then
        echo "zig not found; building host binary only" >&2
    fi
    HOST_CC="${NETINSTALL_CC:-cc}"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) HOST_EXE=".exe" ;;
        *)                    HOST_EXE="" ;;
    esac
    # -D_POSIX_C_SOURCE is what turns __BSD_VISIBLE off in <sys/cdefs.h>, and
    # the BSDs declare unveil, pledge and closefrom behind it -- so with it the
    # host build either does not link at all (<sys/sysctl.h> needs u_long, which
    # is hidden by the same macro) or, worse, compiles the confinement as
    # implicit int(...) calls that happen to work on this ABI and are one
    # -Werror away from not existing. It is there for glibc and musl, which are
    # not these systems. Measured on OpenBSD 7.9 / clang 19: clean without it.
    HOST_CFLAGS=()
    for f in "${CFLAGS[@]}"; do
        case "$(uname -s):$f" in
            OpenBSD:-D_POSIX_C_SOURCE=*|FreeBSD:-D_POSIX_C_SOURCE=*|\
            NetBSD:-D_POSIX_C_SOURCE=*|DragonFly:-D_POSIX_C_SOURCE=*) continue ;;
        esac
        HOST_CFLAGS+=("$f")
    done
    HOST_LIBS=""
    HOST_EXTRA=""
    # The same subsystem the cross build links, for the same reason and with the
    # same check. The suite runs against this binary, and a host build left on
    # the console subsystem would be testing the console behaviour of a program
    # that does not ship one -- every assertion about where a diagnostic goes
    # would be measuring the wrong binary.
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            HOST_LIBS="-ladvapi32 -luser32 -lgdi32"
            HOST_EXTRA="-Wl,--subsystem,windows" ;;
    esac
    $HOST_CC "${HOST_CFLAGS[@]}" $HOST_EXTRA ${NETINSTALL_CFLAGS:-} \
        -o "$OUT/netinstall$HOST_EXE" "${SRC[@]}" $HOST_LIBS
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            got="$(nt_pe_subsystem "$OUT/netinstall$HOST_EXE")"
            if [ "$got" != "2" ]; then
                echo "build.sh: host binary linked subsystem $got, wanted 2 (GUI)" >&2
                exit 1
            fi
            ;;
    esac
    echo "  $OUT/netinstall$HOST_EXE"
    exit 0
fi

for entry in "${TARGETS[@]}"; do
    name="${entry%%:*}"
    rest="${entry#*:}"
    triple="${rest%%:*}"
    ext="${rest#*:}"
    echo "building $name"
    LIBS=""
    EXTRA=""
    case "$triple" in
        # -mwindows is the subsystem, and the reason the two below are needed:
        # with no console of its own this binary has nowhere to print, so
        # MessageBoxA carries the diagnostics and a real window carries the
        # Loading... -- both of which live in user32.
        #
        # -Wl,--subsystem,windows and not -mwindows. zig cc accepts -mwindows,
        # warns that it went unused, and links a CONSOLE binary anyway -- so the
        # flag that reads as the obvious one is a flag that silently does
        # nothing, which is why nt_pe_subsystem below reads the answer back out
        # of the artifact instead of trusting the command line. Measured on zig
        # 0.16.0: -mwindows gives subsystem 3, this gives 2.
        *windows*) LIBS="-ladvapi32 -luser32 -lgdi32"; EXTRA="-Wl,--subsystem,windows" ;;
    esac
    zig cc -target "$triple" "${CFLAGS[@]}" $EXTRA ${NETINSTALL_CFLAGS:-} \
        -o "$OUT/neutrino-netinstall-$name$ext" "${SRC[@]}" $LIBS
    # Read back what was asked for. A console binary here is not a cosmetic
    # miss: it is a black window on every launch, and the splash and the
    # message box both exist because there is not supposed to be one.
    case "$triple" in
        *windows*)
            got="$(nt_pe_subsystem "$OUT/neutrino-netinstall-$name$ext")"
            if [ "$got" != "2" ]; then
                echo "build.sh: $name linked subsystem $got, wanted 2 (GUI)" >&2
                exit 1
            fi
            ;;
    esac
done

ls -1 "$OUT"
