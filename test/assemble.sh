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
document.title = myConfig.name;
EOF
cat > "$WORK/app-plain.js" <<'EOF'
document.title = "example";
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
sed 's|^\( *\)//#RUNWEB_START$|\1// removed by assemble.sh|' "$T/webview.cmd" > "$T/broken.cmd"
mv "$T/broken.cmd" "$T/webview.cmd"
bash "$T/build.sh" --tier=tight "$WORK/app-plain.js" "$T/out.cmd" > "$WORK/marker.log" 2>&1
eq "a template missing a marker is refused" "$([ "$?" -eq 0 ] && echo built || echo refused)" "refused"
eq "and no artifact is left behind" "$(size "$T/out.cmd")" "missing"

T="$(tree appmarker)"
printf 'document.title = "x";\n//#RUNWEB_END\n' > "$WORK/app-marker.js"
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

# The read-back, asserted the way every other check in this file is: against a
# template it cannot apply to. A document line with no style to replace used to
# be nothing at all -- awk matched, printed a composed line, and the build went
# on -- so this is the case that says the read-back is doing work.
T="$(tree shell-readback)"
sed 's|^\(<!doctype html><html>\).*$|\1<head></head>|' "$T/webview.cmd" > "$T/w.tmp"
mv "$T/w.tmp" "$T/webview.cmd"
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
