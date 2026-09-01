#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# assemble.sh - the assembler's inputs, and the stamp it says it applied.
#
# build.sh is the program every other suite's artifact comes out of, and it
# carries the one check in this tree whose job is to say that a build did not
# quietly produce a weaker file than the one that was asked for. That check
# used to read the *first* line in the output shaped like the stamp, and the
# app spliced into the output is arbitrary JavaScript that may carry one. So
# the check could be answered by the thing it was checking, and three openings
# went through it:
#
#   the output as the template   `> "$OUTPUT"` is set up before the pipeline
#                                reads the template, so naming the template as
#                                the output truncated it, spliced nothing, and
#                                exited 0 with the app's own line standing in
#                                for the stamp. With an app carrying no such
#                                line it exited 1 and deleted the template.
#                                The template is assembled into a temporary now
#                                and that exact name cannot be given any more,
#                                so what stands in its place is the source tree
#                                it is assembled from -- the same opening in a
#                                worse shape, since a build that truncates
#                                neutrino/js/message.js leaves nothing to
#                                reassemble from at all.
#   the output as the app        the redirection belongs to the `sed` on the
#                                right of the pipeline and the `cat` on the left
#                                runs beside it, so the assembler read back what
#                                it had already written.
#   the app's own source         the substitution had no range, so it rewrote
#                                every line in the stream shaped like the stamp.
#
# And the artifact's own shell region read the stamp the same way, with an empty
# read falling back to "default" -- the weakest tier this file has.
#
# The before-state is an artifact here and not a sentence. `oldbuild.sh` below
# is the assembler as it shipped through PR 23, and every defect above is
# asserted to reproduce against it in the same run that asserts the fix closes
# it. "It would have failed before" is a claim until something runs it, and this
# runs it on every push. The day a platform makes the old spelling behave
# differently, this goes red and says which half moved.
#
# Two controls, because a refusal that builds nothing is not a pass. `plain`
# says the shipped assembler works on this platform at all, and `old-plain` says
# the before-state assembler does too -- without the second, a before-state that
# simply failed to run would report every defect as reproduced.
#
# No display, no engine, about a second. Usage: assemble.sh

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
# An app carrying a `tiers:` line is not a contrived one -- it is any app with a
# config object that happens to use the name. It is the fixture for most of what
# follows because it is what made the openings above silent. No app in this
# repository carries one today, which is a reason to close this cheaply and not
# a reason to leave it open.
cat > "$WORK/app-tiers.js" <<'EOF'
var myConfig = {
    tiers: "offline,tight",
    name: "example"
};
document.title = myConfig.name;
EOF
cat > "$WORK/app-plain.js" <<'EOF'
document.title = "example";
EOF
APP_TIERS_BYTES="$(size "$WORK/app-tiers.js")"

# A fresh copy of the tree per case, because half of these destroy the source
# they are handed. build.sh takes neutrino/ from beside itself, which is what
# makes "the output is the source" expressible at all.
#
# `webview.cmd` in the copy is not a file this repository has any more. It is
# the launcher as assemble.sh puts it together with its comments left in, and it
# is here for two readers: the frozen before-state assembler below, which knows
# no other way to find a template, and the assertions that ask what value an
# unflagged build inherits. Comments left in on purpose -- the before-state's
# output is compared byte for byte against `build.sh --comments`, and the two
# have to be reading the same bytes for that comparison to mean the splice
# rather than the strip.
tree() {
    rm -rf "$WORK/$1"
    mkdir -p "$WORK/$1"
    cp "$ROOT/build.sh" "$WORK/$1/"
    cp -R "$ROOT/neutrino" "$WORK/$1/"
    bash "$WORK/$1/neutrino/assemble.sh" --comments > "$WORK/$1/webview.cmd"
    cp "$WORK/oldbuild.sh" "$WORK/$1/" 2>/dev/null
    echo "$WORK/$1"
}

# =====================================================================
# The before-state, as an artifact
# =====================================================================
# Verbatim as it shipped through PR 23. It is frozen on purpose: it is not a
# copy of a live program that could drift, it is the state the assertions below
# are measured against.
cat > "$WORK/oldbuild.sh" <<'OLDEOF'
#!/bin/bash
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
STAMPED="$(sed -n 's/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$OUTPUT" | head -1)"
if [ "$STAMPED" != "$TIER" ]; then
    echo "Error: tier stamp did not apply (wanted '$TIER', found '${STAMPED:-nothing}')" >&2
    rm -f "$OUTPUT"
    exit 1
fi
OLDEOF
chmod +x "$WORK/oldbuild.sh"

TPL_BYTES="$(size "$(tree tplsize)/webview.cmd")"

# =====================================================================
# The controls
# =====================================================================
report "section: controls"
echo "=== both assemblers build, on this platform ==="
T="$(tree plain)"
bash "$T/build.sh" --tier=tight "$WORK/app-plain.js" "$T/new.cmd" > "$WORK/plain.log" 2>&1
eq "the shipped assembler builds" "$?" "0"
eq "and stamps what it was asked for" \
   "$(sed -n '/\/\/#TIER_START/,/\/\/#TIER_END/s/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$T/new.cmd" | head -1)" \
   "default,tight"
bash "$T/oldbuild.sh" --tier=tight "$WORK/app-plain.js" "$T/old.cmd" > "$WORK/oldplain.log" 2>&1
eq "the before-state assembler builds too" "$?" "0"

