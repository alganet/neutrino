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
/*
 * Opt-in second tier. Handling read rights turns the ruleset into an allowlist
 * for reads too, which is the only way to put $HOME/.ssh out of reach -- but it
 * is also what risks starving WebKitGTK's bubblewrap and Chromium's zygote, so
 * it is a build-time choice and the default stays writes-only.
 */
#ifdef NEUTRINO_CONFINE_TIGHT
#define NT_READ_RIGHTS ( \
    LANDLOCK_ACCESS_FS_READ_FILE | \
    LANDLOCK_ACCESS_FS_READ_DIR)
#else
#define NT_READ_RIGHTS 0ULL
#endif

/*
 * Write xor execute, tight tier only.
 *
 * Landlock takes the union of every rule matching along a path, not the closest
 * one, so there is no way to grant execute broadly and subtract it for one
 * directory -- it has to be an allowlist. That is only affordable in the tight
 * tier, which already allowlists the same system paths for reads. The writable
 * directories are simply absent from it, so an app can drop a binary in its own
 * directory and never run it.
 */
#ifdef NEUTRINO_CONFINE_TIGHT
#define NT_EXEC_RIGHT LANDLOCK_ACCESS_FS_EXECUTE
#else
#define NT_EXEC_RIGHT 0ULL
#endif

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

#ifdef NEUTRINO_CONFINE_TIGHT
/*
 * Everything a GTK or Qt webview reads on the way up. Anything absent here is
 * denied, which is the point: $HOME as a whole is not on the list.
 */
static void nt_allow_system_reads(int ruleset)
{
    static const char *const system_paths[] = {
        "/usr", "/bin", "/sbin", "/lib", "/lib64", "/lib32", "/libx32",
        "/opt", "/etc", "/sys", "/run", "/tmp/.X11-unix", NULL
    };
    static const char *const home_paths[] = {
        "/.config/fontconfig", "/.config/gtk-3.0", "/.config/gtk-4.0",
        "/.config/dconf", "/.config/QtProject", "/.config/mimeapps.list",
        "/.local/share/fonts", "/.local/share/icons", "/.local/share/mime",
        "/.local/share/applications", "/.local/share/glib-2.0",
        "/.icons", "/.fonts", "/.themes", "/.Xauthority", NULL
    };
    char path[NT_PATH_MAX];
    const char *userhome;
    const char *xauth;
    int i;

    for (i = 0; system_paths[i]; i++) {
        nt_allow(ruleset, system_paths[i], NT_READ_RIGHTS | NT_EXEC_RIGHT);
    }

    userhome = getenv("HOME");
    if (userhome && *userhome) {
        for (i = 0; home_paths[i]; i++) {
            snprintf(path, sizeof(path), "%s%s", userhome, home_paths[i]);
            nt_allow(ruleset, path, NT_READ_RIGHTS);
        }
    }

    /* Without the X cookie an X11 client cannot connect at all. */
    xauth = getenv("XAUTHORITY");
    if (xauth && *xauth) {
        nt_allow(ruleset, xauth, LANDLOCK_ACCESS_FS_READ_FILE);
    }
}
#endif

int nt_confine(nt_phase phase, const char *home, const char *appdir,
               char *desc, size_t desclen)
{
    struct landlock_ruleset_attr attr;
    unsigned long long rights = NT_WRITE_RIGHTS | NT_READ_RIGHTS;
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
    attr.handled_access_fs = rights | NT_EXEC_RIGHT;
#ifdef LANDLOCK_ACCESS_NET_BIND_TCP
    /*
     * Nothing here should be listening. Connect is left unhandled, so the app's
     * own outbound traffic is untouched; trailing zero fields are accepted by
     * older kernels, so this only takes effect from ABI 4.
     */
    if (abi >= 4) {
        attr.handled_access_net = LANDLOCK_ACCESS_NET_BIND_TCP;
    }
#endif
    ruleset = nt_ll_create(&attr, sizeof(attr), 0);
    if (ruleset < 0) {
        snprintf(desc, desclen, "none (landlock ruleset rejected)");
        return -1;
    }

    if (phase == NT_PHASE_FETCH) {
        snprintf(path, sizeof(path), "%s/blobs", home);
        nt_allow(ruleset, path, rights);
#ifdef NEUTRINO_CONFINE_TIGHT
        nt_allow_system_reads(ruleset);
        nt_allow(ruleset, "/proc", NT_READ_RIGHTS);
        nt_allow(ruleset, "/dev", NT_READ_RIGHTS | LANDLOCK_ACCESS_FS_WRITE_FILE);
#endif
        snprintf(desc, desclen, "landlock abi %d, writes confined to %s", abi, path);
    } else {
        nt_allow(ruleset, appdir, rights);
        nt_allow(ruleset, "/dev", NT_READ_RIGHTS | LANDLOCK_ACCESS_FS_WRITE_FILE);
        nt_allow(ruleset, "/dev/shm", rights);
        nt_allow(ruleset, "/proc", NT_READ_RIGHTS | LANDLOCK_ACCESS_FS_WRITE_FILE);
        runtime = getenv("XDG_RUNTIME_DIR");
        if (runtime && *runtime) {
            nt_allow(ruleset, runtime, NT_READ_RIGHTS | LANDLOCK_ACCESS_FS_WRITE_FILE);
        }
#ifdef NEUTRINO_CONFINE_TIGHT
        /*
         * The script lives one level above the writable dir so an app cannot
         * rewrite its own launcher. Once reads are handled that same split
         * hides the script from sh, so the parent needs read and execute --
         * and only those, or the split stops meaning anything.
         */
        {
            char parent[NT_PATH_MAX];
            char *cut;

            snprintf(parent, sizeof(parent), "%s", appdir);
            cut = strrchr(parent, '/');
            if (cut && cut != parent) {
                *cut = '\0';
                nt_allow(ruleset, parent, NT_READ_RIGHTS);
            }
        }
        nt_allow_system_reads(ruleset);
        snprintf(desc, desclen,
                 "landlock abi %d, reads and writes confined to %s", abi, appdir);
#else
        snprintf(desc, desclen, "landlock abi %d, writes confined to %s", abi, appdir);
#endif
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
