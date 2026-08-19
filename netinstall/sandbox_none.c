/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#if !defined(__linux__) && !defined(__APPLE__) && !defined(_WIN32) && \
    !defined(__OpenBSD__) && !defined(__FreeBSD__) && !defined(__NetBSD__)

#include <stdio.h>

#include "sandbox.h"

int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen)
{
    (void)phase;
    (void)home;
    (void)appdir;
    (void)enforce;
    snprintf(desc, desclen, "none (unsupported platform)");
    return -1;
}

#endif
