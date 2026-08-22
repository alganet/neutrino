/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <process.h>
#else
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "fetch.h"
#include "netinstall.h"
#include "sandbox.h"

/* What the fetch child exits with when it will not run unconfined. Out of the
 * way of curl's own exit codes, which go up to 99. */
#define NT_FETCH_REFUSED 120

/*
 * Release binaries refuse anything but https. The test build additionally
 * allows http so the suite can serve fixtures from loopback; this is compiled
 * in, never a runtime switch.
 */
#ifdef NEUTRINO_TESTING
#define NT_PROTOS "=http,https"
#else
#define NT_PROTOS "=https"
#endif

/*
 * The downloader is resolved from absolute paths rather than $PATH so a
 * planted "curl" earlier in the search order cannot take over the fetch.
 * Its own configuration is deliberately left alone: the OS trust store and
 * the user's curl config are the trust anchor this design chose, so
 * scrubbing them would remove exactly the control that was the point.
 */
static const char *nt_curl_paths[] = {
#ifdef _WIN32
    "C:\\Windows\\System32\\curl.exe",
#else
    "/usr/bin/curl",
    "/bin/curl",
    "/usr/local/bin/curl",
    "/opt/homebrew/bin/curl",
#endif
    NULL
};

#ifndef _WIN32
static const char *nt_wget_paths[] = {
    "/usr/bin/wget",
    "/bin/wget",
    "/usr/local/bin/wget",
    NULL
};
#endif

static const char *nt_first_existing(const char **paths)
{
    int i;

    for (i = 0; paths[i]; i++) {
#ifdef _WIN32
        if (GetFileAttributesA(paths[i]) != INVALID_FILE_ATTRIBUTES) {
            return paths[i];
        }
#else
        if (access(paths[i], X_OK) == 0) {
            return paths[i];
        }
#endif
    }
    return NULL;
}

static void nt_join(char *out, size_t len, char *const argv[])
{
    size_t used = 0;
    int i;

    out[0] = '\0';
    for (i = 0; argv[i]; i++) {
        size_t n = strlen(argv[i]);
        if (used + n + 2 >= len) {
            return;
        }
        if (used > 0) {
            out[used++] = ' ';
        }
        memcpy(out + used, argv[i], n);
        used += n;
        out[used] = '\0';
    }
}

static const char *nt_build(const char *url, const char *dest, char *maxsize,
                            size_t maxlen, char **argv)
{
    const char *bin;
    int n = 0;

    snprintf(maxsize, maxlen, "%d", NT_MAX_PAYLOAD);

    bin = nt_first_existing(nt_curl_paths);
    if (bin) {
        argv[n++] = (char *)bin;
        argv[n++] = (char *)"-fsSL";
        argv[n++] = (char *)"--proto";
        argv[n++] = (char *)NT_PROTOS;
        argv[n++] = (char *)"--proto-redir";
        argv[n++] = (char *)NT_PROTOS;
        argv[n++] = (char *)"--max-redirs";
        argv[n++] = (char *)"5";
        argv[n++] = (char *)"--max-time";
        argv[n++] = (char *)"120";
        argv[n++] = (char *)"--max-filesize";
        argv[n++] = maxsize;
        argv[n++] = (char *)"-o";
        argv[n++] = (char *)dest;
        argv[n++] = (char *)url;
        argv[n] = NULL;
    } else {
#ifdef _WIN32
        fprintf(stderr, "netinstall: no curl.exe found in System32\n");
        return NULL;
#else
        bin = nt_first_existing(nt_wget_paths);
        if (!bin) {
            fprintf(stderr, "netinstall: no curl or wget found\n");
            return NULL;
        }
        argv[n++] = (char *)bin;
        /*
         * --https-only governs recursive link following, not redirects for a
         * single file, and wget has no equivalent of --max-filesize. Refusing
         * redirects outright is the only way to keep the scheme constrained
         * here; the size is bounded after transfer instead of during it.
         */
        argv[n++] = (char *)"--max-redirect=0";
        argv[n++] = (char *)"--timeout=120";
        argv[n++] = (char *)"-q";
        argv[n++] = (char *)"-O";
        argv[n++] = (char *)dest;
        argv[n++] = (char *)url;
        argv[n] = NULL;
#endif
    }

    return bin;
}