# What ships may not change, and the strip is the one change it is allowed to
# be. Every app CI builds, from both assemblers, byte for byte -- with the
# comments left in on both sides, because that is the comparison that is about
# the splice. A repair that fixes this check by changing the artifact is a
# different PR, and this is the line that would say so.
report "section: byte-identity"
echo "=== the artifacts CI builds are unchanged, comments and all ==="
for spec in "default:neutrinotest" "testing:neutrinoloaders" "tight,offline:neutrinooffline" "testing:neutrinoearly"; do
    tier="${spec%%:*}"; app="$ROOT/test/${spec#*:}.js"
    if [ ! -f "$app" ]; then
        fail "$(basename "$app") is not in this tree; the comparison below measured nothing"
        continue
    fi
    T="$(tree ident)"
    bash "$T/oldbuild.sh" --tier="$tier" "$app" "$T/old.cmd" > /dev/null 2>&1
    bash "$T/build.sh" --comments --tier="$tier" "$app" "$T/new.cmd" > /dev/null 2>&1
    # Compared with the returns taken off both sides. What is asserted is the
    # splice, and a line ending is not the splice: the frozen assembler leaves
    # whatever the checkout gave it and the shipped one normalises on purpose
    # (see the carriage-return note in neutrino/assemble.sh), so on a CRLF
    # checkout the two differ
    # by one byte per line and by nothing else. Stripping here says that, rather
    # than letting the comparison mean two things at once.
    tr -d '\r' < "$T/old.cmd" > "$T/old.lf"
    tr -d '\r' < "$T/new.cmd" > "$T/new.lf"
    if cmp -s "$T/old.lf" "$T/new.lf"; then
        pass "$(basename "$app" .js) at --tier=$tier is byte-identical"
    else
        fail "$(basename "$app" .js) at --tier=$tier changed ($(size "$T/old.cmd") -> $(size "$T/new.cmd"))"
    fi
done

# And what the strip takes off is prose and nothing else. The stripped artifact
# is asserted against the commented one it was built beside: smaller, carrying
# no line that is only a comment, and every line that is not a comment still
# there in the same order. The last of those is the one that matters -- a strip
# that dropped a line of code would still be smaller and still carry no
# comments.
report "section: strip"
echo "=== the strip removes comments and nothing else ==="
T="$(tree strip)"
bash "$T/build.sh" --comments --tier=testing "$ROOT/test/neutrinotest.js" "$T/full.cmd" >/dev/null 2>&1
bash "$T/build.sh"            --tier=testing "$ROOT/test/neutrinotest.js" "$T/thin.cmd" >/dev/null 2>&1
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
cat > "$WORK/app-spdx.js" <<'EOF'
// SPDX-FileCopyrightText: 2026 Somebody Else <nobody@example.invalid>
// SPDX-License-Identifier: MIT
// An ordinary comment, which is prose and goes.
document.title = "x";
EOF
bash "$T/build.sh" "$WORK/app-spdx.js" "$T/spdx.cmd" >/dev/null 2>&1
eq "the app's licence notice survives the strip" \
   "$(grep -c 'SPDX-License-Identifier: MIT' "$T/spdx.cmd" | head -1)" "1"
eq "and its copyright line does too" \
   "$(grep -c 'nobody@example.invalid' "$T/spdx.cmd" | head -1)" "1"
eq "while the comment beside them does not" \
   "$(grep -c 'An ordinary comment' "$T/spdx.cmd" | head -1)" "0"

# =====================================================================
# The parts, each read by its own language
# =====================================================================
# The split is only worth its shape if a part is a thing an editor, a linter or
# a checker can open. It was not, to begin with: the JavaScript went in as runs
# of `key: value,` entries cut out of the middle of one object literal, and
# every one of the twenty-five files was a syntax error on its own. They are
# `NeutrinoWebview.parseColor = ...` assignments now, and this is the line that
# says so on every push rather than the day somebody notices.
#
# Two files are not documents and are not checked here: html/document.html,
# whose closing tags are the skeleton's last line, and the `.list` manifests,
# which claim no language. neutrino/assemble.sh checks the assembled regions,
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
    if command -v node >/dev/null 2>&1; then
        NT_BAD="$(node -e '
            var fs = require("fs"), vm = require("vm"), path = require("path");
            var bad = [];
            process.argv.slice(1).forEach(function (f) {
                try { new vm.Script(fs.readFileSync(f, "utf8"), { filename: f }); }
                catch (e) { bad.push(path.basename(f)); }
            });
            process.stdout.write(bad.join(" "));
        ' "$T"/neutrino/js/*.js "$T/fragment.js")"
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
    # This is the only place they run. build.sh passes --no-verify, because the
    # answer is a property of neutrino/ and not of the app -- fifty builds out
    # of one tree used to mean fifty node startups, and on the Windows runner
    # that was a step that timed out at five minutes with nothing else wrong.
    bash "$T/neutrino/assemble.sh" > "$T/verified.cmd" 2> "$WORK/verify.log"
    eq "the assembler's own region checks pass" "$?" "0"
    if [ -s "$WORK/verify.log" ]; then
        report "verify said: $(sed -n '1p' "$WORK/verify.log")"
    fi
    # The two lines an object lift anchors on. There are two lifts -- one in
    # test/parse.sh and one in test/verify-windows.ps1 -- and the second is
    # PowerShell, so it only runs on the platform where a mistake is most
    # expensive to find. It anchored on the first `    };` and kept doing so
    # when the object stopped being one literal: the range that used to be the
    # whole launcher became the thirteen lines of the stamped literal, the
    # member list it wanted was not in there, and what said so was a Windows
    # runner an hour later.
    #
    # Asserted on a built artifact rather than on the template, because the app
    # is spliced inside the range both lifts take and an app carrying either
    # line moves where they end.
    bash "$T/build.sh" "$WORK/app-plain.js" "$T/anchors.cmd" >/dev/null 2>&1
    eq "the artifact opens the object on exactly one line" \
       "$(grep -c '^    var NeutrinoWebview = {$' "$T/anchors.cmd" | head -1)" "1"
    eq "and starts it on exactly one line" \
       "$(grep -c '^    NeutrinoWebview\.run();$' "$T/anchors.cmd" | head -1)" "1"

    # The control: a part broken in a way no per-file check would see, since the
    # file it breaks is the one that is never stripped and never parsed.
    T2="$(tree parts-broken)"
    printf 'NeutrinoWebview.nope = function () {\n' >> "$T2/neutrino/js/launch.js"
    bash "$T2/neutrino/assemble.sh" > /dev/null 2>&1
    eq "and a region that does not parse is refused" \
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
# `cmd/launcher.cmd` with a return on the end matched no extension in nt_read,
# the whole batch region went out through the fallback `cat`, and every build
# step on the Windows lane was red behind
# `cat: .../launcher.cmd$'\r': No such file or directory`. Behind that, the
# parts that are never stripped -- the skeleton and the document line -- would
# have kept their returns in a file where everything else had lost them, and
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
    bash "$T/build.sh" --tier=tight "$WORK/app-plain.js" "$T/eol.cmd" > "$WORK/eol.log" 2>&1
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
        bash "$T2/build.sh" --tier=tight "$WORK/app-plain.js" "$T2/eol.cmd" > /dev/null 2>&1
        if cmp -s "$T/eol.cmd" "$T2/eol.cmd"; then
            pass "and it is byte for byte the artifact the unix checkout builds"
        else
            fail "the two checkouts disagree ($(size "$T/eol.cmd") against $(size "$T2/eol.cmd"))"
        fi
    fi
