/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifndef NT_SPLASH_H
#define NT_SPLASH_H

#include <stddef.h>

/*
 * A window with a moving indicator in it, for the one stretch of a run that has
 * nothing else on screen: after the cache has been found empty and before the
 * payload exists to draw its own. A warm cache never reaches this -- main()
 * sets `cached` and skips the whole branch -- which is the point. The window
 * marks a download, not a launch.
 *
 * It carries no words, and that is a decision this file should defend rather
 * than leave to be rediscovered. It said "Loading..." for its first rounds, and
 * two things were wrong with that at once. The first is language: a launcher
 * that has not yet downloaded anything has nothing to read a locale out of --
 * no payload, no manifest, no preference -- so the word could only ever be
 * English, and shipping one language to everybody is a choice the rest of this
 * program does not make anywhere else. The second is the font. Five platforms
 * drew that word five ways -- the X server's `fixed`, a bitmap table compiled
 * into this binary for wayland, DEFAULT_GUI_FONT on windows, whatever
 * NSTextField picked on macOS -- and the sheets show it: four lanes
 * photographing the same feature and no two pictures alike. Neither problem has
 * a fix that is worth the code. A run of blocks that moves has neither: it
 * belongs to no language, and it is rectangles, which every one of the four
 * that can draw at all puts on a screen at exactly the same size.
 *
 * The payload's title, size and colour still live inside the payload and are
 * still not guessed at here. Anything more than this would be the program
 * inventing an appearance for an app it has not downloaded yet.
 *
 * Two numbers keep it from blinking. It is not raised until the download has
 * been running NT_SPLASH_DELAY_MS -- a fetch that finishes inside that, which
 * a small payload from a near host does, never gets a window at all. And once
 * raised it stays up NT_SPLASH_HOLD_MS at the least, so a download that
 * crossed the first line by a few milliseconds is not a window that appears
 * and is gone before the eye has settled on it. Both are about the same thing
 * from opposite sides: a window that is on screen for less time than it takes
 * to read is not information, it is a flash.
 *
 * The lifecycle is three calls. nt_splash_arm says a download is starting and
 * a window is wanted if it turns out to be worth one; nt_splash_up is what
 * the fetch calls at NT_SPLASH_DELAY_MS if it is still waiting; and
 * nt_splash_down takes the window away, sleeping out the rest of the hold
 * first. The delay is the fetch's to measure because the wait is the fetch's
 * own -- see fetch.h -- and the hold is this module's because it is the same
 * on every platform and about nothing but the window.
 */
#define NT_SPLASH_DELAY_MS 100L
#define NT_SPLASH_HOLD_MS 400L

/*
 * What is drawn, to the pixel, in one place because five files draw it. Every
 * number below is used by all of them: the window is the same size on X11, on
 * wayland, on windows and on macOS, the track sits in the same place inside it,
 * and the cells are the same cells. That is not tidiness. The four lanes that
 * photograph this window publish their pictures into the same sheet format, and
 * a reader comparing them is trying to see a difference between platforms --
 * which is only possible if everything that is *not* a difference between
 * platforms has been made identical here rather than four times over.
 *
 * The track is NT_SPLASH_CELLS cells of NT_SPLASH_CELL_W by NT_SPLASH_CELL_H
 * with NT_SPLASH_GAP between them, centred in the window; NT_SPLASH_LIT of them
 * are dark at any moment, and which ones moves by one cell every
 * NT_SPLASH_FRAME_MS, wrapping. It says nothing about how far along the
 * download is, and must not: this program learns the size of what it is
 * fetching from a header it does not require and does not check, so a bar that
 * claimed a fraction would be claiming one it cannot know. What it says is that
 * something is still happening, which is the only thing this window has ever
 * had to say.
 */
