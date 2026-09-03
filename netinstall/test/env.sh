#!/bin/bash
# env.sh - what the environment allowlist admits, and what a loader does with it
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# env.c passes whole namespaces by prefix -- GTK_, GDK_, GSETTINGS_, QT_,
# QTWEBENGINE_, WEBKIT_, LIBGL_, MESA_, EGL_, VK_, XDG_ -- and says of them:
#
#     Nothing here can name a file that gets loaded into another process:
#     LD_*, DYLD_* and GIO_MODULE_DIR are absent by construction.
#
# Those three are indeed absent. The claim about the rest is what this suite is
# here to measure, because every one of those namespaces contains at least one
# name whose value is a path the toolkit opens and runs: GTK_MODULES,
# GDK_PIXBUF_MODULE_FILE, QT_PLUGIN_PATH, QTWEBENGINE_PROCESS_PATH,
# WEBKIT_INJECTED_BUNDLE_PATH, WEBKIT_EXEC_PATH, LIBGL_DRIVERS_PATH,
# VK_LAYER_PATH -- and QTWEBENGINE_CHROMIUM_FLAGS, which is appended to
# Chromium's argv by Qt itself and can carry --renderer-cmd-prefix.
#
# Three questions, in the order a fix needs them answered:
#
#   reach   which of those names survive the scrub as shipped
#   effect  whether a surviving name actually loads code, measured against a
#           module that says so, and whether the confinement stops it anyway
#   cost    whether the app still comes up on this lane with the whole
#           candidate deny set removed from the environment first
#
# Nothing here changes production code. What is asserted is only the three
# claims env.c already makes -- LD_*, DYLD_*, GIO_MODULE_DIR -- plus the probe's
# own controls, so a lane that measures the door wide open is still green and
# the reading is in the results rather than in an exit code.

set -uo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "usage: env.sh <netinstall built with -DNEUTRINO_TESTING> [tight binary]" >&2
    exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
# The tight binary, optional and only used for the module half: whether the
# tier that answers EXEC_BLOCKED to an execve also has anything to say about a
# library being mapped decides whether denying the names is the only defence
# there is, or merely the first one.
BIN_TIGHT="${2:-}"
[ -n "$BIN_TIGHT" ] && [ -x "$BIN_TIGHT" ] &&
    BIN_TIGHT="$(cd "$(dirname "$BIN_TIGHT")" && pwd)/$(basename "$BIN_TIGHT")"
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ "$NT_WINDOWS" = "1" ]; then
    # Same reason confine.sh skips here: the payload is sh and windows launches
    # through cmd.exe. The windows half of the reach question is in privs.sh,
    # which already has a batch payload running under the real launcher.
    echo "=== SKIP: sh payloads do not run here; see privs.sh for the windows reach ==="
    exit 0
fi

WORK="$(mktemp -d)"
SERVE="$WORK/serve"
mkdir -p "$SERVE" "$WORK/bin" "$WORK/bin-tight" "$WORK/mod" "$WORK/marks"
export NEUTRINO_HOME="$WORK/home"

FAILURES=0
UNAME="$(uname -s)"

# =====================================================================
# The battery
# =====================================================================
#
# Every name a toolkit reads as "open this file" or "do not sandbox", grouped by
# the prefix that admits it, plus the three env.c claims are absent and two
# controls. Values are deliberately inert: a nonexistent path, or the literal 1
# for the toggles. Nothing here is loaded during the reach run -- the payload is
# sh, which reads none of it -- so the values only have to be distinguishable
# from unset.
# Every name that answers "which file should I load", "which program should I
# run" or "should I sandbox myself" inside an admitted namespace. All of these
# reached the payload before this PR; all of them are asserted gone now.
NT_LOADERS="
GTK_MODULES GTK_PATH GTK_EXE_PREFIX GTK_DATA_PREFIX GTK_IM_MODULE GTK_IM_MODULE_FILE
GDK_PIXBUF_MODULE_FILE GDK_PIXBUF_MODULEDIR
QT_PLUGIN_PATH QT_QPA_PLATFORM_PLUGIN_PATH QT_IM_MODULE
QTWEBENGINE_CHROMIUM_FLAGS QTWEBENGINE_PROCESS_PATH QTWEBENGINE_RESOURCES_PATH
QTWEBENGINE_DISABLE_SANDBOX
WEBKIT_INJECTED_BUNDLE_PATH WEBKIT_EXEC_PATH WEBKIT_FORCE_SANDBOX
WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS
LIBGL_DRIVERS_PATH MESA_LOADER_DRIVER_OVERRIDE
VK_LAYER_PATH VK_ADD_LAYER_PATH VK_ICD_FILENAMES VK_DRIVER_FILES VK_INSTANCE_LAYERS
"

# The other half of the same fix, and the reason this is not just a shorter
# allowlist: a rule that denied the namespaces outright would pass every
# assertion above and take the display, the platform plugin and the locale with
# it. These are prefix-admitted names that carry data or a mode rather than a
# file, and each one has to still arrive.
NT_KEEPERS="
GDK_BACKEND GTK_THEME GSETTINGS_BACKEND GSETTINGS_SCHEMA_DIR
QT_QPA_PLATFORM QT_SCALE_FACTOR EGL_PLATFORM LIBGL_ALWAYS_SOFTWARE
XDG_DATA_DIRS XDG_CONFIG_DIRS XDG_RUNTIME_DIR
"

