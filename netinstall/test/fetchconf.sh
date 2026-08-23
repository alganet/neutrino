#!/bin/bash
# fetchconf.sh - what else is on the downloader's command line
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# fetch.c resolves curl and wget from absolute paths so a planted binary cannot
# take over the fetch, hands each of them an argv it built itself, and since
# PR 14 prints that argv and a `bounds` line from --info. Neither branch tells
# its downloader to ignore its configuration file: curl reads $CURL_HOME/.curlrc
# or $HOME/.curlrc unless given -q, and wget reads $WGETRC or $HOME/.wgetrc
# unless given --no-config. The -q already on the wget branch is wget's *quiet*
# flag and suppresses output, not configuration.
#
# Leaving that config alone is a decision fetch.c states out loud -- the OS
# trust store and the user's curl config are the trust anchor this design chose.
# That is a decision about trust. A config file is not limited to trust: every
# other option is in it too, including the two PR 14 put in the argv and taught
# --info to print, and including the one that chooses where the payload lands.
#
# The environment is the same channel. nt_env_scrub runs in main() *after*
# nt_fetch returns, and not at all under --fetch, so $CURL_HOME and $WGETRC --
# neither of which survives the allowlist -- reach the downloader intact.
#
# Every number below was measured on this branch before anything was written,
# on six lanes and four curl versions -- see SANDBOX.md, PR 17 -- and is
# asserted to what was measured, so a curl that grows a config location, or a
# config that starts beating the argv, is a failure here and not silence.
#
# The two production changes this gates: --info now names what the downloader
# reads besides its argv, and a downloader that reports success while writing
# nothing where it was told is said in those words rather than as "payload too
# large or unreadable". Both assertions fail against the commit before this one.
#
# Usage: fetchconf.sh <testing binary> <prefer-wget binary> [tight binary]

set -uo pipefail

BIN="${1:-}"
WBIN="${2:-}"
TBIN="${3:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: fetchconf.sh <netinstall -DNEUTRINO_TESTING> <-DNEUTRINO_FETCH_PREFER_WGET>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
[ -n "$WBIN" ] && [ -x "$WBIN" ] && WBIN="$(cd "$(dirname "$WBIN")" && pwd)/$(basename "$WBIN")"
[ -n "$TBIN" ] && [ -x "$TBIN" ] && TBIN="$(cd "$(dirname "$TBIN")" && pwd)/$(basename "$TBIN")"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin" "$WORK/cfg"
export NEUTRINO_HOME="$WORK/home"
BLOBS="$NEUTRINO_HOME/blobs"

FAILURES=0
LIMIT=$((16 * 1024 * 1024))

# What each lane measured before anything was written. Windows curl 8.16.0
# reads every location asked about; the two older curls read CURL_HOME and
# ~/.curlrc but not XDG; OpenBSD reads none of them through netinstall because
# unveil is an allowlist and the fetch list does not include any -- README.md
# has said so since PR 11 and this is the measurement behind the sentence.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        WANT_LOCS=" CURL_HOME=READ XDG=READ HOME_dot=READ HOME_us=READ APPDATA=READ USERPROFILE=READ INBLOBS=READ"
        WANT_OUT=landed ;;
    OpenBSD|FreeBSD|NetBSD|DragonFly)
        WANT_LOCS=" CURL_HOME=no XDG=no HOME_dot=no INBLOBS=READ"
        WANT_OUT=refused ;;
    *)
        WANT_LOCS=" CURL_HOME=READ XDG=no HOME_dot=READ INBLOBS=READ"
        WANT_OUT=refused ;;
esac

ok()  { echo "  PASS: $*"; }
bad() { nt_fail "$*"; FAILURES=$((FAILURES + 1)); }
bytes_of() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }

# What a run said for itself, short enough to survive as an annotation. The
# testing build narrates its own fetch confinement on stderr and that line is
# never the answer, so it comes out; what is left is the downloader's complaint
# and netinstall's verdict on it, which is exactly what tells a refused write
# apart from a fetch that simply did not happen.
said() {
    [ -f "$1" ] || { echo "<no stderr>"; return 0; }
    tr -d '\r' < "$1" | grep -av 'fetch confine:' | grep -av 'fetch failed:' \
        | grep -av '^[[:space:]]*$' \
        | tail -2 | tr '\n' ';' | tr -s ' ' | cut -c1-80
}

# ---------------------------------------------------------------- the server

PORT=$((20000 + RANDOM % 20000))
"$(nt_python)" "$HERE/hostile.py" "$PORT" "$SERVE" >/dev/null 2>&1 &
SERVER_PID=$!
export NEUTRINO_TEST_ORIGIN="http://127.0.0.1:$PORT"
trap 'kill $SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

UP=NO
for i in $(seq 1 100); do
    curl -sS -o /dev/null "$NEUTRINO_TEST_ORIGIN/ping" 2>/dev/null && { UP=YES; break; }
    sleep 0.1