fi

# =====================================================================
# The output named as the source
# =====================================================================
# The before-state is still measured against a template that is a file, because
# that is what it was: `oldbuild.sh` reads `webview.cmd` from beside itself and
# nothing else. What the after-state is asked is the same question in the shape
# it can be asked today -- the source the template is assembled from is a
# directory, and naming anything inside it as the output is the opening the
# monolith had, with no earlier artifact to compare against afterwards.
report "section: output-as-template"
echo "=== the output may not be the template ==="
T="$(tree oldclobber)"
bash "$T/oldbuild.sh" --tier=tight "$WORK/app-tiers.js" "$T/webview.cmd" > "$WORK/oc.log" 2>&1
OC_RC=$?
OC_TPL="$(size "$T/webview.cmd")"
report "before: rc=$OC_RC template=$OC_TPL/$TPL_BYTES"
eq "before, it destroyed the template" "$([ "$OC_TPL" = "$TPL_BYTES" ] && echo intact || echo destroyed)" "destroyed"
eq "before, it said nothing about it" "$OC_RC" "0"

# The same opening with an app carrying no stamp line: the before-state exits 1
# here, and then removes the template it has already truncated. Both destroy it;
# this is the half that at least says so, and it is still a destroyed template.
T="$(tree oldclobber2)"
bash "$T/oldbuild.sh" --tier=tight "$WORK/app-plain.js" "$T/webview.cmd" > /dev/null 2>&1
eq "before, an app with no stamp line lost the template as well" "$(size "$T/webview.cmd")" "missing"

echo "=== the output may not be anywhere in the source tree ==="
# Three names, because the refusal is about the directory and not about a file:
# a part that exists, a part that does not, and the include list itself. Each
# one would be truncated before it was read.
for nt_out in "neutrino/js/message.js" "neutrino/js/nothing-here.js" "neutrino/skeleton.cmd"; do
    T="$(tree newclobber)"
    NT_WAS="$(size "$T/$nt_out")"
    bash "$T/build.sh" --tier=tight "$WORK/app-tiers.js" "$T/$nt_out" > "$WORK/nc.log" 2>&1
    eq "an output at $nt_out is refused" "$([ "$?" -eq 0 ] && echo built || echo refused)" "refused"
    eq "and $nt_out is untouched" "$(size "$T/$nt_out")" "$NT_WAS"
    eq "and it says the tree is the problem" \
       "$(grep -c 'the output is inside' "$WORK/nc.log" | head -1)" "1"
done

# The control. The refusal is the source tree's and not every path with the word
# in it, or "refused" above is also what a build.sh that refuses everything
# reports.
T="$(tree newclobber-ok)"
mkdir -p "$T/neutrino-apps"
bash "$T/build.sh" --tier=tight "$WORK/app-tiers.js" "$T/neutrino-apps/out.cmd" > /dev/null 2>&1
eq "an output beside the tree still builds" "$?" "0"

# =====================================================================
# The output named as a directory
# =====================================================================
# `mv -f "$TMP" "$OUTPUT"` moves a file into a directory of that name, so an
# output that already existed as one came out as `<dir>/<name>.tmp.<pid>`: not
# at the path that was asked for, under a name that reads as leftover rubbish,
# from a build that exited 0.
report "section: output-as-directory"
echo "=== a directory is not an artifact path ==="
T="$(tree dirout)"
mkdir -p "$T/adir"
bash "$T/build.sh" "$WORK/app-plain.js" "$T/adir" > "$WORK/dirout.log" 2>&1
eq "an output that is a directory is refused" "$([ "$?" -eq 0 ] && echo built || echo refused)" "refused"
eq "and nothing was written into it" "$(ls -A "$T/adir" | wc -l | tr -d ' ')" "0"
eq "and it says what an output is" \
   "$(grep -c 'is a directory' "$WORK/dirout.log" | head -1)" "1"

