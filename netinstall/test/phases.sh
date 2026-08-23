#!/bin/bash
# phases.sh - the two phases either side of the run phase, and what they get
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# The run phase has --info, confine.sh, a tier flag and a strict build that
# refuses when nothing applied. The fetch phase had none of that: nt_fetch
# called nt_confine and threw the answer away, nothing printed what the
# downloader was given, and no suite ever asked. Neither had anyone asked what
# a session that half closed leaves the app holding. This asserts both, and
# every assertion here fails against the commit before it.
#
# Where the answer is a platform's ceiling rather than a fix -- windows has no
# unprivileged filesystem confinement to give the downloader -- it is asserted
# to the measured value, so a windows that gains or loses one is a failure here
# and not a silence.
#
# The instrument for the first is curl's own configuration file. netinstall
# resolves the downloader from absolute paths and deliberately leaves its
# config alone -- the OS trust store and the user's curl config are this
# design's trust anchor -- so a "cookie-jar" line in $CURL_HOME/.curlrc is a
# write the fetch child attempts after execv, from inside whatever sandbox it
# was handed, with nothing on netinstall's command line overriding it. curl
# gives up on a jar it cannot write without failing the transfer, so the file's
# presence is the fetch child's write reach and nothing else.
#
# Readings leave through test/annotate.sh rather than one annotation each:
# GitHub keeps ten warnings per step, the netinstall step is already over that,
# and a measurement nobody can read is not a measurement. Failures go out as
# errors, which have a bucket of their own.

set -uo pipefail

BIN="${1:-}"
TIGHT="${2:-}"
FAILCLOSED="${3:-}"
SESSION="${4:-}"
OPENSESSION="${5:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: phases.sh <testing> [tight] [strict] [strict+session] [session]" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
for v in TIGHT FAILCLOSED SESSION OPENSESSION; do
    eval "b=\${$v}"
    [ -n "$b" ] && [ -x "$b" ] &&
        eval "$v=\"\$(cd \"\$(dirname \"$b\")\" && pwd)/\$(basename \"$b\")\""
done
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"

FAILURES=0