# What env.c said was absent by construction, and still is.
NT_CLAIMS="LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH GIO_MODULE_DIR"

NT_BATTERY="$NT_LOADERS $NT_KEEPERS $NT_CLAIMS
NEUTRINO_ENV_CONTROL_KEPT NT_ENV_CONTROL_DROPPED
"
NT_LOADERS="$(tr -s ' \n' ' ' <<<"$NT_LOADERS" | sed 's/^ //; s/ $//')"
NT_KEEPERS="$(tr -s ' \n' ' ' <<<"$NT_KEEPERS" | sed 's/^ //; s/ $//')"
NT_BATTERY="$(tr -s ' \n' ' ' <<<"$NT_BATTERY" | sed 's/^ //; s/ $//')"

# =====================================================================
# The instrument: a module that says it was loaded
# =====================================================================
#
# A knob that names a file is only interesting if opening the file runs
# something. env-module.c has a constructor, so the tag appears the moment the
# loader opens it -- before any entry point a toolkit looks for, which is the
# distinction between "this knob loads code" and "this knob names a module that
# was then rejected".
NT_MODEXT=".so"
NT_MODFLAGS=(-shared -fPIC)
if [ "$UNAME" = "Darwin" ]; then
    NT_MODEXT=".dylib"
    NT_MODFLAGS=(-dynamiclib)
fi
NT_CC="${NETINSTALL_CC:-cc}"
NT_MOD_BUILT=0
nt_build_module() {
    local tag="$1"
    local out="$WORK/mod/$tag$NT_MODEXT"
    $NT_CC "${NT_MODFLAGS[@]}" -DNT_MOD_TAG="\"$tag\"" \
        -o "$out" "$ROOT/netinstall/test/env-module.c" >/dev/null 2>&1 || return 1
    [ -s "$out" ]
}
if command -v "$NT_CC" >/dev/null 2>&1 && nt_build_module dlopen; then
    NT_MOD_BUILT=1
fi
NT_MOD="$WORK/mod/dlopen$NT_MODEXT"

# Built as an argv for env(1) rather than exported, so LD_PRELOAD and friends
# apply to the process under test and not to every helper this suite runs.
#
# DYLD_INSERT_LIBRARIES is the one name whose *value* can take the measurement
# down. dyld terminates any process that is not SIP-restricted when an inserted
# dylib fails to load, and it resolves the insert through DYLD_LIBRARY_PATH
# first -- which this battery deliberately points at a directory that does not
# exist. Round 1 pointed it at a nonexistent file and killed netinstall before
# main; round 2 pointed it at a dylib that does exist and dyld went looking for
# the leaf name under the bogus search path instead and killed it again.
#
# So the value is empty. dyld splits it on ':', finds no entries, and inserts
# nothing, while the name is still *set* as far as the payload's test is
# concerned -- and the name is the whole question, because nt_env_keep never
# looks at a value.
NT_SET=()
for n in $NT_BATTERY; do
    case "$n" in
        NT_ENV_CONTROL_DROPPED)  NT_SET+=("$n=dropped-control") ;;
        NEUTRINO_ENV_CONTROL_KEPT) NT_SET+=("$n=kept-control") ;;
        DYLD_INSERT_LIBRARIES)   NT_SET+=("$n=") ;;
        *SANDBOX*|GDK_BACKEND|GTK_THEME|QT_QPA_PLATFORM|QT_SCALE_FACTOR|\
        EGL_PLATFORM|LIBGL_ALWAYS_SOFTWARE|*_IM_MODULE)
            NT_SET+=("$n=1") ;;
        *) NT_SET+=("$n=/nonexistent/neutrino-env-probe") ;;
    esac
done

# =====================================================================
# The reach payload
# =====================================================================
#
# It reports three things: which battery names arrived, the whole set of names
# that did arrive (so the cost of a rule can be read off a real desktop session
# rather than guessed), and whether a module can be loaded from inside the
# sandbox at all.
cat > "$SERVE/envprobe.cmd" <<'SCRIPT'
for n in $NEUTRINO_TEST_BATTERY; do
    eval "seen=\${$n+set}"
    if [ "${seen:-}" = set ]; then echo "env $n SEEN"; else echo "env $n GONE"; fi
done
echo "admitted: $(env | sed 's/=.*//' | sort | tr '\n' ' ')"

# dlopen, twice: from the one directory this process may write to, and from
# where the harness left the file. The first is what an app that has already
# been handed a knob would do with it; the second is what an inherited knob
# pointing anywhere readable would do. Landlock's EXECUTE right mediates
# execve, and whether it says anything about mapping a library is exactly the
# question -- the tight tier answers EXEC_BLOCKED to the execve form.
mod="${NEUTRINO_TEST_MODULE:-}"
mark="$XDG_DATA_HOME/marks"
mkdir -p "$mark" 2>/dev/null
if [ -z "$mod" ]; then
    echo "DLOPEN_SKIP_NOMODULE"
