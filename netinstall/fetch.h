/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifndef NT_FETCH_H
#define NT_FETCH_H

#include <stddef.h>

/*
 * Returns 0 on success, -1 when the download failed, and -2 when it was refused
 * before it started -- a strict build with nothing to confine the downloader
 * with. The refusal has already been explained on stderr, in terms the generic
 * "fetch failed" line cannot improve on.
 */
int nt_fetch(const char *url, const char *dest, const char *home,
             char *shown, size_t shownlen);

/* Builds the command that a fetch would run, without running it. */
int nt_fetch_command(const char *url, const char *dest, char *shown, size_t shownlen);

#endif
