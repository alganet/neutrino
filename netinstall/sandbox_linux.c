/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifdef __linux__

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/landlock.h>
#include <linux/seccomp.h>

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

#ifndef LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET
#define LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)
#endif
#ifndef LANDLOCK_SCOPE_SIGNAL
#define LANDLOCK_SCOPE_SIGNAL (1ULL << 1)
#endif

/*
 * Spelled out rather than taken from the uapi header, because a build machine
 * older than ABI 6 has a two-field struct and there would be nowhere to put the
 * scope. The kernel zero-extends a short struct and rejects a long one whose
 * extra bytes are not zero, so passing the full size is safe either way.
 */
struct nt_ruleset_attr {
    unsigned long long handled_access_fs;
    unsigned long long handled_access_net;
    unsigned long long scoped;
};

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

static int nt_ll_create(const void *attr, size_t size, unsigned int flags)
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


/*
 * Landlock mediates paths and nothing else, so the syscalls that reach across
 * process boundaries or into the kernel's own machinery are all still open to a
 * confined app. A small denylist closes the worst of them.
 *
 * A denylist, not an allowlist, and deliberately: an allowlist that a webview
 * survives is an enormous piece of archaeology that rebreaks whenever an engine
 * changes libc, and Chromium and WebKit already ship exactly that filter for
 * their own renderers. Filters stack, so theirs still installs on top of this
 * one -- verified, not assumed.
 *
 * Everything returns EPERM rather than killing the process. A SIGSYS turns an
 * unexpected-but-harmless syscall into a crash, and a crash in a webview is
 * indistinguishable from a bug in netinstall.
 *
 * The mount family is pointedly absent. Landlock already denies it whenever it
 * handles a filesystem right, and on a kernel too old for Landlock, denying it
 * here would newly break WebKitGTK's bubblewrap for no gain.
 */
static const int nt_denied_syscalls[] = {
#ifdef __NR_ptrace
    __NR_ptrace,                /* read and write any other same-uid process */
#endif
#ifdef __NR_process_vm_readv
    __NR_process_vm_readv,
#endif
#ifdef __NR_process_vm_writev
    __NR_process_vm_writev,
#endif
#ifdef __NR_userfaultfd
    __NR_userfaultfd,           /* a long-running kernel exploit primitive */
#endif
#ifdef __NR_perf_event_open
    __NR_perf_event_open,
#endif
#ifdef __NR_bpf
    __NR_bpf,
#endif
#ifdef __NR_kcmp
    __NR_kcmp,
#endif
#ifdef __NR_keyctl
    __NR_keyctl,                /* the kernel keyring holds real credentials */
#endif
#ifdef __NR_add_key
    __NR_add_key,
#endif
#ifdef __NR_request_key
    __NR_request_key,
#endif
#ifdef __NR_io_uring_setup
    __NR_io_uring_setup,        /* large attack surface, and no toolkit needs it */
#endif
#ifdef __NR_io_uring_enter
    __NR_io_uring_enter,
#endif
#ifdef __NR_io_uring_register
    __NR_io_uring_register,
#endif
#ifdef __NR_setns
    __NR_setns,
#endif
#ifdef __NR_open_by_handle_at
    __NR_open_by_handle_at,     /* reaches a file without walking a path to it */
#endif
#ifdef __NR_name_to_handle_at
    __NR_name_to_handle_at,
#endif
#ifdef __NR_syslog
    __NR_syslog,
#endif
#ifdef __NR_init_module
    __NR_init_module,
#endif
#ifdef __NR_finit_module
    __NR_finit_module,
#endif
#ifdef __NR_delete_module
    __NR_delete_module,
#endif
#ifdef __NR_kexec_load
    __NR_kexec_load,
#endif
#ifdef __NR_kexec_file_load
    __NR_kexec_file_load,
#endif
#ifdef __NR_swapon
    __NR_swapon,
#endif
#ifdef __NR_swapoff
    __NR_swapoff,
#endif
#ifdef __NR_modify_ldt
    __NR_modify_ldt,
#endif
#ifdef __NR_iopl
    __NR_iopl,
#endif
#ifdef __NR_ioperm
    __NR_ioperm,
#endif
    -1
};

#if defined(__x86_64__)
#define NT_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__i386__)
#define NT_AUDIT_ARCH AUDIT_ARCH_I386
#elif defined(__aarch64__)
#define NT_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__arm__)
#define NT_AUDIT_ARCH AUDIT_ARCH_ARM
#elif defined(__riscv) && __riscv_xlen == 64
#define NT_AUDIT_ARCH AUDIT_ARCH_RISCV64
#elif defined(__powerpc64__)
#define NT_AUDIT_ARCH AUDIT_ARCH_PPC64LE
#endif

#if defined(__x86_64__)
#define NT_X32_GUARD 1
#else
#define NT_X32_GUARD 0
#endif

#define NT_SECCOMP_MAX (8 + (sizeof(nt_denied_syscalls) / sizeof(int)))

/* Asks whether a filter could be installed, without installing one, so --info
 * describes a real launch rather than guessing at it. */
