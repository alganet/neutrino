#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# navrefuse.sh - the macOS navigation guard refuses, and says that it refused
#
# PR 6 gave the macOS driver a navigation guard: didStartProvisionalNavigation:
# notices a navigation the app did not ask for and stops the load. It shipped
# spelled `webViewRef.stopLoading()`, and JXA runs a zero-argument selector when
# the property is *read* -- so the read stopped the load, yielded undefined, and
# the `()` after it threw having already had its effect. For four PRs the guard
# refused every navigation and logged `could not refuse navigation to ...` every
# time. PR 23 removed the parentheses.
#
# Nothing in this tree could have caught that, and the reason is the point of
# this file. verify-attack.sh records macOS's `nav` as `any` and aims at a host
# that never resolves, so the field is free there whatever the guard does.
# verify-early.sh does aim at a target that answers and does assert `at=held` --
# but with no control, and `held` was the reading before the fix and after it,
# because the guard was working the whole time. A suite that reads the same
# thing on a working build and a broken one is not measuring the build.
#
# So this asserts the two halves separately, and neither alone is the check:
#
#   the effect  a build with the refusal deleted must lose the window, and the
#               shipped build must keep it. Without the control, "the app's
#               document is still there" is also what a build that never
#               navigated anywhere reports.
#   the account the driver must say `refused navigation to`, and must not say
#               `could not refuse`. This is the half that fails before the fix,
#               and it is ground rule 5 -- a guard announcing a failure it did
#               not have is `--info` claiming what did not happen.
#
# What an escape looks like here is not `at=escaped`, which is why the control
# is asserted to three fields and not one. The app's document is destroyed with
# its pending report, and the page that arrives is refused by the sender check
# when it tries to set the title -- so nothing settles, and `at=none` is the
# escape. `at=none` is also what a build that never rendered reports. `up`,
# from the status file the driver writes when it creates the window and before
# any navigation, and `navout`, from the target server's own access log,
# separate the two.
#
# The control is this artifact with one line deleted, not a second build and
# not the previous commit, so the difference between the two readings is the
# fix and nothing else.
#
# Usage: navrefuse.sh <early-app.cmd built at --testing>

set -uo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -f "$APP" ]; then
    echo "usage: navrefuse.sh <app.cmd built from test/neutrinoearly.js>" >&2
    exit 2
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# One engine has this bridge and one driver is written against it.
if [ "$(uname -s)" != "Darwin" ]; then
    echo "report: not Darwin; the JXA bridge is the only one with this rule"
    exit 0
fi