elif ! command -v python3 >/dev/null 2>&1; then
    echo "DLOPEN_SKIP_NOPYTHON"
else
    own="$XDG_DATA_HOME/probe-module${NEUTRINO_TEST_MODEXT}"
    # Said out loud, because the tight tier cannot read the harness's copy to
    # make one of its own and would otherwise be loading a file whose
    # provenance is not in the output.
    if [ -e "$own" ]; then echo "MODPRESENT_PRE"; else echo "MODPRESENT_ABSENT"; fi
    if cp "$mod" "$own" 2>/dev/null; then echo "MODCOPY_OK"; else echo "MODCOPY_BLOCKED"; fi
    rm -f "$mark/dlopen"
    if NEUTRINO_TEST_MODULE_MARKDIR="$mark" python3 -c \
        'import ctypes,sys; ctypes.CDLL(sys.argv[1])' "$own" 2>/dev/null
    then echo "DLOPEN_OWNDIR_OK"; else echo "DLOPEN_OWNDIR_BLOCKED"; fi
    if [ -e "$mark/dlopen" ]; then echo "MODCTOR_OWNDIR_RAN"; else echo "MODCTOR_OWNDIR_SILENT"; fi
    rm -f "$mark/dlopen"
    if NEUTRINO_TEST_MODULE_MARKDIR="$mark" python3 -c \
        'import ctypes,sys; ctypes.CDLL(sys.argv[1])' "$mod" 2>/dev/null
    then echo "DLOPEN_OUTSIDE_OK"; else echo "DLOPEN_OUTSIDE_BLOCKED"; fi
    if [ -e "$mark/dlopen" ]; then echo "MODCTOR_OUTSIDE_RAN"; else echo "MODCTOR_OUTSIDE_SILENT"; fi
    # And from under $HOME, which is neither the app dir nor the temp dir the
    # macOS profile allows by design.
    rm -f "$mark/dlopen"
    if [ -z "${NEUTRINO_TEST_MODULE_HOME:-}" ]; then
        echo "DLOPEN_HOME_SKIP"
    elif NEUTRINO_TEST_MODULE_MARKDIR="$mark" python3 -c \
        'import ctypes,sys; ctypes.CDLL(sys.argv[1])' "$NEUTRINO_TEST_MODULE_HOME" 2>/dev/null
    then echo "DLOPEN_HOME_OK"; else echo "DLOPEN_HOME_BLOCKED"; fi
    if [ -e "$mark/dlopen" ]; then echo "MODCTOR_HOME_RAN"; else echo "MODCTOR_HOME_SILENT"; fi
    # The execve form of the same question, so the two rights can be told
    # apart in one reading rather than across two suites.
    cp /bin/true "$XDG_DATA_HOME/probe-exec" 2>/dev/null && chmod +x "$XDG_DATA_HOME/probe-exec" 2>/dev/null
    if "$XDG_DATA_HOME/probe-exec" 2>/dev/null; then echo "EXEC_OWN_DIR"; else echo "EXEC_BLOCKED"; fi
fi
# What the launcher asks at launch, asked from where the app will ask it. Round 1
# measured the WebKit injected bundle loading through netinstall and staying
# silent without it, which only makes sense if the confinement is what turned
# WebKitGTK's own bubblewrap off -- and that is a measurement, not an inference,
# so it is taken here rather than reasoned about in the results.
if command -v bwrap >/dev/null 2>&1; then
    if bwrap --unshare-user --ro-bind / / /bin/true >/dev/null 2>&1
    then echo "BWRAP_OK"; else echo "BWRAP_BLOCKED"; fi
else echo "BWRAP_ABSENT"; fi
echo "PROBE_END"
SCRIPT

# A third place to load from, and the only one that answers the question the
# other two cannot. $WORK is a mktemp directory, which on macOS means the Darwin
# per-user temp dir -- a path the seatbelt profile allows on purpose, since
# Foundation needs it. So DLOPEN_OUTSIDE_OK under the tight tier there says
# nothing about read confinement; it says the profile allows what it says it
# allows. This copy sits under $HOME, which neither tier's writable set contains
# and which the tight tier's read confinement is supposed to cover.
NT_HOMEDIR="$HOME/.neutrino-env-probe-$$"
mkdir -p "$NT_HOMEDIR"

nt_serve "$SERVE" || exit 2
trap 'kill ${NT_SERVER_PID:-} 2>/dev/null; rm -rf "$WORK" "$NT_HOMEDIR"' EXIT

SPEC="envprobe-example-com-1$(nt_pin "$SERVE/envprobe.cmd")"
APP="$(nt_as "$BIN" "$SPEC" "$WORK/bin")"
APPDIR="$NEUTRINO_HOME/apps/$(nt_appkey "$SPEC")/envprobe"

export NEUTRINO_TEST_BATTERY="$NT_BATTERY"
export NEUTRINO_TEST_MODEXT="$NT_MODEXT"
if [ "$NT_MOD_BUILT" = "1" ]; then
    export NEUTRINO_TEST_MODULE="$NT_MOD"
    cp "$NT_MOD" "$NT_HOMEDIR/home-module$NT_MODEXT" 2>/dev/null &&
        export NEUTRINO_TEST_MODULE_HOME="$NT_HOMEDIR/home-module$NT_MODEXT"