done
if [ "$UP" != "YES" ]; then
    bad "the hostile server on port $PORT never came up; nothing below would mean anything"
    echo "=== Results: $FAILURES failure(s) ==="
    exit "$FAILURES"
fi

as()          { nt_as "$1" "$2" "$WORK/bin"; }
cached_path() { echo "$NEUTRINO_HOME/apps/$(nt_appkey "$1")/${1%%-*}.cmd"; }

# Runs "$@" under a wall-clock bound of $1 seconds. Not nt_timeout: it falls
# back to running unbounded where coreutils timeout is missing, which is macOS,
# and one shape here is a body that never ends. RUN_RC is -1 when the bound is
# what stopped it, and RUN_EL is how long it actually took.
RUN_RC=0
RUN_ALIVE=NO
RUN_EL=0
run_bounded() {
    local secs="$1"; shift
    local pid i t0 t1
    t0=$(date +%s)
    "$@" >/dev/null 2>&1 &
    pid=$!
    RUN_ALIVE=NO
    for i in $(seq 1 "$secs"); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        RUN_ALIVE=YES; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RUN_RC=-1
    else
        wait "$pid"; RUN_RC=$?
    fi
    t1=$(date +%s)
    RUN_EL=$((t1 - t0))
}

# Every location probe below runs the same benign fetch under a different
# environment, and every one of them has to start from nothing cached or the
# second run answers out of the cache rather than off the network.
clean_home() { rm -rf "$NEUTRINO_HOME"; }

printf 'echo hello from a neutrino app\n' > "$SERVE/good.cmd"
GOOD="good-com-example-0$(nt_pin "$SERVE/good.cmd")"
GOODBIN="$(as "$BIN" "$GOOD")"

# ------------------------------------------------------- control: it fetches

echo "=== Control: a benign payload, no configuration anywhere ==="
clean_home
BASE_RC=1
if "$GOODBIN" --fetch >/dev/null 2>&1 && [ -f "$(cached_path "$GOOD")" ]; then
    BASE_RC=0
    ok "the server serves, the fetch verifies, the blob is cached"
else
    bad "benign payload expected=fetched+cached actual=no; every reading below is vacuous"
fi

echo "=== The downloader this platform resolved ==="
INFO="$("$GOODBIN" --info 2>/dev/null)"
DLINE="$(printf '%s\n' "$INFO" | sed -n 's/^downloader  *//p')"
BLINE="$(printf '%s\n' "$INFO" | sed -n 's/^bounds  *//p')"
DBIN="$(printf '%s\n' "$DLINE" | awk '{print $1}')"
TOOL="${DBIN:-none}"; TOOL="${TOOL##*\\}"; TOOL="${TOOL##*/}"; TOOL="${TOOL%.exe}"
case "$TOOL" in
    curl) VER="$("$DBIN" --version 2>/dev/null | head -1 | cut -d' ' -f2)" ;;
    *)    VER="?" ;;
esac
# nt_build puts the output flag and its two operands last on both branches, so
# everything before them is the flag set under test. The binary comes off the
# front and the output flag off the back, because every reconstruction below
# supplies its own -o and its own url -- leave the flag on and curl is handed
# two of them.
NTOK="$(printf '%s\n' "$DLINE" | awk '{print NF}')"
OFLAG="$(printf '%s\n' "$DLINE" | awk '{print $(NF - 2)}')"
FLAGS=""
if [ "${NTOK:-0}" -ge 5 ] && { [ "$OFLAG" = "-o" ] || [ "$OFLAG" = "-O" ]; }; then
    FLAGS="$(printf '%s\n' "$DLINE" | awk '{for (i = 2; i <= NF - 3; i++) printf "%s%s", $i, (i < NF - 3 ? " " : "")}')"
else
    bad "--info's downloader line does not end in <output flag> <dest> <url>: '${DLINE:-<none>}'; the reconstructions below are skipped"
fi
CLINE="$(printf '%s\n' "$INFO" | sed -n 's/^config  *//p')"
echo "  downloader $DLINE"
echo "  bounds     $BLINE"
echo "  config     ${CLINE:-<none>}"

# The half of this PR that is about --info telling the truth. Before it there
# was no config line at all, and the downloader line was a claim a file can add
# to. Asserted per platform, because the honest sentence differs: on OpenBSD
# the fetch phase cannot read any of these, which README.md has said since
# PR 11 and which the locations below measure.
case "$(uname -s)" in
    OpenBSD|FreeBSD|NetBSD|DragonFly) WANT_CFG="unveil" ;;
    *)                                WANT_CFG="not suppressed" ;;
esac
case "$CLINE" in
    *"$WANT_CFG"*) ok "--info names what the downloader reads besides its argv" ;;
    *) bad "--info config expected=*${WANT_CFG}* actual='${CLINE:-<none>}'" ;;
