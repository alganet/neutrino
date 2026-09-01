# lib.sh - shared helpers so the suite runs on linux, macos and git-bash
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) NT_WINDOWS=1; NT_EXE=".exe" ;;
    Darwin)               NT_WINDOWS=0; NT_EXE="" ;;
    *)                    NT_WINDOWS=0; NT_EXE="" ;;
esac
export NT_WINDOWS NT_EXE

nt_python() {
    if command -v python3 >/dev/null 2>&1; then
        echo python3
    else
        echo python
    fi
}

nt_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        # OpenBSD ships neither, and the suite is otherwise portable to it.
        sha256 -q "$1"
    fi
}

# Thirty-two, which is the floor the parser enforces. Every fixture in this
# suite gets its name from here, so this one number is what keeps the suite
# above the floor; it was run at 32 for a full round before the floor moved,
# which is what said the change cost nothing.
nt_pin() {
    nt_sha256 "$1" | cut -c1-"${2:-32}"
}

# Serves $1 on a free-ish port. Sets NT_SERVER_PID and NEUTRINO_TEST_ORIGIN in
# the caller's shell, so it must not be run in a command substitution.
nt_serve() {
    local dir="$1" port i log py
    port=$((20000 + RANDOM % 20000))
    py="$(nt_python)"
    # The server's own output used to go to /dev/null, so a suite whose fixture
    # never came up said "never came up" and nothing else -- eleven times in one
    # netbsd run, which is most of that lane's failure count and none of it a
    # statement about the confinement. Keep it: it is the only thing that knows
    # whether the interpreter is missing, the module is absent, or the bind was
    # refused.
    log="${TMPDIR:-/tmp}/nt-serve-$$-$port.log"
    local t0=$SECONDS
    ( cd "$dir" && exec "$py" -m http.server "$port" --bind 127.0.0.1 ) >"$log" 2>&1 &
    NT_SERVER_PID=$!
    export NEUTRINO_TEST_ORIGIN="http://127.0.0.1:$port"
    # How long the fixture took to answer, and after how many polls. Two
    # readings and not one: the macOS lane spends about thirty-seven seconds per
    # suite that the Linux lane spends none of, and the two candidates are a
    # server slow to bind -- which shows up as a high poll count -- and a poller
    # slow to give up on each attempt, which shows up as a long wall time at a
    # low count. A single elapsed number cannot tell those apart, and this loop
    # is bounded at a hundred tries either way, so the difference is the whole
    # question.
    for i in $(seq 1 100); do
        curl -fsS "$NEUTRINO_TEST_ORIGIN/" >/dev/null 2>&1 && {
            rm -f "$log"
            # No `report:` prefix: that marks the lines a reader scans for a
            # result, and how long a fixture took to bind is not one.
            echo "  nt_serve up port=$port polls=$i secs=$((SECONDS - t0))"
            return 0
        }
        sleep 0.1
    done
    {
        echo "nt_serve: server on port $port never came up"
        echo "  interpreter: $py -> $(command -v "$py" 2>/dev/null || echo '<not on PATH>')"
        echo "  still running: $(kill -0 "$NT_SERVER_PID" 2>/dev/null && echo yes || echo no)"
        echo "  poller: curl -> $(command -v curl 2>/dev/null || echo '<not on PATH>')"
        echo "  it said: $(tr '\n' ' ' < "$log" 2>/dev/null | tr -d '[:cntrl:]' | cut -c1-300)"
    } >&2
    rm -f "$log"
    return 1
}

# Installs the binary under a spec name and echoes the path to invoke.
nt_as() {
    local bin="$1" spec="$2" dir="$3"
    mkdir -p "$dir"
    rm -f "$dir/$spec$NT_EXE"
    cp "$bin" "$dir/$spec$NT_EXE"
    echo "$dir/$spec$NT_EXE"
}

# Prints a failure and, on GitHub, also emits it as an annotation.
#
# This one stays while the readings around it go. An annotation on a failure is
# not a workaround for anything -- it is how a red check says what went wrong on
# the run page, without opening a log -- and it is cheap because failures are
# rare. It is also the reason the readings had to leave: they were crowding it
# out of a thirty-annotation budget.
nt_fail() {
    echo "  FAIL: $*"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::error title=netinstall::$(basename "${0:-suite}"): $*"
    fi
}

