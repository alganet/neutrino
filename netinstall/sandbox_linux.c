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

/*
 * Set when the session tier managed to put an untrusted cookie in the app's
 * hands. The tight tier reads it: leaving the trusted cookie on the read
 * allowlist would hand back exactly what the untrusted one took away.
 */
#ifdef NEUTRINO_CONFINE_NOSESSION
static int nt_x11_replaced;
#else
#define nt_x11_replaced 0
#endif

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
            if (nt_x11_replaced && strcmp(home_paths[i], "/.Xauthority") == 0) {
                continue;
            }
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
 * The session tier, and the namespaces it is built on.
 *
 * connect(2) to a pathname unix socket is not a filesystem operation. No
 * Landlock rule sees it, measured rather than inferred: under a ruleset that
 * grants nothing but /usr, connects to the session bus, the ssh-agent socket
 * and /tmp/.X11-unix/X0 all still succeed. So the session bus stays reachable
 * to a confined app, and an app that reaches the session bus can ask systemd
 * for StartTransientUnit and start a process outside everything here.
 *
 * The only lever left is to make the path stop leading to a socket, which means
 * a mount namespace, which means a user namespace. Ubuntu 24.04 and its
 * derivatives refuse those to any binary without an AppArmor profile -- unshare
 * itself returns EPERM there -- so this tier is available on some machines and
 * not others, and --info says which.
 */
#if defined(NEUTRINO_CONFINE_NOSESSION) || defined(NEUTRINO_CONFINE_OFFLINE)
#define NT_USE_NAMESPACES 1
#endif

#ifdef NT_USE_NAMESPACES

/*
 * Read before any namespace exists, and that is not a detail: inside a user
 * namespace with no map written yet, getuid() answers the overflow uid, and a
 * map naming 65534 is refused with the same EPERM a distribution ban gives.
 */
static uid_t nt_uid;
static gid_t nt_gid;

static int nt_write_file(const char *path, const char *value)
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

/* The one map an unprivileged process may write: a single line naming its own
 * id, and only once setgroups is denied. */
static int nt_map_self(void)
{
    char line[64];

    nt_write_file("/proc/self/setgroups", "deny");
    snprintf(line, sizeof(line), "%u %u 1\n", (unsigned)nt_uid, (unsigned)nt_uid);
    if (nt_write_file("/proc/self/uid_map", line) != 0) {
        return -1;
    }
    snprintf(line, sizeof(line), "%u %u 1\n", (unsigned)nt_gid, (unsigned)nt_gid);
    nt_write_file("/proc/self/gid_map", line);
    return 0;
}

/* Joining rather than snprintf at every call site: a path that silently loses
 * its tail is a path that means something else. */
static int nt_join(char *out, size_t len, const char *dir, const char *name)
{
    int n = snprintf(out, len, "%s/%s", dir, name);

    return (n < 0 || (size_t)n >= len) ? -1 : 0;
}

static const char *nt_runtime_dir(void)
{
    static char buf[NT_PATH_MAX];
    const char *rt = getenv("XDG_RUNTIME_DIR");

    if (rt && *rt) {
        return rt;
    }
    snprintf(buf, sizeof(buf), "/run/user/%u", (unsigned)nt_uid);
    return buf;
}

/*
 * /dev/null over the socket, rather than an empty file: a bind mount refuses a
 * directory over a non-directory, and connecting to a path that resolves to
 * something which is not a socket answers ECONNREFUSED -- the errno a client
 * already reads as "nothing is listening", where EPERM is the one libxcb
 * declines to retry on.
 */
static void nt_cover(const char *path)
{
    struct stat st;

    if (stat(path, &st) != 0) {
        return;
    }
    mount("/dev/null", path, NULL, MS_BIND, NULL);
}

/*
 * An allowlist rather than a list of socket names to cover, for the same reason
 * the environment is one: a denylist has to enumerate every socket a desktop
 * has ever put in the runtime directory and silently passes the next one. A
 * fresh tmpfs goes over the directory and only the sockets an app is meant to
 * keep are bound back into it -- the compositor and audio. The bus, the
 * keyring, the portal and whatever the next release adds are gone without being
 * named.
 *
 * The keepers are pinned by an O_PATH descriptor first, because once the tmpfs
 * is on there is no path left to bind from; /proc/self/fd/<n> still resolves to
 * the original. What is left is writable, so an app that wants a runtime file
 * of its own gets one that leaves with it.
 */
