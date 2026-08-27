#!/bin/bash
# fetchbound.sh - what bounds the bytes and the seconds a hostile host can spend
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# NT_MAX_PAYLOAD bounds what netinstall will *accept*: nt_sha256_file reads a
# file already on disk and refuses past sixteen mebibytes. What stops the bytes
# arriving is the downloader, and there are two of them with very different
# answers.
#
# verify.sh's oversized case is served by python -m http.server, which always
# sends a truthful Content-Length -- the one response shape a length-based guard
# refuses before any body arrives. hostile.py serves the shapes that decide the
# question instead: a length absent, a length that lies, a body delimited by the
# close, and a body that never ends.
#
# Every number asserted below was measured on this branch before the fix, on
# five lanes and four curl versions. See SANDBOX.md, PR 14.
#
# Usage: fetchbound.sh <testing binary> <prefer-wget binary>

set -uo pipefail

BIN="${1:-}"
WBIN="${2:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: fetchbound.sh <netinstall -DNEUTRINO_TESTING> <-DNEUTRINO_FETCH_PREFER_WGET>" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
[ -n "$WBIN" ] && [ -x "$WBIN" ] && WBIN="$(cd "$(dirname "$WBIN")" && pwd)/$(basename "$WBIN")"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin" "$WORK/out"
export NEUTRINO_HOME="$WORK/home"

FAILURES=0
LIMIT=$((16 * 1024 * 1024))
DEADLINE=120

# Thirty-two legal hex characters matching nothing. Every hostile shape is
# refused on size or on the clock long before a digest is compared.
NOMATCH="0a1b2c3d4e5f60718a1b2c3d4e5f6071"

ok()   { echo "  PASS: $*"; }
bad()  { nt_fail "$*"; FAILURES=$((FAILURES + 1)); }
bytes_of() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------- the server

PORT=$((20000 + RANDOM % 20000))
"$(nt_python)" "$HERE/hostile.py" "$PORT" "$SERVE" >/dev/null 2>&1 &
SERVER_PID=$!
export NEUTRINO_TEST_ORIGIN="http://127.0.0.1:$PORT"
trap 'kill $SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT

# No -f: an unrouted path answers 404 on purpose, and a 404 arriving is the
# server being up.
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

# Runs "$@" under a wall-clock bound of $1 seconds. Not nt_timeout: that falls
# back to running unbounded where coreutils timeout is missing, which is macOS,
# and one of the shapes here is a body that never ends. RUN_RC is -1 when the
# bound is what stopped it.
RUN_RC=0
RUN_ALIVE=NO
RUN_ERR=""
run_bounded() {
    local secs="$1"; shift
    local pid i
    if [ -n "$RUN_ERR" ]; then
        "$@" >/dev/null 2>"$RUN_ERR" &
    else
        "$@" >/dev/null 2>&1 &
    fi
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
}

# ------------------------------------------ control: the server serves at all

echo "=== Control: a benign payload from the same server ==="
printf 'echo hello from a neutrino app\n' > "$SERVE/good.cmd"
GOOD="good-example-com-1$(nt_pin "$SERVE/good.cmd")"
if "$(as "$BIN" "$GOOD")" --fetch >/dev/null 2>&1 && [ -f "$(cached_path "$GOOD")" ]; then
    ok "the server serves, the fetch verifies, the blob is cached"
else
    bad "benign payload expected=fetched+cached actual=no; every assertion below is vacuous"
fi

# ----------------------------------------------- the flag set actually shipped

echo "=== The downloader this platform resolved ==="
INFO="$("$(as "$BIN" "$GOOD")" --info 2>/dev/null)"
DLINE="$(printf '%s\n' "$INFO" | sed -n 's/^downloader  *//p')"
BLINE="$(printf '%s\n' "$INFO" | sed -n 's/^bounds  *//p')"
# nt_build puts the output flag and its two operands last on both branches, so
# everything before them is the flag set under test. A string and the shell's
# own splitting rather than an array: macOS runs this on bash 3.2, where
# "${a[@]}" on an empty array is unbound under set -u.
NTOK="$(printf '%s\n' "$DLINE" | awk '{print NF}')"
FLAGS=""
if [ "${NTOK:-0}" -lt 4 ]; then
    bad "--info printed no usable downloader line: '${DLINE:-<none>}'"
else
    FLAGS="$(printf '%s\n' "$DLINE" | awk '{for (i = 1; i <= NF - 2; i++) printf "%s%s", $i, (i < NF - 2 ? " " : "")}')"
fi
DBIN="$(printf '%s\n' "$DLINE" | awk '{print $1}')"
TOOL="${DBIN:-none}"; TOOL="${TOOL##*\\}"; TOOL="${TOOL##*/}"; TOOL="${TOOL%.exe}"
case "$TOOL" in
    curl) VER="$("$DBIN" --version 2>/dev/null | head -1 | cut -d' ' -f2)" ;;
    wget) VER="$("$DBIN" --version 2>/dev/null | head -1 | sed -n 's/.*Wget \([^ ]*\).*/\1/p')" ;;
    *)    VER="?" ;;
