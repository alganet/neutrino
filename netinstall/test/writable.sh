#!/bin/bash
# writable.sh - what "writes confined to X" actually means, per platform
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Every platform ends nt_confine with one sentence naming one directory, and
# --info prints it, and a non-strict build prints it on stderr as the warning a
# user actually reads. Every platform then grants writes somewhere else as well:
# /dev, /dev/shm, /proc and $XDG_RUNTIME_DIR on linux; the whole Darwin per-user
# temp dir and four Library subtrees on macOS; /dev and /tmp on OpenBSD; and on
# windows low integrity is not a directory at all. All of it deliberate, all of
# it with a reason in the source, none of it in the sentence.
#
# It enumerates what a confined app can actually put bytes into, from inside the
# confinement, on every lane and in both tiers, and asserts the sentence names
# what it finds. It was a probe for one round; every letter below is now held to
# what that round measured, so a platform that changes its mind in either
# direction is a failure and not a silence.
#
# What it would have caught before the fix, on the lanes that measured it:
# runtime=--O on both linux lanes, in both tiers -- a session runtime directory
# an app could write over but not create in -- against a sentence that named the
# app dir and stopped. And on macOS and OpenBSD, an --info fetch line naming the
# cache root while the confinement was the blobs directory inside it.
#
# Three letters per target, because the mechanisms distinguish three operations
# and the answers differ:
#
#   C  created a file that was not there            (O_CREAT on a new name)
#   T  truncated one that was, through a redirect   (O_CREAT|O_TRUNC, existing)
#   O  wrote one that was, without O_CREAT          (open(2) "r+")
#
# Landlock takes MAKE_REG for the first and WRITE_FILE for the third; unveil is
# documented to count O_CREAT as a create whether or not the file is there,
# which would make T and O different letters on OpenBSD and the same letter on
# linux. No shell can ask the third question, so that half goes through python3
# and says so when there is none. Windows answers C and T from a batch file and
# cannot ask O at all.

set -uo pipefail

BIN="${1:-}"
TIGHT="${2:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: writable.sh <netinstall binary built with -DNEUTRINO_TESTING> [tight binary]" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
[ -n "$TIGHT" ] && [ -x "$TIGHT" ] &&
    TIGHT="$(cd "$(dirname "$TIGHT")" && pwd)/$(basename "$TIGHT")"
. "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
FAKEHOME="$HOME/.netinstall-writable-$$"
mkdir -p "$SERVE" "$WORK/bin" "$FAKEHOME"
export NEUTRINO_HOME="$WORK/home"

FAILURES=0
DROPPED=""
PLANTED=""

# Cleans every file this suite planted, wherever it planted it. The targets are
# shared directories -- /tmp, /dev/shm, the session runtime dir, a user's
# Library -- and leaving probe files in them is not this suite's right.
nt_cleanup() {
    kill ${NT_SERVER_PID:-} 2>/dev/null
    local d
    for d in $PLANTED; do
        rm -f "$d"/nt-w-pre "$d"/nt-w-new-* 2>/dev/null
    done
    rm -rf "$WORK" "$FAKEHOME"
}
trap nt_cleanup EXIT

# =====================================================================
# The targets
# =====================================================================
#
# Each is a directory a confined app might try to write, and each gets a file
# planted in it from out here first, unconfined, so the T and O halves have
# something that already exists to aim at. A target this suite cannot plant into
# is dropped and named rather than reported as denied: "the app could not write
# there" and "nobody can write there" are different claims.

TARGETS=""

add_target() {
    local label="$1" dir="$2"
    [ -n "$dir" ] || { DROPPED="$DROPPED ${label}(unset)"; return 0; }
    case "$dir" in
        *" "*) DROPPED="$DROPPED ${label}(space)"; return 0 ;;
    esac
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
    if [ ! -d "$dir" ]; then
        DROPPED="$DROPPED ${label}(absent)"
        return 0
    fi
    if ! echo pre > "$dir/nt-w-pre" 2>/dev/null; then
        DROPPED="$DROPPED ${label}(unplantable)"
        return 0
    fi
    PLANTED="$PLANTED $dir"
    TARGETS="$TARGETS $label=$dir"
}

