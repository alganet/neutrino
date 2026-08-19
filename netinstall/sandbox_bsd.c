/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#if defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__NetBSD__)

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "netinstall.h"
#include "sandbox.h"

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
        snprintf(desc, desclen, "unveil + pledge, writes confined to %s",
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
    if (pledge(NULL, "stdio rpath wpath cpath fattr flock inet dns unix "
                     "proc exec prot_exec drm recvfd sendfd tty ps vminfo") != 0) {
        snprintf(desc, desclen, "none (pledge failed)");
        return -1;
    }
    snprintf(desc, desclen, "unveil + pledge, writes confined to %s", appdir);
    return 0;
}

#else

/*
 * Capsicum only confines programs that cooperate, and jail/chroot/ugidfw all
 * need root, so there is nothing to apply to a GUI child here.
 */
int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen)
{
    (void)phase;
    (void)home;
    (void)appdir;
    (void)enforce;
    snprintf(desc, desclen, "none (no unprivileged confinement on this system)");
    return -1;
}

#endif
#endif