# =====================================================================
# The other build.sh, and the source file it removed
# =====================================================================
# There are two programs called build.sh here and they take different things.
# The one under test assembles an app -- `build.sh <app.js> <output.cmd>`. The
# one in pages/ assembles the published site and takes at most one argument, the
# directory to write it into, which it removes before it writes anything.
#
# So from inside pages/, `./build.sh demo.js demo.cmd` is the site builder with
# `demo.js` as its output directory: it removed pages/demo.js and left an empty
# directory where the sample app used to be, then failed on the app it could no
# longer read. Measured twice, by somebody reading the other program's usage
# line -- which is the shape of mistake a usage line cannot fix on its own,
# because both programs answer to `./build.sh`.
#
# Asserted here rather than in a suite of its own because it is the same hazard
# the three sections above cover: an output path that is somebody's source.
report "section: pages"
echo "=== the site builder does not remove what it was not given ==="
PAGES="$ROOT/pages/build.sh"
if [ ! -f "$PAGES" ]; then
    fail "no pages/build.sh in this tree; nothing below is a reading"
else
    T="$(tree pages)"
    mkdir -p "$T/site" "$T/notasite"
    printf 'var app = 1;\n' > "$T/notasite/demo.js"
    printf 'x\n' > "$T/afile"
    # Measured rather than written down: what is asserted is that the bytes did
    # not move, and a length in the assertion is a second thing to keep right.
    PAGES_SRC="$(size "$T/notasite/demo.js")"
    PAGES_FILE="$(size "$T/afile")"

    pages_refuses() {
        nt_what="$1"; shift
        bash "$PAGES" "$@" > "$WORK/pages.log" 2>&1
        if [ "$?" = "0" ]; then
            fail "$nt_what was accepted"
        elif ! grep -q '^error:' "$WORK/pages.log"; then
            fail "$nt_what was refused without saying why"
        else
            pass "$nt_what is refused ($(sed -n '1s/^error: //p' "$WORK/pages.log"))"
        fi
    }

    pages_refuses "the app build's two arguments" "$T/site" "out.cmd"
    pages_refuses "an output that is a file"      "$T/afile"
    pages_refuses "a directory holding source"    "$T/notasite"

    eq "and the source it would have removed is still there" \
       "$(size "$T/notasite/demo.js")" "$PAGES_SRC"
    eq "and the file it would have removed is still there" \
       "$(size "$T/afile")" "$PAGES_FILE"

    # The control: an empty directory is a legitimate output and has to get past
    # the guard. It cannot be run to completion on every lane -- the published
    # binaries need zig -- so what is asserted is that the refusal above is
    # about the path and not about every path.
    bash "$PAGES" "$T/site" > "$WORK/pagesok.log" 2>&1
    eq "an empty directory is not refused by the guard" \
       "$(grep -c '^error: .*directory' "$WORK/pagesok.log" | head -1)" "0"
fi

# =====================================================================
# The output named as the app
# =====================================================================
report "section: output-as-app"
echo "=== the output may not be the app ==="
T="$(tree oldself)"
cp "$WORK/app-tiers.js" "$T/a.js"
# Bounded by the kernel and by a clock, and this is the one invocation in the
# suite that needs both.
#
# The old assembler builds `{ sed template; cat "$APP_JS"; sed template; }` into
# a pipeline whose last stage redirects over $OUTPUT -- and here $APP_JS and
# $OUTPUT are the same file. So `cat` reads the bytes the final `sed` is still
# writing, hands them back, and they are written again. Whether that ever
# reaches EOF is a scheduling race between two processes and not a property of
# any input, which is what the note about 213225 against 164073 was already
# saying without naming the mechanism.
#
# The race was winnable while the template was small and stopped being winnable
# when it grew: measured on this machine, 3713 lines of template terminated with
# a 240 KB file and 4281 lines did not terminate at all, having written 2.1 GB in
# twenty-five seconds and still going. That is the suite's own rule being broken
# -- a program whose exit it does not control -- so the exit is controlled here
# rather than hoped for. RLIMIT_FSIZE is the same instrument netinstall uses on
# a downloader that cannot express a bound of its own.
#
# What is asserted does not change, because the runaway was never the finding.
# The finding is that the old assembler destroyed the app it was handed and
# said nothing, and both halves of that are true the instant the redirection
# truncates -- long before the loop this now stops.
#
# The clock is optional and the file bound is not. `timeout` is coreutils, and
# macOS ships neither it nor gtimeout -- there this read rc=127, the assembler
# never ran at all, and the app was therefore still intact, so the before-state
# asserted the exact opposite of the thing it exists to measure. RLIMIT_FSIZE
# needs no such program and is the bound that actually stops this anyway, since
# what runs away here is a file that grows without end.
OS_LOG="$WORK/oldself.log"
OS_CLOCK=""
command -v timeout >/dev/null 2>&1 && OS_CLOCK="timeout 20"
( ulimit -f 8192 2>/dev/null
  exec $OS_CLOCK bash "$T/oldbuild.sh" --tier=tight "$T/a.js" "$T/a.js" ) \
    > "$OS_LOG" 2>&1
