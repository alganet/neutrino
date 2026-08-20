/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

/*
 * session-probe.c - one named technique, applied to a real program.
 *
 * netinstall mediates paths, syscalls and TCP, and none of that reaches the two
 * things a linux desktop hands every process for free: the session bus and the
 * X11 display. Connecting to a pathname unix socket is not a filesystem
 * operation any Landlock rule can see, so the only lever left is to make the
 * path not lead to a socket -- which means a mount namespace, which means a user
 * namespace, which the distribution may refuse to hand out.
 *
 * This applies one candidate and then execs what it was given, so the suite can
 * put a real webview behind each one and record what survives. Nothing here is
 * shipped; it exists to answer whether any of it can be.
 *
 *   session-probe [technique flags] [--] command...
 *   session-probe --report
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef LANDLOCK_CREATE_RULESET_VERSION
#define LANDLOCK_CREATE_RULESET_VERSION (1U << 0)
#endif
#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#endif

#define P_PATH 512

struct opts {
    int userns;
    int mountns;
    int pidns;
    int netns;
    int hide_bus;
    int hide_x11;
    int hide_agents;
    int seal_runtime;
    int report;
};

static int nt_write(const char *path, const char *value)
{
    ssize_t n;
    int fd = open(path, O_WRONLY | O_CLOEXEC);

    if (fd < 0) {
        return -1;
    }
    n = write(fd, value, strlen(value));
    close(fd);
    return n < 0 ? -1 : 0;
}

/*
 * A single-line identity map of the caller's own id is the one map an
 * unprivileged process may write, and only after setgroups is denied. Ubuntu's
 * AppArmor default hands out the namespace and refuses this, which is the whole
 * reason the report mode exists.
 *
 * The ids are the ones read before the namespace existed, and that is not a
 * detail: inside a namespace with no map yet, getuid() answers the overflow uid,
 * and a map naming 65534 is refused with the same EPERM a distribution ban
 * gives. Cost an hour once; written down so it cannot cost a second one.
 */
static uid_t nt_uid;
static gid_t nt_gid;

static int nt_map_self(void)
{
    char line[64];

    nt_write("/proc/self/setgroups", "deny");
    snprintf(line, sizeof(line), "%u %u 1\n", (unsigned)nt_uid, (unsigned)nt_uid);
    if (nt_write("/proc/self/uid_map", line) != 0) {
        return -1;
    }
    snprintf(line, sizeof(line), "%u %u 1\n", (unsigned)nt_gid, (unsigned)nt_gid);
    nt_write("/proc/self/gid_map", line);
    return 0;
}

/*
 * /dev/null over a socket rather than an empty file over it: the cover has to
 * be a non-directory or the bind is refused, and connecting to a path that
 * resolves to something which is not a socket answers ECONNREFUSED. That is the
 * errno a client already knows how to read as "nothing is listening there",
 * where EPERM is the one libxcb declines to retry on.
 */
static int nt_cover(const char *path)
{
    struct stat st;

    if (stat(path, &st) != 0) {
        return 0;               /* nothing there to hide */
    }
    if (mount("/dev/null", path, NULL, MS_BIND, NULL) != 0) {
        fprintf(stderr, "session-probe: cover %s: %s\n", path, strerror(errno));
        return -1;
    }
    return 0;
}

static const char *nt_runtime_dir(void)
{
    static char buf[P_PATH];
    const char *rt = getenv("XDG_RUNTIME_DIR");

    if (rt && *rt) {
        return rt;
    }
    snprintf(buf, sizeof(buf), "/run/user/%u", (unsigned)nt_uid);
    return buf;
}

static int nt_hide_buses(void)
{
    char path[P_PATH];
    int rc = 0;

    snprintf(path, sizeof(path), "%s/bus", nt_runtime_dir());
    rc |= nt_cover(path);
    rc |= nt_cover("/run/dbus/system_bus_socket");
    rc |= nt_cover("/var/run/dbus/system_bus_socket");
    return rc;
}

/*
 * Every agent socket that signs or decrypts on request. SSH_AUTH_SOCK is
 * already dropped from the environment before an app starts, which raises the
 * bar and does not close the door: the gnome-keyring and gpg sockets sit at
 * derivable paths under the runtime dir.
 */
static int nt_hide_agents(void)
{
    static const char *const names[] = {
        "keyring/ssh", "keyring/control", "keyring/pkcs11",
        "gnupg/S.gpg-agent", "gnupg/S.gpg-agent.ssh", NULL
    };
    char path[P_PATH];
    const char *sock = getenv("SSH_AUTH_SOCK");
    int rc = 0;
    int i;

    for (i = 0; names[i]; i++) {
        snprintf(path, sizeof(path), "%s/%s", nt_runtime_dir(), names[i]);
        rc |= nt_cover(path);
    }
    if (sock && *sock) {
        rc |= nt_cover(sock);
    }
    return rc;
}

