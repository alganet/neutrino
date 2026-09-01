#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# assemble.sh - the assembler's inputs, and the artifact it says it built.
#
# neutrino/assemble.sh is the program every other suite's artifact comes out of.
# It used to be half of a pair: it put a template together and build.sh spliced
# an app into it with four text replacements. Each of those was a sed or awk
# pattern with no failure path of its own, so each needed a read-back to say
# whether it had applied, and most of this file was those read-backs and the
# `oldbuild.sh` before-state they were measured against.
#
# All of that is gone, and it is gone by construction rather than by being
# fixed. There is one directive, `@@include`, and an include cannot half-apply:
# a part that is not there is a refusal before a byte is written, and a part
# that is there arrives whole. The hazards that needed proving -- an app's own
# `tiers:` line answering the check that was checking it, a substitution with no
# range rewriting the app's source, a stamp that silently did not land -- are
# not hazards this program has, because it performs no substitution.
#
# What is left to assert is what an assembler can still get wrong: which file
# wins when two roots carry the same part, what the strip takes off, where the
# artifact may be written, and whether a config the launcher could not use is
# refused before it ships rather than after.
#
# No display, no engine, a few seconds. Usage: assemble.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
report() { echo "report: $*"; }
pass()   { echo "  PASS: $*"; }
fail()   { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }
eq()     { if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1 expected=$3 actual=$2"; fi; }
# Sizes through `wc -c` and never `stat`: the two spellings of stat in this
# matrix take different flags and the reading is a number either way.
size()   { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo missing; fi; }

report "platform=$(uname -s) bash=${BASH_VERSION:-none}"

# =====================================================================
# The fixtures
# =====================================================================
# A fresh copy of the tree per case, because some of these destroy the source
# they are handed. assemble.sh takes neutrino/ from beside itself, which is what
# makes "the output is inside the source" expressible at all.
tree() {
    rm -rf "$WORK/$1"
    mkdir -p "$WORK/$1"
    cp -R "$ROOT/neutrino" "$WORK/$1/"
    echo "$WORK/$1"
}

# An overlay holding one app.js, read from stdin, which is what most of these
# want. An app is a directory now and this is the shortest way to write one.
appdir() {
    nt_d="$WORK/ov-$1"
    rm -rf "$nt_d"
    mkdir -p "$nt_d"
    cat > "$nt_d/app.js"
    printf '%s\n' "$nt_d"
}

# An empty overlay for a config case to write into. Unlike appdir this reads
# nothing: its callers write config.json themselves, some from a here document
# and some from mkconf below, and a `cat` in here would swallow whichever of the
# two the caller was not using -- which is a suite that hangs waiting on a
# terminal rather than one that fails.
confdir() {
    nt_d="$WORK/cf-$1"
    rm -rf "$nt_d"
    mkdir -p "$nt_d"
    printf '%s\n' "$nt_d"
}

# The defaults, as the tree carries them, so nothing below writes a second copy
# of a value that lives in a file.
# A config value out of a built artifact, bounded by the two lines the launcher
# itself writes around the include: `        config:` opens it and the JSON's own
# `}` at column zero closes it. That used to be a pair of `//#` markers, and it
# is real code now for the same reason nothing else is a marker any more.
conf() {
    sed -n '/^        config:$/,/^}$/p' "$1" |
        sed -n -e "s/^ *\"$2\": \"\(.*\)\",\{0,1\}\$/\1/p" \
               -e "s/^ *\"$2\": \([^\",]*\),\{0,1\}\$/\1/p" | head -1
}
default_of() {
    sed -n -e "s/^ *\"$1\": \"\(.*\)\",\{0,1\}\$/\1/p" \
           -e "s/^ *\"$1\": \([^\",]*\),\{0,1\}\$/\1/p" \
        "$ROOT/neutrino/config.json" | head -1
}

APP_PLAIN="$(appdir plain <<'EOF'
document.title = "example";
EOF
)"

# An app carrying a `tiers:` line. It used to be the fixture most of this file
# was built on: the substitutions had no range, so a line of the app's own
# source shaped like the stamp was rewritten by the build and read back by the
# check that was meant to catch it. Nothing substitutes now, and this is here to
# say that -- an app may write whatever it likes and the assembler does not edit
# the app.
APP_TIERS="$(appdir tiers <<'EOF'
var myConfig = {
    tiers: "offline,tight",
    name: "example"
};
document.title = myConfig.name;
EOF
)"

# =====================================================================
# The controls
# =====================================================================
# A refusal that builds nothing is not a pass. Everything below that asserts
# something is refused is worth reading only if this says the assembler works
# on this platform at all.
report "section: controls"
echo "=== the assembler builds, with and without an overlay ==="
T="$(tree plain)"
bash "$T/neutrino/assemble.sh" "$T/bare.cmd" > "$WORK/plain.log" 2>&1
eq "a build with no overlay succeeds" "$?" "0"
eq "and carries the tree's default tier" "$(conf "$T/bare.cmd" tiers)" "$(default_of tiers)"

bash "$T/neutrino/assemble.sh" --overlay "$APP_PLAIN" "$T/app.cmd" > "$WORK/app.log" 2>&1
eq "a build with an app overlay succeeds" "$?" "0"
eq "and the app is in it" "$(grep -c 'document.title = "example";' "$T/app.cmd" | head -1)" "1"
eq "and the app is inside the runWeb slot" \
   "$(sed -n '/^    NeutrinoWebview.runWeb = function () {$/,/^    };$/p' "$T/app.cmd" |
      grep -c 'document.title = "example";' | head -1)" "1"

# The app is a part like any other, so the assembler has no business editing it.
# This is the hazard the old suite was mostly about, asserted the other way
# round: not "the substitution had a range" but "there is no substitution".
bash "$T/neutrino/assemble.sh" --overlay "$APP_TIERS" "$T/tiers.cmd" >/dev/null 2>&1
eq "an app carrying a tiers: line builds" "$?" "0"
eq "and its line is untouched" \
   "$(sed -n '/^    NeutrinoWebview.runWeb = function () {$/,/^    };$/s/^ *tiers: "\(.*\)",$/\1/p' "$T/tiers.cmd" | head -1)" \
   "offline,tight"
eq "and the artifact's own stamp is the tree's" \
   "$(conf "$T/tiers.cmd" tiers)" "$(default_of tiers)"

# =====================================================================
# Which root a part comes from
# =====================================================================
# The whole of what an overlay is. `--overlay` names a directory that is
# searched before this one, more than one may be given, and the last named wins
# -- so a caller can stack a general overlay under a specific one and change a
# single part without copying the rest.
report "section: overlays"
echo "=== the last overlay named is the first root searched ==="
T="$(tree overlay)"
OV_A="$WORK/ov-a"; OV_B="$WORK/ov-b"
rm -rf "$OV_A" "$OV_B"; mkdir -p "$OV_A" "$OV_B"
printf 'document.title = "from A";\n' > "$OV_A/app.js"
printf 'i-am-from-a{color:red}\n'     > "$OV_A/style.css"
printf 'document.title = "from B";\n' > "$OV_B/app.js"

