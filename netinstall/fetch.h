/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifndef NT_FETCH_H
#define NT_FETCH_H

#include <stddef.h>

/*
 * Returns 0 on success, -1 when the download failed, and -2 when it was
 * refused: a strict build with nothing to confine the downloader with, a host
 * that sent more than NT_MAX_PAYLOAD, or a host that held the transfer open
 * past the deadline. Every -2 has already been explained on stderr, in terms
 * the generic "fetch failed" line cannot improve on.
 */
int nt_fetch(const char *url, const char *dest, const char *home,
             char *shown, size_t shownlen);

/*
 * Builds the command that a fetch would run, without running it. `bounds`, when
 * not NULL, is filled with the size and time limits in force -- which on the
 * wget branch are imposed by the kernel and appear nowhere in `shown`.
 *
 * `config`, when not NULL, is filled with what the downloader reads *besides*
 * the argv in `shown`. Both downloaders read a configuration file, deliberately
 * -- see the trust model in README.md -- and neither is told not to. So `shown`
 * is the command this program builds and not the whole command that runs, and
 * a --info that printed only the first was making a claim a file can add to.
 */
int nt_fetch_command(const char *url, const char *dest, char *shown,
                     size_t shownlen, char *bounds, size_t boundslen,
                     char *config, size_t configlen);

#endif