static const char *const nt_runtime_keep[] = {
    "wayland-0", "wayland-1", "pulse/native", "pipewire-0", "pipewire-0-manager",
    NULL
};

static int nt_seal_runtime(void)
{
    const char *rt = nt_runtime_dir();
    const char *wayland = getenv("WAYLAND_DISPLAY");
    struct stat rtst;
    const char *names[16];
    int fds[16];
    char path[NT_PATH_MAX];
    char target[NT_PATH_MAX];
    char source[64];
    struct stat st;
    int n = 0;
    int i;

    /* A machine with no runtime directory has nothing here to seal, which is
     * not the same as failing to seal it. */
    if (stat(rt, &rtst) != 0 || !S_ISDIR(rtst.st_mode)) {
        return 0;
    }
    if (wayland && *wayland && *wayland != '/') {
        names[n++] = wayland;
    }
    for (i = 0; nt_runtime_keep[i] && n < 15; i++) {
        names[n++] = nt_runtime_keep[i];
    }
    for (i = 0; i < n; i++) {
        fds[i] = nt_join(path, sizeof(path), rt, names[i]) == 0
                     ? open(path, O_PATH | O_CLOEXEC) : -1;
    }

    if (mount("none", rt, "tmpfs", MS_NOSUID | MS_NODEV, "mode=0700") != 0) {
        for (i = 0; i < n; i++) {
            if (fds[i] >= 0) {
                close(fds[i]);
            }
        }
        return -1;
    }

    for (i = 0; i < n; i++) {
        char *cut;

        if (fds[i] < 0) {
            continue;
        }
        snprintf(source, sizeof(source), "/proc/self/fd/%d", fds[i]);
        if (nt_join(target, sizeof(target), rt, names[i]) != 0) {
            close(fds[i]);
            continue;
        }
        snprintf(path, sizeof(path), "%s", target);
        cut = strrchr(path, '/');
        if (cut && cut != path) {
            *cut = '\0';
            mkdir(path, 0700);
        }
        if (fstat(fds[i], &st) == 0 && S_ISDIR(st.st_mode)) {
            mkdir(target, 0700);
        } else {
            int fd = open(target, O_CREAT | O_WRONLY | O_CLOEXEC, 0600);

            if (fd >= 0) {
                close(fd);
            }
        }
        mount(source, target, NULL, MS_BIND, NULL);
        close(fds[i]);
    }
    return 0;
}

/* Without loopback up a network namespace takes local IPC down with the
 * internet, and the tier stops being about the network. */
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

/*
 * A mount namespace on its own is not a boundary: /proc/<pid>/root of any
 * process left outside it is a path straight back to the sockets that were
 * covered, and only Yama's ptrace_scope stands in front of that -- which is 1 on
 * Debian and Ubuntu and 0 on plenty of other distributions. A pid namespace
 * with its own /proc leaves no outside process to walk through.
 *
 * It is also why this function may not return in the caller: the process that
 * asks for a pid namespace does not enter it, only its children do. So
 * netinstall forks, the child becomes pid 1 of the new namespace and goes on to
 * exec the app, and netinstall itself stays behind as its parent, waiting and
 * exiting with whatever the app returned. That is the one place on this
 * platform where the launcher does not become the app.
 *
 * Being pid 1 has a consequence worth knowing: when the app exits, the kernel
 * takes the rest of the namespace with it. The polyglot execs its runtime
 * rather than backgrounding it, so there is nothing to strand -- but an app
 * that forks and exits early would find its children gone, where without this
 * they would have been reparented and left running.
 */
static int nt_enter_pidns(void)
{
    pid_t child = fork();
    pid_t gone;
    int status = 0;
    int code = 0;

    if (child < 0) {
        return -1;
    }
    if (child == 0) {
        mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
        return 0;
    }
    for (;;) {
        gone = waitpid(-1, &status, 0);
        if (gone < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;                      /* ECHILD: nothing left to wait for */
        }
        if (gone == child) {
            code = WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                       : WEXITSTATUS(status);
        }
    }
    _exit(code);
}

/*
 * Asks the same question the enforcing path is about to ask, in a child, so
 * nothing here confines the process that is asking -- and so the enforcing path
 * can decline to start something it cannot finish.
 *
 * That last part is not tidiness. A process that enters a user namespace and
 * then fails to write its own uid map is left as the overflow uid: its view of
 * the filesystem is unchanged and every file it owns has become unreadable,
 * which is a worse place to be than not having tried. Ask first, in a child
 * that can be thrown away.
 *
 * The failing step and its errno come back over a pipe, because "the namespace
 * was refused" and "the map was refused" are different sentences and --info is
 * the line someone reads when they want to know which.
 */