esac

# Whether the argv suppresses the downloader's config. It does not, on purpose
# -- see the trust model in README.md, and the cost of the alternative measured
# at the bottom of this file. Reported so that a future argv growing a -q is
# visible here rather than only in whatever stopped working.
#
# Not to be read as a statement about --info, which does now name the config:
# that is the assertion a few lines above.
case "$DLINE" in
    *" -q "*|*" --no-config "*) ARGVQ=yes ;;
    *)                          ARGVQ=no ;;
esac

# ------------------------------------------- is the config channel open at all
#
# A dead proxy, not a file. Every other detector needs a path inside a config
# file, and a path is the one thing that does not survive the trip to a native
# windows downloader unchanged -- so a negative would be unreadable: a location
# that is not honoured and a path that did not translate look identical. A
# proxy line has no path in it. If the benign fetch that just succeeded now
# fails, the file was read, on any platform, with no translation involved.

DEADPROXY='http://127.0.0.1:1'

# Writes a curl config carrying only the dead proxy, at $1.
write_proxy_rc() {
    mkdir -p "$(dirname "$1")"
    printf 'proxy = "%s"\n' "$DEADPROXY" > "$1"
}

# Runs the benign fetch with the environment in $1 (name=value pairs, already
# native) and answers READ if it failed the way a dead proxy fails. The _keep
# form leaves the cache alone, for the one location that lives inside it.
try_location_keep() {
    local label="$1"; shift
    if env "$@" "$GOODBIN" --fetch >/dev/null 2>&1 && [ -f "$(cached_path "$GOOD")" ]; then
        echo "  $label: no (the fetch succeeded; the file was not read)"
        return 1
    fi
    echo "  $label: READ (the fetch was refused, which is the proxy answering)"
    return 0
}

try_location() {
    local label="$1"; shift
    clean_home
    try_location_keep "$label" "$@"
}

# The location every probe below this point writes its config into: the first
# one measured to be both honoured by this curl and readable under the fetch
# phase's own rules. Empty means no such location exists on this platform, and
# the probes that need one say so rather than reporting a number they did not
# earn.
CFGDIR=""
CFGENV=""
CFGWHERE=none

echo "=== Which configuration files this downloader reads ==="

LOCS=""
CURLHOME_OK=no

if [ "$TOOL" != "curl" ]; then
    echo "  SKIP: this platform did not resolve curl (tool=$TOOL)"
    LOCS=" tool=$TOOL"
