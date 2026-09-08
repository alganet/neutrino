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
# Readings are collected into one file and printed at the end rather than
# emitted line by line, which keeps a measurement and its neighbours together in
# the log. Failures go out as `::error` annotations, which is the one annotation
# this tree still uses.

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
# harness.sh after lib.sh, and the order is the mechanism: both define nt_fail
# and they disagree about arity, so the one sourced second is the one this file
# speaks. probe(), nt_note and nt_result are lib.sh's and are not shadowed.
#
# The tenth netinstall suite through the conversion, and the one with the most
# ways to stop early. Four binaries are optional arguments -- tight, fail-closed,
# session, open-session -- and the session half is Linux-only and needs a user
# namespace the runner may refuse. Where the earlier suites could put a skip in
# an else, this one has to put them before an `exit`, because a suite that
# returns in the middle leaves every case after it as a hole and a hole reads
# like a lane that stopped reporting.
. "$(cd "$(dirname "$0")/../../test/lib" && pwd)/harness.sh"
# The annotation lib.sh's nt_fail emitted, kept by name so a red netinstall check
# still says so on the run page.
NT_ANNOTATE=netinstall

# The session half's cases, listed once because three different places have to
# say "none of these could be asked here".
NT_SESSION_CASES="phases.session.baseline phases.session.strict.refused \
phases.session.strict.said phases.session.pid.norun phases.session.pid.said \
phases.session.normal.ran phases.session.normal.said phases.session.fork"
nt_skip_session() {
    local c
    for c in $NT_SESSION_CASES; do nt_skip "$c" "$1"; done
}

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin"
export NEUTRINO_HOME="$WORK/home"


# One line per measurement, printed together at the end.
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
    for p in /usr/bin/curl /bin/curl /usr/local/bin/curl /usr/pkg/bin/curl \
             /opt/homebrew/bin/curl; do
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

SPEC="fetchprobe-example-com-1$(nt_pin "$SERVE/fetchprobe.cmd")"
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
    nt_pass phases.control.jar "CONTROL_JAR_WRITTEN"
    CONTROL_OK=1
else
    nt_fail phases.control.jar "control expected=CONTROL_JAR_WRITTEN actual=no jar at $HOMEJAR (curl $("$CURLBIN" --version 2>&1 | head -1))"
fi
rm -f "$HOMEJAR"

# =====================================================================
# The measurement, per binary and per target
# =====================================================================
#
# Each run starts from an empty cache, or netinstall answers from the blob it
# already has and no fetch child is created at all.
# assert_write and assert_cost, and the rename is the same one writable.sh,
# envlen.sh and confine.sh each needed: these are the helpers that take their id
# through a variable, so they are the ones the registry scan in
# test/lib/selftest.sh cannot follow by reading the file, and assert_[a-z_]+ is
# the shape that scan knows. It also stops something that asserts from being
# named after the probe() beside it, which only records.
assert_write() {
    local id="$1" app="$2" label="$3" jar="$4" name="$5" want="$6"
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
        nt_fail "$id" "$label/$name: the fetch itself did not complete (rc=$rc) err=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        return
    fi
    got=BLOCKED
    [ -f "$jar" ] && got=ESCAPED
    probe "$label: ${name}_${got}"
    if [ "$got" = "$want" ]; then
        nt_pass "$id" "$label ${name}_${got}"
    else
        nt_fail "$id" "$label/$name expected=$want actual=$got"
    fi
    rm -f "$jar"
}

report_confine() {
    local label="$1" line
    line="$(grep -a 'fetch confine:' "$WORK/err" 2>/dev/null | tail -1 | sed 's/.*fetch confine: //')"
    probe "$label: fetch phase says '${line:-<nothing printed>}'"
}