bash "$T/neutrino/assemble.sh" --overlay "$OV_A" --overlay "$OV_B" "$T/ab.cmd" >/dev/null 2>&1
eq "the later overlay's part wins" "$(grep -c 'from B' "$T/ab.cmd" | head -1)" "1"
eq "and the earlier one's is not in the file" "$(grep -c 'from A' "$T/ab.cmd" | head -1)" "0"
eq "while a part only the earlier one has still arrives" \
   "$(grep -c 'i-am-from-a' "$T/ab.cmd" | head -1)" "1"
# Without this, "the later one wins" is also what a program that ignores the
# earlier overlay entirely would report.
bash "$T/neutrino/assemble.sh" --overlay "$OV_B" --overlay "$OV_A" "$T/ba.cmd" >/dev/null 2>&1
eq "and the order is the argument order, not the alphabet" \
   "$(grep -c 'from A' "$T/ba.cmd" | head -1)" "1"

# neutrino/ is last, so a part no overlay carries is the launcher's.
eq "a part no overlay carries comes from the tree" \
   "$(grep -c 'Welcome to neutrino' "$T/ab.cmd" | head -1)" "1"

# Any part, and not only the four an app usually writes. An overlay carrying a
# launcher module replaces the launcher's, because the author of the overlay is
# the person shipping the artifact.
rm -rf "$WORK/ov-deep"; mkdir -p "$WORK/ov-deep/js"
printf 'NeutrinoWebview.somethingOfMyOwn = function () { return 42; };\n' \
    > "$WORK/ov-deep/js/note.js"
bash "$T/neutrino/assemble.sh" --overlay "$WORK/ov-deep" "$T/deep.cmd" >/dev/null 2>&1
eq "an overlay may replace a part inside a subdirectory" \
   "$(grep -c 'somethingOfMyOwn' "$T/deep.cmd" | head -1)" "1"

# A part named by an include and carried by nobody is a refusal before a byte is
# written, because the expansion runs inside a pipeline and an exit taken in
# there is an exit taken in a subshell -- the assembly would carry on with a
# hole in it and come out looking assembled.
T2="$(tree overlay-missing)"
printf '@@include js/nothing-here.js\n' >> "$T2/neutrino/js/parts.list"
rm -f "$T2/out.cmd"
bash "$T2/neutrino/assemble.sh" "$T2/out.cmd" > "$WORK/missing.log" 2>&1
eq "a part nothing carries is refused" "$?" "1"
eq "and says which one" "$(grep -c 'no such part' "$WORK/missing.log" | head -1)" "1"
eq "and no artifact is left behind" "$(size "$T2/out.cmd")" "missing"

# The control for that refusal: the same include, satisfied by an overlay.
rm -rf "$WORK/ov-fills"; mkdir -p "$WORK/ov-fills/js"
printf 'NeutrinoWebview.filled = 1;\n' > "$WORK/ov-fills/js/nothing-here.js"
bash "$T2/neutrino/assemble.sh" --overlay "$WORK/ov-fills" "$T2/filled.cmd" >/dev/null 2>&1
eq "and an overlay that carries it builds" "$?" "0"

# An include may not climb out of the roots it is resolved against.
T3="$(tree overlay-escape)"
printf '@@include ../../../etc/passwd\n' >> "$T3/neutrino/js/parts.list"
bash "$T3/neutrino/assemble.sh" "$T3/out.cmd" > "$WORK/escape.log" 2>&1
eq "an include that leaves the tree is refused" "$?" "1"
eq "and says so" "$(grep -c 'leaves the source tree' "$WORK/escape.log" | head -1)" "1"

# =====================================================================
# The strip
# =====================================================================
# What the strip takes off is prose and nothing else. The stripped artifact is
# asserted against the commented one it was built beside: smaller, carrying no
# line that is only a comment, and every line that is not a comment still there
# in the same order. The last of those is the one that matters -- a strip that
# dropped a line of code would still be smaller and still carry no comments.
report "section: strip"
echo "=== the strip removes comments and nothing else ==="
T="$(tree strip)"
APP_TEST="$(appdir suite < "$ROOT/test/neutrinotest.js")"
bash "$T/neutrino/assemble.sh" --comments --overlay "$APP_TEST" "$T/full.cmd" >/dev/null 2>&1
bash "$T/neutrino/assemble.sh"             --overlay "$APP_TEST" "$T/thin.cmd" >/dev/null 2>&1
FULL="$(size "$T/full.cmd")"; THIN="$(size "$T/thin.cmd")"
report "full=$FULL thin=$THIN"
eq "the stripped artifact is smaller" \
   "$([ "${THIN:-0}" -lt "${FULL:-0}" ] 2>/dev/null && echo smaller || echo not-smaller)" "smaller"
# Under a third of what it was would mean whole regions had gone missing, and
# over nine tenths would mean the strip had stopped running. Neither is a size
# anybody should have to eyeball in a log.
eq "and not so much smaller that something is missing" \
   "$([ "${THIN:-0}" -gt "$((FULL / 3))" ] && [ "${THIN:-0}" -lt "$((FULL * 9 / 10))" ] \
        && echo in-range || echo out-of-range)" "in-range"
# Three spellings of prose, one per family of language in the file: a batch REM
# line, a shell or Python comment at the left margin, and a JavaScript line
# comment that opens with a capital. None of them can match a line of code, and
# the count in the commented artifact is asserted first -- a pattern that
# matched nothing would report the strip working perfectly.
#
# SPDX lines are excluded because they are not prose and are kept on purpose. A
# licence notice removed from somebody else's source by a build step is not a
# size optimisation, so the strip keeps them and this counts what is left.
for nt_kind in "REM:^REM " "hash:^# " "slash:^[[:space:]]*// [A-Z]"; do
    nt_name="${nt_kind%%:*}"; nt_pat="${nt_kind#*:}"
    nt_before="$(grep "$nt_pat" "$T/full.cmd" | grep -vc 'SPDX-' | head -1)"
    nt_after="$(grep "$nt_pat" "$T/thin.cmd" | grep -vc 'SPDX-' | head -1)"
    report "prose $nt_name before=$nt_before after=$nt_after"
    if [ "${nt_before:-0}" -lt 1 ]; then
        fail "no $nt_name prose in the commented artifact; the count below measured nothing"
    else
        eq "no $nt_name prose survives the strip" "$nt_after" "0"
    fi
done

# And the strip only ever removes. Asserted as a diff with no additions rather
# than by restating the rules here, because a second copy of the rules is a
# second thing to keep right -- and this catches a line that was rewritten as
# well as one that was invented, which no rule-shaped check would.
eq "every line the stripped artifact carries is a line of the commented one" \
   "$(diff "$T/full.cmd" "$T/thin.cmd" | grep -c '^>' | head -1)" "0"

# And the notice survives. Built from an app that carries one of its own, so
# this measures the app's header and not the skeleton's, which is never
# stripped and would pass this on its own.
APP_SPDX="$(appdir spdx <<'EOF'
// SPDX-FileCopyrightText: 2026 Somebody Else <nobody@example.invalid>
// SPDX-License-Identifier: MIT
// An ordinary comment, which is prose and goes.
document.title = "x";
EOF
)"
bash "$T/neutrino/assemble.sh" --overlay "$APP_SPDX" "$T/spdx.cmd" >/dev/null 2>&1
eq "the app's licence notice survives the strip" \
   "$(grep -c 'SPDX-License-Identifier: MIT' "$T/spdx.cmd" | head -1)" "1"