# One line per measurement, packed into annotations at the end. nt_result would
# spend one of the step's ten warnings on each.
RESULTS="$WORK/results.log"
: > "$RESULTS"
probe() {
    echo "  $*"
    echo "probe: $*" >> "$RESULTS"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# The same list, in the same order, that fetch.c resolves from. Asking $PATH
# would ask a different question than the one under test.
nt_downloader() {
    local p
    if [ "$NT_WINDOWS" = "1" ]; then
        for p in "/c/Windows/System32/curl.exe" \
                 "$(cygpath -u "${SYSTEMROOT:-C:\\Windows}" 2>/dev/null)/System32/curl.exe"; do
            [ -x "$p" ] && { echo "$p"; return 0; }
        done
        return 1
    fi
    for p in /usr/bin/curl /bin/curl /usr/local/bin/curl /opt/homebrew/bin/curl; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

CURLBIN="$(nt_downloader)"
if [ -z "$CURLBIN" ]; then
    nt_note "SKIP: no curl at the paths fetch.c resolves; the wget fallback keeps its config elsewhere"
    rm -rf "$WORK"
    exit 0
fi

# Native for curl.exe, which does not read a git-bash path. Forward slashes on
# purpose: curl's config parser treats a backslash as an escape.
nt_native() {
    if [ "$NT_WINDOWS" = "1" ]; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Both names, because curl looks for _curlrc first on windows and .curlrc
# everywhere else.
nt_curlrc() {
    local dir="$1" jar="$2"
    mkdir -p "$dir"
    rm -f "$dir/.curlrc" "$dir/_curlrc"
    printf 'cookie-jar = %s\n' "$(nt_native "$jar")" > "$dir/.curlrc"
    cp "$dir/.curlrc" "$dir/_curlrc"
}

nt_serve "$SERVE" || exit 2
trap 'kill $NT_SERVER_PID 2>/dev/null; rm -f "$HOME/nt-fetch-probe-jar.txt"; rm -rf "$WORK"' EXIT

# Two targets, because "denied" and "allowed on purpose" look identical from
# here. $HOME is the one every platform should refuse. The mktemp directory is
# the Darwin per-user temp dir, which the fetch profile allows by name -- so a
# macOS ESCAPED there is the profile working as written, not a hole, and
# reporting only one of the two would have said the opposite. PR 1's O_TRUNC
# mistake is what this second target is here to avoid repeating.
HOMEJAR="$HOME/nt-fetch-probe-jar.txt"
TMPJAR="$WORK/nt-fetch-probe-jar.txt"
BLOBJAR="$NEUTRINO_HOME/blobs/nt-fetch-probe-jar.txt"

# The payload: cheap, and it carries the cost question for the windows half of
# the fix. If the fetch child has to be confined the way the run phase is, the
# thing that has to survive it is curl -- so ask the run phase, which already
# applies exactly that, whether curl still works inside it.
echo "COST_TARGET" > "$SERVE/cost.txt"
if [ "$NT_WINDOWS" = "1" ]; then
    cat > "$SERVE/fetchprobe.cmd" <<'BATCH'
@echo off
echo APP_RAN
"%NEUTRINO_TEST_CURL%" -fsS "%NEUTRINO_TEST_ORIGIN%/cost.txt" -o "%XDG_DATA_HOME%\cost.txt" >nul 2>&1
if errorlevel 1 (echo PAYLOADCURL_FAIL) else (echo PAYLOADCURL_OK)
BATCH
    export NEUTRINO_TEST_CURL="$(cygpath -w "$CURLBIN")"
else
    cat > "$SERVE/fetchprobe.cmd" <<'SCRIPT'
echo APP_RAN
if "$NEUTRINO_TEST_CURL" -fsS "$NEUTRINO_TEST_ORIGIN/cost.txt" -o "$XDG_DATA_HOME/cost.txt" 2>/dev/null; then
    echo PAYLOADCURL_OK
else
    echo PAYLOADCURL_FAIL
fi
SCRIPT
    export NEUTRINO_TEST_CURL="$CURLBIN"
fi

SPEC="fetchprobe-com-example-0$(nt_pin "$SERVE/fetchprobe.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
APP_TIGHT=""
[ -n "$TIGHT" ] && APP_TIGHT="$(nt_as "$TIGHT" "$SPEC" "$WORK/bin-tight")"

# =====================================================================
# The control: the instrument works, and the target is writable
# =====================================================================
#
# Without this every BLOCKED below is unearned -- a curl too old for the
# option, a config file in the wrong place and a sandbox doing its job are the
# same absence of a file.
echo "=== Control: an unconfined curl writes the jar ==="
CONTROL_OK=0
nt_curlrc "$WORK/rc-control" "$HOMEJAR"
rm -f "$HOMEJAR"
if CURL_HOME="$(nt_native "$WORK/rc-control")" "$CURLBIN" -fsS \
        "$NEUTRINO_TEST_ORIGIN/cost.txt" -o "$WORK/control.out" >/dev/null 2>&1 &&
   [ -f "$HOMEJAR" ]; then
    echo "  PASS: CONTROL_JAR_WRITTEN"
    CONTROL_OK=1
else
    nt_fail "control expected=CONTROL_JAR_WRITTEN actual=no jar at $HOMEJAR (curl $("$CURLBIN" --version 2>&1 | head -1))"
    FAILURES=$((FAILURES + 1))
fi
rm -f "$HOMEJAR"

# =====================================================================
# The measurement, per binary and per target
# =====================================================================
#
# Each run starts from an empty cache, or netinstall answers from the blob it
# already has and no fetch child is created at all.
probe_write() {
    local app="$1" label="$2" jar="$3" name="$4" want="$5"
    local out rc got

    rm -rf "$NEUTRINO_HOME"
    rm -f "$jar"
    # In the blobs directory, not a temp dir of the suite's own. The fetch phase
    # confines writes everywhere and reads too where the mechanism is an
    # allowlist -- OpenBSD's unveil is, so a config anywhere else is unreadable
    # and the child never learns where to write. That reads as BLOCKED, which is
    # the answer this is trying to earn, and the in-reach control below is what
    # caught it. blobs is the one directory every platform's fetch phase can
    # both read and write, so the instrument works the same in all four.
    mkdir -p "$NEUTRINO_HOME/blobs"
    nt_curlrc "$NEUTRINO_HOME/blobs" "$jar"
    out="$(CURL_HOME="$(nt_native "$NEUTRINO_HOME/blobs")" nt_timeout 60 "$app" 2>"$WORK/err")"
    rc=$?
    if ! grep -q APP_RAN <<<"$out"; then
        nt_fail "$label/$name: the fetch itself did not complete (rc=$rc) err=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        FAILURES=$((FAILURES + 1))
        return
    fi
    got=BLOCKED
    [ -f "$jar" ] && got=ESCAPED
    probe "$label: ${name}_${got}"
    if [ "$got" = "$want" ]; then
        echo "  PASS: $label ${name}_${got}"
    else
        nt_fail "$label/$name expected=$want actual=$got"
        FAILURES=$((FAILURES + 1))
    fi
    rm -f "$jar"
}

report_confine() {
    local label="$1" line
    line="$(grep -a 'fetch confine:' "$WORK/err" 2>/dev/null | tail -1 | sed 's/.*fetch confine: //')"
    probe "$label: fetch phase says '${line:-<nothing printed>}'"
}

# What each platform is asserted to. Windows has no unprivileged mechanism that
# confines a write, so the job object and stripped token it now gets are a
# resource boundary and nothing more -- asserted as such rather than wished
# otherwise. The other three confine the downloader to the blobs directory, and
# on macOS that is true only since the per-user temp allow came out of the
# fetch profile.
WANT_HOME=BLOCKED
WANT_TMP=BLOCKED
if [ "$NT_WINDOWS" = "1" ]; then
    WANT_HOME=ESCAPED
    WANT_TMP=ESCAPED
fi

echo "=== Default tier: what the fetch child could write ==="
probe_write "$APP" default "$HOMEJAR" HOMEJAR "$WANT_HOME"
report_confine default
probe_write "$APP" default "$TMPJAR" TMPJAR "$WANT_TMP"

echo "=== Default tier: the in-reach control ==="
# The other half of the control pair: a jar inside the directory the fetch
# phase says it confines writes to. If this one is missing too, the child never
# read the config and every BLOCKED above is vacuous.
rm -rf "$NEUTRINO_HOME"
mkdir -p "$NEUTRINO_HOME/blobs"
nt_curlrc "$NEUTRINO_HOME/blobs" "$BLOBJAR"
OUT="$(CURL_HOME="$(nt_native "$NEUTRINO_HOME/blobs")" nt_timeout 60 "$APP" 2>"$WORK/err")"
if [ -f "$BLOBJAR" ]; then
    echo "  PASS: INJAR_WRITTEN -- the config is read from inside the confinement"
else
    nt_fail "in-reach control expected=INJAR_WRITTEN actual=nothing at $BLOBJAR; every BLOCKED above is unearned"
    FAILURES=$((FAILURES + 1))
fi

if [ -n "$APP_TIGHT" ]; then
    echo "=== Tight tier: the same two questions ==="
    probe_write "$APP_TIGHT" tight "$HOMEJAR" HOMEJAR "$WANT_HOME"
    report_confine tight
    probe_write "$APP_TIGHT" tight "$TMPJAR" TMPJAR "$WANT_TMP"
fi

# =====================================================================
# What --info says about any of this
# =====================================================================
echo "=== --info and the fetch phase ==="
# It reported 'confine' for the run phase and 'downloader' for the command, and
# nothing at all for what confines the downloader -- so the one platform where
# that was nothing looked exactly like the three where it was something.
INFO="$("$APP" --info 2>/dev/null | grep '^fetch' | sed 's/^fetch *//')"
case "$(uname -s)" in
    Linux)                      WANT_INFO="landlock" ;;
    Darwin)                     WANT_INFO="seatbelt" ;;
    OpenBSD|FreeBSD|NetBSD)     WANT_INFO="unveil" ;;
    *)                          WANT_INFO="job object" ;;
