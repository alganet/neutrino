#!/bin/bash
# confine-strict.sh - does the tight tier hold, and can a webview still start?
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: confine-strict.sh <binary built with -DNEUTRINO_CONFINE_TIGHT>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
OUTSIDE="$HOME/.netinstall-outside-$$"
mkdir -p "$SERVE" "$WORK/bin" "$OUTSIDE"
export NEUTRINO_HOME="$WORK/home"
echo "top secret" > "$OUTSIDE/secret"

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -rf "$WORK" "$OUTSIDE"' EXIT

FAILURES=0

if [ "$NT_WINDOWS" = "1" ]; then
    export NEUTRINO_TEST_OUTSIDE="$(cygpath -w "$OUTSIDE")"
    cat > "$SERVE/nosy.cmd" <<'BATCH'
@echo off
> "%NEUTRINO_TEST_OUTSIDE%\pwned" echo owned 2>nul
if exist "%NEUTRINO_TEST_OUTSIDE%\pwned" (echo ESCAPED_OUTSIDE) else (echo OUTSIDE_BLOCKED)
> "%XDG_DATA_HOME%\ok" echo x 2>nul
if exist "%XDG_DATA_HOME%\ok" (echo OWN_DIR_OK) else (echo OWN_DIR_BLOCKED)
copy "%NEUTRINO_TEST_OUTSIDE%\secret" nul >nul 2>&1
if errorlevel 1 (echo SECRET_BLOCKED) else (echo READ_SECRET)
BATCH
else
    export NEUTRINO_TEST_OUTSIDE="$OUTSIDE"
    cat > "$SERVE/nosy.cmd" <<'SCRIPT'
if echo owned > "$NEUTRINO_TEST_OUTSIDE/pwned" 2>/dev/null; then echo "ESCAPED_OUTSIDE"; else echo "OUTSIDE_BLOCKED"; fi
if echo x > "$XDG_DATA_HOME/ok" 2>/dev/null; then echo "OWN_DIR_OK"; else echo "OWN_DIR_BLOCKED"; fi
if cat "$NEUTRINO_TEST_OUTSIDE/secret" >/dev/null 2>&1; then echo "READ_SECRET"; else echo "SECRET_BLOCKED"; fi
if cat /etc/hosts >/dev/null 2>&1; then echo "ETC_OK"; else echo "ETC_BLOCKED"; fi
if ls /usr/share >/dev/null 2>&1; then echo "USR_OK"; else echo "USR_BLOCKED"; fi
nt_true=""
for c in /bin/true /usr/bin/true; do [ -x "$c" ] && { nt_true="$c"; break; }; done
echo "EXECSRC:${nt_true:-none}"
if [ -n "$nt_true" ] && cp "$nt_true" "$XDG_DATA_HOME/probe" 2>/dev/null &&
   chmod +x "$XDG_DATA_HOME/probe" 2>/dev/null; then
    if "$XDG_DATA_HOME/probe" 2>/dev/null; then echo "EXEC_OWN_DIR"; else echo "EXEC_BLOCKED"; fi
else
    echo "EXEC_NOCOPY"
fi
SCRIPT
fi

SPEC="nosy-example-com-1$(nt_pin "$SERVE/nosy.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"

OUT="$(nt_timeout 60 "$APP" 2>"$WORK/err" | tr -d "\r")"
CONFINE="$("$APP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
nt_note "confinement: $CONFINE"

if ! nt_tight_tier "$CONFINE"; then
    nt_note "SKIP: this binary has no tight confinement ($CONFINE)"
    exit 0
fi

