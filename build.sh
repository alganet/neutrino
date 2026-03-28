#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# build.sh - Neutrino polyglot assembler
# Usage: ./build.sh <app.js> <output.cmd>
#
# Takes a JS file and embeds it into the runWeb() slot of webview.cmd,
# producing a new polyglot .cmd file.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <app.js> <output.cmd>" >&2
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

{
    sed -n '1,/\/\/#RUNWEB_START/p' "$TEMPLATE"
    cat "$APP_JS"
    sed -n '/\/\/#RUNWEB_END/,$p' "$TEMPLATE"
} > "$OUTPUT"