eq "and its copyright line does too" \
   "$(grep -c 'nobody@example.invalid' "$T/spdx.cmd" | head -1)" "1"
eq "while the comment beside them does not" \
   "$(grep -c 'An ordinary comment' "$T/spdx.cmd" | head -1)" "0"

# CSS is the one language whose comments come off whatever was asked for, and
# it is not tidiness: `*/` closes the block comment the whole shell and document
# region lives inside, and a stylesheet is where an author writes that pair
# without thinking about it. A licence header in a stylesheet is a comment and
# goes with the rest, which is why there is no SPDX exception here.
report "section: css"
echo "=== a stylesheet's comments never reach the artifact ==="
T="$(tree css)"
OV_CSS="$WORK/ov-css"
rm -rf "$OV_CSS"; mkdir -p "$OV_CSS"
cat > "$OV_CSS/style.css" <<'EOF'
/* SPDX-License-Identifier: MIT */
/* a normal comment */
q{color:green}
r{color:blue} /* trailing, and on a line with a rule */
s{color:pink}
/* one that
   runs across
   three lines */
t{color:grey}
EOF
for nt_mode in "" "--comments"; do
    rm -f "$T/css.cmd"
    if [ -n "$nt_mode" ]; then
        bash "$T/neutrino/assemble.sh" "$nt_mode" --overlay "$OV_CSS" "$T/css.cmd" >/dev/null 2>&1
    else
        bash "$T/neutrino/assemble.sh" --overlay "$OV_CSS" "$T/css.cmd" >/dev/null 2>&1
    fi
    nt_label="${nt_mode:---stripped}"
    eq "a stylesheet with comments builds ($nt_label)" "$?" "0"
    eq "no comment survives ($nt_label)" \
       "$(grep -c 'a normal comment\|runs across\|trailing, and on a line' "$T/css.cmd" | head -1)" "0"
    eq "not even the licence header ($nt_label)" \
       "$(grep -c 'SPDX-License-Identifier: MIT' "$T/css.cmd" | head -1)" "0"
    for nt_rule in 'q{color:green}' 'r{color:blue}' 's{color:pink}' 't{color:grey}'; do
        eq "the rule $nt_rule survives ($nt_label)" \
           "$(grep -cF "$nt_rule" "$T/css.cmd" | head -1)" "1"
    done
done

# A stylesheet is written across as many lines as it wants to be. The document
# used to be one physical line -- the style and the body were folded into it --
# and an app's CSS arrived as one long run with its structure gone.
eq "and the stylesheet keeps its own lines" \
   "$(sed -n '/^<!doctype html><html>/,/^<script type=text\/javascript>/p' "$T/css.cmd" |
      grep -c '^[qrst]{color:' | head -1)" "4"

# =====================================================================
# The parts, each read by its own language
# =====================================================================
# The split is only worth its shape if a part is a thing an editor, a linter or
# a checker can open. It was not, to begin with: the JavaScript went in as runs
# of `key: value,` entries cut out of the middle of one object literal, and
# every one of the files was a syntax error on its own.
#
# What is not checked here is anything that is not a document in its own right:
# html/document.html, whose closing tags are the skeleton's last line, the
# `.list` manifests, which claim no language, app.js, which is the body of a
# function rather than a program, and any part carrying an `@@include` -- a
# directive is not JavaScript and a file with one in it is a template. That last
# exclusion is derived rather than listed, so a part that grows an include stops
# being checked here without anybody editing this file, and a part that loses
# one starts being checked again. assemble.sh checks the assembled regions,
# which is a different thing -- a tree of fragments assembles into something
# that parses perfectly well.
report "section: parts"
echo "=== every part is a document its own language can read ==="
T="$(tree parts)"
PARTS_JS="$(ls "$T"/neutrino/js/*.js 2>/dev/null | wc -l | tr -d ' ')"
PARTS_SH="$(ls "$T"/neutrino/sh/*.sh 2>/dev/null | wc -l | tr -d ' ')"
report "parts js=$PARTS_JS sh=$PARTS_SH"
if [ "${PARTS_JS:-0}" -lt 10 ] || [ "${PARTS_SH:-0}" -lt 5 ]; then
    fail "the tree has $PARTS_JS js and $PARTS_SH sh parts; the checks below measured nothing"
