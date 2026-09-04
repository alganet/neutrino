#!/bin/bash
# wayland-up.sh - a headless compositor, for the one lane that has to have one
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: wayland-up.sh <env-file> [<width>x<height>]
#
# Writes XDG_RUNTIME_DIR and WAYLAND_DISPLAY into <env-file> for the caller to
# source, and exits non-zero -- with the compositor's own log printed -- if
# nothing came up. That is the whole contract: a lane that exists to exercise
# the wayland path must not quietly become a lane that exercises nothing, and
# the failure mode this guards against is not hypothetical. netinstall's splash
# declines silently when it cannot reach a display, by design, so a compositor
# that failed to start turns every window case in splash.sh into a skip and the
# lane goes green having measured nothing at all.
#
# sway, and not weston, which is also in the archive and is the reference
# implementation. The deciding difference is the screenshot: sway is wlroots,
# so `grim` takes a picture through wlr-screencopy with no ceremony, while
# weston's screenshooter is a protocol it only advertises when it was started
# with --debug and a client that writes its output into the working directory
# under a name of its own choosing. The lane's picture is half of what it is
# for, so the compositor is chosen for the one that can be photographed.
#
# What is being tested is neither of them. splash_wayland.c speaks the protocol
# over the socket itself -- no libwayland, a registry walked by hand, the
# window's pixels composed into a pair of shm buffers and alternated a frame at
# a time -- so the compositor here is the instrument and not the subject. That is also why the version is reported: the day this
# breaks, which compositor and which version answered is the first question.
#
# The liveness check is a wayland client and not `swaymsg`, which is what the
# first version of this used and what cost the lane its first run. swaymsg
# speaks sway's own IPC protocol over a second socket named for the compositor's
# pid, found through SWAYSOCK -- a variable sway exports into its children and
# which nothing here is a child of. It answered "Unable to retrieve socket
# path" about a compositor that was up, serving, and about to be terminated as
# an orphan at the end of the job. The wayland socket was never in question.
#
# So the probe is `wayland-info`, which connects to the socket this lane is
# about and walks the registry the way the thing under test does. That makes it
# the right instrument twice over: it proves the socket answers, and it names
# the three globals splash_wayland.c binds -- wl_compositor, wl_shm and
# xdg_wm_base. A compositor advertising none of them is one this splash
# correctly declines to draw on, and that is worth telling apart from a bug.

set -uo pipefail

ENVFILE="${1:?usage: wayland-up.sh <env-file> [<width>x<height>]}"
GEOM="${2:-1024x768}"
WIDTH="${GEOM%x*}"
HEIGHT="${GEOM#*x}"

# A runtime directory the compositor can put its socket in. The kde lane makes
# one the same way and for the same reason: a hosted runner has no logind
# session, so nothing has set this, and wayland has nowhere to bind without it.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
    export XDG_RUNTIME_DIR
fi
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# The socket, found rather than chosen. sway takes no --socket flag: it binds
# the first free wayland-N and tells its children through the environment, so
# the only way to learn the name from outside is to look.
wl_socket() {
    local c
    for c in "$XDG_RUNTIME_DIR"/wayland-*; do
        case "$c" in *.lock) continue ;; esac
        [ -S "$c" ] && { basename "$c"; return 0; }
    done
    return 1
}

LOG="${TMPDIR:-/tmp}/sway.log"
SWAYPID=""

# Everything below this line has to happen whether the compositor was already
# there or was started here, which is why the two paths meet before the check
# rather than after it. The first version returned early on a socket it found,
# so the one path that could be exercised on a developer's machine was the one
# path that verified nothing.
die() {
    echo "report: wayland-up $1" >&2
    shift
    [ "$#" -gt 0 ] && printf '  %s\n' "$@" >&2
    [ -f "$LOG" ] && sed 's/^/  /' "$LOG" >&2
    # Started here, so cleaned up here. A compositor left running is one the
    # runner reports as an orphan at the end of the job, which reads as this
    # script having lost track of it.
    [ -n "$SWAYPID" ] && kill "$SWAYPID" 2>/dev/null
    exit 1
}