if [ "$NT_WINDOWS" = "1" ]; then
    # =================================================================
    # windows: a batch payload, the way privs.sh does it. confine.sh skips
    # this platform entirely, so the tight tier's sentence -- "writes confined
    # to <appdir>" over a mechanism that is a token label and not a directory
    # -- has never been asked anything.
    # =================================================================
    printf '@echo off\r\necho placeholder\r\n' > "$SERVE/writable.cmd"
    SPEC="writable-example-com-1$(nt_pin "$SERVE/writable.cmd")"
    APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
    APPDIR="$("$APP" --info 2>/dev/null | tr -d '\r' | awk '$1 == "appdir" { print $2 }')"

    # LocalLow and the AppDataLow key exist so that low-integrity processes have
    # somewhere to write. If the sentence is false anywhere on this platform it
    # is false there, so they are the two the payload is pointed at.
    W_HOME="$(cygpath -w "$FAKEHOME" 2>/dev/null)"
    W_APPDATA="${LOCALAPPDATA:-}"
    W_USERTEMP="${TEMP:-}"
    W_LOCALLOW="${USERPROFILE:-}\\AppData\\LocalLow"
    W_WINTEMP="C:\\Windows\\Temp"

    plant_w() {
        local label="$1" wpath="$2" upath
        [ -n "$wpath" ] || { DROPPED="$DROPPED ${label}(unset)"; return 1; }
        upath="$(cygpath -u "$wpath" 2>/dev/null)"
        [ -n "$upath" ] || { DROPPED="$DROPPED ${label}(nopath)"; return 1; }
        [ -d "$upath" ] || mkdir -p "$upath" 2>/dev/null
        if [ ! -d "$upath" ] || ! echo pre > "$upath/nt-w-pre" 2>/dev/null; then
            DROPPED="$DROPPED ${label}(unplantable)"
            return 1
        fi
        PLANTED="$PLANTED $upath"
        return 0
    }

    plant_w appdir   "${APPDIR:+$APPDIR\\data}" && TARGETS="$TARGETS appdir="
    plant_w home     "$W_HOME"     && TARGETS="$TARGETS home="
    plant_w usertemp "$W_USERTEMP" && TARGETS="$TARGETS usertemp="
    plant_w locallow "$W_LOCALLOW" && TARGETS="$TARGETS locallow="
    if plant_w wintemp "$W_WINTEMP"; then
        TARGETS="$TARGETS wintemp="
    else
        W_WINTEMP=""
    fi
    # The two keys are not files and nothing has to be planted for them: reg add
    # creates or opens, and either way the answer is whether it succeeded.
    TARGETS="$TARGETS reg= reglow="

    export NEUTRINO_TEST_T_HOME="$W_HOME"
    export NEUTRINO_TEST_T_USERTEMP="$W_USERTEMP"
    export NEUTRINO_TEST_T_LOCALLOW="$W_LOCALLOW"
    export NEUTRINO_TEST_T_WINTEMP="$W_WINTEMP"
    export NEUTRINO_TEST_T_REG="HKCU\\Software\\NeutrinoWritableProbe"
    export NEUTRINO_TEST_T_REGLOW="HKCU\\Software\\AppDataLow\\NeutrinoWritableProbe"

    # A new name per run, from the tag: a create that could not be cleaned up
    # afterwards would otherwise be reported as a create the next run got for
    # free, in the reassuring direction.
    cat > "$SERVE/writable.cmd" <<'BATCH'
@echo off
echo PROBE_BEGIN
echo tag=%NEUTRINO_TEST_TAG%
echo temp=%TEMP%
echo datahome=%XDG_DATA_HOME%
call :try appdir   "%XDG_DATA_HOME%"
call :try home     "%NEUTRINO_TEST_T_HOME%"
call :try usertemp "%NEUTRINO_TEST_T_USERTEMP%"
call :try locallow "%NEUTRINO_TEST_T_LOCALLOW%"
call :try wintemp  "%NEUTRINO_TEST_T_WINTEMP%"
call :reg reg      "%NEUTRINO_TEST_T_REG%"
call :reg reglow   "%NEUTRINO_TEST_T_REGLOW%"
> nul echo x 2>nul
if errorlevel 1 (echo devnull=BLOCKED) else (echo devnull=OK)
echo PROBE_END
goto :eof

