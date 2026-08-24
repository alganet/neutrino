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
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
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
 * One number for the clock, spent as curl's --max-time on the branch that has
 * such a flag and as an alarm on the branch that does not.
 */
#define NT_FETCH_MAX_SECONDS 120
#define NT_STR_(x) #x
#define NT_STR(x) NT_STR_(x)

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
 *
 * That decision is about trust, and a configuration file is not limited to
 * trust. Measured, on four curl versions across five lanes: the two bounds
 * below survive it -- a config asking for a larger --max-filesize or a smaller
 * --max-time loses to the argv, because curl parses the config first and a
 * last-wins option is therefore won by the command line. What does not
 * last-win is -o, which pairs with URLs in the order both appear: an `output`
 * line in a config takes the one URL and leaves this program's -o holding
 * nothing. So the decision stands, and the two things that were false about it
 * do not -- see nt_fetch_config below, and the "wrote nothing" refusal in
 * netinstall.c.
 */
#if !(defined(NEUTRINO_TESTING) && defined(NEUTRINO_FETCH_PREFER_WGET)) || defined(_WIN32)
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
#endif

#ifndef _WIN32
/*
 * The same list, and it has to be: the curl list above carries
 * /opt/homebrew/bin and this one did not, so on an Apple Silicon mac -- where
 * homebrew installs there rather than to /usr/local -- a wget the user has is
 * a wget this never finds. Harmless in practice, because macOS ships curl in
 * /usr/bin and the fallback is never reached; visible immediately once
 * something tried to reach it on purpose, which is how it was found.
 */
static const char *nt_wget_paths[] = {
    "/usr/bin/wget",
    "/bin/wget",
    "/usr/local/bin/wget",
    "/opt/homebrew/bin/wget",
    NULL
};
#endif

#ifndef _WIN32
/*
 * The fetch deadline is the parent's, and it took a measurement to learn why.
 *
 * The obvious place is the child: alarm() before execv, since a pending alarm
 * survives an exec. It does -- against curl, which is what the probe ran, and
 * which dies at the second with SIGALRM. wget implements its own --timeout with
 * SIGALRM and overwrites ours the moment it starts, so the one branch that
 * needs a total is the one branch where that mechanism does nothing. Measured:
 * curl rc 142 at eight seconds, wget still dribbling three minutes into an
 * eight-second deadline.
 *
 * netinstall is already waiting on the child and has no alarms of its own, so
 * the deadline goes here, where nothing can clear it.
 */
static volatile sig_atomic_t nt_fetch_timed_out;

static void nt_fetch_alarm(int sig)
{
    (void)sig;
    nt_fetch_timed_out = 1;
}
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

/*
 * `wget` is set when the fallback was taken, because that branch's bounds are
 * not in its argv and the two callers both need to know: the child, which has
 * to impose them, and --info, which would otherwise print a command line that
 * understates what is in force.
 */
static const char *nt_build(const char *url, const char *dest, char *maxsize,
                            size_t maxlen, char **argv, int *wget)
{
    const char *bin;
    int n = 0;

    snprintf(maxsize, maxlen, "%d", NT_MAX_PAYLOAD);
    if (wget) {
        *wget = 0;
    }

#if defined(NEUTRINO_TESTING) && defined(NEUTRINO_FETCH_PREFER_WGET) && !defined(_WIN32)
    /*
     * Every runner this suite has -- and every machine anyone is likely to run
     * netinstall on -- resolves curl, so the fallback is a branch nothing has
     * ever taken. Measured: curl PRESENT on all five reporting lanes. This
     * exists only in test builds, so a release binary cannot be talked out of
     * the stronger downloader; it is the door confine already opens on the
     * same terms.
     */
    bin = NULL;
#else
    bin = nt_first_existing(nt_curl_paths);
#endif
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
        argv[n++] = (char *)NT_STR(NT_FETCH_MAX_SECONDS);
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
        if (wget) {
            *wget = 1;
        }
        argv[n++] = (char *)bin;
        /*
         * --https-only governs recursive link following, not redirects for a
         * single file, so refusing redirects outright is the only way to keep
         * the scheme constrained here.
         *
         * The two bounds this branch cannot express in its argv are imposed on
         * it in the child below instead. wget has no equivalent of
         * --max-filesize, and --timeout is per read rather than a total, so a
         * host sending one byte a second satisfies it forever -- measured, on
         * five lanes, still alive at forty seconds with nothing else stopping
         * it.
         */
        argv[n++] = (char *)"--max-redirect=0";
        argv[n++] = (char *)"--timeout=" NT_STR(NT_FETCH_MAX_SECONDS);
        argv[n++] = (char *)"-q";
        argv[n++] = (char *)"-O";
        argv[n++] = (char *)dest;
        argv[n++] = (char *)url;
        argv[n] = NULL;
#endif
    }

    return bin;
}

