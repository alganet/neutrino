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

echo "### Building strict-confinement binary"
NETINSTALL_CFLAGS="-DNEUTRINO_TESTING -DNEUTRINO_CONFINE_TIGHT" \
    bash "$HERE/../build.sh" host >/dev/null || exit 2
mv "$HERE/../dist/netinstall$NT_EXE" "$HERE/../dist/netinstall-strict$NT_EXE"

# job-ui is an investigation, not a gate, and it costs ten minutes of windows CI
# per run. It answered its question -- see the README -- so it is opt-in now.
SUITES="names verify confine confine-strict offline strict e2e"
[ "${NEUTRINO_JOB_UI_BISECT:-}" = "1" ] && SUITES="$SUITES job-ui"

for t in $SUITES; do
    echo
    echo "### $t.sh"
    case "$t" in
        names) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-release$NT_EXE" ;;
        confine-strict) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-strict$NT_EXE" ;;
        offline) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-offline$NT_EXE" ;;
        # Nine real webview launches, most of them waiting out a timeout on
        # purpose, so this one needs a longer leash than the rest.
        job-ui) nt_timeout 1200 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-testing$NT_EXE" ;;
        strict) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-failclosed$NT_EXE" ;;
        e2e)   nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-testing$NT_EXE" "${NEUTRINO_SCREENSHOTS:-}" ;;
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