OS_RC=$?
OS_SIZE="$(size "$T/a.js")"
report "before: rc=$OS_RC app=$OS_SIZE was=$APP_TIERS_BYTES"
# Asserted as "not the app any more" and never to a length: what the file holds
# is however far the loop above got before it was stopped.
eq "before, the app was overwritten" "$([ "$OS_SIZE" = "$APP_TIERS_BYTES" ] && echo intact || echo overwritten)" "overwritten"
# Read off what it printed rather than off its status. The status is downstream
# of the race -- 0 where cat won, a signal where the bound stopped it -- while
# the refusal it never printed is the thing the after-state adds and is the
# same reading on every lane.
eq "before, it said nothing about it" "$(grep -c '^Error:' "$OS_LOG")" "0"

T="$(tree newself)"
cp "$WORK/app-tiers.js" "$T/a.js"
bash "$T/build.sh" --tier=tight "$T/a.js" "$T/a.js" > /dev/null 2>&1
eq "after, it refuses" "$([ "$?" -eq 0 ] && echo built || echo refused)" "refused"
eq "after, the app is untouched" "$(size "$T/a.js")" "$APP_TIERS_BYTES"

# =====================================================================
# The app's own source
# =====================================================================
report "section: app-source"
echo "=== the assembler does not edit the app it is given ==="
T="$(tree appstamp)"
bash "$T/oldbuild.sh" --tier=tight "$WORK/app-tiers.js" "$T/old.cmd" > /dev/null 2>&1
bash "$T/build.sh"    --tier=tight "$WORK/app-tiers.js" "$T/new.cmd" > /dev/null 2>&1
eq "before, the app's line was rewritten" \
   "$(grep -c '^    tiers: "offline,tight",$' "$T/old.cmd" | head -1)" "0"
eq "after, the app's line is verbatim" \
   "$(grep -c '^    tiers: "offline,tight",$' "$T/new.cmd" | head -1)" "1"
eq "after, there is still exactly one stamp between the sentinels" \
   "$(sed -n '/\/\/#TIER_START/,/\/\/#TIER_END/p' "$T/new.cmd" | grep -c '^ *tiers: "[a-z,]*",' | head -1)" "1"
eq "and it is the tier that was asked for" \
   "$(sed -n '/\/\/#TIER_START/,/\/\/#TIER_END/s/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$T/new.cmd" | head -1)" \
   "default,tight"
# The half the before-state could not tell apart: two stamp-shaped lines in one
# artifact is now the normal case, and the check has to still be the stamp's.
eq "the artifact has two stamp-shaped lines and that is fine" \
   "$(grep -c '^ *tiers: "[a-z,]*",' "$T/new.cmd" | head -1)" "2"

# =====================================================================
# A template, or an app, that is not shaped like one
# =====================================================================
report "section: sentinels"
echo "=== the sentinels are counted before anything is spliced ==="
T="$(tree marker)"
# A template missing a splice marker is not a build that fails: sed prints the
# whole file when a range never matches, and what comes out is the app appended
# past the end of the document.
#
# Taken out of the part that carries it rather than out of an assembled file,
# because an assembled file is not what build.sh reads any more. This is also
# the assertion that the count is run on the assembly and not on the parts: the
# marker is one line of one file in a tree of thirty-eight.
# Unanchored, because a CRLF checkout puts a return between the marker and the
# end of the line and an anchored pattern then matches nothing -- which is a
# suite that quietly measures a build with its marker still in it.
sed 's|^\( *\)//#RUNWEB_START|\1// removed by assemble.sh|' "$T/neutrino/js/run.js" > "$T/broken.js"
mv "$T/broken.js" "$T/neutrino/js/run.js"
bash "$T/build.sh" --tier=tight "$WORK/app-plain.js" "$T/out.cmd" > "$WORK/marker.log" 2>&1
eq "a template missing a marker is refused" "$([ "$?" -eq 0 ] && echo built || echo refused)" "refused"
eq "and no artifact is left behind" "$(size "$T/out.cmd")" "missing"

T="$(tree appmarker)"
printf 'document.title = "x";\n//#RUNWEB_END\n' > "$WORK/app-marker.js"
bash "$T/build.sh" --tier=tight "$WORK/app-marker.js" "$T/out.cmd" > "$WORK/appmarker.log" 2>&1
eq "an app carrying a marker line is refused" "$([ "$?" -eq 0 ] && echo built || echo refused)" "refused"
eq "and no artifact is left behind" "$(size "$T/out.cmd")" "missing"
eq "and no temporary of any of the three kinds is left behind either" \
   "$(ls "$T" | grep -c '\.\(tmp\|tpl\|app\)\.' | head -1)" "0"

# And the same on the way out of a build that worked, which is the half that was
# missing and the half that cost something. build.sh writes three files beside
# the artifact -- the assembled template, the stripped app, and the artifact
# before it is moved into place -- and it used to disarm the trap after the
# move, back when the move had already consumed the only one there was. So a
# successful build left `out.cmd.tpl.NNNN` and `out.cmd.app.NNNN` next to
# `out.cmd`: 153 KB and the app source, under names nobody would think to
# delete. pages/build.sh publishes whatever is in its output directory, so both
# of them went to the website.
T="$(tree tmpclean)"
bash "$T/build.sh" --tier=tight "$WORK/app-plain.js" "$T/out.cmd" > /dev/null 2>&1
eq "a build that works leaves the artifact" "$([ -f "$T/out.cmd" ] && echo yes || echo no)" "yes"
eq "and nothing beside it" \
   "$(ls "$T" | grep -c '\.\(tmp\|tpl\|app\)\.' | head -1)" "0"

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
echo "=== an artifact whose stamp cannot be read does not launch at default ==="
T="$(tree runtime)"
bash "$T/build.sh" --tier=tight,offline "$WORK/app-tiers.js" "$T/out.cmd" > /dev/null 2>&1
eq "the stamp reads back between the sentinels" \
   "$(sed -n '/\/\/#TIER_START/,/\/\/#TIER_END/s/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$T/out.cmd" | head -1)" \
   "default,tight,offline"