/*
 * The covers above are a denylist, and this is the allowlist: a fresh tmpfs
 * over the runtime directory, with only the sockets an app is meant to keep
 * bound back into it. Everything else in there -- the bus, the keyring, the
 * portal, pipewire's manager socket, whatever the next desktop release adds --
 * is gone without having to be named.
 *
 * The keepers are pinned by an O_PATH descriptor before the tmpfs goes on,
 * because once it is on there is no path left to bind from; /proc/self/fd/<n>
 * still resolves to the original, which is exactly what makes this work. The
 * new directory is writable, so an app that wants a runtime file of its own
 * gets one that disappears with it.
 */
static const char *const nt_runtime_keep[] = {
    "wayland-0", "wayland-1", "pulse/native", "pipewire-0", "pipewire-0-manager", NULL
};

static int nt_seal_runtime(void)
{
    const char *rt = nt_runtime_dir();
    const char *wayland = getenv("WAYLAND_DISPLAY");
    const char *names[16];
    int fds[16];
    char path[P_PATH];
    char target[P_PATH];
    char source[64];
    struct stat st;
    int n = 0;
    int i;

    if (wayland && *wayland && *wayland != '/') {
        names[n++] = wayland;
    }
    for (i = 0; nt_runtime_keep[i] && n < 15; i++) {
        names[n++] = nt_runtime_keep[i];
    }

    for (i = 0; i < n; i++) {
        snprintf(path, sizeof(path), "%s/%s", rt, names[i]);
        fds[i] = open(path, O_PATH | O_CLOEXEC);
    }

    if (mount("none", rt, "tmpfs", MS_NOSUID | MS_NODEV, "mode=0700") != 0) {
        fprintf(stderr, "session-probe: seal %s: %s\n", rt, strerror(errno));
        return -1;
    }

    for (i = 0; i < n; i++) {
        if (fds[i] < 0) {
            continue;
        }
        snprintf(source, sizeof(source), "/proc/self/fd/%d", fds[i]);
        snprintf(target, sizeof(target), "%s/%s", rt, names[i]);
        if (strchr(names[i], '/')) {
            char *cut;

            snprintf(path, sizeof(path), "%s", target);
            cut = strrchr(path, '/');
            if (cut) {
                *cut = '\0';
                mkdir(path, 0700);
            }
        }
        if (fstat(fds[i], &st) == 0 && S_ISDIR(st.st_mode)) {
            mkdir(target, 0700);
        } else {
            int fd = open(target, O_CREAT | O_WRONLY | O_CLOEXEC, 0600);

            if (fd >= 0) {
                close(fd);
            }
        }
        if (mount(source, target, NULL, MS_BIND, NULL) != 0) {
            fprintf(stderr, "session-probe: keep %s: %s\n", names[i], strerror(errno));
        }
        close(fds[i]);
    }
    return 0;
}

/*
 * The X11 pathname sockets all live in one directory, so an empty read-only
 * tmpfs over it is the whole hiding. The abstract socket an X client asks for
 * first lives in the network namespace instead, and is only closed by --netns
 * or by Landlock's abstract-socket scope.
 */
static int nt_hide_x11(void)
{
    if (mount("none", "/tmp/.X11-unix", "tmpfs", MS_RDONLY | MS_NOSUID | MS_NODEV,
              "mode=0755") != 0) {
        fprintf(stderr, "session-probe: hide x11: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

/* Without loopback up, a network namespace also takes local IPC down, and the
 * measurement stops being about the internet. */
static void nt_loopback_up(void)
{
    struct ifreq ifr;
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);

    if (fd < 0) {
        return;
    }
    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "lo");
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) == 0) {
        ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
        ioctl(fd, SIOCSIFFLAGS, &ifr);
    }
    close(fd);
}