esac
probe "--info fetch line: ${INFO:-<absent>}"
if [ -z "$INFO" ]; then
    nt_fail "--info expected=a fetch line actual=none"
    FAILURES=$((FAILURES + 1))
elif grep -q "$WANT_INFO" <<<"$INFO"; then
    echo "  PASS: --info names this platform's fetch mechanism ($WANT_INFO)"
else
    nt_fail "--info fetch expected=$WANT_INFO actual=$INFO"
    FAILURES=$((FAILURES + 1))
fi

# =====================================================================
# Cost: does curl survive the confinement the run phase applies?
# =====================================================================
#
# The downloader now runs inside what the run phase applies, so what the run
# phase costs curl is what the fetch costs it: Landlock, a seatbelt profile, a
# job object with a stripped token, and at the tight tier a low integrity label
# on windows. Kept as an assertion rather than a reading, because the day this
# stops being true is the day the fix stops being affordable.
echo "=== Cost: curl under the run phase's own confinement ==="
cost_probe() {
    local app="$1" label="$2" out
    rm -rf "$NEUTRINO_HOME"
    out="$(nt_timeout 60 "$app" 2>"$WORK/err")"
    case "$out" in
        *PAYLOADCURL_OK*)
            probe "$label: PAYLOADCURL_OK"
            echo "  PASS: $label curl works under the run phase confinement" ;;
        *)  nt_fail "$label: curl under the run phase expected=PAYLOADCURL_OK actual=$(tr '\n' ' ' <<<"$out" | cut -c1-160)"
            FAILURES=$((FAILURES + 1)) ;;
    esac
    probe "$label: run phase is '$("$app" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')'"
}
cost_probe "$APP" default
[ -n "$APP_TIGHT" ] && cost_probe "$APP_TIGHT" tight

