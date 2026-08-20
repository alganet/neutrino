/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifndef NT_ENV_H
#define NT_ENV_H

/*
 * Reduces the environment the app inherits to a fixed allowlist. With enforce
 * zero nothing is changed and only the counts are reported, so --info can
 * describe it without side effects.
 *
 * Returns the number of variables dropped, and writes the number seen into
 * total when it is not NULL.
 */
int nt_env_scrub(int enforce, int *total);

#endif