:try
set "L=%~1"
set "D=%~2"
set "R=-"
set "T=-"
if "%D%"=="" goto :tryout
> "%D%\nt-w-new-%NEUTRINO_TEST_TAG%" echo new 2>nul
if exist "%D%\nt-w-new-%NEUTRINO_TEST_TAG%" set "R=C"
> "%D%\nt-w-pre" echo trunc-%NEUTRINO_TEST_TAG% 2>nul
findstr /c:"trunc-%NEUTRINO_TEST_TAG%" "%D%\nt-w-pre" >nul 2>&1
if not errorlevel 1 set "T=T"
:tryout
echo w %L% %R%%T%-
goto :eof

:reg
set "L=%~1"
set "K=%~2"
set "R=-"
reg add "%K%" /v tag /t REG_SZ /d "%NEUTRINO_TEST_TAG%" /f >nul 2>&1
if not errorlevel 1 set "R=K"
echo w %L% %R%--
goto :eof
BATCH
    # cmd.exe reads a batch file line by line off disk. A payload written with
    # bare newlines runs on a runner and has surprised this suite before, so the
    # line endings are made explicit rather than inherited from the shell.
    "$(nt_python)" - "$SERVE/writable.cmd" <<'PY'
import sys
p = sys.argv[1]
data = open(p, 'rb').read().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
open(p, 'wb').write(data)
PY
else
    # =================================================================
    # posix
    # =================================================================
    cat > "$SERVE/writable.cmd" <<'SCRIPT'
echo "PROBE_BEGIN"
echo "tag=${NEUTRINO_TEST_TAG:-none}"
echo "tmpdir=${TMPDIR:-<unset>}"
echo "runtime=${XDG_RUNTIME_DIR:-<unset>}"
nt_py=""
for c in /usr/bin/python3 /usr/local/bin/python3 /usr/pkg/bin/python3 \
         /opt/homebrew/bin/python3 /usr/bin/python; do
    [ -x "$c" ] && { nt_py="$c"; break; }
done
echo "py=${nt_py:-none}"
for t in $NEUTRINO_TEST_TARGETS; do
    label="${t%%=*}"
    dir="${t#*=}"
    r="-"; u="-"; o="-"
    new="$dir/nt-w-new-${NEUTRINO_TEST_TAG:-x}"
    pre="$dir/nt-w-pre"
    if echo new > "$new" 2>/dev/null; then
        r="C"
        rm -f "$new" 2>/dev/null
    fi
    if echo "trunc-${NEUTRINO_TEST_TAG:-x}" > "$pre" 2>/dev/null; then u="T"; fi
    # The one operation no shell can express: O_RDWR without O_CREAT, on a file
    # that is already there. It is the whole question for a WRITE_FILE grant
    # that carries no MAKE_REG with it.
    #
    # Which makes the interpreter part of the apparatus: with no python the O is
    # a dash on every target at every tier, and that is a full set of denials
    # this suite never made. Measured on the netbsd lane, where pkgsrc puts
    # python under /usr/pkg and the list above did not have it: eleven failures,
    # `py=none`, and the unconfined control refusing to certify any of it --
    # which is the control doing exactly its job.
    if [ -n "$nt_py" ] && "$nt_py" -c 'import sys
f = open(sys.argv[1], "r+")
f.write("o")
f.close()' "$pre" 2>/dev/null; then o="O"; fi
    echo "w $label $r$u$o"
