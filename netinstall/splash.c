/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include <stdio.h>
#include <stdlib.h>

#include "splash.h"

/*
 * Whether the platform half is holding a window, and the only state here. It is
 * what lets nt_splash_down be called twice in one run without a platform file
 * having to notice: netinstall.c takes the window down the moment the fetch
 * returns, and also registers the same function with atexit as a net for the
 * failure paths above that line. Whichever runs first does the work and the
 * other returns.
 */
static int nt_splash_is_up = 0;
static char nt_splash_desc[128];

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

void nt_splash_up(void)
{
    if (nt_splash_is_up) {
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
        NT_SPLASH_TRACE("netinstall: splash: none: %s\n", nt_splash_desc);
        return;
    }
    nt_splash_is_up = 1;
    NT_SPLASH_TRACE("netinstall: splash: up: %s\n", nt_splash_desc);
}

void nt_splash_down(void)
{
    if (!nt_splash_is_up) {
        return;
    }
    nt_splash_platform_down();
    nt_splash_is_up = 0;
    NT_SPLASH_TRACE("netinstall: splash: down\n");
}
