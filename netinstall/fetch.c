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
    (void)home;
    return _spawnv(_P_WAIT, bin, (const char *const *)argv) == 0 ? 0 : -1;
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
            nt_confine(NT_PHASE_FETCH, home, NULL, 1, desc, sizeof(desc));
            execv(bin, argv);
            _exit(127);
        }
        if (waitpid(pid, &status, 0) < 0) {
            return -1;
        }
        return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : -1;
    }
#endif
}
