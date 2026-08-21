#!/bin/bash
# confine.sh - assert a hostile script is contained to its own app dir
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: confine.sh <netinstall binary built with -DNEUTRINO_TESTING>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
. "$(dirname "$0")/lib.sh"

if [ "$NT_WINDOWS" = "1" ]; then
    echo "=== SKIP: payloads run through cmd.exe here; see the windows job ==="
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
NEUTRINO_TEST_FAKEHOME="$HOME/.netinstall-confine-$$"
mkdir -p "$SERVE" "$WORK/bin" "$NEUTRINO_TEST_FAKEHOME"
export NEUTRINO_HOME="$WORK/home"

nt_serve "$SERVE" || exit 2

# A listener outside the sandbox, so the abstract-socket probe has something
# real to reach for. A nonexistent name is no good: the kernel resolves the name
# before the scope check, so it answers ECONNREFUSED either way.
NT_ABSTRACT_PID=""
if [ "$(uname -s)" = "Linux" ] && command -v python3 >/dev/null 2>&1; then
    export NEUTRINO_TEST_ABSTRACT="neutrino-confine-probe-$$"
    python3 -c "
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('\0' + sys.argv[1])
s.listen(8)
time.sleep(600)
" "$NEUTRINO_TEST_ABSTRACT" &
    NT_ABSTRACT_PID=$!
    sleep 1
    # The same helper doubles as the peer for the /proc/<pid>/mem probe. What
    # that probe needs is exactly what this already is: a live, same-uid,
    # unconfined process with mapped writable memory that is not a descendant
    # of the app. A descendant would be reachable under yama's default scope
    # and would answer the wrong question.
    export NEUTRINO_TEST_PEER="$NT_ABSTRACT_PID"
fi

# Recorded in the results below, because the probe means nothing without it.
NT_PTRACE_STATE="n/a"
[ "$(uname -s)" = "Linux" ] && NT_PTRACE_STATE="$(nt_ptrace_scope)"

nt_cleanup() {
    kill $NT_SERVER_PID $NT_ABSTRACT_PID 2>/dev/null
    nt_ptrace_scope_restore
    if [ "$(uname -s)" = "Darwin" ]; then
        # The LaunchServices probe launches real applications, and what it
        # opens outlives the suite that opened it. Terminal only on a runner:
        # on a developer's mac the window this would close is very likely the
        # one the suite is being watched from.
        [ -n "${GITHUB_ACTIONS:-}" ] && pkill -x Terminal >/dev/null 2>&1
        pkill -f 'Evil.app/Contents/MacOS/Evil' >/dev/null 2>&1
    fi
    if [ -n "${NEUTRINO_TEST_KEYCHAIN:-}" ]; then
        security delete-generic-password -a "$NEUTRINO_TEST_KEYCHAIN" \
            -s "$NEUTRINO_TEST_KEYCHAIN" >/dev/null 2>&1
    fi
    rm -rf "$WORK" "$NEUTRINO_TEST_FAKEHOME"
}
trap nt_cleanup EXIT

FAILURES=0

# Writes outside the app dir, tries to overwrite its own launcher, then reports
# what the XDG redirection gave it.
cat > "$SERVE/hostile.cmd" <<'SCRIPT'
outside="$NEUTRINO_TEST_FAKEHOME/pwned"
if echo owned > "$outside" 2>/dev/null; then echo "ESCAPED_HOME"; else echo "BLOCKED_HOME"; fi
if echo owned > "$(dirname "$0")/hostile.cmd" 2>/dev/null; then echo "ESCAPED_LAUNCHER"; else echo "BLOCKED_LAUNCHER"; fi
if echo owned > "$XDG_DATA_HOME/ok" 2>/dev/null; then echo "OWN_DIR_WRITABLE"; else echo "OWN_DIR_BLOCKED"; fi
if cat /etc/hosts >/dev/null 2>&1; then echo "READS_WORK"; else echo "READS_BLOCKED"; fi
cp /bin/true "$XDG_DATA_HOME/probe" 2>/dev/null && chmod +x "$XDG_DATA_HOME/probe" 2>/dev/null
if "$XDG_DATA_HOME/probe" 2>/dev/null; then echo "EXEC_OWN_DIR"; else echo "EXEC_BLOCKED"; fi
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0))" 2>/dev/null; then echo "BIND_OK"; else echo "BIND_BLOCKED"; fi
else echo "BIND_SKIP"; fi
probe_tmp="${TMPDIR:-/tmp}/neutrino-exec-probe"
cp /bin/echo "$probe_tmp" 2>/dev/null && chmod +x "$probe_tmp" 2>/dev/null
if "$probe_tmp" >/dev/null 2>&1; then echo "EXEC_TMP"; else echo "EXEC_TMP_BLOCKED"; fi
rm -f "$probe_tmp" 2>/dev/null
if read -r _ <&3 2>/dev/null; then echo "FD_INHERITED"; else echo "FD_CLOSED"; fi
if [ -n "${NEUTRINO_TEST_ABSTRACT:-}" ]; then
    python3 -c "
