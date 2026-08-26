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
# Overwriting its own launcher is the question, and until the freebsd lane it
# had only ever been asked where the answer was no. Where the answer is yes the
# write lands on the file this shell is still reading, sh reads a script
# lazily, and the next read is EOF: measured as
# `hostile.cmd: 17: Syntax error: end of file unexpected (expecting "fi")`,
# six markers in, with every check after it reporting a refusal the platform
# had not made and --verify reporting a broken pin on top. So the bytes go
# aside first and come back immediately, into the same inode at the same
# length, which is what leaves this shell's offset pointing at what it was
# pointing at. Where the write is refused both copies are refused with it and
# nothing changes.
launcher="$(dirname "$0")/hostile.cmd"
cp "$launcher" "$XDG_DATA_HOME/.launcher.bak" 2>/dev/null
if echo owned > "$launcher" 2>/dev/null; then echo "ESCAPED_LAUNCHER"; else echo "BLOCKED_LAUNCHER"; fi
cat "$XDG_DATA_HOME/.launcher.bak" > "$launcher" 2>/dev/null
# And say whether that worked, because a restore that silently did not is the
# same empty reading as the truncation it was added to undo.
if cmp -s "$XDG_DATA_HOME/.launcher.bak" "$launcher" 2>/dev/null
then echo "LAUNCHER_RESTORED"; else echo "LAUNCHER_NOT_RESTORED"; fi
if echo owned > "$XDG_DATA_HOME/ok" 2>/dev/null; then echo "OWN_DIR_WRITABLE"; else echo "OWN_DIR_BLOCKED"; fi
if cat /etc/hosts >/dev/null 2>&1; then echo "READS_WORK"; else echo "READS_BLOCKED"; fi
nt_true=""
for c in /bin/true /usr/bin/true; do [ -x "$c" ] && { nt_true="$c"; break; }; done
echo "EXECSRC:${nt_true:-none}"
if [ -n "$nt_true" ] && cp "$nt_true" "$XDG_DATA_HOME/probe" 2>/dev/null &&
   chmod +x "$XDG_DATA_HOME/probe" 2>/dev/null; then
    if "$XDG_DATA_HOME/probe" 2>/dev/null; then echo "EXEC_OWN_DIR"; else echo "EXEC_BLOCKED"; fi
else
    echo "EXEC_NOCOPY"
fi
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0))" 2>/dev/null; then echo "BIND_OK"; else echo "BIND_BLOCKED"; fi
else echo "BIND_SKIP"; fi
probe_tmp="${TMPDIR:-/tmp}/neutrino-exec-probe"
nt_echo=""
for c in /bin/echo /usr/bin/echo; do [ -x "$c" ] && { nt_echo="$c"; break; }; done
echo "EXECTMPSRC:${nt_echo:-none}"
if [ -n "$nt_echo" ] && cp "$nt_echo" "$probe_tmp" 2>/dev/null &&
   chmod +x "$probe_tmp" 2>/dev/null; then
    if "$probe_tmp" >/dev/null 2>&1; then echo "EXEC_TMP"; else echo "EXEC_TMP_BLOCKED"; fi
else
    echo "EXEC_TMP_NOCOPY"
fi
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
    # A raise by one, not a constant: the kernel refuses to *lower*
    # oom_score_adj without CAP_SYS_RESOURCE, so a probe that wrote 100 would
    # report the ruleset refusing on any machine whose ambient value is higher
    # -- 500 on a github runner, 200 on this desk. Raising is never refused for
    # that reason, so what is left to refuse it is the thing under test.
    # Put back afterwards where the kernel allows it; a peer one point closer to
    # the OOM killer is the finding, not a side effect worth hiding.
    path = base + '/oom_score_adj'
    try:
        with open(path) as f:
            was = f.read().strip()
        bump = str(min(int(was or '0') + 1, 1000))
        fd = os.open(path, os.O_WRONLY)
        try:
            os.write(fd, (bump + '\n').encode())
            print('%sOOM_ESCAPED' % label)
            try:
                os.write(fd, (was + '\n').encode())
            except OSError:
                pass
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
def current(path):
    try:
        with open(path) as f:
            return f.read().strip() or '0'
    except OSError:
        return '0'

