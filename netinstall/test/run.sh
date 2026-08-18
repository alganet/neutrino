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

for t in names verify confine e2e; do
    echo
    echo "### $t.sh"
    case "$t" in
        names) nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-release$NT_EXE" ;;
        e2e)   nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-testing$NT_EXE" "${NEUTRINO_SCREENSHOTS:-}" ;;
        *)     nt_timeout 600 bash "$HERE/$t.sh" "$HERE/../dist/netinstall-testing$NT_EXE" ;;
    esac
    RC=$?
    [ "$RC" -eq 124 ] && { echo "  $t.sh: timed out"; RC=1; }
    [ "$RC" -eq 0 ] || { echo "  $t.sh: $RC failure(s)"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=netinstall::$t.sh reported $RC failure(s)"; }
    # A finish marker per suite, so a hang localises to one suite in the
    # annotations instead of taking the whole step down anonymously.
    nt_note "$t.sh finished rc=$RC"
    FAILURES=$((FAILURES + RC))
done

echo
echo "### Total: $FAILURES failure(s)"
exit $FAILURES