int nt_fetch_command(const char *url, const char *dest, char *shown, size_t shownlen)
{
    char maxsize[32];
    char *argv[24];

    if (!nt_build(url, dest, maxsize, sizeof(maxsize), argv)) {
        snprintf(shown, shownlen, "(no downloader found)");
        return -1;
    }
    nt_join(shown, shownlen, argv);
    return 0;
}

/*
 * The forced-off hook exists only in test builds, so a release binary has no
 * way to be talked out of confining the downloader -- the same door, on the
 * same terms, that nt_apply_confine opens for the run phase.
 */
static int nt_fetch_confine(const char *home, char *desc, size_t desclen)
{
#ifdef NEUTRINO_TESTING
    const char *off = getenv("NEUTRINO_TEST_NO_CONFINE");

    if (off && *off == '1') {
        snprintf(desc, desclen, "none (disabled for testing)");
        return -1;
    }
#endif
    return nt_confine(NT_PHASE_FETCH, home, NULL, 1, desc, desclen);
}

int nt_fetch(const char *url, const char *dest, const char *home,
             char *shown, size_t shownlen)
{
    char maxsize[32];
    char *argv[24];
    const char *bin;

    bin = nt_build(url, dest, maxsize, sizeof(maxsize), argv);
    if (!bin) {
        return -1;
    }
    if (shown) {
        nt_join(shown, shownlen, argv);
    }

#ifdef _WIN32
    /*
     * Before the spawn rather than inside the child, because what this platform
     * has to offer -- a job object and an adjusted token -- is inherited rather
     * than applied per process. It stays in force for the run phase too, which
     * creates a job of its own on top of it; nested jobs are fine from windows
     * 8 and CI says so.
     */
    {
        char desc[256];

        if (nt_fetch_confine(home, desc, sizeof(desc)) != 0) {
#ifdef NEUTRINO_STRICT_SANDBOX
            fprintf(stderr, "netinstall: refusing to fetch unconfined: %s\n", desc);
            return -2;
#else
            fprintf(stderr, "netinstall: warning: fetching unconfined: %s\n", desc);
#endif
        }
#ifdef NEUTRINO_TESTING
        fprintf(stderr, "netinstall: fetch confine: %s\n", desc);
#endif
    }
    return nt_win_spawn(bin, argv) == 0 ? 0 : -1;
#else
    {
        pid_t pid = fork();
        int status;

        if (pid < 0) {
            return -1;
        }
        if (pid == 0) {
            char desc[256];
            struct rlimit rl;

            rl.rlim_cur = 0;
            rl.rlim_max = 0;
            setrlimit(RLIMIT_CORE, &rl);
            /* curl needs stdio and nothing else the caller happened to leave open. */
            nt_close_inherited();
            /*
             * The answer was thrown away here for as long as this file has
             * existed. The downloader is the one process that reads bytes an
             * attacker chose, off the network, before anything has verified
             * them -- a strict build that refuses to *run* unconfined and then
             * fetches unconfined is not strict, it is late.
             */
            if (nt_fetch_confine(home, desc, sizeof(desc)) != 0) {
#ifdef NEUTRINO_STRICT_SANDBOX
                fprintf(stderr, "netinstall: refusing to fetch unconfined: %s\n",
                        desc);
                _exit(NT_FETCH_REFUSED);
#else
                fprintf(stderr, "netinstall: warning: fetching unconfined: %s\n",
                        desc);
#endif
            }
#ifdef NEUTRINO_TESTING
            fprintf(stderr, "netinstall: fetch confine: %s\n", desc);
#endif
            execv(bin, argv);
            _exit(127);
        }
        if (waitpid(pid, &status, 0) < 0) {
            return -1;
        }
        if (WIFEXITED(status) && WEXITSTATUS(status) == NT_FETCH_REFUSED) {
            /* The child already said why, and said it precisely. A second,
             * vaguer line about the url on top of that helps nobody. */
            return -2;
        }
        return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : -1;
    }
#endif
}
