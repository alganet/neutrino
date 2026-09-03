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
#include <sched.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <net/if.h>
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

/*
 * Fallbacks so an old uapi header cannot silently compile the network rules
 * out. Whether they take effect is decided at runtime by the reported ABI.
 */
#ifndef LANDLOCK_ACCESS_NET_BIND_TCP
#define LANDLOCK_ACCESS_NET_BIND_TCP (1ULL << 0)
#endif
#ifndef LANDLOCK_ACCESS_NET_CONNECT_TCP
#define LANDLOCK_ACCESS_NET_CONNECT_TCP (1ULL << 1)
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
 * IOCTL_DEV is left unhandled: handling it means granting it on /dev/dri or
 * losing the GPU, for no benefit here.
 */
/*
 * Reads are not confined, here or on any other platform, and this is where that
 * decision lands on linux.
 *
 * Handling read rights would turn the ruleset into an allowlist for reads too,
 * which is the only way to put $HOME/.ssh out of reach -- and it worked. It is
 * gone because windows cannot do it at all: low integrity is a no-write-up rule
 * and AppContainer, the one mechanism that would, is measured not to start a
 * webview. A capability three platforms have and the fourth cannot is the shape
 * that gets reported as a bug against the fourth, so it is not a capability any
 * of them has.
 *
 * The ruleset stays write-shaped, which is what it was in the shipped build all
 * along.
 */
#define NT_READ_RIGHTS 0ULL

/*
 * Write xor execute is not expressible here without the read allowlist above.
 *
 * Landlock takes the union of every rule matching along a path, not the closest
 * one, so there is no way to grant execute broadly and subtract it for one
 * directory -- it has to be an allowlist, and the allowlist went with the
 * reads. macOS keeps its (deny process-exec*) and OpenBSD gets w^x free from
 * unveil, because those cost nothing there; neither is promised, and windows
 * has none either way.
 */
#define NT_EXEC_RIGHT 0ULL

/*
 * The rest of the writable set, spelled where a user can read it.
 *
 * Every path in here is granted deliberately, a few lines from the sentence
 * that used to name one directory and stop: /dev/shm is where a renderer puts
 * its shared memory and takes the full write set; /dev takes the writes every
 * shell redirection in a launched script depends on; /proc is this process's
 * own entry and no peer's, and confine.sh's PEEROOM_BLOCKED is what says so.
 * Each was measured -- shm=CTO, devnull=OK -- and the one grant that measured
 * backwards, $XDG_RUNTIME_DIR, is gone rather than described.
 *
 * "writes confined to" is a claim about a set. It named the first member of it
 * for as long as this file has existed.
 */
/*
 * "and /proc/self", not "and every process's /proc entry", on every build --
 * because the rule below is the narrow one on every build now. These two were
 * a tier apart, and a sentence that outlived its rule by one commit is the
 * defect ground rule 5 exists for: --info would have promised the wide grant
 * while the ruleset refused it, which is the same lie in the safer direction
 * and still a lie.
 */
#define NT_ALSO_WRITABLE ", /dev, /dev/shm and /proc/self"
/*
 * Empty, and it stays a macro rather than becoming nothing at the two call
 * sites, because the fetch phase's set is a claim about what it grants and
 * naming it in one place is what stopped that sentence drifting from the rules.
 * It was " and /dev" under the tight tier, which granted the fetch child a
 * device write it does not need -- measured: with the grant removed the fetch
 * still succeeds.
 */