esac

# --info must name the bounds, because on the fallback branch neither of them
# appears in the command it prints. Ground rule 5.
case "$BLINE" in
    *"from curl"*) ok "--info names curl's own bounds" ;;
    *) bad "--info bounds expected=from-curl actual='${BLINE:-<none>}'" ;;
esac
nt_result "report: fetchbound tool=$TOOL ver=${VER:-?} bounds=$BLINE"

# ---------------------------- the shipped flags, asserted to what was measured

# Directly, rather than through --fetch: netinstall removes the temporary file
# on refusal, so by the time it has answered there is nothing left to weigh.
echo "=== The shipped flags, four hostile shapes ==="
RECON=skipped
if [ -n "$FLAGS" ]; then
    run_bounded 60 $FLAGS "$WORK/out/recon.bin" "$NEUTRINO_TEST_ORIGIN/good.cmd"
    RECON=$RUN_RC
fi
[ "$RECON" = "0" ] && ok "the reconstructed argv runs" ||
    bad "reconstruction expected=rc0 actual=$RECON; the four results below could be one broken command line"

SHAPES=""
for shape in declared chunked lying eof; do
    OUT="$WORK/out/$shape.bin"; rm -f "$OUT"
    T0=$(date +%s)
    if [ -n "$FLAGS" ]; then
        run_bounded 90 $FLAGS "$OUT" "$NEUTRINO_TEST_ORIGIN/$shape.cmd"
    else
        RUN_RC=-2
    fi
    T1=$(date +%s)
    SZ=$(bytes_of "$OUT")
    SHAPES="$SHAPES $shape=$RUN_RC/${SZ}b"
    case "$shape" in
        declared)
            # A declared length past the limit is refused before a body starts.
            [ "$SZ" -eq 0 ] && ok "an honest oversized length writes nothing" ||
                bad "declared expected=0b actual=${SZ}b" ;;
        chunked|eof)
            # The half that had never been measured: no length to refuse in
            # advance, so the guard has to bite mid-body. It does, on four curl
            # versions, at exactly the limit.
            [ "$SZ" -le "$LIMIT" ] && [ "$RUN_RC" -ne 0 ] &&
                ok "$shape stops at ${SZ}b, at or under the limit, rc=$RUN_RC" ||
                bad "$shape expected=<=${LIMIT}b-and-refused actual=${SZ}b/rc=$RUN_RC" ;;
        lying)
            # curl takes the header at its word and writes what it was promised.
            # The digest refuses it a moment later.
            [ "$SZ" -eq 1024 ] && ok "a lying length yields the 1024 bytes it declared" ||
                bad "lying expected=1024b actual=${SZ}b" ;;
    esac
done
nt_result "report: fetchbound direct recon=$RECON$SHAPES limit=$LIMIT"

echo "=== Control: the flag is what is doing that ==="
# Without this the four assertions above could pass on a curl that simply never
# writes much, and the flag could be removed tomorrow with the suite still green.
NOMAX="$(printf '%s\n' "$FLAGS" | sed -e 's/--max-filesize  *[0-9]*//' -e 's/  */ /g')"
if [ -n "$FLAGS" ]; then
    rm -f "$WORK/out/nomax.bin"
    run_bounded 90 $NOMAX "$WORK/out/nomax.bin" "$NEUTRINO_TEST_ORIGIN/chunked.cmd"
    NOMAXSZ=$(bytes_of "$WORK/out/nomax.bin")
    [ "$NOMAXSZ" -gt "$LIMIT" ] &&
        ok "with the flag removed the same curl writes ${NOMAXSZ}b, past the limit" ||
        bad "no-flag control expected=>${LIMIT}b actual=${NOMAXSZ}b; the assertions above prove nothing"
else
    NOMAXSZ=0
fi

# ------------------------------------------------ and the verdicts netinstall gives

echo "=== The same four shapes through --fetch ==="
VERDICTS=""
for shape in declared chunked lying eof; do
    SPEC="$shape-example-com-1$NOMATCH"
    run_bounded 150 "$(as "$BIN" "$SPEC")" --fetch
    CACHED=no; [ -f "$(cached_path "$SPEC")" ] && CACHED=YES
    VERDICTS="$VERDICTS $shape=$RUN_RC/$CACHED"
    [ "$RUN_RC" -ne 0 ] && [ "$CACHED" = "no" ] && ok "$shape refused, nothing cached" ||
        bad "$shape expected=refused+nothing-cached actual=rc=$RUN_RC cached=$CACHED"
done
nt_result "report: fetchbound netinstall$VERDICTS nomax=${NOMAXSZ}b"

