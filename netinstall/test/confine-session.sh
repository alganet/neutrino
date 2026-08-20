#!/bin/bash
# confine-session.sh - does the session tier close the bus, and does a webview
# still start once it has?
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
CONTROL="${2:-}"
TIGHT="${3:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: confine-session.sh <binary built with -DNEUTRINO_CONFINE_NOSESSION> [control binary]" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
[ -n "$CONTROL" ] && [ -x "$CONTROL" ] &&
    CONTROL="$(cd "$(dirname "$CONTROL")" && pwd)/$(basename "$CONTROL")"
[ -n "$TIGHT" ] && [ -x "$TIGHT" ] &&
    TIGHT="$(cd "$(dirname "$TIGHT")" && pwd)/$(basename "$TIGHT")"
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ "$(uname -s)" != "Linux" ]; then
    echo "=== SKIP: the session tier is linux-only ==="
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"
NT_BUS_PID=""

nt_serve "$SERVE" || exit 2
nt_cleanup() {
    kill $NT_SERVER_PID $NT_BUS_PID 2>/dev/null
    nt_userns_restore
    rm -rf "$WORK"
}
trap nt_cleanup EXIT

FAILURES=0

# A bus to close. Asserting that an absent bus cannot be reached would pass on a
# machine where the tier does nothing at all.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="$WORK/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
fi
if [ ! -S "$XDG_RUNTIME_DIR/bus" ] && command -v dbus-daemon >/dev/null 2>&1; then
    dbus-daemon --session --nofork --nopidfile \
        --address="unix:path=$XDG_RUNTIME_DIR/bus" >/dev/null 2>&1 &
    NT_BUS_PID=$!
    for _ in $(seq 1 50); do
        [ -S "$XDG_RUNTIME_DIR/bus" ] && break
        sleep 0.1
    done
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

cat > "$SERVE/session.cmd" <<'SCRIPT'
python3 -c "
import os, socket

def reach(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(path)
        return 'OK'
    except OSError as e:
        return type(e).__name__
    finally:
        s.close()

rt = os.environ.get('XDG_RUNTIME_DIR', '/run/user/%d' % os.getuid())
print('BUS_' + ('OK' if reach(rt + '/bus') == 'OK' else 'BLOCKED'))
print('SYSTEMBUS_' + ('OK' if reach('/run/dbus/system_bus_socket') == 'OK' else 'BLOCKED'))
print('RUNTIME:' + ' '.join(sorted(os.listdir(rt))))
print('PIDS:%d' % len([d for d in os.listdir('/proc') if d.isdigit()]))
" 2>/dev/null || echo "PROBE_FAILED"
if [ -n "${XAUTHORITY:-}" ] && cat "$XAUTHORITY" >/dev/null 2>&1; then echo "OWN_COOKIE_OK"; else echo "OWN_COOKIE_GONE"; fi
if cat "$HOME/.Xauthority" >/dev/null 2>&1; then echo "TRUSTED_COOKIE_READABLE"; else echo "TRUSTED_COOKIE_DENIED"; fi
if [ -n "${DISPLAY:-}" ] && command -v import >/dev/null 2>&1; then
    if import -window root -silent "$XDG_DATA_HOME/shot.png" 2>/dev/null; then echo "SCREENSHOT_OK"; else echo "SCREENSHOT_REFUSED"; fi
else
    echo "SCREENSHOT_SKIP"
fi
SCRIPT

SPEC="session-com-example-0$(nt_pin "$SERVE/session.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"

confine_line() {
    "$1" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }'
}

case "$(confine_line "$APP")" in
    *"session closed"*|*"session open"*|*"session half"*) ;;
    *)  nt_note "SKIP: this binary has no session tier ($(confine_line "$APP"))"
        exit 0 ;;
esac

# The lift comes before --info is read for real: that line is a measurement of
# the world the app is about to be launched into, and lifting the restriction
# afterwards would leave the suite asserting against a world that no longer
# exists. It did exactly that once, and reported the tier open while the run
# was closing the bus.
nt_tier_closes() {
    case "$(confine_line "$APP")" in
        *"session closed"*) return 0 ;;
    esac
    return 1
}

if ! nt_userns nt_tier_closes; then
    nt_summary "session tier could not apply here: $(confine_line "$APP")"
    nt_note "SKIP: no usable user namespace on this machine; the tier cannot apply"
    exit 0
fi
[ "$NT_USERNS_LIFTED" = "1" ] &&
    nt_summary "session tier measured with kernel.apparmor_restrict_unprivileged_userns lifted for the suite"

CONFINE="$(confine_line "$APP")"
nt_note "confinement: $CONFINE"

OUT="$("$APP" 2>"$WORK/err")"
echo "$OUT" | sed 's/^/  /'

check() {
    local label="$1" want="$2"
    if grep -qx "$want" <<<"$OUT"; then
        echo "  PASS: $label ($want)"
    else
        nt_fail "$label expected=$want actual=$(tr '\n' ' ' <<<"$OUT")"
        FAILURES=$((FAILURES + 1))
    fi
}

