#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# build.sh - Neutrino polyglot assembler
# Usage: ./build.sh [--tier=<list>] [--title=<str>] [--size=<WxH>]
#                   [--background=<#rrggbb|auto>] [--decorations=<auto|none>]
#                   [--style=<file>] [--body=<file>]
#                   <app.js> <output.cmd>
#
# Takes a JS file and embeds it into the runWeb() slot of webview.cmd,
# producing a new polyglot .cmd file.
#
# The early shell -- --title, --size, --background, --decorations, --style and --body.
#
# What an app looks like before a line of its JavaScript has run. The style and
# the body are markup on the template's document line, so they are in the first
# paint; the title and the size are stamped into the config object, because
# createWindow runs on every lane before there is a document to read them from.
# Each flag replaces its own part and the ones left out keep the template's.
#
# The style and the body must survive being one line inside the template, and
# that is a real constraint rather than a stylistic one. That line sits inside
# the JavaScript block comment the whole shell region lives in, and it is the
# line both halves of the file are cut from. So the CSS and the HTML are folded
# to a single line here, CSS comments are removed, and four sequences are
# refused outright rather than escaped -- see nt_refuse below, which says what
# each one would do.
#
# An author who wants more than one line of either has the same choice they
# already have for JavaScript: keep the early shell small and build the real
# page from script once the engine is up, or write markup that fits. Neither is
# the wrong answer, and the second one loads with nothing to wait for.
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
# Empty means "not asked for", which is not the same as "asked for empty" --
# an author can want a shell with no style at all, and --style /dev/null says
# so. The three flags below carry the file paths, and these carry the answer.
NT_TITLE=""; NT_TITLE_SET=""
NT_SIZE=""; NT_WIDTH=""; NT_HEIGHT=""; NT_SIZE_SET=""
NT_BG=""; NT_BG_SET=""
NT_DECOR=""; NT_DECOR_SET=""
NT_STYLE_FILE=""; NT_STYLE_SET=""
NT_BODY_FILE=""; NT_BODY_SET=""

nt_usage() {
    echo "Usage: $0 [--tier=<list>] [--title=<str>] [--size=<WxH>]" >&2
    echo "          [--background=<#rrggbb|auto>] [--decorations=<auto|none>]" >&2
    echo "          [--style=<file>] [--body=<file>]" >&2
    echo "          <app.js> <output.cmd>" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tier=*)  TIER="${1#--tier=}"; shift ;;
        --tier)    TIER="${2:-}"; shift 2 ;;
        --title=*) NT_TITLE="${1#--title=}"; NT_TITLE_SET=1; shift ;;
        --title)   NT_TITLE="${2:-}"; NT_TITLE_SET=1; shift 2 ;;
        --size=*)  NT_SIZE="${1#--size=}"; NT_SIZE_SET=1; shift ;;
        --size)    NT_SIZE="${2:-}"; NT_SIZE_SET=1; shift 2 ;;
        --background=*) NT_BG="${1#--background=}"; NT_BG_SET=1; shift ;;
        --background)   NT_BG="${2:-}"; NT_BG_SET=1; shift 2 ;;
        --decorations=*) NT_DECOR="${1#--decorations=}"; NT_DECOR_SET=1; shift ;;
        --decorations)   NT_DECOR="${2:-}"; NT_DECOR_SET=1; shift 2 ;;
        --style=*) NT_STYLE_FILE="${1#--style=}"; NT_STYLE_SET=1; shift ;;
        --style)   NT_STYLE_FILE="${2:-}"; NT_STYLE_SET=1; shift 2 ;;
        --body=*)  NT_BODY_FILE="${1#--body=}"; NT_BODY_SET=1; shift ;;
        --body)    NT_BODY_FILE="${2:-}"; NT_BODY_SET=1; shift 2 ;;
        --)        shift; break ;;
        -*)        echo "Error: unknown option $1" >&2; nt_usage; exit 1 ;;
        *)         break ;;
    esac
