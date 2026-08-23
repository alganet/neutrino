/*
 * envlen-probe.c - the environments a shell cannot build
 *
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 *
 * envlen.sh asks four questions of the platform and two of them cannot be asked
 * from a shell. env(1) will not set a name with no characters in it, and no
 * shell will hand a child an environ it did not build out of assignments -- so
 * the empty-name entry and the wholesale replacement both need a program that
 * writes the array itself.
 *
 * Modes:
 *
 *   emit                      one line per entry: its name length and the first
 *                             32 characters of the name. The instrument for
 *                             "how long a name does this platform deliver".
 *   unsetlen <n>              set a name of n characters, confirm it is there,
 *                             remove it, confirm it is gone. Says whether a fix
 *                             that stops truncating would work on this libc.
 *   craft <empty|none> <prog> [args...]
 *                             execv prog with this process's environ, with an
 *                             entry whose name is empty inserted at the front
 *                             (or not, which is the control).
 *   replace <prog> [args...]  assign a filtered array to environ and execv, so
 *                             the alternative fix -- build a new environment
 *                             rather than unset names one at a time -- can be
 *                             measured rather than assumed portable.
 *   setafter <prog> [args...] the same, and then four setenv calls on top of
 *                             the assigned array. netinstall does exactly that
 *                             -- nt_env_scrub(1) and then five setenv_dir calls
 *                             for the XDG directories -- so whether this libc
 *                             lets a caller grow an environ it did not
 *                             allocate is what decides whether that fix is
 *                             available at all.
 *   stability                 remove an entry from the middle and report
 *                             whether the entries in front of it are still the
 *                             same names in the same order. The other fix --
 *                             keep unsetenv, advance past what cannot be
 *                             removed -- needs a count of already-examined
 *                             leading entries to stay meaningful across a
 *                             removal, and that is not something POSIX
 *                             promises.
 *
 * craft and replace are POSIX only and say so on windows: the windows scrub
 * walks a copy of the block and skips '='-led entries by name, so neither
 * question exists there.
 */

/*
 * envlen.sh builds this with a bare `cc -o`, so nothing on the command line
 * declares setenv, unsetenv or execv. Asked for here instead: unlike
 * netinstall's own build this file touches no BSD extension, so the macro that
 * hides unveil and pledge on OpenBSD costs it nothing.
 */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
extern char **environ;
#endif

#define NT_EMIT_SHOWN 32

static void nt_emit_one(const char *entry)
{
    const char *eq = strchr(entry, '=');
    size_t namelen = eq ? (size_t)(eq - entry) : strlen(entry);
    char shown[NT_EMIT_SHOWN + 1];
    size_t n = namelen < NT_EMIT_SHOWN ? namelen : NT_EMIT_SHOWN;

    memcpy(shown, entry, n);
    shown[n] = '\0';
    printf("envlen name %lu %s\n", (unsigned long)namelen, shown);
}

static int nt_emit(void)
{
#ifdef _WIN32
    char *block = GetEnvironmentStringsA();
    char *p;

    if (!block) {
        printf("envlen emit NOBLOCK\n");
        return 1;
    }
    for (p = block; *p; p += strlen(p) + 1) {
        nt_emit_one(p);
    }
    FreeEnvironmentStringsA(block);
#else
    int i;

    for (i = 0; environ[i]; i++) {
        nt_emit_one(environ[i]);
    }
#endif
    printf("envlen emit END\n");
    return 0;
}

/*
 * A name of exactly n characters, all of them valid in a shell identifier so
 * the same name can be asked for from the payload side.
 */
static char *nt_name_of(size_t n)
{
    char *s = malloc(n + 1);
    size_t i;

    if (!s) {
        return NULL;
    }
    memcpy(s, "NT_EL_", 6 < n ? 6 : n);
    for (i = 6 < n ? 6 : n; i < n; i++) {
        s[i] = 'L';
    }
    s[n] = '\0';
    return s;
}