# What each platform is asserted to, and it is now one answer everywhere.
#
# The other three confine the downloader to the blobs directory, and on macOS
# that is true only since the per-user temp allow came out of the fetch profile.
#
# Windows used to be the exception and the only place in this suite where two
# tiers were asserted to different answers: its default tier had no unprivileged
# mechanism that confined a write, so both of these targets escaped and were
# asserted as escaping rather than wished otherwise. The low integrity token and
# the Low label on the payload file alone are the fetch phase now, not an opt-in
# on top of it, so windows is asserted to the same BLOCKED as everywhere else
# and the special case is gone. These two lines are what would have failed
# before this commit.
WANT_HOME=BLOCKED
WANT_TMP=BLOCKED
WANT_TIGHT_HOME=BLOCKED
WANT_TIGHT_TMP=BLOCKED
# And where the fetch phase confines nothing at all -- FreeBSD and NetBSD,
# whose nt_confine returns -1 -- both targets escape, because there is nothing
# to confine them. Read off the sentence and not off a list of platforms: that
# is what --info is for, and it is now the only special case left here, windows
# having stopped being one.
SAYS_FETCH="$("$APP" --info 2>/dev/null | grep '^fetch' | sed 's/^fetch *//')"
case "$SAYS_FETCH" in
    none*)
        WANT_HOME=ESCAPED
        WANT_TMP=ESCAPED
        WANT_TIGHT_HOME=ESCAPED
        WANT_TIGHT_TMP=ESCAPED
        nt_note "the fetch phase confines nothing here ($SAYS_FETCH); both targets are asserted to escape" ;;
esac

echo "=== Default tier: what the fetch child could write ==="
assert_write phases.fetch.home "$APP" default "$HOMEJAR" HOMEJAR "$WANT_HOME"
report_confine default
assert_write phases.fetch.tmp "$APP" default "$TMPJAR" TMPJAR "$WANT_TMP"

echo "=== Default tier: the in-reach control ==="
# The other half of the control pair: a jar inside the directory the fetch
# phase says it confines writes to. If this one is missing too, the child never
# read the config and every BLOCKED above is vacuous.
rm -rf "$NEUTRINO_HOME"
mkdir -p "$NEUTRINO_HOME/blobs"
nt_curlrc "$NEUTRINO_HOME/blobs" "$BLOBJAR"
OUT="$(CURL_HOME="$(nt_native "$NEUTRINO_HOME/blobs")" nt_timeout 60 "$APP" 2>"$WORK/err")"
if [ "$NT_WINDOWS" = "1" ]; then
    # Windows grants one file, not the directory, so there is no second
    # writable thing in blobs to use as an in-reach control -- and this
    # assertion used to fail for exactly that reason once low integrity became
    # the tier rather than an opt-in on top of it.
    #
    # The in-reach control here is the payload itself: the child ran, read the
    # config (which is what BLOBJAR being absent would otherwise be ambiguous
    # about) and completed a transfer into the one file it was granted. If that
    # did not happen, every BLOCKED above is unearned in the same way.
    #
    # And the jar staying absent is the assertion, not a control. It is what
    # says the grant is a file and not a directory: the obvious implementation
    # -- labelling blobs -- would write this jar and pass everything above it.
    # Two facts here and they are two cases. The control is that the child ran
    # at all -- without it every BLOCKED above is unearned -- and the assertion
    # is that the jar stayed absent, which is what says the grant is a file and
    # not a directory. On the other three platforms the control is the jar being
    # written, because there the grant *is* the directory. One id for the
    # control with two expectations, and a second id for the windows-only claim.
    if ! grep -q APP_RAN <<<"$OUT"; then
        nt_fail phases.control.inreach "in-reach control expected=APP_RAN actual=nothing; the fetch never completed and every BLOCKED above is unearned; err=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        nt_skip phases.blobjar "the fetch never completed, so there is nothing to read the grant's width from"
    elif [ -f "$BLOBJAR" ]; then
        nt_pass phases.control.inreach "APP_RAN -- the child ran and read the config"
        probe "default: BLOBJAR_ESCAPED -- the grant is wider than the payload file"
        nt_fail phases.blobjar "BLOBJAR expected=BLOCKED actual=ESCAPED; the fetch child wrote $BLOBJAR"
    else
        nt_pass phases.control.inreach "APP_RAN -- the child ran and read the config"
        probe "default: BLOBJAR_BLOCKED -- the payload file was the only write"
        nt_pass phases.blobjar "BLOBJAR_BLOCKED -- the child ran and the payload file was its only write"
    fi
    rm -f "$BLOBJAR"