def poke(path, flags):
    # The value written is whatever is already there. Only the permission path
    # is under test here, and writing a constant would answer a different
    # question on any machine with a non-zero ambient oom_score_adj: lowering
    # it needs CAP_SYS_RESOURCE and comes back EACCES, which is the same errno
    # the ruleset would give and means something else entirely.
    data = (current(path) + '\n').encode()
    try:
        fd = os.open(path, flags)
    except OSError as e:
        return 'BLOCKED', 'open errno=%d' % e.errno
    try:
        os.write(fd, data)
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

# Narrowing the grant puts a write-only rule underneath a read-only one, and
# reads under /proc/self survive that only because landlock accumulates rights
# walking up the hierarchy rather than letting the deepest rule decide alone.
# That is a claim about kernel behaviour, so it gets asked rather than assumed:
# every engine here reads its own maps, and a ruleset that took that away would
# fail the webview for a reason nobody would attribute to this rule.
try:
    with open('/proc/self/maps') as f:
        f.readline()
    print('PROCSELFREAD_OK')
except OSError as e:
    print('PROCSELFREAD_BLOCKED')
    print('procselfread errno=%d' % e.errno)

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

# Whether the unshare itself is permitted at all. Not the interesting question
# on its own -- the map write below is -- but it separates "seccomp refused the
# syscall" from "the map could not be written", which otherwise arrive as the
# same silence.
#
# The map write from inside the unshared child is reported too, and it is the
# shape that *cannot* work, deliberately kept because it explains the errno on
# the shape that can: inside an unmapped user namespace the task's own /proc
# inode no longer maps to a uid it can pass, so a child writing its own uid_map
# is refused by the ownership check before any ruleset is consulted. That is
# also why bubblewrap does not do it this way round.
sys.stdout.flush()
pid = os.fork()
if pid == 0:
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.unshare(0x10000000) != 0:               # CLONE_NEWUSER
        print('USERNSCHILD_BLOCKED')
        print('usernschild unshare errno=%d' % ctypes.get_errno())
        print('UIDMAPCHILD_SKIP')
        sys.stdout.flush()
        os._exit(0)
    print('USERNSCHILD_OK')
    wrote = True
    for path, data in (('/proc/self/setgroups', b'deny'),
                       ('/proc/self/uid_map', ('0 %d 1\n' % os.getuid()).encode())):
        try:
            fd = os.open(path, os.O_WRONLY)
            try:
                os.write(fd, data)
            finally:
                os.close(fd)
        except OSError as e:
            print('UIDMAPCHILD_BLOCKED')
            print('uidmapchild %s errno=%d' % (path.rsplit('/', 1)[1], e.errno))
            wrote = False
            break
    if wrote:
        print('UIDMAPCHILD_OK')
    sys.stdout.flush()
    os._exit(0)
os.waitpid(pid, 0)

# And the shape that is actually load-bearing, which the first version of this
# probe got wrong. bubblewrap and chromium's namespace sandbox both fork a
# child that unshares, and then the *parent* writes the child's
# /proc/<pid>/setgroups and uid_map. That is a descendant's entry, so the grant
# that ships covers it and a rule pinned to /proc/self does not.
#
# This is the question that decides PR 2: if it succeeds here, narrowing the
# grant takes away the mechanism the engines' own sandboxes are built on, which
# is a worse outcome than the finding being fixed. The errno names the mediator
# -- 13 is a ruleset, 1 is the distro's restriction on unprivileged user
# namespaces, and those are not the same answer.
sys.stdout.flush()
ready_r, ready_w = os.pipe()
pid = os.fork()
if pid == 0:
    import ctypes
    os.close(ready_r)
    libc = ctypes.CDLL(None, use_errno=True)
    rc = libc.unshare(0x10000000)                  # CLONE_NEWUSER
    os.write(ready_w, b'1' if rc == 0 else b'0')
    os.close(ready_w)
    time.sleep(8)
    os._exit(0)
os.close(ready_w)
ready = os.read(ready_r, 1)
os.close(ready_r)
if ready != b'1':
    print('USERNSMAP_SKIP')
    print('usernsmap the child could not unshare, so there is no map to write')
else:
    mapped = True
    for name, data in (('setgroups', b'deny'),
                       ('uid_map', ('0 %d 1\n' % os.getuid()).encode())):
        try:
            fd = os.open('/proc/%d/%s' % (pid, name), os.O_WRONLY)
            try:
                os.write(fd, data)
            finally:
                os.close(fd)
        except OSError as e:
            print('USERNSMAP_BLOCKED')
            print('usernsmap %s errno=%d' % (name, e.errno))
            mapped = False
            break
    if mapped:
        print('USERNSMAP_OK')
