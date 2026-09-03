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

# The suite's own web server, two directories up. Resolved from this file rather
# than from $0 because every script here sources lib.sh from a different place.
NT_HTTPSERVE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)/test/httpserve.py"
export NT_HTTPSERVE

# This directory, resolved the same way and for the same reason: the liveness
# probe below reaches for probe-window.ps1, which lives beside this file.
NT_TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export NT_TESTDIR

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
    # test/httpserve.py and not `-m http.server`: the module looks up what
    # loopback is called every time it binds, macOS counts that as looking for
    # devices on the local network, and the runner then asks a question nobody
    # is there to answer. The numbers this function already prints are what
    # named it -- `polls=6 secs=36` on macOS against nothing on linux, six
    # seconds a request in a loop that sleeps a tenth of a second.
    if [ -f "$NT_HTTPSERVE" ]; then
        ( cd "$dir" && exec "$py" "$NT_HTTPSERVE" "$port" --bind 127.0.0.1 ) >"$log" 2>&1 &
    else
        # A netinstall tree without the repository's test/ beside it. Worth a
        # line rather than a failure: the module still serves, it just asks the
        # question again on macOS.
        echo "  nt_serve: no $NT_HTTPSERVE; falling back to -m http.server" >&2
        ( cd "$dir" && exec "$py" -m http.server "$port" --bind 127.0.0.1 ) >"$log" 2>&1 &
    fi
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