elif [ -f "$BLOBJAR" ]; then
    nt_pass phases.control.inreach "INJAR_WRITTEN -- the config is read from inside the confinement"
else
    nt_fail phases.control.inreach "in-reach control expected=INJAR_WRITTEN actual=nothing at $BLOBJAR; every BLOCKED above is unearned"
fi

if [ -z "$APP_TIGHT" ]; then
    for c in phases.tight.home phases.tight.tmp phases.tight.blobjar phases.info.tight phases.cost.tight; do
        nt_skip "$c" "no tight-tier binary was given to this suite"
    done
fi
if [ -n "$APP_TIGHT" ]; then
    echo "=== Tight tier: the same two questions ==="
    assert_write phases.tight.home "$APP_TIGHT" tight "$HOMEJAR" HOMEJAR "$WANT_TIGHT_HOME"
    report_confine tight
    assert_write phases.tight.tmp "$APP_TIGHT" tight "$TMPJAR" TMPJAR "$WANT_TIGHT_TMP"

    # The strongest thing the tight tier says, and the one that separates it
    # from every other platform here: the fetch child may write the payload file
    # and nothing else -- not even inside the blobs directory it downloads into,
    # which the other three grant wholesale. The default tier's in-reach control
    # above writes this same jar; at the tight tier it must not.
    #
    # It is also the control that says the tier is a file grant rather than a
    # directory one. A tight tier that had taken the obvious route -- labelling
    # blobs -- would write this jar and pass everything above it.
    if [ "$NT_WINDOWS" != "1" ]; then
        # The other three grant the blobs directory wholesale, so there is no
        # narrower grant here to read. Only windows makes this claim.
        nt_skip phases.tight.blobjar "this platform grants the blobs directory, so the payload file is not a narrower grant"
    fi
    if [ "$NT_WINDOWS" = "1" ]; then
        echo "=== Tight tier: and nothing else, not even in blobs ==="
        rm -rf "$NEUTRINO_HOME"
        mkdir -p "$NEUTRINO_HOME/blobs"
        nt_curlrc "$NEUTRINO_HOME/blobs" "$BLOBJAR"
        OUT="$(CURL_HOME="$(nt_native "$NEUTRINO_HOME/blobs")" nt_timeout 60 "$APP_TIGHT" 2>"$WORK/err")"
        if grep -q APP_RAN <<<"$OUT" && [ ! -f "$BLOBJAR" ]; then
            probe "tight: BLOBJAR_BLOCKED -- the payload file was the only write"
            nt_pass phases.tight.blobjar "BLOBJAR_BLOCKED"
        elif [ -f "$BLOBJAR" ]; then
            probe "tight: BLOBJAR_ESCAPED -- the grant is wider than the payload file"
            nt_fail phases.tight.blobjar "tight/BLOBJAR expected=BLOCKED actual=ESCAPED; the fetch child wrote $BLOBJAR"
        else
            nt_fail phases.tight.blobjar "tight/BLOBJAR: the fetch itself did not complete; err=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        fi
        rm -f "$BLOBJAR"
    fi
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
    OpenBSD)                    WANT_INFO="unveil" ;;
    # Not "unveil". These two were grouped with OpenBSD from the day the arm
    # was written and neither has one: sandbox_bsd.c returns -1 for them and
    # the line reads `none (no unprivileged confinement on this system...)`.
    # Measured on both lanes.
    FreeBSD|NetBSD|DragonFly)   WANT_INFO="none" ;;
    *)                          WANT_INFO="job object" ;;