fi

echo "=== Reach: what the allowlist admits ==="
OUT="$(nt_timeout 120 env "${NT_SET[@]}" "$APP" 2>"$WORK/err")"
CONFINE="$(env "${NT_SET[@]}" "$APP" --info 2>/dev/null |
    awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
INFO_ENV="$(env "${NT_SET[@]}" "$APP" --info 2>/dev/null |
    awk '$1 == "env" { $1 = ""; sub(/^ +/, ""); print }')"
nt_note "confinement: $CONFINE"

# The same run with nothing in the way, so every reading below has a control
# that says what the answer looks like when no rule applies.
CTL_OUT="$(nt_timeout 120 env "${NT_SET[@]}" NEUTRINO_TEST_NO_CONFINE=1 "$APP" 2>/dev/null)"

# And the same payload with no netinstall at all, which is the only thing that
# can tell "the scrub dropped it" from "it never got this far anyway". macOS is
# why: /bin/sh is SIP-restricted, and dyld strips DYLD_* out of the environment
# of a restricted binary before it starts. Asserting DYLD_INSERT_LIBRARIES is
# gone without this control would be PR 1's O_TRUNC mistake a second time --
# a pass earned by a rule that is not the one under test.
mkdir -p "$WORK/bare"
BARE_OUT="$(nt_timeout 120 env "${NT_SET[@]}" XDG_DATA_HOME="$WORK/bare" \
    sh "$SERVE/envprobe.cmd" 2>/dev/null)"

# And once more under the tight tier, which is the only place the w^x rule
# exists on linux.
TIGHT_OUT=""
TIGHT_CONFINE="not measured"
if [ -n "$BIN_TIGHT" ] && [ -x "$BIN_TIGHT" ]; then
    APP_TIGHT="$(nt_as "$BIN_TIGHT" "$SPEC" "$WORK/bin-tight")"
    # Planted from outside rather than left behind by the run above, so the
    # reading does not depend on which order the two tiers ran in. An app that
    # can write its own directory is the ordinary case -- the tight tier grants
    # exactly that -- and this is that file, put there by something that was
    # allowed to put it there.
    if [ "$NT_MOD_BUILT" = "1" ]; then
        mkdir -p "$APPDIR/data"
        cp "$NT_MOD" "$APPDIR/data/probe-module$NT_MODEXT" 2>/dev/null
    fi
    TIGHT_OUT="$(nt_timeout 120 env "${NT_SET[@]}" "$APP_TIGHT" 2>/dev/null)"
    TIGHT_CONFINE="$(env "${NT_SET[@]}" "$APP_TIGHT" --info 2>/dev/null |
        awk '$1 == "confine" { $1 = ""; sub(/^ +/, ""); print }')"
fi

nt_seen() { grep -qx "env $1 SEEN" <<<"$2"; }

check() {
    local label="$1" want="$2"
    if grep -qx "$want" <<<"$OUT"; then
        echo "  PASS: $label ($want)"
    else
        nt_fail "$label expected=$want actual=$(tr '\n' ' ' <<<"$OUT" | cut -c1-400)"
        FAILURES=$((FAILURES + 1))
    fi
}

# --- controls first: nothing below means anything without them ---
NT_RAN=1
if grep -qx PROBE_END <<<"$OUT"; then
    echo "  PASS: the payload ran"
else
    NT_RAN=0
    nt_fail "payload expected=ran actual=$(tr '\n' ' ' <<<"$OUT" | cut -c1-200) err=$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
    FAILURES=$((FAILURES + 1))
fi
check "a name outside the allowlist is dropped"        "env NT_ENV_CONTROL_DROPPED GONE"
check "a NEUTRINO_ name arrives, so the battery was set" "env NEUTRINO_ENV_CONTROL_KEPT SEEN"

# --- the three claims env.c already makes ---
echo "=== The names env.c says are absent by construction ==="
NT_PREEMPTED=""
for n in $NT_CLAIMS; do
    if nt_seen "$n" "$OUT"; then
        nt_fail "$n expected=dropped actual=reached the payload"
        FAILURES=$((FAILURES + 1))
    elif ! nt_seen "$n" "$BARE_OUT"; then
        # Gone without netinstall too, so this run cannot say the scrub is what
        # removed it. Recorded rather than counted, in either direction.
        NT_PREEMPTED="$NT_PREEMPTED $n"
        echo "  NOTE: $n is already absent with no netinstall in the way"
    else
        echo "  PASS: $n is dropped by the scrub"
    fi
done
[ -n "$NT_PREEMPTED" ] &&
    nt_note "removed before the scrub could, so unmeasured here:$NT_PREEMPTED"

# --- the names this PR denies, each of which arrived before it ---
#
# Written as assertions rather than as a reading, because that is the whole
# change: every one of these reached the payload on every unix lane in the four
# probing rounds, and a run that measures one arriving again is a regression and
# not a note. The bare control is still consulted first, so a name the runner
# never set cannot pass this for free.
echo "=== The loader knobs a prefix used to admit ==="
for n in $NT_LOADERS; do
    if ! nt_seen "$n" "$BARE_OUT"; then
        nt_note "$n never arrived even without netinstall; unmeasured here"
    else
        check "$n is dropped" "env $n GONE"
    fi