done

if [ $# -lt 2 ]; then
    nt_usage
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

# The early shell's values, and the shapes this refuses.
#
# Everything here runs before a byte is spliced, because a document line that
# breaks the polyglot is not a defect anyone would find by reading the output:
# three of the four sequences below produce a file that still looks like a
# neutrino app and fails on an engine, or on all four at once.

# One line, from however many the author wrote. Whitespace is not significant in
# either CSS or HTML outside a few elements -- `<pre>` is the one that will
# notice -- so folding is safe where escaping would not be, and it is the
# constraint being enforced rather than a convenience.
nt_fold() {
    tr '\n\r\t' '   ' < "$1" | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# CSS comments are removed rather than refused, because `/* */` is ordinary in a
# stylesheet and an author has no reason to expect this file's comment rules to
# reach into theirs. What survives the strip is still checked: a `*/` left over
# from an unbalanced comment is exactly the hazard, and repairing it silently
# would be guessing at what the author meant.
nt_decomment() {
    awk '{
        out = ""
        s = $0
        while ((i = index(s, "/*")) > 0) {
            out = out substr(s, 1, i - 1) " "
            s = substr(s, i + 2)
            j = index(s, "*/")
            if (j == 0) { s = ""; break }
            s = substr(s, j + 2)
        }
        print out s
    }'
}

# What a sequence would do, said in the refusal, because the consequence is the
# only part of this that is not obvious from the character.
nt_refuse() {
    nt_what="$1"
    nt_text="$2"
    nt_bad() {
        echo "Error: the $nt_what contains \`$1\`, which $2" >&2
        exit 1
    }
    case "$nt_text" in
        *'*/'*) nt_bad '*/' \
            'ends the block comment this file opens on line 1 -- every engine but jsc reads the whole shell region as comment, and a close here spills 1375 lines of shell into four JavaScript parsers at once' ;;
    esac
    if printf '%s' "$nt_text" | LC_ALL=C grep -qi '</*script'; then
        nt_bad '<script' \
            'moves where both halves of this file are cut: the document runs from the doctype to the first script tag after it, and the page script from that same tag'
    fi
    if printf '%s' "$nt_text" | LC_ALL=C grep -qi '<!doctype'; then
        nt_bad '<!doctype' \
            'is a second doctype, which the launcher refuses outright rather than guess which one the document starts at'
    fi
    if printf '%s' "$nt_text" | LC_ALL=C grep -qi 'content-security-policy'; then
        nt_bad 'Content-Security-Policy' \
            'is a second copy of the header the offline tier swaps -- the swap takes the first, so this one would sit in the document unswapped and enforcing nothing'
    fi
    if printf '%s' "$nt_text" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        nt_bad 'a control character' 'cannot be written on a single line of the template'
    fi
}

nt_readpart() {
    nt_which="$1"
    nt_path="$2"
    if [ ! -f "$nt_path" ] && [ ! -r "$nt_path" ]; then
        echo "Error: --$nt_which: $nt_path not found" >&2
        exit 1
    fi
    if [ "$nt_which" = "style" ]; then
        nt_fold "$nt_path" | nt_decomment | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
    else
        nt_fold "$nt_path"
    fi
}

if [ -n "$NT_TITLE_SET" ]; then
    # The title is a JavaScript string in live code rather than markup, so its
    # rules are the string's. Refused rather than escaped for the same reason
    # parseMessage drops a malformed record instead of repairing it: a window
    # title is not worth a second quoting scheme that has to be right.
    case "$NT_TITLE" in
        *'"'*) echo 'Error: --title cannot contain a double quote; it is a JavaScript string literal' >&2; exit 1 ;;
        *'\'*) echo 'Error: --title cannot contain a backslash; it is a JavaScript string literal' >&2; exit 1 ;;
    esac
    if printf '%s' "$NT_TITLE" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        echo 'Error: --title cannot contain a control character' >&2
        exit 1
    fi
    if [ -z "$NT_TITLE" ]; then
        echo 'Error: --title cannot be empty; a window with no title is not a shell anyone asked for' >&2
        exit 1
    fi
