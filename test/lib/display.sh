# display.sh - the desktop a windowed suite needs, brought up once.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Sourced. `. test/lib/display.sh` then `nt_display_up [metacity|openbox]`.
#
# This line was in .github/workflows/ci.yml forty-one times:
#
#   pgrep Xvfb >/dev/null 2>&1 || { Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 & \
#     sleep 3; metacity >/dev/null 2>&1 & sleep 2; }
#
# Twenty-nine with metacity, eleven with openbox, one with no window manager at
# all, and six more places that spelled it without the `pgrep` guard and so
# started a second Xvfb on a display that already had one. Every step that
# wanted a window carried its own copy, because a step is the unit a workflow
# gives you and there was nowhere else to put it.
#
# The guard is the load-bearing part and it is why this is a function rather
# than a step. A lane runs a dozen windowed suites and wants one display for all
# of them; `pgrep` is what makes the second through twelfth calls free. The six
# unguarded copies are the bug that makes: a second Xvfb on :99 races the first,
# and which one a suite's window lands on is then a matter of timing.

# The screen these pictures have always been taken on. Every sheet in this
# repository is 1024x768 and comparing a lane against last month's artifact
# assumes it stays that way, so it is named here rather than repeated.
NT_DISPLAY="${NT_DISPLAY:-:99}"
NT_SCREEN="${NT_SCREEN:-1024x768x24}"

# Bring up an X server and, unless told otherwise, a window manager.
#
# The window manager is not decoration. Half of what this suite asserts is about
# the frame -- _NET_FRAME_EXTENTS, where a move puts the title bar, whether a
# chromeless build has a border -- and none of it exists without something to
# draw one. metacity and openbox are both here because they disagree about
# reparenting, which verify-linux.sh's assert_position has a long comment about.
#
# `wm=none` is for the lanes that assert on the walk rather than on the frame.
# Whether this display answers. `pgrep Xvfb` is what the workflow used and it
# asks a different question -- is any X server running anywhere -- which is the
# same answer on a lane with one display and the wrong one everywhere else.
nt_display_answers() {
    command -v xdpyinfo >/dev/null 2>&1 || return 2
    xdpyinfo -display "$NT_DISPLAY" >/dev/null 2>&1
}

nt_display_up() {
    local wm="${1:-metacity}"
    export DISPLAY="$NT_DISPLAY"

    if nt_display_answers; then
        echo "report: display $NT_DISPLAY already up"
    elif [ "$?" = 2 ] && pgrep Xvfb >/dev/null 2>&1; then
        # No xdpyinfo to ask, so fall back to the question the workflow asked.
        echo "report: display $NT_DISPLAY assumed up (no xdpyinfo; an Xvfb is running)"
    else
        # Said rather than assumed. Every copy of this in the workflow ran Xvfb
        # unconditionally, so a lane missing it started nothing, slept three
        # seconds, and handed the suites a display that was not there -- which
        # then failed as "no window appeared", a sentence about the app.
        command -v Xvfb >/dev/null 2>&1 || {
            echo "  FAIL: no Xvfb on this lane; nothing below can open a window"
            return 1
        }
        Xvfb "$NT_DISPLAY" -screen 0 "$NT_SCREEN" >/dev/null 2>&1 &
        if command -v xdpyinfo >/dev/null 2>&1; then
            local waited=0
            while [ "$waited" -lt 30 ]; do
                nt_display_answers && break
                sleep 0.5; waited=$((waited + 1))
            done
            nt_display_answers || {
                echo "  FAIL: Xvfb was started but $NT_DISPLAY never answered"
                return 1
            }
        else
            # The workflow's own wait, kept for a lane with no xdpyinfo.
            sleep 3
        fi
        echo "report: display $NT_DISPLAY up ($NT_SCREEN)"
    fi

    case "$wm" in
        none) return 0 ;;
    esac
    # One window manager, however many suites. pgrep on the name rather than a
    # pidfile: the lane may have started it in an earlier step and this function
    # is meant to be safe to call from every one of them.
    if pgrep -x "$wm" >/dev/null 2>&1; then
        echo "report: window manager $wm already running"
    else
        command -v "$wm" >/dev/null 2>&1 || {
            echo "report: no $wm on this lane; the frame assertions have nothing to draw them"
            return 0
        }
        "$wm" >/dev/null 2>&1 &
        sleep 2
        echo "report: window manager $wm up"
    fi
}

# The knobs QtWebEngine needs on a runner with no GPU. Twelve copies in the
# workflow, and the three that matter are not obvious: software GL because there
# is no device, xcb because the lane is X11 and Qt would otherwise pick for
# itself, and a runtime dir because Qt warns and then behaves oddly without one.
nt_qt_env() {
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
    export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
    export QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS:---disable-dev-shm-usage}"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -un)}"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
}

# GTK's, for the lanes that run WebKitGTK.
nt_gtk_env() {
    export GDK_BACKEND="${GDK_BACKEND:-x11}"
}
