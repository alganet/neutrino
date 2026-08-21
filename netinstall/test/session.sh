#!/bin/bash
# session.sh - what closes the session bus and X11, and what it costs
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# This is a probe, not a gate. It applies each candidate for closing the two
# holes the README calls out -- the session bus and the X11 display -- on its
# own, against a real webview, with an unconfined control on the same clock
# either side of the table and one lane that has to die. The session tier is
# what came of it and confine-session.sh gates that; this stays so a future
# engine or kernel can be re-measured in one command.

set -uo pipefail

. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
SHOTS="${1:-}"

if [ "$(uname -s)" != "Linux" ]; then
    echo "=== SKIP: namespaces and X11 are linux questions ==="
    exit 0
fi

# A probe whose whole output is its measurements uses the shared results
# channel for all of them; see nt_result in lib.sh for why that is not the
# notice one.
nt_probe() {
    nt_result "$@"
}

WORK="$(mktemp -d)"
[ -n "$SHOTS" ] || SHOTS="$WORK/screenshots"
mkdir -p "$SHOTS"
PROBE="$WORK/session-probe"
FAILURES=0
NT_BUS_PID=""

nt_cleanup() {
    [ -n "$NT_BUS_PID" ] && kill "$NT_BUS_PID" 2>/dev/null
    nt_userns_restore
    rm -rf "$WORK"
}
trap nt_cleanup EXIT

echo "=== Build the probe ==="
CC="${NETINSTALL_CC:-cc}"
if ! $CC -O1 -Wall -o "$PROBE" "$HERE/session-probe.c" 2>"$WORK/cc.log"; then
    nt_fail "session-probe did not build: $(tail -3 "$WORK/cc.log" | tr '\n' ' ')"
    exit 1
fi
echo "  built $PROBE"

# A bus to hide. The kde lane runs the suite under dbus-run-session and the gjs
# lane does not, so without this half the table would be measuring an absence.
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
    echo "  started a session bus at $XDG_RUNTIME_DIR/bus"
fi

echo "=== What this machine will hand out ==="
"$PROBE" --report > "$WORK/report.txt" 2>&1
cat "$WORK/report.txt"
nt_summary "session-probe report: $(tr '\n' '; ' < "$WORK/report.txt")"

USERNS_OK=0
grep -qx "userns+mountns: ok" "$WORK/report.txt" && USERNS_OK=1
PIDNS_OK=0
grep -qx "userns+pidns: ok" "$WORK/report.txt" && PIDNS_OK=1
NS_LIFTED=0

# The probe's own binary is what gets asked, not util-linux's unshare: on Ubuntu
# that one carries an AppArmor profile letting it do what an unprofiled binary
# cannot, so it would answer for itself rather than for anything netinstall
# ships. Where the answer is no, the restriction is lifted for the length of
# this run, recorded, and put back. Nothing shipped may do that.
nt_probe_userns() {
    "$PROBE" --report > "$WORK/report.txt" 2>&1
    grep -qx "userns+mountns: ok" "$WORK/report.txt"
}

if [ "$USERNS_OK" != "1" ] && nt_userns nt_probe_userns; then
    USERNS_OK=1
    grep -qx "userns+pidns: ok" "$WORK/report.txt" && PIDNS_OK=1
    if [ "$NT_USERNS_LIFTED" = "1" ]; then
        NS_LIFTED=1
        nt_probe "namespaces: refused by the distribution default; measured below with kernel.apparmor_restrict_unprivileged_userns=0"
    fi
fi
if [ "$NS_LIFTED" = "0" ]; then
    nt_probe "namespaces as this machine hands them out: $(grep '^userns' "$WORK/report.txt" | tr '\n' ' ')"
fi
nt_probe "landlock here: $(grep '^landlock' "$WORK/report.txt"), yama $(awk -F': ' '/ptrace_scope/ { print $2 }' "$WORK/report.txt"), proc-root escape $(awk -F': ' '/proc-root-escape/ { print $2 }' "$WORK/report.txt")"

# The payload every lane runs: what can it still reach?
cat > "$WORK/reach.py" <<'PY'
import os, socket, sys