import os, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect('\0' + os.environ['NEUTRINO_TEST_ABSTRACT'])
    print('ABSTRACT_OK')
except PermissionError:
    print('ABSTRACT_BLOCKED')
except OSError:
    print('ABSTRACT_ABSENT')
" 2>/dev/null || echo "ABSTRACT_ABSENT"
else echo "ABSTRACT_SKIP"; fi
if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import ctypes, os
class Iov(ctypes.Structure):
    _fields_ = [(\"base\", ctypes.c_void_p), (\"len\", ctypes.c_size_t)]
libc = ctypes.CDLL(None, use_errno=True)
libc.process_vm_readv.restype = ctypes.c_ssize_t
libc.process_vm_readv.argtypes = [ctypes.c_int, ctypes.POINTER(Iov), ctypes.c_ulong,
                                  ctypes.POINTER(Iov), ctypes.c_ulong, ctypes.c_ulong]
dst = ctypes.create_string_buffer(8)
src = ctypes.create_string_buffer(b\"12345678\", 8)
a = Iov(ctypes.cast(dst, ctypes.c_void_p).value, 8)
b = Iov(ctypes.cast(src, ctypes.c_void_p).value, 8)
n = libc.process_vm_readv(os.getpid(), ctypes.byref(a), 1, ctypes.byref(b), 1, 0)
print(\"PEEK_OK\" if n == 8 else \"PEEK_BLOCKED\")
" 2>/dev/null || echo "PEEK_BLOCKED"
else echo "PEEK_SKIP"; fi
if [ -n "${NEUTRINO_TEST_PEER:-}" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$NEUTRINO_TEST_PEER" 2>/dev/null <<'PY' || echo "PEERMEM_ERROR"
import os, sys, time

# Finding 3 says the landlock ruleset's WRITE_FILE grant on /proc re-opens
# ptrace through /proc/<pid>/mem, because that file's access check happens in
# proc_mem_open rather than through the ptrace syscall seccomp denies.
#
# There are two mediators in that path and they have to be told apart, or the
# fix gets written against the wrong one. The filesystem rights are one. The
# other is the LSM ptrace hook, which landlock also implements: a sandboxed
# process may not reach a task outside its own domain, whatever the filesystem
# says. Both refuse with EACCES and both refuse at open.
#
# So the probe asks the same question twice, against two targets that differ in
# exactly one thing. The peer is outside the domain. The child is inside it.
# The /proc rule is identical for both. If the child answers and the peer does
# not, what is holding is the domain check and not the grant this branch was
# about to narrow.
def mapping(pid):
    try:
        with open('/proc/%s/maps' % pid) as f:
            for line in f:
                cols = line.split()
                if len(cols) >= 2 and cols[1][:2] == 'rw':
                    return int(cols[0].split('-')[0], 16), None
    except OSError as e:
        return None, 'errno=%d' % e.errno
    return None, 'no writable mapping'

def poke(pid, label):
    # Report the maps read separately: it needs only PTRACE_MODE_READ, so it is
    # the weaker of the two questions and says which check gave way first.
    addr, why = mapping(pid)
    print('%sMAPS_%s' % (label, 'OK' if addr is not None else 'BLOCKED'))
    if why:
        print('%s maps %s' % (label.lower(), why))
    try:
        fd = os.open('/proc/%s/mem' % pid, os.O_RDWR)
    except OSError as e:
        print('%sMEM_BLOCKED' % label)
        print('%s mem open errno=%d' % (label.lower(), e.errno))
        return
    if addr is None:
        print('%sMEM_OPENED' % label)
        os.close(fd)
        return
    try:
        # Read a byte and put the same byte back. The question is whether the
        # write is permitted, not what it can do, and neither of these targets
        # is something to corrupt for the sake of a token.
        os.lseek(fd, addr, os.SEEK_SET)
        byte = os.read(fd, 1)
        os.lseek(fd, addr, os.SEEK_SET)
        os.write(fd, byte)
        print('%sMEM_ESCAPED' % label)
    except OSError as e:
        print('%sMEM_BLOCKED' % label)
        print('%s mem write errno=%d' % (label.lower(), e.errno))
    finally:
        os.close(fd)

# The other half of the same question, and the one that decides whether the
# grant is worth narrowing at all. /proc/<pid>/mem is not the only writable
# file under another process's directory, and the rest do not all go through
# ptrace_may_access -- oom_score_adj in particular is a plain 0644 file owned
# by the task's uid. So rather than guess which one matters, open every regular
# file under the peer's entry for writing and say which ones the domain lets
# through. Opened and closed, not written: the list is the answer.
def survey(pid, label):
    import stat as st
    base = '/proc/%s' % pid
    opened = []
    try:
        names = sorted(os.listdir(base))
    except OSError as e:
        print('%sWRITABLE_UNLISTABLE' % label)
        print('%s listdir errno=%d' % (label.lower(), e.errno))
        return
    for name in names:
        path = base + '/' + name
        try:
            if not st.S_ISREG(os.lstat(path).st_mode):
                continue
            fd = os.open(path, os.O_WRONLY)
        except OSError:
            continue
        os.close(fd)
        opened.append(name)
    print('%sWRITABLE_%s' % (label, 'SOME' if opened else 'NONE'))
    print('%s writable %s' % (label.lower(), ','.join(opened) or '-'))
    # And one real write, on the file chromium uses and the kernel checks least.
    # Raised then put back: this peer has to stay alive for the rest of the run.
    path = base + '/oom_score_adj'
    try:
        with open(path) as f:
            was = f.read().strip()
        fd = os.open(path, os.O_WRONLY)
        try:
            os.write(fd, b'100\n')
            print('%sOOM_ESCAPED' % label)
            os.write(fd, (was + '\n').encode())
        finally:
            os.close(fd)
    except OSError as e:
        print('%sOOM_BLOCKED' % label)
        print('%s oom errno=%d' % (label.lower(), e.errno))

poke(sys.argv[1], 'PEER')
survey(sys.argv[1], 'PEER')

pid = os.fork()
if pid == 0:
    time.sleep(8)
    os._exit(0)
poke(str(pid), 'CHILD')
os.kill(pid, 9)
os.waitpid(pid, 0)
PY
else echo "PEERMEM_SKIP"; fi
if [ -e /proc/self/oom_score_adj ] && command -v python3 >/dev/null 2>&1; then
    python3 - 2>/dev/null <<'PY' || echo "PROCSELF_ERROR"
import os, sys, time

# The regression control for narrowing the /proc write grant, in the exact
# shape chromium's zygote uses it: plain O_WRONLY and a write, no truncate.
# A shell redirection is the wrong instrument here -- ">" is O_TRUNC, which
# needs LANDLOCK_ACCESS_FS_TRUNCATE, a right this ruleset does not grant on
# /proc today. It refuses for a reason that has nothing to do with the rule
# under test, so both forms are reported and only the plain one is the control.
def poke(path, flags):
    try:
        fd = os.open(path, flags)
    except OSError as e:
        return 'BLOCKED', 'open errno=%d' % e.errno
    try:
        os.write(fd, b'0\n')
        return 'OK', ''
    except OSError as e:
        return 'BLOCKED', 'write errno=%d' % e.errno
    finally:
        os.close(fd)

verdict, why = poke('/proc/self/oom_score_adj', os.O_WRONLY)
print('PROCSELF_' + verdict)
if why:
    print('procself %s' % why)
verdict, why = poke('/proc/self/oom_score_adj', os.O_WRONLY | os.O_TRUNC)
print('PROCSELFTRUNC_' + verdict)

# And the one the zygote actually depends on: a *descendant's* entry, not its
# own. A /proc/self rule would not cover this, which is the whole CI risk of
# narrowing the grant, so the before-state has to be on the record.
pid = os.fork()
if pid == 0:
    time.sleep(5)
    os._exit(0)
verdict, why = poke('/proc/%d/oom_score_adj' % pid, os.O_WRONLY)
print('PROCCHILD_' + verdict)
if why:
    print('procchild %s' % why)
os.kill(pid, 9)
os.waitpid(pid, 0)
PY
else echo "PROCSELF_SKIP"; fi
if [ "$(uname -s)" = "Darwin" ] && [ -n "${NEUTRINO_TEST_LSD_TAG:-}" ]; then
    drop_cmd="$NEUTRINO_TEST_FAKEHOME/lsd-command-$NEUTRINO_TEST_LSD_TAG"
    drop_app="$NEUTRINO_TEST_FAKEHOME/lsd-app-$NEUTRINO_TEST_LSD_TAG"
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$drop_cmd" > "$XDG_DATA_HOME/evil.command" 2>/dev/null
    chmod +x "$XDG_DATA_HOME/evil.command" 2>/dev/null
    # Which door /usr/bin/open ends up using depends on this. With Terminal
    # already running, LaunchServices delivers the document to it as an apple
    # event -- which this profile denies outright, and which is a different
    # question from whether launchservicesd will spawn something for us.
    if pgrep -x Terminal >/dev/null 2>&1; then echo "LSD_TERM_UP=yes"; else echo "LSD_TERM_UP=no"; fi
    /usr/bin/open "$XDG_DATA_HOME/evil.command" >/dev/null 2>&1
    echo "LSD_COMMAND_RC=$?"
    mkdir -p "$XDG_DATA_HOME/Evil.app/Contents/MacOS" 2>/dev/null
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$drop_app" > "$XDG_DATA_HOME/Evil.app/Contents/MacOS/Evil" 2>/dev/null
    chmod +x "$XDG_DATA_HOME/Evil.app/Contents/MacOS/Evil" 2>/dev/null
    cat > "$XDG_DATA_HOME/Evil.app/Contents/Info.plist" 2>/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Evil</string>
<key>CFBundleIdentifier</key><string>com.example.neutrino.evil</string>
<key>CFBundleName</key><string>Evil</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
    /usr/bin/open "$XDG_DATA_HOME/Evil.app" >/dev/null 2>&1
    echo "LSD_APP_RC=$?"
    lsd_i=0
    while [ "$lsd_i" -lt 25 ]; do
        [ -e "$drop_cmd" ] && [ -e "$drop_app" ] && break
        sleep 1
        lsd_i=$((lsd_i + 1))
    done
    if [ -e "$drop_cmd" ]; then echo "LSD_COMMAND_ESCAPED"; else echo "LSD_COMMAND_BLOCKED"; fi
    if [ -e "$drop_app" ]; then echo "LSD_APP_ESCAPED"; else echo "LSD_APP_BLOCKED"; fi
else echo "LSD_SKIP"; fi
if command -v security >/dev/null 2>&1; then
    if [ -n "${NEUTRINO_TEST_KEYCHAIN:-}" ]; then
        if security find-generic-password -a "$NEUTRINO_TEST_KEYCHAIN" \
                 -s "$NEUTRINO_TEST_KEYCHAIN" -w 2>/dev/null | grep -q probe-secret
        then echo "KEYCHAIN_READ"; else echo "KEYCHAIN_BLOCKED"; fi
    else echo "KEYCHAIN_SKIP"; fi
    echo "TLS: $(curl -sS --max-time 20 -o /dev/null -w "%{http_code}" https://example.com 2>&1 | tail -1)"
fi
if [ -n "${NETINSTALL_FAKE_TOKEN:-}" ]; then echo "SECRET_INHERITED"; else echo "SECRET_SCRUBBED"; fi
if [ -n "${SSH_AUTH_SOCK:-}" ]; then echo "AGENT_INHERITED"; else echo "AGENT_SCRUBBED"; fi
if [ -n "${PATH:-}" ] && [ -n "${HOME:-}" ]; then echo "BASICS_KEPT"; else echo "BASICS_LOST"; fi
SCRIPT

SPEC="hostile-com-example-0$(nt_pin "$SERVE/hostile.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
export NEUTRINO_TEST_FAKEHOME
# Two things a filesystem sandbox cannot reach: a token that exists only as a
# variable, and a live agent socket. Both have to be gone by the time sh starts.
export NETINSTALL_FAKE_TOKEN="a-secret-that-only-lives-in-the-environment"

# A real secret in the real keychain. Searching for an item that does not exist
# proves nothing -- it fails the same way whether securityd was reachable or
# not -- so the probe has to try to read a password that is genuinely there.
if [ "$(uname -s)" = "Darwin" ]; then
    NEUTRINO_TEST_KEYCHAIN="neutrino-probe-$$"
    if security add-generic-password -a "$NEUTRINO_TEST_KEYCHAIN" \
             -s "$NEUTRINO_TEST_KEYCHAIN" -w probe-secret -A 2>/dev/null; then
        export NEUTRINO_TEST_KEYCHAIN
    else
        unset NEUTRINO_TEST_KEYCHAIN
    fi
fi
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-/nonexistent/agent.sock}"

# LaunchServices, measured from outside the sandbox before it is measured from
# inside. /usr/bin/open does not spawn anything itself -- it asks
# launchservicesd, which is in nobody's profile -- so the interesting question
# is whether the profile stops the request. That question only has an answer if
# the same two artifacts launch at all on this runner, and a headless one may
# have no session for them to launch into.
#
# The control runs first on purpose. It warms LaunchServices and leaves Terminal
# up, so a cold start cannot make the confined attempt time out and read as
# blocked -- which would be the wrong answer in the reassuring direction.
NT_LSD_CONTROL="skipped (not darwin)"
NT_LSD_WARM="not measured"
if [ "$(uname -s)" = "Darwin" ]; then
    CTL="$WORK/lsd"
    mkdir -p "$CTL/Evil.app/Contents/MacOS"
    cat > "$CTL/Evil.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Evil</string>
<key>CFBundleIdentifier</key><string>com.example.neutrino.evilcontrol</string>
<key>CFBundleName</key><string>Evil</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST

    # Terminal running or not is what decides which door /usr/bin/open takes,
    # so both attempts have to meet the same state or they are not answering
    # the same question. Only on a runner: on a developer's mac the window
    # this closes is very likely the one the suite is being watched from, and
    # there the probe measures whatever state the desk is in and says so.
    nt_lsd_cold() {
        [ -n "${GITHUB_ACTIONS:-}" ] || return 0
        pkill -x Terminal >/dev/null 2>&1
        sleep 3
        return 0
    }

    nt_lsd_wait() {
        local i
        for i in $(seq 1 25); do
            [ -e "$1" ] && [ -e "$2" ] && return 0
            sleep 1
        done
        return 1
    }

    # The control. /usr/bin/open does not spawn anything itself -- it asks
    # launchservicesd, which is in nobody's profile -- so the question is
    # whether the profile stops the request. That question only has an answer
    # if these same two artifacts launch at all here, and a runner may have no
    # session for them to launch into.
    CTL_CMD="$NEUTRINO_TEST_FAKEHOME/lsd-control-command-$$"
    CTL_APP="$NEUTRINO_TEST_FAKEHOME/lsd-control-app-$$"
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$CTL_CMD" > "$CTL/evil.command"
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$CTL_APP" > "$CTL/Evil.app/Contents/MacOS/Evil"
    chmod +x "$CTL/evil.command" "$CTL/Evil.app/Contents/MacOS/Evil"
    nt_lsd_cold
    /usr/bin/open "$CTL/evil.command" >/dev/null 2>&1
    NT_LSD_CTL_CMD_RC=$?
    /usr/bin/open "$CTL/Evil.app" >/dev/null 2>&1
    NT_LSD_CTL_APP_RC=$?
    nt_lsd_wait "$CTL_CMD" "$CTL_APP"
    NT_LSD_CONTROL="command=$([ -e "$CTL_CMD" ] && echo LAUNCHED || echo NOTHING)(rc=$NT_LSD_CTL_CMD_RC)"
    NT_LSD_CONTROL="$NT_LSD_CONTROL app=$([ -e "$CTL_APP" ] && echo LAUNCHED || echo NOTHING)(rc=$NT_LSD_CTL_APP_RC)"

    # The control just started Terminal. Put it back down, or the confined
    # attempt below asks the apple-event question instead of the spawn one.
    nt_lsd_cold
    export NEUTRINO_TEST_LSD_TAG="cold-$$"
fi

# fd 3 carries a readable file in, so the payload can tell "closed" from "empty".
OUT="$("$APP" 2>"$WORK/err" 3<"$SERVE/hostile.cmd")"
CONFINE="$("$APP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
nt_note "confinement: $CONFINE"

# And the same question with Terminal already up, which is the ordinary state
# of a mac and the one where LaunchServices hands the document over as an apple
# event rather than spawning. Two doors, two answers, and a denial has to close
# both or it has closed neither.
if [ "$(uname -s)" = "Darwin" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
    WARM_CMD="$NEUTRINO_TEST_FAKEHOME/lsd-warmup-$$"
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$WARM_CMD" > "$CTL/warm.command"
    chmod +x "$CTL/warm.command"
    /usr/bin/open "$CTL/warm.command" >/dev/null 2>&1
    for _ in $(seq 1 25); do
        [ -e "$WARM_CMD" ] && break
        sleep 1
    done
    export NEUTRINO_TEST_LSD_TAG="warm-$$"
    WARM_OUT="$("$APP" 2>/dev/null 3<"$SERVE/hostile.cmd")"
    NT_LSD_WARM="$(grep -oE 'LSD_[A-Z]+_(ESCAPED|BLOCKED)|LSD_TERM_UP=[a-z]+' <<<"$WARM_OUT" | tr '\n' ' ')"
    NT_LSD_WARM="$NT_LSD_WARM(terminal reached by the warmup: $([ -e "$WARM_CMD" ] && echo yes || echo no))"
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

if [ "${CONFINE#none}" != "$CONFINE" ]; then
    nt_note "SKIP: no confinement available; asserting the inverse"
    check "writes outside the app dir succeed unconfined" ESCAPED_HOME
else
    check "write outside the app dir is blocked"  BLOCKED_HOME
    check "overwriting its own launcher is blocked" BLOCKED_LAUNCHER
fi

check "its own dir stays writable" OWN_DIR_WRITABLE
check "reads still work"           READS_WORK

echo "=== The environment is an allowlist ==="
check "a token that lives only in the env is dropped" SECRET_SCRUBBED
check "the ssh agent socket is dropped"               AGENT_SCRUBBED
check "what a toolkit needs survives"                 BASICS_KEPT

if [ "$(uname -s)" = "Darwin" ]; then
    # Write xor execute: the one directory an app can write to is the one it
    # must not be able to run anything from. On linux this needs the exec
    # allowlist, so it lives in the tight tier and confine-strict.sh covers it.
    check "cannot execute what it wrote"                 EXEC_BLOCKED
    # TMPDIR is not redirected on macOS, so it is a real writable directory
    # outside the app dir -- w^x is a lie if it stays executable.
    check "cannot execute what it wrote to the temp dir" EXEC_TMP_BLOCKED
else
    nt_note "w^x is tight-tier only on linux; got $(grep -o 'EXEC_[A-Z_]*' <<<"$OUT" | tr '\n' ' ')"
fi

if [ "$(uname -s)" = "Darwin" ]; then
    # Recorded, not asserted. Denying securityd is what actually closes the
    # keychain, and trustd is left reachable so TLS keeps working -- both are
    # claims about Apple daemons, so the suite reports what really happened.
    case "$OUT" in
        *KEYCHAIN_SKIP*)
            nt_note "keychain probe skipped: no fixture could be planted" ;;
        *)
            # Measured in CI, not assumed: denying com.apple.SecurityServer does
            # stop a real password being read back, so this is a boundary and
            # gets asserted like one.
            check "a real keychain password cannot be read" KEYCHAIN_BLOCKED ;;
    esac
    nt_note "https under the profile: $(grep '^TLS:' <<<"$OUT" | cut -c6-)"
fi

echo "=== Descriptors the caller left open ==="
check "an inherited descriptor does not reach the app" FD_CLOSED

echo "=== Sockets the app has no path-based rule against ==="
# Abstract-socket scoping is deliberately skipped when a display is set, because
# an X11 client does not survive it. Asserting it therefore needs a run without
# one -- and the run above, with whatever display CI has, is what proves the
# skip really happens rather than being a claim in a comment.
if [ "$(uname -s)" = "Linux" ]; then
    NOX_OUT="$(env -u DISPLAY "$APP" 2>/dev/null 3<"$SERVE/hostile.cmd")"
    NOX_CONFINE="$(env -u DISPLAY "$APP" --info 2>/dev/null |
        awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
    nt_note "without a display: $NOX_CONFINE"
    case "$NOX_CONFINE" in
        *"sockets+signals scoped"*)
            if grep -qx ABSTRACT_BLOCKED <<<"$NOX_OUT"; then
                echo "  PASS: cannot reach an abstract unix socket outside the sandbox"
            else
                nt_fail "abstract socket expected=ABSTRACT_BLOCKED actual=$(grep -o 'ABSTRACT_[A-Z]*' <<<"$NOX_OUT")"
                FAILURES=$((FAILURES + 1))
            fi ;;
        *)  nt_note "socket scoping needs landlock abi 6; got $NOX_CONFINE" ;;
    esac
    case "$CONFINE" in
        *"sockets+signals scoped"*)
            nt_note "no display was set here, so socket scoping applied to the main run too" ;;
        *"signals scoped"*)
            echo "  PASS: with a display set, socket scoping is skipped so X11 survives" ;;
    esac