os.kill(pid, 9)
os.waitpid(pid, 0)
PY
else echo "PROCSELF_SKIP"; fi
if [ "$(uname -s)" = "Darwin" ] && [ -n "${NEUTRINO_TEST_LSD_TAG:-}" ]; then
    drop_cmd="$NEUTRINO_TEST_FAKEHOME/lsd-command-$NEUTRINO_TEST_LSD_TAG"
    drop_app="$NEUTRINO_TEST_FAKEHOME/lsd-app-$NEUTRINO_TEST_LSD_TAG"
    drop_ws="$NEUTRINO_TEST_FAKEHOME/lsd-ws-$NEUTRINO_TEST_LSD_TAG"
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
    # The third door, and the one an app actually has. /usr/bin/open is a
    # convenience the payload could be denied outright; NSWorkspace.openURL is
    # the same request made from inside any process that can reach AppKit,
    # which under netinstall is arbitrary sh with osascript on it. A denial
    # that closes one and not the other has closed neither.
    mkdir -p "$XDG_DATA_HOME/Ws.app/Contents/MacOS" 2>/dev/null
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$drop_ws" > "$XDG_DATA_HOME/Ws.app/Contents/MacOS/Ws" 2>/dev/null
    chmod +x "$XDG_DATA_HOME/Ws.app/Contents/MacOS/Ws" 2>/dev/null
    cat > "$XDG_DATA_HOME/Ws.app/Contents/Info.plist" 2>/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Ws</string>
<key>CFBundleIdentifier</key><string>com.example.neutrino.ws</string>
<key>CFBundleName</key><string>Ws</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
    /usr/bin/osascript -l JavaScript -e \
        "ObjC.import('AppKit'); \$.NSWorkspace.sharedWorkspace.openURL(\$.NSURL.fileURLWithPath('$XDG_DATA_HOME/Ws.app'))" \
        >/dev/null 2>&1
    echo "LSD_WS_RC=$?"
    lsd_i=0
    while [ "$lsd_i" -lt 25 ]; do
        [ -e "$drop_cmd" ] && [ -e "$drop_app" ] && [ -e "$drop_ws" ] && break
        sleep 1
        lsd_i=$((lsd_i + 1))
    done
    if [ -e "$drop_cmd" ]; then echo "LSD_COMMAND_ESCAPED"; else echo "LSD_COMMAND_BLOCKED"; fi
    if [ -e "$drop_app" ]; then echo "LSD_APP_ESCAPED"; else echo "LSD_APP_BLOCKED"; fi
    if [ -e "$drop_ws" ]; then echo "LSD_WS_ESCAPED"; else echo "LSD_WS_BLOCKED"; fi
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
# Last line on purpose. Without it "the marker is not there" and "the payload
# stopped before it got there" are the same reading, and on FreeBSD they were:
# this script died six markers in and five checks after it each reported a
# refusal the platform had not made.
echo "PAYLOAD_END"
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
    mkdir -p "$CTL/Evil.app/Contents/MacOS" "$CTL/Ws.app/Contents/MacOS"
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
    cat > "$CTL/Ws.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Ws</string>
