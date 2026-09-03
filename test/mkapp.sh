#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# mkapp.sh - build a test app out of one .js file.
# Usage: mkapp.sh [--tier=<list>] [--title=<str>] [--size=<WxH>]
#                 [--background=<#rrggbb|auto>] [--decorations=<auto|none>]
#                 [--comments] [--overlay <dir>]...
#                 <app.js> <output.cmd>
#
# neutrino/assemble.sh lays overlay directories over neutrino/ and an app is a
# directory: app.js, config.json, style.css, body.html. Every app in this suite
# is one .js file and wants the launcher's defaults for the rest, and committing
# ten directories with one file each to say so would be ten directories saying
# nothing.
#
# --tier is overlay selection and nothing else now. There is no tier stamp in an
# artifact and nothing at run time reads one: neutrino/tier/<name> replaces the
# few parts that tier varies, so a testing build has the scaffolding in it and a
# release build does not have it at all.
#
# So this builds the overlay instead. It writes app.js and config.json into a
# temporary, and the flags above are the keys of config.json spelled as command
# line arguments -- which is what build.sh took before the two builders became
# one. That is deliberate: it keeps the suite's call sites readable, and it puts
# the sugar in the test tree, where a shortcut costs nothing if it is wrong,
# rather than in the assembler, where every app would inherit it.
#
# The defaults come out of neutrino/config.json rather than being written here,
# so this cannot come to disagree with the file it is standing in for.
#
# --no-verify, for the reason build.sh passed it: `node --check` alone is a
# third of a second on the Windows runner and this suite builds fifty artifacts.
# The artifacts that matter go through test/parse.sh, which reads the JavaScript
# region of the built file and is where a syntax error in an app is caught.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$ROOT/neutrino"
DEFAULTS="$SOURCE/config.json"

NT_TIERS=""; NT_TITLE=""; NT_WIDTH=""; NT_HEIGHT=""; NT_BG=""; NT_DECOR=""
NT_COMMENTS=""
# Newline separated and not an array, for the reason assemble.sh spells out:
# `set -u` with an empty array is an unbound variable on the bash macOS ships.
NT_EXTRA=""
nt_addoverlay() {
    if [ -z "$NT_EXTRA" ]; then NT_EXTRA="$1"; else NT_EXTRA="$NT_EXTRA
$1"; fi
}

nt_usage() {
    echo "Usage: $0 [--tier=<list>] [--title=<str>] [--size=<WxH>]" >&2
    echo "          [--background=<#rrggbb|auto>] [--decorations=<auto|none>]" >&2
    echo "          [--comments] [--overlay <dir>]... <app.js> <output.cmd>" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tier=*)  NT_TIERS="${1#--tier=}"; shift ;;
        --tier)    NT_TIERS="${2:-}"; shift 2 ;;
        --title=*) NT_TITLE="${1#--title=}"; shift ;;
        --title)   NT_TITLE="${2:-}"; shift 2 ;;
        --size=*)  NT_SIZE="${1#--size=}"; shift ;;
        --size)    NT_SIZE="${2:-}"; shift 2 ;;
        --background=*) NT_BG="${1#--background=}"; shift ;;
        --background)   NT_BG="${2:-}"; shift 2 ;;
        --decorations=*) NT_DECOR="${1#--decorations=}"; shift ;;
        --decorations)   NT_DECOR="${2:-}"; shift 2 ;;
        --overlay=*) nt_addoverlay "${1#--overlay=}"; shift ;;
        --overlay)   nt_addoverlay "${2:-}"; shift 2 ;;
        --comments)  NT_COMMENTS=1; shift ;;
        --)          shift; break ;;
        -*)          echo "mkapp.sh: unknown option $1" >&2; nt_usage; exit 1 ;;
        *)           break ;;
    esac
done

if [ -n "${NT_SIZE:-}" ]; then
    case "$NT_SIZE" in
        *x*) NT_WIDTH="${NT_SIZE%%x*}"; NT_HEIGHT="${NT_SIZE#*x}" ;;
        *) echo "mkapp.sh: --size wants WxH, got '$NT_SIZE'" >&2; exit 1 ;;
    esac
