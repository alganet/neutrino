#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# serve-target.sh - Serves test/ on loopback, and does not return until it answers.
#
# test/neutrinoearly.js navigates somewhere. That somewhere has to answer, or
# the navigation fails on its own and every driver reports "held" whether it
# has a guard or not -- measured, and the reason the target stopped being a
# host that never resolves.
#
# Backgrounding a server and carrying on is not enough, and this exists because
# it was tried: the lane that got there first found nothing listening. Waiting
# is not tidiness, it is the test's premise. The app must not be launched until
# the target is up, because a page that navigates into a closed port is back to
# measuring nothing.
#
# Prints the server's pid on stdout so the caller can kill it. Everything else
# goes to stderr, including the diagnostic written when it never comes up: the
# step that calls this dies before it reaches whatever it meant to print.
#
# Usage: PID="$(bash test/serve-target.sh [logfile])"

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${NEUTRINO_TARGET_PORT:-8098}"
URL="http://127.0.0.1:$PORT/early-target.html"
LOG="${1:-${TMPDIR:-/tmp}/neutrino-pages.log}"
WAIT=30

# httpserve.py and not `-m http.server`: the module's own server_bind does a
# reverse lookup on the address it just bound, which on macOS is what raises
# "Allow Python to find devices on local networks?" over every picture the lane
# takes afterwards. Same handler, same responses; see the file for the rest.
python3 "$HERE/httpserve.py" --bind 127.0.0.1 --directory "$HERE" "$PORT" > "$LOG" 2>&1 &
PID=$!

waited=0
while [ "$waited" -lt "$WAIT" ]; do
    # A server that died is not going to start answering, and the log says why
    # -- a port already taken is the likeliest, and it reads identically to a
    # slow start until you look.
    kill -0 "$PID" 2>/dev/null || break
    # No pipe: `curl | grep -q` under `set -o pipefail` reports failure when
    # grep exits early on a match, which reads as DOWN whatever happens.
    if curl -fsS -m 2 "$URL" -o "$LOG.body" 2>/dev/null &&
       grep -q "EARLY-TARGET" "$LOG.body"; then
        echo "$PID"
        exit 0
    fi
    sleep 1
    waited=$((waited + 1))
done

{
    echo "FAIL: nothing answering at $URL after ${waited}s of ${WAIT}"
    echo "FAIL: server alive: $(kill -0 "$PID" 2>/dev/null && echo yes || echo no)"
    echo "FAIL: server said: $(tr '\n' ' ' < "$LOG" 2>/dev/null | tail -c 200)"
} > "$LOG.diag"

cat "$LOG.diag" >&2
kill "$PID" 2>/dev/null || true
exit 1
