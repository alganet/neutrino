#!/bin/bash
# run.sh - build netinstall and run the whole suite
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
FAILURES=0

echo "### Building release binary"
bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-release$NT_EXE"

echo "### Building test binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING" bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-testing$NT_EXE"

# fetchbound.sh needs the fallback branch built, because no machine anyone can
# rent resolves wget: curl is present on all five reporting lanes, so the branch
# whose bounds this PR added is otherwise never taken. The flag exists only
# under NEUTRINO_TESTING, so a release binary cannot be talked down to it.
echo "### Building prefer-wget binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING -DNEUTRINO_FETCH_PREFER_WGET" \
    bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-wget$NT_EXE"

# job-ui is an investigation, not a gate, and it costs ten minutes of windows CI
# per run. It answered its question -- see the README -- so it is opt-in now.
#
# pinfloor runs first. The position used to be the point -- annotations were
# capped and dropped silently, so a measurement taken last was one nobody
# outside the runner could read -- and that reason has gone with the
# annotations: the whole log is fetchable now and order costs a reader nothing.
# It stays in front because a floor that fails should fail before the suites
# resting on it, which was always the better half of the argument.
#
# envlen and writable sit behind them, which is where env.sh and confine.sh
# already are. That is what being asserted rather than
# reported buys: a green tick is its whole answer, and its report lines are for
# whoever is already reading the log. Each of them was in front for exactly one
# round, to put its own after-values on the record once -- envlen for PR 15 and
# writable for PR 16. A failure is an ::error, which has a bucket of its own, so
# nothing that matters is lost back here.
#
# fetchconf sits back here beside envlen and writable, and for the same reason:
# it was in front for exactly the rounds that had to put its readings on the
# record -- three probing and one candidate -- and it is an assertion suite now.
# Its reports fall past the cap, a green tick is its whole answer, and a failure
# is an ::error, which has a bucket of its own.
#
# crashdump and landlockfloor are in front for the same reason envlen and
# writable each were, for one round: they are probes whose whole output is a
# reading somebody has to act on, and a reading taken last is one nobody scrolls
# to. Both come out of this list once they have answered. Neither costs anything
# on a platform it does not apply to -- crashdump is windows, landlockfloor is
# linux with docker, and each says which it was rather than passing silently.
SUITES="pinfloor crashdump landlockfloor fetchbound envlen writable fetchconf names verify confine privs env phases splash e2e"
# The BSDs have no webview on any runner that can be had, so e2e and env -- the
# two suites that launch one -- would fail for the absence of a toolkit rather
# than anything about the confinement. Everything that measures unveil and
# pledge stays in.
case "$(uname -s)" in
    OpenBSD|FreeBSD|NetBSD|DragonFly)
        SUITES="pinfloor fetchbound envlen writable fetchconf names verify confine phases splash" ;;
esac
[ "${NEUTRINO_JOB_UI_BISECT:-}" = "1" ] && SUITES="$SUITES job-ui"

# A caller may name the list outright, and there is one reason to.
#
# Almost everything above is a question about a kernel: what Landlock refuses,
# what seccomp refuses, what bounds curl is given, what the environment
# allowlist drops. None of it knows what a webview is. `gjs` and `kde` are both
# ubuntu-latest -- same kernel, both reporting landlock abi 7 -- so running the
# whole list on both is the same measurement taken twice on the same machine.
# Measured on run 33674586566, that is about 170 s a push: fetchbound at 130,
# fetchconf at 34, and a dozen suites at a second or two each.
#
# What genuinely differs between those two lanes is the toolkit, so that is what
# the second one is asked for: `env` (the loader knobs are GTK's on one and Qt's
# on the other) and `e2e`, which puts a real webview under the confinement.
#
# Last, and after the opt-in probes, so an explicit list wins over everything
# above it. That is the point of naming one.
#
# It does not shorten the build block: all three binaries are still built,
# because the builds are seconds on a machine with a compiler and a suite list
# that quietly changed what was compiled would be a worse thing to own.
[ -n "${NEUTRINO_SUITES:-}" ] && SUITES="$NEUTRINO_SUITES"

