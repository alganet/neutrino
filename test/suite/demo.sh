#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# demo.sh - does the app on the download page work?
#
# The one artifact in this tree nobody ran. Every other suite here builds its
# own probe and each of those waits for a document by hand, so the app written
# the way the README tells an author to write one was the app with no instrument
# on it -- and it shipped with a Close button that did nothing on Windows,
# found by a person on Windows Home rather than by anything here.
#
# What it asserts is one title. test/probe/demoprobe.js, appended to the app's own
# script, reads back what the app put on its page and names it in the window
# title; this waits for that title and checks each field. Three failures are
# told apart rather than counted together:
#
#   no title            the app's own script threw before the reporter ran
#   eng=UNREADABLE      the early shell was not on the page when the app looked
#   eng=UNFILLED        the app ran, found its markup, and filled in nothing
#
# The middle one is the defect this file exists for. It is what the demo did on
# WebView2 for as long as an app's script ran before the parser had produced
# anything, and it is invisible from outside without a reading like this: the
# window comes up, it is the right size, it is painted correctly, and the two
# words that say what is rendering are ellipses.
#
# The app is launched by the caller, the way every other verifier here is
# arranged: a suite may not start a program whose exit it does not control.
#
# Usage: demo.sh [screenshot-dir]

set -uo pipefail

# The six words. Every green branch below used to be a `note`, so on a run where
# the demo worked this suite filed nothing at all -- the shape 720ec92 called
# the most common defect this conversion turns up, and a bad one here: the whole
# point of the file is that the app on the download page shipped broken and
# nothing in CI could say so.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/harness.sh"
# And the reader. This copy was verify-early.sh's, and it arrived without the
# `|| true` that file carries -- correct only because this suite has no `set -e`
# to be killed by, which is a fact about a line at the top of a different file.
. "$(cd "$(dirname "$0")/.." && pwd)/lib/title.sh"

SHOT_DIR="${1:-$HOME/screenshots}"
TIMEOUT=180
POLL=0.5

mkdir -p "$SHOT_DIR"

# The three cases below the title all read one field out of it. Where there is
# no title, each says so rather than going unreported: a case that files nothing
# is a hole the grid cannot tell from a suite that never ran.
skip_fields() {
    nt_skip demo.engine.named "$1"
    nt_skip demo.transport.wired "$1"
    nt_skip demo.close.bound "$1"
}

# An instrument that is not here, which is not the app failing. Every case this
# suite has is read out of a window title, so with nothing that can read one
# there is no question here that can be answered.
if [ "$NT_TITLE_HOW" = none ]; then
    WHY="neither xdotool nor wmctrl is here, so nothing can read a title"
    nt_skip demo.reported "$WHY"
    skip_fields "$WHY"
    nt_finish
fi

echo "=== Waiting for the demo to report ==="
TITLE=""
WAITED=0
while [ "$WAITED" -lt "$TIMEOUT" ]; do
    TITLE="$(nt_title "DEMOPROBE ")"
    [ -n "$TITLE" ] && break
    sleep "$POLL"
    WAITED=$((WAITED + 1))
done

if [ -z "$TITLE" ]; then
    nt_fail demo.reported "no DEMOPROBE title in ${TIMEOUT}s; the app's own script did not reach the reporter"
    # What did come up, because "no window with this name" and "no window at
    # all" want different fixes.
    if command -v wmctrl >/dev/null 2>&1; then
        nt_report "windows up right now:"
        wmctrl -l 2>/dev/null | sed 's/^/  /' || true
    fi
    skip_fields "nothing reported, so there were no fields to read"
    nt_finish
fi

nt_pass demo.reported "the demo reported a title"
nt_report "title [$TITLE]"

# A picture of the app as it ships, which is the other half of what this step
# is for: every field below is a string, and nobody reviewing a sheet can see
# from a string that the window is legible.
if command -v import >/dev/null 2>&1; then
    import -window root "$SHOT_DIR/demo.png" 2>/dev/null &&
        nt_report "shot $SHOT_DIR/demo.png"
fi

field() { nt_field "$1" "$TITLE"; }

ENG="$(field eng)"
TX="$(field tx)"
SIZE="$(field size)"
DESKTOP="$(field desktop)"
BOUND="$(field bound)"

# The reading this file was written for. UNREADABLE is the early shell missing
# at the app's first statement; UNFILLED is the app running and reporting
# nothing.
case "$ENG" in
    WebView2|QtWebEngine|Chromium|WebKit)
        nt_pass demo.engine.named "engine $ENG -- the app read its own markup and named the engine" ;;
    UNREADABLE)
        nt_fail demo.engine.named "eng=UNREADABLE: document.getElementById answered null in the app's own script, so the early shell was not on the page when it ran" ;;
    UNFILLED|"")
        nt_fail demo.engine.named "eng=${ENG:-<absent>}: the app ran and never filled its own page in" ;;
    *)
        nt_fail demo.engine.named "eng=$ENG is not an engine this app knows how to name" ;;
esac

case "$TX" in
    scriptmessage|wkscriptmessage|console|webmessage|title)
        nt_pass demo.transport.wired "transport $TX" ;;
    unwired)
        nt_fail demo.transport.wired "tx=unwired: this launch has no channel to the host, so none of the window verbs on the page can work" ;;
    *)
        nt_fail demo.transport.wired "tx=${TX:-<absent>} is not a transport this launcher offers" ;;
esac

# Against the app's own config rather than a number written here, for the reason
# every lift in this tree gives: a copy goes stale and still passes.
WANT_W="$(sed -n 's/.*"width"[^0-9]*\([0-9]*\).*/\1/p' "$(dirname "$0")/../../pages/demo/config.json")"
WANT_H="$(sed -n 's/.*"height"[^0-9]*\([0-9]*\).*/\1/p' "$(dirname "$0")/../../pages/demo/config.json")"
if [ "$SIZE" = "${WANT_W}_x_${WANT_H}" ]; then
    nt_report "size $SIZE agrees with config.json"
else
    # A reading and not a control. innerWidth is the content area and a window
    # manager may hand back less than was asked for; what would be a defect is
    # the app failing to read a size at all, and that is the case above.
    nt_report "size $SIZE against config ${WANT_W}x${WANT_H} -- the window manager had the last word"
fi

nt_report "desktop $DESKTOP"

# The button, which is the whole of what the person on Windows Home reported.
if [ "$BOUND" = "yes" ]; then
    nt_pass demo.close.bound "the Close button has a handler on it"
else
    nt_fail demo.close.bound "bound=$BOUND: the Close button on the published demo has no handler, which is exactly the defect this file was written for"
fi

nt_finish
