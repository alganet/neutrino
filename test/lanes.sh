#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# lanes.sh - the engine walk: which one is chosen, and what makes it move on
#
# The launcher used to name one interpreter. `command -v gjs` succeeded or it
# went looking for Qt, which meant two things measured on real desktops:
#
#   - a Cinnamon machine, where the interpreter is called cjs and Gtk 3.0 and
#     WebKit2 4.1 are both installed and working, got no window at all
#   - a machine with gjs installed but without the WebKit2 typelib -- they are
#     separate packages -- died with a traceback while a working qml6 sat
#     unreached, because the branch was committed the moment the name existed
#
# And a third, which is the one this file exists for more than the other two:
# when nothing was found the last command in the branch was an `echo`, so the
# `exit $?` on the seam exited **0**. A launch that opened no window reported
# success. Under netinstall that is not cosmetic -- nt_exec execs /bin/sh on the
# script it just fetched and verified, so the whole cycle came back successful
# with nothing on screen.
#
# Every check here is on the walk, not on an engine, so it needs no display and
# no toolkit: the candidates are stubs that record that they ran and exit with a
# status of this suite's choosing. That is the entire point -- the walk's
# contract is "what does a status mean", and a stub can say a status a real
# interpreter can only be coaxed into.
#
# Usage: lanes.sh [app.cmd]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
report() { echo "report: $*"; }
fail()   { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }
eq() {
    if [ "$2" = "$3" ]; then
        echo "  PASS: $1"
    else
        fail "$1: expected '$3', got '$2'"
    fi
}

APP_IN="${1:-}"
if [ -z "$APP_IN" ]; then
    APP_IN="$WORK/built.cmd"
    bash "$ROOT/build.sh" "$ROOT/test/neutrinotest.js" "$APP_IN" > /dev/null 2>&1 ||
        { echo "lanes.sh: could not build an artifact to test"; exit 1; }
fi
[ -r "$APP_IN" ] || { echo "lanes.sh: no such artifact: $APP_IN"; exit 1; }
# Copied into the work directory and launched from there rather than run where
# it was handed over. Two things fall out of that and both were defects first.
#
# run_lane launches from inside $WORK, so a path the caller wrote relative to
# its own directory stops resolving the moment the subshell changes directory,
# and bash answers a script it cannot open with 127 -- a status this suite
# hands its stubs to mean something else entirely, so every reading came back
# empty and the harness's own bug read as the launcher's. CI passes a relative
# path; the run that wrote this file did not.
#
# And run_qt and run_pygobject both create their app directory beside the
# artifact. A suite that leaves one inside the tree it was given has a side
# effect on the thing it is measuring.
cp "$APP_IN" "$WORK/app.cmd"
APP="$WORK/app.cmd"

# The minimum a launch needs before it reaches the walk at all: the tier stamp
# is read with sed and head, and the lanes below use dirname, basename, mkdir
# and rm. Built by symlink rather than by copying a $PATH, because the whole
# method here is controlling exactly which engines exist.
BIN="$WORK/bin"
mkdir -p "$BIN"
for tool in sh bash sed head env dirname basename mkdir rm cat awk; do
    src="$(command -v "$tool" 2>/dev/null)" && ln -sf "$src" "$BIN/$tool"
done

MARKS="$WORK/marks"

# A stub engine: says it ran, and exits with whatever this suite is asking the
# walk about.
stub() {
    local name="$1" status="$2"
    cat > "$BIN/$name" <<STUB
#!/bin/sh
echo "$name" >> "$MARKS"
exit $status
STUB
    chmod +x "$BIN/$name"
}

# The same, without the mark: an engine that is reached and reports it cannot
# start, which is not the same event as one that ran.
stub_quiet() {
    printf '#!/bin/sh\nexit %s\n' "$2" > "$BIN/$1"
    chmod +x "$BIN/$1"
}

