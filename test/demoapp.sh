#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# demoapp.sh - build the published sample app, with a reporter on the end of it.
#
# The app is pages/demo, unchanged: the same four files pages/build.sh hands to
# the assembler for the artifact on the download page. What this adds is
# test/demoprobe.js, concatenated onto the end of the app's own script, which
# reads back what the app put on the page and puts it in the window title.
#
# Concatenated rather than laid over. An overlay *replaces* a part -- that is
# what makes an overlay an overlay -- so an overlay carrying app.js would test
# the reporter instead of the app. What has to be measured here is the published
# source, so the published source is what runs, with two dozen lines after it.
#
# No --testing. Everything else in this tree builds a testing artifact because
# it needs the trace channel; this one is deliberately the shape that ships,
# because the thing under test is the download and not the launcher.
#
# Usage: demoapp.sh [out.cmd]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HERE/neutrinodemo.cmd}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$ROOT"/pages/demo/* "$WORK/"
cat "$HERE/demoprobe.js" >> "$WORK/app.js"

bash "$ROOT/neutrino/assemble.sh" --overlay "$WORK" "$OUT"

# The window this app opens is named by its config, and the verifiers wait for
# the reporter's title rather than for that name -- so a build whose config
# stopped saying what this thinks it says would have them waiting on the wrong
# thing. Said here, once, where both of them can read it.
echo "demoapp: built $OUT from pages/demo plus test/demoprobe.js"
echo "demoapp: config says $(tr -d ' \n' < "$ROOT/pages/demo/config.json")"