static int nt_seccomp_available(void)
{
#ifndef NT_AUDIT_ARCH
    return 0;
#else
#ifdef SECCOMP_GET_ACTION_AVAIL
    {
        unsigned int action = SECCOMP_RET_ERRNO;

        if (syscall(__NR_seccomp, SECCOMP_GET_ACTION_AVAIL, 0U, &action) == 0) {
            return 1;
        }
    }
#endif
    return prctl(PR_GET_SECCOMP, 0, 0, 0, 0) >= 0;
#endif
}

/*
 * Returns 0 when a filter is in force. The caller has already asked for
 * PR_SET_NO_NEW_PRIVS, which seccomp requires for an unprivileged process.
 */
static int nt_seccomp(void)
{
#ifndef NT_AUDIT_ARCH
    return -1;
#else
    struct sock_filter prog[NT_SECCOMP_MAX];
    struct sock_fprog fprog;
    unsigned short n = 0;
    int i, count = 0;

    while (nt_denied_syscalls[count] != -1) {
        count++;
    }

    /*
     * A process can reach the same kernel code through a different syscall
     * table, so the architecture is checked first and anything foreign is
     * refused outright. On x86-64 that includes x32, which shares the audit
     * arch and only differs by a bit in the syscall number.
     */
    prog[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                                             offsetof(struct seccomp_data, arch));
    prog[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                           NT_AUDIT_ARCH, 0, 0);
    prog[n].jf = (unsigned char)(count + 2 + NT_X32_GUARD);
    n++;
    prog[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                                             offsetof(struct seccomp_data, nr));
#if defined(__x86_64__)
    prog[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K,
                                           0x40000000, 0, 0);
    prog[n].jt = (unsigned char)(count + 1);
    n++;
#endif

    for (i = 0; i < count; i++) {
        prog[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                               (unsigned int)nt_denied_syscalls[i],
                                               0, 0);
        prog[n].jt = (unsigned char)(count - i);
        n++;
    }
    prog[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    prog[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K,
                                             SECCOMP_RET_ERRNO |
                                             (EPERM & SECCOMP_RET_DATA));

    fprog.len = n;
    fprog.filter = prog;

#ifdef __NR_seccomp
    if (syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, 0U, &fprog) == 0) {
        return 0;
    }
#endif
    /* Pre-3.17 kernels have no seccomp syscall, only the prctl. */
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &fprog, 0, 0) == 0 ? 0 : -1;
#endif
}

int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen)
{
    struct nt_ruleset_attr attr;
    unsigned long long rights = NT_WRITE_RIGHTS | NT_READ_RIGHTS;
    char path[NT_PATH_MAX];
    const char *runtime;
    const char *scoped = "";
    const char *secc;
    int abi, ruleset;

    /*
     * Before Landlock, and independently of it: the filter is worth having even
     * on a kernel with no Landlock at all, and no_new_privs is a precondition
     * for both.
     */
    if (enforce) {
        prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
        secc = nt_seccomp() == 0 ? " + seccomp" : "";
    } else {
        secc = nt_seccomp_available() ? " + seccomp" : "";
    }

    abi = nt_ll_create(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 1) {
        /*
         * Still -1: a syscall filter is not filesystem confinement, and a
         * strict build must refuse rather than settle for it.
         */
        snprintf(desc, desclen, "none (landlock unavailable)%s", secc);
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
    /*
     * Scoping is the only part of Landlock that is not about paths. Signals are
     * free and unconditional: nothing here has any business reaching a process
     * outside its own domain.
     *
     * Abstract unix sockets are not free, and the reason is worth stating
     * exactly, because the obvious assumption is wrong. An X11 client asks for
     * the abstract socket first and is documented to fall back to
     * /tmp/.X11-unix/X0 -- but libxcb only retries on ENOENT and ECONNREFUSED,
     * and scoping answers EPERM, which is not on that list. Measured with strace
     * under a scoped domain: exactly one connect(), to @/tmp/.X11-unix/X0, EPERM,
     * and the pathname socket is never tried even though it is reachable. So on
     * an X11 session this does not tighten the sandbox, it removes the display.
     *
     * It is therefore applied only when there is no X11 display to break, which
     * is where it costs nothing and still closes a namespace no path rule can
     * reach. --info says which of the two was applied.
     */
    if (abi >= 6) {
        const char *display = getenv("DISPLAY");

        attr.scoped = LANDLOCK_SCOPE_SIGNAL;
        scoped = " (signals scoped)";
        if (!display || !*display) {
            attr.scoped |= LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET;
            scoped = " (sockets+signals scoped)";
        }
    }
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
        snprintf(desc, desclen, "none (landlock ruleset rejected)%s", secc);
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
        snprintf(desc, desclen, "landlock abi %d%s%s, writes confined to %s",
                 abi, scoped, secc, path);
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
                 "landlock abi %d%s%s, reads and writes confined to %s",
                 abi, scoped, secc, appdir);
#else
        snprintf(desc, desclen, "landlock abi %d%s%s, writes confined to %s",
                 abi, scoped, secc, appdir);
#endif
    }

    if (!enforce) {
        close(ruleset);
        return 0;
    }

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 || nt_ll_restrict(ruleset) != 0) {
        close(ruleset);
        snprintf(desc, desclen, "none (landlock enforcement failed)%s", secc);
        return -1;
    }
    close(ruleset);
    return 0;
}

#endif
