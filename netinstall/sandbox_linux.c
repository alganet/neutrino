/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifdef __linux__

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <linux/landlock.h>

#include "netinstall.h"
#include "sandbox.h"

#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#define __NR_landlock_add_rule 445
#define __NR_landlock_restrict_self 446
#endif

#ifndef LANDLOCK_ACCESS_FS_REFER
#define LANDLOCK_ACCESS_FS_REFER (1ULL << 13)
#endif
#ifndef LANDLOCK_ACCESS_FS_TRUNCATE
#define LANDLOCK_ACCESS_FS_TRUNCATE (1ULL << 14)
#endif

/*
 * Only write-shaped rights are handled, so reads stay unrestricted. That is
 * deliberate: a read allowlist forces WebKitGTK's bubblewrap and Chromium's
 * zygote to fight our ruleset, and Landlock unconditionally denies mount and
 * pivot_root to any domain handling a filesystem right. Trading the renderer's
 * own sandbox for our allowlist is not obviously a win, so v1 does not.
 *
 * IOCTL_DEV is likewise left unhandled: handling it means granting it on
 * /dev/dri or losing the GPU, for no benefit here.
 */
#define NT_WRITE_RIGHTS ( \
    LANDLOCK_ACCESS_FS_WRITE_FILE | \
    LANDLOCK_ACCESS_FS_REMOVE_DIR | \
    LANDLOCK_ACCESS_FS_REMOVE_FILE | \
    LANDLOCK_ACCESS_FS_MAKE_CHAR | \
    LANDLOCK_ACCESS_FS_MAKE_DIR | \
    LANDLOCK_ACCESS_FS_MAKE_REG | \
    LANDLOCK_ACCESS_FS_MAKE_SOCK | \
    LANDLOCK_ACCESS_FS_MAKE_FIFO | \
    LANDLOCK_ACCESS_FS_MAKE_BLOCK | \
    LANDLOCK_ACCESS_FS_MAKE_SYM)

static int nt_ll_create(const struct landlock_ruleset_attr *attr, size_t size,
                        unsigned int flags)
{
    return (int)syscall(__NR_landlock_create_ruleset, attr, size, flags);
}

static int nt_ll_add(int fd, const struct landlock_path_beneath_attr *attr)
{
    return (int)syscall(__NR_landlock_add_rule, fd, LANDLOCK_RULE_PATH_BENEATH,
                        attr, 0U);
}

static int nt_ll_restrict(int fd)
{
    return (int)syscall(__NR_landlock_restrict_self, fd, 0U);
}

static void nt_allow(int ruleset, const char *path, unsigned long long rights)
{
    struct landlock_path_beneath_attr attr;
    int fd;

    fd = open(path, O_PATH | O_CLOEXEC);
    if (fd < 0) {
        return;
    }
    memset(&attr, 0, sizeof(attr));
    attr.allowed_access = rights;
    attr.parent_fd = fd;
    nt_ll_add(ruleset, &attr);
    close(fd);
}

int nt_confine(nt_phase phase, const char *home, const char *appdir,
               char *desc, size_t desclen)
{
    struct landlock_ruleset_attr attr;
    unsigned long long rights = NT_WRITE_RIGHTS;
    char path[NT_PATH_MAX];
    const char *runtime;
    int abi, ruleset;

    abi = nt_ll_create(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 1) {
        snprintf(desc, desclen, "none (landlock unavailable)");
        return -1;
    }
    if (abi >= 2) {
        rights |= LANDLOCK_ACCESS_FS_REFER;
    }
    if (abi >= 3) {
        rights |= LANDLOCK_ACCESS_FS_TRUNCATE;
    }

    memset(&attr, 0, sizeof(attr));
    attr.handled_access_fs = rights;
    ruleset = nt_ll_create(&attr, sizeof(attr), 0);
    if (ruleset < 0) {
        snprintf(desc, desclen, "none (landlock ruleset rejected)");
        return -1;
    }

    if (phase == NT_PHASE_FETCH) {
        snprintf(path, sizeof(path), "%s/blobs", home);
        nt_allow(ruleset, path, rights);
        snprintf(desc, desclen, "landlock abi %d, writes confined to %s", abi, path);
    } else {
        nt_allow(ruleset, appdir, rights);
        nt_allow(ruleset, "/dev", LANDLOCK_ACCESS_FS_WRITE_FILE);
        nt_allow(ruleset, "/dev/shm", rights);
        nt_allow(ruleset, "/proc", LANDLOCK_ACCESS_FS_WRITE_FILE);
        runtime = getenv("XDG_RUNTIME_DIR");
        if (runtime && *runtime) {
            nt_allow(ruleset, runtime, LANDLOCK_ACCESS_FS_WRITE_FILE);
        }
        snprintf(desc, desclen, "landlock abi %d, writes confined to %s", abi, appdir);
    }

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 || nt_ll_restrict(ruleset) != 0) {
        close(ruleset);
        snprintf(desc, desclen, "none (landlock enforcement failed)");
        return -1;
    }
    close(ruleset);
    return 0;
}

#endif
