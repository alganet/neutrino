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
 * The rest of the run phase's writable set, spelled where a user can read it.
 *
 * /dev is unveiled "rwc" and /tmp "rw" -- both for reasons that are in the
 * comments beside the rules, and neither of them is the app dir. Measured on
 * the openbsd lane in both tiers, on a VM running as root, so nothing there was
 * refused by ordinary permissions and the letters are unveil and nothing else:
 * appdir=CTO, devnull=OK, and tmp=--O -- an existing file written, and neither
 * created nor truncated, which is "rw" without a "c" exactly as this file and
 * the README have been describing it since PR 11. First time it was asked.
 */
#define NT_ALSO_WRITABLE " and /dev, plus files that already exist under /tmp"

/*
 * The unveil table is destroyed on execve unless execpromises were set, so the
 * order matters: unveil, lock, then pledge with execpromises, then exec. Both
 * survive into the child that way.
 *
 * Everything below was written from the manual pages and had never run: no
 * runner GitHub offers is a BSD, netinstall/build.sh cross-compiles six targets
 * and none of them is one either, and until the openbsd lane in this PR nothing
 * in this repository had so much as compiled this file. Four of the rules were
 * wrong. What each of them is now, and what it was measured against, is in the
 * comments where they sit -- and the lane runs the same confine.sh the other
 * four platforms answer to, so they stay measured.
 */
int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen)
{
    char path[NT_PATH_MAX];

    /*
     * No early return for --info. The description used to be written twice --
     * once here from `home` as handed in, and once below from the blobs
     * directory the unveil is actually built around -- and the two said
     * different things. Measured on the openbsd lane: --info's fetch line named
     * the cache root while the confinement was the directory inside it. macOS
     * had the same split for the same reason and lost it in the same change;
     * linux never had it, because linux describes what it applies from the
     * place it applies it.
     */
    if (phase == NT_PHASE_FETCH) {
        snprintf(path, sizeof(path), "%s/blobs", home);
        if (!enforce) {
            snprintf(desc, desclen, "unveil + pledge, writes confined to %s", path);
            return 0;
        }
        /*
         * /usr covers /usr/local/lib, but ld.so is how a binary gets there and
         * ld.so reads the hints file to know that /usr/local/lib exists at all.
         * Without it curl -- which lives in /usr/local and links against it --
         * dies before main with "can't load library 'libcurl.so'", so the fetch
         * phase could not download anything on this platform. Measured: the one
         * line is the whole difference between SIGKILL and a completed fetch.
         */
        /*
         * "/" readable, and this is the one place in the collapse where a
         * platform is deliberately widened rather than narrowed.
         *
         * unveil is a read allowlist by construction, so OpenBSD got read
         * confinement free while no other platform could promise it -- windows
         * cannot confine a read at all. Keeping it would have been a bonus, and
         * the rule is that a capability three platforms lack is not one any of
         * them has.
         *
         * It closes a divergence on the way out, which is the part worth
         * having: this list did not include the user's curl configuration, so
         * ~/.curlrc was read on linux and macOS -- where it is part of the
         * trust model -- and silently not read here. Somebody's proxy settings
         * stopped applying on exactly one platform.
         */
        if (unveil("/", "r") != 0 ||
            unveil(path, "rwc") != 0 ||
            unveil("/var/run/ld.so.hints", "r") != 0 ||
            unveil("/usr", "rx") != 0 ||
            unveil("/bin", "rx") != 0 ||
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

    if (!enforce) {
        snprintf(desc, desclen, "unveil + pledge%s" NT_SESSION_NOTE
                                ", writes confined to %s" NT_ALSO_WRITABLE,
                 NT_OFFLINE_NOTE, appdir);
        return 0;
    }

    /*
     * Write xor execute, and here it is free. On linux it costs an exec
     * allowlist and lives in the tight tier; unveil is an allowlist already, so
     * taking the x off the one directory the app can write to costs a letter.
     * Measured both ways: with it, the app copies a binary into its own dir and
     * runs it; without it, EACCES on both that directory and the redirected
     * TMPDIR inside it -- and the launcher still runs, because sh needs to read
     * the script, not execute it.
     *
     * /dev is "rwc" and the c is not cosmetic. unveil counts O_CREAT as create
     * whether or not the file is already there, and a shell redirection is
     * O_CREAT -- so with "rw" every `2>/dev/null` in every script this launches
     * is refused. Measured: confine.sh's thirteen probes all end in one, seven
     * of them reported a denial they had not earned, and the suite went from
     * two failures to none on this letter alone. It grants nothing: /dev is
     * root-owned and mode 755, ordinary permissions still refuse to create
     * anything in it, and unveil only ever subtracts.
     *
     * /tmp stays "rw", and that is not "writes confined to the app dir". An
     * existing file there can be overwritten -- not created, and not through a
     * shell redirection, which is O_CREAT -- so it takes a deliberate open(2)
     * without O_CREAT. It stays because an X11 client connects through
     * /tmp/.X11-unix and there is no display on the lane to measure a narrower
     * rule against. Recorded in the README rather than quietly dropped.
     */
    /*
     * "/" readable -- see the fetch phase above for why a platform is being
     * widened here. unveil resolves the most specific matching path, so the
     * "rwc" and "rx" entries below still decide their own subtrees; only the
     * reads everywhere else change, from denied to allowed.
     */
    if (unveil("/", "r") != 0 ||
        unveil(appdir, "rwc") != 0 ||
        unveil("/var/run/ld.so.hints", "r") != 0 ||
        unveil("/usr", "rx") != 0 ||
        unveil("/bin", "rx") != 0 ||
        unveil("/dev", "rwc") != 0 ||
        unveil("/tmp", "rw") != 0 ||
        unveil(NULL, NULL) != 0) {
        snprintf(desc, desclen, "none (unveil failed)");
        return -1;
    }
    /*
     * The offline tier is just the same promise list without inet and dns.
     * pledge is an allowlist, so taking a promise away is the whole change.
     *
     * getpw is here because /bin/sh is ksh and ksh calls pledge() on startup.
     * A process that inherited execpromises may only narrow them, so ksh's own
     * request was refused and it exited before reading a line of the launcher.
     * nt_exec execs /bin/sh and nothing else, so the run phase on this platform
     * had never started an app. Measured one promise at a time: this is the
     * only one missing -- id and unveil change nothing.
     */
    if (pledge(NULL, "stdio rpath wpath cpath fattr flock getpw "
#ifndef NEUTRINO_CONFINE_OFFLINE
                     "inet dns "
#endif
                     "unix proc exec prot_exec drm recvfd sendfd tty "
                     "ps vminfo") != 0) {
        snprintf(desc, desclen, "none (pledge failed)");
        return -1;
    }
    snprintf(desc, desclen, "unveil + pledge%s" NT_SESSION_NOTE
                            ", writes confined to %s" NT_ALSO_WRITABLE,
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
