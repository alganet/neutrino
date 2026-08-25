#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# build.sh - Neutrino polyglot assembler
# Usage: ./build.sh [--tier=<list>] <app.js> <output.cmd>
#
# Takes a JS file and embeds it into the runWeb() slot of webview.cmd,
# producing a new polyglot .cmd file.
#
# The tier list is stamped into the output at build time and read back out of
# the file at run time by whichever language is driving. netinstall does the
# same thing with -D flags for the same reason: a shipped artifact should have
# no way to be talked out of confining anything, and an environment variable is
# exactly such a way. Tiers compose as independent axes, comma separated:
#
#   default   the confinement every build gets. Always present, never optional.
#   tight     self-applied process confinement, where the platform has any.
#   offline   deny the page the network, at the document. Measured, on all four
#             engines: the app's own page script cannot fetch, XHR, load an
#             image, a stylesheet, a script or an iframe, or reach for
#             sendBeacon, EventSource or a WebSocket. It also stops the page
#             handing a url to the machine's browser, which no content policy
#             can see. What it does not stop is the request a top-level
#             navigation makes on its way to being refused: gjs and Qt refuse
#             before the request, macOS and Windows after it, so on those two an
#             offline build leaks one GET per navigation attempt. This is a
#             document-level tier and not a process-level one -- netinstall's
#             -DNEUTRINO_CONFINE_OFFLINE is the second, and they compose.
#   testing   re-enable test scaffolding. Never in a release build.

set -euo pipefail

TIER="default"

while [ $# -gt 0 ]; do
    case "$1" in
        --tier=*) TIER="${1#--tier=}"; shift ;;
        --tier)   TIER="${2:-}"; shift 2 ;;
        --)       shift; break ;;
        -*)       echo "Error: unknown option $1" >&2; exit 1 ;;
        *)        break ;;
    esac
done

if [ $# -lt 2 ]; then
    echo "Usage: $0 [--tier=<list>] <app.js> <output.cmd>" >&2
    exit 1
fi

APP_JS="$1"
OUTPUT="$2"
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/webview.cmd"

if [ ! -f "$APP_JS" ]; then
    echo "Error: $APP_JS not found" >&2
    exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
    echo "Error: $TEMPLATE not found" >&2
    exit 1
fi

# The output may not be either input, and this is checked before anything is
# opened because by then it is already too late.
#
# `> "$OUTPUT"` is set up before the pipeline below reads the template, so
# naming the template as the output truncated it and the build spliced nothing.
# It exited 0: the stamp check at the bottom read the first `tiers:` line in the
# output, and an app carrying one of its own supplied it. Measured on all four
# lanes -- `webview.cmd` 116 bytes, exit 0. With an app that carries no such
# line it exits 1 instead and the `rm` that follows deletes the template as
# well. Both destroy it; one of them says so.
#
# Naming the app as the output is the same opening in a worse shape. The
# redirection belongs to the `sed` on the right of the pipeline and the `cat` on
# the left runs beside it, so the assembler reads back what it has already
# written -- a 116-byte app came out 213225 bytes on three lanes and 164073 on
# the fourth, from the same inputs.
#
# `-ef` is a comparison of what the two names resolve to and not of the strings,
# which is what makes `./webview.cmd` and `webview.cmd` one file. Measured
# supported on GNU bash 5.2, 5.3 under MINGW64, and the 3.2.57 macOS ships.
if [ -e "$OUTPUT" ] && { [ "$OUTPUT" -ef "$TEMPLATE" ] || [ "$OUTPUT" -ef "$APP_JS" ]; }; then
    echo "Error: the output is one of the inputs; it would be destroyed before it was read" >&2
    exit 1
fi

# "default" is not optional, so it is added rather than required, and a tier
# named something this build does not understand is a typo that would otherwise
# silently produce a weaker artifact than the one that was asked for.
case ",$TIER," in *,default,*) ;; *) TIER="default,$TIER" ;; esac
TIER="${TIER%,}"
for t in $(echo "$TIER" | tr ',' ' '); do
    case "$t" in
        default|tight|offline|testing) ;;
        *) echo "Error: unknown tier '$t' (want: default, tight, offline, testing)" >&2; exit 1 ;;
    esac
done

# The template says where each of its regions begins and ends, and every one of
# those sentinels has to be there exactly once before anything is spliced. A
# missing //#RUNWEB_START is not a build that fails: `sed -n '1,/x/p'` prints the
# whole file when it never matches, the second range then prints nothing, and
# what comes out is the app appended past the end of the document -- an artifact
# no engine can run, from an assembler that said nothing.
for nt_mark in RUNWEB_START RUNWEB_END TIER_START TIER_END; do
    nt_count="$(grep -c "//#$nt_mark" "$TEMPLATE" | head -1)"
    if [ "$nt_count" != "1" ]; then
        echo "Error: $TEMPLATE has $nt_count //#$nt_mark markers, wanted exactly 1" >&2
        exit 1
    fi
done

# Written beside the output and moved into place only once the stamp has been
# read back, so a build that fails leaves the previous artifact alone rather
# than a half-written one with the same name.
TMP="$OUTPUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT

# The substitution is bounded by the tier sentinels. Without the range it
# rewrote every line in the stream shaped like the stamp, and the app's own
# source is in that stream: an app carrying `tiers: "offline,tight",` came out
# of here saying `tiers: "default,tight",`. The app's code is the app's, and
# this program has no business editing it. Measured: a range address reads the
# same on GNU sed and on the BSD sed macOS ships.
{
    sed -n '1,/\/\/#RUNWEB_START/p' "$TEMPLATE"
    cat "$APP_JS"
    sed -n '/\/\/#RUNWEB_END/,$p' "$TEMPLATE"
} | sed '/\/\/#TIER_START/,/\/\/#TIER_END/s|^\( *\)tiers: "[a-z,]*",|\1tiers: "'"$TIER"'",|' > "$TMP"

# The stamp is what every tier decision in the output reads, so a build that
# quietly failed to apply it would produce a file claiming a confinement it does
# not have. Check rather than assume -- and check the stamp, which is the line
# between the sentinels, rather than the first line in the file that looks like
# one. `head -1` is what made the two openings above silent: it read the app's
# code and was satisfied by it.
STAMPS="$(sed -n '/\/\/#TIER_START/,/\/\/#TIER_END/p' "$TMP" | grep -c '^ *tiers: "[a-z,]*",' | head -1)"
STAMPED="$(sed -n '/\/\/#TIER_START/,/\/\/#TIER_END/s/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$TMP" | head -1)"
if [ "$STAMPS" != "1" ] || [ "$STAMPED" != "$TIER" ]; then
    echo "Error: tier stamp did not apply (wanted '$TIER', found '${STAMPED:-nothing}' on $STAMPS line(s) between the sentinels)" >&2
    exit 1
fi

# And the app may not carry a line that is structure here. The document's
# opening tag is already refused by test/parse.sh for the same reason: a splice
# marker in the app moves where a later build -- or a reader -- thinks each
# region ends.
for nt_mark in RUNWEB_START RUNWEB_END TIER_START TIER_END; do
    nt_count="$(grep -c "//#$nt_mark" "$TMP" | head -1)"
    if [ "$nt_count" != "1" ]; then
        echo "Error: $APP_JS carries a //#$nt_mark line; that name is this file's structure" >&2
        exit 1
    fi
done

mv -f "$TMP" "$OUTPUT"
trap - EXIT
