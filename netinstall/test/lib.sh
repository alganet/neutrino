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