esac
probe "--info fetch line: ${INFO:-<absent>}"
# And the tight tier's own line, which was the default tier's word for word
# until PR 18 -- measured empty for a round because netinstall parses its spec
# out of argv[0], which is why this asks the installed app and not the binary.
if [ -n "$APP_TIGHT" ]; then
    TINFO="$("$APP_TIGHT" --info 2>/dev/null | grep '^fetch' | sed 's/^fetch *//')"
    probe "--info fetch line, tight: ${TINFO:-<absent>}"
    if [ "$NT_WINDOWS" = "1" ]; then
        if grep -q "low integrity" <<<"$TINFO"; then
            nt_pass phases.info.tight "the tight tier's fetch line names what it applies"
        else
            nt_fail phases.info.tight "--info fetch tight expected=low integrity actual=$TINFO"
        fi
    fi
fi
if [ -z "$INFO" ]; then
    nt_fail phases.info.fetch "--info expected=a fetch line actual=none"
elif grep -q "$WANT_INFO" <<<"$INFO"; then
    nt_pass phases.info.fetch "--info names this platform's fetch mechanism ($WANT_INFO)"
else
    nt_fail phases.info.fetch "--info fetch expected=$WANT_INFO actual=$INFO"
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
assert_cost() {
    local id="$1" app="$2" label="$3" out
    rm -rf "$NEUTRINO_HOME"
    out="$(nt_timeout 60 "$app" 2>"$WORK/err")"
    case "$out" in
        *PAYLOADCURL_OK*)
            probe "$label: PAYLOADCURL_OK"
            nt_pass "$id" "$label curl works under the run phase confinement" ;;
        *)  nt_fail "$id" "$label: curl under the run phase expected=PAYLOADCURL_OK actual=$(tr '\n' ' ' <<<"$out" | cut -c1-160)" ;;
    esac
    probe "$label: run phase is '$("$app" --info 2>/dev/null | awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')'"
}
assert_cost phases.cost.default "$APP" default
[ -n "$APP_TIGHT" ] && assert_cost phases.cost.tight "$APP_TIGHT" tight

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
if [ -z "$FAILCLOSED" ]; then
    for c in phases.strict.nofetch phases.strict.said phases.strict.nopayload phases.strict.both; do
        nt_skip "$c" "no fail-closed binary was given to this suite"
    done
fi
if [ -n "$FAILCLOSED" ]; then
    echo "=== A strict build refuses to fetch unconfined ==="
    printf 'echo PAYLOAD_RAN\n' > "$SERVE/strictprobe.cmd"
    STRICTSPEC="strictprobe-example-com-1$(nt_pin "$SERVE/strictprobe.cmd")"
    STRICTAPP="$(nt_as "$FAILCLOSED" "$STRICTSPEC" "$WORK/bin-strict")"
    rm -rf "$NEUTRINO_HOME"
    OUT="$(NEUTRINO_TEST_NO_CONFINE=1 nt_timeout 60 "$STRICTAPP" 2>"$WORK/err")"
    RC=$?
    BLOBS="$(ls "$NEUTRINO_HOME/blobs" 2>/dev/null | grep -c '^[0-9a-f]\{64\}$')"
    probe "strict, nothing available: blobs=$BLOBS exit=$RC"
    if [ "$BLOBS" -eq 0 ]; then
        nt_pass phases.strict.nofetch "STRICT_FETCH_REFUSED -- nothing was downloaded"
    else
        nt_fail phases.strict.nofetch "strict fetch expected=nothing downloaded actual=$BLOBS blob(s)"
    fi
    if grep -qa "refusing to fetch unconfined" "$WORK/err"; then
        nt_pass phases.strict.said "said why on stderr"
    else
        nt_fail phases.strict.said "stderr expected=refusing-to-fetch-unconfined actual=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
    fi
    # Said either way: this spoke only when a strict build had run the payload
    # anyway, so the run where it behaved filed nothing at all.
    if grep -q PAYLOAD_RAN <<<"$OUT"; then
        nt_fail phases.strict.nopayload "strict build ran the payload with confinement disabled"
    else
        nt_pass phases.strict.nopayload "and did not run the payload"
    fi

    echo "=== And fetches, and runs, when both phases are confined ==="
    # Which needs a platform where both phases can be. Where nothing confines,
    # a strict build is *supposed* to refuse and this control has no positive
    # to offer -- asserting it there fails the build for keeping its contract.
    # The inverse is asserted instead, which is the contract on that platform:
    # it refuses at the first phase, and the refusal names the fetch and not
    # the run, because the fetch is where it stops.
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
    if [ "${SAYS_FETCH#none}" != "$SAYS_FETCH" ]; then
        if [ "$RC" -ne 0 ] && ! grep -q PAYLOAD_RAN <<<"$OUT" &&
           grep -qa "refusing to fetch unconfined" "$WORK/err"; then
            nt_pass phases.strict.both "nothing confines here, so it refused at the fetch and said so (exit $RC)"
        else
            nt_fail phases.strict.both "strict build with nothing to confine it expected=refuse at the fetch actual=exit $RC $(tr '\n' ' ' < "$WORK/err" | cut -c1-160)"
        fi
    elif grep -q PAYLOAD_RAN <<<"$OUT"; then
        nt_pass phases.strict.both "BOTH_PHASES_CONFINED -- fetched and ran"
    else
        nt_fail phases.strict.both "strict build expected=fetch and run actual=exit $RC err=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
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
    # Before the exit, not after it. A suite that returns from the middle leaves
    # every case below as a hole, and a hole is what a lane that stopped
    # reporting looks like -- so the reason has to be filed here, where it is
    # still known.
    if [ "$(uname -s)" != "Linux" ]; then
        nt_skip_session "the session half is linux-only; this is $(uname -s)"
    else
        nt_skip_session "no strict+session binary was given to this suite"
    fi
    cat "$RESULTS"
    echo "=== Results: $NT_FAILURES failure(s) ==="
    exit $NT_FAILURES
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

