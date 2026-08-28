/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include "splash.h"

#if defined(__linux__) || defined(__OpenBSD__) || defined(__FreeBSD__) || \
    defined(__NetBSD__)

/*
 * The half of the splash that is the same whichever display server answered:
 * choosing one, forking the process that keeps the window alive, and killing it
 * again.
 *
 * The fork is not an implementation detail that could have gone either way.
 * Between nt_splash_up and nt_splash_down this program is blocked in waitpid on
 * a downloader it allows up to two minutes, and neither display protocol
 * tolerates a client that stops reading its socket for that long -- X11 goes
 * blank the first time anything passes over the window, and a wayland
 * compositor kills a surface whose client stops answering ping. So the window
 * needs a process whose whole job is to answer, and this program's own is to
 * wait on curl.
 *
 * What is deliberately *not* forked is the part that decides whether a window
 * exists at all. Everything up to and including the first draw happens here, in
 * the parent, so that nt_splash_platform_up can answer from work it did rather
 * than from a child it would otherwise have to interrogate through a pipe and a
 * deadline. The child inherits a connection that is already working.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/prctl.h>
#endif

static pid_t nt_splash_pid = -1;
/* Which of the two the connection speaks, so the child services the right one. */
static int nt_splash_wayland = 0;

int nt_splash_platform_up(char *desc, size_t desclen)
{
    int fd = -1;
    pid_t pid;

    /*
     * Wayland first where there is one. A session running XWayland sets both
     * WAYLAND_DISPLAY and DISPLAY, and taking the X path there would draw
     * through a compatibility layer to reach the same compositor this can talk
     * to directly -- so the presence of DISPLAY says nothing about which is the
     * native one, and only WAYLAND_DISPLAY does.
     *
     * X11 is the fallback and not the lesser path: it is the only one on an
     * ordinary X session, and the only one on a compositor with no xdg_wm_base.
     */
    nt_splash_wayland = 0;
    if (getenv("WAYLAND_DISPLAY")) {
        fd = nt_splash_wayland_up(desc, desclen);
        if (fd >= 0) {
            nt_splash_wayland = 1;
        }
    }
    if (fd < 0) {
        fd = nt_splash_x11_up(desc, desclen);
    }
    if (fd < 0) {
        return -1;
    }

    pid = fork();
    if (pid < 0) {
        /*
         * The window is up and there is nobody to keep it. Take it down by
         * closing the connection -- the server frees everything the connection
         * owned -- rather than leave a window that will go blank and never
         * recover, which is a worse artifact than no window at all.
         */
        close(fd);
        snprintf(desc, desclen, "none (cannot fork a process to hold the window)");
        return -1;
    }
    if (pid == 0) {
#ifdef __linux__
        /*
         * If this program dies without tearing the window down -- a crash, a
         * kill -9, anything that runs no handler -- the window would otherwise
         * outlive it with nobody holding the pid that could remove it. This is
         * the only mechanism that covers that case, and it is why the suite's
         * orphan check is a check and not a note.
         *
         * It does not cover the ordinary exit into the payload: execv keeps the
         * pid, so the parent never dies and no signal is sent. That path is
         * covered by the explicit nt_splash_down before nt_exec.
         */
        prctl(PR_SET_PDEATHSIG, SIGKILL);
        /*
         * ...and if the parent died between the fork and the prctl, the signal
         * that was going to arrive already has. Checking afterwards is the only
         * way to close that window.
         */
        if (getppid() == 1) {
            _exit(0);
        }
#endif
        /*
         * A dead socket must end this process, not deliver a signal it has no
         * handler for -- nt_splash_x11_serve reads the write error and exits on
         * it, which it can only do if SIGPIPE is not fatal first.
         */
        signal(SIGPIPE, SIG_IGN);
        /*
         * The three the caller gave this program, which this child has no use
         * for and must not keep. A netinstall on the write end of a pipe is the
         * case that makes it matter: the reader sees end-of-file when the last
         * writer closes, so a splash child still holding stdout keeps
         * `netinstall | anything` alive for as long as the window is up.
         * Measured, before this line existed: the payload had run, the launcher
         * had exited, and the pipeline sat there.
         *
         * Redirected rather than closed. A descriptor that is merely closed
         * leaves 0, 1 and 2 free for the next open() to claim, and the next
         * open() here is inside the X code -- which would then be writing the
         * protocol into whatever the caller thought stdout was.
         */
        /*
         * ...but only after the connection is out of their way. A caller that
         * ran this with stdin closed -- `netinstall 0<&-` -- hands socket() the
         * number 0, and the redirect below would then close the very thing this
         * child exists to hold.
         */
        while (fd <= 2) {
            int higher = dup(fd);

            if (higher < 0) {
                _exit(0);
            }
            close(fd);
            fd = higher;
        }
        {
            int devnull = open("/dev/null", O_RDWR);

            if (devnull >= 0) {
                dup2(devnull, 0);
                dup2(devnull, 1);
                dup2(devnull, 2);
                if (devnull > 2) {
                    close(devnull);
                }
            }
        }
        if (nt_splash_wayland) {
            nt_splash_wayland_serve(fd);
        } else {
            nt_splash_x11_serve(fd);
        }
        _exit(0);
    }

    /*
     * The parent's copy goes away so that the child's is the only one left. The
     * connection stays open on the strength of the child's descriptor alone,
     * which is what makes killing the child sufficient to destroy the window --
     * no DestroyWindow, no close handshake, nothing this has to get right on a
     * path where it is already giving up.
     */
    close(fd);
    nt_splash_pid = pid;
    return 0;
}

void nt_splash_platform_down(void)
{
    int status;

    if (nt_splash_pid <= 0) {
        return;
    }
    kill(nt_splash_pid, SIGKILL);
    /*
     * Reaped, and not merely signalled. Without this the child is a zombie for
     * as long as this process lives, which on the ordinary path is until execv
     * -- but on windows-shaped control flow, and on any failure that returns
     * through main, it is longer. A launcher that leaves a defunct process
     * behind it is a launcher someone will eventually have to explain.
     */
    while (waitpid(nt_splash_pid, &status, 0) < 0 && errno == EINTR) {
        /* again */
    }
    nt_splash_pid = -1;
}

#endif