fi

if [ -n "$NT_SIZE_SET" ]; then
    NT_WIDTH="${NT_SIZE%%x*}"
    NT_HEIGHT="${NT_SIZE#*x}"
    case "$NT_SIZE" in
        *x*) ;;
        *) echo "Error: --size wants WxH, got '$NT_SIZE'" >&2; exit 1 ;;
    esac
    case "$NT_WIDTH$NT_HEIGHT" in
        ''|*[!0-9]*) echo "Error: --size wants WxH in whole pixels, got '$NT_SIZE'" >&2; exit 1 ;;
    esac
    # The same floor the message parser holds resize to. A window sized zero is
    # a launch that comes up with nothing on screen and no error anywhere.
    if [ "$NT_WIDTH" -lt 1 ] || [ "$NT_HEIGHT" -lt 1 ]; then
        echo "Error: --size wants both dimensions above zero, got '$NT_SIZE'" >&2
        exit 1
    fi
fi

if [ -n "$NT_BG_SET" ]; then
    # `#rgb` or `#rrggbb`, matching what the launcher's parseColor reads. A
    # colour it cannot read is refused here rather than at launch, where every
    # lane would independently decline to paint and the window would come up in
    # the theme colour -- which is the bug this flag exists to close, arrived at
    # by a different route and with nothing said.
    #
    # `auto` is the one value that is not a colour, and it is what the template
    # already carries -- so passing it is the same build as leaving the flag
    # out. It is accepted anyway, because a script that means "follow the
    # desktop" should be able to say so rather than say nothing and be right by
    # omission. Everything else is still refused: `system`, `theme` and `none`
    # are all things somebody will try, and a build that took one and painted
    # white would be this flag failing quietly again.
    case "$NT_BG" in
        auto) ;;
        '#'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        '#'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        *) echo "Error: --background wants #rgb, #rrggbb or auto, got '$NT_BG'" >&2; exit 1 ;;
    esac
fi

# Two words and nothing else, refused here rather than at launch for the reason
# the background above is: every lane compares against `none` and keeps its
# frame for anything else, so a misspelling would ship a build that silently
# ignored the flag it was given. `false`, `off`, `no` and `0` are in the refused
# list by name because they are what somebody reaches for when they are thinking
# of a boolean, and `frameless` and `chromeless` because they are what somebody
# reaches for when they are thinking of another launcher.
if [ -n "$NT_DECOR_SET" ]; then
    case "$NT_DECOR" in
        auto|none) ;;
        *) echo "Error: --decorations wants auto or none, got '$NT_DECOR'" >&2; exit 1 ;;
    esac
fi

if [ -n "$NT_STYLE_SET" ]; then
    NT_STYLE="$(nt_readpart style "$NT_STYLE_FILE")"
    nt_refuse "style from $NT_STYLE_FILE" "$NT_STYLE"
fi

if [ -n "$NT_BODY_SET" ]; then
    NT_BODY="$(nt_readpart body "$NT_BODY_FILE")"
    nt_refuse "body from $NT_BODY_FILE" "$NT_BODY"
fi

# The template says where each of its regions begins and ends, and every one of
# those sentinels has to be there exactly once before anything is spliced. A
# missing //#RUNWEB_START is not a build that fails: `sed -n '1,/x/p'` prints the
# whole file when it never matches, the second range then prints nothing, and
# what comes out is the app appended past the end of the document -- an artifact
# no engine can run, from an assembler that said nothing.
for nt_mark in RUNWEB_START RUNWEB_END TIER_START TIER_END CONFIG_START CONFIG_END; do
    nt_count="$(grep -c "//#$nt_mark" "$TEMPLATE" | head -1)"
    if [ "$nt_count" != "1" ]; then
        echo "Error: $TEMPLATE has $nt_count //#$nt_mark markers, wanted exactly 1" >&2
        exit 1
    fi