/*
 * Where the downloader looks for the options this program did not give it.
 * Asserted to the measured set rather than to the manual: fetchconf.sh probes
 * each location on every lane, so a curl that grows or drops one fails here
 * instead of quietly making this sentence wrong.
 */
#if defined(__OpenBSD__)
/* unveil is an allowlist for reads and the fetch list does not include any of
 * them, so on this platform the sentence is that nothing is read at all. */
#define NT_CURL_CONFIG "curl reads none of its own config here: the fetch " \
                       "phase's unveil set does not include it"
#define NT_WGET_CONFIG "wget reads none of its own config here: the fetch " \
                       "phase's unveil set does not include it"
#elif defined(_WIN32)
#define NT_CURL_CONFIG "curl also reads its own config, and it is not " \
                       "suppressed: %CURL_HOME%, %XDG_CONFIG_HOME%, %HOME%, " \
                       "%APPDATA%, %USERPROFILE%"
#define NT_WGET_CONFIG "no wget branch on windows"
#else
#define NT_CURL_CONFIG "curl also reads its own config, and it is not " \
                       "suppressed: $CURL_HOME/.curlrc, then ~/.curlrc"
#define NT_WGET_CONFIG "wget also reads its own config, and it is not " \
                       "suppressed: $WGETRC, then ~/.wgetrc, then /etc/wgetrc"
#endif