def unix(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(path)
        return "OK"
    except OSError as e:
        return type(e).__name__
    finally:
        s.close()

rt = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
print("BUS", unix(rt + "/bus"))
print("SYSTEMBUS", unix("/run/dbus/system_bus_socket"))
display = os.environ.get("DISPLAY", "")
screen = display.split(":")[-1].split(".")[0] if ":" in display else "0"
print("X11", unix("/tmp/.X11-unix/X" + screen))

# An X client asks for the abstract name first, and the abstract namespace is a
# property of the network namespace -- so covering the directory does not touch
# it. This is the difference between hiding the display and closing it.
a = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    a.connect("\0/tmp/.X11-unix/X" + screen)
    print("X11ABSTRACT OK")
except OSError as e:
    print("X11ABSTRACT", type(e).__name__)
finally:
    a.close()

# The abstract namespace lives in the network namespace, not the mount one.
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect("\0" + sys.argv[1])
    print("ABSTRACT OK")
except OSError as e:
    print("ABSTRACT", type(e).__name__)
finally:
    s.close()

t = socket.socket()
t.settimeout(5)
try:
    t.connect(("127.0.0.1", int(sys.argv[2])))
    print("TCPLOCAL OK")
except OSError as e:
    print("TCPLOCAL", type(e).__name__)
finally:
    t.close()

# Loopback says nothing about the internet -- it is per-namespace, and a UDP
# sendto to a local port succeeds whether or not anything is there. The offline
# question needs an address that has to be routed.
n = socket.socket()
n.settimeout(4)
try:
    n.connect(("1.1.1.1", 80))
    print("TCPNET OK")
except OSError as e:
    print("TCPNET", type(e).__name__, e.errno)
finally:
    n.close()

u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    u.sendto(b"probe", ("1.1.1.1", 53))
    print("UDPNET OK")
except OSError as e:
    print("UDPNET", type(e).__name__, e.errno)
finally:
    u.close()
PY

# Two listeners outside every namespace, so a refusal is the technique and not a
# dead port. A name that resolves to nothing answers ECONNREFUSED either way.
ABSTRACT_NAME="neutrino-session-probe-$$"
python3 - "$ABSTRACT_NAME" <<'PY' >"$WORK/listener.port" 2>/dev/null &
import socket, sys, time
a = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
a.bind("\0" + sys.argv[1])
a.listen(8)
t = socket.socket()
t.bind(("127.0.0.1", 0))
t.listen(8)
print(t.getsockname()[1], flush=True)
time.sleep(900)
PY
NT_LISTENER_PID=$!
for _ in $(seq 1 50); do
    [ -s "$WORK/listener.port" ] && break
    sleep 0.1
done
PORT="$(cat "$WORK/listener.port" 2>/dev/null)"
[ -n "$PORT" ] || PORT=1
trap 'kill $NT_LISTENER_PID 2>/dev/null; nt_cleanup' EXIT

reach() {
    "$@" python3 "$WORK/reach.py" "$ABSTRACT_NAME" "$PORT" 2>&1
}

want() {
    local out="$1" key="$2" want="$3" label="$4"
    local got
    got="$(awk -v k="$key" '$1 == k { print $2 }' <<<"$out")"
    if [ "$got" = "$want" ]; then
        echo "  PASS: $label ($key=$got)"
    else
        nt_fail "$label: $key expected=$want actual=${got:-nothing}"
        FAILURES=$((FAILURES + 1))
    fi
}

# Which refusal arrives is the kernel's business and varies with the technique:
# a covered socket answers ECONNREFUSED, a hidden directory ENOENT, an
# unroutable address ENETUNREACH. What matters is that it is not a connection.
denied() {
    local out="$1" key="$2" label="$3"
    local got
    got="$(awk -v k="$key" '$1 == k { print $2 }' <<<"$out")"
    if [ -n "$got" ] && [ "$got" != "OK" ]; then
        echo "  PASS: $label ($key=$got)"
    else
        nt_fail "$label: $key expected=refused actual=${got:-nothing}"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== Control: what an unconfined process reaches ==="
CONTROL="$(reach env)"
echo "$CONTROL" | sed 's/^/  /'
want "$CONTROL" BUS OK "the session bus is reachable unconfined"
want "$CONTROL" X11 OK "the display is reachable unconfined"
want "$CONTROL" ABSTRACT OK "an abstract socket is reachable unconfined"
want "$CONTROL" TCPLOCAL OK "a local tcp listener is reachable unconfined"
nt_note "unconfined reach: tcp=$(awk '$1=="TCPNET"{print $2}' <<<"$CONTROL") udp=$(awk '$1=="UDPNET"{print $2}' <<<"$CONTROL")"

if [ "$USERNS_OK" = "1" ]; then
    echo "=== Technique: cover the buses in a mount namespace ==="
    HIDDEN="$(reach "$PROBE" --hide-bus --hide-agents --)"
    echo "$HIDDEN" | sed 's/^/  /'
    want "$HIDDEN" BUS ConnectionRefusedError "the session bus is gone"
    want "$HIDDEN" SYSTEMBUS ConnectionRefusedError "the system bus is gone"
    want "$HIDDEN" X11 OK "the display still works, which is the point"

    # The covers above are a denylist of socket names, which is the shape this
    # project distrusts everywhere else. The allowlist version is a fresh tmpfs
    # over the runtime dir with only the compositor and audio sockets bound back.
    echo "=== Technique: seal the runtime dir, keep the compositor and audio ==="
    SEALRT="$(reach "$PROBE" --seal-runtime --)"
    echo "$SEALRT" | sed 's/^/  /'
    denied "$SEALRT" BUS "the session bus is gone without being named"
    nt_probe "sealing the runtime dir leaves the system bus: SYSTEMBUS=$(awk '$1=="SYSTEMBUS"{print $2}' <<<"$SEALRT")"
    nt_probe "runtime dir after the seal: $("$PROBE" --seal-runtime -- ls -A "$XDG_RUNTIME_DIR" 2>/dev/null | tr '\n' ' ')"

    echo "=== Technique: and the display sockets too ==="
    NOX="$(reach "$PROBE" --hide-bus --hide-x11 --)"
    echo "$NOX" | sed 's/^/  /'
    denied "$NOX" X11 "the X11 pathname socket is gone"
    nt_probe "hiding the X11 directory leaves the abstract name: X11ABSTRACT=$(awk '$1=="X11ABSTRACT"{print $2}' <<<"$NOX")"

    echo "=== Technique: everything at once, for a session with no X11 in it ==="
    SEALED="$(reach "$PROBE" --hide-bus --hide-agents --hide-x11 --netns --pidns --)"
    echo "$SEALED" | sed 's/^/  /'
    denied "$SEALED" BUS "sealed: no session bus"
    denied "$SEALED" X11 "sealed: no X11 pathname socket"
    denied "$SEALED" X11ABSTRACT "sealed: no X11 abstract socket either"
    denied "$SEALED" ABSTRACT "sealed: no abstract sockets at all"

    if [ "$PIDNS_OK" = "1" ]; then
        echo "=== Technique: a pid namespace closes the way back ==="
        PIDNS="$(reach "$PROBE" --hide-bus --pidns --)"
        echo "$PIDNS" | sed 's/^/  /'
        want "$PIDNS" BUS ConnectionRefusedError "the session bus is gone under a pid namespace too"
        ESCAPE="$("$PROBE" --hide-bus --pidns -- sh -c 'ls /proc | grep -c "^[0-9]*$"' 2>&1 | tail -1)"
        if [ "${ESCAPE:-99}" -le 3 ] 2>/dev/null; then
            echo "  PASS: no process outside the namespace is listed in /proc ($ESCAPE entries)"
        else
            nt_fail "pid namespace: /proc still lists $ESCAPE processes"
            FAILURES=$((FAILURES + 1))
        fi
    else
        nt_note "no pid namespace here; the /proc/<pid>/root way back is only closed by Yama"
    fi

    # The offline tier is documented as TCP-only, because that is all Landlock
    # can express. A network namespace is the mechanism that does not have that
    # shape of hole -- and it closes the abstract socket namespace on the way,
    # which is the one scoping can only reach when there is no X11 display.
    echo "=== Technique: a network namespace, for the offline tier ==="
    NETNS="$(reach "$PROBE" --netns --)"
    echo "$NETNS" | sed 's/^/  /'
    denied "$NETNS" TCPLOCAL "a listener outside the namespace is unreachable"
    denied "$NETNS" ABSTRACT "the abstract namespace is gone with it"
    if [ "$(awk '$1=="TCPNET"{print $2}' <<<"$CONTROL")" = "OK" ]; then
        denied "$NETNS" TCPNET "outbound tcp is gone"
        denied "$NETNS" UDPNET "outbound udp is gone, which landlock cannot do"
    else
        nt_note "this machine has no route out unconfined, so the offline half is unmeasured"
    fi
    nt_note "a network namespace leaves the buses alone: BUS=$(awk '$1=="BUS"{print $2}' <<<"$NETNS")"
else
    nt_note "no user namespace here: $(grep '^userns' "$WORK/report.txt" | tr '\n' ' ')"
    nt_note "every namespace technique below is unavailable on this machine"
fi

echo
echo "=== The other half: X11 ==="
# Hiding the display is not on the table when the app needs it, so the only
# lever left is the SECURITY extension: generate an untrusted cookie, hand the
# app that one, and the server itself refuses the requests that make X11 an
# escape. What it costs is a much shorter extension list, which is exactly what
# a toolkit might not survive.
UNTRUSTED=""
if [ -z "${DISPLAY:-}" ]; then
    nt_note "no display here; the X11 half is unmeasured"
elif ! command -v xauth >/dev/null 2>&1; then
    nt_note "no xauth here; the X11 half is unmeasured"
else
    UNTRUSTED="$WORK/untrusted.xauth"
    : > "$UNTRUSTED"
    if xauth -f "$UNTRUSTED" generate "$DISPLAY" MIT-MAGIC-COOKIE-1 untrusted \
            timeout 0 >"$WORK/xauth.log" 2>&1; then
        echo "  generated an untrusted cookie for $DISPLAY"
    else
        nt_note "xauth generate failed: $(tr '\n' ' ' < "$WORK/xauth.log")"
        UNTRUSTED=""
    fi
fi

if [ -n "$UNTRUSTED" ] && command -v xdpyinfo >/dev/null 2>&1; then
    TRUSTED_EXT="$(xdpyinfo 2>/dev/null | awk '/number of extensions/ { print $4 }')"
    UNTRUSTED_EXT="$(XAUTHORITY="$UNTRUSTED" xdpyinfo 2>/dev/null | awk '/number of extensions/ { print $4 }')"
    nt_probe "x11 extensions: trusted=${TRUSTED_EXT:-?} untrusted=${UNTRUSTED_EXT:-?}"
    nt_summary "x11 untrusted extension list: $(XAUTHORITY="$UNTRUSTED" xdpyinfo 2>/dev/null |
        sed -n '/number of extensions/,/^default screen/p' | sed '1d;$d' | tr -d ' ' | tr '\n' ' ')"
fi

if [ -n "$UNTRUSTED" ] && command -v import >/dev/null 2>&1; then
    echo "=== Can an untrusted client photograph the screen? ==="
    if import -window root -silent "$WORK/trusted.png" >/dev/null 2>&1 &&
       [ -s "$WORK/trusted.png" ]; then
        echo "  PASS: control -- a trusted client screenshots the root window"
    else
        nt_fail "screenshot control expected=captured actual=failed; the pair below measures nothing"
        FAILURES=$((FAILURES + 1))
    fi
    if XAUTHORITY="$UNTRUSTED" import -window root -silent "$WORK/untrusted.png" \
            >/dev/null 2>&1 && [ -s "$WORK/untrusted.png" ]; then
        nt_probe "x11 untrusted: screen capture STILL WORKS"
    else
        nt_probe "x11 untrusted: screen capture refused by the server"
    fi
fi

# Keylogging is the other half of what X11 hands out, and it is not the same
# question as screen capture: XTEST and RECORD are extensions an untrusted
# client does not get, but XGrabKeyboard and XQueryKeymap are core protocol.
cat > "$WORK/snoop.py" <<'PY'
import ctypes, sys, time

X = ctypes.CDLL("libX11.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XDefaultRootWindow.restype = ctypes.c_ulong
X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]

failed = []

@ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
def on_error(dpy, ev):
    failed.append(1)
    return 0

d = X.XOpenDisplay(None)
if not d:
    print("OPEN_FAILED", flush=True)
    sys.exit(1)
X.XSetErrorHandler(on_error)
root = X.XDefaultRootWindow(ctypes.c_void_p(d))

rc = X.XGrabKeyboard(ctypes.c_void_p(d), ctypes.c_ulong(root), 1, 1, 1, 0)
X.XSync(ctypes.c_void_p(d), 0)
print("GRAB", "error" if failed else ("success" if rc == 0 else "rc=%d" % rc), flush=True)
failed.clear()

keymap = ctypes.create_string_buffer(32)
event = ctypes.create_string_buffer(256)
deadline = time.time() + float(sys.argv[1])
saw_event = False
saw_keymap = False
while time.time() < deadline:
    if X.XPending(ctypes.c_void_p(d)) > 0:
        X.XNextEvent(ctypes.c_void_p(d), event)
        if event.raw[0] == 2:           # KeyPress
            saw_event = True
            break
    X.XQueryKeymap(ctypes.c_void_p(d), keymap)
    if any(keymap.raw[:32]):
        saw_keymap = True
    time.sleep(0.02)

print("KEYPRESS", "seen" if saw_event else "none", flush=True)
print("KEYMAP", "readable" if saw_keymap else "quiet", flush=True)
PY

if [ -n "$UNTRUSTED" ] && command -v xdotool >/dev/null 2>&1 &&
   python3 -c "import ctypes; ctypes.CDLL('libX11.so.6')" >/dev/null 2>&1; then
    echo "=== Can an untrusted client read the keyboard? ==="
    snoop() {
        local label="$1" auth="$2"
        ( if [ -n "$auth" ]; then XAUTHORITY="$auth" python3 "$WORK/snoop.py" 6; \
          else python3 "$WORK/snoop.py" 6; fi ) > "$WORK/snoop-$label.txt" 2>&1 &
        local pid=$!
        sleep 1.5
        for _ in $(seq 1 12); do
            xdotool key --clearmodifiers a >/dev/null 2>&1
            sleep 0.3
        done
        wait $pid 2>/dev/null
        tr '\n' ' ' < "$WORK/snoop-$label.txt"
    }
    TRUSTED_SNOOP="$(snoop trusted "")"
    UNTRUSTED_SNOOP="$(snoop untrusted "$UNTRUSTED")"
    nt_probe "x11 keyboard, trusted: $TRUSTED_SNOOP| untrusted: $UNTRUSTED_SNOOP"
    case "$TRUSTED_SNOOP" in
        *"KEYPRESS seen"*)
            echo "  PASS: control -- a trusted client sees injected keys" ;;
        *)  nt_fail "keyboard control expected=KEYPRESS-seen actual=$TRUSTED_SNOOP; the pair measures nothing"
            FAILURES=$((FAILURES + 1)) ;;
    esac