<key>CFBundleIdentifier</key><string>com.example.neutrino.wscontrol</string>
<key>CFBundleName</key><string>Ws</string>
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
            [ -e "$1" ] && [ -e "$2" ] && [ -e "$3" ] && return 0
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
    CTL_WS="$NEUTRINO_TEST_FAKEHOME/lsd-control-ws-$$"
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$CTL_CMD" > "$CTL/evil.command"
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$CTL_APP" > "$CTL/Evil.app/Contents/MacOS/Evil"
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$CTL_WS" > "$CTL/Ws.app/Contents/MacOS/Ws"
    chmod +x "$CTL/evil.command" "$CTL/Evil.app/Contents/MacOS/Evil" "$CTL/Ws.app/Contents/MacOS/Ws"
    nt_lsd_cold
    /usr/bin/open "$CTL/evil.command" >/dev/null 2>&1
    NT_LSD_CTL_CMD_RC=$?
    /usr/bin/open "$CTL/Evil.app" >/dev/null 2>&1
    NT_LSD_CTL_APP_RC=$?
    /usr/bin/osascript -l JavaScript -e \
        "ObjC.import('AppKit'); \$.NSWorkspace.sharedWorkspace.openURL(\$.NSURL.fileURLWithPath('$CTL/Ws.app'))" \
        >/dev/null 2>&1
    NT_LSD_CTL_WS_RC=$?
    nt_lsd_wait "$CTL_CMD" "$CTL_APP" "$CTL_WS"
    NT_LSD_CONTROL="command=$([ -e "$CTL_CMD" ] && echo LAUNCHED || echo NOTHING)(rc=$NT_LSD_CTL_CMD_RC)"
    NT_LSD_CONTROL="$NT_LSD_CONTROL app=$([ -e "$CTL_APP" ] && echo LAUNCHED || echo NOTHING)(rc=$NT_LSD_CTL_APP_RC)"
    NT_LSD_CONTROL="$NT_LSD_CONTROL ws=$([ -e "$CTL_WS" ] && echo LAUNCHED || echo NOTHING)(rc=$NT_LSD_CTL_WS_RC)"

    # The control just started Terminal. Put it back down, or the confined
    # attempt below asks the apple-event question instead of the spawn one.
    nt_lsd_cold
    export NEUTRINO_TEST_LSD_TAG="cold-$$"
fi

# fd 3 carries a readable file in, so the payload can tell "closed" from "empty".
OUT="$("$APP" 2>"$WORK/err" 3<"$SERVE/hostile.cmd")" && OUT_RC=0 || OUT_RC=$?
CONFINE="$("$APP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
nt_note "confinement: $CONFINE"

# The payload's own account of whether it finished, and the stderr this suite
# has redirected to a file since it was written and never once read. On FreeBSD
# the payload stopped after EXEC_OWN_DIR and every check below reported
# `expected=X actual=<the six markers it did print>` -- which reads as five
# separate refusals by the platform and is one death in the script.
nt_result "report: confine payload rc=$OUT_RC lines=$(grep -c . <<<"$OUT") finished=$(grep -qx PAYLOAD_END <<<"$OUT" && echo yes || echo NO)"
# The tail, and netinstall's own warnings filtered out of it. Round 4 reported
# the head and spent the whole 260 characters on `warning: running unconfined`,
# which the confinement line above already says -- while the payload's own last
# words, which are the reading, were past the cut. Same rule annotate.sh states
# for chunks: the answer is at the end.
NT_PAYLOAD_ERR="$(grep -av '^netinstall:' "$WORK/err" 2>/dev/null |
                  tail -4 | tr '\n' ' ' | tr -d '[:cntrl:]')"
[ -n "$NT_PAYLOAD_ERR" ] || NT_PAYLOAD_ERR="<nothing the app itself said>"
nt_result "report: confine payload stderr: $NT_PAYLOAD_ERR"

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

case "$(uname -s)" in
    Darwin|OpenBSD)
        # Write xor execute: the one directory an app can write to is the one it
        # must not be able to run anything from. On linux this needs the exec
        # allowlist, so it lives in the tight tier and confine-strict.sh covers
        # it; on these two the mechanism is an allowlist already and it costs
        # nothing, so it is asserted at every tier.
        check "cannot execute what it wrote"                 EXEC_BLOCKED
        # macOS does not redirect TMPDIR, so that is a real writable directory
        # outside the app dir; OpenBSD does redirect it, into the app dir the
        # line above just took execute off. Two different reasons, one answer,
        # and w^x is a lie on either platform if it comes back executable.
        check "cannot execute what it wrote to the temp dir" EXEC_TMP_BLOCKED ;;
    *)
        nt_note "w^x is tight-tier only on linux; got $(grep -o 'EXEC_[A-Z_]*' <<<"$OUT" | tr '\n' ' ')" ;;
esac

# What the probe actually copied. A denial and a copy that never happened have
# looked identical here for as long as this file has existed -- and on any
# platform without /bin/true they are not the same thing at all.
nt_note "exec probe sources: $(grep -oE 'EXEC(TMP)?SRC:[^ ]*' <<<"$OUT" | tr '\n' ' ')"

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
# Which tier this binary is, taken from what it reports rather than from how the
# suite was invoked. The /proc write rule differs between the two and the
# assertions have to follow the binary, or a tier could be measured against the
# other one's expectations and pass.
NT_TIGHT=0
nt_tight_tier "$CONFINE" && NT_TIGHT=1