else
    # One node for all of them, and not `node --check` per file. Twenty-three
    # interpreter startups is a third of a second each on the Windows runner and
    # nothing at all here, which is the shape of cost that took this suite from
    # forty-seven seconds to a timeout.
    #
    # The control is the last name on the list: a run of entries out of the
    # middle of an object literal, which is what every one of these files used
    # to be. If it is not reported as broken then neither is anything else.
    printf 'foo: function () {\n    return 1;\n},\n' > "$T/fragment.js"
    NT_DOCS=""
    NT_TEMPLATES=""
    for nt_part in "$T"/neutrino/js/*.js; do
        if grep -q '^@@include ' "$nt_part"; then
            NT_TEMPLATES="$NT_TEMPLATES $(basename "$nt_part")"
        else
            NT_DOCS="$NT_DOCS $nt_part"
        fi
    done
    report "js parts carrying an include:${NT_TEMPLATES:- none}"
    if command -v node >/dev/null 2>&1; then
        NT_BAD="$(node -e '
            var fs = require("fs"), vm = require("vm"), path = require("path");
            var bad = [];
            process.argv.slice(1).forEach(function (f) {
                try { new vm.Script(fs.readFileSync(f, "utf8"), { filename: f }); }
                catch (e) { bad.push(path.basename(f)); }
            });
            process.stdout.write(bad.join(" "));
        ' $NT_DOCS "$T/fragment.js")"
        eq "the only js/ file that does not parse is the fragment control" \
           "${NT_BAD:-none}" "fragment.js"
    else
        report "node absent: the js/ parts were not parsed"
    fi

    NT_BAD=""
    for nt_part in "$T"/neutrino/sh/*.sh; do
        bash -n "$nt_part" 2>/dev/null || NT_BAD="$NT_BAD $(basename "$nt_part")"
    done
    eq "every sh/ part parses as a shell script" "${NT_BAD:-none}" "none"

    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' \
            "$T/neutrino/py/shim.py" >/dev/null 2>&1
        eq "the PyGObject shim compiles as Python" "$?" "0"
    else
        report "python3 absent: the shim was not compiled"
    fi

    # And the same three languages again, on the stripped assembly rather than
    # on the parts. These are different questions: a tree of parts that all
    # parse can still assemble into a region that does not, because the strip is
    # what runs in between.
    #
    # `--check` runs them and writes nothing. It reads the overlays too, so an
    # app whose JavaScript does not parse is refused here -- which is a change:
    # build.sh could not check an app it had not spliced yet. test/mkapp.sh
    # still passes --no-verify, because fifty builds out of one tree used to
    # mean fifty node startups and on the Windows runner that was a step that
    # timed out at five minutes with nothing else wrong.
    bash "$T/neutrino/assemble.sh" --check 2> "$WORK/verify.log"
    eq "the assembler's own region checks pass" "$?" "0"
    if [ -s "$WORK/verify.log" ]; then
        report "verify said: $(sed -n '1p' "$WORK/verify.log")"
    fi

    # The two lines an object lift anchors on. There are two lifts -- one in
    # test/parse.sh and one in test/verify-windows.ps1 -- and the second is
    # PowerShell, so it only runs on the platform where a mistake is most
    # expensive to find.
    #
    # Asserted on a built artifact rather than on a bare tree, because the app
    # sits inside the range both lifts take and an app carrying either line
    # moves where they end.
    bash "$T/neutrino/assemble.sh" --overlay "$APP_PLAIN" "$T/anchors.cmd" >/dev/null 2>&1
    eq "the artifact opens the object on exactly one line" \
       "$(grep -c '^    var NeutrinoWebview = {$' "$T/anchors.cmd" | head -1)" "1"
    eq "and starts it on exactly one line" \
       "$(grep -c '^    NeutrinoWebview\.run();$' "$T/anchors.cmd" | head -1)" "1"

    # The control: a part broken in a way no per-file check would see, since the
    # file it breaks is the one that is never stripped and never parsed.
    T2="$(tree parts-broken)"
    printf 'NeutrinoWebview.nope = function () {\n' >> "$T2/neutrino/js/launch.js"
    bash "$T2/neutrino/assemble.sh" --check > /dev/null 2>&1
    eq "and a region that does not parse is refused" \
       "$([ "$?" = "0" ] && echo accepted || echo refused)" "refused"

    # The same check, reaching into an overlay. An app is part of the assembly
    # now and this is the line that says the check knows it.
    APP_BROKEN="$(appdir broken <<'EOF'
document.title = "x"
function unclosed() {
EOF
)"
    bash "$T/neutrino/assemble.sh" --check --overlay "$APP_BROKEN" > /dev/null 2>&1
    eq "and so is an app whose javascript does not parse" \
       "$([ "$?" = "0" ] && echo accepted || echo refused)" "refused"
fi

# =====================================================================
# The endings the checkout gave it
# =====================================================================
# Git for Windows checks this tree out with CRLF endings, and the monolith
# never had to know: it went through sed and awk and nothing else, both of which
# normalise on that platform, so the artifact came out with unix endings
# wherever it was built. The split put `cat` and a bash `read` loop in the path
# and both of them keep a return.
#
# What that cost, measured on the runner: an include line spelled
# `cmd/launcher.cmd` with a return on the end matched no extension in the
# reader, the whole batch region went out through the fallback, and every build
# step on the Windows lane was red behind
# `cat: .../launcher.cmd$'\r': No such file or directory`. Behind that, the
# parts that are never stripped -- the skeleton and the document -- would have
# kept their returns in a file where everything else had lost them, and
# test/parse.sh reads the here-document delimiter off the seam line with a `$`
# anchor.
#
# So it is asserted here, on every lane, rather than on the one platform that
# has the endings. The fixture is checked first: a copy that did not come out
# CRLF is a reading about this suite and not about the assembler.
report "section: line-endings"
echo "=== a CRLF checkout builds the same artifact as a unix one ==="
NT_CRCH="$(printf '\r')"
T="$(tree eol)"
find "$T/neutrino" -type f ! -name 'assemble.sh' ! -name '*.md' -print |
while IFS= read -r nt_part; do
    sed "s/\$/$NT_CRCH/" "$nt_part" > "$nt_part.eol" && mv "$nt_part.eol" "$nt_part"
done
EOL_CRS="$(tr -dc "$NT_CRCH" < "$T/neutrino/skeleton.cmd" | wc -c | tr -d ' ')"
EOL_LINES="$(wc -l < "$T/neutrino/skeleton.cmd" | tr -d ' ')"
report "fixture returns=$EOL_CRS lines=$EOL_LINES"
if [ "$EOL_CRS" != "$EOL_LINES" ]; then
    # Reported and not failed. The sed that writes the fixture is the platform's
    # and this suite runs on four of them; a lane that cannot spell a carriage
    # return has measured nothing here, which is not the same as a defect.
    report "this sed does not write CRLF: the line-ending assertions were not run"
else
    bash "$T/neutrino/assemble.sh" --overlay "$APP_PLAIN" "$T/eol.cmd" > "$WORK/eol.log" 2>&1
    EOL_RC=$?
    eq "a CRLF checkout builds" "$EOL_RC" "0"
    if [ "$EOL_RC" != "0" ]; then
        # The two below read the artifact. Without this they read a file that
        # is not there, and "no returns in it" is what an empty read says.
        report "no artifact: $(sed -n '1p' "$WORK/eol.log")"
    else
        eq "and the artifact it produces has no returns in it" \
           "$(tr -dc "$NT_CRCH" < "$T/eol.cmd" | wc -c | tr -d ' ')" "0"
        T2="$(tree eol-unix)"
        bash "$T2/neutrino/assemble.sh" --overlay "$APP_PLAIN" "$T2/eol.cmd" > /dev/null 2>&1
        if cmp -s "$T/eol.cmd" "$T2/eol.cmd"; then
            pass "and it is byte for byte the artifact the unix checkout builds"
        else
            fail "the two checkouts disagree ($(size "$T/eol.cmd") against $(size "$T2/eol.cmd"))"
        fi
    fi
fi

# =====================================================================
# Where the artifact may be written
# =====================================================================
# Every one of these was a build that destroyed one of its own inputs and said
# nothing, or said the wrong thing. They are kept as assertions because the
# shapes are still expressible: the roots are directories of files and the
# output is a path somebody types beside them.
report "section: output"
echo "=== the output may not be inside anything this build reads ==="
T="$(tree output)"
# Three names, because the refusal is about the directory and not about a file:
# the part that used to be the template, a part that never was, and a name in
# there that does not exist yet.
for nt_out in neutrino/skeleton.cmd neutrino/js/message.js neutrino/anything.cmd; do
    rm -f "$WORK/marker"
    cp "$T/$nt_out" "$WORK/marker" 2>/dev/null
    bash "$T/neutrino/assemble.sh" "$T/$nt_out" > "$WORK/out.log" 2>&1
    eq "the output $nt_out is refused" "$?" "1"
    eq "and says why" "$(grep -c 'that tree is what this build reads' "$WORK/out.log" | head -1)" "1"
    if [ -f "$WORK/marker" ]; then
        cmp -s "$WORK/marker" "$T/$nt_out" && pass "and $nt_out is untouched" \
            || fail "$nt_out was modified by a build that refused"
    fi
done
# The control. The refusal is about the roots and not about every path with the
# word neutrino in it, or "refused" above is also what an assembler that refuses
# everything reports.
mkdir -p "$T/neutrino-apps"
bash "$T/neutrino/assemble.sh" "$T/neutrino-apps/out.cmd" > /dev/null 2>&1
eq "a directory merely named like the source is not refused" "$?" "0"

# An app is a root too, so its own parts are unnameable as an output. This is
# the shape that used to be spelled "the output is one of the inputs", and it
# used to cost the app: the redirection belonged to the sed on the right of the
# pipeline and the cat on the left ran beside it, so the assembler read back
# what it had already written and a 116-byte app came out 213225 bytes.
cp "$APP_PLAIN/app.js" "$WORK/app-before.js"
bash "$T/neutrino/assemble.sh" --overlay "$APP_PLAIN" "$APP_PLAIN/app.js" > "$WORK/selfout.log" 2>&1
eq "an overlay's own part is refused as the output" "$?" "1"
cmp -s "$WORK/app-before.js" "$APP_PLAIN/app.js" && pass "and the app is untouched" \
    || fail "the app was destroyed by a build that refused"

# A directory is not an output either, and it used to be accepted: `mv -f` moves
# a file *into* a directory of that name, so the artifact came out as
# `<dir>/<name>.tmp.<pid>` -- not at the path that was asked for, under a name
# that reads as leftover rubbish, from a build that exited 0.
mkdir -p "$T/adir"
bash "$T/neutrino/assemble.sh" "$T/adir" > "$WORK/dirout.log" 2>&1
eq "a directory named as the output is refused" "$?" "1"
eq "and says which it wanted" \
   "$(grep -c "the output is the artifact's own path" "$WORK/dirout.log" | head -1)" "1"
eq "and nothing was written into it" "$(ls -A "$T/adir" | wc -l | tr -d ' ')" "0"

# And nothing this program writes outlives a failure. build.sh wrote three
# temporaries beside the output and cleared its trap after the `mv`, which left
# two of them there under names nobody would think to delete -- 153 KB and the
# app's own source, published to the website by pages/build.sh, which copies
# whatever is in its output directory.
rm -rf "$T/clean"; mkdir -p "$T/clean"
bash "$T/neutrino/assemble.sh" --overlay "$APP_PLAIN" "$T/clean/out.cmd" >/dev/null 2>&1
eq "a build that succeeds leaves one file behind" \
   "$(ls -A "$T/clean" | wc -l | tr -d ' ')" "1"

# =====================================================================
# The other build.sh, and the source file it removed
# =====================================================================
# There used to be two programs called build.sh here and they took different
# things: one assembled an app, the other assembles the site. From inside
# pages/, `./build.sh demo.js demo.cmd` was the site builder with `demo.js` as
# its output directory, and it removed pages/demo.js and left an empty directory
# in its place. Measured, twice, by somebody reading the other one's usage line.
#
# The name collision is gone -- an app is assembled by neutrino/assemble.sh --
# but the shape of the mistake is not, because pages/build.sh still starts by
# removing the directory it is handed.
report "section: pages"
echo "=== the site builder refuses anything it was not meant to remove ==="
PAGES="$ROOT/pages/build.sh"
if [ ! -f "$PAGES" ]; then
    fail "no pages/build.sh in this tree; nothing below is a reading"
else
    rm -rf "$WORK/pagesdir"; mkdir -p "$WORK/pagesdir"
    printf 'keep me\n' > "$WORK/pagesdir/notes.txt"
    bash "$PAGES" "$WORK/pagesdir" > "$WORK/pages.log" 2>&1
    eq "a directory it did not write is refused" "$?" "1"
    eq "and the file in it survives" "$(size "$WORK/pagesdir/notes.txt")" "8"
    printf 'an app\n' > "$WORK/anapp.js"
    bash "$PAGES" "$WORK/anapp.js" "$WORK/out.cmd" > "$WORK/pages2.log" 2>&1
    eq "an app build passed to it is refused" "$?" "1"
    eq "and the app survives" "$(size "$WORK/anapp.js")" "7"
    eq "and it says which program was meant" \
       "$(grep -c 'that is a different program' "$WORK/pages2.log" | head -1)" "1"
fi

# =====================================================================
# The tier list, and how the shell comes to have it
# =====================================================================
# There used to be four `//#` sentinels in the artifact and a section here about
# keeping them intact. They were splice targets: a second program stamped the
# tier list into the JavaScript region, so the shell had to search the built
# file for it and had to be told where to stop looking.
#
# Nothing is stamped. sh/tiers.sh includes config.json as a here document of its
# own, the way sh/qt.sh includes qml/window.qml, so the shell has the value
# rather than going to look for it -- and the JavaScript region has the same
# file, included by the same assembler in the same pass. What that removes is
# not a check but the reason for one.
report "section: tiers"
echo "=== the shell and the javascript carry one file, included twice ==="
T="$(tree tiers)"
nt_d="$(confdir tiers)"
cat > "$nt_d/config.json" <<'EOF'
{
    "tiers": "default,tight,offline",
    "title": "S",
    "width": 900,
    "height": 600,
    "background": "auto",
    "decorations": "auto"
}
EOF
bash "$T/neutrino/assemble.sh" --overlay "$nt_d" --overlay "$APP_TIERS" "$T/out.cmd" >/dev/null 2>&1
eq "a build with a full tier list succeeds" "$?" "0"

eq "the artifact carries no // # markers at all" \
   "$(grep -c '//#' "$T/out.cmd" || true)" "0"

# The two copies, read the way each language reaches its own. The shell's is the
# here document; the JavaScript's is the config object. They are one file, so
# this is asserting the assembler put the same bytes in both places.
nt_shellcopy() {
    sed -n "/<<'NEUTRINO_CONFIG_JSON'/,/^NEUTRINO_CONFIG_JSON\$/p" "$1" |
        sed -e '1d' -e '$d'
}
nt_jscopy() {
    sed -n '/^        config:$/,/^}$/p' "$1" | sed -e '1d'
}
if [ -z "$(nt_shellcopy "$T/out.cmd")" ]; then
    fail "no here document in the shell region; the two readings below measured nothing"
else
    if [ "$(nt_shellcopy "$T/out.cmd")" = "$(nt_jscopy "$T/out.cmd")" ]; then
        pass "the shell's copy and the JavaScript's are the same bytes"
    else
        fail "the two copies of config.json differ"
    fi
fi

# And the app cannot reach either of them. This is the defect the sentinels
# existed for, asserted the other way round: the app carries a line shaped like
# the stamp, and the shell never looks at a file the app is in.
eq "the tier list the shell reads is the config's" \
   "$(nt_shellcopy "$T/out.cmd" | sed -n 's/^ *"tiers": "\([a-z,]*\)".*$/\1/p' | head -1)" \
   "default,tight,offline"

# The shell's sed and the assembler's validator are two programs in two
# languages reading one format, and the shape they accept has to be the same
# shape. It was not: the validator trims a tab as readily as a space, the sed
# was anchored `^ *`, and a config.json indented with tabs therefore validated,
# assembled, and read as nothing -- which is `has_tier` answering false for
# every tier a build had named. Asserted on both indents, and on the value
# rather than on the exit status, because a build that refuses and a build that
# reads an empty list both leave the tier unapplied.
nt_tierof() {
    nt_shellcopy "$1" | sed -n 's/^[[:space:]]*"tiers": "\([a-z,]*\)".*$/\1/p' | head -1
}
for nt_indent in spaces tabs; do
    nt_d="$(confdir indent)"
    if [ "$nt_indent" = tabs ]; then nt_pad="$(printf '\t')"; else nt_pad="    "; fi
    {
        printf '{\n'
        printf '%s"tiers": "default,tight",\n' "$nt_pad"
        printf '%s"title": "S",\n' "$nt_pad"
        printf '%s"width": 900,\n' "$nt_pad"
        printf '%s"height": 600,\n' "$nt_pad"
        printf '%s"background": "auto",\n' "$nt_pad"
        printf '%s"decorations": "auto"\n' "$nt_pad"
        printf '}\n'
    } > "$nt_d/config.json"
    rm -f "$T/indent.cmd"
    bash "$T/neutrino/assemble.sh" --overlay "$nt_d" "$T/indent.cmd" >/dev/null 2>&1
    eq "a config indented with $nt_indent builds" "$?" "0"
    eq "and the shell reads its tier list ($nt_indent)" \
       "$(nt_tierof "$T/indent.cmd")" "default,tight"
done

# config.json is in the shell region now, which is inside the block comment the
# whole file opens with and above the doctype the document is cut from. Two
# sequences it therefore may not carry, and neither is escapable.
badconf_shape() {
    nt_name="$1"; nt_d="$(confdir shape)"
    cat > "$nt_d/config.json"
    rm -f "$T/shape.cmd"
    bash "$T/neutrino/assemble.sh" --overlay "$nt_d" "$T/shape.cmd" > "$WORK/shape.log" 2>&1
    if [ "$?" = "0" ]; then
        fail "$nt_name was accepted"
    else
        pass "$nt_name is refused"
    fi
    eq "and no artifact is left behind ($nt_name)" "$(size "$T/shape.cmd")" "missing"
}
badconf_shape "a title closing the block comment" <<'EOF'
{
    "tiers": "default",
    "title": "done */ here",
    "width": 900,
    "height": 600,
    "background": "auto",
    "decorations": "auto"
}
EOF
badconf_shape "a title naming a doctype" <<'EOF'
{
    "tiers": "default",
    "title": "about <!doctype html>",
    "width": 900,
    "height": 600,
    "background": "auto",
    "decorations": "auto"
}
EOF