else
    # Three levels, so a negative can be told apart from a broken probe:
    #   -K            -- the file's contents are valid for this curl
    #   direct + env  -- the location is honoured and the path translated
    #   netinstall    -- and the environment reaches the real fetch
    write_proxy_rc "$WORK/cfg/explicit"
    if "$DBIN" -sS -K "$(nt_native "$WORK/cfg/explicit")" -o /dev/null \
            "$NEUTRINO_TEST_ORIGIN/good.cmd" >/dev/null 2>&1; then
        bad "-K control expected=refused actual=fetched; this curl ignored a config it was handed by name, so every 'no' below is unreadable"
        KCTL=IGNORED
    else
        ok "handed the file by name, this curl takes the proxy from it"
        KCTL=OK
    fi

    write_proxy_rc "$WORK/cfg/curlhome/.curlrc"
    if env "CURL_HOME=$(nt_native "$WORK/cfg/curlhome")" "$DBIN" -sS -o /dev/null \
            "$NEUTRINO_TEST_ORIGIN/good.cmd" >/dev/null 2>&1; then
        echo "  direct CURL_HOME: no"
        DIRECT=no
    else
        echo "  direct CURL_HOME: READ"
        DIRECT=READ
    fi

    # Now the same question of the fetch netinstall actually performs. A hit
    # here is two findings at once: the location is honoured, and the caller's
    # environment reached the downloader unscrubbed.
    if try_location "netinstall CURL_HOME/.curlrc" "CURL_HOME=$(nt_native "$WORK/cfg/curlhome")"; then
        CURLHOME_OK=yes
        LOCS="$LOCS CURL_HOME=READ"
        CFGDIR="$WORK/cfg/work"
        CFGENV="CURL_HOME=$(nt_native "$WORK/cfg/work")"
        CFGWHERE=tmp
    else
        LOCS="$LOCS CURL_HOME=no"
    fi

    write_proxy_rc "$WORK/cfg/xdg/curlrc"
    try_location "netinstall XDG_CONFIG_HOME/curlrc" "XDG_CONFIG_HOME=$(nt_native "$WORK/cfg/xdg")" \
        && LOCS="$LOCS XDG=READ" || LOCS="$LOCS XDG=no"

    write_proxy_rc "$WORK/cfg/home/.curlrc"
    try_location "netinstall HOME/.curlrc" "HOME=$(nt_native "$WORK/cfg/home")" \
        && LOCS="$LOCS HOME_dot=READ" || LOCS="$LOCS HOME_dot=no"

    if [ "$NT_WINDOWS" = "1" ]; then
        # The windows spellings. curl looks for _curlrc as well as .curlrc, and
        # at %APPDATA% and %USERPROFILE% as well as %HOME%. Each in a directory
        # of its own, or the .curlrc written above answers for the _curlrc case.
        write_proxy_rc "$WORK/cfg/home_us/_curlrc"
        try_location "netinstall HOME/_curlrc" "HOME=$(nt_native "$WORK/cfg/home_us")" \
            && LOCS="$LOCS HOME_us=READ" || LOCS="$LOCS HOME_us=no"

        write_proxy_rc "$WORK/cfg/appdata/_curlrc"
        try_location "netinstall APPDATA/_curlrc" "APPDATA=$(nt_native "$WORK/cfg/appdata")" \
            && LOCS="$LOCS APPDATA=READ" || LOCS="$LOCS APPDATA=no"

        write_proxy_rc "$WORK/cfg/userprofile/_curlrc"
        try_location "netinstall USERPROFILE/_curlrc" "USERPROFILE=$(nt_native "$WORK/cfg/userprofile")" \
            && LOCS="$LOCS USERPROFILE=READ" || LOCS="$LOCS USERPROFILE=no"
    fi

    # The reading round 1 was missing, and the one that decides what OpenBSD's
    # three noes mean. Every location above lives under a temporary directory,
    # and the fetch phase there unveils /usr, /bin, /etc/ssl, /etc/resolv.conf,
    # /dev/urandom, the hints file and <home>/blobs -- and nothing else. So a
    # "no" on that lane could be either of two very different things: the
    # location is not honoured, or it is honoured and the confinement refused
    # the read. The `direct` control says curl honours it; this says what the
    # confinement does when the file is somewhere it may look. <home>/blobs is
    # the one directory granted in every fetch profile on every platform.
    clean_home
    mkdir -p "$BLOBS"
    write_proxy_rc "$BLOBS/.curlrc"
    if try_location_keep "netinstall CURL_HOME=<blobs>" "CURL_HOME=$(nt_native "$BLOBS")"; then
        LOCS="$LOCS INBLOBS=READ"
        # Preferred over the temporary directory above, and the preference is
        # the point. The tight tiers allowlist reads, and OpenBSD's unveil is an
        # allowlist by construction, so a config anywhere else is a file those
        # phases cannot open -- and a steal that does not land then says nothing
        # about the write, which is the question. blobs is granted in every
        # fetch profile on every platform at every tier.
        CFGDIR="$BLOBS"
        CFGENV="CURL_HOME=$(nt_native "$BLOBS")"
        CFGWHERE=blobs
    else
        LOCS="$LOCS INBLOBS=no"
    fi
fi

nt_result "report: fetchconf tool=$TOOL ver=${VER:-?} argv-suppresses=$ARGVQ base=$BASE_RC kctl=${KCTL:-n/a} direct=${DIRECT:-n/a}"
nt_result "report: fetchconf locations$LOCS"
if [ "$LOCS" = "$WANT_LOCS" ]; then
    ok "every configuration location reads exactly as measured"
else
    bad "locations expected='$WANT_LOCS' actual='$LOCS'"
fi

# ------------------------------------------------ does the config beat the argv
#
# curl documents its config as parsed *before* the command line, so for a
# last-wins option the argv should win and PR 14's two bounds should hold. That
# is the whole of PR 14's claim on this branch and it has never been asked with
# a config file present. Asked in both directions: a size the config raises and
# a clock the config lowers.

echo "=== Whether a config option beats the same option on the argv ==="
# Gated on the *direct* control, not on CFGENV: these run curl straight from
# the shell with no confinement anywhere, so the only thing they need is a curl
# that honours CURL_HOME -- which is what `direct` measured. Round 1 gated them
# on the confined reading instead and skipped OpenBSD for a reason that has
# nothing to do with the question.
OVR="unasked"
if [ "${DIRECT:-no}" = "READ" ]; then
    CH="$WORK/cfg/override"
    mkdir -p "$CH"

    # Size. The config asks for a limit far past netinstall's, against a body
    # with no declared length -- the shape fetchbound measured the flag biting
    # mid-body on. If the argv wins, this stops at or under the limit.
    printf 'max-filesize = 999999999\n' > "$CH/.curlrc"
    rm -f "$WORK/ovr-size.bin"
    if [ -z "$FLAGS" ]; then
        OVRSIZE="unasked/no-flags"
    else
        run_bounded 90 env "CURL_HOME=$(nt_native "$CH")" "$DBIN" $FLAGS \
            -o "$WORK/ovr-size.bin" "$NEUTRINO_TEST_ORIGIN/chunked.cmd"
        SZ=$(bytes_of "$WORK/ovr-size.bin")
        if [ "$SZ" -le "$LIMIT" ]; then
            ok "a config asking for 999999999 bytes does not raise the argv's limit (${SZ}b)"
            OVRSIZE="argv/${SZ}b"
        else
            OVRSIZE="config/${SZ}b"
            echo "  the config raised the size bound: ${SZ}b, past $LIMIT"
        fi
    fi

    # Clock, the other direction: a config asking for less than the argv. If
    # the argv wins this runs to the bound below and is still alive; if the
    # config wins it exits at about three seconds.
    printf 'max-time = 3\n' > "$CH/.curlrc"
    if [ -n "$FLAGS" ]; then
        run_bounded 30 env "CURL_HOME=$(nt_native "$CH")" "$DBIN" $FLAGS \
            -o "$WORK/ovr-time.bin" "$NEUTRINO_TEST_ORIGIN/dribble.cmd"
        if [ "$RUN_ALIVE" = "YES" ]; then
            OVRTIME="argv/alive-at-30s"
        else
            OVRTIME="config/${RUN_EL}s"
        fi
    else
        OVRTIME="unasked"
    fi
    echo "  size=$OVRSIZE time=$OVRTIME"
    OVR="size=$OVRSIZE time=$OVRTIME"
