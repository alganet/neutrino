#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# confine-macos.sh - assertions for the launcher's own seatbelt profile.
#
# Usage: confine-macos.sh [artifact.cmd]
#
# neutrino/sh/macos-confine.sh had no test of anything until this file. Every
# macOS suite in the tree launches the launcher and then asks about the window:
# whether a title arrived, whether the page ran, whether the palette moved. All
# of those pass with the profile silently missing, because the window does not
# depend on it -- and under netinstall they pass with it missing *and* the app
# still confined, by netinstall's own profile, which is this one with the same
# rules and its own parameters. Two defects lived in that gap:
#
#   - the profile was built with a here-document, and /bin/sh on macOS is bash
#     3.2, whose here-documents go to /tmp no matter what $TMPDIR says. Under
#     netinstall -- which does not grant /tmp -- the redirection failed, `cat`
#     wrote nothing, and the launcher took its unconfined fallback.
#   - the fallback then said "seatbelt rejected the profile", which sent the
#     reading of a shell failure to the sandbox, the one place it was not.
#
# Neither is visible from a window, so neither was visible to anything here.
#
# What this file asserts is the profile as a value: that it can be built at all,
# that it is the same text under a profile that denies /tmp as it is in a bare
# shell, that seatbelt takes it, and that what it takes actually confines. None
# of it needs a display, an engine or a window, so it runs in about a second and
# on every push.
#
# The functions are lifted out of a built artifact rather than sourced from
# neutrino/sh, for the reason parse.sh gives about the splitter: an assertion
# that reads the source cannot tell you what shipped. The `@@include` that puts
# this file's subject into an artifact is the step most able to go wrong.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

pass() { echo "  PASS: $*"; }
fail() {
    echo "  FAIL: $*"
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=confine-macos::$*"
    FAILURES=$((FAILURES + 1))
}

if [ "$(uname -s)" != "Darwin" ]; then
    echo "confine-macos.sh: not macOS; nothing here applies"
    exit 0
fi
if [ ! -x /usr/bin/sandbox-exec ]; then
    echo "confine-macos.sh: no sandbox-exec on this machine"
    exit 1
fi

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    TARGET="$WORK/template.cmd"
    bash "$ROOT/neutrino/assemble.sh" "$TARGET" >/dev/null || exit 2
fi
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
echo "confine-macos.sh: artifact=$TARGET"

# The three functions that make the profile, in the order they are defined, cut
# from the artifact by their own opening lines. A cut that comes back short is
# a failure and not an empty suite: it means the shell region moved and these
# assertions would otherwise pass by asserting nothing.
GEN="$WORK/gen.sh"
{
    sed -n '/^nt_resolve() {/,/^}/p' "$TARGET"
    grep '^nt_sbquote()' "$TARGET"
    sed -n '/^nt_macos_profile() {/,/^}/p' "$TARGET"
    echo 'nt_macos_profile "$1"'
} > "$GEN"
for fn in nt_resolve nt_sbquote nt_macos_profile; do
    if ! grep -q "^$fn" "$GEN"; then
        fail "could not lift $fn out of the artifact; the shell region has moved"
        echo "report: totals confine-macos failures=$FAILURES"
        exit 1
    fi
done
pass "lifted the profile builder out of the artifact"

# A here-document in what was just lifted is the original defect returning by
# another route -- a second one added elsewhere in the same function, or the
# printf reverted. The text assertion below catches it under the sandbox that
# denies /tmp, and this says which line to look at when it does.
if grep -qE '<<-?[A-Za-z_'\''"]' "$GEN"; then
    fail "the profile builder contains a here-document; bash 3.2 puts those in /tmp"
else
    pass "the profile builder needs no temp file"
fi

# Under $HOME and not under $WORK, and that is the difference between these
# assertions meaning the APPDIR rule and meaning nothing. mktemp puts $WORK in
# /private/var/folders, which the profile grants outright -- for the Darwin
# temp dir, with a comment -- so an app dir inside it is writable and
# non-executable whether or not a single line naming APPDIR survives. Put it
# somewhere the profile denies by default and the two probes below are about
# the rule they say they are about.
APPDIR="$HOME/.neutrino-confine-test.$$"
mkdir -p "$APPDIR/tmp"
trap 'rm -rf "$WORK" "$APPDIR"' EXIT

echo "=== The profile is built, and is the same text under confinement ==="

BARE="$WORK/bare.sb"
if /bin/sh "$GEN" "$APPDIR" > "$BARE" 2>"$WORK/bare.err" && [ -s "$BARE" ]; then
    pass "built in a bare shell ($(wc -c < "$BARE" | tr -d ' ') bytes)"
else
    fail "profile expected=non-empty actual=$(wc -c < "$BARE" | tr -d ' ') bytes, stderr: $(tr '\n' ' ' < "$WORK/bare.err")"
    echo "report: totals confine-macos failures=$FAILURES"
    exit 1
fi

