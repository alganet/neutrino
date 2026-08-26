/*
 * nnp-probe.c - what an unprivileged process on this BSD can still pick up
 *
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 *
 * sandbox_bsd.c's non-OpenBSD half claims a floor: FreeBSD's
 * PROC_NO_NEW_PRIVS_CTL, applied so an app cannot gain privileges from a setuid
 * binary. Nothing in this repository has ever compiled that branch, let alone
 * run it, so the claim is a manual page reading.
 *
 * PR 4's rule applies: assert the consequence, not the flag. procctl returning
 * 0 says the kernel accepted a request; what the sentence in --info promises is
 * that a setuid-root program executed afterwards does not come back root. So
 * this measures that directly, and it carries its own positive control -- the
 * same exec without the flag, which must come back euid=0 or the mechanism was
 * never in play and "blocked" means nothing.
 *
 *   nnp-probe report          prints the ids it ended up with
 *   nnp-probe run <0|1> <p>   optionally raises no-new-privs, drops to an
 *                             unprivileged uid, execs <p> report
 *
 * Two modes in one file so the setuid-root target and the dropper are the same
 * bytes: a probe that compiles two programs can have one of them fail to build
 * and report the other's silence as a result.
 */

#include <sys/types.h>

#include <errno.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__FreeBSD__)
#include <sys/procctl.h>
#endif

static int report(void)
{
    printf("euid=%ld ruid=%ld egid=%ld\n", (long)geteuid(), (long)getuid(),
           (long)getegid());
    return 0;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "report";
    struct passwd *pw;

    if (strcmp(mode, "report") == 0) {
        return report();
    }

    if (strcmp(mode, "flag") == 0) {
        /*
         * The flag on its own, for the platform that has it. Separate from
         * "run" because a kernel that refuses the request and a kernel that has
         * no such request are different readings, and the exec below cannot
         * tell them apart.
         */
#if defined(__FreeBSD__) && defined(PROC_NO_NEW_PRIVS_CTL)
        int arg = PROC_NO_NEW_PRIVS_ENABLE;
        int st = -1;

        if (procctl(P_PID, (id_t)getpid(), PROC_NO_NEW_PRIVS_CTL, &arg) != 0) {
            printf("defined=yes ctl=errno=%d status=n/a\n", errno);
            return 0;
        }
        if (procctl(P_PID, (id_t)getpid(), PROC_NO_NEW_PRIVS_STATUS, &st) != 0) {
            printf("defined=yes ctl=ok status=errno=%d\n", errno);
            return 0;
        }
        printf("defined=yes ctl=ok status=%d\n", st);
#else
        printf("defined=no ctl=n/a status=n/a\n");
#endif
        return 0;
    }

    if (strcmp(mode, "run") != 0 || argc < 4) {
        fprintf(stderr, "usage: nnp-probe report | flag | run <0|1> <prog>\n");
        return 2;
    }

    if (strcmp(argv[2], "1") == 0) {
#if defined(__FreeBSD__) && defined(PROC_NO_NEW_PRIVS_CTL)
        int arg = PROC_NO_NEW_PRIVS_ENABLE;

        if (procctl(P_PID, (id_t)getpid(), PROC_NO_NEW_PRIVS_CTL, &arg) != 0) {
            printf("ctl-failed errno=%d\n", errno);
            return 0;
        }
#else
        printf("ctl-absent\n");
        return 0;
#endif
    }

    /*
     * Drop after the flag, never before: the caller is root and only root can
     * have made the setuid file this is about to exec. The order is the one
     * sandbox_bsd.c uses -- apply, then become the app.
     */
    pw = getpwnam("nobody");
    if (pw == NULL) {
        printf("no-nobody\n");
        return 0;
    }
    if (setgid(pw->pw_gid) != 0 || setuid(pw->pw_uid) != 0) {
        printf("drop-failed errno=%d\n", errno);
        return 0;
    }
    execl(argv[3], argv[3], "report", (char *)NULL);
    printf("exec-failed errno=%d\n", errno);
    return 0;
}