[ "$CONTROL_OK" = "1" ] || probe "the control failed, so every BLOCKED above is unearned"

# =====================================================================
# Strict, and the phase it used to skip
# =====================================================================
#
# nt_fetch dropped nt_confine's answer, so a strict build downloaded the payload
# unconfined and refused afterwards -- measured on all four lanes before this
# changed, windows without any hook at all. NEUTRINO_TEST_NO_CONFINE is what
# stands in here for the kernel too old for Landlock, the macOS that rejects the
# profile, and the windows that cannot make a job object.
if [ -n "$FAILCLOSED" ]; then
    echo "=== A strict build refuses to fetch unconfined ==="
    printf 'echo PAYLOAD_RAN\n' > "$SERVE/strictprobe.cmd"
    STRICTSPEC="strictprobe-com-example-0$(nt_pin "$SERVE/strictprobe.cmd")"
    STRICTAPP="$(nt_as "$FAILCLOSED" "$STRICTSPEC" "$WORK/bin-strict")"
    rm -rf "$NEUTRINO_HOME"
    OUT="$(NEUTRINO_TEST_NO_CONFINE=1 nt_timeout 60 "$STRICTAPP" 2>"$WORK/err")"
    RC=$?
    BLOBS="$(ls "$NEUTRINO_HOME/blobs" 2>/dev/null | grep -c '^[0-9a-f]\{64\}$')"
    probe "strict, nothing available: blobs=$BLOBS exit=$RC"
    if [ "$BLOBS" -eq 0 ]; then
        echo "  PASS: STRICT_FETCH_REFUSED -- nothing was downloaded"
    else
        nt_fail "strict fetch expected=nothing downloaded actual=$BLOBS blob(s)"
        FAILURES=$((FAILURES + 1))
    fi
    if grep -qa "refusing to fetch unconfined" "$WORK/err"; then
        echo "  PASS: said why on stderr"
    else
        nt_fail "stderr expected=refusing-to-fetch-unconfined actual=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        FAILURES=$((FAILURES + 1))
    fi
    if grep -q PAYLOAD_RAN <<<"$OUT"; then
        nt_fail "strict build ran the payload with confinement disabled"
        FAILURES=$((FAILURES + 1))
    fi

    echo "=== And fetches, and runs, when both phases are confined ==="
    # The positive control for the refusal above, and on windows it is also the
    # nested job object question: the run phase creates a job of its own on top
    # of the one the fetch phase already put this process in. A strict binary is
    # the instrument -- if the second job is refused it exits 3 and says so
    # rather than launching quietly.
    rm -rf "$NEUTRINO_HOME"
    OUT="$(nt_timeout 60 "$STRICTAPP" 2>"$WORK/err")"
    RC=$?
    FETCHLINE="$(grep -a 'fetch confine:' "$WORK/err" | tail -1 | sed 's/.*fetch confine: //')"
    probe "strict, both phases: fetch got '${FETCHLINE:-<nothing printed>}', exit=$RC"
    if grep -q PAYLOAD_RAN <<<"$OUT"; then
        echo "  PASS: BOTH_PHASES_CONFINED -- fetched and ran"
    else
        nt_fail "strict build expected=fetch and run actual=exit $RC err=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        FAILURES=$((FAILURES + 1))
    fi