done

echo "=== And what a prefix still has to admit ==="
for n in $NT_KEEPERS; do
    if ! nt_seen "$n" "$BARE_OUT"; then
        nt_note "$n never arrived even without netinstall; unmeasured here"
    else
        check "$n still arrives" "env $n SEEN"
    fi
done

echo "=== The same, as a reading ==="
NT_REACHED=""
NT_STOPPED=""
NT_NEVERSET=""
# A payload that never ran reports every name as GONE, which is the shape a
# reassuring wrong answer takes here: it would read as the allowlist stopping
# all of them. Round 2 produced exactly that on macOS.
if [ "$NT_RAN" = "0" ]; then
    NT_REACHED=" unmeasured (the payload never ran)"
    NT_STOPPED=" unmeasured"
    NT_NEVERSET=" unmeasured"
fi
for n in $NT_BATTERY; do
    [ "$NT_RAN" = "0" ] && break
    case "$n" in
        LD_*|DYLD_*|GIO_MODULE_DIR|NT_ENV_CONTROL_DROPPED|NEUTRINO_ENV_CONTROL_KEPT) continue ;;
    esac
    if nt_seen "$n" "$OUT"; then
        NT_REACHED="$NT_REACHED $n"
    elif ! nt_seen "$n" "$BARE_OUT"; then
        NT_NEVERSET="$NT_NEVERSET $n"
    else
        NT_STOPPED="$NT_STOPPED $n"
    fi
done
echo "  reached the payload:$NT_REACHED"
echo "  stopped by the scrub:$NT_STOPPED"
echo "  never got that far anyway:$NT_NEVERSET"

# =====================================================================
# Effect: does loading actually happen, and does confinement stop it
# =====================================================================
echo "=== Effect: a module, loaded from inside the sandbox ==="
nt_tok() { grep -oE "$1" <<<"$2" | tr '\n' ' '; }
NT_DL="$(nt_tok '(BWRAP|MODPRESENT|MODCOPY|DLOPEN_OWNDIR|DLOPEN_OUTSIDE|DLOPEN_HOME|MODCTOR_OWNDIR|MODCTOR_OUTSIDE|MODCTOR_HOME|EXEC_OWN_DIR|EXEC_BLOCKED|DLOPEN_SKIP)[A-Z_]*' "$OUT")"
NT_DL_CTL="$(nt_tok '(BWRAP|MODPRESENT|MODCOPY|DLOPEN_OWNDIR|DLOPEN_OUTSIDE|DLOPEN_HOME|MODCTOR_OWNDIR|MODCTOR_OUTSIDE|MODCTOR_HOME|EXEC_OWN_DIR|EXEC_BLOCKED|DLOPEN_SKIP)[A-Z_]*' "$CTL_OUT")"
NT_DL_TIGHT="$(nt_tok '(BWRAP|MODPRESENT|MODCOPY|DLOPEN_OWNDIR|DLOPEN_OUTSIDE|DLOPEN_HOME|MODCTOR_OWNDIR|MODCTOR_OUTSIDE|MODCTOR_HOME|EXEC_OWN_DIR|EXEC_BLOCKED|DLOPEN_SKIP)[A-Z_]*' "$TIGHT_OUT")"
echo "  confined:   $NT_DL"
echo "  tight tier: ${NT_DL_TIGHT:-not measured}"
echo "  unconfined: $NT_DL_CTL"
# The instrument has to work somewhere or its silence means nothing.
if [ "$NT_MOD_BUILT" = "1" ]; then
    if grep -q 'MODCTOR_[A-Z]*_RAN' <<<"$NT_DL_CTL$NT_DL"; then
        echo "  PASS: the module's constructor ran at least once, so silence elsewhere is a denial"
    else
        nt_fail "instrument expected=MODCTOR_*_RAN somewhere actual=confined[$NT_DL] unconfined[$NT_DL_CTL]"
        FAILURES=$((FAILURES + 1))
    fi
else
    nt_note "no module built ($NT_CC unavailable or failed); the effect half is unmeasured here"
fi

# =====================================================================
# Effect, against the real toolkit
# =====================================================================
#
# dlopen above says the sandbox does not stop a library being mapped. It does
# not say a toolkit honours the knob, which is the other half of the claim and
# the half only the real engine can answer. So: the actual polyglot, launched
# through netinstall, with one knob per lane pointed at a tagged copy of the
# module -- and the same launch without netinstall in the way as the control.
#
# The marks land in the app dir because that is the one directory the loaded
# code may write to. The harness reads them from outside.
NT_TOOLKIT="not measured"
NT_TOOLKIT_CTL="not measured"

# Up, and nothing more than up. nt_app_probe in lib.sh is the one instrument
# the suite asks this of -- this file used to carry a second copy of it, asking
# xdotool where lib.sh asks the window manager, which is two answers to one
# question and the shorter road to them disagreeing.
nt_app_up() {
    [ "$(nt_app_probe "${1:-45}")" = "CONTENT_OK" ]
}

