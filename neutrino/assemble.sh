#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# assemble.sh - builds a neutrino app out of neutrino/ and the overlays laid
#               over it.
# Usage: assemble.sh [--comments] [--no-verify] [--overlay <dir>]... <output.cmd>
#        assemble.sh --check [--overlay <dir>]...
#
# skeleton.cmd carries the lines that are more than one language at once and
# nothing else. Everything under it is ordinary source in one language, pulled
# in by an `@@include <path>` line. See POLYGLOT.md.
#
# There is one directive and there are no substitutions. This program used to be
# half of a pair: it put a template together, and build.sh then spliced an app
# into it with four text replacements -- the app into a slot, the tier list into
# a stamp, five config keys into an object, and a rebuilt document line. Every
# one of those was a sed or awk pattern with no failure path of its own, so each
# one needed a read-back afterwards to say whether it had applied, and the
# read-backs were most of that program. A replacement that stops matching
# produces an artifact that is valid, runs, and quietly has the old title in it.
#
# An include cannot half-apply. So the things build.sh spliced are parts now,
# and an app supplies its own by laying a directory over this one:
#
#   app.js         the body of runWeb, which is the app
#   config.json    the window, laid in verbatim
#   style.css      the early shell's stylesheet
#   body.html      the early shell's markup
#
# `--overlay <dir>` puts a directory ahead of this one in the search path, and
# more than one may be given -- later wins. Any part is overridable and not just
# those four: an overlay carrying `js/policy.js` replaces the launcher's. That
# is the author's business, because the author is the one shipping the artifact.
#
# `build/testing` is the only overlay shipped under this directory, and it is
# scaffolding rather than a security setting: the trace channel, the macOS status
# file, the two windows environment overrides and Qt's --no-sandbox. A release
# build does not carry that behind a flag -- it does not carry it.
#
# It lived at `tier/testing` beside `tier/offline` and `tier/tight`. Those two
# are gone: there is one confinement now, every build has it, and nothing here
# uses the word tier any more.
#
# The default output has no comments in it. That is the whole point of the
# split: a comment can be removed by a program that knows which language it is
# reading, and in a single file that knows five at once it cannot. --comments
# keeps them, which is what to reach for when a lane is failing and the artifact
# has to be read.
#
# Stripping is whole-line only, except in CSS. A trailing comment stays, and so
# does anything sharing its line with code, because the cheap rule is the one
# that cannot be wrong about a `//` inside a string. What it costs is a few
# hundred bytes; what it buys is that this program never has to parse the
# language it is cutting.
#
# CSS is the exception, and it is not a stylistic one. A stylesheet's comments
# are removed wherever they sit on the line, and they are removed even under
# --comments, because `*/` ends the block comment the entire shell and document
# region of this polyglot lives inside. A stylesheet is the one place an author
# writes that pair without thinking about it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
KEEP=""
VERIFY=1
CHECK_ONLY=""
OUTPUT=""
# Newline separated and not an array, in the order the caller named them. An
# array is the natural spelling and it is not available: `set -u` with an empty
# one is an unbound variable on bash before 4.4, which is the 3.2.57 macOS
# ships. No path in this tree carries a newline, and one that did would be
# refused by the include check below before it could be read.
NT_OVERLAYS=""
nt_addoverlay() {
    if [ -z "$NT_OVERLAYS" ]; then
        NT_OVERLAYS="$1"
    else
        NT_OVERLAYS="$NT_OVERLAYS
$1"
    fi
}

nt_usage() {
    echo "Usage: $0 [--comments] [--no-verify] [--overlay <dir>]... <output.cmd>" >&2
    echo "       $0 --check [--overlay <dir>]..." >&2
    echo "       the output may be - for stdout" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --comments)  KEEP=1; shift ;;
        --no-verify) VERIFY=0; shift ;;
        --check)     CHECK_ONLY=1; shift ;;
        --overlay=*) nt_addoverlay "${1#--overlay=}"; shift ;;
        --overlay)   nt_addoverlay "${2:-}"; shift 2 ;;
        --)          shift; break ;;
        -)           break ;;
        -*)          echo "assemble.sh: unknown option $1" >&2; nt_usage; exit 1 ;;
        *)           break ;;
    esac
done