else
    echo "  SKIP: this curl does not honour CURL_HOME even unconfined"
fi
nt_result "report: fetchconf override $OVR"
# PR 14 put --max-filesize and --max-time in the argv and taught --info to
# print them. This is that claim asked with a config file trying to move both,
# which is the regression this suite exists to hold: curl parses the config
# first, so a last-wins option is won by the command line.
case "$OVR" in
    *"size=argv/"*) ok "a config cannot raise the argv's size bound" ;;
    *) bad "override size expected=argv actual='$OVR'" ;;
esac
case "$OVR" in
    *"time=argv/"*) ok "a config cannot lower the argv's clock either" ;;
    *) bad "override time expected=argv actual='$OVR'" ;;
esac

# --------------------------------------------- and the option that is not last-wins
#
# -o does not last-win. curl pairs output flags with URLs in the order both
# appear, and the config is prepended -- so a config `output` would take the
# one URL and netinstall's -o would be left holding nothing. Where the payload
# lands then is the question, and the fetch phase confinement is what decides
# it: PR 10 confines that child's writes to <home>/blobs on three platforms and
# to nothing at all on the fourth, which is measured here rather than reasoned.

echo "=== Where a config's own output flag puts the payload ==="
STEAL_IN=unasked
STEAL_OUT=unasked
STEAL_TIGHT=unasked
FCONF=""

# One steal, against the binary in $1, writing to $2. Sets STEAL to the reading.
# The config goes in at CFGDIR after the cache is wiped, because on the platform
# where CFGDIR is <home>/blobs the wipe takes the config with it.
STEAL=""
steal_into() {
    local bin="$1" dest="$2" rc cached
    clean_home
    mkdir -p "$BLOBS" "$CFGDIR"
    rm -f "$dest"
    printf 'output = "%s"\n' "$(nt_native "$dest")" > "$CFGDIR/.curlrc"
    env "$CFGENV" "$bin" --fetch >/dev/null 2>"$WORK/steal.err"
    rc=$?
    cached=no; [ -f "$(cached_path "$GOOD")" ] && cached=YES
    STEAL="rc=$rc/$(bytes_of "$dest")b/cached=$cached/$(said "$WORK/steal.err")"
}

if [ -n "$CFGENV" ]; then
    # Inside the confined set first: if this does not land, the mechanism is
    # not there and the outside case below would be a false negative.
    steal_into "$GOODBIN" "$BLOBS/steal-inside.bin"
    STEAL_IN="$STEAL"
    cp "$WORK/steal.err" "$WORK/steal-in.err" 2>/dev/null
    echo "  inside blobs: $STEAL_IN"

    # And outside it, which is the one the confinement is supposed to refuse.
    steal_into "$GOODBIN" "$WORK/steal-outside.bin"
    STEAL_OUT="$STEAL"
    echo "  outside blobs: $STEAL_OUT"

    # The same question of the tight tier. nt_fetch_confine_win has no tier
    # branch in it at all, so on windows this is expected to read the same as
    # the line above -- which is the point: a tier that confines the run phase's
    # writes and not the fetch phase's is a thing to have measured rather than
    # inferred from an #ifdef that is not there.
    STEAL_TIN=unasked
    if [ -n "$TBIN" ] && [ -x "$TBIN" ]; then
        TIGHTBIN="$(as "$TBIN" "$GOOD")"
        steal_into "$TIGHTBIN" "$BLOBS/steal-tight-in.bin"
        STEAL_TIN="$STEAL"
        echo "  inside blobs, tight tier: $STEAL_TIN"
        steal_into "$TIGHTBIN" "$WORK/steal-tight.bin"
        STEAL_TIGHT="$STEAL"
        echo "  outside blobs, tight tier: $STEAL_TIGHT"
    else
        STEAL_TIN="SKIP no tight binary given"
        STEAL_TIGHT="SKIP no tight binary given"
    fi

    # What the confinement said it was doing while that happened, so the
    # readings above can be attributed to a rule rather than to luck. The
    # mechanism, not the path: the path is a temporary directory whose name is
    # different every run and is half the width of an annotation.
    FCONF="$(printf '%s\n' "$INFO" | sed -n 's/^fetch  *//p' | sed 's/,* writes confined to .*//' | cut -c1-70)"
