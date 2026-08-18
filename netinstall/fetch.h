/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifndef NT_FETCH_H
#define NT_FETCH_H

#include <stddef.h>

int nt_fetch(const char *url, const char *dest, const char *home,
             char *shown, size_t shownlen);

#endif