# =====================================================================
# The config the app declares
# =====================================================================
# Five window values and the tier list, laid in verbatim because JSON is a
# JavaScript object literal. There is no serializer, so nothing here can write a
# value differently from the way the author spelled it -- and nothing needs a
# read-back to say it landed, which is what most of this file used to be.
#
# What is left is refusing a shape the launcher could not use. Every one of
# these produces a valid artifact that is quietly wrong if it is let through.
report "section: config"
echo "=== a config the launcher could not use is refused ==="
T="$(tree config)"
BASE_TIERS="$(default_of tiers)"

# Written as one string so a case is one line and reads as the file it stands
# for. `|` separates the six values in the order they appear in config.json.
mkconf() {
    printf '{\n    "tiers": "%s",\n    "title": "%s",\n    "width": %s,\n' "$1" "$2" "$3"
    printf '    "height": %s,\n    "background": "%s",\n    "decorations": "%s"\n}\n' "$4" "$5" "$6"
}
accepts() {
    nt_name="$1"; shift
    nt_d="$(confdir case)"
    mkconf "$@" > "$nt_d/config.json"
    rm -f "$T/out.cmd"
    bash "$T/neutrino/assemble.sh" --overlay "$nt_d" "$T/out.cmd" > "$WORK/conf.log" 2>&1
    if [ "$?" != "0" ]; then
        fail "$nt_name was refused: $(sed -n '1p' "$WORK/conf.log")"
    else
        pass "$nt_name builds"
    fi
}
refuses() {
    nt_name="$1"; shift
    nt_d="$(confdir case)"
    mkconf "$@" > "$nt_d/config.json"
    rm -f "$T/out.cmd"
    bash "$T/neutrino/assemble.sh" --overlay "$nt_d" "$T/out.cmd" > "$WORK/conf.log" 2>&1
    if [ "$?" = "0" ]; then
        fail "$nt_name was accepted"
    elif ! grep -q 'config.json' "$WORK/conf.log"; then
        fail "$nt_name was refused without naming the file"
    else
        pass "$nt_name is refused"
    fi
    eq "and no artifact is left behind ($nt_name)" "$(size "$T/out.cmd")" "missing"
}