else
    nt_note "landlock scoping is linux-only; got $(grep -o 'ABSTRACT_[A-Z]*' <<<"$OUT")"
fi

echo "=== Syscalls that reach across process boundaries ==="
case "$CONFINE" in
    *seccomp*)
        # process_vm_readv on your own memory always succeeds unfiltered, so a
        # refusal here is the filter and nothing else.
        check "cannot read another process's memory" PEEK_BLOCKED ;;
    *)
        nt_note "no seccomp filter here; got $(grep -o 'PEEK_[A-Z]*' <<<"$OUT")" ;;
esac

# Measured, and settled, so it is asserted rather than recorded. Finding 3
# said the WRITE_FILE grant on /proc re-opens ptrace through /proc/<pid>/mem,
# whose check happens in proc_mem_open and so is not covered by the seccomp
# denial of __NR_ptrace. The seccomp half of that is right and the conclusion
# is not: landlock implements the LSM ptrace hook too, and a domain may not
# reach a task outside itself whatever the filesystem says.
#
# The two lines below are the argument. Same /proc rule, same call, two targets
# that differ only in whether they are inside this domain. If the peer ever
# starts answering, the hook stopped covering it and the finding is live again;
# if the child ever stops, the reasoning above no longer holds and the verdict
# needs re-deriving rather than trusting.
#
# What this does not say is that the grant is harmless. mem is the one file the
# hook takes off the table, and the survey in the results below is there
# because the rest of the peer's entry is still writable.
case "$CONFINE" in
    *landlock*)
        if grep -qx PEERMEM_SKIP <<<"$OUT"; then
            nt_note "no peer to probe /proc against here"
        else
            check "cannot write a peer's memory through /proc"  PEERMEM_BLOCKED
            check "cannot read a peer's maps either"            PEERMAPS_BLOCKED
            check "the same /proc rule still reaches its own"   CHILDMEM_ESCAPED
        fi ;;
    *)  nt_note "the /proc verdict needs a landlock domain; got $CONFINE" ;;
