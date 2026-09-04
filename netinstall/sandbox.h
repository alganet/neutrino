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
 * Windows confines a child rather than the caller, in both phases. Everything
 * else in this file changes the process that asks; a low integrity token can
 * only change a child, because integrity is a one-way trip and both phases have
 * work left at their own level afterwards -- the fetch has the digest, the app
 * directory and the hard link, and the run phase has a build slot label to take
 * back off when the .cmd returns.
 *
 * So each phase is spread over calls it makes in order: nt_confine builds the
 * token, a grant opens the one place the child is allowed to write, and a
 * revoke closes it again before anything trusts what is there. nt_confine
 * leaves the token where the phase's consumer can pick it up -- nt_fetch_token
 * for the downloader, nt_run_token for the payload -- because threading a
 * handle through nt_confine's signature would put a windows type in a header
 * three other platforms include.
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
/* The same for the payload. NULL only where nt_confine already answered -1. */
void *nt_run_token(void);
/* Creates dest and makes it the one thing that token may write. 0 on failure. */
int nt_fetch_grant(const char *dest);
/*
 * Takes it back. Must run before dest is hashed, not merely before it is used,
 * and answers rather than returning void: a payload that could not be taken
 * back from low integrity is a digest checked against content that can still
 * change, which is not a thing to continue past.
 */
int nt_fetch_revoke(const char *dest);

/*
 * The run phase's pair, and the shape is the fetch's with two differences that
 * are both in sandbox_win.c beside the code.
 *
 * The grant is a *directory*, because the launcher rotates its exe through
 * random names and windows will rename a running image but not overwrite one.
 * And a grant that fails is not a refusal: the slot is a relaxation, so a
 * launch without one is more confined rather than less, and the caller carries
 * on with a launcher that compiles every launch as it did before.
 *
 * The revoke must run before anything records what is in the slot -- the same
 * rule as the fetch's, for the same reason -- and it clears the label from
 * every entry as well as from the container, because the grant is inheritable.
 */
int nt_build_grant(const char *slot);
int nt_build_revoke(const char *slot);
/*
 * Tells the run phase's sentence what to name. Called before nt_confine on
 * every windows launch, describing or enforcing, so that --info's confine line
 * and the warning a user reads are conditional on the same answer the launch
 * itself acts on. A sealed launch's sentence is unchanged, to the byte.
 */
void nt_build_slot(const char *slot, int owed);
#endif

#endif
