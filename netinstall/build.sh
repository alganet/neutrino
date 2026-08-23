#!/bin/bash
# build.sh - cross-compile netinstall for every supported os/arch
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/dist"
SRC=(netinstall.c env.c fetch.c sha256.c sandbox_linux.c sandbox_bsd.c sandbox_macos.c sandbox_win.c sandbox_none.c)
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
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) HOST_LIBS="-ladvapi32" ;; esac
    $HOST_CC "${HOST_CFLAGS[@]}" ${NETINSTALL_CFLAGS:-} -o "$OUT/netinstall$HOST_EXE" \
        "${SRC[@]}" $HOST_LIBS
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
    case "$triple" in *windows*) LIBS="-ladvapi32" ;; esac
    zig cc -target "$triple" "${CFLAGS[@]}" ${NETINSTALL_CFLAGS:-} \
        -o "$OUT/neutrino-netinstall-$name$ext" "${SRC[@]}" $LIBS
done

ls -1 "$OUT"