esac

NT_ABI="$(grep -o 'abi [0-9]*' <<<"$CONFINE" | awk '{print $2}')"
if [ "$(uname -s)" = "Linux" ] && [ -n "$NT_ABI" ] && [ "$NT_ABI" -ge 4 ]; then
    check "cannot bind a TCP port" BIND_BLOCKED
elif [ "$(uname -s)" = "Linux" ]; then
    nt_note "tcp bind mediation needs landlock abi 4; this kernel reports ${NT_ABI:-none}"
else
    nt_note "tcp bind confinement is landlock-only; got $(grep -o 'BIND_[A-Z]*' <<<"$OUT")"
fi

# The control for the /proc probes, through the same binary with confinement
# forced off. Without it a refusal cannot be attributed: the runner's own yama
# setting, the environment scrub and the ruleset all fail the same way and at
# the same call. This is the run that says which of them it was.
NT_PROC_CONTROL="not measured"
if [ "$(uname -s)" = "Linux" ] && [ -n "${NEUTRINO_TEST_PEER:-}" ]; then
    NOCONF_OUT="$(NEUTRINO_TEST_NO_CONFINE=1 "$APP" 2>/dev/null 3<"$SERVE/hostile.cmd")"
    NT_PROC_CONTROL="$(grep -oE '(PEER|CHILD)(MEM|MAPS|WRITABLE|OOM)_[A-Z]+' <<<"$NOCONF_OUT" | tr '\n' ' ')"
    NT_PROC_CONTROL="$NT_PROC_CONTROL[$(grep -E '^(peer|child) ' <<<"$NOCONF_OUT" | tr '\n' ';')]"