done
# Not a target and not a letter: /dev/null is a file, not a directory, and it
# is the one write outside the app dir that every shell payload here depends on
# -- OpenBSD unveils /dev "rwc" for exactly this reason, and confine.sh's own
# probes all end in one. A narrowing that took it away would be read as thirteen
# unrelated denials, which is what happened to this tree once already.
if echo x > /dev/null 2>/dev/null; then echo "devnull=OK"; else echo "devnull=BLOCKED"; fi
echo "PROBE_END"
SCRIPT
    SPEC="writable-example-com-1$(nt_pin "$SERVE/writable.cmd")"
    APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
    APPDIR="$("$APP" --info 2>/dev/null | awk '$1 == "appdir" { print $2 }')"

    # A runtime directory this suite owns, so the grant is exercised against a
    # directory whose contents are known. The runner's own is recorded, because
    # replacing it is a thing the reading has to be read against.
    #
    # Under the fake $HOME rather than under $WORK, and that is not tidiness:
    # $WORK is a mktemp directory, which is under /tmp, which OpenBSD unveils
    # "rw" for its own reasons. A runtime dir there would read as writable
    # because of the /tmp rule and be recorded as the runtime grant. Under
    # $HOME it is a path no platform grants anything to except the one rule
    # under test -- and the home target beside it is the control that says so.
    HAD_RUNTIME="${XDG_RUNTIME_DIR:-<unset>}"
    export XDG_RUNTIME_DIR="$FAKEHOME/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"

    add_target appdir "$APPDIR/data"
    add_target home   "$FAKEHOME"
    add_target tmp    "/tmp"
    add_target runtime "$XDG_RUNTIME_DIR"
    case "$(uname -s)" in
        Linux)
            add_target shm "/dev/shm"
            # TMPDIR is redirected into the app dir here, so this is expected
            # to read the same as appdir. Asked anyway: it is the claim.
            add_target tmpdir "$APPDIR/tmp" ;;
        Darwin)
            # The one platform where TMPDIR is deliberately not redirected, so
            # $TMPDIR is the per-user Darwin temp dir -- shared with every other
            # process this user is running, and granted wholesale by the profile
            # as /private/var/folders.
            add_target tmpdir "${TMPDIR:-/tmp}"
            add_target darwin "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
            add_target libcache "$HOME/Library/Caches"
            add_target libprefs "$HOME/Library/Preferences" ;;
        *)
            add_target tmpdir "$APPDIR/tmp" ;;
    esac
    export NEUTRINO_TEST_TARGETS="${TARGETS# }"
fi

nt_serve "$SERVE" || exit 2
SPEC="writable-example-com-1$(nt_pin "$SERVE/writable.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
APP_TIGHT=""
[ -n "$TIGHT" ] && [ -x "$TIGHT" ] && APP_TIGHT="$(nt_as "$TIGHT" "$SPEC" "$WORK/tbin")"

# =====================================================================
# The three runs
# =====================================================================
say_confine() {
    "$1" --info 2>/dev/null | tr -d '\r' |
        awk -v k="$2" '$1 == k { $1 = ""; sub(/^ +/, ""); print }'
}

OUT_DEFAULT="$(env NEUTRINO_TEST_TAG=default "$APP" 2>"$WORK/err.default")"
SAYS_DEFAULT="$(say_confine "$APP" confine)"
SAYS_FETCH_DEFAULT="$(say_confine "$APP" fetch)"

OUT_TIGHT=""
SAYS_TIGHT="(no tight binary)"
SAYS_FETCH_TIGHT="(no tight binary)"
if [ -n "$APP_TIGHT" ]; then
    OUT_TIGHT="$(env NEUTRINO_TEST_TAG=tight "$APP_TIGHT" 2>"$WORK/err.tight")"
    SAYS_TIGHT="$(say_confine "$APP_TIGHT" confine)"
    SAYS_FETCH_TIGHT="$(say_confine "$APP_TIGHT" fetch)"
fi

# The control, and ground rule 3: an instrument that writes nowhere reports a
# perfectly confined app on a platform that confines nothing.
OUT_NOCONF="$(env NEUTRINO_TEST_TAG=noconf NEUTRINO_TEST_NO_CONFINE=1 "$APP" 2>/dev/null)"

echo "=== What the sentence says ==="
echo "  default confine: $SAYS_DEFAULT"
echo "  default fetch:   $SAYS_FETCH_DEFAULT"
echo "  tight confine:   $SAYS_TIGHT"
echo "  tight fetch:     $SAYS_FETCH_TIGHT"

# =====================================================================
# Reading the three runs
# =====================================================================
letters() {
    local out="$1" label="$2" v
    v="$(printf '%s\n' "$out" | tr -d '\r' | awk -v l="$label" '$1 == "w" && $2 == l { print $3 }' | tail -1)"
    echo "${v:-??}"
}

labels_of() {
    local t
    for t in $TARGETS; do
        printf '%s ' "${t%%=*}"
    done
    echo
}

set_of() {
    local out="$1" l s=""
    for l in $(labels_of); do
        s="$s $l=$(letters "$out" "$l")"
    done
    echo "${s# }"
}

SET_DEFAULT="$(set_of "$OUT_DEFAULT")"
SET_TIGHT="$(set_of "$OUT_TIGHT")"
SET_NOCONF="$(set_of "$OUT_NOCONF")"

echo "=== What is writable, per tier ==="
echo "  default:    $SET_DEFAULT"
echo "  tight:      $SET_TIGHT"
echo "  unconfined: $SET_NOCONF"

