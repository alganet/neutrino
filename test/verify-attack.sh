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

TIMEOUT=90
POLL_INTERVAL=0.5
FAILURES=0

case "$(uname -s)" in
    Darwin)
        # The macOS driver has no window the shell can query, so the title
        # arrives through the same status file every other macOS check uses.
        read_title() { sed -n '1p' "${TMPDIR:-/tmp}/neutrino-title.txt" 2>/dev/null || true; }
        EXPECT_FORGE="REFUSED"
        # No navigation refusal on macOS: the policy callback wants a decision
        # block and calling one from JXA is not established. Recorded, not
        # asserted, because either answer here is a finding and not a break.
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
                wmctrl -l 2>/dev/null | sed -n 's/^[^ ]* *[^ ]* *[^ ]* *\(ATTACK .*\)$/\1/p' | tail -1
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
    echo "FAIL: a frame drove the native window"
    echo "      the content policy let it run and the host took its messages,"
    echo "      which is a same-null-origin escape and not a residual"
    exit 1
fi

if [ "$TITLE" = "ATTACK-DATA-ESCAPED" ]; then
    echo "FAIL: a data: document drove the native window"
    echo "      the navigation was permitted and the host obeyed the page that"
    echo "      arrived, which is a same-null-origin escape and not a residual"
    exit 1
fi

if [ -z "$TITLE" ]; then
    echo "FAIL: the attack app never reported"
    echo "      a build that renders nothing would refuse every attack by"
    echo "      doing nothing at all, so no report is a failure and not a pass"
    exit 1
fi

echo "  report: $TITLE"

field() { echo "$TITLE" | sed -n "s/.*$1=\([A-Za-z]*\).*/\1/p"; }

assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "any" ]; then
        echo "  NOTE: $name = $actual (recorded, not asserted on this platform)"
    elif [ "$actual" = "$expected" ]; then
        echo "  PASS: $name = $actual"
    else
        echo "  FAIL: $name expected=$expected actual=$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

# Without this the rest is worthless: it says a well-formed record sent down the
# same path the attacks used was obeyed, so the refusals are refusals and not a
# transport that drops everything.
assert "wire (control)" "LIVE" "$(field wire)"

assert "malformed records refused" "REFUSED" "$(field raw)"
assert "base-uri pinned"           "REFUSED" "$(field base)"

# A forged title is only refusable where the title is not the channel. Keying
# this off the transport the build reports means the assertion follows the code
# instead of a platform's history: the day a transport is replaced, this starts
# demanding the stronger answer on its own.
TRANSPORT="$(field tx)"
echo "  transport: $TRANSPORT"
if [ "$TRANSPORT" = "title" ]; then
    EXPECT_FORGE="OBEYED"
fi
assert "forged title refused"      "$EXPECT_FORGE" "$(field forge)"
assert "navigation refused"        "$EXPECT_NAV"   "$(field nav)"

# A frame that drove the window would have said so in the title, and that is
# checked before any of this is read. Reaching here means it did not.
echo "  PASS: no frame drove the window"

# Refusing the top-frame data: navigation is not this project's doing -- every
# engine here already answers "not allowed to navigate top frame to data URL".
# Recorded so the difference is visible, not claimed as a control.
NAVDATA="$(field navdata)"
if [ "$NAVDATA" = "REFUSED" ]; then
    echo "  NOTE: top-frame data: navigation refused (the engine refuses these)"
else
    echo "  NOTE: data: navigation was permitted; the document that arrived"
    echo "        could not drive the window, so it is contained and not closed"
fi

echo "=== Results: $FAILURES failure(s) ==="
[ "$FAILURES" -eq 0 ]