done

# The template's document line, taken apart so the flags that were given can
# replace their own part and the ones that were not can keep the template's.
#
# The prefix -- doctype, charset and the content policy -- is carried over
# verbatim rather than written out here. It has to be: the offline tier is one
# string replace against `defaultContentPolicy` in webview.cmd, so a policy
# spelled a second time in this file is one that can drift, and the drift shows
# up as a build that refuses at launch rather than at assembly.
nt_docparts() {
    awk '
        !done && /^<!doctype html><html>/ {
            done = 1
            i = index($0, "<style>")
            j = index($0, "</style></head><body>")
            if (i == 0 || j == 0) { exit 3 }
            print substr($0, 1, i - 1)
            print substr($0, i + 7, j - (i + 7))
            print substr($0, j + 21)
        }
        END { if (!done) exit 3 }
    ' "$1"
}

if ! nt_doc="$(nt_docparts "$TEMPLATE")"; then
    echo "Error: $TEMPLATE has no document line this can take apart" >&2
    echo "       wanted one line: <!doctype html><html>...<style>...</style></head><body>..." >&2
    exit 1
fi
# Three lines out, and either of the last two may legitimately be empty, so they
# are read positionally rather than by splitting on anything.
NT_DOC_PREFIX="$(printf '%s\n' "$nt_doc" | sed -n '1p')"
[ -n "$NT_STYLE_SET" ] || NT_STYLE="$(printf '%s\n' "$nt_doc" | sed -n '2p')"
[ -n "$NT_BODY_SET" ] || NT_BODY="$(printf '%s\n' "$nt_doc" | sed -n '3p')"

NT_DOCLINE="$NT_DOC_PREFIX<style>$NT_STYLE</style></head><body>$NT_BODY"

# It travels to awk through the environment, which is what keeps this free of a
# second escaping scheme -- ENVIRON hands the value over with no processing at
# all, where -v would read backslashes in it. That is also the bound: the whole
# document line has to fit in one environment variable on every platform this
# assembler runs on, and 64 KiB is comfortably under the smallest of them.
if [ "${#NT_DOCLINE}" -gt 65536 ]; then
    echo "Error: the document line came to ${#NT_DOCLINE} bytes; the limit is 65536" >&2
    echo "       an early shell this size is an app, and an app belongs in the JavaScript" >&2
    exit 1
fi
export NT_DOCLINE
export NT_TITLE NT_WIDTH NT_HEIGHT NT_BG NT_DECOR

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
} | sed '/\/\/#TIER_START/,/\/\/#TIER_END/s|^\( *\)tiers: "[a-z,]*",|\1tiers: "'"$TIER"'",|' \
  | awk '
        # The document line is replaced whole rather than edited in place. It is
        # matched on its opening, which parse.sh already requires to be the first
        # doctype in the file, so there is nothing else in the stream it can hit
        # -- and `!done` means an app that somehow carries a second one keeps it
        # rather than having this write over code that belongs to the app.
        !done && /^<!doctype html><html>/ { print ENVIRON["NT_DOCLINE"]; done = 1; next }

        # Bounded by the sentinels for the reason the tier stamp above is: the
        # app source is in this stream, and a line of it shaped like a config
        # entry is not the config entry.
        /\/\/#CONFIG_START/ { inconf = 1; print; next }
        /\/\/#CONFIG_END/   { inconf = 0; print; next }

        # Rebuilt from the indent rather than substituted into, because sub()
        # reads an `&` in the replacement as the whole match, and the title is
        # text this program has no business editing.
        #
        # The trailing comma is copied off the line being replaced rather than
        # written by each rule. Writing it cost a launch: `height` was the last
        # key in the object, its rule printed no comma, and adding `background`
        # after it produced `height: 300` with nothing between it and the next
        # key -- valid to nothing, and the artifact came out of the assembler
        # exit 0. Following the template means the punctuation is right for
        # whatever order the keys are in.
        function stamp(key, value,   ind, tail) {
            match($0, /^ */)
            ind = substr($0, 1, RLENGTH)
            tail = ($0 ~ /,[ \t]*$/) ? "," : ""
            print ind key ": " value tail
        }
        inconf && ENVIRON["NT_TITLE"]  != "" && /^ *title: /      { stamp("title", "\"" ENVIRON["NT_TITLE"] "\""); next }
        inconf && ENVIRON["NT_WIDTH"]  != "" && /^ *width: /      { stamp("width",  ENVIRON["NT_WIDTH"]);  next }
        inconf && ENVIRON["NT_HEIGHT"] != "" && /^ *height: /     { stamp("height", ENVIRON["NT_HEIGHT"]); next }
        inconf && ENVIRON["NT_BG"]     != "" && /^ *background: / { stamp("background", "\"" ENVIRON["NT_BG"] "\""); next }
        inconf && ENVIRON["NT_DECOR"]  != "" && /^ *decorations: / { stamp("decorations", "\"" ENVIRON["NT_DECOR"] "\""); next }

        { print }
    ' > "$TMP"

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

