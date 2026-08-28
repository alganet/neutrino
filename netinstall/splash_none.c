/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include <stdio.h>

#include "splash.h"

#ifndef NT_SPLASH_HAVE_IMPL

/*
 * The platforms with no way in yet. Says the same sentence sandbox_none.c says,
 * for the same reason: "nothing happened" and "nothing could happen here" are
 * different findings, and a probe that cannot tell them apart passes on both.
 */
int nt_splash_platform_up(char *desc, size_t desclen)
{
    snprintf(desc, desclen, "none (unsupported platform)");
    return -1;
}

void nt_splash_platform_down(void)
{
}

#endif
