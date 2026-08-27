#!/bin/bash
# build.sh - assemble the site served at alganet.github.io/neutrino/
#
# Two sections of downloads: a sample neutrino app, and the netinstall binaries
# that fetch it. Those binaries are published under the spec they need as their
# filename, derived here from the digest of the app this script just built and
# never written by hand -- so a download cannot come to pin a file that is not
# the one beside it, and nobody has to rename anything.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-$ROOT/_site}"

# Where this is published, and the two facts the shape encodes. Change these
# together with the repository or the Pages settings, never separately.
HOST="alganet.github.io"
DIR="neutrino"
APP="demo"
SHAPE=3          # 3 = one directory, and the file is named
PINLEN=32        # the parser's floor, and what every example in the docs uses

# What a Windows machine fetches on top of the app the first time it runs one:
# the WebView2 package, which neutrino downloads into the app directory. Linux
# and macOS render on a runtime the system already has and fetch nothing.
# 8.8 MiB, as measured and recorded in netinstall/README.md.
WEBVIEW2_BYTES=$((8 * 1048576 + 819200))

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# LC_ALL=C, because awk takes its decimal separator from the locale and this
# machine rendered "9,0 MB" on a page that CI would have rendered "9.0 MB".
# A size that depends on who ran the build is not a size.
human() {
    LC_ALL=C awk -v b="$1" 'BEGIN {
        if (b < 1024) printf "%d B", b;
        else if (b < 1048576) printf "%.0f KB", b / 1024;
        else printf "%.1f MB", b / 1048576;
    }'
}

rm -rf "$OUT"
mkdir -p "$OUT"

echo "Building the sample app"
bash "$ROOT/build.sh" "$HERE/demo.js" "$OUT/$APP.cmd"

# netinstall/build.sh falls back to a host-only build when zig is missing, and
# says so on stderr rather than failing. Publishing on top of that fallback is
# how a page comes to list five stale binaries and one current one, so the
# cross-compile is required here rather than hoped for.
if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig is needed to cross-compile the published netinstall binaries" >&2
    echo "       (netinstall/build.sh alone would silently build only this host)" >&2
    exit 1
fi

echo "Building netinstall"
rm -f "$ROOT"/netinstall/dist/neutrino-netinstall-*
bash "$ROOT/netinstall/build.sh"

APPBYTES="$(wc -c < "$OUT/$APP.cmd" | tr -d ' ')"
SHA="$(sha256_of "$OUT/$APP.cmd")"
SPEC="$APP-$DIR-$(printf '%s' "$HOST" | tr '.' '-')-$SHAPE$(printf '%s' "$SHA" | cut -c1-"$PINLEN")"

# netinstall reads its own filename, so the file someone downloads has to
# already be the spec -- nobody should have to rename anything. Six binaries
# cannot share a directory under one name, so each platform gets its own, and
# the basename is identical in all of them. A browser's save and `curl -O` both
# keep that basename, which is the whole point.
#
# The order is written here rather than taken from the glob, which sorts ARM64
# above x86-64 on both Linux and Windows. A target that build.sh grows and this
# list does not know is a download nobody can find, so it is an error rather
# than a silent omission -- the label has to be written before it can ship.
PLATFORMS="linux-x86_64 linux-aarch64 macos-arm64 macos-x86_64 windows-x86_64 windows-aarch64"

label_for() {
    case "$1" in
        linux-x86_64)     echo "Linux &middot; x86-64" ;;
        linux-aarch64)    echo "Linux &middot; ARM64" ;;
        macos-x86_64)     echo "macOS &middot; Intel" ;;
        macos-arm64)      echo "macOS &middot; Apple silicon" ;;
        windows-x86_64)   echo "Windows &middot; x86-64" ;;
        windows-aarch64)  echo "Windows &middot; ARM64" ;;
    esac
}

BINARIES=""
for plat in $PLATFORMS; do
    ext=""
    case "$plat" in windows-*) ext=".exe" ;; esac
    src="$ROOT/netinstall/dist/neutrino-netinstall-$plat$ext"
    if [ ! -f "$src" ]; then
        echo "error: netinstall/build.sh produced no $plat binary" >&2
        exit 1
    fi
    mkdir -p "$OUT/$plat"
    cp "$src" "$OUT/$plat/$SPEC$ext"
    BINARIES="$BINARIES    <li><a href=\"$plat/$SPEC$ext\" download>$(label_for "$plat")</a><span class=\"size\">$(human "$(wc -c < "$src")")</span></li>"$'\n'
done

# And the other direction: a binary on disk that no row points at.
for f in "$ROOT"/netinstall/dist/neutrino-netinstall-*; do
    plat="$(basename "$f")"
    plat="${plat#neutrino-netinstall-}"
    plat="${plat%.exe}"
    case " $PLATFORMS " in
        *" $plat "*) ;;
        *) echo "error: $plat has no row in pages/build.sh; add a label for it" >&2; exit 1 ;;
    esac
done

# BINARIES is multi-line, so it goes in through r rather than s.
printf '%s' "$BINARIES" > "$OUT/.binaries.html"

# The launcher's row carries what running it costs, which is not the same as
# what downloading it costs: on Windows the app fetches the WebView2 package on
# top of itself. A size column that stopped at the file would be off by a factor
# of fifty there. The figure is the addition, not the total -- "+" says so.
DEMOSIZE="$(human "$APPBYTES") (+$(human "$WEBVIEW2_BYTES") only on Windows first run)"

echo "Rendering index.html"
sed -e "s|@DEMOSIZE@|$DEMOSIZE|g" \
    -e "/@BINARIES@/{r $OUT/.binaries.html" -e "d;}" \
    "$HERE/index.html.in" > "$OUT/index.html"
rm -f "$OUT/.binaries.html"

# actions/deploy-pages serves the artifact as uploaded and runs no Jekyll, so
# this changes nothing today. It is here because a branch-based publish does run
# Jekyll, and Jekyll drops files it does not recognise -- a .cmd polyglot being
# exactly such a file. One empty file against a silent 404 later.
touch "$OUT/.nojekyll"

if grep -q '@[A-Z0-9]*@' "$OUT/index.html"; then
    echo "error: unsubstituted placeholder left in index.html" >&2
    grep -o '@[A-Z0-9]*@' "$OUT/index.html" | sort -u >&2
    exit 1
fi

echo
(cd "$OUT" && find . -type f | sed 's|^\./|  |' | sort)
echo
echo "  app   https://$HOST/$DIR/$APP.cmd"
echo "  name  $SPEC"
echo "  sha   $SHA"
