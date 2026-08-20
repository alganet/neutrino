/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifndef NETINSTALL_H
#define NETINSTALL_H

#include <stddef.h>

#define NT_VERSION "0.1.0"

#define NT_NAME_MAX 256
#define NT_HOST_MAX 256
#define NT_TOKEN_MAX 128
#define NT_SPEC_MAX 512
#define NT_PATH_MAX 4096

#define NT_TOKEN_MIN 16
#define NT_MAX_PAYLOAD (16 * 1024 * 1024)

typedef struct {
    char spec[NT_SPEC_MAX];
    char app[NT_SPEC_MAX];
    char name[NT_NAME_MAX];
    char host[NT_HOST_MAX];
    char token[NT_TOKEN_MAX];
    char url[NT_PATH_MAX];
} nt_spec;

int nt_parse_name(const char *base, nt_spec *out);
int nt_self_path(char *buf, size_t len, const char *argv0);
const char *nt_basename(const char *path);

int nt_home(char *buf, size_t len);
int nt_mkdir_p(const char *path);

int nt_sha256_file(const char *path, char *hex65);
int nt_is_text(const char *path);

#ifndef _WIN32
/* Leaves only 0, 1 and 2 open, so nothing the caller had open reaches the app. */
void nt_close_inherited(void);
#endif

#endif