HALFSPEC="half-example-com-1$(nt_pin "$SERVE/half.cmd")"
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
    nt_skip_session "the tier cannot close here ($(half_info))"
    cat "$RESULTS"
    echo "=== Results: $NT_FAILURES failure(s) ==="
    exit $NT_FAILURES
fi
[ "$NT_USERNS_LIFTED" = "1" ] &&
    probe "session states: measured with kernel.apparmor_restrict_unprivileged_userns lifted for this suite"

echo "=== The whole session, closed, as the baseline ==="
rm -rf "$NEUTRINO_HOME"
BASE="$(nt_timeout 60 "$HALFAPP" 2>"$WORK/err")"
probe "closed: $(grep -oE 'BUS_[A-Z]*|SYSTEMBUS_[A-Z]*|PIDS:[0-9]*|UID:[0-9]*|FORK_AGAIN_[A-Z]*' <<<"$BASE" | tr '\n' ' ')"
# Said either way, and it was not before: a baseline that ran printed nothing,
# so the row carrying "everything below has something to be read against" was
# filed on exactly the runs where nothing below could be.
if grep -q PAYLOAD_RAN <<<"$BASE"; then
    nt_pass phases.session.baseline "the closed baseline ran"
else
    nt_fail phases.session.baseline "the closed baseline never ran; every half-closed reading below is against nothing"
fi

# Two binaries for each state: the session tier as it ships, which has to keep
# working, and the same tier built fail-closed, which has to refuse. One alone
# proves nothing -- a build that refuses everything and a build that accepts
# everything each pass half of this.
OPENAPP=""
[ -n "$OPENSESSION" ] && OPENAPP="$(nt_as "$OPENSESSION" "$HALFSPEC" "$WORK/bin-open")"
if [ -z "$OPENAPP" ]; then
    for c in phases.session.pid.norun phases.session.pid.said \
             phases.session.normal.ran phases.session.normal.said phases.session.fork; do
        nt_skip "$c" "no open-session binary was given to this suite, so there is nothing to compare the strict build against"
    done
fi

