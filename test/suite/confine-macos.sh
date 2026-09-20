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
#
# It speaks test/lib/harness.sh now, where it used to carry its own pass/fail
# pair and its own totals line. Three things go with that and each is worth
# saying once.
#
# The rows reach the grid, which is the whole point: this file asserted fourteen
# things into prose, on the one lane that runs it, so a run where it stopped
# executing and a run where it passed produced the same empty column. The suite
# exists because two defects hid in a gap nothing could see; reporting where
# nothing can see it is the same gap one level up.
#
# The totals line says `confine` and not `confine-macos`, because the harness
# takes the name from the row and the row is `confine`. That is the same name
# netinstall's confinement suite files under on three other lanes, which is
# right: they are the same subject asked of different things, and the ids keep
# them apart.
#
# The private `fail` emitted `::error title=confine-macos::` on every failure.
# The harness only annotates when NT_ANNOTATE is set, which nothing sets, and
# that is deliberate -- GitHub keeps thirty annotations a job and drops the
# earliest first, so a suite that spends them on itself spends them on behalf of
# every other. Nothing is lost: test/run.sh annotates the lane once for a suite
# that reported failures, which is the line a reader needs from the run page.

set -uo pipefail

. "$(cd "$(dirname "$0")/.." && pwd)/lib/harness.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Every case this file can file, in the order it files them.
#
# Named in one place because two branches below stop early -- the profile
# builder not lifting, and the bare build coming back empty -- and everything
# after such a stop has to be skipped *by name*. A case that files nothing on a
# lane its `applies-to` names is a hole, and a hole is indistinguishable from a
# lane that stopped reporting, which is the one thing the grid must never be
# unable to tell. `assert_` is not decoration on these two helpers: the registry
# scan in test/lib/selftest.sh follows ids through a variable only for a helper
# named assert_*, and an id reaching nt_skip through $c under any other name
# comes back as "in cases.tsv but emitted nowhere".
NT_CASES="confine.macos.lifted confine.macos.no-heredoc confine.macos.built
confine.macos.built-confined confine.macos.identical confine.macos.accepted
confine.macos.control.write confine.macos.write-denied
confine.macos.write-allowed confine.macos.control.exec confine.macos.noexec
confine.macos.nest.outside confine.macos.nest.inside confine.macos.messages"
NT_FILED=""

assert_filed() { NT_FILED="$NT_FILED $1"; }

assert_rest_skipped() {
    local c
    for c in $NT_CASES; do
        case " $NT_FILED " in
            *" $c "*) continue ;;
        esac
        nt_skip "$c" "$1"
    done
}

if [ "$(uname -s)" != "Darwin" ]; then
    echo "confine-macos.sh: not macOS; nothing here applies"
    assert_rest_skipped "this is not macOS; the seatbelt profile is not a thing here"
    nt_finish
fi
if [ ! -x /usr/bin/sandbox-exec ]; then
    echo "confine-macos.sh: no sandbox-exec on this machine"
    # A skip and not the failure this used to exit. A Mac with no sandbox-exec
    # is a machine that cannot be asked, which is the other half of the contract
    # every live half in this tree keeps -- and it used to leave the lane red
    # with no case named in it at all.
    assert_rest_skipped "no sandbox-exec on this machine, so nothing here can be asked"
    nt_finish
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
        nt_fail confine.macos.lifted "could not lift $fn out of the artifact; the shell region has moved"
        assert_filed confine.macos.lifted
        assert_rest_skipped "the profile builder did not come out of the artifact, so there is no profile to ask about"
        nt_finish
    fi
done
nt_pass confine.macos.lifted "lifted the profile builder out of the artifact"
assert_filed confine.macos.lifted

