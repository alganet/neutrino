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
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

nt_pin() {
    nt_sha256 "$1" | cut -c1-"${2:-16}"
}

# Serves $1 on a free-ish port. Sets NT_SERVER_PID and NEUTRINO_TEST_ORIGIN in
# the caller's shell, so it must not be run in a command substitution.
nt_serve() {
    local dir="$1" port i
    port=$((20000 + RANDOM % 20000))
    ( cd "$dir" && exec "$(nt_python)" -m http.server "$port" --bind 127.0.0.1 ) >/dev/null 2>&1 &
    NT_SERVER_PID=$!
    export NEUTRINO_TEST_ORIGIN="http://127.0.0.1:$port"
    for i in $(seq 1 100); do
        curl -fsS "$NEUTRINO_TEST_ORIGIN/" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "nt_serve: server on port $port never came up" >&2
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

# Prints a failure and, on GitHub, also emits it as an annotation so the
# message is readable from the checks API without downloading the log.
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

# A measurement that has to survive the trip out of CI. The notice bucket is
# capped at ten per step and the suite fills it long before the interesting
# lines arrive, so results go out as warnings, which nothing else here uses.
# Findings, not problems -- but a finding nobody can read is not a finding.
nt_result() {
    echo "  $*"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning title=netinstall::$(basename "${0:-suite}"): $*"
    fi
}

nt_note() {
    echo "  $*"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::notice title=netinstall::$(basename "${0:-suite}"): $*"
    fi
}

# Runs a command under a wall-clock bound where coreutils timeout exists.
# macOS ships none by default, so there it just runs the command.
nt_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
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

# Mirrors find_qt_runtime in webview.cmd: on Ubuntu the Qt runner is not on
# PATH, it sits at an absolute path. Miss that and a "no runtime" fallback
# launches a GUI app it expected to exit immediately.
nt_linux_runtime() {
    command -v gjs >/dev/null 2>&1 && return 0
    command -v qml6 >/dev/null 2>&1 && return 0
    command -v qml >/dev/null 2>&1 && return 0
    [ -x /usr/lib/qt6/bin/qml ] && return 0
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

# The app directory is keyed on the spec without its pin, so versions of the
# same app share it.
nt_appkey() {
    echo "${1%-*}"
}
