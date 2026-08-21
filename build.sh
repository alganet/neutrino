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
#   offline   deny the page network access.
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

{
    sed -n '1,/\/\/#RUNWEB_START/p' "$TEMPLATE"
    cat "$APP_JS"
    sed -n '/\/\/#RUNWEB_END/,$p' "$TEMPLATE"
} | sed "s|^\( *\)tiers: \"[a-z,]*\",|\1tiers: \"$TIER\",|" > "$OUTPUT"

# The stamp is what every tier decision in the output reads, so a build that
# quietly failed to apply it would produce a file claiming a confinement it does
# not have. Check rather than assume.
STAMPED="$(sed -n 's/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$OUTPUT" | head -1)"
if [ "$STAMPED" != "$TIER" ]; then
    echo "Error: tier stamp did not apply (wanted '$TIER', found '${STAMPED:-nothing}')" >&2
    rm -f "$OUTPUT"
    exit 1
fi