# Annotations are capped per step, and a result split across several notices is
# exactly the shape that gets truncated -- twice now. The step summary has no
# such cap and renders on the run page itself, so anything that has to survive
# the trip goes here rather than into an annotation.
nt_summary() {
    echo "  $*"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# A measurement that has to survive the trip out of CI.
#
# It used to go out as a `::warning` as well, because for a long stretch there
# was no `gh` and no token here: the checks API served annotations and nothing
# else, so a reading that was not an annotation could not be read at all. That
# is no longer true -- the job log is fetchable directly and every assertion
# also reaches the lane's sheet -- and the annotation had a real cost. GitHub
# returns thirty per job and drops the rest silently, oldest first, and this
# function alone could fill that. Six of seven lanes were pinned at exactly
# thirty, which meant a genuine `::error` from nt_fail was liable to be one of
# the ones discarded.
#
# The step summary stays: it has no cap and renders on the run page.
nt_result() {
    echo "  $*"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

nt_note() {
    echo "  $*"
}

# Runs a command under a wall-clock bound where coreutils timeout exists.
# macOS ships none by default, so there it just runs the command.
nt_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        # A bound that silently is not there is worse than no bound: run.sh
        # reads as though every suite in the list is capped, and on a platform
        # without timeout(1) none of them are. Say it once rather than let the
        # list be believed.
        echo "  nt_timeout: no timeout(1) on this platform; running unbounded: $*" >&2
        "$@"
    fi
}

# On windows the pid a suite holds is not the app's: the launcher STARTs the
# real program and exits, so nt_kill_tree cannot reach it and a suite that
# thinks it cleaned up leaves a webview running. The image name is the only
# reliable handle. Called between suites so one cannot leak processes into the
# next -- which is otherwise invisible until the suite order changes.
nt_kill_app() {
    [ "${NT_WINDOWS:-0}" = "1" ] || return 0
    taskkill //F //T //IM neutrinotest.exe >/dev/null 2>&1
    taskkill //F //T //IM msedgewebview2.exe >/dev/null 2>&1
    return 0
}

# A webview leaves children behind, so kill the whole tree rather than the
# process we happen to hold a pid for.
nt_kill_tree() {
    local pid="$1" child
    [ -n "$pid" ] || return 0
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        nt_kill_tree "$child"
    done
    kill "$pid" 2>/dev/null
    return 0
}

# Which GI-capable JavaScript interpreter the launcher would pick, in its
# order. Printed rather than answered yes/no: on Cinnamon the answer is cjs,
# and a suite that only ever asked about gjs called that machine runtime-less
# while it was busy running the app.
nt_linux_gijs() {
    local c
    for c in gjs gjs-console cjs cjs-console; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# Mirrors find_qt_runtime in webview.cmd: on Ubuntu the Qt runner is not on
# PATH, it sits at an absolute path, and the distributions that do that do not
# agree on which one. Miss it and a "no runtime" fallback launches a GUI app it
# expected to exit immediately.
nt_linux_qt() {
    local c
    for c in qml6 qml; do
        command -v "$c" >/dev/null 2>&1 && return 0
    done
    for c in /usr/lib/qt6/bin/qml /usr/lib64/qt6/bin/qml /usr/lib/*/qt6/bin/qml; do
        [ -x "$c" ] && return 0
    done
    return 1
}

# The one candidate whose presence on PATH says nothing at all. python3 is on
# every desktop and PyGObject is a separate package, so this is asked by
# importing what the lane actually needs rather than by looking for a name.
nt_linux_pygobject() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I -c '
import gi, sys
gi.require_version("Gtk", "3.0")
for api in ("4.1", "4.0"):
    try:
        gi.require_version("WebKit2", api)
        gi.require_version("JavaScriptCore", api)
        break
    except Exception:
        continue
else:
    sys.exit(1)
from gi.repository import Gtk, WebKit2, JavaScriptCore
' >/dev/null 2>&1
}

nt_linux_runtime() {
    nt_linux_gijs >/dev/null 2>&1 && return 0
    nt_linux_qt && return 0
    nt_linux_pygobject && return 0
    return 1
}

# Ubuntu 24.04 and its derivatives hand an unprivileged user namespace to a
# binary without an AppArmor profile and then refuse to let anything be done
# with it: unshare succeeds and writing uid_map returns EPERM. CI runs on
# exactly that. A suite that needs a working namespace lifts the restriction for
# its own run, says in its results that it did, and puts it back. Nothing
# shipped may do this: it is root's decision. A test may, or the session tier
# goes unexercised on the only machine that runs the suite.
#
# The caller passes its own test rather than this asking util-linux's unshare,
# which on Ubuntu carries a profile of its own and can therefore do what the
# binary under test cannot. Asking the wrong process this question is how a
# suite once reported the tier open while the run under it was closing the bus.
NT_USERNS_LIFTED=0

nt_userns() {
    "$@" && return 0
    [ -n "${GITHUB_ACTIONS:-}" ] || return 1
    sudo -n true 2>/dev/null || return 1
    sudo -n sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null 2>&1 || return 1
    if "$@"; then
        NT_USERNS_LIFTED=1
        return 0
    fi
    nt_userns_restore
    return 1
}

nt_userns_restore() {
    [ "$NT_USERNS_LIFTED" = "1" ] || return 0
    sudo -n sysctl -w kernel.apparmor_restrict_unprivileged_userns=1 >/dev/null 2>&1
    NT_USERNS_LIFTED=0
}

# Yama's ptrace_scope is 1 on Debian, Ubuntu and therefore on CI, and at that
# setting the kernel refuses PTRACE_MODE_ATTACH on anything that is not a
# descendant -- before any of our own confinement is consulted. A probe that
# asks whether a confined app can reach another process's memory then gets the
# kernel's answer to a different question, and reads as a pass. The suite lifts
# the knob for its own run, says so in its results, and puts it back. Same
# terms as nt_userns above: nothing shipped may do this, it is root's decision,
# and a test is the only thing entitled to make it.
#
# Unlike nt_userns this takes no command to try first. There is nothing here to
# ask the right process: the value is global, the process that has to be asked
# is the payload, and by then the sysctl is already whatever it is going to be.
# So it reads the knob, reports what it found, and lifts only what it must.
NT_PTRACE_SCOPE_SAVED=""

nt_ptrace_scope() {
    local knob=/proc/sys/kernel/yama/ptrace_scope cur
    [ -r "$knob" ] || { echo "absent (no yama)"; return 0; }
    cur="$(cat "$knob" 2>/dev/null)"
    [ "$cur" = "0" ] && { echo "0"; return 0; }
    [ -n "${GITHUB_ACTIONS:-}" ] || { echo "$cur (not lifted: not CI)"; return 0; }
    sudo -n true 2>/dev/null || { echo "$cur (not lifted: no sudo)"; return 0; }
    if sudo -n sysctl -w kernel.yama.ptrace_scope=0 >/dev/null 2>&1; then
        NT_PTRACE_SCOPE_SAVED="$cur"
        echo "0 (lifted from $cur)"
    else
        echo "$cur (lift refused)"
    fi
}

nt_ptrace_scope_restore() {
    [ -n "$NT_PTRACE_SCOPE_SAVED" ] || return 0
    sudo -n sysctl -w "kernel.yama.ptrace_scope=$NT_PTRACE_SCOPE_SAVED" >/dev/null 2>&1
    NT_PTRACE_SCOPE_SAVED=""
}

# Which tier a binary is, read off the sentence --info prints, because that is
# the only channel that says so.
#
# It used to be the phrase "reads and writes confined to", matched in two
# suites independently. That phrase was also a false claim -- the tight tier
# confines reads to an allowlist, not to the app dir -- and removing it would
# have made confine-strict.sh skip its whole battery with a note and exit 0,
# which is a green tick for a suite that asserted nothing. Caught locally, and
# writable.sh now asserts that this function still recognises the tier, so the
# next rewording fails loudly instead of quietly.
#
# Keyed on the read claim each platform actually makes, and on windows on the
# mechanism, because that platform confines no reads and says so.
nt_tight_tier() {
    case "$1" in
        *"reads allowlisted"*|*"reads denied under"*|*"low integrity"*) return 0 ;;
    esac
    return 1
}

# A path as a native downloader will read it. curl.exe and wget.exe do not read
# a git-bash path, and git-bash rewrites path-shaped *arguments* on the way to
# them but not the contents of a config file and not the value of an
# environment variable -- which is where every path these suites hand a
# downloader goes. Forward slashes on purpose: curl's config parser treats a
# backslash as an escape.
#
# Lifted here from phases.sh when fetchconf.sh turned out to need the same
# thing. Two copies of this is how the two suites drift into disagreeing about
# what a path is.
nt_native() {
    if [ "${NT_WINDOWS:-0}" = "1" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

# The app directory is keyed on the spec without its pin -- so versions of the
# same app share it -- but *with* its shape, because two names that differ only
# in shape resolve to different URLs and must not.
nt_appkey() {
    local head="${1%-*}" token="${1##*-}"
    echo "$head-${token%"${token#?}"}"
}