for STEP in seal pid map; do
    echo "=== A session that failed at: $STEP ==="
    rm -rf "$NEUTRINO_HOME"
    OUT="$(NEUTRINO_TEST_SESSION_FAIL=$STEP nt_timeout 60 "$HALFAPP" 2>"$WORK/err")"
    RC=$?
    probe "$STEP, strict build: exit=$RC $(grep -oa 'refusing to run[a-z :]*' "$WORK/err" | tail -1)"
    if grep -q PAYLOAD_RAN <<<"$OUT"; then
        nt_fail phases.session.strict.refused "$STEP: a strict build launched into a session that did not close"
    else
        nt_pass phases.session.strict.refused "$STEP: the strict build refused"
    fi
    # Half confined and broken are different refusals, and which one arrives
    # says whether the tier repaired what it could.
    WANT_SAID="refusing to run half confined"
    [ "$STEP" = "pid" ] && WANT_SAID="refusing to run: .*session broken"
    if grep -qa "$WANT_SAID" "$WORK/err"; then
        nt_pass phases.session.strict.said "$STEP: and said '$WANT_SAID'"
    else
        nt_fail phases.session.strict.said "$STEP: stderr expected=$WANT_SAID actual=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
    fi

    [ -n "$OPENAPP" ] || continue
    rm -rf "$NEUTRINO_HOME"
    OUT="$(NEUTRINO_TEST_SESSION_FAIL=$STEP nt_timeout 60 "$OPENAPP" 2>"$WORK/err")"
    RC=$?
    # grep -oE: `\|` is GNU's alternation and BSD reads it literally, so this
    # would have handed back an empty $MARKS on the bsd and macos-netinstall
    # lanes rather than the marks it was asked for. Every case that reads $MARKS
    # skips on all four lanes today for an unrelated reason, so it was a trap
    # rather than a defect -- but it was the same trap as the one above.
    MARKS="$(grep -oE 'BUS_[A-Z]*|SYSTEMBUS_[A-Z]*|PIDS:[0-9]*|UID:[0-9]*|PAYLOAD_RAN|PROBE_FAILED|FORK_AGAIN_[A-Z]*' <<<"$OUT" | tr '\n' ' ')"
    probe "$STEP, normal build: exit=$RC ${MARKS:-<no output>}"

    # "pid" is the one state with nothing left to try: the step that would have
    # repaired the others is the step that failed. What is left cannot fork
    # twice, so no build launches into it -- this is the one place where the
    # normal build is asserted to refuse as hard as the strict one.
    if [ "$STEP" = "pid" ]; then
        if grep -q PAYLOAD_RAN <<<"$OUT"; then
            nt_fail phases.session.pid.norun "pid: the normal build launched into a process that can fork once"
        else
            nt_pass phases.session.pid.norun "no build launches into an unfinishable session"
        fi
        if grep -qa "refusing to run: .*session broken" "$WORK/err"; then
            nt_pass phases.session.pid.said "and said so as a refusal, not a warning"
        else
            nt_fail phases.session.pid.said "pid: stderr expected=refusing-to-run-session-broken actual=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
        fi
        continue
    fi

    if ! grep -q PAYLOAD_RAN <<<"$OUT"; then
        nt_fail phases.session.normal.ran "$STEP: the normal build did not run at all; a step that fails now costs the launch"
        continue
    fi
    nt_pass phases.session.normal.ran "$STEP: the normal build ran"
    if grep -qa "warning: running half confined" "$WORK/err"; then
        nt_pass phases.session.normal.said "$STEP: it ran, and said what it actually got"
    else
        nt_fail phases.session.normal.said "$STEP: stderr expected=warning-running-half-confined actual=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
    fi
    # The fork ceiling is the whole reason this is not merely a weaker sandbox.
    # Both remaining states asked for a pid namespace and were finished into
    # one on the way out, so both have to come back able to fork -- including
    # the unmapped one, which is in trouble for a different reason.
    case " $MARKS " in
        *FORK_AGAIN_OK*) nt_pass phases.session.fork "$STEP: the app can still fork" ;;
        *) nt_fail phases.session.fork "$STEP: expected=FORK_AGAIN_OK actual=$MARKS err=$(grep -oai 'cannot fork' "$WORK/err" | head -1)" ;;
    esac
done

cat "$RESULTS"
# $NT_FAILURES rather than a counter of this file's own: nt_fail counts.
echo "=== Results: $NT_FAILURES failure(s) ==="
exit $NT_FAILURES