if [ -n "$CHECK_ONLY" ]; then
    if [ $# -gt 0 ]; then
        echo "assemble.sh: --check writes nothing and takes no output" >&2
        exit 1
    fi
else
    if [ $# -lt 1 ]; then
        echo "assemble.sh: no output named" >&2
        nt_usage
        exit 1
    fi
    if [ $# -gt 1 ]; then
        echo "assemble.sh: one output, got $#: $*" >&2
        nt_usage
        exit 1
    fi
    OUTPUT="$1"
fi

# The search path, highest priority first, with this directory last. Resolved
# rather than compared as text: a relative path, a symlinked checkout and
# `neutrino/../neutrino` are all the same directory and only one of them looks
# like it.
NT_ROOTS=""
while IFS= read -r nt_dir; do
    [ -n "$nt_dir" ] || continue
    if [ ! -d "$nt_dir" ]; then
        echo "assemble.sh: --overlay: $nt_dir is not a directory" >&2
        exit 1
    fi
    # In front of what is there already, so the last overlay named is the first
    # one searched.
    NT_ROOTS="$(cd "$nt_dir" && pwd)${NT_ROOTS:+
$NT_ROOTS}"
done <<EOF
$NT_OVERLAYS
EOF
NT_ROOTS="${NT_ROOTS:+$NT_ROOTS
}$ROOT"

# Every root, one per line, for a caller that wants to walk them. A here
# document and not a pipe: a `while read` on the right of a pipe runs in a
# subshell, and half the walks below want to exit out of the middle.
nt_roots() {
    printf '%s\n' "$NT_ROOTS"
}

# One part, by name, from the first root that has it. The same walk awk does
# below, spelled here for the shell's own reads.
nt_resolve() {
    nt_found=""
    while IFS= read -r nt_r; do
        [ -n "$nt_r" ] || continue
        if [ -z "$nt_found" ] && [ -f "$nt_r/$1" ]; then
            nt_found="$nt_r/$1"
        fi
    done <<EOF
$NT_ROOTS
EOF
    [ -n "$nt_found" ] || return 1
    printf '%s\n' "$nt_found"
}

# =====================================================================
# Where the artifact may be written
# =====================================================================
# Checked before anything is opened, because by then it is already too late.
#
# The template used to be a file beside this one, and naming it as the output
# truncated it: `> "$OUTPUT"` was set up before the pipeline read it, so the
# build spliced nothing and exited 0. Measured on all four lanes, `webview.cmd`
# 116 bytes. The assembly goes to a temporary now and that exact name cannot be
# given any more -- but the source it is assembled from is a directory of files
# with the same opening in it, and it is a worse one: a build that truncates
# neutrino/js/message.js leaves nothing to reassemble from and no earlier
# artifact to compare against.
#
# So every root is refused as an output. That covers the app's own parts as well
# as the launcher's, because an app is a root: `--overlay pages/demo` makes
# `pages/demo/app.js` unnameable as an output, which is the shape that used to
# be spelled "the output is one of the inputs". Naming the app as the output
# cost a round -- the redirection belonged to the `sed` on the right of the
# pipeline and the `cat` on the left ran beside it, so the assembler read back
# what it had already written and a 116-byte app came out 213225 bytes.
if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "-" ]; then
    # A directory is not an output either, and it used to be accepted. `mv -f`
    # moves a file *into* a directory of that name, so the artifact came out as
    # `<dir>/<name>.tmp.<pid>` -- not at the path that was asked for, under a
    # name that reads as leftover rubbish, from a build that exited 0. Measured.
    if [ -d "$OUTPUT" ]; then
        echo "assemble.sh: $OUTPUT is a directory; the output is the artifact's own path" >&2
        exit 1
    fi
    NT_OUTDIR="$(cd "$(dirname "$OUTPUT")" 2>/dev/null && pwd)" || NT_OUTDIR=""
    if [ -z "$NT_OUTDIR" ]; then
        echo "assemble.sh: $OUTPUT is not in a directory that exists" >&2
        exit 1
    fi
    while IFS= read -r nt_r; do
        [ -n "$nt_r" ] || continue
        case "$NT_OUTDIR/" in
            "$nt_r"/*)
                echo "assemble.sh: the output is inside $nt_r; that tree is what this build reads" >&2
                exit 1 ;;
        esac
    done <<EOF
$NT_ROOTS
EOF
fi

# =====================================================================
# Every part named anywhere has to exist before a byte is written
# =====================================================================
# Because the expansion below runs inside a pipeline, and an exit taken in there
# is an exit taken in a subshell -- the assembly would carry on with a hole in
# it and come out looking assembled.
nt_missing=""
while IFS= read -r nt_ref; do
    [ -n "$nt_ref" ] || continue
    case "$nt_ref" in
        *..*|/*) echo "assemble.sh: include path leaves the source tree: $nt_ref" >&2; exit 1 ;;
    esac
    nt_resolve "$nt_ref" >/dev/null || nt_missing="$nt_missing $nt_ref"
done <<EOF
$(nt_roots | while IFS= read -r nt_r; do
      [ -n "$nt_r" ] && grep -rh '^@@include ' "$nt_r" || true
  done | sed 's/^@@include //' | tr -d '\r' | sort -u)
EOF
if [ -n "$nt_missing" ]; then
    echo "assemble.sh: no such part:$nt_missing" >&2
    exit 1
fi

# =====================================================================
# The app's config, checked but never rewritten
# =====================================================================
# JSON is a JavaScript object literal, so what ships is the author's own bytes
# and there is no serializer in here to disagree with them. The five window keys
# used to arrive as five command-line flags and be stamped into the object one
# at a time, and each of those five needed its own read-back to say whether it
# had landed; a file that is laid in whole needs none.
#
# What is left is refusing a shape the launcher could not use. Every one of
# these closed a build that produced a valid artifact which was quietly wrong:
# a colour parseColor cannot read leaves every lane declining to paint and the
# window coming up in the theme colour, and a `decorations` value that is not
# `none` is compared against `none` by five lanes and silently keeps its frame.
# `false`, `off`, `no`, `0`, `frameless` and `chromeless` are all things
# somebody reaches for, and a build that took one and kept the frame would be
# this check failing quietly.
#
# Flat, one entry per line, every key present. There is no merge in this
# program -- an overlay replaces config.json whole -- so a file naming only a
# title would silently take the rest from nowhere. Requiring all five is what
# makes "the artifact carries a file somebody wrote" true.
nt_checkconfig() {
    awk -v path="$1" '
        # awk runs END after an exit, so the flag is what stops a refusal from
        # being followed by a second one about a brace the reader never got to.
        function bad(msg) {
            print "assemble.sh: " path ": " msg > "/dev/stderr"
            failed = 1
            exit 1
        }
        BEGIN {
            split("title width height background decorations", k, " ")
            for (i in k) known[k[i]] = 1
        }
        # A line at a time, because that is the shape this file is written in
        # and a parser that accepted more would be accepting shapes the check
        # below could not read back.
        {
            line = $0
            sub(/\r$/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line == "") next
            if (line == "{") { if (opened++) bad("more than one object in it"); next }
            if (line == "}") { closed = 1; next }
            if (closed) bad("something follows the closing brace")
            if (!opened) bad("it does not open with {")

            if (line !~ /^"[a-z]+": /) bad("not one \"key\": value entry: " line)
            key = line
            sub(/^"/, "", key); sub(/".*$/, "", key)
            val = line
            sub(/^"[a-z]+": /, "", val)
            sub(/,$/, "", val)

            if (!(key in known)) bad("unknown key \"" key "\"")
            if (key in seen) bad("names \"" key "\" twice")
            seen[key] = 1

            if (key == "width" || key == "height") {
                if (val !~ /^[0-9]+$/) bad(key " wants a whole number of pixels, got " val)
                # The same floor the message parser holds resize to. A window
                # sized zero is a launch that comes up with nothing on screen
                # and no error anywhere.
                if (val + 0 < 1) bad(key " wants a number above zero, got " val)
                next
            }

            if (val !~ /^".*"$/) bad(key " wants a string, got " val)
            s = substr(val, 2, length(val) - 2)

            if (key == "title") {
                if (s == "") bad("title cannot be empty; a window with no title is not a shell anyone asked for")
                next
            }
            if (key == "background") {
                # Spelled out rather than written `{6}`, because the awk macOS
                # ships does not read a repetition interval and would have
                # refused every six-digit colour on that platform alone --
                # including the one the sample app is published with.
                if (s != "auto" &&
                    s !~ /^#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/ &&
                    s !~ /^#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/)
                    bad("background wants #rgb, #rrggbb or auto, got \"" s "\"")
                next
            }
            if (key == "decorations") {
                if (s != "auto" && s != "none") bad("decorations wants auto or none, got \"" s "\"")
                next
            }
        }
        END {
            if (failed) exit 1
            if (!opened) bad("it is empty")
            if (!closed) bad("it does not close with }")
            for (key in known) if (!(key in seen)) missing = missing " " key
            if (missing != "") bad("does not name:" missing)
        }
    ' "$1"
}

NT_CONFIG="$(nt_resolve config.json)" || {
    echo "assemble.sh: no config.json in any root" >&2
    exit 1
}
nt_checkconfig "$NT_CONFIG"

# The three-quote strings Python opens, spelled here because there is no way to
# write an apostrophe inside the awk programs below.
NT_Q3="'''"

# A carriage return, and the two places this file has to know what one is.
#
# Git for Windows checks this tree out with CRLF endings -- webview.cmd was
# 393152 bytes on that runner against 385580 here, which is one return per line
# -- and the programs that read a part do not agree about them. sed and awk
# normalise on the way through and never show one to their caller; `cat` and
# bash `read` pass them along. The monolith went through sed and awk and nothing
# else, so the artifact came out with unix endings on every platform and nobody
# had to know any of this.
#
# The split put `cat` and a `read` loop in the path and both openings came with
# it. An include line reached the loop spelled `cmd/launcher.cmd` with a return
# on the end, no case in the reader matched the extension any more, and the
# whole batch region went out through the fallback `cat` -- measured as
# `cat: .../launcher.cmd$'\r': No such file or directory` with every build step
# on the Windows lane red behind it. And the parts that are never stripped, the
# skeleton and the document, would have kept their returns in a file where
# everything else had lost them: test/parse.sh reads the here-document
# delimiter off the seam line with a `$` anchor and would have found nothing
# there, on an artifact that no shell could run either.
#
# So: the include directive is trimmed where awk reads it, and the assembly is
# normalised whole on the way out.

# One awk program for the whole assembly, and the reason it is one is a lane
# rather than a preference.
#
# It used to be a shell function per language and a `while read` loop per part:
# forty awk processes and forty subshells for one template, four templates per
# build for the region checks, and fifty builds in test/assemble.sh. That is
# sixteen thousand processes, which is a fifth of a second here and five minutes
# on a Windows runner -- measured, as a timed-out step with nothing else wrong
# in the job. Process creation is the cost on that platform and the only fix
# that matters is making fewer.
#
# So the include expansion and all five strip rules live in one recursive awk
# function. Its per-file state -- which comment it is inside, which string it is
# inside -- is declared as extra parameters, which is how awk spells a local,
# and a file that ends inside any of them says which file it was.
nt_awk='
    function fail(msg) {
        print "assemble.sh: " msg > "/dev/stderr"
        exit 1
    }

    # A part by name, from the first root that has it. -1 from getline is
    # "cannot read", and 0 is an empty file that is nonetheless there, so the
    # test is against zero and not against one.
    function resolve(ref,   i, cand, r, sink) {
        for (i = 1; i <= nroots; i++) {
            cand = root[i] "/" ref
            r = (getline sink < cand)
            close(cand)
            if (r >= 0) return cand
        }
        return ""
    }

    # The extension decides the rules. skeleton.cmd is the one part with none:
    # its lines are comments to some languages and code to others at the same
    # character, so there is no language to strip it in.
    function suffix(path,   e) {
        if (path !~ /\.[A-Za-z0-9]+$/) return ""
        e = path
        sub(/^.*\./, "", e)
        return e
    }

    function emit(path, raw, depth,
                  e, ret, line, t, u, ref, i, j, cand, out,
                  inblock, intpl, indoc, incss, nheld, spdx, held) {
        if (depth > 8) fail("include nesting is too deep at " path)
        e = raw ? "" : suffix(path)
        ret = (getline line < path)
        if (ret < 0) fail("cannot read " path)
        while (ret > 0) {
            # The states that swallow a line whatever it looks like, before
            # anything is asked about how it begins.
            if (intpl) {
                t = line
                if (gsub(/`/, "\\&", t) % 2) intpl = 0
                print line
            } else if (indoc) {
                if (triples(line) % 2) indoc = 0
                print line
            } else if (inblock) {
                held[nheld++] = line
                if (line ~ /SPDX-/) spdx = 1
                if (line ~ /\*\//) {
                    if (spdx) { for (i = 0; i < nheld; i++) print held[i] }
                    inblock = 0; nheld = 0; spdx = 0
                }
            } else if (line ~ /^@@include /) {
                ref = substr(line, 11)
                sub(/\r$/, "", ref)
                cand = resolve(ref)
                if (cand == "") fail("no such part: " ref)
                emit(cand, 0, depth + 1)
            } else if (e == "css") {
                # Comments out wherever they sit, and out under --comments too.
                # See the note at the top: `*/` closes the block comment this
                # whole region lives inside, and a stylesheet is where an author
                # writes that pair without thinking about it. There is no SPDX
                # exception for the same reason -- a licence header is a comment
                # and its close is the hazard.
                t = line
                out = ""
                while (1) {
                    if (incss) {
                        j = index(t, "*/")
                        if (j == 0) { t = ""; break }
                        t = substr(t, j + 2)
                        incss = 0
                    } else {
                        i = index(t, "/*")
                        if (i == 0) break
                        out = out substr(t, 1, i - 1) " "
                        t = substr(t, i + 2)
                        incss = 1
                    }
                }
                out = out t
                u = out
                sub(/^[ \t]+/, "", u)
                sub(/[ \t\r]+$/, "", u)
                if (u != "") print out
            } else if (keep != "" || e == "") {
                print line
            } else {
                t = line
                sub(/^[ \t]+/, "", t)
                sub(/\r$/, "", t)
                if (t == "") {
                    # a blank line, and it goes
                } else if (e == "js" || e == "jsc" || e == "qml") {
                    if (t ~ /^\/\/#/ || t ~ /SPDX-/) {
                        print line
                    } else if (t ~ /^\/\//) {
                        # a line comment, and it goes
                    } else if (t ~ /^\/\*/) {
                        if (t !~ /\*\//) {
                            inblock = 1; nheld = 0; spdx = 0
                            held[nheld++] = line
                        }
                    } else {
                        print line
                        u = line
                        if (gsub(/`/, "\\&", u) % 2) intpl = 1
                    }
                } else if (e == "sh" || e == "py") {
                    if (substr(t, 1, 1) != "#" || t ~ /SPDX-/) {
                        print line
                        if (e == "py" && triples(line) % 2) indoc = 1
                    }
                } else if (e == "cmd") {
                    u = toupper(t)
                    if (t ~ /SPDX-/ || (u !~ /^REM([ \t]|$)/ && t !~ /^::/)) print line
                } else {
                    print line
                }
            }
            ret = (getline line < path)
        }
        close(path)
        if (inblock) fail("a block comment is never closed in " path)
        if (intpl)   fail("a template literal is never closed in " path)
        if (indoc)   fail("a triple-quoted string is never closed in " path)
        if (incss)   fail("a stylesheet comment is never closed in " path)
    }

    BEGIN {
        nroots = split(ENVIRON["NT_ROOTS"], root, "\n")
        if (ENVIRON["NT_ONE"] != "") emit(ENVIRON["NT_ONE"], 0, 0)
        else emit(resolve("skeleton.cmd"), 1, 0)
    }