static int nt_apply(const struct opts *o)
{
    int flags = 0;

    if (o->userns) {
        flags |= CLONE_NEWUSER;
    }
    if (o->mountns) {
        flags |= CLONE_NEWNS;
    }
    if (o->pidns) {
        flags |= CLONE_NEWPID;
    }
    if (o->netns) {
        flags |= CLONE_NEWNET;
    }
    if (!flags) {
        return 0;
    }
    if (unshare(flags) != 0) {
        fprintf(stderr, "session-probe: unshare: %s\n", strerror(errno));
        return -1;
    }
    if (o->userns && nt_map_self() != 0) {
        fprintf(stderr, "session-probe: uid_map: %s\n", strerror(errno));
        return -1;
    }
    if (o->netns) {
        nt_loopback_up();
    }
    if (o->mountns) {
        /*
         * Without this every cover below propagates back out to the session
         * that started us, which would hide the bus from the whole desktop.
         */
        if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
            fprintf(stderr, "session-probe: make-private: %s\n", strerror(errno));
            return -1;
        }
    }
    if (o->seal_runtime && nt_seal_runtime() != 0) {
        return -1;
    }
    if (o->hide_bus && nt_hide_buses() != 0) {
        return -1;
    }
    if (o->hide_agents && nt_hide_agents() != 0) {
        return -1;
    }
    if (o->hide_x11 && nt_hide_x11() != 0) {
        return -1;
    }
    return 0;
}

/*
 * A pid namespace is not entered by the process that asks for it, only by its
 * children, so this is where the probe stops being a plain exec. It is here
 * because a mount namespace on its own is not a boundary: /proc/<pid>/root of
 * any process left outside it is a path back to the sockets that were covered,
 * and Yama is the only thing standing in front of that.
 */
static int nt_fork_into_pidns(void)
{
    pid_t child = fork();
    int status = 0;

    if (child < 0) {
        fprintf(stderr, "session-probe: fork: %s\n", strerror(errno));
        return -1;
    }
    if (child == 0) {
        if (mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC,
                  NULL) != 0) {
            fprintf(stderr, "session-probe: mount /proc: %s\n", strerror(errno));
        }
        return 0;
    }
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
        continue;
    }
    if (WIFSIGNALED(status)) {
        _exit(128 + WTERMSIG(status));
    }
    _exit(WEXITSTATUS(status));
}

static int nt_landlock_abi(void)
{
    return (int)syscall(__NR_landlock_create_ruleset, NULL, 0,
                        LANDLOCK_CREATE_RULESET_VERSION);
}

static int nt_connects(const char *path)
{
    struct sockaddr_un addr;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    int rc;

    if (fd < 0) {
        return -1;
    }
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    close(fd);
    return rc == 0 ? 1 : 0;
}

/*
 * Each answer comes from a child, so asking the question does not confine the
 * process that asked it -- and the child says which step failed, not just that
 * something did. That distinction cost a day: an earlier version reported the
 * errno alone, and "unshare refused" and "namespace granted, uid map refused"
 * are both EPERM. They are not the same machine. Ubuntu's AppArmor default
 * produces the second: the namespace is handed over and then nothing can be
 * done with it.
 */
static void nt_try(const char *label, int flags, int map)
{
    pid_t pid;

    fflush(stdout);
    pid = fork();
    if (pid < 0) {
        printf("%s: unmeasured (fork failed)\n", label);
        return;
    }
    if (pid == 0) {
        if (unshare(flags) != 0) {
            printf("%s: unshare refused: %s\n", label, strerror(errno));
        } else if (map && nt_map_self() != 0) {
            printf("%s: namespace granted, uid map refused: %s\n", label,
                   strerror(errno));
        } else {
            printf("%s: ok\n", label);
        }
        fflush(stdout);
        _exit(0);
    }
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
        continue;
    }
}

/*
 * The escape a mount namespace does not close on its own: a process left
 * outside it publishes its own root through /proc, and connect() walks that
 * path like any other. Whether it is reachable is Yama's call, not ours, so it
 * is measured rather than assumed.
 */
static void nt_report_proc_escape(void)
{
    char path[P_PATH];
    pid_t outside = getpid();
    pid_t pid;
    int status = 0;

    snprintf(path, sizeof(path), "%s/bus", nt_runtime_dir());
    if (!nt_connects(path)) {
        printf("proc-root-escape: untested (no session bus at %s)\n", path);
        return;
    }
    pid = fork();
    if (pid < 0) {
        return;
    }
    if (pid == 0) {
        char escape[P_PATH];

        if (unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0 || nt_map_self() != 0) {
            _exit(2);
        }
        mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
        if (nt_hide_buses() != 0) {
            _exit(2);
        }
        snprintf(escape, sizeof(escape), "%s/bus", nt_runtime_dir());
        if (nt_connects(escape)) {
            _exit(3);           /* the cover itself did not hold */
        }
        snprintf(escape, sizeof(escape), "/proc/%d/root%s/bus",
                 (int)outside, nt_runtime_dir());
        _exit(nt_connects(escape) ? 1 : 0);
    }
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        continue;
    }
    switch (WIFEXITED(status) ? WEXITSTATUS(status) : -1) {
    case 0:  printf("proc-root-escape: blocked\n"); break;
    case 1:  printf("proc-root-escape: OPEN (a mount namespace alone is not a boundary here)\n"); break;
    case 3:  printf("proc-root-escape: cover did not hold\n"); break;
    default: printf("proc-root-escape: untested (namespace unavailable)\n"); break;
    }
}