fi

# The measurements below are recorded rather than checked, but whether the
# probe can still see anything is checked here. A probe that has quietly
# stopped working reports the same reassuring nothing as a boundary that holds,
# and these three lines are what tell those apart.
echo "=== The probes can still detect what they are looking for ==="
case "$(uname -s)-$NT_PTRACE_STATE" in
    Linux-0*)
        if grep -q PEERMEM_ESCAPED <<<"$NT_PROC_CONTROL"; then
            echo "  PASS: unconfined, the probe does reach a peer's memory"
        else
            nt_fail "proc control expected=PEERMEM_ESCAPED actual=$NT_PROC_CONTROL"
            FAILURES=$((FAILURES + 1))
        fi ;;
    Linux-*)
        # yama refuses the attach before any of our confinement is consulted,
        # so nothing here is decisive and saying so is the honest answer.
        nt_note "proc control not decisive: ptrace_scope=$NT_PTRACE_STATE" ;;
esac

if [ "$(uname -s)" = "Darwin" ]; then
    case "$NT_LSD_CONTROL" in
        *command=LAUNCHED*app=LAUNCHED*)
            echo "  PASS: unconfined, both launchservices doors do open" ;;
        *)  nt_fail "launchservices control expected=both LAUNCHED actual=$NT_LSD_CONTROL"
            FAILURES=$((FAILURES + 1)) ;;
    esac