# The control first: the ordinary case has to build, or every refusal below is
# also what a checker that refuses everything reports.
accepts "an ordinary config" "default" "Sample" 1024 768 "#12141a" "auto"
accepts "a config naming every tier" "default,tight,offline,testing" "S" 10 20 "auto" "none"
for nt_bg in '#12141a' '#FFF' '#000000' '#AbCdEf' 'auto'; do
    accepts "the background $nt_bg" "default" "S" 900 600 "$nt_bg" "auto"
done

# The background, which is the config value with a shape. `system`, `theme` and
# `none` are in here because they are what somebody reaches for when `auto` is
# the word they half-remember, and a build that took one and painted white would
# be the value failing silently: every lane declines to paint a colour it cannot
# read, so the window comes up in the theme colour, which is the bug the value
# exists to close reached by a different route and with nothing said.
for nt_bg in 'white' 'rgb(1,2,3)' '#12' '#1234' '#12345' '#1234567' '12141a' '#12141g' \
             'system' 'theme' 'none' 'Auto' 'AUTO' ''; do
    refuses "the background [${nt_bg:-empty}]" "default" "S" 900 600 "$nt_bg" "auto"
done

# The frame, which is the value whose wrong answers are all words. Every lane
# compares against `none` and keeps its frame for anything else, so a
# misspelling is not a build that fails, it is a build that comes up with the
# title bar the config asked to remove and says nothing at all. `false`, `off`,
# `no` and `0` are what somebody reaches for who is thinking of a boolean;
# `frameless`, `chromeless` and `borderless` are what somebody reaches for who
# is thinking of another launcher.
for nt_dec in auto none; do
    accepts "the decorations $nt_dec" "default" "S" 900 600 "auto" "$nt_dec"
done
for nt_dec in 'false' 'off' 'no' '0' 'true' 'on' 'yes' '1' \
              'frameless' 'chromeless' 'borderless' 'None' 'NONE' 'system' ''; do
    refuses "the decorations [${nt_dec:-empty}]" "default" "S" 900 600 "auto" "$nt_dec"
done

# The size. Zero is the one that matters: a window sized zero is a launch that
# comes up with nothing on screen and no error anywhere, and it is the floor the
# message parser already holds resize to.
for nt_size in "0 600" "900 0" "-1 600" "9.5 600" "tall 600" '"900" 600'; do
    set -- $nt_size
    refuses "the size [$1 x $2]" "default" "S" "$1" "$2" "auto" "auto"
done
accepts "a one-pixel window" "default" "S" 1 1 "auto" "auto"

# The tier list. `default` is not optional and it is not added: build.sh used to
# put it in front of whatever it was handed, which meant the list in the
# artifact was not the list anyone wrote. A file that declares the confinement
# declares all of it.
refuses "a tier list without default" "tight" "S" 900 600 "auto" "auto"
refuses "an unknown tier" "default,paranoid" "S" 900 600 "auto" "auto"
refuses "a tier named twice" "default,tight,tight" "S" 900 600 "auto" "auto"
refuses "an empty tier list" "" "S" 900 600 "auto" "auto"
refuses "an empty title" "default" "" 900 600 "auto" "auto"

