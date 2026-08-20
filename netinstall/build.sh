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
    HOST_LIBS=""
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) HOST_LIBS="-ladvapi32" ;; esac
    $HOST_CC "${CFLAGS[@]}" ${NETINSTALL_CFLAGS:-} -o "$OUT/netinstall$HOST_EXE" \
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