fi

# =====================================================================
# A session that half closed
# =====================================================================
#
# A namespace granted and then not sealed used to leave the app in a fresh
# mount namespace with nothing covered -- the bus it was supposed to lose still
# there -- and, worse, able to fork exactly once, because the pid namespace it
# was put in front of was never entered. Nothing printed that and no build
# refused it.
#
# Now the step that decides whether the app can fork is finished anyway, the
# tier says which step failed, and a strict build refuses. All three are
# asserted here against a forced failure at each step in turn, because a runner
# will not produce one on its own.
if [ -z "$SESSION" ] || [ "$(uname -s)" != "Linux" ]; then
    probe "session states: SKIPPED (no strict+session binary, or not linux)"
    bash "$ROOT/test/annotate.sh" phases "$RESULTS" 'probe:'
    echo "=== Results: $FAILURES failure(s) ==="
    exit $FAILURES
fi

# The order inside the payload is load-bearing. unshare(CLONE_NEWPID) puts the
# caller's children in a new namespace without entering it, so the app's *first*
# child becomes pid 1 of it -- and when that child exits the namespace dies and
# every fork after it fails. So the questions that need a child are asked first,
# in one child, and what is left of the app's ability to fork is measured last
# rather than being spent on a subshell that only wanted to print a uid.
cat > "$SERVE/half.cmd" <<'SCRIPT'
echo "PAYLOAD_RAN"
python3 -c "
import os, socket
def reach(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(path)
        return True
    except OSError:
        return False
    finally:
        s.close()
rt = os.environ.get('XDG_RUNTIME_DIR', '/run/user/%d' % os.getuid())
print('UID:%d' % os.getuid())
print('BUS_' + ('OK' if reach(rt + '/bus') else 'BLOCKED'))
print('SYSTEMBUS_' + ('OK' if reach('/run/dbus/system_bus_socket') else 'BLOCKED'))
print('PIDS:%d' % len([d for d in os.listdir('/proc') if d.isdigit()]))
" 2>/dev/null || echo "PROBE_FAILED"
# No redirection: when the fork is what failed it is the shell that says so,
# and sending its stderr to /dev/null threw away the only sentence naming the
# cause. That happened once here already.
if /bin/true; then echo "FORK_AGAIN_OK"; else echo "FORK_AGAIN_FAIL"; fi
SCRIPT

HALFSPEC="half-com-example-0$(nt_pin "$SERVE/half.cmd")"
HALFAPP="$(nt_as "$SESSION" "$HALFSPEC" "$WORK/bin-session")"

# A bus to lose. Asserting that an absent bus is unreachable would pass in
# every state this is trying to tell apart.
NT_BUS_PID=""
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
trap 'kill $NT_SERVER_PID $NT_BUS_PID 2>/dev/null; nt_userns_restore; rm -f "$HOMEJAR"; rm -rf "$WORK"' EXIT

half_info() {
    "$HALFAPP" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }'
}

# The tier has to be able to close for real before a forced failure means
# anything: on a runner that refuses the namespace outright, every state below
# collapses into "session open" and says nothing about half of anything.
nt_tier_closes() {
    case "$(half_info)" in
        *"session closed"*) return 0 ;;
    esac
    return 1
}
if ! nt_userns nt_tier_closes; then
    probe "session states: UNMEASURED -- the tier cannot close here ($(half_info))"
    bash "$ROOT/test/annotate.sh" phases "$RESULTS" 'probe:'
    echo "=== Results: $FAILURES failure(s) ==="
    exit $FAILURES
fi
[ "$NT_USERNS_LIFTED" = "1" ] &&
    probe "session states: measured with kernel.apparmor_restrict_unprivileged_userns lifted for this suite"

echo "=== The whole session, closed, as the baseline ==="
rm -rf "$NEUTRINO_HOME"
BASE="$(nt_timeout 60 "$HALFAPP" 2>"$WORK/err")"
probe "closed: $(grep -o 'BUS_[A-Z]*\|SYSTEMBUS_[A-Z]*\|PIDS:[0-9]*\|UID:[0-9]*\|FORK_AGAIN_[A-Z]*' <<<"$BASE" | tr '\n' ' ')"
if ! grep -q PAYLOAD_RAN <<<"$BASE"; then
    nt_fail "the closed baseline never ran; every half-closed reading below is against nothing"
    FAILURES=$((FAILURES + 1))