# =====================================================================
# Controls. Everything above is a reading; these four are the assertions.
# =====================================================================
ran() {
    case "$1" in
        *PROBE_END*) return 0 ;;
        *) return 1 ;;
    esac
}

echo "=== Controls ==="
for pair in "default:$OUT_DEFAULT" "noconf:$OUT_NOCONF"; do
    tag="${pair%%:*}"
    if ran "${pair#*:}"; then
        echo "  PASS: the $tag payload ran to the end"
    else
        nt_fail "the $tag payload did not finish: $(printf '%s' "${pair#*:}" | tr '\n' ' ' | cut -c1-160)"
        FAILURES=$((FAILURES + 1))
    fi
done
if [ -n "$APP_TIGHT" ]; then
    if ran "$OUT_TIGHT"; then
        echo "  PASS: the tight payload ran to the end"
    else
        # Not fatal on windows: low integrity stopping the payload before it
        # answers is itself the finding there, and a blank column that says why
        # beats a failure that says nothing.
        if [ "$NT_WINDOWS" = "1" ]; then
            nt_result "report: writable windows tight payload produced no PROBE_END: $(printf '%s' "$OUT_TIGHT" | tr '\n' ' ' | cut -c1-120) err=$(tr '\n' ' ' < "$WORK/err.tight" | cut -c1-120)"
        else
            nt_fail "the tight payload did not finish: $(printf '%s' "$OUT_TIGHT" | tr '\n' ' ' | cut -c1-160)"
            FAILURES=$((FAILURES + 1))
        fi
    fi
fi

# The write every payload in this suite depends on, in every state. A tier that
# lost it would fail a dozen probes elsewhere for a reason none of them names.
DEVNULL=""
for pair in default tight noconf; do
    case "$pair" in
        default) out="$OUT_DEFAULT" ;;
        tight)   out="$OUT_TIGHT"; [ -n "$APP_TIGHT" ] || continue ;;
        noconf)  out="$OUT_NOCONF" ;;
    esac
    ran "$out" || continue
    v="$(printf '%s\n' "$out" | tr -d '\r' | sed -n 's/^devnull=//p' | tail -1)"
    DEVNULL="$DEVNULL $pair=${v:-??}"
    if [ "$v" = "OK" ]; then
        echo "  PASS: $pair tier can still write /dev/null"
    else
        nt_fail "$pair tier /dev/null expected=OK actual=${v:-<absent>}"
        FAILURES=$((FAILURES + 1))
    fi
done

# The unconfined control has to reach every target, or the letters above are
# measuring the instrument rather than the confinement.
BAD=""
for l in $(labels_of); do
    v="$(letters "$OUT_NOCONF" "$l")"
    case "$l" in
        reg|reglow) want="K--" ;;
        *) [ "$NT_WINDOWS" = "1" ] && want="CT-" || want="CTO" ;;
    esac
    [ "$v" = "$want" ] || BAD="$BAD $l=$v(want $want)"
done
if [ -z "$BAD" ]; then
    echo "  PASS: an unconfined payload reaches every target"
else
    nt_fail "unconfined control could not reach:$BAD"
    FAILURES=$((FAILURES + 1))
fi

# And the two the whole design rests on, in every tier that applied something.
confines_writes() {
    [ -n "$1" ] || return 1
    case "$1" in
        none*|*"no filesystem confinement"*) return 1 ;;
    esac
    return 0
}

check_tier() {
    local tier="$1" set_str="$2" says="$3"

    case " $set_str " in
        *" appdir=CT"*) echo "  PASS: $tier tier keeps its own dir writable" ;;
        *)
            nt_fail "$tier tier app dir expected=writable actual=$(printf '%s' "$set_str" | grep -o 'appdir=[A-Z?-]*')"
            FAILURES=$((FAILURES + 1)) ;;
    esac
    # A platform that applied nothing is not a platform that failed to confine:
    # it is the one whose sentence is already true, and the letters above are
    # the unconfined answer read twice. Read off the sentence rather than off a
    # list of platforms, because the sentence is what this suite is about --
    # windows says "no filesystem confinement on windows" in its default tier
    # and FreeBSD says "none", and both mean it.
    if ! confines_writes "$says"; then
        nt_note "$tier tier confines no writes here ($says); the letters above are that, not a failure"
        return 0
    fi
    case " $set_str " in
        *" home=--- "*) echo "  PASS: $tier tier still refuses a directory outside the app dir" ;;
        *)
            nt_fail "$tier tier outside-write expected=home=--- actual=$(printf '%s' "$set_str" | grep -o 'home=[A-Z?-]*')"
            FAILURES=$((FAILURES + 1)) ;;
    esac
}