WORK="$(mktemp -d)"
STATUS="${TMPDIR:-/tmp}/neutrino-title.txt"
PAGES="$WORK/pages.log"
TARGET_PID=""
STALL_PID=""
cleanup() {
    [ -n "$TARGET_PID" ] && kill "$TARGET_PID" 2>/dev/null
    [ -n "$STALL_PID" ] && kill "$STALL_PID" 2>/dev/null
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

FAILURES=0
WAIT=45

report() { echo "report: $*"; }
pass()   { echo "  PASS: $*"; }
fail()   { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# What the control deletes. Matched without the spelling on the end -- neither
# `;` nor `();` -- on purpose: run against the build before the fix this then
# reaches the assertions and fails on the account the driver gives, which is the
# finding, instead of failing here on a name it could not find. A suite that
# cannot find what it edits must still say so rather than silently measure two
# copies of one build against each other, which is the failure this file exists
# because of. It is one line in the artifact and asserted to be one line.
REFUSE_LINE='webViewRef.stopLoading'
NOTE_LINE='self.note("refused navigation to " + going);'
HITS="$(grep -cF "$REFUSE_LINE" "$APP" 2>/dev/null | head -1)"
if [ "${HITS:-0}" -ne 1 ]; then
    fail "'$REFUSE_LINE' appears ${HITS:-0} times in this artifact, wanted 1; the guard was rewritten and this suite was not"
    echo "=== Results: $FAILURES failure(s) ==="
    exit 1
fi

# =====================================================================
# The apparatus: the target has to answer, and the load has to stay pending
# =====================================================================
#
# Both are test/neutrinoearly.js's premises rather than this file's. They are
# started here rather than by the workflow so the two runs share one access log,
# which is what lets navout be read as a delta around each launch.
echo "=== Bringing up the navigation target and the stall socket ==="
python3 "$ROOT/test/stall.py" 8099 > "$WORK/stall.log" 2>&1 &
STALL_PID=$!
if ! TARGET_PID="$(bash "$ROOT/test/serve-target.sh" "$PAGES")"; then
    fail "nothing is serving the navigation target; a guard that refused nothing would pass"
    echo "=== Results: $FAILURES failure(s) ==="
    exit 1
fi

# =====================================================================
# The two artifacts
# =====================================================================
cp "$APP" "$WORK/navrefuse-shipped.cmd"
chmod +x "$WORK/navrefuse-shipped.cmd"

respell() {
    local mech="$1" repl="$2"
    awk -v find="$REFUSE_LINE" -v repl="$repl" '
        !done && index($0, find) {
            match($0, /^ */)
            print substr($0, 1, RLENGTH) repl
            done = 1
            next
        }
        { print }
    ' "$APP" > "$WORK/navrefuse-$mech.cmd"
    chmod +x "$WORK/navrefuse-$mech.cmd"
    if cmp -s "$APP" "$WORK/navrefuse-$mech.cmd"; then
        fail "$mech expected=the refusal line replaced actual=identical to the shipped build"
        echo "=== Results: $FAILURES failure(s) ==="
        exit 1
    fi
}
# The success note goes with the refusal, or the control build writes `refused
# navigation to ...` about a navigation it let through -- which is the exact
# sentence this file exists to distrust, in the log of the run that proves the
# point. Measured saying it, in the candidate's own round.
respell noguard 'void 0;'
awk -v note="$NOTE_LINE" '
    !done && index($0, note) {
        match($0, /^ */)
        print substr($0, 1, RLENGTH) "self.note(\"navrefuse: control let it through\");"
        done = 1
        next
    }
    { print }
' "$WORK/navrefuse-noguard.cmd" > "$WORK/navrefuse-noguard.next"
mv "$WORK/navrefuse-noguard.next" "$WORK/navrefuse-noguard.cmd"
chmod +x "$WORK/navrefuse-noguard.cmd"
# The spelling PR 23 replaced, kept as an artifact rather than as a sentence.
# "It would have failed before" is a claim until something runs it, and this
# runs it every push: the parenthesised form refuses the navigation exactly as
# the fixed one does, and tells the log it could not.
respell oldspelling 'webViewRef.stopLoading();'

# Launch, wait for the settled report, and read four things that are four
# different questions.
#
# The app is waited on as a process and never through a pipe: the launcher
# execs osascript, so this pid is the engine and killing it is enough.
measure() {
    local mech="$1"
    local file="$WORK/navrefuse-$mech.cmd"
    local log="$WORK/$mech.log"
    local title="" snap="" pid deadline before after

    # A delta and not a total: one access log serves both runs. Piped through
    # head so the pipeline's status is head's -- `grep -c` exits 1 on a count of
    # zero having already printed the zero, and a `|| echo 0` after it appends a
    # second line that then breaks the arithmetic below.
    before="$(grep -ac 'GET /early-target.html' "$PAGES" 2>/dev/null | head -1)"
    [ -n "$before" ] || before=0

    rm -f "$STATUS"
    bash "$file" > "$log" 2>&1 &
    pid=$!
    deadline=$((SECONDS + WAIT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -s "$STATUS" ]; then
            # Written when the driver creates the window and before any
            # navigation, so the first non-empty read is proof this build came
            # up whatever happens to the document afterwards.
            [ -z "$snap" ] && snap="$(cat "$STATUS" 2>/dev/null)"
            title="$(sed -n '1p' "$STATUS" 2>/dev/null || true)"
            case "$title" in *"EARLY "*"DONE"*) break ;; esac
            title=""
        fi
        sleep 0.5
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    # osascript can outlive the shell that started it if the exec did not take.
    pkill -f "navrefuse-$mech.cmd" 2>/dev/null

    after="$(grep -ac 'GET /early-target.html' "$PAGES" 2>/dev/null | head -1)"
    [ -n "$after" ] || after=0

    # Normalised here and not at each use. The report line prints
    # `${MEASURED_AT:-none}` and the assertions compared the raw value, so a
    # control that read exactly what it wanted failed against its own message:
    # `expected=at=none actual=at=none`. One value, one spelling, one place.
    MEASURED_AT="$(echo "$title" | sed -n 's/.* at=\([A-Za-z]*\).*/\1/p')"
    [ -n "$MEASURED_AT" ] || MEASURED_AT=none
    [ -n "$snap" ] && MEASURED_UP=YES || MEASURED_UP=NO
    [ "$after" -gt "$before" ] && MEASURED_NAVOUT=HIT || MEASURED_NAVOUT=MISS
    MEASURED_SAID="$(grep -aE 'refused navigation to|could not refuse navigation|no navigation guard' "$log" 2>/dev/null \
        | head -1 | sed -e 's/^neutrino: //' -e 's/[[:cntrl:]]/ /g' | cut -c1-120)"

    report "mech=$mech up=$MEASURED_UP at=$MEASURED_AT navout=$MEASURED_NAVOUT said=${MEASURED_SAID:-<silent>}"
}

echo "=== The shipped build ==="
MEASURED_AT=""; MEASURED_UP=""; MEASURED_NAVOUT=""; MEASURED_SAID=""
measure shipped
AT_SHIPPED="$MEASURED_AT"; UP_SHIPPED="$MEASURED_UP"
NAVOUT_SHIPPED="$MEASURED_NAVOUT"; SAID_SHIPPED="$MEASURED_SAID"

echo "=== The same build with the refusal deleted ==="
MEASURED_AT=""; MEASURED_UP=""; MEASURED_NAVOUT=""; MEASURED_SAID=""
measure noguard
AT_NOGUARD="$MEASURED_AT"; UP_NOGUARD="$MEASURED_UP"
NAVOUT_NOGUARD="$MEASURED_NAVOUT"

echo "=== The same build spelled the way it shipped from PR 6 to PR 23 ==="
MEASURED_AT=""; MEASURED_UP=""; MEASURED_NAVOUT=""; MEASURED_SAID=""
measure oldspelling
AT_OLD="$MEASURED_AT"; SAID_OLD="$MEASURED_SAID"

# =====================================================================
# The control, first because everything under it is a judgement it makes
# =====================================================================
echo "=== Results ==="
if [ "$UP_NOGUARD" = "YES" ] && [ "$AT_NOGUARD" = "none" ] && [ "$NAVOUT_NOGUARD" = "HIT" ]; then
    pass "control with the refusal deleted the page takes the window"
else
    fail "control expected=up=YES at=none navout=HIT actual=up=$UP_NOGUARD at=$AT_NOGUARD navout=$NAVOUT_NOGUARD"
    echo "        the guard is not what is keeping the app's document in that"
    echo "        window, so nothing below this line means anything"
fi

# The effect.
if [ "$UP_SHIPPED" = "YES" ]; then
    pass "the app came up"
else
    fail "the app never came up; a build that renders nothing refuses every navigation"
fi
if [ "$AT_SHIPPED" = "held" ]; then
    pass "the navigation was refused and the app kept its own document (at=held)"
else
    fail "at expected=held actual=$AT_SHIPPED"
fi

# The account, and this is the half that fails before the fix. The message is
# asserted and not merely its absence: a guard that stopped noting anything at
# all would satisfy "does not say it could not refuse" by saying nothing.
case "$SAID_SHIPPED" in
    "refused navigation to "*)
        pass "and the driver said so: $SAID_SHIPPED" ;;
    "could not refuse"*)
        fail "the driver refused the navigation and reported that it could not: $SAID_SHIPPED"
        echo "        this is the PR 6 spelling -- stopLoading() rather than"
        echo "        stopLoading -- refusing the load on the property read and"
        echo "        throwing on the call afterwards" ;;
    *)
        fail "the driver said nothing about the navigation it refused (${SAID_SHIPPED:-<silent>})" ;;