# The same read-back for the early shell, and it earns its place the same way
# the tier check does: every one of these splices is a text substitution with no
# failure path of its own. A pattern that stops matching -- because the template
# was reindented, or an awk somewhere spells `match` differently -- produces an
# artifact that is valid, runs, and quietly has the old title, the old size or
# the old markup in it. The build said nothing either way.
nt_readback() {
    if ! nt_out="$(nt_docparts "$TMP")"; then
        echo "Error: the assembled file has no document line; the splice did not apply" >&2
        exit 1
    fi
    nt_got_style="$(printf '%s\n' "$nt_out" | sed -n '2p')"
    nt_got_body="$(printf '%s\n' "$nt_out" | sed -n '3p')"
    if [ "$nt_got_style" != "$NT_STYLE" ]; then
        echo "Error: the style did not apply" >&2
        echo "       wanted: $NT_STYLE" >&2
        echo "       found:  $nt_got_style" >&2
        exit 1
    fi
    if [ "$nt_got_body" != "$NT_BODY" ]; then
        echo "Error: the body did not apply" >&2
        echo "       wanted: $NT_BODY" >&2
        echo "       found:  $nt_got_body" >&2
        exit 1
    fi
}
nt_readback

# Read between the sentinels rather than by taking the first line in the file
# that looks like a config entry, for the reason the tier check spells out: the
# app source is in this file too.
nt_conf() {
    sed -n '/\/\/#CONFIG_START/,/\/\/#CONFIG_END/p' "$TMP" |
        sed -n "s/^ *$1: \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" | head -1
}
for nt_pair in "title:$NT_TITLE" "width:$NT_WIDTH" "height:$NT_HEIGHT" "background:$NT_BG" \
                "decorations:$NT_DECOR"; do
    nt_key="${nt_pair%%:*}"
    nt_want="${nt_pair#*:}"
    [ -n "$nt_want" ] || continue
    nt_have="$(nt_conf "$nt_key")"
    if [ "$nt_have" != "$nt_want" ]; then
        echo "Error: the $nt_key did not apply (wanted '$nt_want', found '${nt_have:-nothing}')" >&2
        exit 1
    fi
done

# And the app may not carry a line that is structure here. The document's
# opening tag is already refused by test/parse.sh for the same reason: a splice
# marker in the app moves where a later build -- or a reader -- thinks each
# region ends.
for nt_mark in RUNWEB_START RUNWEB_END TIER_START TIER_END CONFIG_START CONFIG_END; do
    nt_count="$(grep -c "//#$nt_mark" "$TMP" | head -1)"
    if [ "$nt_count" != "1" ]; then
        echo "Error: $APP_JS carries a //#$nt_mark line; that name is this file's structure" >&2
        exit 1
    fi
done

mv -f "$TMP" "$OUTPUT"
trap - EXIT