# Without this the assertions below could all be passing because the bus was
# never there. The control is a binary with no session tier, on the same clock.
if [ -n "$CONTROL" ]; then
    CSPEC="session-com-example-0$(nt_pin "$SERVE/session.cmd")"
    CAPP="$(nt_as "$CONTROL" "$CSPEC" "$WORK/bin-control")"
    COUT="$("$CAPP" 2>/dev/null)"
    if grep -qx BUS_OK <<<"$COUT"; then
        echo "  PASS: control -- an app without the tier reaches the session bus"
    else
        nt_fail "control expected=BUS_OK actual=$(tr '\n' ' ' <<<"$COUT"); nothing below measures anything"
        FAILURES=$((FAILURES + 1))
    fi
fi

echo "=== The session tier holds ==="
case "$CONFINE" in
    *"session closed"*)
        check "the session bus is unreachable" BUS_BLOCKED
        check "the system bus is unreachable"  SYSTEMBUS_BLOCKED
        RUNTIME="$(sed -n 's/^RUNTIME://p' <<<"$OUT")"
        case " $RUNTIME " in
            *" bus "*)
                nt_fail "the sealed runtime dir still has a bus in it: $RUNTIME"
                FAILURES=$((FAILURES + 1)) ;;
            *)  echo "  PASS: the runtime dir is sealed to an allowlist ($RUNTIME)" ;;
        esac
        PIDS="$(sed -n 's/^PIDS://p' <<<"$OUT")"
        if [ "${PIDS:-99}" -le 5 ] 2>/dev/null; then
            echo "  PASS: no process outside the namespace is visible ($PIDS in /proc)"
        else
            nt_fail "pid namespace expected=few actual=$PIDS processes visible"
            FAILURES=$((FAILURES + 1))
        fi ;;
    *)  nt_fail "the tier reported itself open on a machine that grants namespaces: $CONFINE"
        FAILURES=$((FAILURES + 1)) ;;
esac

echo "=== And the display it cannot hide ==="
case "$CONFINE" in
    *"x11 untrusted"*)
        # The server refuses a screen capture to an untrusted client. Measured
        # here from inside a real confined app rather than trusted to the
        # cookie's existence.
        check "the app cannot photograph the screen" SCREENSHOT_REFUSED ;;
    *)  nt_note "no untrusted cookie here (DISPLAY=${DISPLAY:-unset}); got $(grep -o 'SCREENSHOT_[A-Z]*' <<<"$OUT")" ;;
esac

# An untrusted cookie is only a boundary while the trusted one is out of reach,
# and in the default tier it is not: reads are unconfined, so an app can read
# ~/.Xauthority and connect trusted anyway. The claim is that the tight tier
# closes that, and a claim gets a measurement -- with the payload only, since
# confine-strict.sh already launches a webview under that tier.
case "$CONFINE" in
    *"x11 untrusted"*)
        echo "=== The untrusted cookie is only worth what the read rules make it ==="
        case "$OUT" in
            *TRUSTED_COOKIE_READABLE*)
                nt_summary "default tier: the trusted X cookie stays readable, so the untrusted one raises the bar rather than closing it" ;;
            *)  echo "  PASS: the trusted cookie is unreadable in this build" ;;
        esac
        if [ -n "$TIGHT" ]; then
            TSPEC="session-com-example-0$(nt_pin "$SERVE/session.cmd")"
            TAPP="$(nt_as "$TIGHT" "$TSPEC" "$WORK/bin-tight")"
            TOUT="$(NEUTRINO_HOME="$WORK/home-tight" "$TAPP" 2>/dev/null)"
            if grep -qx TRUSTED_COOKIE_DENIED <<<"$TOUT"; then
                echo "  PASS: with the tight tier the trusted cookie is out of reach"
            else
                nt_fail "tight tier expected=TRUSTED_COOKIE_DENIED actual=$(tr '\n' ' ' <<<"$TOUT")"
                FAILURES=$((FAILURES + 1))
            fi
            if grep -qx OWN_COOKIE_OK <<<"$TOUT"; then
                echo "  PASS: and the untrusted one it was given is still readable"
            else
                nt_fail "tight tier expected=OWN_COOKIE_OK actual=$(tr '\n' ' ' <<<"$TOUT")"
                FAILURES=$((FAILURES + 1))
            fi
        else
            nt_note "no tight+session binary passed in; that half is unmeasured here"
        fi ;;
esac

echo "=== Can a real webview still start under it? ==="
if [ -n "${DISPLAY:-}" ] && nt_linux_runtime; then
    bash "$ROOT/build.sh" "$ROOT/test/neutrinotest.js" "$SERVE/neutrinotest.cmd"
    GSPEC="neutrinotest-com-example-0$(nt_pin "$SERVE/neutrinotest.cmd")"
    GAPP="$(nt_as "$BIN" "$GSPEC" "$WORK/bin")"
    "$GAPP" > "$WORK/app.log" 2>&1 &
    GPID=$!
    nt_timeout 240 bash "$ROOT/test/verify-linux.sh" "${NEUTRINO_SCREENSHOTS:-$WORK/shots}/session"
    RC=$?
    nt_kill_tree $GPID
    if [ "$RC" -eq 0 ]; then
        nt_note "webview started with the session closed"
        echo "  PASS: webview works under the session tier"
    else
        nt_fail "webview failed under the session tier (rc=$RC); the tier is not viable as written"
        nt_note "app log: $(tr '\n' ' ' < "$WORK/app.log" 2>/dev/null | tail -c 400)"
        FAILURES=$((FAILURES + 1))
    fi
else
    nt_note "SKIP: no webview runtime here; viability untested"
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
