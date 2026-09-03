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
# over the socket itself -- no libwayland, a registry walked by hand, glyphs
# rasterised into a shm buffer -- so the compositor here is the instrument and
# not the subject. That is also why the version is reported: the day this
# breaks, which compositor and which version answered is the first question.

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

# Already up, which is what a second invocation in one job finds. Reported and
# reused rather than started again, so the step is safe to repeat.
if SOCK="$(wl_socket)"; then
    echo "report: wayland-up found a compositor already at $SOCK"
    printf "export XDG_RUNTIME_DIR='%s'\nexport WAYLAND_DISPLAY='%s'\n" \
        "$XDG_RUNTIME_DIR" "$SOCK" > "$ENVFILE"
    exit 0
fi

if ! command -v sway >/dev/null 2>&1; then
    echo "report: wayland-up has no sway on this machine, and nothing to fall back to" >&2
    exit 2
fi

LOG="${TMPDIR:-/tmp}/sway.log"
CONF="${TMPDIR:-/tmp}/sway.conf"
# An empty config would do -- nothing here sends a key or opens a terminal --
# but the output line makes the screen a known size, which is what the lane's
# picture is taken of. HEADLESS-1 is what wlroots names the virtual output; a
# name that stops being right costs a warning in the log and a default size,
# not a lane.
cat > "$CONF" <<EOF
output HEADLESS-1 resolution ${WIDTH}x${HEIGHT}
EOF

# headless, because there is no display and no GPU; pixman, because software
# rendering is the point and the EGL path would want a device this runner does
# not have; and no libinput devices, because there is no seat to open one from.
#
# The output count is spelled out rather than left to the default. It is one
# either way today, and the difference between a compositor with no output and
# a compositor that is merely slow to make one is a difference this script
# would otherwise have to guess at from an empty list.
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

if [ -z "$SOCK" ]; then
    echo "report: wayland-up got no socket in 20s; sway said:" >&2
    sed 's/^/  /' "$LOG" >&2
    kill "$SWAYPID" 2>/dev/null
    exit 1
fi

# A socket is a file, and a file is not a compositor answering. swaymsg is a
# real client doing a real round trip, which is the difference between "the
# path exists" and "something is listening on it" -- and the outputs it prints
# are the geometry the picture below will be taken at.
if command -v swaymsg >/dev/null 2>&1; then
    if OUTS="$(XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$SOCK" \
               swaymsg -t get_outputs -r 2>&1)"; then
        FLAT="$(printf '%s' "$OUTS" | tr -d '\n ')"
        # An empty list is a compositor with nowhere to put a window, which is
        # not a smaller version of this lane -- it is a lane whose picture
        # cannot be taken and whose surface may never be mapped. Better a
        # named failure here than a splash that reports "up" onto no screen.
        if [ "$FLAT" = "[]" ]; then
            echo "report: wayland-up has a compositor at $SOCK with no outputs at all" >&2
            sed 's/^/  /' "$LOG" >&2
            exit 1
        fi
        echo "report: wayland-up outputs: $(printf '%s' "$FLAT" | cut -c1-200)"
    else
        echo "report: wayland-up has a socket at $SOCK that swaymsg could not talk to:" >&2
        printf '  %s\n' "$OUTS" >&2
        exit 1
    fi
fi

echo "report: wayland-up started $(sway --version 2>&1 | head -1) on $SOCK at ${WIDTH}x${HEIGHT}"
# Quoted, because this file is sourced by the caller and a path it did not
# choose has no business being re-split on the way back in.
printf "export XDG_RUNTIME_DIR='%s'\nexport WAYLAND_DISPLAY='%s'\n" \
    "$XDG_RUNTIME_DIR" "$SOCK" > "$ENVFILE"
exit 0