# A here-document in what was just lifted is the original defect returning by
# another route -- a second one added elsewhere in the same function, or the
# printf reverted. The text assertion below catches it under the sandbox that
# denies /tmp, and this says which line to look at when it does.
if grep -qE '<<-?[A-Za-z_'\''"]' "$GEN"; then
    nt_fail confine.macos.no-heredoc "the profile builder contains a here-document; bash 3.2 puts those in /tmp"
else
    nt_pass confine.macos.no-heredoc "the profile builder needs no temp file"
fi
assert_filed confine.macos.no-heredoc

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
    nt_pass confine.macos.built "built in a bare shell ($(wc -c < "$BARE" | tr -d ' ') bytes)"
    assert_filed confine.macos.built
else
    nt_fail confine.macos.built "profile expected=non-empty actual=$(wc -c < "$BARE" | tr -d ' ') bytes, stderr: $(tr '\n' ' ' < "$WORK/bare.err")"
    assert_filed confine.macos.built
    assert_rest_skipped "there is no profile text to compare, feed to seatbelt or probe with"
    nt_finish
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
    nt_pass confine.macos.built-confined "built inside a profile that denies /tmp"
else
    nt_fail confine.macos.built-confined "building inside an outer profile expected=ok actual=$(tr '\n' ' ' < "$WORK/confined.err")"
fi
assert_filed confine.macos.built-confined

# The regression assertion, and the sharpest one in this file. The old builder
# produced 1553 bytes in a bare shell and 0 under the profile above, and the
# launcher could not tell the difference between that and a profile seatbelt
# had refused.
if cmp -s "$BARE" "$CONFINED"; then
    nt_pass confine.macos.identical "the confined build is byte-identical to the bare one"
else
    nt_fail confine.macos.identical "profile text expected=identical actual=bare $(wc -c < "$BARE" | tr -d ' ') vs confined $(wc -c < "$CONFINED" | tr -d ' ') bytes"
fi
assert_filed confine.macos.identical

echo "=== Seatbelt takes it ==="

if /usr/bin/sandbox-exec -p "$(cat "$BARE")" /usr/bin/true >/dev/null 2>&1; then
    nt_pass confine.macos.accepted "sandbox-exec -p accepts the profile"
else
    nt_fail confine.macos.accepted "sandbox-exec expected=accepts actual=rejects: $(/usr/bin/sandbox-exec -p "$(cat "$BARE")" /usr/bin/true 2>&1 | tr '\n' ' ')"
fi
assert_filed confine.macos.accepted

echo "=== And what it takes confines ==="

# Each of these is asserted against an unconfined control, because a probe that
# fails for its own reasons -- a path that does not exist, a script that is not
# executable -- looks exactly like a confinement that worked.
OUTSIDE="$HOME/.neutrino-confine-probe.$$"
rm -f "$OUTSIDE"
if /bin/sh -c "echo x > '$OUTSIDE'" 2>/dev/null && [ -f "$OUTSIDE" ]; then
    # The control had no passing voice until now: it spoke only when it failed,
    # so the run where the whole apparatus worked filed nothing for it. That is
    # the case whose entire job is to stop a green from being an accident.
    nt_pass confine.macos.control.write "unconfined, a write to \$HOME does land, so the probe below means what it says"
    rm -f "$OUTSIDE"
    if /usr/bin/sandbox-exec -p "$(cat "$BARE")" \
            /bin/sh -c "echo x > '$OUTSIDE'" 2>/dev/null && [ -f "$OUTSIDE" ]; then
        nt_fail confine.macos.write-denied "a write to \$HOME expected=denied actual=written"
        rm -f "$OUTSIDE"
    else
        nt_pass confine.macos.write-denied "a write outside the app dir is denied"
    fi
else
    nt_fail confine.macos.control.write "the control write to \$HOME did not land; the probe proves nothing"
    nt_skip confine.macos.write-denied "the control write did not land, so a denial here would prove nothing"
fi
assert_filed confine.macos.control.write
assert_filed confine.macos.write-denied

