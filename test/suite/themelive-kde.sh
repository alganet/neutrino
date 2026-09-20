#!/bin/bash
# themelive-kde.sh - the Qt lane's live theme half, on the KDE qtkde.sh brings up.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: themelive-kde.sh
#
# test/apparatus/qtkde.sh supplies a real Plasma 6 in a container and runs
# themeflip.sh's live half inside it, and it exits 0 both when the half passed
# and when there was no desktop to run it on -- those are not the same result
# to a reader, and the kde-live step used to tell them apart by reading the
# log after the fact. That reading is this file, so the lane is a row like
# every other and the verdict is a suite's rather than a step's.
#
# It files two cases now rather than only exiting a status, and the two are the
# control and the flip. See where they are filed below for why the control is a
# case and not a reading. A half that could not run skips and does not fail the
# lane -- the contract the other live halves keep -- and a skip is a verdict the
# grid can see, which a silence is not.
#
# The image is named from NT_KDE_OWNER, which the workflow sets from the
# repository owner on the job: a fork pulls its own package and, failing that,
# builds the image locally rather than failing here. Unset, qtkde.sh's own
# default applies, which is what a desk wants.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/harness.sh"

if [ -n "${NT_KDE_OWNER:-}" ] && [ -z "${NT_KDE_IMAGE:-}" ]; then
    NT_KDE_IMAGE="ghcr.io/$(printf '%s' "$NT_KDE_OWNER" | tr '[:upper:]' '[:lower:]')/neutrino-kde:f42"
    export NT_KDE_IMAGE
fi
export NT_KDE_RUNTIME="${NT_KDE_RUNTIME:-docker}"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
bash "$HERE/../apparatus/qtkde.sh" 2>&1 | tee "$LOG"

# Two cases, and the reason there are two is the reason this lane exists.
#
# `qml/window.qml` can only be shown to follow a live colour scheme on a
# machine where setting one reaches Qt at all, and for three probe rounds it
# was not obvious which of the two had failed: an app that does not react and a
# desktop that never delivered anything look identical from a failing assertion.
# themeflip.sh takes the control first -- two schemes, each set *before* a
# process starts, read back from a fresh window -- and only then flips one under
# a running app. So the control is a case of its own: it is what says whether
# the next line is about the product or about the machine.
#
# Until now this lane filed neither. It reported a verdict in prose and an exit
# status, and test/cases.tsv said so in as many words: "kde-live is still the
# only lane with no row anywhere here". A lane that files nothing is a column of
# dots in the grid, which is indistinguishable from a lane that stopped running
# -- and this lane did stop asking its own question, for ten days, while staying
# green. That is the argument for a vocabulary, made by the lane itself.
# The ids are spelled out at every call and not held in a variable. The registry
# scan in test/lib/selftest.sh follows them by reading this file, so an id that
# reaches nt_pass through $CONTROL is an id it cannot see -- it comes back as
# "in cases.tsv but emitted nowhere", which is what it said when these two were
# written that way.
# The last note the apparatus left, which is the one that says how far it got.
# `qtkde:` reasons are the container; `live half:` reasons are the desktop
# inside it.
nt_reason() {
    sed -n -E 's/^report: ((live half|live control|qtkde): .*)$/\1/p' "$LOG" | tail -1
}
REASON="$(nt_reason)"
[ -n "$REASON" ] || REASON="the apparatus left no note at all"

# FAIL first, and that order is the whole point: a run that reached the flip and
# was handed nothing also prints the note saying which plugin it found, so a
# skip check asked first would read a real failure as a machine that could not
# run the half.
if grep -q '^report: live control: the colour scheme knob moves a Qt palette across launches' "$LOG"; then
    nt_pass themelive.kde.control "two schemes set before a launch give a fresh window different palettes, so the knob reaches Qt here"
    CONTROL_OK=1
else
    CONTROL_OK=0
    nt_skip themelive.kde.control "no control reading to judge a flip by: $REASON"
fi

if grep -q '^FAIL' "$LOG"; then
    nt_fail themelive.kde.flip "$(grep -m1 '^FAIL' "$LOG" | sed 's/^FAIL: *//')"
elif grep -q '^PASS: the running app was handed a new palette' "$LOG"; then
    nt_pass themelive.kde.flip "a running app was handed a new palette when the desktop's colour scheme moved"
elif [ "$CONTROL_OK" = 0 ]; then
    nt_skip themelive.kde.flip "the control could not be taken, so the flip was never asked: $REASON"
else
    # The control passed and the flip said nothing, which is neither a machine
    # that could not ask nor an app that did not react. It is this file losing
    # track of the suite under it, and it is a failure here rather than a silence.
    nt_fail themelive.kde.flip "the control passed and no flip verdict followed; the notes above are all there is"
fi

nt_finish