case "$CONFINE" in
    *landlock*)
        if grep -qx PEERMEM_SKIP <<<"$OUT"; then
            nt_note "no peer to probe /proc against here"
        else
            check "cannot write a peer's memory through /proc"  PEERMEM_BLOCKED
            check "cannot read a peer's maps either"            PEERMAPS_BLOCKED
            if [ "$NT_TIGHT" = "1" ]; then
                check "nothing under a peer's entry is writable"  PEERWRITABLE_NONE
                check "a peer's oom_score_adj is out of reach"    PEEROOM_BLOCKED
                # The narrowed rule takes the in-domain child with it. Asserted
                # so the pair above cannot be read as the ptrace hook doing the
                # work: here it is the filesystem rule, and both are refusing.
                check "an in-domain child goes with it"           CHILDMEM_BLOCKED
            else
                check "the same /proc rule still reaches its own" CHILDMEM_ESCAPED
                # Asserted to the measured value, not to the desirable one. This
                # is the default tier's ceiling and the README says so; if it
                # ever reads BLOCKED the ceiling moved and the README is wrong,
                # which is a failure worth having rather than silence.
                check "a peer's oom_score_adj is writable here"   PEEROOM_ESCAPED
            fi
        fi
        if grep -qx PROCSELF_SKIP <<<"$OUT"; then
            nt_note "no /proc/self probe here"
        else
            # Both tiers. The tight rule grants only WRITE_FILE on /proc/self
            # and reads survive on the read rule above it, which is landlock
            # accumulating rights up the hierarchy rather than letting the
            # deepest rule decide alone. A tier that passed everything else by
            # having quietly stopped reading its own /proc would look like a
            # clean result, so this is asked rather than assumed.
            check "reads under its own /proc entry still work" PROCSELFREAD_OK
            if [ "$NT_TIGHT" = "1" ]; then
                check "its own /proc entry is read-only now"      PROCSELF_BLOCKED
                check "a descendant's /proc entry is out of reach" PROCCHILD_BLOCKED
            else
                check "its own /proc entries stay writable"        PROCSELF_OK
                check "a descendant's /proc entry stays writable"  PROCCHILD_OK
            fi
            # The write bubblewrap and chromium's namespace_sandbox.c depend on:
            # a parent setting up a child's user namespace by writing that
            # child's setgroups and uid_map. It is what the tight tier pays for
            # the peer being out of reach, and what the default tier keeps by
            # not narrowing. Asserted both ways so the trade cannot move in
            # either direction without the suite saying so.
            if grep -qx USERNSMAP_SKIP <<<"$OUT"; then
                nt_note "no user namespace to map here: $(grep '^usernsmap ' <<<"$OUT")"
            elif [ "$NT_TIGHT" = "1" ]; then
                check "and the map write an engine sandbox needs" USERNSMAP_BLOCKED
            else
                check "the map write an engine sandbox needs works" USERNSMAP_OK
            fi
        fi ;;
    *)  nt_note "the /proc verdict needs a landlock domain; got $CONFINE" ;;
esac