# Where the wall clock went, per suite, in the order they ran.
#
# The whole suite costs 5 minutes on ubuntu and 14.5 on macos, and until this
# was measured the difference was attributed to the runner being slower. It is
# not: fifteen suites that take under two seconds on Linux take thirty-seven
# apiece on macOS, and thirteen of those thirty-seven are spent before the suite
# prints its first line. A per-suite number is what turns "macOS is slow" into a
# name, and it costs one variable.
TIMINGS=""

for t in $SUITES; do
    echo
    echo "### $t.sh"
    SUITE_T0=$SECONDS
    case "$t" in
        names) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-release$NT_EXE" ;;
        # No binary. Both build or find their own instrument: crashdump compiles
        # crash-probe.c, because what it measures is what WER does with an
        # unhandled exception and netinstall is not the thing that has to raise
        # it; landlockfloor wants the static musl build rather than the host one,
        # since a host binary would fail to start on half the images it visits
        # for a reason that is not about Landlock.
        #
        # Four crashes, each bounded and each followed by a wait for an
        # asynchronous reporter, so this one needs more than the default leash.
        crashdump) nt_timeout 900 bash "$HERE/$t.sh" ;;
        # Seven image pulls before any of them runs.
        landlockfloor) nt_timeout 1200 bash "$HERE/$t.sh" ;;
        writable) nt_timeout 600 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-testing$NT_EXE" ;;
        # Two binaries: the branch every machine actually takes, and the
        # fallback, whose two bounds come from the kernel and can therefore
        # only be asserted against a build that reaches it. The longer leash is
        # the clock assertion, which waits out a real deadline on purpose.
        fetchbound) nt_timeout 900 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-testing$NT_EXE" \
            "$HERE/../dist/netinstall-wget$NT_EXE" ;;
        # Two binaries, for the same reason fetchbound takes them: the question
        # is what else is on each downloader's command line, and the fallback is
        # the branch whose bounds are not on one at all.
        fetchconf) nt_timeout 900 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-testing$NT_EXE" \
            "$HERE/../dist/netinstall-wget$NT_EXE" ;;
        # Nine real webview launches, most of them waiting out a timeout on
        # purpose, so this one needs a longer leash than the rest.
        job-ui) nt_timeout 1200 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-testing$NT_EXE" ;;
        # One binary. This took five while the tiers existed -- what the fetch
        # phase confined at each, and a session that failed a step, refused by
        # the fail-closed build and survived by the one that shipped.
        phases) nt_timeout 600 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-testing$NT_EXE" ;;
        # Up to four real webview launches -- two with a loader knob pointed at
        # a module, two with the candidate deny set taken away -- and each one
        # is bounded by a wait it is allowed to lose. Same leash as job-ui for
        # the same reason.
        env)   nt_timeout 1200 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-testing$NT_EXE" ;;
        *)     nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-testing$NT_EXE" ;;
    esac
    RC=$?
    # Whatever that suite left running is not the next suite's problem.
    nt_kill_app
    [ "$RC" -eq 124 ] && { echo "  $t.sh: timed out"; RC=1; }
    [ "$RC" -eq 0 ] || { echo "  $t.sh: $RC failure(s)"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=netinstall::$t.sh reported $RC failure(s)"; }
    # A finish marker per suite, so a hang localises to one suite instead of
    # taking the whole step down anonymously. It goes to the step summary, which
    # renders on the run page and has no cap.
    SUITE_SECS=$((SECONDS - SUITE_T0))
    TIMINGS="$TIMINGS$(printf '%5ds  %s\n' "$SUITE_SECS" "$t.sh")
"
    nt_summary "$t.sh finished rc=$RC in ${SUITE_SECS}s"
    FAILURES=$((FAILURES + RC))
done

# Sorted, because the question this answers is "what is the expensive one" and
# a reader should not have to scan a list in run order to find out. The run
# order is above, one line per suite, for whoever wants it.
echo
echo "### Where the time went"
printf '%s' "$TIMINGS" | sort -rn
echo
echo "### Total: $FAILURES failure(s)"
exit $FAILURES
