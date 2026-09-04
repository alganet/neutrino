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
# Under $HOME on macOS, and mktemp's directory everywhere else.
#
# Not a preference. mktemp puts this in /private/var/folders, and the launcher's
# own seatbelt profile denies process-exec* on that subpath -- w^x, deliberately,
# with a paragraph beside it. So every stub this suite writes was unexecutable
# by the one lane that applies that profile:
#
#   sandbox-exec: execvp() of 'osascript' failed: Operation not permitted
#
# which is why lanes.sh has never run on macOS, and why the osascript
# assertions below fail there against a launcher that is behaving correctly.
# A stub standing in for a real engine belongs where a real engine lives, which
# is not a directory the app may write; $HOME is the nearest thing to that this
# suite can create.
case "$(uname -s)" in
    Darwin) WORK="$(mktemp -d "$HOME/.neutrino-lanes.XXXXXX")" ;;
    *)      WORK="$(mktemp -d)" ;;
esac
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

# The minimum a launch needs before it reaches the walk at all: sed, because the
# loader scrub reads the environment's names through it, and dirname, basename,
# mkdir and rm for the lanes below. Built by symlink rather than by copying a
# $PATH, because the whole method here is controlling exactly which engines
# exist.
#
# This used to say sed and head were how the tier stamp was read. There is no
# stamp -- that went before the tiers themselves did -- and head is kept only
# because removing a tool from this list is a separate measurement.
BIN="$WORK/bin"
mkdir -p "$BIN"
for tool in sh bash sed head env dirname basename mkdir rm cat awk; do
    src="$(command -v "$tool" 2>/dev/null)" && ln -sf "$src" "$BIN/$tool"
done

# In $TMPDIR and not in $WORK, for the other half of the reason $WORK moved.
#
# The stubs have to be somewhere the launcher's seatbelt profile permits
# executing, which is anywhere but the app dir and the Darwin temp dir; the
# marks file has to be somewhere it permits *writing*, which is the app dir and
# the Darwin temp dir and nowhere else. One directory cannot be both, so they
# are two. $TMPDIR satisfies the write side on macOS -- the profile grants it by
# name and again through /private/var/folders -- and is ordinary everywhere
# else.
MARKS="${TMPDIR:-/tmp}/nt-lanes-marks.$$"
trap 'rm -rf "$WORK"; rm -f "$MARKS"' EXIT

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
echo "=== lanes: Qt sits below osascript too, and for a sharper reason ==="
# python3 below osascript is a cost argument -- a Mac should not fork an
# interpreter it will not use. Qt below osascript is a correctness one: a Mac
# that reached the Qt lane got no window at all, because run_qt hands the engine
# a document with no name and that hand-off is /proc/self/fd-shaped. Linux
# reopens the inode; macOS's /dev/fd is a dup of a write-only descriptor and
# there is nothing to hand over. find_qt_runtime still succeeded on any Mac with
# Homebrew's qt, so the walk stopped at a lane that cannot run and exited with
# its status while osascript sat below it.
clear_lane
stub qml6 0
stub osascript 0
run_lane > /dev/null
eq "osascript answers before the Qt lane is tried" "$(marks)" "osascript"


echo ""
echo "=== lanes: a lane that cannot hand over its document is unavailable, not fatal ==="
# The contract at the top of dispatch.sh says 69 means "this lane could not
# reach its engine -- reported by the lane itself, after looking, and before it
# has created anything". The nameless-document refusal is exactly that condition
# and it used to return 1, which took the whole launch down instead of moving
# the walk on.
#
# Only askable where the hand-off actually fails, so it is probed rather than
# assumed from a uname: open a write-only descriptor, unlink it, and see whether
# this kernel will reopen it for reading the way run_qt needs.
handoff_works() {
    ( d="$WORK/ho"; mkdir -p "$d"; f="$d/probe.$$"
      exec 8>"$f"; rm -f "$f"; printf x >&8
      for dir in /dev/fd /proc/self/fd; do
          [ -r "$dir/8" ] && exec 9<"$dir/8" && exit 0
      done
      exit 1 )
}
clear_lane
stub qml6 0
if handoff_works; then
    run_lane > /dev/null
    eq "the Qt lane is reached where osascript does not exist" "$(marks)" "qml6"
    report "this kernel reopens an unlinked descriptor, so there is no refusal to measure"
else
    status="$(run_lane)"
    # The walk kept looking. Before the reserved status was returned here the
    # refusal was a `return 1`, dispatch took it for the app's own status and
    # exited on the spot -- so the summary line, which is the walk saying what
    # it looked for, was never printed. That line is the assertion.
    eq "the refusal starts no engine" "$(marks)" ""
    eq "and the walk keeps looking rather than exiting on it" \
       "$(grep -c 'no runtime here can open a window' "$WORK/out.log")" "1"
    eq "and the refusal was said out loud" \
       "$(grep -c 'cannot hand the engine a document without a name here' "$WORK/out.log")" "1"
    eq "and an engineless machine still exits non-zero" "$status" "1"
fi

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
# Two readings of the same fact, because "reached" is not "ran" on every
# kernel. run_pygobject hands its interpreter a nameless document exactly the
# way run_qt does, so where that hand-off cannot work the lane is entered and
# refuses before it execs anything -- and the stub, which is how this file
# usually says a lane ran, is never reached. The refusal is then what says the
# walk got here. This assertion asked only the first question until it was run
# on macOS for the first time, where it had never been able to pass.
if handoff_works; then
    eq "and python3 is reached where it does not" "$(marks)" "python3"
else
    # Two refusals and not one: clear_lane always leaves a qml6 stub in place,
    # so the Qt lane is entered and refuses on its way past. The second is
    # python3's, and its presence is the reading.
    eq "and python3 is reached where it does not (refusing before it execs)" \
       "$(grep -c 'cannot hand the engine a document without a name here' "$WORK/out.log")" "2"
fi

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