# The shapes that are not a flat object of the six keys. There is no merge in
# the assembler -- an overlay replaces config.json whole -- so a file naming
# only a title would take the rest from nowhere.
badconf() {
    nt_name="$1"; nt_d="$(confdir case)"
    cat > "$nt_d/config.json"
    rm -f "$T/out.cmd"
    bash "$T/neutrino/assemble.sh" --overlay "$nt_d" "$T/out.cmd" > "$WORK/conf.log" 2>&1
    if [ "$?" = "0" ]; then fail "$nt_name was accepted"; else pass "$nt_name is refused"; fi
}
badconf "a config missing a key" <<'EOF'
{
    "tiers": "default",
    "title": "S"
}
EOF
badconf "a config naming an unknown key" <<'EOF'
{
    "tiers": "default",
    "title": "S",
    "width": 900,
    "height": 600,
    "background": "auto",
    "decorations": "auto",
    "url": "https://example.invalid/"
}
EOF
badconf "a config naming a key twice" <<'EOF'
{
    "tiers": "default",
    "title": "S",
    "title": "T",
    "width": 900,
    "height": 600,
    "background": "auto",
    "decorations": "auto"
}
EOF
badconf "a config that is not an object" <<'EOF'
"just a string"
EOF
badconf "a config with something after the close" <<'EOF'
{
    "tiers": "default",
    "title": "S",
    "width": 900,
    "height": 600,
    "background": "auto",
    "decorations": "auto"
}
trailing
EOF
badconf "an empty config" <<'EOF'
EOF

# And the artifact a good config produces is JavaScript. The way this went wrong
# before produced a file no engine could parse from an assembler that exited 0:
# `height` was the last key when its rule was written, so the rule printed no
# comma, and `background` arrived after it. Measured on cjs: `SyntaxError:
# missing } after property list`. Nothing writes the punctuation now -- the file
# is copied in whole -- and this is the line that says the copy is a literal.
nt_d="$(confdir good)"
mkconf "default,tight" "A Title" 10 20 "#010203" "none" > "$nt_d/config.json"
bash "$T/neutrino/assemble.sh" --overlay "$nt_d" "$T/good.cmd" >/dev/null 2>&1
eq "a full config builds" "$?" "0"
for nt_pair in "tiers:default,tight" "title:A Title" "width:10" "height:20" \
               "background:#010203" "decorations:none"; do
    eq "the ${nt_pair%%:*} reaches the artifact" \
       "$(conf "$T/good.cmd" "${nt_pair%%:*}")" "${nt_pair#*:}"
done
if command -v node >/dev/null 2>&1; then
    cp "$T/good.cmd" "$T/good.js"
    node --check "$T/good.js" >/dev/null 2>&1
    eq "and the artifact still parses as JavaScript" "$?" "0"
else
    report "node absent: the config artifact was not parsed"
fi

# A title carrying a quote or a backslash was refused by build.sh, because it
# was stamped into a JavaScript string literal as raw text. JSON escapes what a
# JavaScript string escapes, so the author's own escaping is the answer and
# there is nothing here to get wrong.
nt_d="$(confdir quoted)"
cat > "$nt_d/config.json" <<'EOF'
{
    "tiers": "default",
    "title": "He said \"hello\" \\ goodbye",
    "width": 900,
    "height": 600,
    "background": "auto",
    "decorations": "auto"
}
EOF
bash "$T/neutrino/assemble.sh" --overlay "$nt_d" "$T/quoted.cmd" >/dev/null 2>&1
eq "a title carrying a quote and a backslash builds" "$?" "0"
if command -v node >/dev/null 2>&1; then
    cp "$T/quoted.cmd" "$T/quoted.js"
    node --check "$T/quoted.js" >/dev/null 2>&1
    eq "and the artifact still parses as JavaScript" "$?" "0"
fi

# =====================================================================
# What the early shell may not carry
# =====================================================================
# Each of these produces a different broken artifact if it is let through. The
# star-slash is the one that matters most: every engine but jsc reads the whole
# shell region as one block comment, so a close in the document spills the shell
# into four JavaScript parsers at once -- and the file still looks like a
# neutrino app.
report "section: early-shell-refusals"
echo "=== the sequences that are this file's structure are refused ==="
T="$(tree shell-refuse)"
shellrefuses() {
    nt_name="$1"; nt_part="$2"
    nt_d="$WORK/sr"; rm -rf "$nt_d"; mkdir -p "$nt_d"
    cat > "$nt_d/$nt_part"
    rm -f "$T/out.cmd"
    bash "$T/neutrino/assemble.sh" --overlay "$nt_d" "$T/out.cmd" > "$WORK/refuse.log" 2>&1
    if [ "$?" = "0" ]; then
        fail "$nt_name was accepted"
    elif ! grep -q 'the early shell contains' "$WORK/refuse.log"; then
        fail "$nt_name was refused without saying why"
    else
        pass "$nt_name is refused ($(sed -n 's/.*contains `\([^`]*\)`.*/\1/p' "$WORK/refuse.log" | head -1))"
    fi
    eq "and no artifact is left behind ($nt_name)" "$(size "$T/out.cmd")" "missing"
}
# The pair has to survive comment removal to be a hazard, so it is written
# inside a string rather than inside a comment -- a comment carrying it would be
# taken off by the strip and prove nothing.
shellrefuses "a style closing the block comment" style.css <<'EOF'
p::after{content:"*/"}
EOF
shellrefuses "a body opening a script" body.html <<'EOF'
<p>x</p><script>alert(1)</script>
EOF
shellrefuses "a body naming a second doctype" body.html <<'EOF'
<p><!doctype html></p>
EOF
shellrefuses "a body carrying a second policy" body.html <<'EOF'
<meta http-equiv="Content-Security-Policy" content="x">
EOF

# The control: an ordinary style and an ordinary body build, or the four above
# are also what an assembler that refuses every overlay reports.
nt_d="$WORK/sr-ok"; rm -rf "$nt_d"; mkdir -p "$nt_d"
printf 'q{color:green}\n' > "$nt_d/style.css"
printf '<p id=x>hi</p>\n' > "$nt_d/body.html"
bash "$T/neutrino/assemble.sh" --overlay "$nt_d" "$T/ok.cmd" >/dev/null 2>&1
eq "an ordinary early shell builds" "$?" "0"
DOCREGION() {
    sed -n '/^<!doctype html><html>/,/^<script type=text\/javascript>/p' "$1"
}
eq "and the style is the one that was given" \
   "$(DOCREGION "$T/ok.cmd" | grep -c 'q{color:green}' | head -1)" "1"
eq "and the body is the one that was given" \
   "$(DOCREGION "$T/ok.cmd" | grep -c '<p id=x>hi</p>' | head -1)" "1"
# The content policy is the launcher's own, carried through rather than written
# by the assembler, because the offline tier is one string replace against it. A
# second spelling would be one that can drift, and the drift shows up as a build
# that refuses at launch instead of at assembly.
eq "and the policy the offline tier swaps is there exactly once" \
   "$(DOCREGION "$T/ok.cmd" | grep -c 'Content-Security-Policy' | head -1)" "1"