clear_lane() {
    rm -f "$MARKS" "$BIN"/gjs "$BIN"/gjs-console "$BIN"/cjs "$BIN"/cjs-console \
          "$BIN"/qml6 "$BIN"/qml "$BIN"/osascript "$BIN"/python3
    : > "$MARKS"
    # Qt is the one lane PATH cannot hide, and it is deliberate: find_qt_runtime
    # falls back to the absolute paths distributions install into, because on
    # Ubuntu the runner is not on PATH at all. Right for a launcher, fatal for a
    # harness that controls engines with PATH -- measured on the kde lane, where
    # the real qml6 was found at its absolute path, ran, and aborted, so the
    # walk answered 134 to a question about a refusal and the two lanes below Qt
    # were never reached. Every reading here was about the runner rather than
    # the launcher.
    #
    # So Qt is given a stub that reports the lane unavailable. PATH is consulted
    # first, so the stub wins and the absolute list is never reached, and the
    # walk behaves identically on a machine with Qt installed and one without --
    # which is the only way these readings mean the same thing on every lane.
    # 69 is the launcher's own reserved status, spelled out because this file
    # deliberately shares no code with the thing it measures.
    stub_quiet qml6 69
}

run_lane() {
    ( cd "$WORK" && PATH="$BIN" "$BIN/bash" "$APP" > "$WORK/out.log" 2>&1 )
    echo "$?"
}

marks() { tr '\n' ' ' < "$MARKS" | sed 's/ $//'; }

echo "=== lanes: nothing to run is a refusal, and refusals are not zero ==="
clear_lane
status="$(run_lane)"
eq "an engineless machine exits non-zero" "$status" "1"
eq "and says which engines it looked for" \
   "$(grep -c 'no runtime here can open a window' "$WORK/out.log")" "1"
eq "and ran nothing" "$(marks)" ""

echo ""
echo "=== lanes: the reserved status moves the walk on ==="
clear_lane
stub gjs 69
stub cjs 0
status="$(run_lane)"
eq "a lane that could not start its engine is not the answer" "$(marks)" "gjs cjs"
eq "and the lane that did start decides the status" "$status" "0"

echo ""
echo "=== lanes: an app failing on its own is not a lane failing ==="
clear_lane
stub gjs 3
stub cjs 0
status="$(run_lane)"
eq "the walk stops at the engine that ran the app" "$(marks)" "gjs"
eq "and hands back the app's own status" "$status" "3"

echo ""
echo "=== lanes: a name that cannot be executed is this lane being unavailable ==="
clear_lane
ln -sf /nonexistent-interpreter "$BIN/gjs"
stub cjs 0
status="$(run_lane)"
eq "a dangling engine moves the walk on" "$(marks)" "cjs"
eq "and does not become the launch's status" "$status" "0"

echo ""
echo "=== lanes: the order is upstream, then the fork ==="
clear_lane
stub gjs 0
stub gjs-console 0
stub cjs 0
stub cjs-console 0
run_lane > /dev/null
eq "gjs is preferred to every other spelling" "$(marks)" "gjs"

clear_lane
stub cjs 0
stub cjs-console 0
status="$(run_lane)"
eq "and the plain name to the -console one" "$(marks)" "cjs"

echo ""
echo "=== lanes: python3 sits below osascript, so a Mac never pays for it ==="
clear_lane
stub osascript 0
stub python3 0
run_lane > /dev/null
eq "osascript answers first where it exists" "$(marks)" "osascript"

clear_lane
stub python3 0
run_lane > /dev/null
eq "and python3 is reached where it does not" "$(marks)" "python3"

echo ""
echo "=== lanes: every candidate is a builtin lookup until one is chosen ==="
# The cost claim in the launcher's own comment, made checkable. `command -v` is
# a builtin, so a walk that finds nothing must not have forked an engine -- and
# the marks file, which only an engine writes to, is how that is read.
clear_lane
stub cjs 0
run_lane > /dev/null
eq "a machine with only the third candidate still runs exactly one engine" \
   "$(marks)" "cjs"

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "lanes.sh: $FAILURES failure(s)"
    exit 1
fi
echo "lanes.sh: the walk behaved"
