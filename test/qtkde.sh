#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# qtkde.sh - the Qt lane's live theme half, on a KDE that actually exists.
#
# themeflip.sh's live_half_qt asserts that a running app is handed a new
# palette when the desktop's colour scheme moves. It can only do that where
# Qt's KDE platform theme is installed, and neither this project's runner nor
# a typical dev machine has one: Ubuntu ships plasma-integration built against
# Qt 5, so QT_QPA_PLATFORMTHEME=kde there finds no Qt 6 plugin and Qt falls
# back to QGtk3Theme, which delivers nothing live. Three probe rounds were
# spent discovering that the answer could not be reached from there.
#
# So this file supplies the desktop. Fedora 42 carries Qt 6.10 and
# plasma-integration 6.6 in the same image, which is a real Plasma 6 stack and
# not a mock: KDEPlasmaPlatformTheme6.so is the plugin Qt loads, confirmed in
# the loader log rather than assumed.
#
# Two things the container has to get right, both of them measured the hard
# way. It runs as a normal user, because Chromium refuses to start as root
# without --no-sandbox and the launcher does not pass one. And it exports
# QT_FORCE_STDERR_LOGGING, because Fedora builds Qt against journald: without
# it qWarning leaves stderr entirely when stderr is not a tty, and every probe
# in here runs, exits 0 and prints nothing at all -- so does `qml -h`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CF="$ROOT/test/kde.containerfile"
# A bare tag builds locally; a name with a registry in it is pulled first and
# only built if the pull fails, which is what CI passes so a run costs a
# download rather than a dnf transaction.
IMAGE="${NT_KDE_IMAGE:-neutrino-kde:test}"

note() { echo "report: $*"; }

RT="${NT_KDE_RUNTIME:-}"
if [ -z "$RT" ]; then
    for c in podman docker; do command -v "$c" >/dev/null 2>&1 && { RT="$c"; break; }; done
fi
if [ -z "$RT" ] || ! command -v "$RT" >/dev/null 2>&1; then
    note "qtkde: no podman or docker here, so there is no KDE to run the Qt live half on"
    exit 0
fi
note "qtkde: runtime=$RT image=$IMAGE"

have_image() {
    "$RT" image exists "$IMAGE" >/dev/null 2>&1 && return 0
    "$RT" image inspect "$IMAGE" >/dev/null 2>&1
}

if ! have_image; then
    case "$IMAGE" in
        */*)
            note "qtkde: pulling $IMAGE"
            "$RT" pull "$IMAGE" >/dev/null 2>&1 ||
                note "qtkde: pull failed; falling back to building it here"
            ;;
    esac
fi

if ! have_image; then
    note "qtkde: building $IMAGE from ${CF#$ROOT/} (this pulls a full Qt 6 and Plasma 6 stack)"
    if ! "$RT" build -t "$IMAGE" -f "$CF" "$ROOT"; then
        note "qtkde: the image would not build; no KDE to run the Qt live half on"
        exit 0
    fi
fi

# The repo goes in read-only and everything written goes to the probe user's
# home, so a run cannot leave a built artifact or a log in the working tree.
exec "$RT" run --rm \
    -v "$ROOT:/src:ro" \
    -e NT_FLIP_LIVE_ONLY=1 \
    "$IMAGE" bash -c '
set -u
cp -r /src /home/probe/neutrino
chown -R probe /home/probe
exec su probe -c "
    export HOME=/home/probe
    export XDG_CURRENT_DESKTOP=KDE
    export QT_FORCE_STDERR_LOGGING=1
    export NT_FLIP_LIVE_ONLY=1
    cd /home/probe/neutrino
    xvfb-run -a --server-args=\"-screen 0 1024x768x24\" \
      dbus-run-session -- \
      bash test/themeflip.sh qt \
        /home/probe/std.cmd /home/probe/shots /home/probe/live.cmd
"
'
