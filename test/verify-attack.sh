#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-attack.sh - Asserts what neutrinoattack.js measured (Linux and macOS).
#
# The app reports one final title and then leaves it alone, so this does not
# have to keep pace with anything -- it waits for a report and reads it.
#
# Three of the five results are invariants and are asserted. The other two are
# platform facts this branch measured rather than fixed, and they are asserted
# to the value that was measured, so that a change in either direction shows up
# as a failure rather than as silence.

set -euo pipefail

# The six words. This suite reported in prose and reached no case id, so the
# three lanes that run it had nothing to say in the grid about whether a hostile
# document can drive the native window -- which is the question it exists for.
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

TIMEOUT=90
POLL_INTERVAL=0.5

# The nine cases below this point all read one field out of the settled title.
# Where there is no title to read them from, each says so: an escape and a
# no-show are both answers to the two cases above them and to none of these, and
# a case that files nothing is a hole the grid cannot tell from a suite that
# stopped early.
nt_skip_fields() {
    local why="$1"
    nt_skip attack.wire.control "$why"
    nt_skip attack.raw.refused "$why"
    nt_skip attack.base.pinned "$why"
    nt_skip attack.inline.blocked "$why"
    nt_skip attack.eval.blocked "$why"
    nt_skip attack.frame.api "$why"
    nt_skip attack.forge.refused "$why"
    nt_skip attack.nav.refused "$why"
    nt_skip attack.postnav.channel "$why"
}

case "$(uname -s)" in
    Darwin)
        # The macOS driver has no window the shell can query, so the title
        # arrives through the same status file every other macOS check uses.
        read_title() { sed -n '1p' "${TMPDIR:-/tmp}/neutrino-title.txt" 2>/dev/null || true; }
        EXPECT_FORGE="REFUSED"
        # Recorded and not asserted, and no longer for the reason this used to
        # give. This driver does have a navigation guard -- PR 6 built one out
        # of didStartProvisionalNavigation: and -stopLoading, because the policy
        # callback wants a decision block and JXA cannot call one -- and PR 23
        # measured it refusing. What is free here is the field, not the guard:
        # the navigation above aims at a host that never resolves, so the
        # provisional load fails on its own and every driver reports REFUSED
        # whether it refused anything or not. The suite that asks this question
        # against a target that answers is test/navrefuse.sh.
        EXPECT_NAV="any"
        ;;
    *)
        # xdotool is what CI installs and what the other Linux verifier uses;
        # wmctrl is the fallback so this is runnable on a desktop that has one
        # and not the other.
        if command -v xdotool >/dev/null 2>&1; then
            read_title() {
                local wid
                wid=$(xdotool search --name "^ATTACK " 2>/dev/null | head -1) || true
                [ -n "$wid" ] && xdotool getwindowname "$wid" 2>/dev/null || true
            }
        elif command -v wmctrl >/dev/null 2>&1; then
            read_title() {
                # `|| true`, the way the xdotool branch above has always had it.
                # This file runs under `set -euo pipefail`, so with pipefail a
                # wmctrl that cannot open the display takes the whole pipeline
                # non-zero and set -e ends the suite inside the wait loop --
                # before the "never reported" branch that exists to say so. The
                # run then stops after "Waiting for the attack app to report"
                # with no verdict and no reason, which is the one outcome this
                # file is written to not produce.
                #
                # Latent rather than live: both Linux lanes install xdotool and
                # take the branch above. It was found by running the suite on a
                # machine with wmctrl and no display.
                wmctrl -l 2>/dev/null | sed -n 's/^[^ ]* *[^ ]* *[^ ]* *\(ATTACK .*\)$/\1/p' | tail -1 || true
            }
        else
            echo "verify-attack.sh: need xdotool or wmctrl to read a window title" >&2
            exit 1
        fi
        EXPECT_FORGE="REFUSED"
        EXPECT_NAV="REFUSED"
        ;;
esac

# Two reports arrive: a snapshot taken before the navigation attempt, and the
# settled one after it. On an engine that permits the navigation the second
# never comes, because this document stops existing -- so wait for a report,
# then give the settled one a bounded chance to replace it.
echo "=== Waiting for the attack app to report ==="
deadline=$((SECONDS + TIMEOUT))
TITLE=""
while [ $SECONDS -lt $deadline ]; do
    TITLE="$(read_title)"
    case "$TITLE" in *"ATTACK "*) break ;; esac
    TITLE=""
    sleep $POLL_INTERVAL
done

if [ -n "$TITLE" ]; then
    settle=$((SECONDS + 15))
    while [ $SECONDS -lt $settle ]; do
        case "$TITLE" in *"DONE"*) break ;; esac
        sleep $POLL_INTERVAL
        latest="$(read_title)"
        case "$latest" in *"ATTACK "*) TITLE="$latest" ;; esac
    done
fi

# A data: document that got the channel says so in the title itself, which is
# not a result to be weighed against others -- it is the escape having happened.
if [ "$TITLE" = "ATTACK-FRAME-ESCAPED" ]; then
    nt_pass attack.reported "the attack app reported a settled title"
    nt_fail attack.frame.title-escape "a frame drove the native window: the content policy let it run and the host took its messages, which is a same-null-origin escape and not a residual"
    nt_skip attack.data.escape "a frame escaped first, so what a data: document would have done was never reached"
    nt_skip_fields "a frame drove the window, so the fields of a settled report were never read"
    nt_finish
fi