check() {
    local label="$1" want="$2"
    if grep -qx "$want" <<<"$OUT"; then
        echo "  PASS: $label ($want)"
    else
        nt_fail "$label expected=$want actual=$(tr '\n' ' ' <<<"$OUT")"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== The tight tier holds ==="
check "writes outside the app dir are blocked" OUTSIDE_BLOCKED
check "its own dir stays writable"             OWN_DIR_OK

if [ "$NT_WINDOWS" = "1" ]; then
    # Low integrity is a no-write-up rule, not a no-read-up one. Asserting the
    # limitation keeps the README honest rather than implying reads are covered.
    check "reads are NOT confined at low integrity" READ_SECRET
else
    check "a secret outside is unreadable" SECRET_BLOCKED
    check "system config stays readable"   ETC_OK
    check "system data stays readable"     USR_OK
    check "cannot execute what it wrote"   EXEC_BLOCKED
fi

# The open question this suite exists to answer: the tier has to keep a real
# webview alive, or it is not worth having.
#
# "Alive" is the whole of it, and nt_app_probe in lib.sh is what asks. This
# section used to run test/verify-linux.sh and its two siblings, which assert
# neutrino's six-state window contract -- a question this lane's own launch
# steps have already answered, minutes earlier, outside any sandbox.
echo "=== Can a real webview still start under it? ==="
bash "$ROOT/test/mkapp.sh" --tier=testing "$NT_TESTDIR/alive.js" "$SERVE/alive.cmd"
GSPEC="alive-example-com-1$(nt_pin "$SERVE/alive.cmd")"
GAPP="$(nt_as "$BIN" "$GSPEC" "$WORK/bin")"
GAPPDIR="$NEUTRINO_HOME/apps/$(nt_appkey "$GSPEC")/alive"
STATE=""

if [ "$NT_WINDOWS" = "1" ]; then
    "$GAPP" > "$WORK/app.log" 2>&1 &
    GPID=$!
    for _ in $(seq 1 120); do
        [ -f "$GAPPDIR/alive.exe" ] && break
        sleep 1
    done
    if [ -f "$GAPPDIR/alive.exe" ]; then
        echo "  PASS: jsc.exe still compiles at low integrity"
    else
        nt_fail "jsc.exe did not compile at low integrity"
        FAILURES=$((FAILURES + 1))
    fi
    STATE="$(nt_app_probe 120)"
    nt_kill_tree $GPID
elif [ "$(uname -s)" = "Darwin" ]; then
    nt_app_gone
    "$GAPP" > "$WORK/app.log" 2>&1 &
    GPID=$!
    STATE="$(nt_app_probe 180)"
    nt_kill_tree $GPID
elif [ -n "${DISPLAY:-}" ] && nt_linux_runtime; then
    nt_app_gone
    "$GAPP" > "$WORK/app.log" 2>&1 &
    GPID=$!
    STATE="$(nt_app_probe 120)"
    nt_kill_tree $GPID
else
    nt_note "SKIP: no webview runtime here; viability untested"
fi

# The viewport alive.js announced from a frame callback, or empty if no frame
# ever came. Printed on every platform because it is a reading, and asserted on
# Windows because there it is the question. Microsoft documents low integrity as
# leaving WebView2 with a window and no rendering, and this repository believed
# that in prose for a long time -- while its own CI recorded the opposite on
# every run, because nothing here asserted the difference and "a script ran"
# cannot see it. It is asserted now, in the direction the measurement points:
# green means a frame with a size on it, and a return to what the vendor
# documents goes red rather than quietly back into a comment.
FRAME="$(nt_app_frame)"

case "$STATE" in
    "") ;;
    CONTENT_OK)
        nt_note "webview started under tight confinement, viewport ${FRAME:-<no frame announced>}"
        case "$FRAME" in
            ""|0x*|*x0)
                if [ "$NT_WINDOWS" = "1" ]; then
                    # This is the shape the README's long-standing claim
                    # predicts, and until now nothing here could see it: the
                    # process lives, the page runs, and the view never gets as
                    # far as a frame with a size on it.
                    nt_fail "the webview ran but scheduled no frame with a size (viewport ${FRAME:-none}); the tight tier is not viable for GUI apps on windows"
                    FAILURES=$((FAILURES + 1))
                else
                    nt_note "no viewport was announced (${FRAME:-none}); the frame half is unmeasured on this lane"
                fi ;;
            *)
                echo "  PASS: webview works under the tight tier, laid out at $FRAME" ;;
        esac ;;
    NO_WINDOW|WINDOW_NO_CONTENT)
        # Windows used to be excused here, on the strength of a documented
        # limitation this lane has never actually reproduced. That excuse was
        # load-bearing in the wrong direction: it meant the one platform whose
        # tier was most suspect was also the only one where a webview failing to
        # come up produced a green tick and a note. Every platform fails now.
        # If low integrity does start behaving as Microsoft documents, the way
        # to find out is a red lane, and the state says which half went --
        # WINDOW_NO_CONTENT is the renderer, NO_WINDOW is a process that never
        # got that far.
        nt_fail "webview failed under tight confinement ($STATE); this tier is not viable as written"
        nt_note "app log: $(tr '\n' ' ' < "$WORK/app.log" 2>/dev/null | tail -c 400)"
        FAILURES=$((FAILURES + 1)) ;;
    *)
        # Not a reading about the tier at all. Kept apart from the two states
        # above so that a probe which could not run is never filed as the
        # Windows limitation it happens to resemble.
        nt_fail "the webview probe did not report a state ($STATE)"
        FAILURES=$((FAILURES + 1)) ;;
esac

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
