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
# FAIL first, and that order is the whole point: a run that reached the flip
# and was handed nothing also prints the note saying which plugin it found, so
# a skip check asked first would read a real failure as a machine that could
# not run the half. A half that could not run says so and does not fail the
# lane -- the contract the other live halves keep.
#
# The image is named from NT_KDE_OWNER, which the workflow sets from the
# repository owner on the job: a fork pulls its own package and, failing that,
# builds the image locally rather than failing here. Unset, qtkde.sh's own
# default applies, which is what a desk wants.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ -n "${NT_KDE_OWNER:-}" ] && [ -z "${NT_KDE_IMAGE:-}" ]; then
    NT_KDE_IMAGE="ghcr.io/$(printf '%s' "$NT_KDE_OWNER" | tr '[:upper:]' '[:lower:]')/neutrino-kde:f42"
    export NT_KDE_IMAGE
fi
export NT_KDE_RUNTIME="${NT_KDE_RUNTIME:-docker}"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
bash "$HERE/../apparatus/qtkde.sh" 2>&1 | tee "$LOG"

if grep -q '^FAIL' "$LOG"; then
    exit 1
fi
if grep -q '^PASS' "$LOG"; then
    exit 0
fi
if grep -qE '^report: (live half: (no|a scheme|the control)|qtkde: (no|the image|pull))' "$LOG"; then
    echo "themelive-kde: the half did not run here; the notes above say why"
    exit 0
fi
echo "  FAIL: themelive-kde: no PASS, no FAIL and no reason given"
exit 1