# The whole screen, to $1, as a PNG -- on whichever of the three desktops this
# is. Returns non-zero when nothing was written, and says nothing itself: the
# caller is the one that knows whether a missing picture is a finding.
#
# The whole screen and not the window, on every platform, for the reason
# verify-linux.sh and its siblings take theirs that way: a capture that had to
# find the window first would be an instrument that fails exactly when the
# thing it exists to photograph is not where it was expected, and a picture of
# the desktop with nothing on it is the more useful of the two failures.
#
# Windows goes through the same CopyFromScreen the verifiers use, in a
# powershell started for the purpose. That start is the slow part -- seconds on
# a cold runner -- and it is why the splash case holds its window for as long
# as it does before the shutter is due.
nt_screenshot() {
    local out="$1" ps
    mkdir -p "$(dirname "$out")" 2>/dev/null
    rm -f "$out"
    if [ "${NT_WINDOWS:-0}" = "1" ]; then
        ps=powershell
        command -v pwsh >/dev/null 2>&1 && ps=pwsh
        "$ps" -NoProfile -ExecutionPolicy Bypass -Command "
            Add-Type -AssemblyName System.Drawing
            Add-Type -AssemblyName System.Windows.Forms
            \$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            \$bmp = New-Object System.Drawing.Bitmap \$b.Width, \$b.Height
            \$g = [System.Drawing.Graphics]::FromImage(\$bmp)
            \$g.CopyFromScreen(\$b.X, \$b.Y, 0, 0, \$bmp.Size)
            \$g.Dispose()
            \$bmp.Save('$(cygpath -w "$out")', [System.Drawing.Imaging.ImageFormat]::Png)
        " >/dev/null 2>&1
    elif [ "$(uname -s)" = "Darwin" ]; then
        screencapture -x "$out" 2>/dev/null
    elif command -v import >/dev/null 2>&1; then
        import -window root "$out" 2>/dev/null
    fi
    [ -s "$out" ]
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
    taskkill //F //T //IM alive.exe >/dev/null 2>&1
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

# ---------------------------------------------------------------------------
# Did a webview come up, and did its content run?
# ---------------------------------------------------------------------------
#
# Three suites here launch a real webview and none of them is asking about
# neutrino's window: `e2e.sh` wants to know that a fetched and verified app
# runs, `confine-strict.sh` and `confine-session.sh` that a tier is worth
# having. Each of them used to answer that by running `test/verify-linux.sh`
# and its two siblings -- neutrino's own verifiers, which assert the title at
# each of six states, the size to the pixel, the frame's corner and the
# desktop's palette, and keep a screenshot of every one.
#
# Every lane that runs this suite already runs that verifier directly against a
# standalone launch, in a step of its own, a few minutes earlier: `gjs` and
# `kde` do, `windows-launch` does in `core launch`, and `macos` does beside
# `macos-netinstall`. So the second run measured nothing the first had not, and
# it cost more than the time: a regression in neutrino's geometry or palette
# turned three netinstall suites red on four lanes, each of them reporting a
# webview defect under a sandbox's name.
#
# What is left when that is taken out is one question with three answers, and
# they are the ones probe-window.ps1 was already written to give:
#
#   NO_WINDOW          nothing ever showed a window
#   WINDOW_NO_CONTENT  a window appeared but the page never set its title
#   CONTENT_OK         the page ran and drove the title
#
# The middle one is why this is a probe and not a boolean. A sandbox that lets
# the process start and kills its renderer is the interesting failure -- it is
# what Windows low integrity does to WebView2 -- and "the verifier reported 4
# failures" could not say it.
#
# The app is netinstall/test/alive.js, which this suite owns: it sets the title
# once and holds the window. Nothing here waits out neutrino's eleven-second
# head start any more, and nothing here breaks when its step list changes.
NT_ALIVE_TITLE="NETINSTALL-ALIVE"
export NT_ALIVE_TITLE

# The title the probe matched, written to a file rather than to a variable.
#
# Every caller spells this `STATE="$(nt_app_probe ...)"`, which is a subshell,
# so an assignment inside it is gone before the caller reads it --
# verify-linux.sh carries the same file for the same reason and got there by
# reporting `wid_src=?` on every lane for a round.
#
# What it is for: alive.js announces its viewport size from a frame callback, so
# the title arrives as `NETINSTALL-ALIVE 900x600` once the view has laid the
# document out and scheduled a frame, and as a bare `NETINSTALL-ALIVE` before
# that. Those two are different readings -- a view that ran a script and a view
# that got a surface -- and on Windows the difference is the whole question,
# because low integrity is documented to leave WebView2 with a window and no
# rendering.
NT_APP_TITLE_FILE="${TMPDIR:-/tmp}/nt-app-title-$$"

# How long a bare NETINSTALL-ALIVE is given to grow a size before the probe
# settles for it. A frame callback runs in about sixteen milliseconds and this
# loop polls once a second, so in practice the first poll already sees the size;
# this is the bound on the case where no frame ever comes, and it has to be
# short because that case is a reading and not a hang.
NT_FRAME_GRACE=5

nt_app_title() {
    cat "$NT_APP_TITLE_FILE" 2>/dev/null
}

# The viewport alive.js reported, as WxH, or empty if no frame was announced.
# Never the string "0x0" quietly: a zero viewport is a real reading and the
# caller is the one that decides what it means.
nt_app_frame() {
    nt_app_title | sed -n "s/.*$NT_ALIVE_TITLE \([0-9][0-9]*x[0-9][0-9]*\).*/\1/p" | head -1
}

# The window manager's own list of managed top-levels, which is what
# verify-linux.sh reaches for first and for the reason it gives at length:
# `xdotool search` matches any window carrying the name, and GTK gives that
# name to more than the toplevel. Asked through xprop, so this needs x11-utils
# and not xdotool -- both lanes install both, and xprop is the one that is also
# on a developer's machine.
nt_x11_titles() {
    local wid
    for wid in $(xprop -root _NET_CLIENT_LIST 2>/dev/null |
                 sed -n 's/.*# *//p' | tr ',' '\n' | tr -d ' ' | grep '^0x'); do
        xprop -id "$wid" _NET_WM_NAME WM_NAME 2>/dev/null |
            sed -n 's/.*= *"\(.*\)"/\1/p'
    done
}

# Prints one of the three outcomes above. $1 is the budget in seconds; it
# returns as soon as the answer is CONTENT_OK, and spends the whole budget only
# when it is about to report one of the other two.
# A fourth word, and it is not one of the outcomes: the probe itself did not
# report. Only the Windows path can produce it -- powershell missing, the script
# unreadable, an exception before the first Write-Output -- and it exists so
# that case cannot arrive as the empty string, which every caller's `case` would
# quietly fall through. A probe that could not run is a failure of the suite and
# has to read as one.
nt_app_probe() {
    local secs="${1:-60}" i titles title saw=0 ps out raw grace=""
    if [ "${NT_WINDOWS:-0}" = "1" ]; then
        ps=powershell
        command -v pwsh >/dev/null 2>&1 && ps=pwsh
        # The whole wait happens inside the script, which is the only side that
        # can skip the console hosts: the launcher runs cmd.exe, whose window
        # carries the script path in its title and a real MainWindowHandle.
        raw="$("$ps" -NoProfile -ExecutionPolicy Bypass \
            -File "$(cygpath -w "$NT_TESTDIR/probe-window.ps1")" \
            -TimeoutSeconds "$secs" 2>/dev/null | tr -d '\r')"
        out="$(printf '%s\n' "$raw" | grep -E '^(NO_WINDOW|WINDOW_NO_CONTENT|CONTENT_OK)$' | tail -1)"
        printf '%s\n' "$raw" | sed -n 's/^TITLE //p' | tail -1 > "$NT_APP_TITLE_FILE"
        case "$out" in
            NO_WINDOW|WINDOW_NO_CONTENT|CONTENT_OK) echo "$out" ;;
            *) echo PROBE_FAILED ;;
        esac
        return 0
    fi
    for i in $(seq 1 "$secs"); do
        if [ "$(uname -s)" = "Darwin" ]; then
            # The macOS driver writes the title it set to this file, and only
            # in the testing tier. Line 1 is the title; the launcher writes the
            # window's own name there from its clock tick, before any script
            # has run, which is exactly the WINDOW_NO_CONTENT state.
            titles="$(sed -n '1p' "${TMPDIR:-/tmp}/neutrino-title.txt" 2>/dev/null)"
        else
            titles="$(nt_x11_titles)"
        fi
        # Line by line, and the bare title matched exactly. A substring match
        # for `neutrino` over the whole display finds a terminal sitting in
        # this checkout, and would turn NO_WINDOW into WINDOW_NO_CONTENT on a
        # developer's machine -- which is the one reading here that is only
        # ever used to explain a failure.
        while IFS= read -r title; do
            case "$title" in
                *"$NT_ALIVE_TITLE "[0-9]*x[0-9]*)
                    # A title carrying a size: the view got a surface. Nothing
                    # further is worth waiting for.
                    printf '%s\n' "$title" > "$NT_APP_TITLE_FILE"
                    echo CONTENT_OK
                    return 0 ;;
                *"$NT_ALIVE_TITLE"*)
                    # The bare one. The script ran, and whether a frame follows
                    # is the reading this waits a moment for -- see
                    # NT_FRAME_GRACE. Recorded now so that if none comes, the
                    # caller still has the title that did.
                    printf '%s\n' "$title" > "$NT_APP_TITLE_FILE"
                    [ -n "$grace" ] || grace=$((SECONDS + NT_FRAME_GRACE)) ;;
                neutrino) saw=1 ;;
            esac
        done <<TITLES