ran "$OUT_DEFAULT" && check_tier default "$SET_DEFAULT" "$SAYS_DEFAULT"
[ -n "$APP_TIGHT" ] && ran "$OUT_TIGHT" && check_tier tight "$SET_TIGHT" "$SAYS_TIGHT"

# =====================================================================
# What each platform is held to
# =====================================================================
#
# Read off round 1, which measured all six lanes with the runtime-dir grant
# still in place. The only letter that changes here is that one: linux read
# runtime=--O then and reads runtime=--- now. Everything else is a platform
# fact, asserted so that a kernel, an OS minor or an edit to a profile that
# moves it says so out loud.
case "$(uname -s)" in
    Linux)
        # /dev/shm takes the full write set and is in the sentence; the session
        # runtime dir takes nothing at all, which is this PR; tmpdir is inside
        # the app dir because TMPDIR is redirected here.
        WANT_DEFAULT="appdir=CTO home=--- tmp=--- runtime=--- shm=CTO tmpdir=CTO"
        WANT_TIGHT="$WANT_DEFAULT"
        # One sentence now, because there is one rule. The default build used
        # to say "every process's /proc entry" and mean it; the grant is
        # /proc/self on every build, so this is the line that would have failed
        # before the narrowing landed.
        SAY_DEFAULT=", /dev, /dev/shm and /proc/self"
        SAY_TIGHT="$SAY_DEFAULT" ;;
    Darwin)
        # Four writable trees outside the app dir, in both tiers, every one of
        # them load-bearing: the Darwin per-user temp dir under two names
        # because TMPDIR is deliberately not redirected here, and the two
        # Library subtrees CFPreferences and WebKit write on every launch.
        WANT_DEFAULT="appdir=CTO home=--- tmp=--- runtime=--- tmpdir=CTO darwin=CTO libcache=CTO libprefs=CTO"
        WANT_TIGHT="$WANT_DEFAULT"
        SAY_DEFAULT="/private/var/folders"
        SAY_TIGHT="/private/var/folders" ;;
    OpenBSD)
        # tmp=--O is unveil "rw" without a "c", measured for the first time in
        # round 1 and matching what this tree has claimed since PR 11: an
        # existing file written, and neither created nor truncated, because
        # unveil counts O_CREAT as a create either way.
        WANT_DEFAULT="appdir=CTO home=--- tmp=--O runtime=--- tmpdir=CTO"
        WANT_TIGHT="$WANT_DEFAULT"
        SAY_DEFAULT="plus files that already exist under /tmp"
        SAY_TIGHT="plus files that already exist under /tmp" ;;
    FreeBSD|NetBSD|DragonFly)
        # These are not OpenBSD and they were grouped with it for as long as
        # this arm has existed -- written from unveil's answer, on two platforms
        # that have no unveil. sandbox_bsd.c returns -1 here and says so, and
        # every letter below is the unconfined set read a second time. Measured
        # on the freebsd lane: default, tight and unconfined are the same five
        # letters, `dropped=[]`.
        #
        # That is not a gap being papered over -- it is ground rule 6. The day
        # one of these grows something unprivileged, this goes red and names
        # which letter moved, which is the whole reason to assert a platform's
        # ceiling rather than skip it.
        #
        # DragonFly has never run: it is here because sandbox_bsd.c does not
        # compile for it at all -- the file's own #if names three systems and
        # DragonFly is not one, so it links sandbox_none.c, whose sentence has
        # this shape. Reasoned from the source, and said so rather than left to
        # look measured.
        WANT_DEFAULT="appdir=CTO home=CTO tmp=CTO runtime=CTO tmpdir=CTO"
        WANT_TIGHT="$WANT_DEFAULT"
        SAY_DEFAULT="none (no unprivileged confinement"
        SAY_TIGHT="none (no unprivileged confinement" ;;
    *)
        # Both rows are the same row now, and that is the assertion.
        #
        # This arm used to hold the default tier to the unconfined control --
        # appdir=CT- home=CT- usertemp=CT- wintemp=CT- reg=K--, every letter
        # identical to no confinement at all -- because windows had no
        # filesystem confinement outside the tight tier. Low integrity is the
        # tier now, so the default binary has to measure what the tight one
        # measured, and the two places the Low label leaves open by design are
        # still not the app dir.
        #
        # Written as one value used twice rather than two equal literals: if
        # they ever diverge again it is because somebody put a tier back, and
        # this should not be the file that quietly permits it.
        WANT_DEFAULT="appdir=CT- home=--- usertemp=--- locallow=CT- wintemp=--- reg=--- reglow=K--"
        WANT_TIGHT="$WANT_DEFAULT"
        SAY_DEFAULT="LocalLow"
        SAY_TIGHT="LocalLow" ;;