'

# Python opens a string three quotes at a time and one of the three cannot be
# written inside the program above, which is a single-quoted shell word. It
# arrives as a variable instead.
nt_triples='
    function triples(s,   n) {
        n = gsub(/"""/, "\\&", s)
        return n + gsub(q3, "\\&", s)
    }
'

# Unix endings, whatever the checkout had. See the carriage-return note above:
# this is the half of that fix which makes the artifact the same bytes on every
# platform rather than the same bytes as its own source tree.
#
# `tr` and not a rule about which parts are stripped, because a part that is
# never stripped is exactly where the returns survived. No source file in this
# tree carries a return anywhere but at the end of a line -- the escape
# sequences in cmd/launcher.cmd are ESC, not CR -- so deleting the character
# outright cannot take anything else with it.
#
# The search path and the single-part name travel to awk through the
# environment rather than through `-v`, and that is a lane rather than a
# preference. `-v` will not carry a newline at all on the awk macOS ships:
# `awk: newline in string ... at source line 1`, which took every build step on
# that runner with it. It also reads backslash escapes in what it is given,
# where ENVIRON hands the value over with no processing of any kind -- so a root
# path is the path and not a re-reading of it.
nt_assemble() {
    NT_ROOTS="$NT_ROOTS" NT_ONE="${1:-}" \
        awk -v q3="$NT_Q3" -v keep="$KEEP" \
        "$nt_triples$nt_awk" | tr -d '\r'
}

# One region, by name, and it is a separate function because of what the
# spelling below it does with a name it cannot find.
#
# `nt_assemble "$(nt_resolve some/part)"` reads as "assemble that part". It is
# not: command substitution discards nt_resolve's exit status, so a part that
# does not exist arrives as an empty argument, NT_ONE is empty, and the awk
# program falls back to assembling skeleton.cmd -- the whole polyglot, document
# and all. Every check downstream then passes, because the whole polyglot does
# parse as JavaScript. Measured: renaming web/ to else/ and forgetting this one
# line left `--check` green while it checked the artifact instead of the region,
# and the only symptom was a stylesheet turning up in a JavaScript syntax error
# three suites later.
nt_region() {
    nt_part="$(nt_resolve "$1")" || {
        echo "assemble.sh: cannot check the region: no such part: $1" >&2
        exit 1
    }
    nt_assemble "$nt_part"
}

if [ "$VERIFY" = "1" ]; then
    # Each region checked by the language it is written in, on the text that is
    # about to ship rather than on the text it was cut from. A strip that took
    # one line too many is a syntax error here and an engine that opens no
    # window three suites later.
    #
    # These run over the overlays too, so an app whose JavaScript does not parse
    # is refused here rather than by an engine with no window and nothing to
    # say. That is a change: build.sh passed --no-verify on every build because
    # the checks were a property of neutrino/ alone and the app was spliced in
    # afterwards. The app is part of the assembly now.
    nt_tmp="$(mktemp -d)"
    trap 'rm -rf "$nt_tmp"' EXIT
    nt_region sh/parts.list                    > "$nt_tmp/region.sh"
    # The JavaScript region is three includes in the skeleton rather than one,
    # and it is checked as the one thing they make: js/parts.list, then the
    # `@else` branch of the conditional-compilation block, then the call that
    # starts it. Concatenated in the artifact's own order, so what node reads
    # here is what an engine reads there.
    #
    # It matters that all three are named. The app is else/parts.list now, and
    # a check that had kept reading js/parts.list alone would have stopped
    # looking at the app on the day the app moved -- silently, still passing.
    nt_region js/parts.list                    > "$nt_tmp/region.js"
    nt_region else/parts.list                 >> "$nt_tmp/region.js"
    nt_region js/launch.js                    >> "$nt_tmp/region.js"
    nt_region py/shim.py                       > "$nt_tmp/region.py"
    if command -v bash >/dev/null 2>&1; then
        bash -n "$nt_tmp/region.sh" || {
            echo "assemble.sh: the shell region does not parse" >&2; exit 1; }
    fi
    if command -v node >/dev/null 2>&1; then
        node --check "$nt_tmp/region.js" || {
            echo "assemble.sh: the JavaScript region does not parse" >&2; exit 1; }
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' \
            "$nt_tmp/region.py" || {
            echo "assemble.sh: the PyGObject shim does not parse" >&2; exit 1; }
    fi
fi

[ -n "$CHECK_ONLY" ] && exit 0

# =====================================================================
# The shape of what came out
# =====================================================================
# What a part may not carry, because it would move where this file is cut. This
# is cheaper here than anywhere else: an app whose markup moves the cut produces
# a file that still looks like a neutrino app and fails on an engine, or on all
# four at once.
#
# There used to be a census of `//#` sentinels above this, and there is not one
# now because there are no sentinels. They were splice targets, and nothing
# splices; the two readers that outlived the splice read a part or a line of
# real code instead.
nt_shape() {
    nt_file="$1"

    # The document region, which is everything from the doctype to the seam
    # line, and the four things it may not contain. Each one produces a file
    # that runs and is wrong rather than a file that fails.
    nt_doc="$(grep -n '^<!doctype html><html>' "$nt_file" | head -1 | cut -d: -f1)"
    nt_seam="$(grep -n '^<script type=text/javascript>' "$nt_file" | head -1 | cut -d: -f1)"
    if [ -z "$nt_doc" ] || [ -z "$nt_seam" ] || [ "$nt_seam" -le "$nt_doc" ]; then
        echo "assemble.sh: the assembly has no document between a doctype and a script tag" >&2
        exit 1
    fi
    # A document with nothing between its doctype and its seam is not a range
    # any sed will read: the two spellings disagree about an address that runs
    # backwards, and one of them errors.
    if [ "$((nt_doc + 1))" -gt "$((nt_seam - 1))" ]; then
        : > "$nt_file.doc"
    else
        sed -n "$((nt_doc + 1)),$((nt_seam - 1))p" "$nt_file" > "$nt_file.doc"
    fi

    nt_bad() {
        echo "assemble.sh: the early shell contains \`$1\`, which $2" >&2
        rm -f "$nt_file.doc"
        exit 1
    }
    if LC_ALL=C grep -q '\*/' "$nt_file.doc"; then
        nt_bad '*/' \
            'ends the block comment this file opens on line 1 -- every engine but jsc reads the whole shell region as comment, and a close here spills the shell into four JavaScript parsers at once'
    fi
    if LC_ALL=C grep -qi '</*script' "$nt_file.doc"; then
        nt_bad '<script' \
            'moves where both halves of this file are cut: the document runs from the doctype to the first script tag after it, and the page script from that same tag'
    fi
    if LC_ALL=C grep -qi '<!doctype' "$nt_file.doc"; then
        nt_bad '<!doctype' \
            'is a second doctype, which the launcher refuses outright rather than guess which one the document starts at'
    fi
    # Exactly one, and not none: html/policy.html is a part of the document now
    # and its line is in this region. A second would be the hazard -- a browser
    # takes the intersection of every policy it is given, so two of them is a
    # document enforcing something nobody wrote, and the offline overlay's is
    # the one that would stop being what it says.
    nt_pol="$(LC_ALL=C grep -ci 'content-security-policy' "$nt_file.doc" || true)"
    if [ "$nt_pol" != "1" ]; then
        echo "assemble.sh: the document carries $nt_pol content policies, wanted exactly 1" >&2
        echo "             it is html/policy.html, and an overlay replaces it rather than adding one" >&2
        rm -f "$nt_file.doc"
        exit 1
    fi
    # Tabs and newlines are ordinary in markup now that the document is a region
    # rather than one line. Everything else in the C0 range is not: a stray NUL
    # or escape is a byte an engine reads and nobody can see in a diff.
    if LC_ALL=C grep -q '[[:cntrl:]]' "$nt_file.doc" ; then
        nt_bad 'a control character' 'is a byte an engine reads and no reader can see'
    fi
    rm -f "$nt_file.doc"
}

if [ "$OUTPUT" = "-" ]; then
    # Straight out, and the shape checks cannot run on a stream. This is the
    # spelling for a caller that wants the bytes and is doing its own reading;
    # `--check` is the one that wants the checks.
    nt_assemble
    exit 0
fi

# Written beside the output rather than in a temporary directory, because that
# is the one place already known to be writable and on the same filesystem as
# the artifact. $TMP is moved into place only once the shape has been read back,
# so a build that fails leaves the previous artifact alone rather than a
# half-written one with the same name.
TMP="$OUTPUT.tmp.$$"
trap 'rm -f "$TMP" "$TMP.doc"' EXIT
nt_assemble > "$TMP"
nt_shape "$TMP"
mv -f "$TMP" "$OUTPUT"

# The trap is left armed on the way out, and that is the fix for a leak rather
# than an oversight. It used to be cleared here, back when the `mv` above had
# already consumed the only temporary -- and clearing it left the others sitting
# beside the artifact under names nobody would think to delete, published to the
# website by pages/build.sh, which copies whatever is in its output directory.
# `rm -f` on a name the `mv` has already taken is a no-op, so there is nothing
# to clear it for.