# Already up, which is what a second invocation in one job finds. Reused rather
# than started again, so the step is safe to repeat.
if SOCK="$(wl_socket)"; then
    echo "report: wayland-up found a compositor already at $SOCK"
    STARTED=no
else
    STARTED=yes
    if ! command -v sway >/dev/null 2>&1; then
        echo "report: wayland-up has no sway on this machine, and nothing to fall back to" >&2
        exit 2
    fi
fi

if [ "$STARTED" = yes ]; then
    CONF="${TMPDIR:-/tmp}/sway.conf"
    # An empty config would do -- nothing here sends a key or opens a terminal
    # -- but the output line makes the screen a known size, which is what the
    # lane's picture is taken of. HEADLESS-1 is what wlroots names the virtual
    # output; a name that stops being right costs a warning in the log and a
    # default size, not a lane.
    cat > "$CONF" <<EOF
output HEADLESS-1 resolution ${WIDTH}x${HEIGHT}
EOF

    # headless, because there is no display and no GPU; pixman, because
    # software rendering is the point and the EGL path would want a device this
    # runner does not have; and no libinput devices, because there is no seat
    # to open one from.
    #
    # The output count is spelled out rather than left to the default. It is
    # one either way today, and a compositor with no output at all is a lane
    # whose picture cannot be taken -- so it is said rather than assumed.
    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    WLR_LIBINPUT_NO_DEVICES=1 \
    WLR_RENDERER=pixman \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        nohup sway -c "$CONF" > "$LOG" 2>&1 &
    SWAYPID=$!

    SOCK=""
    for i in $(seq 1 100); do
        kill -0 "$SWAYPID" 2>/dev/null || break
        SOCK="$(wl_socket)" && break
        SOCK=""
        sleep 0.2
    done
    [ -n "$SOCK" ] || die "got no socket in 20s; sway said:"
    echo "report: wayland-up started $(sway --version 2>&1 | head -1) on $SOCK at ${WIDTH}x${HEIGHT}"
fi

# A socket is a file, and a file is not a compositor answering. This is the one
# check that distinguishes them, and it does it by being the same kind of
# client as the thing under test: connect, walk the registry, and see what is
# advertised. Absent -- the package is not installed -- it is a report and not
# a failure, because splash.sh's own NEUTRINO_SPLASH_EXPECT still catches a
# compositor that is not there.
if command -v wayland-info >/dev/null 2>&1; then
    INFO="$(XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$SOCK" \
            wayland-info 2>&1)" \
        || die "has a socket at $SOCK that no wayland client could reach:" \
               "$(printf '%s' "$INFO" | tr '\n' ' ' | cut -c1-300)"
    MISSING=""
    for g in wl_compositor wl_shm xdg_wm_base wl_output; do
        printf '%s' "$INFO" | grep -q "'$g'" || MISSING="$MISSING $g"
    done
    # The three the splash binds, plus somewhere to put the result. A
    # compositor missing any of them is one this splash correctly declines to
    # draw on -- so the lane would report "none (...)", which is a true answer
    # to the wrong question and would read as a defect in the splash.
    [ -z "$MISSING" ] || die "has a compositor at $SOCK advertising no$MISSING"
    echo "report: wayland-up globals: $(printf '%s' "$INFO" | sed -n "s/.*interface: '\([a-z_0-9]*\)'.*/\1/p" | sort -u | tr '\n' ' ')"
    echo "report: wayland-up mode: $(printf '%s' "$INFO" | sed -n 's/.*width: \([0-9]*\) px, height: \([0-9]*\) px.*/\1x\2/p' | head -1)"
else
    echo "report: wayland-up has no wayland-info, so the socket at $SOCK is unverified"
fi

# Quoted, because this file is sourced by the caller and a path it did not
# choose has no business being re-split on the way back in.
printf "export XDG_RUNTIME_DIR='%s'\nexport WAYLAND_DISPLAY='%s'\n" \
    "$XDG_RUNTIME_DIR" "$SOCK" > "$ENVFILE"
exit 0
