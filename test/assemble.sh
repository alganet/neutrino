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
window.neutrino.window.setTitle(myConfig.name);
EOF
cat > "$WORK/app-plain.js" <<'EOF'
window.neutrino.window.setTitle("example");
EOF
APP_TIERS_BYTES="$(size "$WORK/app-tiers.js")"
TPL_BYTES="$(size "$ROOT/webview.cmd")"

# A fresh copy of the tree per case, because half of these destroy the template
# they are handed. build.sh takes its template from beside itself, which is what
# makes "the output is the template" expressible at all.
tree() {
    rm -rf "$WORK/$1"
    mkdir -p "$WORK/$1"
    cp "$ROOT/build.sh" "$ROOT/webview.cmd" "$WORK/$1/"
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

# What ships may not change. Every app CI builds, from both assemblers, byte for
# byte -- a repair that fixes the check by changing the artifact is a different
# PR, and this is the line that would say so.
report "section: byte-identity"
echo "=== the artifacts CI builds are unchanged ==="
for spec in "default:neutrinotest" "testing:neutrinoloaders" "tight,offline:neutrinooffline" "testing:neutrinoearly"; do
    tier="${spec%%:*}"; app="$ROOT/test/${spec#*:}.js"
    if [ ! -f "$app" ]; then
        fail "$(basename "$app") is not in this tree; the comparison below measured nothing"
        continue
    fi
    T="$(tree ident)"
    bash "$T/oldbuild.sh" --tier="$tier" "$app" "$T/old.cmd" > /dev/null 2>&1
    bash "$T/build.sh"    --tier="$tier" "$app" "$T/new.cmd" > /dev/null 2>&1
    if cmp -s "$T/old.cmd" "$T/new.cmd"; then
        pass "$(basename "$app" .js) at --tier=$tier is byte-identical"
    else
        fail "$(basename "$app" .js) at --tier=$tier changed ($(size "$T/old.cmd") -> $(size "$T/new.cmd"))"
    fi
done

# =====================================================================
# The output named as the template
# =====================================================================
report "section: output-as-template"
echo "=== the output may not be the template ==="
T="$(tree oldclobber)"
bash "$T/oldbuild.sh" --tier=tight "$WORK/app-tiers.js" "$T/webview.cmd" > "$WORK/oc.log" 2>&1
OC_RC=$?
OC_TPL="$(size "$T/webview.cmd")"
report "before: rc=$OC_RC template=$OC_TPL/$TPL_BYTES"
eq "before, it destroyed the template" "$([ "$OC_TPL" = "$TPL_BYTES" ] && echo intact || echo destroyed)" "destroyed"
eq "before, it said nothing about it" "$OC_RC" "0"

T="$(tree newclobber)"
bash "$T/build.sh" --tier=tight "$WORK/app-tiers.js" "$T/webview.cmd" > "$WORK/nc.log" 2>&1
eq "after, it refuses" "$([ "$?" -eq 0 ] && echo built || echo refused)" "refused"
eq "after, the template is untouched" "$(size "$T/webview.cmd")" "$TPL_BYTES"
eq "after, it says which name is the problem" \
   "$(grep -c 'the output is one of the inputs' "$WORK/nc.log" | head -1)" "1"

# The same opening with an app carrying no stamp line: the before-state exits 1
# here, and then removes the template it has already truncated. Both destroy it;
# this is the half that at least says so, and it is still a destroyed template.
T="$(tree oldclobber2)"
bash "$T/oldbuild.sh" --tier=tight "$WORK/app-plain.js" "$T/webview.cmd" > /dev/null 2>&1
eq "before, an app with no stamp line lost the template as well" "$(size "$T/webview.cmd")" "missing"

# =====================================================================
# The output named as the app
# =====================================================================
report "section: output-as-app"
echo "=== the output may not be the app ==="
T="$(tree oldself)"
cp "$WORK/app-tiers.js" "$T/a.js"
bash "$T/oldbuild.sh" --tier=tight "$T/a.js" "$T/a.js" > /dev/null 2>&1
OS_RC=$?
OS_SIZE="$(size "$T/a.js")"
report "before: rc=$OS_RC app=$OS_SIZE was=$APP_TIERS_BYTES"
# Asserted as "not the app any more" and never to a length. What comes out is the
# assembler reading back its own output while it writes it, and the length is not
# a property of the inputs: 213225 on three lanes against 164073 on the Windows
# one, and it moved by exactly the bytes the template grew between two rounds.
# Whatever decides it, it is not this suite's to predict.
eq "before, the app was overwritten" "$([ "$OS_SIZE" = "$APP_TIERS_BYTES" ] && echo intact || echo overwritten)" "overwritten"
eq "before, it said nothing about it" "$OS_RC" "0"

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
sed 's|^\( *\)//#RUNWEB_START$|\1// removed by assemble.sh|' "$T/webview.cmd" > "$T/broken.cmd"
mv "$T/broken.cmd" "$T/webview.cmd"
bash "$T/build.sh" --tier=tight "$WORK/app-plain.js" "$T/out.cmd" > "$WORK/marker.log" 2>&1
eq "a template missing a marker is refused" "$([ "$?" -eq 0 ] && echo built || echo refused)" "refused"
eq "and no artifact is left behind" "$(size "$T/out.cmd")" "missing"

T="$(tree appmarker)"
printf 'window.neutrino.window.setTitle("x");\n//#RUNWEB_END\n' > "$WORK/app-marker.js"
bash "$T/build.sh" --tier=tight "$WORK/app-marker.js" "$T/out.cmd" > "$WORK/appmarker.log" 2>&1
eq "an app carrying a marker line is refused" "$([ "$?" -eq 0 ] && echo built || echo refused)" "refused"
eq "and no artifact is left behind" "$(size "$T/out.cmd")" "missing"
eq "and the temporary file is not left behind either" \
   "$(ls "$T" | grep -c '\.tmp\.' | head -1)" "0"

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

SEARCH='if command -v gjs >/dev/null 2>&1'
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

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "=== Results: $FAILURES failure(s) ==="
    exit 1
fi
echo "=== Results: assembler assertions passed ==="
exit 0
