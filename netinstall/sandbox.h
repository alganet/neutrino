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
 * summary into desc. Returns 0 when everything asked for applied and -1 when it
 * did not. The caller decides whether -1 is fatal.
 *
 * It used to return -2 and -3 as well, for a confinement that partly applied
 * and for one that left a process nothing should be launched into. Both
 * belonged to the linux session tier, which was the one mechanism here built
 * out of steps that could fail separately after the first had already changed
 * the process. Nothing left has that shape: every platform now applies its
 * confinement in a call that either takes or does not.
 */
/*
 * With enforce zero this only describes what would be applied, changing
 * nothing, so --info can report accurately without side effects.
 */
int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen);

#ifdef _WIN32
/*
 * The windows fetch phase, which is the one confinement here that
 * cannot be applied to the process asking for it. Everything else in this file
 * changes the caller; a low integrity token can only change a child, because
 * integrity is a one-way trip and the digest, the app directory and the hard
 * link all happen after the download returns.
 *
 * So it is spread over three calls that the fetch phase makes in order:
 * nt_confine builds the token, nt_fetch_grant opens the one file the downloader
 * is allowed to write, and nt_fetch_revoke closes it again before anything
 * hashes it.
 *
 * Measured on windows-latest: a Low label on the payload file is the narrowest
 * grant a lowered child can download through, and the label has to come back
 * off before the digest -- while it is on, any low integrity process on the
 * machine can rewrite that file, and nothing re-reads it between the digest and
 * the rename. Labelling the blobs *directory* instead is inadmissible for a
 * second reason: nt_link_or_copy commits with CreateHardLink, and a hard link
 * is a second name for one file object, so the label reaches the script nt_exec
 * runs.
 */
/* The token the downloader is spawned under, or NULL for "the caller's own". */
void *nt_fetch_token(void);
/* Creates dest and makes it the one thing that token may write. 0 on failure. */
int nt_fetch_grant(const char *dest);
/*
 * Takes it back. Must run before dest is hashed, not merely before it is used,
 * and answers rather than returning void: a payload that could not be taken
 * back from low integrity is a digest checked against content that can still
 * change, which is not a thing to continue past.
 */
int nt_fetch_revoke(const char *dest);
#endif

#endif