static void nt_read_sysctl(const char *path)
{
    char buf[64];
    ssize_t n;
    int fd = open(path, O_RDONLY | O_CLOEXEC);

    if (fd < 0) {
        printf("%s: absent\n", path);
        return;
    }
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) {
        printf("%s: unreadable\n", path);
        return;
    }
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) {
        buf[--n] = '\0';
    }
    printf("%s: %s\n", path, buf);
}

static int nt_report(void)
{
    char path[P_PATH];

    nt_try("userns", CLONE_NEWUSER, 1);
    nt_try("userns+mountns", CLONE_NEWUSER | CLONE_NEWNS, 1);
    nt_try("userns+pidns", CLONE_NEWUSER | CLONE_NEWPID, 1);
    nt_try("userns+netns", CLONE_NEWUSER | CLONE_NEWNET, 1);
    printf("landlock: abi %d\n", nt_landlock_abi());
    nt_read_sysctl("/proc/sys/kernel/yama/ptrace_scope");
    nt_read_sysctl("/proc/sys/kernel/apparmor_restrict_unprivileged_userns");
    nt_read_sysctl("/proc/sys/kernel/unprivileged_userns_clone");
    nt_read_sysctl("/proc/sys/user/max_user_namespaces");
    snprintf(path, sizeof(path), "%s/bus", nt_runtime_dir());
    printf("session bus at %s: %s\n", path, nt_connects(path) ? "listening" : "absent");
    printf("system bus: %s\n",
           nt_connects("/run/dbus/system_bus_socket") ? "listening" : "absent");
    printf("x11 socket: %s\n",
           nt_connects("/tmp/.X11-unix/X0") ? "listening" : "absent");
    nt_report_proc_escape();
    return 0;
}

static void nt_usage(void)
{
    fprintf(stderr,
        "usage: session-probe [technique] [--] command...\n"
        "       session-probe --report\n"
        "\n"
        "  --userns       user namespace only (implied by everything below)\n"
        "  --mountns      user + mount namespace\n"
        "  --pidns        add a pid namespace and a fresh /proc\n"
        "  --netns        add a network namespace, loopback up\n"
        "  --hide-bus     cover the session and system bus sockets\n"
        "  --hide-x11     empty tmpfs over /tmp/.X11-unix\n"
        "  --hide-agents  cover the keyring and gpg agent sockets\n"
        "  --seal-runtime empty tmpfs over the runtime dir, keeping only the\n"
        "                 compositor and audio sockets\n");
}

int main(int argc, char **argv)
{
    struct opts o;
    int i;

    memset(&o, 0, sizeof(o));
    nt_uid = getuid();
    nt_gid = getgid();
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) {
            i++;
            break;
        } else if (strcmp(argv[i], "--report") == 0) {
            o.report = 1;
        } else if (strcmp(argv[i], "--userns") == 0) {
            o.userns = 1;
        } else if (strcmp(argv[i], "--mountns") == 0) {
            o.mountns = 1;
        } else if (strcmp(argv[i], "--pidns") == 0) {
            o.pidns = 1;
        } else if (strcmp(argv[i], "--netns") == 0) {
            o.netns = 1;
        } else if (strcmp(argv[i], "--hide-bus") == 0) {
            o.hide_bus = 1;
        } else if (strcmp(argv[i], "--hide-x11") == 0) {
            o.hide_x11 = 1;
        } else if (strcmp(argv[i], "--hide-agents") == 0) {
            o.hide_agents = 1;
        } else if (strcmp(argv[i], "--seal-runtime") == 0) {
            o.seal_runtime = 1;
        } else if (strncmp(argv[i], "--", 2) == 0) {
            nt_usage();
            return 2;
        } else {
            break;
        }
    }

    if (o.report) {
        return nt_report();
    }
    if (i >= argc) {
        nt_usage();
        return 2;
    }

    /* Every technique here needs a user namespace to hold it. */
    if (o.mountns || o.pidns || o.netns || o.hide_bus || o.hide_x11 ||
        o.hide_agents || o.seal_runtime) {
        o.userns = 1;
    }
    if (o.hide_bus || o.hide_x11 || o.hide_agents || o.seal_runtime || o.pidns) {
        o.mountns = 1;
    }

    if (nt_apply(&o) != 0) {
        return 3;
    }
    if (o.pidns && nt_fork_into_pidns() != 0) {
        return 3;
    }

    execvp(argv[i], argv + i);
    fprintf(stderr, "session-probe: exec %s: %s\n", argv[i], strerror(errno));
    return 4;
}