else
    echo "  SKIP: no config location is both honoured and readable under the fetch phase"
fi
nt_result "report: fetchconf output cfg=$CFGWHERE in[$STEAL_IN] out[$STEAL_OUT] fetchline=${FCONF:-?}"
nt_result "report: fetchconf output-tight in[${STEAL_TIN:-unasked}] out[$STEAL_TIGHT]"

if [ -n "$CFGENV" ]; then
    # The control, first: the steal has to work somewhere, or "refused" below
    # is a mechanism that was never running.
    case "$STEAL_IN" in
        *"/31b/"*) ok "a config's output flag does take the payload" ;;
        *) bad "steal control expected=31b actual='$STEAL_IN'; the verdicts below prove nothing" ;;
    esac

    # The other half of this PR. netinstall used to answer this with "payload
    # too large or unreadable" -- a true sentence about a file that is not
    # there. This assertion fails against the commit before this one.
    if grep -aq 'wrote nothing to' "$WORK/steal-in.err" 2>/dev/null; then
        ok "and netinstall says the downloader wrote nothing where it was told"
    else
        bad "steal message expected=names-the-empty-destination actual='$(said "$WORK/steal-in.err")'"
    fi
    if grep -aq 'payload too large or unreadable' "$WORK/steal-in.err" 2>/dev/null; then
        bad "steal message: the old sentence is still being printed for a file that was never written"
    fi

    # Where those bytes land is reported here and asserted in phases.sh, which
    # owns that question and has since PR 10: same instrument -- a line in
    # $CURL_HOME/.curlrc that makes the fetch child attempt a write -- asked of
    # every tier on every platform and asserted to the measured value, windows
    # having no unprivileged filesystem confinement to give the downloader
    # included. Asserting it a second time here with a second copy of the same
    # apparatus is how two suites end up disagreeing about one fact. What this
    # suite adds is the consequence phases.sh does not measure: which file the
    # *payload* ends up in, and what netinstall then says about it.
    echo "  (the write reach itself is phases.sh's assertion; expected here: $WANT_OUT)"
fi

# ------------------------------------------------------------- the candidate fix

# Reported, not asserted, and deliberately so. -q is the flag that would close
# this channel outright, and this PR does not take it: honouring the
# downloader's own configuration is a decision README.md's trust model has
# carried since netinstall's first commit, and a user whose ~/.curlrc holds
# `proxy` or `cacert` would lose both silently. What is recorded here is what
# that alternative would have cost, so the decision can be revisited against
# numbers rather than reargued -- including env=kept, which says the
# environment half of the trust model would survive it.
echo "=== What suppressing the config would cost, if it were ever taken ==="
QSTATE="unasked"
if [ "$TOOL" = "curl" ] && [ "${DIRECT:-no}" = "READ" ]; then
    CH="$WORK/cfg/curlhome"     # still the dead proxy
    QACC=no
    "$DBIN" -q --version >/dev/null 2>&1 && QACC=yes

    # First, which is where curl documents it has to be.
    QFIRST=config
    env "CURL_HOME=$(nt_native "$CH")" "$DBIN" -q -sS -o /dev/null \
        "$NEUTRINO_TEST_ORIGIN/good.cmd" >/dev/null 2>&1 && QFIRST=suppressed

    # And after another flag, because the fix has to know whether position is
    # load-bearing before it edits nt_build's argv.
    QLATE=config
    env "CURL_HOME=$(nt_native "$CH")" "$DBIN" -sS -q -o /dev/null \
        "$NEUTRINO_TEST_ORIGIN/good.cmd" >/dev/null 2>&1 && QLATE=suppressed

    # And that the flag costs the shipped flag set nothing: the benign payload
    # still arrives and the size bound still bites.
    QBENIGN=no
    if [ -n "$FLAGS" ]; then
        rm -f "$WORK/q-good.bin"
        run_bounded 60 "$DBIN" -q $FLAGS -o "$WORK/q-good.bin" "$NEUTRINO_TEST_ORIGIN/good.cmd"
        [ "$RUN_RC" = "0" ] && [ "$(bytes_of "$WORK/q-good.bin")" -gt 0 ] && QBENIGN=yes

        rm -f "$WORK/q-chunked.bin"
        run_bounded 90 "$DBIN" -q $FLAGS -o "$WORK/q-chunked.bin" "$NEUTRINO_TEST_ORIGIN/chunked.cmd"
        QBOUND="$(bytes_of "$WORK/q-chunked.bin")"
    else
        QBOUND=-1
    fi
    # And what -q costs. It suppresses the config *file* and nothing else, so
    # a user whose proxy and CA bundle come from the environment keeps both --
    # which is most of what the "the user's curl config is the trust anchor"
    # decision in fetch.c is actually protecting. Measured rather than read out
    # of the manual, because it is the whole argument for the flag.
    QENV=lost
    env "http_proxy=$DEADPROXY" "$DBIN" -q -sS -o /dev/null \
        "$NEUTRINO_TEST_ORIGIN/good.cmd" >/dev/null 2>&1 || QENV=kept

    QSTATE="accepted=$QACC first=$QFIRST late=$QLATE benign=$QBENIGN chunked=${QBOUND}b env=$QENV"
    echo "  $QSTATE"
