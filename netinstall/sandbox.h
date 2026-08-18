/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifndef NT_SANDBOX_H
#define NT_SANDBOX_H

#include <stddef.h>

typedef enum {
    NT_PHASE_FETCH,
    NT_PHASE_RUN
} nt_phase;

/*
 * Applies the platform confinement for the phase and writes a human-readable
 * summary into desc. Returns 0 when something was applied, -1 when nothing
 * was available; the caller decides whether that is fatal.
 */
int nt_confine(nt_phase phase, const char *home, const char *appdir,
               char *desc, size_t desclen);

#endif