if [ "$(uname -s)" = "Darwin" ]; then
    echo "=== LaunchServices, in whichever tier this binary carries ==="
    # Asserted in both directions and keyed on what the binary reports, not on
    # how it was invoked -- the same discipline the /proc rules above use. The
    # default tier's answer is a finding rather than a fix, so ground rule 6
    # applies and it is asserted to the value that was measured: a change in
    # either direction is a failure and not a silence.
    #
    # The .command door is closed in both tiers and always was. It is
    # (deny appleevent-send) doing that, not anything added here -- with
    # Terminal up LaunchServices delivers the document as an apple event, and
    # that has been denied since the profile was written. Asserted so a future
    # change cannot quietly open it while attention is on the other two.
    check "an apple event to Terminal is refused" LSD_COMMAND_BLOCKED
    if [ "$NT_TIGHT" = "1" ]; then
        check "cannot launch a bundle it wrote through open(1)"   LSD_APP_BLOCKED
        check "cannot launch one through NSWorkspace either"      LSD_WS_BLOCKED
    else
        check "the default tier leaves open(1) reaching out"      LSD_APP_ESCAPED
        check "and NSWorkspace with it"                           LSD_WS_ESCAPED
    fi

    # The warm state is a second question, not a second reading of the first:
    # with Terminal already up LaunchServices routes differently, and a denial
    # has to hold in the ordinary state of a mac as well as in the cold one CI
    # manufactures. It carries its own control -- the warmup is an unconfined
    # launch through the same service moments before the confined attempt -- and
    # without it a BLOCKED here would be indistinguishable from a wedged daemon.
    NT_LSD_WARM_WANT="ESCAPED"
    [ "$NT_TIGHT" = "1" ] && NT_LSD_WARM_WANT="BLOCKED"
    case "$NT_LSD_WARM" in
        "not measured"*)
            nt_note "warm launchservices state not measured here" ;;
        *"terminal reached by the warmup: no"*)
            nt_note "warm launchservices not decisive: the warmup did not launch either" ;;
        *)  for d in APP WS; do
                case "$NT_LSD_WARM" in
                    *"LSD_${d}_$NT_LSD_WARM_WANT"*)
                        echo "  PASS: warm $d door agrees with the cold one (LSD_${d}_$NT_LSD_WARM_WANT)" ;;
                    *)  nt_fail "warm $d door expected=LSD_${d}_$NT_LSD_WARM_WANT actual=$NT_LSD_WARM"
                        FAILURES=$((FAILURES + 1)) ;;
                esac
            done ;;
    esac
fi

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
        *command=LAUNCHED*app=LAUNCHED*ws=LAUNCHED*)
            echo "  PASS: unconfined, all three launchservices doors do open" ;;
        *)  nt_fail "launchservices control expected=all three LAUNCHED actual=$NT_LSD_CONTROL"
            FAILURES=$((FAILURES + 1)) ;;
    esac
fi

echo "=== Recorded beside the assertions ==="
# The checks above say which way each answer went. These say what the answer
# was made of -- which files, which errno -- and no assertion carries that. On
# linux the /proc surface is now asserted in both tiers, so this is a record of
# the shape rather than a hole waiting for a fix; the darwin lines below are
# still the latter, and say which PR turns them into checks.
#
# nt_result and not nt_note: notices are capped at ten per step and the suite
# fills that bucket long before this line, and the step summary does not come
# back out through the API at all.
nt_tokens() { grep -oE "$1" <<<"$OUT" | tr '\n' ' '; }
NT_TIER="$([ "${NT_TIGHT:-0}" = "1" ] && echo tight || echo default)"

case "$(uname -s)" in
    Linux)
        nt_result "linux /proc peers [$NT_TIER tier]: ptrace_scope=$NT_PTRACE_STATE peer=${NEUTRINO_TEST_PEER:-none} confined: $(nt_tokens '(PEER|CHILD)(MEM|MAPS|WRITABLE|OOM)_[A-Z]+')[$(grep -E '^(peer|child) ' <<<"$OUT" | tr '\n' ';')] unconfined-control: $NT_PROC_CONTROL"
        nt_result "linux /proc write grant [$NT_TIER tier]: $(nt_tokens '(PROCSELFREAD|PROCSELFTRUNC|PROCSELF|PROCCHILD|USERNSMAP|USERNSCHILD|UIDMAPCHILD)_[A-Z]+')[$(grep -E '^(proc(selfread|self|child)|usernsmap|usernschild|uidmapchild) ' <<<"$OUT" | tr '\n' ';')] confine=$CONFINE"
        ;;
    Darwin)
        # Named by the binary: this suite runs twice on macos, once against the
        # default tier and once against the tight one, and two annotations
        # reading the same thing are one annotation as far as a reader is
        # concerned. Asserted above; recorded here because no assertion carries
        # the rcs, and under the tight tier open(1) reports failure while
        # NSWorkspace reports success and neither launches anything.
        nt_result "launchservices cold [$(basename "$BIN")] [$NT_TIER tier]: $(nt_tokens 'LSD_[A-Z]+_(ESCAPED|BLOCKED)')$(nt_tokens 'LSD_[A-Z]+_RC=[0-9]+')$(nt_tokens 'LSD_TERM_UP=[a-z]+')unconfined-control: $NT_LSD_CONTROL"
        nt_result "launchservices warm [$(basename "$BIN")] [$NT_TIER tier]: $NT_LSD_WARM"
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