fi

# Whether an untrusted cookie is a boundary at all depends on the server
# refusing clients that present none. CI's Xvfb usually runs without auth, so
# ask a server we start ourselves rather than reasoning about it.
if [ -n "$UNTRUSTED" ] && command -v Xvfb >/dev/null 2>&1; then
    echo "=== Does an authorised server refuse a client with no cookie? ==="
    AUTHDISP=":$((80 + RANDOM % 10))"
    AUTHFILE="$WORK/server.xauth"
    : > "$AUTHFILE"
    COOKIE="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    xauth -f "$AUTHFILE" add "$AUTHDISP" MIT-MAGIC-COOKIE-1 "$COOKIE" >/dev/null 2>&1
    Xvfb "$AUTHDISP" -auth "$AUTHFILE" -screen 0 640x480x24 >/dev/null 2>&1 &
    XVFB_PID=$!
    sleep 3
    if DISPLAY="$AUTHDISP" XAUTHORITY="$AUTHFILE" xdpyinfo >/dev/null 2>&1; then
        if DISPLAY="$AUTHDISP" XAUTHORITY="$WORK/empty.xauth" xdpyinfo >/dev/null 2>&1; then
            nt_probe "x11 auth: a server with -auth accepted a client with no cookie"
        else
            echo "  PASS: with -auth, a client holding no cookie is refused"
            nt_probe "x11 auth: with -auth a cookieless client is refused, so an untrusted cookie is a boundary while the trusted one stays unreadable"
        fi
    else
        nt_note "the private Xvfb never came up; the auth question is unmeasured"
    fi
    kill $XVFB_PID 2>/dev/null