NT_HAVE_APP=0
if [ "$UNAME" = "Darwin" ] || { [ -n "${DISPLAY:-}" ] && nt_linux_runtime && command -v xprop >/dev/null 2>&1; }; then
    NT_HAVE_APP=1
fi

if [ "$NT_HAVE_APP" = "1" ]; then
    echo "=== Build the app under test ==="
    if bash "$ROOT/test/mkapp.sh" --tier=testing "$NT_TESTDIR/alive.js" \
            "$SERVE/alive.cmd" >/dev/null 2>&1 &&
       [ -s "$SERVE/alive.cmd" ]; then
        # With the launcher's own loader scrub cut out of it, and both launches
        # get the same file so the pair still differ by netinstall alone.
        #
        # That scrub removes these knobs before any engine starts, which would
        # cost this suite both halves of the toolkit question at once: the
        # control would stop honouring the knob, so the section would report
        # itself unmeasured; and the netinstall launch would be denied twice,
        # so this suite would go on passing after an env.c regression. What is
        # under test here is env.c's allowlist. The launcher's rule is asserted
        # by test/loaders.sh, against a control patched exactly this way.
        awk '/^nt_scrub_loaders$/ { next } { print }' \
            "$SERVE/alive.cmd" > "$SERVE/alive.patched" &&
            mv "$SERVE/alive.patched" "$SERVE/alive.cmd"
        if grep -q '^nt_scrub_loaders$' "$SERVE/alive.cmd"; then
            nt_fail "the polyglot's loader scrub is still in the file under test; the toolkit half measures two rules"
            FAILURES=$((FAILURES + 1))
        fi
        ASPEC="alive-example-com-1$(nt_pin "$SERVE/alive.cmd")"
        AAPP="$(nt_as "$BIN" "$ASPEC" "$WORK/bin")"
        AAPPDIR="$NEUTRINO_HOME/apps/$(nt_appkey "$ASPEC")/alive"
        echo "  built and pinned as $ASPEC"
    else
        # Not a failure of this suite: the polyglot build is e2e.sh's gate, and
        # a second red line here would only point at the same thing.
        nt_note "the polyglot did not build here; the toolkit and cost halves are unmeasured"
        NT_HAVE_APP=0
    fi
fi

# The knobs, per lane. macOS gets none: the driver there is osascript, the
# loader knob that would apply to it is DYLD_*, and that one is already absent
# -- which is a reading about the prefixes, so it is said rather than skipped
# in silence.
NT_KNOBS=()
NT_KNOB_TAGS=""
if [ "$NT_HAVE_APP" = "1" ] && [ "$NT_MOD_BUILT" = "1" ]; then
    # Any lane that loads GTK, which is no longer only the gjs one: the fork is
    # the same toolkit, and so is PyGObject. Qt is excluded because these two
    # knobs are GTK's and WebKitGTK's, and it gets its own further down.
    if nt_linux_gijs >/dev/null 2>&1 || { ! nt_linux_qt && nt_linux_pygobject; }; then
        if nt_build_module gtkmodule && nt_build_module injectedbundle; then
            mkdir -p "$WORK/mod/bundle"
            cp "$WORK/mod/injectedbundle$NT_MODEXT" \
               "$WORK/mod/bundle/libwebkit2gtkinjectedbundle$NT_MODEXT"
            NT_KNOBS+=("GTK_MODULES=$WORK/mod/gtkmodule$NT_MODEXT")
            NT_KNOBS+=("WEBKIT_INJECTED_BUNDLE_PATH=$WORK/mod/bundle")
            NT_KNOB_TAGS="gtkmodule injectedbundle"
        fi
    elif nt_linux_runtime; then
        # Qt loads a plugin only with matching metadata, so the module would be
        # rejected before its constructor mattered. The knob that does not need
        # any of that is the one Qt appends to Chromium's own argv.
        cat > "$WORK/mod/prefix.sh" <<'PREFIX'
#!/bin/sh
[ -n "${NEUTRINO_TEST_MODULE_MARKDIR:-}" ] &&
    printf 'renderer\n' > "$NEUTRINO_TEST_MODULE_MARKDIR/rendererprefix" 2>/dev/null
exec "$@"
PREFIX
        chmod +x "$WORK/mod/prefix.sh"
        NT_KNOBS+=("QTWEBENGINE_CHROMIUM_FLAGS=--disable-dev-shm-usage --renderer-cmd-prefix=$WORK/mod/prefix.sh")
        NT_KNOB_TAGS="rendererprefix"
    fi
fi