static int nt_namespace_available(int flags, char *why, size_t whylen)
{
    int fds[2];
    int report[2] = { 0, 0 };
    pid_t pid;
    int status = 0;

    if (why && whylen) {
        *why = '\0';
    }
    if (pipe(fds) != 0) {
        return 0;
    }
    pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return 0;
    }
    if (pid == 0) {
        close(fds[0]);
        report[0] = 0;
        if (unshare(flags) != 0) {
            report[0] = 1;
            report[1] = errno;
        } else if (nt_map_self() != 0) {
            report[0] = 2;
            report[1] = errno;
        }
        if (write(fds[1], report, sizeof(report)) != sizeof(report)) {
            _exit(1);
        }
        _exit(report[0] == 0 ? 0 : 1);
    }
    close(fds[1]);
    if (read(fds[0], report, sizeof(report)) != (ssize_t)sizeof(report)) {
        report[0] = 3;
        report[1] = 0;
    }
    close(fds[0]);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        continue;
    }
    if (report[0] == 0) {
        return 1;
    }
    if (why && whylen) {
        snprintf(why, whylen, "%s refused: %s",
                 report[0] == 1 ? "namespace" :
                 report[0] == 2 ? "uid map" : "namespace probe",
                 report[1] ? strerror(report[1]) : "no answer");
    }
    return 0;
}

static int nt_session_flags(int hide, int net)
{
    int flags = CLONE_NEWUSER;

    if (hide) {
        flags |= CLONE_NEWNS | CLONE_NEWPID;
    }
    if (net) {
        flags |= CLONE_NEWNET;
    }
    return flags;
}

/*
 * Returns 0 when the session was closed as asked, -1 when the namespace was
 * refused outright, and -2 when it was granted and something after it failed --
 * which is a different sentence in --info, because the app is then in a
 * half-built namespace rather than the one it started in. May not return at
 * all: see nt_enter_pidns.
 */
static int nt_close_session(int hide, int net)
{
    if (unshare(nt_session_flags(hide, net)) != 0 || nt_map_self() != 0) {
        return -1;
    }
    if (net) {
        nt_loopback_up();
    }
    if (!hide) {
        return 0;
    }
    /* Or every cover below propagates back out into the session that started
     * us, and hides the bus from the whole desktop. */
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
        return -2;
    }
    if (nt_seal_runtime() != 0) {
        return -2;
    }
    /* The system bus is not in the runtime dir, and the seal does not reach
     * it. polkit and systemd are on the other end of it. */
    nt_cover("/run/dbus/system_bus_socket");
    nt_cover("/var/run/dbus/system_bus_socket");
    /*
     * The display can only be hidden when the app does not need it. On an X11
     * session it does, and what is left there is the untrusted-cookie question,
     * which is not this tier. The abstract name X clients ask for first belongs
     * to the network namespace, not this one, so scoping or --offline is what
     * closes that half.
     */
    if (!getenv("DISPLAY")) {
        mount("none", "/tmp/.X11-unix", "tmpfs",
              MS_RDONLY | MS_NOSUID | MS_NODEV, "mode=0755");
    }
    return nt_enter_pidns() == 0 ? 0 : -2;
}

#ifdef NEUTRINO_CONFINE_NOSESSION
/*
 * The display cannot be hidden, because the app needs it. What can be done is
 * to hand it a cookie the server itself distrusts.
 *
 * The X11 SECURITY extension splits clients in two. A trusted one may read
 * every other client's windows and input; an untrusted one is refused both.
 * Measured on both engines rather than argued: under an untrusted cookie a
 * screen capture of the root window is refused where a trusted client gets a
 * PNG, and a client that grabs the keyboard and waits sees none of the keys
 * that a trusted client in the same position sees. The cost is the extension
 * list, which drops from twenty-three to two -- no XTEST, no RECORD, and no
 * XKB, MIT-SHM or GLX either. WebKitGTK and QtWebEngine both still came up.
 *
 * This is a boundary only while the trusted cookie stays out of reach. In the
 * default tier reads are unconfined, so an app can read ~/.Xauthority and
 * connect trusted anyway -- there it raises the bar and no more. With
 * -DNEUTRINO_CONFINE_TIGHT the trusted cookie is not on the read allowlist and
 * the session tier seals the runtime directory where a display manager keeps
 * the other copy, and then it holds.
 */