# =====================================================================
# What the artifact reads back at launch
# =====================================================================
# The launcher itself, not an expression lifted out of it -- and neither launch
# below is allowed to reach an engine.
#
# The first draft ran the artifact as it is and bounded it with a sleep-and-kill
# beside a `wait`. That is what took the Windows lane from twelve minutes to
# fifty and then lost the runner: the lane published nothing at all, so which
# step blocked is not even readable after the fact. Two rules out of it. A suite
# may not start a program whose exit it does not control, and a step that runs
# one needs the `timeout-minutes` every other step in that lane already had.
#
# So the engine search is substituted out of both artifacts, one line, the way
# navrefuse.sh substitutes the line it is measuring. What is left runs the tier
# read and then stops with a marker, which is a *stronger* control than the old
# one: `rc=3` says execution reached the search, and not merely that the refusal
# did not print.
report "launch section: substituting the engine search"
echo "=== an artifact whose tier list cannot be read does not launch at default ==="
T="$(tree runtime)"
nt_d="$(confdir runtime)"
mkconf "default,tight,offline" "S" 900 600 "auto" "auto" > "$nt_d/config.json"
bash "$T/neutrino/assemble.sh" --overlay "$nt_d" --overlay "$APP_TIERS" "$T/out.cmd" >/dev/null 2>&1
eq "the tier list the shell would read is the config's" \
   "$(conf "$T/out.cmd" tiers)" "default,tight,offline"

# The anchor is the reserved-status assignment rather than a `command -v` line,
# because there is no longer one line that names the engine. The search is a
# walk over four interpreter names and three more lanes, and the first thing it
# does is declare the status a lane uses to say it could not start -- so this is
# both unique and the earliest point that is unambiguously "about to choose an
# engine". Inserting the halt above it still stops before anything is launched.
SEARCH='nt_ex_noengine=69'
HITS="$(grep -cF "$SEARCH" "$T/out.cmd" | head -1)"
# Two, and not one: config.json is included into the shell region as a here
# document and into the JavaScript region as the config object. Asserted rather
# than tolerated, because one copy would mean an include stopped resolving and
# a third would mean something is writing the file that should not be.
STAMP_LINE='    "tiers": "default,tight,offline",'
STAMP_HITS="$(grep -cF "$STAMP_LINE" "$T/out.cmd" | head -1)"
if [ "${HITS:-0}" != "1" ] || [ "${STAMP_HITS:-0}" != "2" ]; then
    fail "the launcher was rewritten and this suite was not: engine search x${HITS:-0}, tier list x${STAMP_HITS:-0}, wanted 1 and 2"
else
    # Stops where the engine would have been chosen. Both artifacts get it, so
    # the only difference between the two readings is the stamp.
    halt() {
        awk -v find="$SEARCH" '
            !done && index($0, find) {
                print "echo \"assemble: reached the engine search\" >&2; exit 3"
                done = 1
            }
            { print }
        ' "$1" > "$2"
    }
    halt "$T/out.cmd" "$T/intact.cmd"
    # Both copies, because the shell reads its own and the assertion below is
    # about the shell. A file with one of the two mangled is a file nothing in
    # this tree can produce.
    sed 's/^    "tiers": "default,tight,offline",$/    "tiers" : "unreadable",/' \
        "$T/intact.cmd" > "$T/mangled.cmd"

    bash "$T/mangled.cmd" > "$WORK/mangled.log" 2>&1
    eq "an unreadable tier list refuses to launch" "$?" "1"
    eq "and says so" "$(grep -c 'no readable tier list' "$WORK/mangled.log" | head -1)" "1"
    eq "and it stopped before the engine search" \
       "$(grep -c 'reached the engine search' "$WORK/mangled.log" | head -1)" "0"

    # The control. Same artifact, stamp intact: it must get past the read and
    # all the way to where an engine would be chosen. Without it, "the refusal
    # did not print" is also what a launcher that never started reports.
    bash "$T/intact.cmd" > "$WORK/intact.log" 2>&1
    eq "a readable tier list runs on to the engine search" "$?" "3"
    eq "and never took the refusal branch" \
       "$(grep -c 'no readable tier list' "$WORK/intact.log" | head -1)" "0"
fi

# =====================================================================
# The sugar the suite builds its apps with
# =====================================================================
# test/mkapp.sh writes the overlay a one-file app would otherwise be a directory
# for, and it is what every other suite in this tree calls. Its defaults come
# out of neutrino/config.json rather than being written in it, so the two cannot
# drift; this is the line that says the reading works at all.
report "section: mkapp"
echo "=== the test helper writes the overlay it says it does ==="
MK="$ROOT/test/mkapp.sh"
if [ ! -f "$MK" ]; then
    fail "no test/mkapp.sh in this tree; every other suite builds with it"
else
    printf 'document.title = "example";\n' > "$WORK/plainapp.js"
    bash "$MK" "$WORK/plainapp.js" "$WORK/mk-default.cmd" > "$WORK/mk.log" 2>&1
    eq "a build with no flags succeeds" "$?" "0"
    for nt_key in tiers title width height background decorations; do
        eq "and $nt_key is the tree's default" \
           "$(conf "$WORK/mk-default.cmd" "$nt_key")" "$(default_of "$nt_key")"
    done
    eq "and the app is in it" \
       "$(grep -c 'document.title = "example";' "$WORK/mk-default.cmd" | head -1)" "1"

    # --tier is sugar and adds `default`, the way build.sh's flag did. The
    # assembler itself refuses a list that leaves it out rather than adding it.
    bash "$MK" --tier=testing "$WORK/plainapp.js" "$WORK/mk-tier.cmd" >/dev/null 2>&1
    eq "--tier=testing means testing as well as default" \
       "$(conf "$WORK/mk-tier.cmd" tiers)" "default,testing"
    bash "$MK" --tier=testing,offline "$WORK/plainapp.js" "$WORK/mk-two.cmd" >/dev/null 2>&1
    eq "and two of them compose" \
       "$(conf "$WORK/mk-two.cmd" tiers)" "default,testing,offline"

    bash "$MK" --title "My App" --size 1024x768 --background '#12141a' --decorations=none \
        "$WORK/plainapp.js" "$WORK/mk-full.cmd" >/dev/null 2>&1
    eq "a full set of flags builds" "$?" "0"
    for nt_pair in "title:My App" "width:1024" "height:768" \
                   "background:#12141a" "decorations:none"; do
        eq "and the ${nt_pair%%:*} reaches the artifact" \
           "$(conf "$WORK/mk-full.cmd" "${nt_pair%%:*}")" "${nt_pair#*:}"
    done

    # A bad value goes to the assembler and is refused there, so the helper has
    # no second copy of the rules to keep right.
    rm -f "$WORK/mk-bad.cmd"
    bash "$MK" --background 'chartreuse' "$WORK/plainapp.js" "$WORK/mk-bad.cmd" >/dev/null 2>&1
    eq "a bad value is refused" "$?" "1"
    eq "and no artifact is left behind" "$(size "$WORK/mk-bad.cmd")" "missing"

    # And an overlay passed through it still applies, which is how a case builds
    # one app against two different early shells.
    nt_d="$WORK/mk-ov"; rm -rf "$nt_d"; mkdir -p "$nt_d"
    printf 'passed-through{color:red}\n' > "$nt_d/style.css"
    bash "$MK" --overlay "$nt_d" "$WORK/plainapp.js" "$WORK/mk-ov.cmd" >/dev/null 2>&1
    eq "an overlay passed through the helper applies" \
       "$(grep -c 'passed-through' "$WORK/mk-ov.cmd" | head -1)" "1"
    eq "and the app it wrote still wins" \
       "$(grep -c 'document.title = "example";' "$WORK/mk-ov.cmd" | head -1)" "1"
fi

echo
if [ "$FAILURES" = "0" ]; then
    echo "assembler assertions passed"
    exit 0
fi
echo "$FAILURES assertion(s) failed"
exit 1