fi

echo
echo "=== What each technique does to a real webview ==="
# Every verdict above is about what a payload can reach. None of it matters if
# the app cannot start, so each candidate now gets a real neutrino polyglot and
# an unconfined control on the same clock either side of the table.
if [ -z "${DISPLAY:-}" ] || ! nt_linux_runtime; then
    nt_probe "webview compatibility: unmeasured (DISPLAY=${DISPLAY:-unset}, runtime $(nt_linux_runtime && echo found || echo missing))"
    echo "=== Results: $FAILURES failure(s) ==="
    exit $FAILURES
fi

mkdir -p "$WORK/app"
bash "$ROOT/build.sh" --tier=testing "$ROOT/test/neutrinotest.js" "$WORK/app/neutrinotest.cmd" >/dev/null 2>&1 ||
    { nt_fail "could not build the polyglot under test"; exit $((FAILURES + 1)); }

nt_windows_gone() {
    local i
    for i in $(seq 1 40); do
        xdotool search --name '(neutrino|STEP|TESTS DONE)' >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 1
}

LANE_TABLE=""
webview_lane() {
    local label="$1"; shift
    local rc pid

    echo "--- lane: $label ---"
    ( "$@" bash "$WORK/app/neutrinotest.cmd" >"$WORK/lane-$label.log" 2>&1 ) &
    pid=$!
    nt_timeout 240 bash "$ROOT/test/verify-linux.sh" "$SHOTS/$label" \
        >"$WORK/lane-$label.verify" 2>&1
    rc=$?
    nt_kill_tree "$pid"
    pkill -f neutrinotest >/dev/null 2>&1
    nt_windows_gone || nt_note "a window from lane $label outlived it; the next lane may be reading it"
    if [ "$rc" -eq 0 ]; then
        echo "  webview: alive"
        LANE_TABLE="$LANE_TABLE$label=alive "
    else
        echo "  webview: DEAD (verify-linux rc=$rc)"
        grep -m2 -E 'FAIL|TIMEOUT' "$WORK/lane-$label.verify" | sed 's/^/    /'
        tail -3 "$WORK/lane-$label.log" 2>/dev/null | sed 's/^/    app: /'
        LANE_TABLE="$LANE_TABLE$label=dead "
    fi
    return $rc
}