static int nt_x11_untrusted(const char *appdir)
{
    static const char *const xauth[] = {
        "/usr/bin/xauth", "/bin/xauth", "/usr/local/bin/xauth",
        "/usr/X11R6/bin/xauth", NULL
    };
    char out[NT_PATH_MAX];
    const char *display = getenv("DISPLAY");
    pid_t pid;
    int status = 0;
    int i;
    int fd;

    if (!display || !*display) {
        return -1;
    }
    if (nt_join(out, sizeof(out), appdir, ".Xauthority-untrusted") != 0) {
        return -1;
    }
    /* xauth appends to what is there, so a stale file from a previous launch
     * would leave the old entry in front of the new one. */
    unlink(out);
    fd = open(out, O_CREAT | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) {
        return -1;
    }
    close(fd);

    for (i = 0; xauth[i]; i++) {
        if (access(xauth[i], X_OK) != 0) {
            continue;
        }
        pid = fork();
        if (pid < 0) {
            return -1;
        }
        if (pid == 0) {
            int null = open("/dev/null", O_RDWR | O_CLOEXEC);

            if (null >= 0) {
                dup2(null, STDOUT_FILENO);
                dup2(null, STDERR_FILENO);
            }
            execl(xauth[i], "xauth", "-f", out, "generate", display,
                  "MIT-MAGIC-COOKIE-1", "untrusted", "timeout", "0",
                  (char *)NULL);
            _exit(127);
        }
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
            continue;
        }
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
            struct stat st;

            /* xauth exits zero having written nothing when the server has no
             * SECURITY extension, and an empty file is not a cookie. */
            if (stat(out, &st) == 0 && st.st_size > 0) {
                setenv("XAUTHORITY", out, 1);
                nt_x11_replaced = 1;
                return 0;
            }
        }
        break;
    }
    unlink(out);
    return -1;
}
#endif

/*
 * What --info prints and what a launch does, from one place. Returns the phrase
 * for the confinement description, and -- in the enforcing case, when a pid
 * namespace was asked for -- does not return in the parent at all.
 */
static char nt_session_desc[96];

static const char *nt_session_unavailable(int hide, const char *why)
{
    if (!hide) {
        return "";
    }
    snprintf(nt_session_desc, sizeof(nt_session_desc), "session open (%s)",
             why && *why ? why : "namespace refused");
    return nt_session_desc;
}

static const char *nt_apply_session(int enforce, int *net_closed, int *x11,
                                   const char *appdir)
{
    char why[64];
    int hide = 0;
    int net = 0;

#ifdef NEUTRINO_CONFINE_NOSESSION
    hide = 1;
    /*
     * Before the namespaces, because generating the cookie means connecting to
     * the display as a trusted client and reading the trusted cookie to do it,
     * and both of those are things the tier is about to take away.
     */
    if (enforce && nt_x11_untrusted(appdir) == 0) {
        *x11 = 1;
    }
#else
    (void)appdir;
    (void)x11;
#endif
#ifdef NEUTRINO_CONFINE_OFFLINE
    net = 1;
#endif
    nt_uid = getuid();
    nt_gid = getgid();

    if (!enforce) {
#ifdef NEUTRINO_CONFINE_NOSESSION
        {
            static const char *const xauth[] = {
                "/usr/bin/xauth", "/bin/xauth", "/usr/local/bin/xauth",
                "/usr/X11R6/bin/xauth", NULL
            };
            const char *display = getenv("DISPLAY");
            int i;

            for (i = 0; display && *display && xauth[i]; i++) {
                if (access(xauth[i], X_OK) == 0) {
                    *x11 = 1;
                    break;
                }
            }
        }
#endif
        if (!nt_namespace_available(nt_session_flags(hide, net), why, sizeof(why))) {
            return nt_session_unavailable(hide, why);
        }
        *net_closed = net;
        return hide ? "session closed" : "";
    }
    /*
     * The same question, in a throwaway child, before doing it for real. See
     * nt_namespace_available: half-entering a user namespace is worse than not
     * entering one.
     */
    if (!nt_namespace_available(nt_session_flags(hide, net), why, sizeof(why))) {
        return nt_session_unavailable(hide, why);
    }
    switch (nt_close_session(hide, net)) {
    case 0:
        *net_closed = net;
        return hide ? "session closed" : "";
    case -2:
        return hide ? "session half closed (namespace granted, sealing failed)" : "";
    default:
        return hide ? "session open (namespace refused after it was granted)" : "";
    }
}