# The anchor is the reserved-status assignment rather than a `command -v` line,
# because there is no longer one line that names the engine. The search is a
# walk over four interpreter names and three more lanes, and the first thing it
# does is declare the status a lane uses to say it could not start -- so this is
# both unique and the earliest point that is unambiguously "about to choose an
# engine". Inserting the halt above it still stops before anything is launched.
SEARCH='nt_ex_noengine=69'
HITS="$(grep -cF "$SEARCH" "$T/out.cmd" | head -1)"
STAMP_LINE='        tiers: "default,tight,offline",'
STAMP_HITS="$(grep -cF "$STAMP_LINE" "$T/out.cmd" | head -1)"
if [ "${HITS:-0}" != "1" ] || [ "${STAMP_HITS:-0}" != "1" ]; then
    fail "the launcher was rewritten and this suite was not: engine search x${HITS:-0}, stamp x${STAMP_HITS:-0}, wanted 1 each"
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
    sed 's/^        tiers: "default,tight,offline",$/        tiers : "unreadable",/' "$T/intact.cmd" > "$T/mangled.cmd"

    bash "$T/mangled.cmd" > "$WORK/mangled.log" 2>&1
    eq "an unreadable stamp refuses to launch" "$?" "1"
    eq "and says so" "$(grep -c 'no readable tier stamp' "$WORK/mangled.log" | head -1)" "1"
    eq "and it stopped before the engine search" \
       "$(grep -c 'reached the engine search' "$WORK/mangled.log" | head -1)" "0"

    # The control. Same artifact, stamp intact: it must get past the read and
    # all the way to where an engine would be chosen. Without it, "the refusal
    # did not print" is also what a launcher that never started reports.
    bash "$T/intact.cmd" > "$WORK/intact.log" 2>&1
    eq "a readable stamp runs on to the engine search" "$?" "3"
    eq "and never took the refusal branch" \
       "$(grep -c 'no readable tier stamp' "$WORK/intact.log" | head -1)" "0"
fi

# =====================================================================
# The early shell
# =====================================================================
# Four values that reach the artifact by two different routes -- the style and
# the body as markup on the document line, the title and the size as a stamp
# between the config sentinels -- and every one of them is a text substitution
# with no failure path of its own. A pattern that stops matching produces a file
# that is valid, runs, and quietly carries the template's value instead of the
# author's. That is the whole reason build.sh reads each one back, and this is
# what says the read-back is not itself a no-op.
report "section: early-shell"
echo "=== the shell an app is built with is the shell it gets ==="
T="$(tree shell)"
printf 'a{color:red}\n' > "$T/s.css"
printf '<p id=x>hi</p>\n' > "$T/b.html"
bash "$T/build.sh" --title "Sample" --size 1024x768 \
     --style "$T/s.css" --body "$T/b.html" \
     "$WORK/app-plain.js" "$T/out.cmd" > "$WORK/shell.log" 2>&1
eq "a build with a full shell succeeds" "$?" "0"

docline() { grep -m1 '^<!doctype html><html>' "$1"; }
# Normalised, and that is not tidiness. These assertions used to compare the
# raw remainder of the line -- `"Sample",` quotes and comma included -- so
# adding a key after `height` and moving its comma turned a passing assertion
# into a failing one about punctuation, next to the real defect it was hiding.
# What is being asserted is the value.
conf() {
    sed -n '/\/\/#CONFIG_START/,/\/\/#CONFIG_END/p' "$1" |
        sed -n "s/^ *$2: \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" | head -1
}

eq "the style is the one that was given" \
   "$(docline "$T/out.cmd" | sed -n 's/.*<style>\(.*\)<\/style>.*/\1/p')" "a{color:red}"
eq "the body is the one that was given" \
   "$(docline "$T/out.cmd" | sed -n 's/.*<\/style><\/head><body>//p')" "<p id=x>hi</p>"
eq "the title is stamped between the sentinels" "$(conf "$T/out.cmd" title)" "Sample"
eq "the width is too" "$(conf "$T/out.cmd" width)" "1024"
eq "and the height" "$(conf "$T/out.cmd" height)" "768"
# The content policy is carried over from the template rather than written out
# by the assembler, because the offline tier is one string replace against the
# launcher's own copy of it. A second spelling here is one that can drift, and
# the drift shows up as a build that refuses at launch instead of at assembly.
eq "the policy the offline tier swaps survived the splice" \
   "$(docline "$T/out.cmd" | grep -c 'Content-Security-Policy')" "1"
eq "and the document line is still one line" \
   "$(grep -c '^<!doctype html><html>' "$T/out.cmd")" "1"

# The other half of the same rule, and the one a flag-by-flag assembler gets
# wrong: a value nobody asked to change must come through untouched.
T="$(tree shell-partial)"
TPL_STYLE="$(docline "$T/webview.cmd" | sed -n 's/.*<style>\(.*\)<\/style>.*/\1/p')"
TPL_BODY="$(docline "$T/webview.cmd" | sed -n 's/.*<\/style><\/head><body>//p')"
printf 'b{color:blue}\n' > "$T/s.css"
bash "$T/build.sh" --style "$T/s.css" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
eq "the flag that was given applies" \
   "$(docline "$T/out.cmd" | sed -n 's/.*<style>\(.*\)<\/style>.*/\1/p')" "b{color:blue}"