#define NT_FETCH_ALSO_WRITABLE ""

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
     * No scoping and no network rules, and both were deleted rather than
     * kept, because both are decided by the kernel version underneath.
     *
     * LANDLOCK_SCOPE_SIGNAL and LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET need ABI 6,
     * which is 6.12; LANDLOCK_ACCESS_NET_BIND_TCP needs ABI 4, which is 6.7.
     * Debian 12 is on 6.1 and Ubuntu 24.04 on 6.8, and both are in support --
     * so an app could reach a peer's signals, or bind a port, on one supported
     * machine and not another, with nothing in the artifact to say which. That
     * is a support matrix in the one place there is not supposed to be one, and
     * a capability the promise cannot name is not one worth having.
     *
     * The abstract-socket half additionally read $DISPLAY at runtime and
     * applied itself only when there was no X11 display to break -- the same
     * fact twice over, since a machine with a display got a weaker sandbox than
     * the same machine without one.
     *
     * What is left is the filesystem, which every supported kernel with
     * Landlock at all can express identically.
     */
    ruleset = nt_ll_create(&attr, sizeof(attr), 0);
    if (ruleset < 0) {
        snprintf(desc, desclen, "none (landlock ruleset rejected)%s", secc);
        return -1;
    }

    if (phase == NT_PHASE_FETCH) {
        snprintf(path, sizeof(path), "%s/blobs", home);
        nt_allow(ruleset, path, rights);
        snprintf(desc, desclen, "landlock abi %d%s, writes confined to %s"
                 NT_FETCH_ALSO_WRITABLE,
                 abi, secc, path);
    } else {
        nt_allow(ruleset, appdir, rights);
        nt_allow(ruleset, "/dev", NT_READ_RIGHTS | LANDLOCK_ACCESS_FS_WRITE_FILE);
        nt_allow(ruleset, "/dev/shm", rights);
        /*
         * Write on /proc is write on *every* process's entry, not just this
         * one's. Measured: thirteen files under a same-uid peer open for
         * writing, and a real write to a peer's oom_score_adj succeeds --
         * against a process this same ruleset cannot otherwise reach
         * from. No execution and no read, but it contradicts a guarantee made
         * two lines up, so the default tier owes an explanation and the README
         * carries one.
         *
         * Narrowing to /proc/self closes it and is not free, which is why it is
         * a tier decision rather than a fix. nt_allow opens O_PATH, so
         * /proc/self resolves at rule time and the rule is pinned to the pid
         * that builds the ruleset: every child loses write to its own entry as
         * well as to a peer's, and landlock has no rule shape that means "each
         * process's own entry". What that takes with it, measured:
         *
         *   - a descendant's oom_score_adj, which chromium's zygote writes;
         *   - a child's own /proc entry, whatever it wanted there;
         *   - and the one that decides this -- a parent writing a child's
         *     setgroups and uid_map after that child unshares a user
         *     namespace, which is exactly how bubblewrap and chromium's
         *     namespace_sandbox.c set up the sandboxes that stack on top of
         *     this one. USERNSMAP_OK here, USERNSMAP_BLOCKED narrowed.
         *
         * So the default tier keeps the grant and says so, and the tight tier
         * -- which already trades reads and w^x for confinement, and whose
         * users have accepted that trade -- takes the narrower rule. The
         * session tier needs neither: a pid namespace leaves no peer in /proc
         * to write to, which is the better answer where a user namespace can
         * be had, and confine-session.sh gates it.
         *
         * The /proc rule keeps NT_READ_RIGHTS above the narrowed write rule,
         * because landlock accumulates rights walking up the hierarchy rather
         * than letting the deepest rule decide alone. PROCSELFREAD_OK asks
         * that rather than assuming it.
         *
         * Added after nt_apply_session, which is where a pid namespace would
         * have changed both the pid /proc/self resolves to and the /proc it is
         * resolved in.
         */
        /*
         * The write is on this process's own entry and not on every process's,
         * and that used to be the difference between the tiers.
         *
         * The wide grant was a real reach across: measured, thirteen files
         * under a peer's /proc/<pid> open for writing -- oom_score_adj, sched,
         * clear_refs, coredump_filter, timerslack_ns and the id maps among
         * them -- and a write to a peer's oom_score_adj succeeding, which marks
         * a same-uid process for the OOM killer. That is not code execution and
         * it reads nothing, but it reaches a process this same ruleset scopes
         * signals away from, so the narrow rule is what makes the sentence
         * beside it true.
         *
         * It costs nothing measured. PROCSELFREAD_OK says a confined app still
         * reads under its own entry, because Landlock takes the union along a
         * path and the read rule above sits over the narrowed write; and
         * verify-linux.sh renders identically under both grants on WebKitGTK
         * and QtWebEngine, with identical oom_score_adj on every engine
         * process. Chromium's "Failed to adjust OOM score of renderer" predates
         * this and is the kernel refusing without CAP_SYS_RESOURCE.
         */
        nt_allow(ruleset, "/proc", NT_READ_RIGHTS);
        nt_allow(ruleset, "/proc/self", LANDLOCK_ACCESS_FS_WRITE_FILE);
        /*
         * Reads here, and no write, and the write is what this rule used to be.
         * It granted WRITE_FILE with no MAKE_REG beside it, and the two halves
         * of that are not the same thing: measured on both linux lanes and in
         * both tiers, a confined app could neither create a file in the session
         * runtime directory nor truncate one, and could write over one that was
         * already there. Creating is what a toolkit wanting a runtime file of
         * its own would do; writing over what is already there is what nothing
         * legitimate here does, because nothing here owns a file in that
         * directory. So the grant admitted the half nobody needed and refused
         * the half it was presumably for, and every lane was green without it.
         *
         * The read stays, and only the tight tier has one to keep: reads are
         * unhandled in the default tier, so with the write gone there is no
         * rule left to add there at all. A client that cannot read
         * $XDG_RUNTIME_DIR is a client with no display, which is the cost the
         * tight tier already pays attention to.
         *
         * The session tier is the better answer where it can be had, and it is
         * a different one: a tmpfs over this directory with the compositor and
         * audio sockets bound back in. See nt_seal_runtime.
         */
        /*
         * No read grants here at all any more, and none needed: nothing is
         * denied a read, so nothing has to be handed one back. The script
         * living one level above the writable directory still stops an app
         * rewriting its own launcher, which was always the point of the split
         * -- it just no longer costs a rule to keep sh able to read it.
         */
        snprintf(desc, desclen, "landlock abi %d%s, writes confined to "
                 "%s" NT_ALSO_WRITABLE,
                 abi, secc, appdir);
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
    /*
     * 0 or -1, and never -2 or -3 any more. Those existed for the session tier,
     * which was the one mechanism here built out of steps that could fail
     * separately after the first had already changed the process. Nothing left
     * in this file has that shape: landlock is applied in one call that either
     * takes or does not.
     */
    return 0;
}

#endif