fi

# Two binaries for each state: the session tier as it ships, which has to keep
# working, and the same tier built fail-closed, which has to refuse. One alone
# proves nothing -- a build that refuses everything and a build that accepts
# everything each pass half of this.
OPENAPP=""
[ -n "$OPENSESSION" ] && OPENAPP="$(nt_as "$OPENSESSION" "$HALFSPEC" "$WORK/bin-open")"

for STEP in seal pid map; do
    echo "=== A session that failed at: $STEP ==="
    rm -rf "$NEUTRINO_HOME"
    OUT="$(NEUTRINO_TEST_SESSION_FAIL=$STEP nt_timeout 60 "$HALFAPP" 2>"$WORK/err")"
    RC=$?
    probe "$STEP, strict build: exit=$RC $(grep -oa 'refusing to run[a-z :]*' "$WORK/err" | tail -1)"
    if grep -q PAYLOAD_RAN <<<"$OUT"; then
        nt_fail "$STEP: a strict build launched into a session that did not close"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: the strict build refused"
    fi
    # Half confined and broken are different refusals, and which one arrives
    # says whether the tier repaired what it could.
    WANT_SAID="refusing to run half confined"
    [ "$STEP" = "pid" ] && WANT_SAID="refusing to run: .*session broken"
    if grep -qa "$WANT_SAID" "$WORK/err"; then
        echo "  PASS: and said '$WANT_SAID'"
    else
        nt_fail "$STEP: stderr expected=$WANT_SAID actual=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        FAILURES=$((FAILURES + 1))
    fi

    [ -n "$OPENAPP" ] || continue
    rm -rf "$NEUTRINO_HOME"
    OUT="$(NEUTRINO_TEST_SESSION_FAIL=$STEP nt_timeout 60 "$OPENAPP" 2>"$WORK/err")"
    RC=$?
    MARKS="$(grep -o 'BUS_[A-Z]*\|SYSTEMBUS_[A-Z]*\|PIDS:[0-9]*\|UID:[0-9]*\|PAYLOAD_RAN\|PROBE_FAILED\|FORK_AGAIN_[A-Z]*' <<<"$OUT" | tr '\n' ' ')"
    probe "$STEP, normal build: exit=$RC ${MARKS:-<no output>}"

    # "pid" is the one state with nothing left to try: the step that would have
    # repaired the others is the step that failed. What is left cannot fork
    # twice, so no build launches into it -- this is the one place where the
    # normal build is asserted to refuse as hard as the strict one.
    if [ "$STEP" = "pid" ]; then
        if grep -q PAYLOAD_RAN <<<"$OUT"; then
            nt_fail "pid: the normal build launched into a process that can fork once"
            FAILURES=$((FAILURES + 1))
        else
            echo "  PASS: no build launches into an unfinishable session"
        fi
        if grep -qa "refusing to run: .*session broken" "$WORK/err"; then
            echo "  PASS: and said so as a refusal, not a warning"
        else
            nt_fail "pid: stderr expected=refusing-to-run-session-broken actual=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
            FAILURES=$((FAILURES + 1))
        fi
        continue
    fi

    if ! grep -q PAYLOAD_RAN <<<"$OUT"; then
        nt_fail "$STEP: the normal build did not run at all; a step that fails now costs the launch"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    if grep -qa "warning: running half confined" "$WORK/err"; then
        echo "  PASS: it ran, and said what it actually got"
    else
        nt_fail "$STEP: stderr expected=warning-running-half-confined actual=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        FAILURES=$((FAILURES + 1))
    fi
    # The fork ceiling is the whole reason this is not merely a weaker sandbox.
    # Both remaining states asked for a pid namespace and were finished into
    # one on the way out, so both have to come back able to fork -- including
    # the unmapped one, which is in trouble for a different reason.
    case " $MARKS " in
        *FORK_AGAIN_OK*) echo "  PASS: the app can still fork" ;;
        *) nt_fail "$STEP: expected=FORK_AGAIN_OK actual=$MARKS err=$(grep -oai 'cannot fork' "$WORK/err" | head -1)"
           FAILURES=$((FAILURES + 1)) ;;
    esac
done

bash "$ROOT/test/annotate.sh" phases "$RESULTS" 'probe:'
echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