if [ -n "$NT_KNOB_TAGS" ]; then
    echo "=== Effect: the same knobs against the real engine ==="

    # Control first: no netinstall, so the only question is whether the toolkit
    # honours the knob at all. A confined silence means nothing without it.
    nt_app_gone
    rm -f "$WORK/marks"/*
    ( export NEUTRINO_TEST_MODULE_MARKDIR="$WORK/marks"
      env "${NT_KNOBS[@]}" bash "$SERVE/alive.cmd" >"$WORK/ctl-app.log" 2>&1 ) &
    CTL_PID=$!
    nt_app_up 45
    NT_TOOLKIT_CTL=""
    for t in $NT_KNOB_TAGS; do
        NT_TOOLKIT_CTL="$NT_TOOLKIT_CTL $t=$([ -e "$WORK/marks/$t" ] && echo LOADED || echo SILENT)"
    done
    NT_TOOLKIT_CTL="$NT_TOOLKIT_CTL window=$(nt_app_up 1 && echo UP || echo DOWN)"
    nt_kill_tree $CTL_PID
    sleep 2

    # And the same knobs through netinstall, which is where the allowlist is.
    nt_app_gone
    ( export NEUTRINO_TEST_MODULE_MARKDIR="$AAPPDIR"
      env "${NT_KNOBS[@]}" "$AAPP" >"$WORK/app.log" 2>&1 ) &
    APP_PID=$!
    nt_app_up 45
    NT_TOOLKIT=""
    for t in $NT_KNOB_TAGS; do
        NT_TOOLKIT="$NT_TOOLKIT $t=$([ -e "$AAPPDIR/$t" ] && echo LOADED || echo SILENT)"
    done
    NT_TOOLKIT="$NT_TOOLKIT window=$(nt_app_up 1 && echo UP || echo DOWN)"
    nt_kill_tree $APP_PID
    sleep 2
    echo "  through netinstall:$NT_TOOLKIT"
    echo "  no netinstall:     $NT_TOOLKIT_CTL"

    # The instrument first. If no knob loaded anything even with nothing in the
    # way, the engine changed or the module is broken, and every SILENT below
    # is a refusal that rendered nothing.
    if grep -q '=LOADED' <<<"$NT_TOOLKIT_CTL"; then
        echo "  PASS: the engine still honours at least one of these knobs unconfined"
        for t in $NT_KNOB_TAGS; do
            if grep -q "$t=SILENT" <<<"$NT_TOOLKIT"; then
                echo "  PASS: $t did not load through netinstall"
            else
                nt_fail "$t expected=SILENT through netinstall actual=$NT_TOOLKIT"
                FAILURES=$((FAILURES + 1))
            fi
        done
        # And the app is still an app. A denial that took the window with it
        # would report every tag SILENT and pass the three lines above.
        if grep -q 'window=UP' <<<"$NT_TOOLKIT"; then
            echo "  PASS: the app still came up with the knobs denied"
        else
            nt_fail "window expected=UP with the knobs denied actual=$NT_TOOLKIT"
            FAILURES=$((FAILURES + 1))
        fi
    else
        nt_note "no knob loaded even unconfined; the toolkit half is unmeasured: $NT_TOOLKIT_CTL"
    fi
elif [ "$UNAME" = "Darwin" ]; then
    NT_TOOLKIT="skipped: the macos driver is osascript and its loader knob is DYLD_*, already dropped"
    NT_TOOLKIT_CTL="$NT_TOOLKIT"
fi

# =====================================================================
# What the sandbox does not do about any of this
# =====================================================================
#
# Asserted, not recorded, and asserted to what is measured now rather than to
# what used to be true. Three of these read the other way before reads stopped
# being confined on any platform, and they are the clearest statement in the
# suite of what that cost:
#
#   EXEC_BLOCKED    -> EXEC_OWN_DIR       linux w^x needed the exec allowlist,
#                                         and the exec allowlist needed the read
#                                         allowlist, so it went with it. macOS
#                                         and OpenBSD still refuse this; neither
#                                         is promised, and windows never could.
#   DLOPEN_HOME_BLOCKED -> DLOPEN_HOME_OK a library anywhere under $HOME maps
#   MODCTOR_HOME_SILENT -> MODCTOR_HOME_RAN  ...and its constructor runs
#
# Which is exactly why the environment deny list above is the defence and not
# one of two: it is now the only thing standing between a loader variable and
# code of the caller's choosing in the process that renders the page. A kernel
# or a profile that closes any of this again should fail here and be read
# about, not pass quietly.
if [ -n "$NT_DL_TIGHT" ] && [ "$NT_MOD_BUILT" = "1" ]; then
    echo "=== The tight tier, on a library rather than a program ==="
    tight_check() {
        if grep -q "$2" <<<"$NT_DL_TIGHT"; then
            echo "  PASS: $1 ($2)"
        else
            nt_fail "$1 expected=$2 actual=$NT_DL_TIGHT"
            FAILURES=$((FAILURES + 1))
        fi
    }
    tight_check "execve of a file in the app dir is not refused"  EXEC_OWN_DIR
    tight_check "the same directory's library maps anyway"        DLOPEN_OWNDIR_OK
    tight_check "and its constructor runs"                        MODCTOR_OWNDIR_RAN
    tight_check "a library under \$HOME is in reach"              DLOPEN_HOME_OK
    tight_check "and it runs"                                     MODCTOR_HOME_RAN
fi

# =====================================================================
# Cost: the app, with the whole candidate deny set taken away first
# =====================================================================
#
# Every name a rule of the shape "a knob may not name a path, a file or a
# sandbox" would drop -- the maximal candidate. If a lane comes up without all
# of them then every narrower rule is free, and if it does not, this says which
# lane pays and the fix has to answer for it before it is written.
NT_STRIP="
GTK_MODULES GTK_PATH GTK_EXE_PREFIX GTK_DATA_PREFIX GTK_IM_MODULE_FILE
GDK_PIXBUF_MODULE_FILE GDK_PIXBUF_MODULEDIR GSETTINGS_BACKEND GSETTINGS_SCHEMA_DIR
QT_PLUGIN_PATH QT_QPA_PLATFORM_PLUGIN_PATH
QTWEBENGINE_CHROMIUM_FLAGS QTWEBENGINE_PROCESS_PATH QTWEBENGINE_RESOURCES_PATH
QTWEBENGINE_DISABLE_SANDBOX
WEBKIT_INJECTED_BUNDLE_PATH WEBKIT_EXEC_PATH WEBKIT_FORCE_SANDBOX
WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS
LIBGL_DRIVERS_PATH MESA_LOADER_DRIVER_OVERRIDE
VK_LAYER_PATH VK_ADD_LAYER_PATH VK_ICD_FILENAMES VK_DRIVER_FILES VK_INSTANCE_LAYERS
XDG_DATA_DIRS XDG_CONFIG_DIRS XDG_RUNTIME_DIR
"
NT_STRIP="$(tr -s ' \n' ' ' <<<"$NT_STRIP" | sed 's/^ //; s/ $//')"
NT_PRESENT=""
for n in $NT_STRIP; do
    eval "seen=\${$n+set}"
    [ "${seen:-}" = set ] && NT_PRESENT="$NT_PRESENT $n"
done

NT_COST="not measured"
if [ "$NT_HAVE_APP" = "1" ]; then
    echo "=== Cost: the app with the candidate deny set removed ==="
    echo "  set on this lane before the strip:$NT_PRESENT"
    NT_UNSET=()
    for n in $NT_STRIP; do NT_UNSET+=(-u "$n"); done

    nt_app_gone
    ( env "${NT_UNSET[@]}" "$AAPP" >"$WORK/strip.log" 2>&1 ) &
    STRIP_PID=$!
    STRIPPED=DOWN
    nt_app_up 60 && STRIPPED=UP
    nt_kill_tree $STRIP_PID
    sleep 2

    # The control: the same launch with the lane's environment untouched. If
    # this one is DOWN too then the strip is not what the reading is about.
    nt_app_gone
    ( "$AAPP" >"$WORK/keep.log" 2>&1 ) &
    KEEP_PID=$!
    KEPT=DOWN
    nt_app_up 60 && KEPT=UP
    nt_kill_tree $KEEP_PID
    sleep 2

    NT_COST="stripped=$STRIPPED control=$KEPT"
    echo "  $NT_COST"
    if [ "$STRIPPED" = "DOWN" ] && [ "$KEPT" = "UP" ]; then
        nt_note "the strip is what took the window away: $(tr '\n' ' ' < "$WORK/strip.log" | tail -c 300)"
    fi
fi

# =====================================================================
# Results
# =====================================================================
# Named after the engine that would actually be chosen, in the launcher's own
# order, because a result line that says "Linux" and nothing else cannot be
# compared against the run before it on a different desktop.
NT_LANE="$UNAME"
NT_GIJS="$(nt_linux_gijs)" && NT_LANE="$NT_LANE/$NT_GIJS"
if [ "$UNAME" = "Linux" ] && [ -z "$NT_GIJS" ]; then
    if nt_linux_qt; then NT_LANE="$NT_LANE/qt"
    elif nt_linux_pygobject; then NT_LANE="$NT_LANE/pygobject"
    fi
fi

nt_result "env reach [$NT_LANE]: reached:$NT_REACHED | stopped:$NT_STOPPED | \
never arrived even bare:$NT_NEVERSET | absent before the scrub:$NT_PREEMPTED | \
--info says: $INFO_ENV"
nt_result "env admitted set [$NT_LANE]: $(grep '^admitted: ' <<<"$OUT" | cut -c11- | cut -c1-800)"
nt_result "env module load [$NT_LANE] confine=$CONFINE: confined[$NT_DL] unconfined-control[$NT_DL_CTL]"
nt_result "env module load, tight tier [$NT_LANE] confine=$TIGHT_CONFINE: [${NT_DL_TIGHT:-not measured}]"
NT_BWRAP_BARE=BWRAP_ABSENT
if command -v bwrap >/dev/null 2>&1; then
    if bwrap --unshare-user --ro-bind / / /bin/true >/dev/null 2>&1
    then NT_BWRAP_BARE=BWRAP_OK; else NT_BWRAP_BARE=BWRAP_BLOCKED; fi
fi
nt_result "env toolkit [$NT_LANE]: through netinstall[$NT_TOOLKIT] control[$NT_TOOLKIT_CTL] \
webkit sandbox available: confined=$(nt_tok 'BWRAP_[A-Z]+' "$OUT" | sed 's/ $//; s/^$/unmeasured/') \
bare=$NT_BWRAP_BARE"
nt_result "env strip cost [$NT_LANE]: $NT_COST; present before the strip:$NT_PRESENT"

echo "=== Results: $FAILURES failure(s) ==="
exit $FAILURES