int nt_fetch_command(const char *url, const char *dest, char *shown,
                     size_t shownlen, char *bounds, size_t boundslen,
                     char *config, size_t configlen)
{
    char maxsize[32];
    char *argv[24];
    int wget = 0;

    if (!nt_build(url, dest, maxsize, sizeof(maxsize), argv, &wget)) {
        snprintf(shown, shownlen, "(no downloader found)");
        if (bounds) {
            snprintf(bounds, boundslen, "none -- no downloader found");
        }
        if (config) {
            snprintf(config, configlen, "none -- no downloader found");
        }
        return -1;
    }
    if (config) {
        snprintf(config, configlen, "%s", wget ? NT_WGET_CONFIG : NT_CURL_CONFIG);
    }
    nt_join(shown, shownlen, argv);
    /*
     * The wget branch's bounds are nowhere in the line above, so a --info that
     * printed only the command would understate what is in force -- which is
     * the same complaint this document makes about every other --info line.
     */
    if (bounds) {
        if (wget) {
            snprintf(bounds, boundslen,
                     "%d bytes and %d seconds, from the kernel "
                     "(RLIMIT_FSIZE and alarm; wget expresses neither)",
                     NT_MAX_PAYLOAD, NT_FETCH_MAX_SECONDS);
        } else {
            snprintf(bounds, boundslen,
                     "%d bytes and %d seconds, from curl "
                     "(--max-filesize and --max-time)",
                     NT_MAX_PAYLOAD, NT_FETCH_MAX_SECONDS);
        }
    }
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
    int wget = 0;

    bin = nt_build(url, dest, maxsize, sizeof(maxsize), argv, &wget);
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
    /*
     * The tight tier's grant, and the only write its downloader is allowed. In
     * the default tier both calls are no-ops and the spawn is the one that has
     * always been here.
     *
     * The order is the whole mechanism: create and label the destination, run
     * the child that may write nothing else, then take the label straight back
     * off. Revoking is not cleanup -- main() hashes this file next, and a
     * payload still writable at low integrity is a digest checked against
     * content that any low integrity process on the machine can still change.
     */
    {
        int rc;

        if (!nt_fetch_grant(dest)) {
#ifdef NEUTRINO_STRICT_SANDBOX
            fprintf(stderr, "netinstall: refusing to fetch: the payload file "
                            "could not be made the downloader's only write\n");
            return -2;
#else
            fprintf(stderr, "netinstall: warning: the payload file could not be "
                            "made the downloader's only write\n");
#endif
        }
        rc = nt_win_spawn_as(bin, argv, nt_fetch_token());
        /*
         * In every build, not only a strict one. This is not the tier failing
         * to apply -- it is the tier having applied and not come back off, and
         * the next thing that happens to this file is nt_sha256_file. A digest
         * taken over content a low integrity process can still rewrite before
         * the rename is worse than no download.
         */
        if (!nt_fetch_revoke(dest)) {
            fprintf(stderr, "netinstall: refusing the payload: it could not be "
                            "taken back from low integrity, so its digest "
                            "cannot be trusted\n");
            remove(dest);
            return -2;
        }
        return rc == 0 ? 0 : -1;
    }
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
             * What the wget branch cannot say in its own argv, said here by
             * the kernel instead. curl carries --max-filesize and --max-time
             * and needs neither of these; giving them to it would buy nothing
             * and take on the stderr hazard below for free.
             *
             * Measured on linux, macos and openbsd: a downloader with no size
             * flag writes every byte a host offers -- 64 MiB and exit 0 in the
             * probe -- and under RLIMIT_FSIZE stops at exactly the limit with
             * SIGXFSZ. The clock half is the parent's; see nt_fetch_alarm.
             */
            if (wget) {
                /*
                 * RLIMIT_FSIZE bounds the file *offset* a write lands at, not
                 * the size of the write, and it applies to every regular file
                 * this process holds -- including a stderr it inherited. A
                 * caller who redirected netinstall into a log already past the
                 * limit would otherwise watch wget die of its own first
                 * diagnostic, and read it as a network error. Measured: rc 153
                 * on all three POSIX lanes.
                 *
                 * Both the size and the offset, because either can be the one
                 * that matters and the first draft of this checked only the
                 * offset. `2>>log` opens with O_APPEND, where lseek reports 0
                 * until the first write and the kernel then places that write
                 * at the end anyway -- so the guard saw a fresh fd at offset
                 * zero and let the child straight into the trap it was written
                 * to avoid. Caught by the assertion in fetchbound.sh.
                 *
                 * A pipe or a tty is not S_ISREG and is left alone.
                 */
                struct stat st;

                if (fstat(2, &st) == 0 && S_ISREG(st.st_mode) &&
                    (st.st_size >= (off_t)NT_MAX_PAYLOAD ||
                     lseek(2, 0, SEEK_CUR) >= (off_t)NT_MAX_PAYLOAD)) {
                    int devnull = open("/dev/null", O_WRONLY);

                    if (devnull >= 0) {
                        dup2(devnull, 2);
                        if (devnull > 2) {
                            close(devnull);
                        }
                    }
                }
                rl.rlim_cur = (rlim_t)NT_MAX_PAYLOAD;
                rl.rlim_max = (rlim_t)NT_MAX_PAYLOAD;
                setrlimit(RLIMIT_FSIZE, &rl);
                /* The clock is the parent's; see nt_fetch_alarm above. */
            }
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
        {
            struct sigaction sa, old;
            int armed = 0;

            nt_fetch_timed_out = 0;
            /*
             * Only the fallback branch: curl carries --max-time, and a second
             * deadline racing its own would make which message arrives a coin
             * toss.
             */
            if (wget) {
                sa.sa_handler = nt_fetch_alarm;
                sigemptyset(&sa.sa_mask);
                /* No SA_RESTART, or waitpid resumes and the deadline becomes a
                 * flag nobody reads. */
                sa.sa_flags = 0;
                if (sigaction(SIGALRM, &sa, &old) == 0) {
                    armed = 1;
                    alarm(NT_FETCH_MAX_SECONDS);
                }
            }
            while (waitpid(pid, &status, 0) < 0) {
                if (errno != EINTR) {
                    if (armed) {
                        alarm(0);
                        sigaction(SIGALRM, &old, NULL);
                    }
                    return -1;
                }
                if (nt_fetch_timed_out) {
                    kill(pid, SIGKILL);
                }
            }
            if (armed) {
                alarm(0);
                sigaction(SIGALRM, &old, NULL);
            }
            if (nt_fetch_timed_out) {
                fprintf(stderr,
                        "netinstall: the host held the download open past %d seconds\n",
                        NT_FETCH_MAX_SECONDS);
                return -2;
            }
        }
        if (WIFEXITED(status) && WEXITSTATUS(status) == NT_FETCH_REFUSED) {
            /* The child already said why, and said it precisely. A second,
             * vaguer line about the url on top of that helps nobody. */
            return -2;
        }
        /*
         * RLIMIT_FSIZE kills the child before it can say anything, so the
         * reason has to be read out of the status here. Without this a host
         * that filled a disk is indistinguishable from a flaky network.
         */
        if (WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);

            if (sig == SIGXFSZ) {
                fprintf(stderr,
                        "netinstall: the host sent more than %d bytes; refusing\n",
                        NT_MAX_PAYLOAD);
                return -2;
            }
        }
        return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : -1;
    }
#endif
}