if /usr/bin/sandbox-exec -p "$(cat "$BARE")" \
        /bin/sh -c "echo x > '$APPDIR/probe'" 2>/dev/null && [ -f "$APPDIR/probe" ]; then
    nt_pass confine.macos.write-allowed "a write to the app dir is allowed"
else
    nt_fail confine.macos.write-allowed "a write to the app dir expected=allowed actual=denied"
fi
assert_filed confine.macos.write-allowed

# Write xor execute, which is the reason the profile names every writable path
# in its process-exec* rule and not just the app dir.
printf '#!/bin/sh\necho ran\n' > "$APPDIR/exec-probe"
chmod +x "$APPDIR/exec-probe"
if [ "$("$APPDIR/exec-probe" 2>/dev/null)" = "ran" ]; then
    # Same as the write control above, and for the same reason.
    nt_pass confine.macos.control.exec "unconfined, the probe in the app dir does run, so the refusal below means what it says"
    if /usr/bin/sandbox-exec -p "$(cat "$BARE")" \
            "$APPDIR/exec-probe" >/dev/null 2>&1; then
        nt_fail confine.macos.noexec "executing from the app dir expected=denied actual=ran"
    else
        nt_pass confine.macos.noexec "what the app dir can hold, it cannot execute"
    fi
else
    nt_fail confine.macos.control.exec "the control exec did not run; the w^x probe proves nothing"
    nt_skip confine.macos.noexec "the control exec did not run, so a refusal here would prove nothing"
fi
assert_filed confine.macos.control.exec
assert_filed confine.macos.noexec

echo "=== A profile does not nest, which is why the driver asks before it applies ==="

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
    nt_pass confine.macos.nest.outside "the nesting probe is accepted outside a profile"
else
    nt_fail confine.macos.nest.outside "nesting probe expected=accepted outside a profile actual=refused"
fi
assert_filed confine.macos.nest.outside
if /usr/bin/sandbox-exec -f "$OUTER_SB" -D APPDIR="$APPDIR" \
        /usr/bin/sandbox-exec -p "$PROBE" /usr/bin/true >/dev/null 2>&1; then
    nt_fail confine.macos.nest.inside "nesting probe expected=refused inside a profile actual=accepted (macOS now nests; run_macos should apply its own profile under netinstall)"
else
    nt_pass confine.macos.nest.inside "the nesting probe is refused inside one"
fi
assert_filed confine.macos.nest.inside

# And the launcher's four messages, present in the artifact. A branch renamed
# without its assertion being renamed is a suite that asserts a string nothing
# prints, which is the failure mode this whole file exists to end.
# The profile is applied by the driver now, not by sandbox-exec, so the branches
# that can still speak are the shell's one and the driver's three. Named here
# because e2e.sh greps for exactly these, and a branch renamed without its
# assertion being renamed is a suite asserting a string nothing prints.
for msg in \
    "could not build the seatbelt profile" \
    "seatbelt refused this process's own profile" \
    "could not reach sandbox_init_with_parameters" \
    "could not register as an "
do
    # Without the "neutrino: " prefix, because note() adds that at run time and
    # the artifact carries only the text. The shell's one line has the prefix
    # written out; the driver's three do not, and one of them is split across a
    # source line, so each string here is a substring that survives the wrap.
    # One id for four messages, folded rather than split. test/report/matrix.py
    # takes the worst verdict when a lane reports a case more than once, which
    # is the same rule decoflip relies on running its probe under two decoration
    # settings: four branches missing and one missing are both "the artifact has
    # lost a branch e2e.sh greps for", and the sentence names which.
    if grep -qF "$msg" "$TARGET"; then
        nt_pass confine.macos.messages "the artifact can say \"$msg\""
    else
        nt_fail confine.macos.messages "the artifact has no \"$msg\" branch; e2e.sh greps for these"
    fi
done
assert_filed confine.macos.messages

echo ""
nt_finish
