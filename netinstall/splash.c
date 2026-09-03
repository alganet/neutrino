/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include <stdio.h>
#include <stdlib.h>

#include "netinstall.h"
#include "splash.h"

/*
 * Where the window is in its life, and the only state here. Four places:
 * nothing wanted; a download running and a window wanted if it turns out to
 * be slow; a window on screen; and a window asked for and declined, which is
 * kept apart from the first so that the teardown does not sleep out a hold
 * for a window that never existed.
 *
 * It is what lets nt_splash_down be called twice in one run without a
 * platform file having to notice: netinstall.c takes the window down the
 * moment the fetch returns, and also registers the same function with atexit
 * as a net for the failure paths above that line. Whichever runs first does
 * the work and the other returns.
 */
enum { NT_SPLASH_IDLE, NT_SPLASH_ARMED, NT_SPLASH_UP, NT_SPLASH_DECLINED };
static int nt_splash_state = NT_SPLASH_IDLE;
static char nt_splash_desc[128];
/* When the download started and when the window came up, on nt_now_ms. */
static long nt_splash_armed_at;
static long nt_splash_up_at;

/*
 * How long the window has to stay once it is up. The default is the constant;
 * a testing build lets the environment raise it, and only raise it -- a
 * value under the constant is the constant, because the one thing the knob
 * must not be able to do is put the blink back for a run that has it set to
 * zero by accident. Absent from a release binary altogether: it reads no
 * environment it did not ship with a reason for.
 */
static long nt_splash_hold_ms(void)
{
#ifdef NEUTRINO_TESTING
    const char *v = getenv("NEUTRINO_SPLASH_HOLD_MS");

    if (v && *v) {
        char *end;
        long ms = strtol(v, &end, 10);

        if (*end == '\0' && ms > NT_SPLASH_HOLD_MS) {
            return ms;
        }
    }
#endif
    return NT_SPLASH_HOLD_MS;
}

/*
 * The lifecycle, narrated for the one suite that asserts it, and silent for
 * every other. Under NEUTRINO_TESTING alone this wrote three lines to stderr on
 * every run, which is a stream other suites read positionally -- fetchbound
 * takes the last line of a refused download and compares it, and found
 * "splash: down" sitting under the message it was looking for. A diagnostic
 * that displaces the diagnostics is not instrumentation, it is noise.
 *
 * So it is opt-in twice over: absent from any binary not built for testing, and
 * quiet in those unless the suite that wants it asks. It changes nothing either
 * way -- there is no behaviour behind this, only whether a line is printed.
 */
#ifdef NEUTRINO_TESTING
static int nt_splash_tracing(void)
{
    static int known = -1;

    if (known < 0) {
        const char *v = getenv("NEUTRINO_SPLASH_TRACE");

        known = v && *v ? 1 : 0;
    }
    return known;
}
#define NT_SPLASH_TRACE(...) \
    do { if (nt_splash_tracing()) { fprintf(stderr, __VA_ARGS__); } } while (0)
#else
#define NT_SPLASH_TRACE(...) do { } while (0)
#endif

void nt_splash_arm(void)
{
    if (nt_splash_state != NT_SPLASH_IDLE) {
        return;
    }
    nt_splash_state = NT_SPLASH_ARMED;
    nt_splash_armed_at = nt_now_ms();
    NT_SPLASH_TRACE("netinstall: splash: armed\n");
}

void nt_splash_up(void)
{
    /*
     * Only from armed. A caller that never said a download was starting has
     * no business with a window, and a second call on top of a window that is
     * already up -- or was already declined -- is the idempotence the header
     * promises.
     */
    if (nt_splash_state != NT_SPLASH_ARMED) {
        return;
    }
    nt_splash_desc[0] = '\0';
    if (nt_splash_platform_up(nt_splash_desc, sizeof(nt_splash_desc)) != 0) {
        /*
         * Nothing was drawn, and nothing is said about it. The absence is
         * correct on every headless path, and a program that announced its
         * inability to decorate a download would be noisiest exactly where the
         * silence was right.
         */
        nt_splash_state = NT_SPLASH_DECLINED;
        NT_SPLASH_TRACE("netinstall: splash: none: %s\n", nt_splash_desc);
        return;
    }
    nt_splash_state = NT_SPLASH_UP;
    nt_splash_up_at = nt_now_ms();
    NT_SPLASH_TRACE("netinstall: splash: up: %s\n", nt_splash_desc);
}

void nt_splash_down(void)
{
    long held;

    switch (nt_splash_state) {
    case NT_SPLASH_UP:
        break;
    case NT_SPLASH_ARMED:
        /*
         * The download finished before the window was due. Nothing to take
         * down, and the one thing worth saying -- to the suite, which is the
         * only listener -- is how long that took, since it is the number the
         * delay was chosen against.
         */
        nt_splash_state = NT_SPLASH_IDLE;
        NT_SPLASH_TRACE("netinstall: splash: unneeded (the download took %ldms)\n",
                        nt_now_ms() - nt_splash_armed_at);
        return;
    default:
        nt_splash_state = NT_SPLASH_IDLE;
        return;
    }
    /*
     * The rest of the hold, slept here rather than anywhere cleverer. This is
     * the only function that knows both when the window came up and that it
     * is about to go, and the caller is a launcher with nothing else to do in
     * the meantime -- the payload is on disk, verified, and can wait the
     * quarter second a person needs to see what was on screen.
     */
    held = nt_now_ms() - nt_splash_up_at;
    if (held < nt_splash_hold_ms()) {
        nt_sleep_ms(nt_splash_hold_ms() - held);
        held = nt_now_ms() - nt_splash_up_at;
    }
    nt_splash_platform_down();
    nt_splash_state = NT_SPLASH_IDLE;
    NT_SPLASH_TRACE("netinstall: splash: down (held %ldms)\n", held);
}