# The netinstall profile, near enough for the one thing being asked: it denies
# every write except the app dir, the Darwin temp dir and the Library subtrees,
# and it does not grant /tmp. That last clause is the whole test. Written here
# rather than lifted from netinstall/sandbox_macos.c because what is being
# reproduced is the *shape* an outer profile has -- any of them, including one
# belonging to somebody else -- and not netinstall's particular list.
OUTER_SB="$WORK/outer.sb"
cat > "$OUTER_SB" <<'PROFILE'
(version 1)
(allow default)
(deny file-write*)
(allow file-write*
  (subpath (param "APPDIR"))
  (subpath "/private/var/folders")
  (regex #"^/dev/(null|zero|random|urandom|tty|dtracehelper)$"))
PROFILE

CONFINED="$WORK/confined.sb"
if /usr/bin/sandbox-exec -f "$OUTER_SB" -D APPDIR="$APPDIR" \
        /bin/sh "$GEN" "$APPDIR" > "$CONFINED" 2>"$WORK/confined.err"; then
    pass "built inside a profile that denies /tmp"
else
    fail "building inside an outer profile expected=ok actual=$(tr '\n' ' ' < "$WORK/confined.err")"
fi

# The regression assertion, and the sharpest one in this file. The old builder
# produced 1553 bytes in a bare shell and 0 under the profile above, and the
# launcher could not tell the difference between that and a profile seatbelt
# had refused.
if cmp -s "$BARE" "$CONFINED"; then
    pass "the confined build is byte-identical to the bare one"
else
    fail "profile text expected=identical actual=bare $(wc -c < "$BARE" | tr -d ' ') vs confined $(wc -c < "$CONFINED" | tr -d ' ') bytes"
fi

echo "=== Seatbelt takes it ==="

if /usr/bin/sandbox-exec -p "$(cat "$BARE")" /usr/bin/true >/dev/null 2>&1; then
    pass "sandbox-exec -p accepts the profile"
else
    fail "sandbox-exec expected=accepts actual=rejects: $(/usr/bin/sandbox-exec -p "$(cat "$BARE")" /usr/bin/true 2>&1 | tr '\n' ' ')"
fi

echo "=== And what it takes confines ==="

# Each of these is asserted against an unconfined control, because a probe that
# fails for its own reasons -- a path that does not exist, a script that is not
# executable -- looks exactly like a confinement that worked.
OUTSIDE="$HOME/.neutrino-confine-probe.$$"
rm -f "$OUTSIDE"
if /bin/sh -c "echo x > '$OUTSIDE'" 2>/dev/null && [ -f "$OUTSIDE" ]; then
    rm -f "$OUTSIDE"
    if /usr/bin/sandbox-exec -p "$(cat "$BARE")" \
            /bin/sh -c "echo x > '$OUTSIDE'" 2>/dev/null && [ -f "$OUTSIDE" ]; then
        fail "a write to \$HOME expected=denied actual=written"
        rm -f "$OUTSIDE"
    else
        pass "a write outside the app dir is denied"
    fi
else
    fail "the control write to \$HOME did not land; the probe proves nothing"
fi

if /usr/bin/sandbox-exec -p "$(cat "$BARE")" \
        /bin/sh -c "echo x > '$APPDIR/probe'" 2>/dev/null && [ -f "$APPDIR/probe" ]; then
    pass "a write to the app dir is allowed"
else
    fail "a write to the app dir expected=allowed actual=denied"
fi

# Write xor execute, which is the reason the profile names every writable path
# in its process-exec* rule and not just the app dir.
printf '#!/bin/sh\necho ran\n' > "$APPDIR/exec-probe"
chmod +x "$APPDIR/exec-probe"
if [ "$("$APPDIR/exec-probe" 2>/dev/null)" = "ran" ]; then
    if /usr/bin/sandbox-exec -p "$(cat "$BARE")" \
            "$APPDIR/exec-probe" >/dev/null 2>&1; then
        fail "executing from the app dir expected=denied actual=ran"
    else
        pass "what the app dir can hold, it cannot execute"
    fi
else
    fail "the control exec did not run; the w^x probe proves nothing"
fi

echo "=== A sandbox-exec profile does not nest, which the launcher's message rests on ==="

# run_macos tells "already confined" apart from "profile is bad" by offering
# seatbelt a profile that cannot be rejected on its merits and seeing it refused
# anyway. Both halves are asserted, because the message is only right while both
# hold: a macOS that starts allowing this turns "not nesting" into a launch that
# could have confined itself and did not, and this is the line that says so
# rather than a silence.
#
# What is measured here is sandbox-exec inside sandbox-exec, and that is not the
# netinstall case -- netinstall confines itself with
# sandbox_init_with_parameters and then execs, and a sandbox-exec after that is
# accepted, so the launcher really does apply its own profile under the
# downloader. netinstall/test/e2e.sh is where that half is asserted, because it
# takes a netinstall binary to ask. Assuming the two SPIs behaved alike is what
# put a wrong sentence in macos-confine.sh for the length of one afternoon.
PROBE='(version 1)(allow default)'
if /usr/bin/sandbox-exec -p "$PROBE" /usr/bin/true >/dev/null 2>&1; then
    pass "the nesting probe is accepted outside a profile"
else
    fail "nesting probe expected=accepted outside a profile actual=refused"
fi
if /usr/bin/sandbox-exec -f "$OUTER_SB" -D APPDIR="$APPDIR" \
        /usr/bin/sandbox-exec -p "$PROBE" /usr/bin/true >/dev/null 2>&1; then
    fail "nesting probe expected=refused inside a profile actual=accepted (macOS now nests; run_macos should apply its own profile under netinstall)"
else
    pass "the nesting probe is refused inside one"
fi

# And the launcher's four messages, present in the artifact. A branch renamed
# without its assertion being renamed is a suite that asserts a string nothing
# prints, which is the failure mode this whole file exists to end.
for msg in \
    "sandbox-exec not found" \
    "could not build the seatbelt profile" \
    "already inside a seatbelt profile" \
    "seatbelt rejected the profile"
do
    if grep -q "neutrino: $msg" "$TARGET"; then
        pass "the artifact can say \"$msg\""
    else
        fail "the artifact has no \"$msg\" branch; e2e.sh greps for these"
    fi
done

echo ""
echo "report: totals confine-macos failures=$FAILURES"
[ "$FAILURES" -eq 0 ] || exit 1
echo "launcher confinement assertions passed"
