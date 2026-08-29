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

/*
 * Thirty-two hex characters, not sixteen. Sixteen is 64 bits, which puts a
 * second preimage out of reach and does not touch the attack that matters when
 * you did not build what you are pinning: a publisher grinding two files to one
 * truncated digest, benign to get pinned and hostile to serve, at about 2^32.
 * The README recommended 32 for exactly that while the parser accepted 16, so
 * the safe length was advice and the floor was the length it argued against.
 */
#define NT_TOKEN_MIN 32

/*
 * The stem an even shape takes when the name does not carry one. It is what
 * makes `alganet-dev-0<pin>` a whole spec, and it is the launcher's own name
 * rather than the toolkit's: the file being fetched is the thing netinstall
 * knows how to run.
 */
#define NT_DEFAULT_STEM "netinstall"
#define NT_MAX_PAYLOAD (16 * 1024 * 1024)

/*
 * What a downloader appended to a name that was already on disk, kept so the
 * caller can say which file it is actually running. Bounded well under the
 * shapes anyone produces -- "(1)", " (1)", " copy", " 2" -- because a longer
 * tail is not decoration and is left on the name to fail parsing as it should.
 */
#define NT_DECOR_MAX 16

typedef struct {
    char spec[NT_SPEC_MAX];
    char app[NT_SPEC_MAX];
    char name[NT_NAME_MAX];
    char dir[NT_NAME_MAX];
    char host[NT_HOST_MAX];
    char token[NT_TOKEN_MAX];
    char url[NT_PATH_MAX];
    /* Empty unless the name carried a downloader's suffix. See nt_trim_decor. */
    char decor[NT_DECOR_MAX];
} nt_spec;

/* `why`, when not NULL, is filled with the reason a token was refused. */
int nt_parse_name(const char *base, nt_spec *out, char *why, size_t whylen);
int nt_self_path(char *buf, size_t len, const char *argv0);
const char *nt_basename(const char *path);

int nt_home(char *buf, size_t len);
int nt_mkdir_p(const char *path);

int nt_sha256_file(const char *path, char *hex65);
int nt_is_text(const char *path);

#ifndef _WIN32
/* Leaves only 0, 1 and 2 open, so nothing the caller had open reaches the app. */
void nt_close_inherited(void);
#else
/* Runs a program to completion and returns its exit code. Replaces _spawnv,
 * which cannot express which handles a child inherits. */
int nt_win_spawn(const char *exe, char *const *args);
/*
 * The same, under a token the caller derived. void * rather than HANDLE so this
 * header stays free of windows.h; NULL is exactly nt_win_spawn. The fetch phase
 * is the one caller: a process may never raise its own integrity back, and
 * everything after the download -- the digest, the app directory, the hard link
 * -- is work at the launcher's own level, so the tight tier's confinement has
 * to reach the child alone.
 */
int nt_win_spawn_as(const char *exe, char *const *args, void *token);
#endif

#endif