static int nt_present(const char *name)
{
#ifdef _WIN32
    return GetEnvironmentVariableA(name, NULL, 0) != 0 ||
           GetLastError() != ERROR_ENVVAR_NOT_FOUND;
#else
    return getenv(name) != NULL;
#endif
}

static int nt_unsetlen(size_t n)
{
    char *name = nt_name_of(n);
    int set_rc, unset_rc, before, after;

    if (!name) {
        printf("envlen unsetlen %lu NOMEM\n", (unsigned long)n);
        return 1;
    }
#ifdef _WIN32
    set_rc = SetEnvironmentVariableA(name, "1") ? 0 : -1;
#else
    set_rc = setenv(name, "1", 1);
#endif
    before = nt_present(name);
#ifdef _WIN32
    unset_rc = SetEnvironmentVariableA(name, NULL) ? 0 : -1;
#else
    unset_rc = unsetenv(name);
#endif
    after = nt_present(name);
    printf("envlen unsetlen %lu set=%d present=%s unset=%d then=%s\n",
           (unsigned long)n, set_rc, before ? "yes" : "no", unset_rc,
           after ? "still-there" : "gone");
    free(name);
    return 0;
}

#ifndef _WIN32
/*
 * The entry the scrub cannot name. nt_env_scrub splits at the first '=' and
 * hands nt_env_drop a length of zero; unsetenv("") is EINVAL on every libc that
 * implements POSIX, so the entry stays and the walk that has to remove it
 * arrives at it again on the next pass. Nothing a shell can express: env(1)
 * refuses an assignment with no name on the left.
 */
static int nt_craft(const char *how, char **argv)
{
    char **out;
    int n = 0, i, at = 0;

    for (i = 0; environ[i]; i++) {
        n++;
    }
    out = malloc(sizeof(*out) * (size_t)(n + 2));
    if (!out) {
        return 2;
    }
    if (strcmp(how, "empty") == 0) {
        out[at++] = (char *)"=neutrino-empty-name";
    }
    for (i = 0; i < n; i++) {
        out[at++] = environ[i];
    }
    out[at] = NULL;
    environ = out;
    execv(argv[0], argv);
    perror("envlen craft execv");
    return 127;
}

/*
 * The other shape a fix could take: never unset anything, build the array the
 * child should have and point environ at it. Whether that survives execv, and
 * whether getenv agrees with it in the meantime, is a libc question and this is
 * four libcs.
 */
static int nt_replace(char **argv)
{
    char *keep[4];
    const char *v;
    int at = 0;

    keep[at++] = (char *)"NT_EL_REPLACED=yes";
    v = getenv("PATH");
    if (v) {
        static char path[4096];
        snprintf(path, sizeof(path), "PATH=%s", v);
        keep[at++] = path;
    }
    keep[at] = NULL;
    environ = keep;
    printf("envlen replace getenv-sees=%s dropped-still-visible=%s\n",
           getenv("NT_EL_REPLACED") ? "yes" : "no",
           getenv("NT_EL_CONTROL_DROPPED") ? "yes" : "no");
    fflush(stdout);
    execv(argv[0], argv);
    perror("envlen replace execv");
    return 127;
}
#endif

#ifndef _WIN32
/*
 * The replacement fix's one dependency, and the only reason it is not obviously
 * the better of the two. netinstall scrubs and then calls setenv five times for
 * the XDG directories; a libc that will not grow an environ it did not allocate
 * would lose all five, silently, and the app would come up with the caller's
 * cache directory instead of its own.
 */