fi

if [ $# -ne 2 ]; then
    nt_usage
    exit 1
fi

APP_JS="$1"
OUTPUT="$2"

if [ ! -f "$APP_JS" ]; then
    echo "mkapp.sh: $APP_JS not found" >&2
    exit 1
fi

# One key out of the defaults, quotes and trailing comma taken off. The values
# go back through this program unquoted and are re-quoted below, so a default
# that is a number stays a number.
nt_default() {
    # Two expressions and not one: a greedy capture that also allowed the comma
    # read `900,` out of `"width": 900,` and wrote it back as `"width": 900,,`.
    # The first reads a quoted value, whose end is its closing quote and which
    # may hold a comma -- the tier list does. The second reads a bare number.
    sed -n -e "s/^ *\"$1\": \"\(.*\)\",\{0,1\}\$/\1/p" \
           -e "s/^ *\"$1\": \([^\",]*\),\{0,1\}\$/\1/p" "$DEFAULTS" | head -1
}

[ -n "$NT_TITLE" ] || NT_TITLE="$(nt_default title)"
[ -n "$NT_WIDTH" ] || NT_WIDTH="$(nt_default width)"
[ -n "$NT_HEIGHT" ] || NT_HEIGHT="$(nt_default height)"
[ -n "$NT_BG" ] || NT_BG="$(nt_default background)"
[ -n "$NT_DECOR" ] || NT_DECOR="$(nt_default decorations)"

# A tier is an overlay under neutrino/tier, so --tier=testing,offline is two
# more directories in the search path and nothing else. `default` names no
# overlay: it is what a build with none of them is, and it is accepted so that
# the ninety call sites that spell it do not have to change.
NT_TIER_OVERLAYS=""
for nt_t in $(printf '%s' "$NT_TIERS" | tr ',' ' '); do
    case "$nt_t" in
        default) continue ;;
        testing) ;;
        # offline and tight were the other two and are gone. Named in the
        # refusal rather than folded into "unknown", because roughly a hundred
        # call sites spelled a tier and a caller who still spells one of these
        # should be told it was removed, not told it was a typo.
        offline|tight)
            echo "mkapp.sh: the '$nt_t' tier was removed; there is one confinement now and every build has it" >&2
            exit 1 ;;
        *) echo "mkapp.sh: unknown tier '$nt_t' (want: default, testing)" >&2; exit 1 ;;
    esac
    if [ ! -d "$SOURCE/tier/$nt_t" ]; then
        echo "mkapp.sh: no overlay at $SOURCE/tier/$nt_t" >&2
        exit 1
    fi
    NT_TIER_OVERLAYS="$NT_TIER_OVERLAYS$SOURCE/tier/$nt_t
"
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/config.json" <<EOF
{
    "title": "$NT_TITLE",
    "width": $NT_WIDTH,
    "height": $NT_HEIGHT,
    "background": "$NT_BG",
    "decorations": "$NT_DECOR"
}
EOF

cp "$APP_JS" "$WORK/app.js"

# The generated overlay goes last so it wins: a --overlay named on the command
# line supplies parts this one does not write, and the app is this one's.
set -- --no-verify
# Tiers first, so a --overlay named on the command line can still replace a part
# one of them supplies.
while IFS= read -r nt_d; do
    [ -n "$nt_d" ] || continue
    set -- "$@" --overlay "$nt_d"
done <<EOF
$NT_TIER_OVERLAYS
EOF
while IFS= read -r nt_d; do
    [ -n "$nt_d" ] || continue
    set -- "$@" --overlay "$nt_d"
done <<EOF
$NT_EXTRA
EOF
if [ -n "$NT_COMMENTS" ]; then
    set -- "$@" --comments
fi

bash "$SOURCE/assemble.sh" "$@" --overlay "$WORK" "$OUTPUT"
