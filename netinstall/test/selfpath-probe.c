/*
 * selfpath-probe.c - which sysctl spelling answers "what is running" on a BSD
 *
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 *
 * Round 2 read `netinstall: "" is not a valid spec` on NetBSD, on every name
 * the suite offered -- pinfloor rejected 32, 33, 63 and 64 hex alike, and
 * --info printed an empty confine line for all five tiers. netinstall resolves
 * its spec from its own path, and nt_self_path asks for that with FreeBSD's mib
 * layout on all three BSDs:
 *
 *     CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1
 *
 * NetBSD spells the same question differently -- KERN_PROC_PATHNAME is a
 * subcommand of KERN_PROC_ARGS there, and the pid is mib[2] rather than mib[3]:
 *
 *     CTL_KERN, KERN_PROC_ARGS, -1, KERN_PROC_PATHNAME
 *
 * Both constants exist on both systems, so the #ifdef guarding that block is
 * satisfied either way and the wrong spelling is compiled in silently. What it
 * does at run time -- fail, or succeed and hand back something that is not a
 * path -- is the difference between a bug that announces itself and the one
 * observed, and nt_self_path only checks the return value.
 *
 * So this asks both, on whichever platform it is run, and prints the length as
 * well as the bytes: a sysctl that returns 0 having written nothing is exactly
 * how an empty basename gets made.
 */

#include <sys/types.h>
#include <sys/sysctl.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * The wrong spelling may hand back a kernel structure rather than a string, and
 * that goes into a CI annotation. Printable characters only, and a bounded
 * count of them.
 */
static void show_bytes(const char *buf, size_t len)
{
    size_t i;

    putchar('\'');
    for (i = 0; i < len && i < 96; i++) {
        unsigned char c = (unsigned char)buf[i];

        if (c == '\0') {
            fputs("\\0", stdout);
        } else if (c >= 0x20 && c < 0x7f) {
            putchar((int)c);
        } else {
            printf("\\x%02x", (unsigned)c);
        }
    }
    putchar('\'');
}

/*
 * Not PATH_MAX: <limits.h> hides it behind the feature macros on some of the
 * hosts this has to compile on, and netinstall.h's own NT_PATH_MAX is the
 * bound the code under test uses anyway.
 */
#define SP_PATH_MAX 4096

static void ask(const char *label, const int *mib, unsigned n)
{
    char buf[SP_PATH_MAX];
    size_t len = sizeof(buf);

    memset(buf, 0, sizeof(buf));
    if (sysctl(mib, n, buf, &len, NULL, 0) != 0) {
        printf("%s rc=-1 errno=%d\n", label, errno);
        return;
    }
    printf("%s rc=0 len=%lu ", label, (unsigned long)len);
    show_bytes(buf, len);
    /* What nt_self_path would go on to do with it. */
    printf(" first=%s\n", buf[0] == '\0' ? "NUL" : "byte");
}

int main(int argc, char **argv)
{
    int mib[4];
    char rp[SP_PATH_MAX];

    (void)argc;

#if defined(KERN_PROC) && defined(KERN_PROC_PATHNAME)
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_PATHNAME;
    mib[3] = -1;
    ask("as-shipped", mib, 4);
#else
    printf("as-shipped unavailable (constants absent)\n");
#endif

#if defined(KERN_PROC_ARGS) && defined(KERN_PROC_PATHNAME)
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC_ARGS;
    mib[2] = -1;
    mib[3] = KERN_PROC_PATHNAME;
    ask("netbsd-order", mib, 4);
#else
    printf("netbsd-order unavailable (constants absent)\n");
#endif

    /* The fallback nt_self_path takes when the sysctl fails, for comparison. */
    printf("argv0 '%s'\n", (argv[0] && *argv[0]) ? argv[0] : "<empty>");
    if (argv[0] && *argv[0] && realpath(argv[0], rp)) {
        printf("realpath '%s'\n", rp);
    } else {
        printf("realpath errno=%d\n", errno);
    }
    return 0;
}