if ! webview_lane control-before env; then
    nt_fail "the unconfined control did not come up; nothing below this line measures anything"
    FAILURES=$((FAILURES + 1))
fi

if [ "$USERNS_OK" = "1" ]; then
    webview_lane hide-bus "$PROBE" --hide-bus --hide-agents --
    [ "$PIDNS_OK" = "1" ] && webview_lane hide-bus-pidns "$PROBE" --hide-bus --hide-agents --pidns --
    # The candidate tier as a whole: allowlisted runtime dir, both buses gone,
    # no process outside the namespace to walk back through.
    webview_lane sealed-runtime "$PROBE" --seal-runtime --hide-bus --hide-agents --pidns --
    webview_lane hide-bus-and-x11 "$PROBE" --hide-bus --hide-x11 --
    webview_lane netns "$PROBE" --netns --
    # The lane that has to be dead. Hiding the X11 directory does not remove the
    # display -- the abstract name is in the network namespace, so a client just
    # connects to that instead -- and a network namespace alone leaves the
    # pathname socket. Together there is no display left, and a table where
    # nothing dies is a table that cannot see a break.
    if webview_lane no-display-at-all "$PROBE" --hide-x11 --netns --; then
        nt_fail "the webview survived with no display socket of either kind; this table cannot see a break"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: control -- with both display sockets gone, the webview dies"
    fi
fi

if [ -n "$UNTRUSTED" ]; then
    webview_lane x11-untrusted env XAUTHORITY="$UNTRUSTED"
fi

if ! webview_lane control-after env; then
    nt_fail "the unconfined control stopped coming up by the end of the table"
    FAILURES=$((FAILURES + 1))
fi

LIFT_NOTE=""
[ "$NS_LIFTED" = "1" ] && LIFT_NOTE=" (namespace lanes measured with the distribution restriction lifted)"
nt_probe "webview compatibility$LIFT_NOTE: $LANE_TABLE"

echo
echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