# ------------------------------------------------------------- the fallback branch

# Every machine this could run on resolves curl, so the branch whose bounds come
# from the kernel is one nothing takes. -DNEUTRINO_FETCH_PREFER_WGET, which
# exists only under NEUTRINO_TESTING, is what reaches it.
echo "=== The fallback branch, where the kernel holds the bounds ==="
WSTATE=skipped
WOUT=""
if [ -z "$WBIN" ] || [ ! -x "$WBIN" ]; then
    WSTATE="SKIP no prefer-wget binary given"
elif [ "$NT_WINDOWS" = "1" ]; then
    # No fork and no setrlimit; nt_fetch there is nt_win_spawn and there is no
    # wget branch compiled at all. A statement, not a silent pass.
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
    # Control first: the branch has to work before its refusals mean anything.
    cp "$SERVE/good.cmd" "$SERVE/wgood.cmd"
    WGOOD="wgood-example-com-1$(nt_pin "$SERVE/wgood.cmd")"
    if "$(as "$WBIN" "$WGOOD")" --fetch >/dev/null 2>&1 && [ -f "$(cached_path "$WGOOD")" ]; then
        ok "the fallback branch fetches and caches a benign payload"
    else
        bad "fallback control expected=fetched+cached actual=no; its refusals below prove nothing"
    fi

    # Size. Before this PR wget wrote every byte offered and netinstall said
    # "fetch failed: <url>"; now the kernel stops it and the message says which.
    WSPEC="chunked-example-com-1$NOMATCH"
    WERR="$WORK/wchunked.err"
    "$(as "$WBIN" "$WSPEC")" --fetch >/dev/null 2>"$WERR"
    WRC=$?
    WMSG="$(tr -d '\r' < "$WERR" | grep -a 'netinstall:' | tail -1)"
    case "$WMSG" in
        *"sent more than"*) ok "the fallback refuses an endless body by size, and says so" ;;
        *) bad "fallback size expected=names-the-size actual='${WMSG:-<none>}' rc=$WRC" ;;
    esac
    [ -f "$(cached_path "$WSPEC")" ] && bad "fallback size expected=nothing-cached actual=cached"
    WOUT=" size=$WRC"

    # Clock. wget's --timeout is per read, so a byte a second satisfies it
    # forever; the alarm is the only total. This waits out a real deadline on
    # purpose -- a shorter one would be a different number than the one shipped.
    WSPEC2="dribble-example-com-1$NOMATCH"
    WERR2="$WORK/wdribble.err"
    T0=$(date +%s)
    RUN_ERR="$WERR2"
    run_bounded $((DEADLINE + 60)) "$(as "$WBIN" "$WSPEC2")" --fetch
    RUN_ERR=""
    T1=$(date +%s)
    WEL=$((T1 - T0))
    if [ "$RUN_ALIVE" = "YES" ]; then
        bad "fallback clock expected=refused-by-${DEADLINE}s actual=still-running at $((DEADLINE + 60))s"
    elif [ "$WEL" -gt $((DEADLINE + 40)) ]; then
        bad "fallback clock expected=~${DEADLINE}s actual=${WEL}s"
    else
        ok "the fallback gives up on an endless dribble after ${WEL}s"
    fi
    if grep -qa 'held the download open' "$WERR2" 2>/dev/null; then
        ok "and says the host held it open rather than blaming the network"
    else
        bad "fallback clock expected=names-the-deadline actual='$(tr -d '\r' < "$WERR2" | grep -a 'netinstall:' | tail -1)'"
    fi
    WOUT="$WOUT clock=${WEL}s"

    # The trap the fix walks into if nobody looks. RLIMIT_FSIZE bounds the file
    # offset, not the write, and applies to every regular file the child holds
    # -- including an inherited stderr. Measured before the guard: rc 153 on all
    # three POSIX lanes, killing the downloader over its own first diagnostic.
    BIGERR="$WORK/bigerr.log"
    dd if=/dev/zero of="$BIGERR" bs=1048576 count=17 2>/dev/null
    cp "$SERVE/good.cmd" "$SERVE/wbig.cmd"
    WGOOD2="wbig-example-com-1$(nt_pin "$SERVE/wbig.cmd")"
    "$(as "$WBIN" "$WGOOD2")" --fetch >/dev/null 2>>"$BIGERR"
    if [ -f "$(cached_path "$WGOOD2")" ]; then
        ok "a fetch whose stderr is already past the limit still succeeds"
        WSTDERR=OK
    else
        bad "stderr guard expected=fetched actual=no; the child was killed by its own diagnostic"
        WSTDERR=KILLED
    fi
    WOUT="$WOUT stderr-at-$(bytes_of "$BIGERR")b=$WSTDERR"
fi
nt_result "report: fetchbound fallback=$WSTATE$WOUT"

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