esac

expect_set() {
    local tier="$1" out="$2" want="$3" pair l w v labels
    labels=" $(labels_of) "

    for pair in $want; do
        l="${pair%%=*}"
        w="${pair#*=}"
        case "$labels" in
            *" $l "*) ;;
            # A target this lane could not plant into is named, not scored. The
            # dropped list in the report says why.
            *) nt_note "$tier: $l is not a target on this lane"; continue ;;
        esac
        v="$(letters "$out" "$l")"
        if [ "$v" = "$w" ]; then
            echo "  PASS: $tier $l=$v"
        else
            nt_fail "$tier $l expected=$w actual=$v"
            FAILURES=$((FAILURES + 1))
        fi
    done
}

says_names() {
    local tier="$1" says="$2" needle="$3"

    case "$says" in
        *"$needle"*) echo "  PASS: the $tier sentence names $needle" ;;
        *)
            nt_fail "$tier sentence expected to name '$needle' actual='$says'"
            FAILURES=$((FAILURES + 1)) ;;
    esac
}

echo "=== Every letter, held to what it measured ==="
ran "$OUT_DEFAULT" && expect_set default "$OUT_DEFAULT" "$WANT_DEFAULT"
if [ -n "$APP_TIGHT" ] && ran "$OUT_TIGHT"; then
    expect_set tight "$OUT_TIGHT" "$WANT_TIGHT"
fi

# The sentence is not only read by people. confine.sh keys its /proc
# assertions on which tier the binary is, and confine-strict.sh decides whether
# to run its battery at all, and both ask the same question the only way it can
# be asked: by reading this line. Rewording it in this PR made confine-strict.sh
# skip everything it asserts and exit 0 -- a green tick for a suite that
# measured nothing, which is ground rule 3 happening to the suite instead of to
# the payload. So the coupling is asserted here rather than left to be
# rediscovered.
#
# Only where there is a tier to recognise. OpenBSD builds the tight binary and
# gets the same confinement out of it -- unveil is an allowlist already, so the
# default tier is the tight one, and the two sentences are identical by
# construction. confine-strict.sh skips there for exactly that reason and says
# so. Asserting a distinguishable tight sentence on that lane would fail it for
# a tier it does not have, which is the assertion being wrong rather than the
# platform.
echo "=== The sentence is still one the suite can read the tier off ==="
if [ -n "$APP_TIGHT" ] && ran "$OUT_TIGHT" && [ "$SAYS_TIGHT" = "$SAYS_DEFAULT" ]; then
    nt_note "no tight tier here: both binaries describe the same confinement ($SAYS_TIGHT)"
elif [ -n "$APP_TIGHT" ] && ran "$OUT_TIGHT"; then
    if nt_tight_tier "$SAYS_TIGHT"; then
        echo "  PASS: nt_tight_tier recognises the tight sentence"
    else
        nt_fail "nt_tight_tier no longer recognises the tight tier from '$SAYS_TIGHT'; confine-strict.sh will skip its whole battery and pass"
        FAILURES=$((FAILURES + 1))
    fi
    if nt_tight_tier "$SAYS_DEFAULT"; then
        nt_fail "nt_tight_tier reads the default tier as tight from '$SAYS_DEFAULT'; confine.sh will hold it to the other tier's answers"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: and does not mistake the default sentence for it"
    fi
fi

echo "=== And the sentence names the set rather than the first of it ==="
says_names default "$SAYS_DEFAULT" "$SAY_DEFAULT"
[ -n "$APP_TIGHT" ] && says_names tight "$SAYS_TIGHT" "$SAY_TIGHT"