eq "and the body nobody named keeps the template's" \
   "$(docline "$T/out.cmd" | sed -n 's/.*<\/style><\/head><body>//p')" "$TPL_BODY"
eq "as does the title" "$(conf "$T/out.cmd" title)" "$(conf "$T/webview.cmd" title)"

# =====================================================================
# What the shell may not carry
# =====================================================================
# Each of these is refused rather than escaped, and each produces a different
# broken artifact if it is not. The star-slash is the one that matters most:
# every engine but jsc reads the whole shell region as one block comment, so a
# close in the document line spills 1375 lines of shell into four JavaScript
# parsers at once -- and the file still looks like a neutrino app.
report "section: early-shell-refusals"
echo "=== the sequences that are this file's structure are refused ==="
T="$(tree shell-refuse)"
refuses() {
    nt_name="$1"; nt_flag="$2"; nt_file="$3"
    rm -f "$T/out.cmd"
    bash "$T/build.sh" "$nt_flag" "$nt_file" "$WORK/app-plain.js" "$T/out.cmd" \
        > "$WORK/refuse.log" 2>&1
    if [ "$?" = "0" ]; then
        fail "$nt_name was accepted"
    elif ! grep -q '^Error:' "$WORK/refuse.log"; then
        fail "$nt_name was refused without saying why"
    else
        pass "$nt_name is refused ($(sed -n 's/^Error: [^,]*contains `\([^`]*\)`.*/\1/p' "$WORK/refuse.log" | head -1))"
    fi
    eq "and no artifact is left behind" "$(size "$T/out.cmd")" "missing"
}
printf 'p::after{content:"*/"}\n'                       > "$T/star.css"
printf '<p>x</p><script>alert(1)</script>\n'            > "$T/script.html"
printf '<p><!doctype html></p>\n'                       > "$T/doctype.html"
printf '<meta http-equiv="Content-Security-Policy" content="x">\n' > "$T/policy.html"
refuses "a style closing the block comment"  --style "$T/star.css"
refuses "a body opening a script"            --body   "$T/script.html"
refuses "a body naming a second doctype"     --body   "$T/doctype.html"
refuses "a body carrying a second policy"    --body   "$T/policy.html"

# A CSS comment is ordinary and is removed rather than refused -- an author has
# no reason to expect this file's comment rules to reach into their stylesheet.
# What is refused is what survives the removal.
printf '/* a normal comment */\nq{color:green}\n' > "$T/ok.css"
bash "$T/build.sh" --style "$T/ok.css" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
eq "a stylesheet with an ordinary comment builds" "$?" "0"
eq "and the comment is gone from the document" \
   "$(docline "$T/out.cmd" | grep -c 'a normal comment')" "0"
eq "while the rule after it survived" \
   "$(docline "$T/out.cmd" | grep -c 'q{color:green}')" "1"

# The title is a JavaScript string in live code, not markup, so its rules are
# the string's. Refused for the reason parseMessage drops a malformed record
# rather than repairing it: a window title is not worth a second quoting scheme
# that has to be right.
for nt_bad in 'x"y' 'x\y' ''; do
    rm -f "$T/out.cmd"
    bash "$T/build.sh" --title "$nt_bad" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
    [ "$?" = "0" ] && fail "the title [$nt_bad] was accepted" \
                   || pass "the title [${nt_bad:-empty}] is refused"
done
# The control: a title with neither is the ordinary case and has to build, or
# the three refusals above are also what a flag nobody implemented reports.
bash "$T/build.sh" --title "Ordinary Title" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
eq "an ordinary title builds" "$?" "0"
eq "and reaches the config" "$(conf "$T/out.cmd" title)" "Ordinary Title"
for nt_bad in 0x600 900 900xtall 900x0; do
    rm -f "$T/out.cmd"
    bash "$T/build.sh" --size "$nt_bad" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
    [ "$?" = "0" ] && fail "--size $nt_bad was accepted" \
                   || pass "--size $nt_bad is refused"
done

# The background, which is the one config value with a shape. It is refused here
# rather than at launch because every lane declines to paint a colour it cannot
# read -- so an unreadable one comes up in the theme colour, which is precisely
# the bug the value exists to close, reached by a different route and with
# nothing said on the way.
report "section: background"
echo "=== the background is a colour or it is refused ==="
T="$(tree background)"
for nt_ok in '#12141a' '#FFF' '#000000' '#AbCdEf'; do
    rm -f "$T/out.cmd"
    bash "$T/build.sh" --background "$nt_ok" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
    eq "--background $nt_ok reaches the config" "$(conf "$T/out.cmd" background)" "$nt_ok"
done
# `system`, `theme` and `none` are in here because they are what somebody
# reaches for when `auto` is the word they half-remember, and a build that took
# one and painted white would be this flag failing silently all over again.
for nt_bad in 'white' 'rgb(1,2,3)' '#12' '#1234' '#12345' '#1234567' '12141a' '#12141g' \
              'system' 'theme' 'none' 'Auto' 'AUTO' ''; do
    rm -f "$T/out.cmd"
    bash "$T/build.sh" --background "$nt_bad" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
    [ "$?" = "0" ] && fail "--background [$nt_bad] was accepted" \
                   || pass "--background [${nt_bad:-empty}] is refused"
    eq "and no artifact is left behind" "$(size "$T/out.cmd")" "missing"
