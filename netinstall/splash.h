/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifndef NT_SPLASH_H
#define NT_SPLASH_H

#include <stddef.h>

/*
 * A window saying Loading..., for the one stretch of a run that has nothing
 * else on screen: after the cache has been found empty and before the payload
 * exists to draw its own. A warm cache never reaches this -- main() sets
 * `cached` and skips the whole branch -- which is the point. The window marks a
 * download, not a launch.
 *
 * It says one word and carries nothing else. Not a decision about taste: the
 * payload's title, size and colour live inside the payload, and this runs
 * before there is a payload to read them from. Anything more would be this
 * program inventing an appearance for an app it has not downloaded yet.
 */

void nt_splash_up(void);

/*
 * Idempotent, and safe to call when nothing came up. It has to be: the paths
 * out of the fetch branch are many, main() registers this with atexit() to
 * cover them all at once, and the exec path calls it directly on top of that.
 */
void nt_splash_down(void);

/*
 * The platform half. splash.c owns everything that is the same everywhere --
 * the idempotence, the one-line description, the testing marker -- so that a
 * platform file is only the drawing, and a second platform cannot arrive at a
 * different answer about when the window is up.
 *
 * Returns 0 when something was actually drawn and -1 when nothing was, filling
 * desc either way. -1 is an ordinary answer and not a failure: a headless run,
 * a pipe, a container and a machine with no display are all correct places for
 * it, and none of them is a reason to say anything to the user. It is written
 * down rather than returned as void for the reason nt_confine reports what it
 * applied -- a launcher that cannot tell whether it drew has no way to keep a
 * probe honest, and SANDBOX ground rule 3 wants a positive control.
 */
int nt_splash_platform_up(char *desc, size_t desclen);
void nt_splash_platform_down(void);

/*
 * The platforms that have one. splash_none.c compiles itself away when this is
 * defined, which keeps the list of what can draw in one place rather than in a
 * growing chain of negations at the bottom of the fallback file.
 */
#if defined(_WIN32) || defined(__APPLE__) || defined(__linux__) || \
    defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__NetBSD__)
#define NT_SPLASH_HAVE_IMPL 1
#endif

#ifdef NT_SPLASH_HAVE_IMPL
#if defined(__linux__) || defined(__OpenBSD__) || defined(__FreeBSD__) || \
    defined(__NetBSD__)

/*
 * The X11 half, in two pieces either side of a fork.
 *
 * nt_splash_x11_up does everything up to and including the first draw and runs
 * in the parent, which is the whole reason this is split where it is: the
 * caller learns whether a window actually exists from a function that has
 * already made it, instead of from a fork whose child cannot report back
 * without a pipe and a deadline. Returns the connection, or -1 with desc saying
 * which step declined.
 *
 * nt_splash_x11_serve then runs in the child and never returns. It exists
 * because a window that nobody redraws is a window that goes blank the first
 * time anything passes over it, and the parent spends the next two minutes
 * blocked in waitpid on curl.
 */
int nt_splash_x11_up(char *desc, size_t desclen);
void nt_splash_x11_serve(int fd);

/* The same split, for the compositor. See splash_wayland.c for why this one
 * carries its own glyphs and the X11 one does not. */
int nt_splash_wayland_up(char *desc, size_t desclen);
void nt_splash_wayland_serve(int fd);

#endif

#ifdef __APPLE__
/*
 * The other side of the re-exec. AppKit is usable only from a process's main
 * thread, and this program's main thread is the one that blocks on the
 * download -- so on macOS the window is drawn by a second copy of this binary,
 * started with --splash, and this is what that copy runs instead of installing
 * anything. It does not return.
 *
 * deathfd is the read end of a pipe the parent holds open. Reading end-of-file
 * on it means the parent is gone; macOS has no PR_SET_PDEATHSIG, and this is
 * what stands in for it.
 *
 * readyfd is the write end of the other one. A single byte on it says the
 * window is on screen, and closing it without writing -- which every failure
 * here does by exiting -- says it never will be. Without it the parent can only
 * report that it started a process, which is not the thing it is being asked.
 */
int nt_splash_macos_child(int deathfd, int readyfd);
#endif

#endif

#endif