#define NT_SPLASH_WIDTH 260
#define NT_SPLASH_HEIGHT 96
#define NT_SPLASH_CELLS 12
#define NT_SPLASH_CELL_W 12
#define NT_SPLASH_CELL_H 12
#define NT_SPLASH_GAP 6
#define NT_SPLASH_LIT 3
#define NT_SPLASH_FRAME_MS 90L

#define NT_SPLASH_TRACK_W \
    (NT_SPLASH_CELLS * NT_SPLASH_CELL_W + (NT_SPLASH_CELLS - 1) * NT_SPLASH_GAP)
#define NT_SPLASH_TRACK_X ((NT_SPLASH_WIDTH - NT_SPLASH_TRACK_W) / 2)
#define NT_SPLASH_TRACK_Y ((NT_SPLASH_HEIGHT - NT_SPLASH_CELL_H) / 2)
#define NT_SPLASH_CELL_X(i) \
    (NT_SPLASH_TRACK_X + (i) * (NT_SPLASH_CELL_W + NT_SPLASH_GAP))

/*
 * The colours, as 0xRRGGBB, which is the one spelling none of the four
 * platforms wants: X11 needs a pixel value allocated out of a colormap, wayland
 * wants 0x00RRGGBB in a mapped buffer, windows wants a COLORREF, which is the
 * bytes the other way round, and AppKit wants three doubles. Written once in
 * the neutral form and converted at each of the four, rather than four literals
 * that would drift apart the first time one of them was adjusted.
 *
 * A light window with dark cells, and not the reverse, because it is raised
 * over whatever the user was already looking at and the payload has not chosen
 * a palette yet. This is also why the dim cells are drawn at all rather than
 * left as background: the track shows how long the thing is, so a still frame
 * of it -- which is what a CI sheet has -- still reads as an indicator rather
 * than as three squares somebody left on the screen.
 */
#define NT_SPLASH_RGB_BG  0xffffffUL
#define NT_SPLASH_RGB_DIM 0xc8c8c8UL
#define NT_SPLASH_RGB_LIT 0x202020UL

/*
 * The one-pixel edge, which is the same dark as a lit cell on purpose: a third
 * colour would mean a third pixel value to allocate on X11 and a third brush on
 * windows, for a line nobody is going to look at twice.
 *
 * It is drawn by each platform inside the window rather than asked of the
 * system, and that is the point of it. X11 had a border-width of 1 and windows
 * had WS_BORDER -- two edges of different widths in two colours neither file
 * chose -- while macOS had none and the compositor decides on wayland. A line
 * this file draws is a line all four have.
 */
#define NT_SPLASH_RGB_EDGE NT_SPLASH_RGB_LIT

#define NT_SPLASH_R(c) ((int)(((c) >> 16) & 0xff))
#define NT_SPLASH_G(c) ((int)(((c) >> 8) & 0xff))
#define NT_SPLASH_B(c) ((int)((c) & 0xff))

/*
 * Whether cell `cell` is one of the dark ones at phase `phase`. In splash.c and
 * not a macro here for the reason the geometry is not four copies: it is the
 * whole of what the animation *is*, and a platform that got the wrap wrong by
 * one would be a platform whose window moves differently for no reason a reader
 * of the pictures could name.
 */
int nt_splash_cell_lit(int phase, int cell);

void nt_splash_arm(void);
void nt_splash_up(void);

/*
 * Idempotent, and safe to call when nothing came up. It has to be: the paths
 * out of the fetch branch are many, main() registers this with atexit() to
 * cover them all at once, and the exec path calls it directly on top of that.
 *
 * Blocks for whatever is left of the hold when a window is up. A testing build
 * reads NEUTRINO_SPLASH_HOLD_MS to lengthen that -- it is how the suite keeps
 * the window still for a photograph, and how a person can look at the thing
 * for longer than four hundred milliseconds -- and a release binary reads
 * nothing.
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

/* The same split, for the compositor. Symmetrical now that there is no text in
 * the window: both files send rectangles, and the difference between them is
 * only that one asks a server to fill them and the other fills them itself.
 * See splash_wayland.c. */
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