else
    echo "  SKIP: nothing to suppress"
fi
nt_result "report: fetchconf suppress $QSTATE"

# ------------------------------------------------------------ the wget branch
#
# The asymmetry PR 14 created and did not name. This branch's two bounds are
# not in its argv at all -- RLIMIT_FSIZE in the child and an alarm in the
# parent -- so a .wgetrc should not be able to reach them, while the curl
# branch's bounds are argv and might be reachable. Both halves measured.

echo "=== The fallback branch and its own config file ==="
WSTATE=skipped
WOUT=""
if [ -z "$WBIN" ] || [ ! -x "$WBIN" ]; then
    WSTATE="SKIP no prefer-wget binary given"
elif [ "$NT_WINDOWS" = "1" ]; then
    WSTATE="SKIP no fallback branch on windows"
else
    WINFO="$("$(as "$WBIN" "$GOOD")" --info 2>/dev/null)"
    WB="$(printf '%s\n' "$WINFO" | sed -n 's/^bounds  *//p')"
    case "$WB" in
        *"from the kernel"*) WSTATE=REACHED ;;
        *) WSTATE="SKIP wget not installed (bounds='${WB:-none}')" ;;
    esac
fi
echo "  $WSTATE"

if [ "$WSTATE" = "REACHED" ]; then
    WGOODBIN="$(as "$WBIN" "$GOOD")"
    WDBIN="$(printf '%s\n' "$WINFO" | sed -n 's/^downloader  *//p' | awk '{print $1}')"
    WVER="$("$WDBIN" --version 2>/dev/null | head -1 | sed -n 's/.*Wget \([^ ]*\).*/\1/p')"

    # Control: the branch fetches with no config anywhere.
    clean_home
    WBASE=no
    "$WGOODBIN" --fetch >/dev/null 2>&1 && [ -f "$(cached_path "$GOOD")" ] && WBASE=yes
    [ "$WBASE" = "yes" ] && ok "the fallback branch fetches a benign payload" ||
        bad "fallback control expected=fetched actual=no; its readings below prove nothing"

    # wget is not curl and the dead-proxy detector needs a second reading here.
    # GNU wget *fails* when $WGETRC names a file it cannot read, so on a
    # platform whose fetch phase unveils a set that does not include the config,
    # "the fetch was refused" is what both answers produce -- the proxy was
    # read, or the file could not be. Round 1 could not tell those apart and
    # reported READ on OpenBSD for the second one. So: a direct control, the way
    # curl has one, and the wget's own words on stderr.
    WPROXY="$WORK/cfg/wgetrc"
    printf 'http_proxy = %s\nuse_proxy = on\n' "$DEADPROXY" > "$WPROXY"

    WDIRECT=no
    env "WGETRC=$WPROXY" "$WDBIN" -q -O /dev/null \
        "$NEUTRINO_TEST_ORIGIN/good.cmd" >/dev/null 2>&1 || WDIRECT=READ
    echo "  direct WGETRC: $WDIRECT"

    clean_home
    WENV=no
    env "WGETRC=$WPROXY" "$WGOODBIN" --fetch >/dev/null 2>"$WORK/wenv.err" || WENV=REFUSED
    [ -f "$(cached_path "$GOOD")" ] && WENV=no
    echo "  WGETRC: $WENV -- $(said "$WORK/wenv.err")"

    # And $HOME/.wgetrc, which needs no environment variable of its own and
    # which wget treats as optional -- an unreadable one is silence rather than
    # an error, which is the asymmetry that makes these two readings differ.
    mkdir -p "$WORK/cfg/whome"
    cp "$WPROXY" "$WORK/cfg/whome/.wgetrc"
    clean_home
    WHOME=no
    env "HOME=$WORK/cfg/whome" "$WGOODBIN" --fetch >/dev/null 2>&1 || WHOME=READ
    [ -f "$(cached_path "$GOOD")" ] && WHOME=no
    echo "  HOME/.wgetrc: $WHOME"

    # And the same config from inside <home>/blobs, which every fetch profile
    # grants on every platform. This is what says whether a "no" above is the
    # location not being honoured or the confinement refusing the read.
    clean_home
    mkdir -p "$BLOBS"
    cp "$WPROXY" "$BLOBS/wgetrc"
    WINB=no
    env "WGETRC=$BLOBS/wgetrc" "$WGOODBIN" --fetch >/dev/null 2>"$WORK/winb.err" || WINB=READ
    [ -f "$(cached_path "$GOOD")" ] && WINB=no
    echo "  WGETRC=<blobs>/wgetrc: $WINB -- $(said "$WORK/winb.err")"

    # Does a config output_document take the payload the way curl's output does?
    # Run from whichever location just proved readable under the confinement.
    # blobs last, so it wins. Round 2 had these the other way round and the
    # second line overwrote the first on the one lane where it mattered: on
    # OpenBSD WENV is REFUSED *because* the file could not be opened, and
    # WDIRECT is READ, so both readings below went on to run against a config
    # in a temporary directory that the fetch phase cannot read -- which is the
    # very thing this round exists to stop doing.
    WRC_DIR=""
    [ "$WENV" = "REFUSED" ] && [ "$WDIRECT" = "READ" ] && WRC_DIR="$WPROXY"
    [ "$WINB" = "READ" ] && WRC_DIR="$BLOBS/wgetrc"
    WSTEAL=unasked
    if [ -n "$WRC_DIR" ]; then
        WPATH="$WORK/wsteal.bin"
        rm -f "$WPATH"
        clean_home
        mkdir -p "$BLOBS"
        printf 'output_document = %s\n' "$WPATH" > "$WRC_DIR"
        env "WGETRC=$WRC_DIR" "$WGOODBIN" --fetch >/dev/null 2>&1
        WRC=$?
        WCACHED=no; [ -f "$(cached_path "$GOOD")" ] && WCACHED=YES
        WSTEAL="rc=$WRC/$(bytes_of "$WPATH")b/cached=$WCACHED"
        echo "  output_document: $WSTEAL"
    fi

    # The kernel's two bounds, with a config present that would like them gone.
    # quota is wget's own size knob; it does not apply to a single file, which
    # is exactly why the kernel is holding this one. From the readable location,
    # or round 1's reading repeats: wget refusing its own config is not the
    # kernel refusing a body, and both arrive as a failed fetch.
    [ -n "$WRC_DIR" ] || WRC_DIR="$WPROXY"
    # One wipe, and it comes before the config is written -- not after. With
    # the config in a temporary directory the stray second wipe here was
    # harmless; with it in <home>/blobs it deleted the file under test, and
    # what came back was wget refusing an unreadable WGETRC rather than the
    # kernel refusing a body. Which is, exactly, the confusion this round was
    # opened to remove.
    clean_home
    mkdir -p "$BLOBS"
    printf 'quota = 0\ntimeout = 600\ntries = 1\n' > "$WRC_DIR"
    # Thirty-two legal hex characters matching nothing; the size refusal
    # arrives long before a digest is compared.
    WSPEC="chunked-com-example-00a1b2c3d4e5f60718a1b2c3d4e5f6071"
    WERR="$WORK/wbound.err"
    env "WGETRC=$WRC_DIR" "$(as "$WBIN" "$WSPEC")" --fetch >/dev/null 2>"$WERR"
    WBRC=$?
    WMSG="$(tr -d '\r' < "$WERR" | grep -a 'netinstall:' | tail -1)"
    case "$WMSG" in
        *"sent more than"*) WBOUND=held ;;
        *)                  WBOUND="rc=$WBRC/'${WMSG:-<none>}'" ;;
    esac
    echo "  size bound with a config present: $WBOUND"

    # And whether the candidate fix exists on this lane's wget at all.
    WNOCONF=no
    "$WDBIN" --no-config --version >/dev/null 2>&1 && WNOCONF=yes
    echo "  --no-config accepted: $WNOCONF"

    WOUT=" ver=${WVER:-?} base=$WBASE direct=$WDIRECT WGETRC=$WENV HOME=$WHOME inblobs=$WINB"
    WOUT="$WOUT steal[$WSTEAL] bound=$WBOUND noconfig=$WNOCONF"
    # Only where there is something to say. On a lane whose fetch phase can
    # read the config, both of these are empty and an empty annotation costs a
    # slot in a bucket of ten that this suite is already first in line for.
    WSAID="env[$(said "$WORK/wenv.err")] inblobs[$(said "$WORK/winb.err")]"
    case "$WSAID" in
        "env[] inblobs[]") : ;;
        *) nt_result "report: fetchconf wget-said $WSAID" ;;
    esac
fi
nt_result "report: fetchconf wget $WSTATE$WOUT"

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
