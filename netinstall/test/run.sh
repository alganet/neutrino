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

echo "### Building fail-closed binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING -DNEUTRINO_STRICT_SANDBOX" \
    bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-failclosed$NT_EXE"

echo "### Building offline binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING -DNEUTRINO_CONFINE_OFFLINE" \
    bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-offline$NT_EXE"

echo "### Building session binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING -DNEUTRINO_CONFINE_NOSESSION" \
    bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-session$NT_EXE"

echo "### Building session+tight binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING -DNEUTRINO_CONFINE_NOSESSION -DNEUTRINO_CONFINE_TIGHT" \
    bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-session-tight$NT_EXE"

# phases.sh needs the session tier built fail-closed: the half-closed states
# are asserted from both sides, and a build that refuses everything passes half
# of that on its own.
echo "### Building fail-closed session binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING -DNEUTRINO_CONFINE_NOSESSION -DNEUTRINO_STRICT_SANDBOX" \
    bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-failclosed-session$NT_EXE"

# fetchbound.sh needs the fallback branch built, because no machine anyone can
# rent resolves wget: curl is present on all five reporting lanes, so the branch
# whose bounds this PR added is otherwise never taken. The flag exists only
# under NEUTRINO_TESTING, so a release binary cannot be talked down to it.
echo "### Building prefer-wget binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING -DNEUTRINO_FETCH_PREFER_WGET" \
    bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-wget$NT_EXE"

echo "### Building strict-confinement binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING -DNEUTRINO_CONFINE_TIGHT" \
    bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-strict$NT_EXE"

# job-ui is an investigation, not a gate, and it costs ten minutes of windows CI
# per run. It answered its question -- see the README -- so it is opt-in now.
#
# pinfloor runs first, and the position is the point: GitHub keeps ten
# annotations per level per step and drops the rest without saying so, and this
# step already emits more results than that. A measurement taken last is a
# measurement nobody outside the runner gets to read.
SUITES="pinfloor fetchbound names verify confine confine-tight confine-strict confine-session privs env offline phases strict e2e"
# The BSDs have no webview on any runner that can be had, so e2e and env -- the
# two suites that launch one -- would fail for the absence of a toolkit rather
# than anything about the confinement. Everything that measures unveil and
# pledge stays in. confine-strict skips itself here (there is no tight tier on
# this platform) and says so, which is a statement and not a silent pass.
case "$(uname -s)" in
    OpenBSD|FreeBSD|NetBSD|DragonFly)
        SUITES="pinfloor fetchbound names verify confine confine-tight confine-strict offline phases strict" ;;
esac
# session.sh is a probe rather than a gate: it applies each candidate mechanism
# on its own to a real webview. It answered -- the session tier is what came of
# it, and confine-session.sh gates that -- so like job-ui it is opt-in now
# rather than costing eight webview launches on every push. The machinery stays
# for the next engine or kernel.
[ "${NEUTRINO_SESSION_PROBE:-}" = "1" ] && SUITES="$SUITES session"
[ "${NEUTRINO_JOB_UI_BISECT:-}" = "1" ] && SUITES="$SUITES job-ui"

for t in $SUITES; do
    echo
    echo "### $t.sh"
    case "$t" in
        names) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-release$NT_EXE" ;;
        confine-strict) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-strict$NT_EXE" ;;
        # Two binaries: the branch every machine actually takes, and the
        # fallback, whose two bounds come from the kernel and can therefore
        # only be asserted against a build that reaches it. The longer leash is
        # the clock assertion, which waits out a real deadline on purpose.
        fetchbound) nt_timeout 900 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-testing$NT_EXE" \
            "$HERE/../dist/netinstall-wget$NT_EXE" ;;
        # Three binaries: the tier, one without it as the control that says the
        # bus was there to be closed, and one with the tight tier on top, which
        # is where the untrusted X cookie stops being a bar and starts being a
        # boundary.
        confine-session) nt_timeout 600 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-session$NT_EXE" \
            "$HERE/../dist/netinstall-testing$NT_EXE" \
            "$HERE/../dist/netinstall-session-tight$NT_EXE" ;;
        offline) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-offline$NT_EXE" ;;
        # Nine real webview launches, most of them waiting out a timeout on
        # purpose, so this one needs a longer leash than the rest.
        job-ui) nt_timeout 1200 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-testing$NT_EXE" ;;
        strict) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-failclosed$NT_EXE" ;;
        # Five binaries, because both halves of this one are asserted from both
        # sides: what the fetch phase confines at each tier, and a session that
        # fails a step -- refused by the fail-closed build, survived by the one
        # that ships. No webview, so the default leash is enough.
        phases) nt_timeout 600 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-testing$NT_EXE" \
            "$HERE/../dist/netinstall-strict$NT_EXE" \
            "$HERE/../dist/netinstall-failclosed$NT_EXE" \
            "$HERE/../dist/netinstall-failclosed-session$NT_EXE" \
            "$HERE/../dist/netinstall-session$NT_EXE" ;;
        # confine.sh again, against the tight binary -- the /proc write grant is
        # the one rule that differs between the tiers. See the header of
        # confine-tight.sh for why it is the same instrument and not a second
        # payload.
        confine-tight) nt_timeout 600 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-strict$NT_EXE" ;;
        e2e)   nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-testing$NT_EXE" "${NEUTRINO_SCREENSHOTS:-}" ;;
        # Up to four real webview launches -- two with a loader knob pointed at
        # a module, two with the candidate deny set taken away -- and each one
        # is bounded by a wait it is allowed to lose. Same leash as job-ui for
        # the same reason.
        env)   nt_timeout 1200 bash "$HERE/$t.sh" \
            "$HERE/../dist/netinstall-testing$NT_EXE" \
            "$HERE/../dist/netinstall-strict$NT_EXE" ;;
        # Six real webview launches, two of them waiting out a timeout on
        # purpose, so this one needs the same longer leash as job-ui.
        session) nt_timeout 1200 bash "$HERE/$t.sh" "${NEUTRINO_SCREENSHOTS:-}" ;;
        *)     nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-testing$NT_EXE" ;;
    esac
    RC=$?
    # Whatever that suite left running is not the next suite's problem.
    nt_kill_app
    [ "$RC" -eq 124 ] && { echo "  $t.sh: timed out"; RC=1; }
    [ "$RC" -eq 0 ] || { echo "  $t.sh: $RC failure(s)"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=netinstall::$t.sh reported $RC failure(s)"; }
    # A finish marker per suite, so a hang localises to one suite instead of
    # taking the whole step down anonymously. In the summary rather than an
    # annotation: eight of these were crowding out the results they were meant
    # to help find, and annotations are capped per step.
    nt_summary "$t.sh finished rc=$RC"
    FAILURES=$((FAILURES + RC))
done

echo
echo "### Total: $FAILURES failure(s)"
exit $FAILURES