#endif /* NT_USE_NAMESPACES */

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
    char notes[160] = "";
    const char *runtime;
    const char *scoped = "";
    const char *offline = "";
    const char *session = "";
    const char *secc;
    int net_closed = 0;
    int x11_untrusted = 0;
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

#ifdef NT_USE_NAMESPACES
    /*
     * Before Landlock, and it has to be: Landlock denies mount to any domain
     * that handles a filesystem right, by design and even inside a fresh
     * namespace. Which is also what keeps the covers on -- an app that nests
     * another user namespace to get capabilities back still cannot unmount
     * them, and the mounts it inherits are locked to each other anyway.
     *
     * Only the run phase. The fetch has to reach the network, and curl has no
     * business with the session either way.
     */
    if (phase == NT_PHASE_RUN) {
        session = nt_apply_session(enforce, &net_closed, &x11_untrusted, appdir);
    }
#endif

    (void)net_closed;       /* only read by the offline tier */
    (void)x11_untrusted;    /* only set by the session tier */
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
        scoped = "signals scoped";
        if (!display || !*display) {
            attr.scoped |= LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET;
            scoped = "sockets+signals scoped";
        }
    }
    /*
     * Nothing here should be listening. Connect stays unhandled by default, so
     * the app's own outbound traffic is untouched; trailing zero fields are
     * accepted by older kernels, so this only takes effect from ABI 4.
     */
    if (abi >= 4) {
        attr.handled_access_net = LANDLOCK_ACCESS_NET_BIND_TCP;
#ifdef NEUTRINO_CONFINE_OFFLINE
        /*
         * The offline tier handles connect as well and then grants it to
         * nothing, so no outbound TCP leaves the app at all. Only for the run
         * phase -- the fetch is the one thing that must reach the network.
         */
        if (phase == NT_PHASE_RUN) {
            attr.handled_access_net |= LANDLOCK_ACCESS_NET_CONNECT_TCP;
            /*
             * Landlock's network rules are TCP-only, so UDP -- QUIC, DNS,
             * anything else -- is untouched by them. A network namespace has no
             * hole of that shape, and takes the abstract socket namespace with
             * it, so where one is available the tier means what the word says
             * and where it is not, --info says which one you got.
             */
            offline = net_closed ? "offline" : "offline (tcp only)";
        }
#endif
    }
    {
        const char *parts[4];
        size_t used = 0;
        int i, n = 0;

        if (*scoped) {
            parts[n++] = scoped;
        }
        if (*offline) {
            parts[n++] = offline;
        }
        if (*session) {
            parts[n++] = session;
        }
        if (x11_untrusted) {
            parts[n++] = "x11 untrusted";
        }
        for (i = 0; i < n; i++) {
            used += (size_t)snprintf(notes + used, sizeof(notes) - used, "%s%s",
                                     i == 0 ? " (" : ", ", parts[i]);
            if (used >= sizeof(notes) - 2) {
                break;
            }
        }
        if (n) {
            snprintf(notes + used, sizeof(notes) - used, ")");
        }
    }

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
                 abi, notes, secc, path);
    } else {
        nt_allow(ruleset, appdir, rights);
        nt_allow(ruleset, "/dev", NT_READ_RIGHTS | LANDLOCK_ACCESS_FS_WRITE_FILE);
        nt_allow(ruleset, "/dev/shm", rights);
        /*
         * Write on /proc is write on *every* process's entry, not just this
         * one's. Measured: thirteen files under a same-uid peer open for
         * writing, and a real write to a peer's oom_score_adj succeeds --
         * against a process this same ruleset says it has scoped signals away
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
#ifdef NEUTRINO_CONFINE_TIGHT
        nt_allow(ruleset, "/proc", NT_READ_RIGHTS);
        nt_allow(ruleset, "/proc/self", LANDLOCK_ACCESS_FS_WRITE_FILE);
#else
        nt_allow(ruleset, "/proc", NT_READ_RIGHTS | LANDLOCK_ACCESS_FS_WRITE_FILE);
#endif
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
                 abi, notes, secc, appdir);
#else
        snprintf(desc, desclen, "landlock abi %d%s%s, writes confined to %s",
                 abi, notes, secc, appdir);
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