# The fetch line, and both halves of what round 1 found wrong with it on macOS
# and OpenBSD: it named the cache root rather than the blobs directory inside
# it, and a tight build claimed reads were confined by a profile that confines
# none. Asserted on every lane, because the defect was a description written
# somewhere other than where the confinement is applied and that shape can
# come back anywhere.
#
# Except where the fetch phase confines nothing, which is windows and now
# FreeBSD and NetBSD: there is no directory to name, and a sentence that named
# one would be the lie this assertion exists to catch. Keyed on the sentence
# rather than on a list of platforms, for the same reason check_tier above is.
case "$SAYS_FETCH_DEFAULT" in
    none*|"no filesystem confinement"*) NT_FETCH_NAMES_A_DIR=0 ;;
    *)                                  NT_FETCH_NAMES_A_DIR=1 ;;
esac
if [ "$NT_WINDOWS" != "1" ] && [ "$NT_FETCH_NAMES_A_DIR" = "1" ]; then
    says_names "fetch default" "$SAYS_FETCH_DEFAULT" "blobs"
    [ -n "$APP_TIGHT" ] && says_names "fetch tight" "$SAYS_FETCH_TIGHT" "blobs"
elif [ "$NT_WINDOWS" != "1" ]; then
    nt_note "the fetch phase confines nothing here ($SAYS_FETCH_DEFAULT); there is no directory for it to name"
fi
for pair in "fetch default:$SAYS_FETCH_DEFAULT" "fetch tight:$SAYS_FETCH_TIGHT"; do
    case "${pair#*:}" in
        *"reads and writes confined to"*)
            nt_fail "${pair%%:*} claims reads are confined: '${pair#*:}'"
            FAILURES=$((FAILURES + 1)) ;;
        *) echo "  PASS: the ${pair%%:*} sentence makes no read claim it cannot keep" ;;
    esac
done

# =====================================================================
# The reading, out through the one channel that leaves CI without a token.
# =====================================================================
os="$(uname -s)"
if [ "$NT_WINDOWS" = "1" ]; then
    TEMP_SEEN="$(printf '%s\n' "$OUT_DEFAULT" | tr -d '\r' | sed -n 's/^temp=//p' | tail -1)"
    TEMP_TIGHT="$(printf '%s\n' "$OUT_TIGHT" | tr -d '\r' | sed -n 's/^temp=//p' | tail -1)"
    nt_result "report: writable os=$os default=[$SET_DEFAULT]"
    nt_result "report: writable os=$os tight=[$SET_TIGHT]"
    nt_result "report: writable os=$os unconfined=[$SET_NOCONF] dropped=[${DROPPED# }]"
    nt_result "report: writable os=$os temp default='$TEMP_SEEN' tight='$TEMP_TIGHT' locallow='$W_LOCALLOW' devnull=[${DEVNULL# }]"
else
    PY_SEEN="$(printf '%s\n' "$OUT_DEFAULT" | sed -n 's/^py=//p' | tail -1)"
    TMP_SEEN="$(printf '%s\n' "$OUT_DEFAULT" | sed -n 's/^tmpdir=//p' | tail -1)"
    RT_SEEN="$(printf '%s\n' "$OUT_DEFAULT" | sed -n 's/^runtime=//p' | tail -1)"
    nt_result "report: writable os=$os default=[$SET_DEFAULT]"
    nt_result "report: writable os=$os tight=[$SET_TIGHT]"
    nt_result "report: writable os=$os unconfined=[$SET_NOCONF] dropped=[${DROPPED# }]"
    nt_result "report: writable os=$os py=$PY_SEEN tmpdir=$TMP_SEEN runtime=$RT_SEEN had-runtime=$HAD_RUNTIME devnull=[${DEVNULL# }]"
fi
nt_result "report: writable says default(${#SAYS_DEFAULT})='$SAYS_DEFAULT'"
nt_result "report: writable says tight(${#SAYS_TIGHT})='$SAYS_TIGHT'"
nt_result "report: writable says fetch default='$SAYS_FETCH_DEFAULT' tight='$SAYS_FETCH_TIGHT'"

if [ "$NT_WINDOWS" = "1" ]; then
    reg delete "HKCU\\Software\\NeutrinoWritableProbe" /f >/dev/null 2>&1
    reg delete "HKCU\\Software\\AppDataLow\\NeutrinoWritableProbe" /f >/dev/null 2>&1
fi

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
