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
 * summary into desc. Returns 0 when everything asked for applied, -1 when
 * nothing was available, -2 when part of it did -- a different sentence and,
 * for a strict build, the same answer -- and -3 when part of it did and what is
 * left is a process nothing should be launched into. The caller decides whether
 * -1 and -2 are fatal. -3 is fatal in every build.
 *
 * Only the linux session tier can answer -2 or -3, and only for the run phase:
 * it is the one mechanism here built out of steps that can fail separately
 * after the first one has already changed the process.
 */
/*
 * With enforce zero this only describes what would be applied, changing
 * nothing, so --info can report accurately without side effects.
 */
int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen);

#endif