static int nt_setafter(char **argv)
{
    static char *keep[2] = { (char *)"NT_EL_REPLACED=yes", NULL };
    int rc[4];
    int i, sawall = 1;
    static const char *const added[4] = {
        "NT_EL_AFTER1", "NT_EL_AFTER2", "NT_EL_AFTER3", "NT_EL_AFTER4"
    };

    environ = keep;
    for (i = 0; i < 4; i++) {
        rc[i] = setenv(added[i], "yes", 1);
    }
    for (i = 0; i < 4; i++) {
        if (!getenv(added[i])) {
            sawall = 0;
        }
    }
    printf("envlen setafter setenv=%d/%d/%d/%d getenv-all=%s base-still=%s\n",
           rc[0], rc[1], rc[2], rc[3], sawall ? "yes" : "no",
           getenv("NT_EL_REPLACED") ? "yes" : "no");
    fflush(stdout);
    execv(argv[0], argv);
    perror("envlen setafter execv");
    return 127;
}

/*
 * Whether a count of leading entries survives a removal further along. The
 * conservative fix walks from an offset that only advances, and that offset is
 * meaningless if unsetenv is allowed to reorder what sits in front of the entry
 * it took out.
 */
static int nt_stability(void)
{
    char before[8][64];
    const char *eq;
    int i, at, kept = 0, target, n = 0, moved = 0;

    for (i = 0; i < 8; i++) {
        char name[32];

        snprintf(name, sizeof(name), "NT_EL_S%d", i);
        setenv(name, "1", 1);
    }
    for (i = 0; environ[i]; i++) {
        n++;
    }
    /* The entry to remove: the last one this added, so there is plenty in
     * front of it and the answer is not about the tail. */
    target = n - 1;
    for (i = 0; i < target && i < 8; i++) {
        eq = strchr(environ[i], '=');
        at = eq ? (int)(eq - environ[i]) : (int)strlen(environ[i]);
        if (at > 63) {
            at = 63;
        }
        memcpy(before[i], environ[i], (size_t)at);
        before[i][at] = '\0';
        kept++;
    }
    eq = strchr(environ[target], '=');
    {
        char name[256];

        at = eq ? (int)(eq - environ[target]) : (int)strlen(environ[target]);
        if (at > 255) {
            at = 255;
        }
        memcpy(name, environ[target], (size_t)at);
        name[at] = '\0';
        unsetenv(name);
    }
    for (i = 0; i < kept; i++) {
        if (!environ[i]) {
            moved++;
            continue;
        }
        eq = strchr(environ[i], '=');
        at = eq ? (int)(eq - environ[i]) : (int)strlen(environ[i]);
        if (at != (int)strlen(before[i]) || strncmp(environ[i], before[i], (size_t)at) != 0) {
            moved++;
        }
    }
    printf("envlen stability checked=%d before-removal-at=%d moved=%d\n",
           kept, target, moved);
    return 0;
}
#endif

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: envlen-probe emit|unsetlen <n>|craft <how> <prog>...|"
                        "replace <prog>...\n");
        return 2;
    }
    if (strcmp(argv[1], "emit") == 0) {
        return nt_emit();
    }
    if (strcmp(argv[1], "unsetlen") == 0 && argc >= 3) {
        return nt_unsetlen((size_t)strtoul(argv[2], NULL, 10));
    }
#ifdef _WIN32
    if (strcmp(argv[1], "craft") == 0 || strcmp(argv[1], "replace") == 0 ||
        strcmp(argv[1], "setafter") == 0 || strcmp(argv[1], "stability") == 0) {
        printf("envlen %s SKIP windows scrub walks a copy and skips '=' entries\n",
               argv[1]);
        return 0;
    }
#else
    if (strcmp(argv[1], "craft") == 0 && argc >= 4) {
        return nt_craft(argv[2], argv + 3);
    }
    if (strcmp(argv[1], "replace") == 0 && argc >= 3) {
        return nt_replace(argv + 2);
    }
    if (strcmp(argv[1], "setafter") == 0 && argc >= 3) {
        return nt_setafter(argv + 2);
    }
    if (strcmp(argv[1], "stability") == 0) {
        return nt_stability();
    }
#endif
    fprintf(stderr, "envlen-probe: unknown mode %s\n", argv[1]);
    return 2;
}