$titles
TITLES
        if [ -n "$grace" ] && [ $SECONDS -ge $grace ]; then
            echo CONTENT_OK
            return 0
        fi
        sleep 1
    done
    [ "$saw" = "1" ] && { echo WINDOW_NO_CONTENT; return 0; }
    echo NO_WINDOW
    return 0
}

# A window from the previous launch still on the display is indistinguishable
# from this launch's, and would read as CONTENT_OK before anything had started.
# So a suite that launches twice waits for the last one to be gone, and says so
# if it never went.
nt_app_gone() {
    local i
    : > "$NT_APP_TITLE_FILE"
    if [ "$(uname -s)" = "Darwin" ]; then
        rm -f "${TMPDIR:-/tmp}/neutrino-title.txt"
        return 0
    fi
    [ "${NT_WINDOWS:-0}" = "1" ] && return 0
    command -v xprop >/dev/null 2>&1 || return 0
    for i in $(seq 1 20); do
        case "$(nt_x11_titles)" in
            *"$NT_ALIVE_TITLE"*) sleep 1 ;;
            *) return 0 ;;
        esac
    done
    nt_note "an app window outlived its launch; the next reading may be the old one"
    return 1
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

# Mirrors find_qt_runtime in neutrino/sh/qt.sh: on Ubuntu the Qt runner is not on
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
