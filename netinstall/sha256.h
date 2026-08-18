/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifndef NT_SHA256_H
#define NT_SHA256_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t state[8];
    uint64_t bits;
    unsigned char buf[64];
    size_t len;
} nt_sha256;

void nt_sha256_init(nt_sha256 *c);
void nt_sha256_update(nt_sha256 *c, const void *data, size_t len);
void nt_sha256_final(nt_sha256 *c, unsigned char out[32]);

#endif