if [ "$TITLE" = "ATTACK-DATA-ESCAPED" ]; then
    nt_pass attack.reported "the attack app reported a settled title"
    # Reaching here means the title was not the frame's, which is the whole of
    # what that case asks.
    nt_pass attack.frame.title-escape "no frame's title reached the native window"
    nt_fail attack.data.escape "a data: document drove the native window: the navigation was permitted and the host obeyed the page that arrived, which is a same-null-origin escape and not a residual"
    nt_skip_fields "a data: document drove the window, so the fields of a settled report were never read"
    nt_finish
fi

if [ -z "$TITLE" ]; then
    nt_fail attack.reported "the attack app never reported: a build that renders nothing would refuse every attack by doing nothing at all, so no report is a failure and not a pass"
    nt_skip attack.frame.title-escape "nothing reported, so no title was read and no escape could be seen in one"
    nt_skip attack.data.escape "nothing reported, so no title was read and no escape could be seen in one"
    nt_skip_fields "nothing reported, so there were no fields to read"
    nt_finish
fi

nt_pass attack.reported "the attack app reported a settled title"

echo "  report: $TITLE"

# Anchored on the space that separates one field from the next. Without it
# "nav" also matches the tail of "postnav", and the two are different
# answers to different questions.
field() { echo "$TITLE" | sed -n "s/.* $1=\([A-Za-z]*\).*/\1/p"; }

# assert_*, and named that way for the registry scan: the id arrives in a
# variable here, and the prefix is the convention that scan knows.
#
# `any` was a NOTE, which is prose nothing reads. It is the platform saying it
# cannot ask this one, which is what a skip is for -- and the difference matters
# on exactly one field, so leaving it as a note meant one lane's cell was empty
# for a reason no reader could recover.
assert_field() {
    local id="$1" name="$2" expected="$3" actual="$4"
    if [ "$expected" = "any" ]; then
        nt_skip "$id" "$name = $actual, which this platform records rather than asserts"
    elif [ "$actual" = "$expected" ]; then
        nt_pass "$id" "$name = $actual"
    else
        nt_fail "$id" "$name expected=$expected actual=$actual"
    fi
}

# Without this the rest is worthless: it says a well-formed record sent down the
# same path the attacks used was obeyed, so the refusals are refusals and not a
# transport that drops everything.
assert_field attack.wire.control "wire (control)" "LIVE" "$(field wire)"

assert_field attack.raw.refused "malformed records refused" "REFUSED" "$(field raw)"
assert_field attack.base.pinned "base-uri pinned" "REFUSED" "$(field base)"
assert_field attack.inline.blocked "inline script refused" "BLOCKED" "$(field inline)"
# The other half of script-src, and it has no markup to point at. The document
# said 'unsafe-eval' for as long as the engine dispatch went through eval; it
# says 'none' now, and this is what says so on every engine rather than in a
# comment. RANEVAL, RANFUNCTION and RANBOTH each name which call compiled.
assert_field attack.eval.blocked "eval refused" "BLOCKED" "$(field evl)"

# What a frame reached, measured from the parent. The frame is handed this
# build's API, so it attempts the same verb every other check here attempts;
# the size of the window afterwards is the answer, and the parent is the only
# realm that can read it. The title check below is the second half and asks a
# different question -- whether a subframe's title reached the native window,
# which no engine here is supposed to let happen at all.
assert_field attack.frame.api "a frame could not drive it" "REFUSED" "$(field frame)"

# A forged title is only refusable where the title is not the channel. Keying
# this off the transport the build reports means the assertion follows the code
# instead of a platform's history: the day a transport is replaced, this starts
# demanding the stronger answer on its own.
TRANSPORT="$(field tx)"
echo "  transport: $TRANSPORT"
if [ "$TRANSPORT" = "title" ]; then
    EXPECT_FORGE="OBEYED"
fi
assert_field attack.forge.refused "forged title refused" "$EXPECT_FORGE" "$(field forge)"
assert_field attack.nav.refused "navigation refused" "$EXPECT_NAV" "$(field nav)"

# A frame whose *title* reached the native window would have said so in that
# title, and that is checked before any of this is read. Reaching here means
# it did not, and the field above says the API it was handed reached nothing
# either.
nt_pass attack.frame.title-escape "no frame's title reached the native window"

# Refusing the top-frame data: navigation is not this project's doing -- every
# engine here already answers "not allowed to navigate top frame to data URL".
# Recorded so the difference is visible, not claimed as a control.
nt_pass attack.data.escape "no data: document drove the native window"

NAVDATA="$(field navdata)"
if [ "$NAVDATA" = "REFUSED" ]; then
    echo "  NOTE: top-frame data: navigation refused (the engine refuses these)"
else
    echo "  NOTE: data: navigation was permitted; the document that arrived"
    echo "        could not drive the window, so it is contained and not closed"
fi

# A refusal that also broke the channel would look like a pass everywhere else
# on this line, so what happens after one is asserted rather than assumed: the
# navigation is refused, this document is therefore still the app's own, and a
# well-formed record from it has to be obeyed. OBEYED is the right answer here
# and REFUSED would be the app unable to drive its own window.
#
# Where the navigation is not refused, the document answering afterwards is not
# the app's and the same OBEYED would be an escape -- so this is asserted only
# where the refusal above was, and recorded where it was not.
if [ "$EXPECT_NAV" = "REFUSED" ]; then
    assert_field attack.postnav.channel "the refusal left the channel working" "OBEYED" "$(field postnav)"
else
    nt_skip attack.postnav.channel "postnav = $(field postnav), and with no navigation refusal to follow it OBEYED would be an escape rather than a working channel"
fi

# The count, and not whether there was one -- the note that used to be here
# said so about ending on a test, and nt_finish is where that contract lives.
nt_finish