done
bash "$T/build.sh" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
eq "a build that names no background keeps the template's" \
   "$(conf "$T/out.cmd" background)" "$(conf "$T/webview.cmd" background)"

# And what the template's is, asserted here rather than inferred from the line
# above -- which passes just as well when both sides are wrong together. `auto`
# is what makes an unflagged build follow the desktop it is launched on, so a
# template that quietly went back to carrying a colour would turn the whole
# feature off and every assertion in this file would still pass.
eq "and the template's is auto, so that build follows the desktop" \
   "$(conf "$T/webview.cmd" background)" "auto"

# `auto` is accepted from the flag as well as by omission, so a script can say
# what it means instead of meaning it by silence. Refusing it would also be a
# build.sh that cannot reproduce its own default.
rm -f "$T/out.cmd"
bash "$T/build.sh" --background auto "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
eq "--background auto reaches the config" "$(conf "$T/out.cmd" background)" "auto"

# The punctuation, asserted directly, because the way it went wrong produced a
# file no engine could parse from an assembler that exited 0. `height` was the
# last key when its rule was written, so the rule printed no comma; `background`
# arrived after it and the object lost the separator between them. Measured on
# cjs: `SyntaxError: missing } after property list`.
bash "$T/build.sh" --title A --size 10x20 --background '#010203' \
     "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
if command -v node >/dev/null 2>&1; then
    cp "$T/out.cmd" "$T/out.js"
    node --check "$T/out.js" >/dev/null 2>&1
    eq "a fully stamped config still parses as JavaScript" "$?" "0"
else
    report "node absent: the stamped config was not parsed"
fi

# The frame, which is the second config value with a shape and the first whose
# wrong answers are all words. It is refused here rather than passed through
# because every lane compares against `none` and keeps its frame for anything
# else -- so a misspelling is not a build that fails, it is a build that comes
# up with the title bar the flag asked to remove and says nothing at all.
report "section: decorations"
echo "=== the decorations are one of two words or they are refused ==="
T="$(tree decorations)"
for nt_ok in auto none; do
    rm -f "$T/out.cmd"
    bash "$T/build.sh" --decorations "$nt_ok" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
    eq "--decorations $nt_ok reaches the config" "$(conf "$T/out.cmd" decorations)" "$nt_ok"
done
# `false`, `off`, `no` and `0` are what somebody reaches for who is thinking of
# a boolean; `frameless`, `chromeless` and `borderless` are what somebody
# reaches for who is thinking of another launcher; `None` and `NONE` are the
# case the background's `Auto` already stands for on the other flag.
for nt_bad in 'false' 'off' 'no' '0' 'true' 'on' 'yes' '1' \
              'frameless' 'chromeless' 'borderless' 'None' 'NONE' 'system' ''; do
    rm -f "$T/out.cmd"
    bash "$T/build.sh" --decorations "$nt_bad" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
    [ "$?" = "0" ] && fail "--decorations [$nt_bad] was accepted" \
                   || pass "--decorations [${nt_bad:-empty}] is refused"
    eq "and no artifact is left behind" "$(size "$T/out.cmd")" "missing"
done
bash "$T/build.sh" "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
eq "a build that names no decorations keeps the template's" \
   "$(conf "$T/out.cmd" decorations)" "$(conf "$T/webview.cmd" decorations)"

# And what the template's is, asserted directly for the reason the background's
# is: a template that quietly shipped `none` would open every unflagged build
# without a title bar, and the line above would pass just as well.
eq "and the template's is auto, so an unflagged build keeps its frame" \
   "$(conf "$T/webview.cmd" decorations)" "auto"

# The punctuation again, with the key that arrives after `background` -- which
# is the position `background` itself was in when the comma bug was written, and
# the position this key inherits. The assertion is here rather than folded into
# the background's because what it guards is the *last* key in the object, and
# that is now this one.
bash "$T/build.sh" --title A --size 10x20 --background '#010203' --decorations none \
     "$WORK/app-plain.js" "$T/out.cmd" >/dev/null 2>&1
if command -v node >/dev/null 2>&1; then
    cp "$T/out.cmd" "$T/out.js"
    node --check "$T/out.js" >/dev/null 2>&1
    eq "a config stamped in every key still parses as JavaScript" "$?" "0"
else
    report "node absent: the fully stamped config was not parsed"
fi

# The read-back, asserted the way every other check in this file is: against a
# template it cannot apply to. A document line with no style to replace used to
# be nothing at all -- awk matched, printed a composed line, and the build went
# on -- so this is the case that says the read-back is doing work.
T="$(tree shell-readback)"
sed 's|^\(<!doctype html><html>\).*$|\1<head></head>|' "$T/neutrino/html/document.html" > "$T/w.tmp"
mv "$T/w.tmp" "$T/neutrino/html/document.html"
bash "$T/build.sh" --title "Sample" "$WORK/app-plain.js" "$T/out.cmd" > "$WORK/rb.log" 2>&1
eq "a template whose document line cannot be taken apart is refused" "$?" "1"
eq "and it says which shape it wanted" \
   "$(grep -c 'no document line this can take apart' "$WORK/rb.log" | head -1)" "1"
eq "and no artifact is left behind" "$(size "$T/out.cmd")" "missing"

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "=== Results: $FAILURES failure(s) ==="
    exit 1
fi
echo "=== Results: assembler assertions passed ==="
exit 0
