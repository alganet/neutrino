#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# assemble.sh - builds the polyglot template out of neutrino/.
# Usage: assemble.sh [--comments] [--no-verify] > template.cmd
#        assemble.sh --strip <file> > stripped
#
# skeleton.cmd carries the lines that are more than one language at once and
# nothing else. Everything under it is ordinary source in one language, pulled
# in by an `@@include <path>` line, and the path is relative to this directory.
# See POLYGLOT.md.
#
# The default output has no comments in it. That is the whole point of the
# split: a comment can be removed by a program that knows which language it is
# reading, and in a single file that knows five at once it cannot. --comments
# keeps them, and what comes out is byte for byte what the parts say -- which is
# how this is checked against the monolith it replaced.
#
# Stripping is whole-line only. A trailing comment stays, and so does anything
# sharing its line with code, because the cheap rule is the one that cannot be
# wrong about a `//` inside a string. What it costs is a few hundred bytes; what
# it buys is that this program never has to parse the language it is cutting.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
KEEP=""
VERIFY=1
STRIP_ONE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --comments)  KEEP=1; shift ;;
        --no-verify) VERIFY=0; shift ;;
        # One file, by the rules for its extension, and nothing else. build.sh
        # runs the app it is handed through here, so that the artifact carries
        # no more prose than the launcher does and so that there is one
        # implementation of the strip rather than a second copy to drift.
        --strip)     STRIP_ONE="${2:-}"; shift 2 ;;
        *) echo "assemble.sh: unknown option $1" >&2; exit 1 ;;
    esac
done

if [ -n "$STRIP_ONE" ] && [ ! -f "$STRIP_ONE" ]; then
    echo "assemble.sh: --strip: $STRIP_ONE not found" >&2
    exit 1
fi

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
# on the end, no case in nt_read matched the extension any more, and the whole
# batch region went out through the fallback `cat` -- measured as
# `cat: .../launcher.cmd$'\r': No such file or directory` with every build step
# on the Windows lane red behind it. And the parts that are never stripped, the
# skeleton and the document line, would have kept their returns in a file where
# everything else had lost them: test/parse.sh reads the here-document
# delimiter off the seam line with a `$` anchor and would have found nothing
# there, on an artifact that no shell could run either.
#
# So: the include directive is trimmed where awk reads it, and the assembly is
# normalised whole on the way out. What comes out has unix endings whatever the
# checkout had, which is what the monolith did by accident and this does on
# purpose.

# Every part named anywhere under this directory has to exist before a byte is
# written, because the expansion below runs inside a pipeline and an exit taken
# in there is an exit taken in a subshell -- the assembly would carry on with a
# hole in it and come out looking assembled.
nt_missing=""
while IFS= read -r nt_ref; do
    case "$nt_ref" in
        *..*|/*) echo "assemble.sh: include path leaves the source tree: $nt_ref" >&2; exit 1 ;;
    esac
    [ -f "$ROOT/$nt_ref" ] || nt_missing="$nt_missing $nt_ref"
done <<EOF
$(grep -rh '^@@include ' "$ROOT" | sed 's/^@@include //' | tr -d '\r' | sort -u)
EOF
if [ -n "$nt_missing" ]; then
    echo "assemble.sh: no such part:$nt_missing" >&2
    exit 1
fi


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
# So the include expansion and all four strip rules live in one recursive awk
# function. Its per-file state -- which comment it is inside, which string it is
# inside -- is declared as extra parameters, which is how awk spells a local,
# and a file that ends inside either says which file it was.
nt_awk='
    function fail(msg) {
        print "assemble.sh: " msg > "/dev/stderr"
        exit 1
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
                  e, ret, line, t, u, ref, i,
                  inblock, intpl, indoc, nheld, spdx, held) {
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
                emit(root "/" ref, 0, depth + 1)
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
    }

    BEGIN {
        if (one != "") emit(one, 0, 0)
        else emit(root "/skeleton.cmd", 1, 0)
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
nt_assemble() {
    awk -v root="$ROOT" -v q3="$NT_Q3" -v keep="$KEEP" -v one="${1:-}" \
        "$nt_triples$nt_awk" | tr -d '\r'
}

if [ -n "$STRIP_ONE" ]; then
    nt_assemble "$STRIP_ONE"
    exit 0
fi

if [ "$VERIFY" = "1" ]; then
    # Each region checked by the language it is written in, on the text that is
    # about to ship rather than on the text it was cut from. A strip that took
    # one line too many is a syntax error here and an engine that opens no
    # window three suites later.
    #
    # Not on every build. This is a property of the source tree and not of the
    # app being spliced into it, so build.sh passes --no-verify and the checks
    # run once, from test/assemble.sh, rather than fifty times in a suite that
    # builds fifty artifacts out of one tree. `node --check` alone is a third of
    # a second on the Windows runner.
    nt_tmp="$(mktemp -d)"
    trap 'rm -rf "$nt_tmp"' EXIT
    nt_assemble "$ROOT/sh/parts.list" > "$nt_tmp/region.sh"
    nt_assemble "$ROOT/js/parts.list" > "$nt_tmp/region.js"
    nt_assemble "$ROOT/py/shim.py"    > "$nt_tmp/region.py"
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

nt_assemble