esac

# The before-state, measured rather than claimed. Both halves are asserted: the
# old spelling refuses just as well -- which is why four PRs went by without
# anyone noticing -- and it reports a failure it did not have. If a future
# bridge ever makes the parenthesised form work properly, this goes red and says
# so, which is the right way to find that out.
if [ "$AT_OLD" = "held" ]; then
    pass "the spelling this PR replaced refused the navigation too (at=held)"
else
    fail "the old spelling expected=held actual=$AT_OLD; the before-state is not what this PR says it was"
fi
case "$SAID_OLD" in
    "could not refuse"*)
        pass "and reported that it could not, which is the defect: $SAID_OLD" ;;
    *)
        fail "the old spelling was expected to report a failure it did not have, and said: ${SAID_OLD:-<silent>}" ;;
esac

# Recorded and not asserted. PR 6's stated ceiling is that the request has
# already left by the time this delegate runs, and the shipped build has read
# both HIT and MISS here across rounds while the guard's behaviour did not
# change. A field that moves with load is a race, and asserting the value seen
# most often buys a green lane that goes red on someone else's change.
report "the navigation's own request, on this platform = $NAVOUT_SHIPPED (recorded, not asserted)"

echo "=== Results: $FAILURES failure(s) ==="
[ "$FAILURES" -eq 0 ]