fi

echo "=== Measured for the next three PRs, not asserted ==="
# Recorded rather than checked, deliberately. Each of these is a hole this
# branch has not closed yet, and a suite that asserted the fix here would fail
# the commit that measures it. The PR named on each line is the one that turns
# it into a check; if any of them already reads the other way, the finding
# behind it is wrong and the fix should not be written.
#
# nt_result and not nt_note: notices are capped at ten per step and the suite
# fills that bucket long before this line, and the step summary does not come
# back out through the API at all.
nt_tokens() { grep -oE "$1" <<<"$OUT" | tr '\n' ' '; }

case "$(uname -s)" in
    Linux)
        nt_result "PR2 before-state: ptrace_scope=$NT_PTRACE_STATE peer=${NEUTRINO_TEST_PEER:-none} confined: $(nt_tokens '(PEER|CHILD)(MEM|MAPS|WRITABLE|OOM)_[A-Z]+')[$(grep -E '^(peer|child) ' <<<"$OUT" | tr '\n' ';')] unconfined-control: $NT_PROC_CONTROL"
        nt_result "PR2 write-grant before-state: $(nt_tokens '(PROCSELF|PROCSELFTRUNC|PROCCHILD)_[A-Z]+')[$(grep -E '^proc(self|child) ' <<<"$OUT" | tr '\n' ';')] confine=$CONFINE"
        ;;
    Darwin)
        nt_result "PR3 before-state cold: $(nt_tokens 'LSD_[A-Z]+_(ESCAPED|BLOCKED)')$(nt_tokens 'LSD_[A-Z]+_RC=[0-9]+')$(nt_tokens 'LSD_TERM_UP=[a-z]+')unconfined-control: $NT_LSD_CONTROL"
        nt_result "PR3 before-state warm: $NT_LSD_WARM"
        ;;
esac

echo "=== The launcher still verifies after the attempt ==="
if "$APP" --verify >/dev/null 2>&1; then
    echo "  PASS: pin still matches"
else
    nt_fail "pin expected=intact actual=broken"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
