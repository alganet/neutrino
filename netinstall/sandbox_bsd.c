/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#if defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__NetBSD__)

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifdef __FreeBSD__
#include <sys/procctl.h>
#include <sys/types.h>
#endif

#include "netinstall.h"
#include "sandbox.h"

/* Never on the fetch: the download is the one thing that has to reach out. */
#ifdef NEUTRINO_CONFINE_OFFLINE
#define NT_OFFLINE_NOTE " (offline)"
#else
#define NT_OFFLINE_NOTE ""
#endif

/*
 * The session tier is namespaces and the X11 SECURITY extension, and there is
 * nothing here shaped like either. Saying so beats letting a
 * -DNEUTRINO_CONFINE_NOSESSION build look like it did something.
 */
#ifdef NEUTRINO_CONFINE_NOSESSION
#define NT_SESSION_NOTE " (session tier unavailable here)"
#else
#define NT_SESSION_NOTE ""
#endif

#ifdef __OpenBSD__

/*
 * The unveil table is destroyed on execve unless execpromises were set, so the
 * order matters: unveil, lock, then pledge with execpromises, then exec. Both
 * survive into the child that way.
 */
int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen)
{
    char path[NT_PATH_MAX];

    if (!enforce) {
        snprintf(desc, desclen, "unveil + pledge%s" NT_SESSION_NOTE ", writes confined to %s",
                 phase == NT_PHASE_FETCH ? "" : NT_OFFLINE_NOTE,
                 phase == NT_PHASE_FETCH ? home : appdir);
        return 0;
    }

    if (phase == NT_PHASE_FETCH) {
        snprintf(path, sizeof(path), "%s/blobs", home);
        if (unveil(path, "rwc") != 0 ||
            unveil("/usr", "rx") != 0 ||
            unveil("/bin", "rx") != 0 ||
            unveil("/etc/ssl", "r") != 0 ||
            unveil("/etc/resolv.conf", "r") != 0 ||
            unveil("/dev/urandom", "r") != 0 ||
            unveil(NULL, NULL) != 0) {
            snprintf(desc, desclen, "none (unveil failed)");
            return -1;
        }
        if (pledge(NULL, "stdio rpath wpath cpath inet dns tty proc exec") != 0) {
            snprintf(desc, desclen, "none (pledge failed)");
            return -1;
        }
        snprintf(desc, desclen, "unveil + pledge, writes confined to %s", path);
        return 0;
    }

    if (unveil(appdir, "rwxc") != 0 ||
        unveil(home, "r") != 0 ||
        unveil("/usr", "rx") != 0 ||
        unveil("/bin", "rx") != 0 ||
        unveil("/etc", "r") != 0 ||
        unveil("/dev", "rw") != 0 ||
        unveil("/tmp", "rw") != 0 ||
        unveil(NULL, NULL) != 0) {
        snprintf(desc, desclen, "none (unveil failed)");
        return -1;
    }
    /*
     * The offline tier is just the same promise list without inet and dns.
     * pledge is an allowlist, so taking a promise away is the whole change.
     */
    if (pledge(NULL, "stdio rpath wpath cpath fattr flock "
#ifndef NEUTRINO_CONFINE_OFFLINE
                     "inet dns "
#endif
                     "unix proc exec prot_exec drm recvfd sendfd tty "
                     "ps vminfo") != 0) {
        snprintf(desc, desclen, "none (pledge failed)");
        return -1;
    }
    snprintf(desc, desclen, "unveil + pledge%s" NT_SESSION_NOTE ", writes confined to %s",
             NT_OFFLINE_NOTE, appdir);
    return 0;
}

#else

/*
 * Capsicum only confines programs that cooperate, and jail/chroot/ugidfw all
 * need root, so there is still nothing here that confines a GUI child.
 *
 * What FreeBSD does have unprivileged is PROC_NO_NEW_PRIVS_CTL, which at least
 * stops the app picking up privileges from a setuid binary. That is a floor,
 * not confinement, so this still returns -1 and a strict build still refuses to
 * run -- but the description says what was actually applied rather than "none".
 */
int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen)
{
    const char *floor = "";

    (void)phase;
    (void)home;
    (void)appdir;

#if defined(__FreeBSD__) && defined(PROC_NO_NEW_PRIVS_CTL)
    {
        int arg = PROC_NO_NEW_PRIVS_ENABLE;

        if (!enforce ||
            procctl(P_PID, (id_t)getpid(), PROC_NO_NEW_PRIVS_CTL, &arg) == 0) {
            floor = "; no-new-privs set";
        }
    }
#else
    (void)enforce;
#endif

    snprintf(desc, desclen,
             "none (no unprivileged confinement on this system%s)%s"
             NT_SESSION_NOTE, floor,
#ifdef NEUTRINO_CONFINE_OFFLINE
             " (offline tier unavailable here)"
#else
             ""
#endif
             );
    return -1;
}

#endif
#endif
