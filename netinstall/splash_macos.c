/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include "splash.h"

#ifdef __APPLE__

/*
 * A Loading... window, drawn with AppKit, in a process of its own.
 *
 * Two constraints decide the whole shape of this file, and neither is a
 * preference.
 *
 * The first is that AppKit is only usable from a process's main thread. Windows
 * puts its message pump on a second thread precisely because it may; here that
 * is not available, and the main thread is the one that spends the next two
 * minutes inside waitpid on curl. So the window cannot live in this process.
 *
 * The second is that it cannot live in a plain fork either. A forked child
 * inherits a copy of a Core Foundation runtime whose locks and ports belonged
 * to the parent, and calling into it without an exec first is documented as
 * unsupported and behaves like it. So the child is fork *and exec*: this same
 * binary, run again with --splash, whose main thread is then its own and whose
 * frameworks initialise from scratch.
 *
 * The frameworks are dlopened rather than linked. Linking AppKit would make the
 * cross-compile need a macOS SDK, and zig ships stubs for libSystem and not for
 * the frameworks -- so `zig cc -target aarch64-macos` would stop working for
 * everyone in order to draw a box for the people on macOS. dlopen costs
 * nothing at build time and fails cleanly at runtime on a machine with no
 * window server, which is the same answer the other platforms give.
 */

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "netinstall.h"

#define NT_M_TEXT "Loading..."
#define NT_M_WIDTH 260.0
#define NT_M_HEIGHT 96.0

/* ---------------------------------------------------------------- parent -- */

static pid_t nt_m_pid = -1;
/*
 * The write end of the pipe whose only purpose is to be closed. macOS has no
 * PR_SET_PDEATHSIG and no equivalent, so the child cannot ask the kernel to
 * kill it when this process dies. What it can do is hold the read end of a pipe
 * and block: every way this process can stop -- including the ones that run no
 * code at all -- closes this descriptor, and the child's read returns
 * end-of-file. Race-free, unlike polling getppid, and it needs nothing from the
 * platform beyond pipes.
 */
static int nt_m_deathfd = -1;

int nt_splash_platform_up(char *desc, size_t desclen)
{
    char self[NT_PATH_MAX];
    char deatharg[16];
    char readyarg[16];
    int fds[2];
    int ready[2];
    pid_t pid;

    if (nt_self_path(self, sizeof(self), NULL) != 0) {
        snprintf(desc, desclen, "none (cannot find own path to re-exec)");
        return -1;
    }
    if (pipe(fds) != 0) {
        snprintf(desc, desclen, "none (cannot create the parent-death pipe)");
        return -1;
    }
    /*
     * The other direction, and the reason it exists: without it this function
     * returns as soon as fork does, and reports a window on the strength of
     * having started a process. Everything that can actually fail -- dlopening
     * AppKit, the activation policy a bundle-less process needs, the window
     * itself -- happens after that in a child this side never hears from. A
     * report of "up" that a failed child cannot contradict is the shape ground
     * rule 5 exists to forbid, and it would leave the suite unable to tell a
     * drawn window from a dead one on this platform alone.
     */
    if (pipe(ready) != 0) {
        close(fds[0]);
        close(fds[1]);
        snprintf(desc, desclen, "none (cannot create the readiness pipe)");
        return -1;
    }
    snprintf(deatharg, sizeof(deatharg), "%d", fds[0]);
    snprintf(readyarg, sizeof(readyarg), "%d", ready[1]);

    pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        close(ready[0]);
        close(ready[1]);
        snprintf(desc, desclen, "none (cannot fork)");
        return -1;
    }
    if (pid == 0) {
        char *args[5];

        close(fds[1]);
        close(ready[0]);
        /*
         * Nothing of the caller's is wanted in there, and a splash child
         * holding stdout is a splash child that keeps `netinstall | anything`
         * from ever seeing end-of-file. Measured on the x11 path, where it did
         * exactly that.
         */
        {
            int devnull = open("/dev/null", O_RDWR);

            if (devnull >= 0) {
                dup2(devnull, 0);
                dup2(devnull, 1);
                dup2(devnull, 2);
                if (devnull > 2) {
                    close(devnull);
                }
            }
        }
        args[0] = self;
        args[1] = (char *)"--splash";
        args[2] = deatharg;
        args[3] = readyarg;
        args[4] = NULL;
        execv(self, args);
        _exit(127);
    }

    close(fds[0]);
    close(ready[1]);
    nt_m_deathfd = fds[1];
    nt_m_pid = pid;

    /*
     * One byte means the window is on screen; end-of-file means the child died
     * on the way there and closed it by dying. Both are answers, and the
     * timeout is the third: bounded because this sits in front of a download,
     * and a splash that cannot decide whether it exists must not become the
     * reason nothing is fetched.
     */
    {
        struct pollfd pfd;
        char b;
        int got;

        pfd.fd = ready[0];
        pfd.events = POLLIN;
        got = poll(&pfd, 1, 2000);
        if (got == 1 && read(ready[0], &b, 1) == 1) {
            close(ready[0]);
            snprintf(desc, desclen, "appkit (re-exec, pid %ld)", (long)pid);
            return 0;
        }
        close(ready[0]);
        nt_splash_platform_down();
        snprintf(desc, desclen, got == 0 ? "none (the window did not come up in time)"
                                         : "none (the window process died)");
        return -1;
    }
}

void nt_splash_platform_down(void)
{
    int status;

    if (nt_m_pid <= 0) {
        return;
    }
    kill(nt_m_pid, SIGKILL);
    while (waitpid(nt_m_pid, &status, 0) < 0 && errno == EINTR) {
        /* again */
    }
    if (nt_m_deathfd >= 0) {
        close(nt_m_deathfd);
        nt_m_deathfd = -1;
    }
    nt_m_pid = -1;
}

/* ----------------------------------------------------------------- child -- */

typedef struct objc_object *nt_id;
typedef struct objc_selector *nt_sel;
typedef struct objc_class *nt_class;

typedef struct { double x, y; } nt_point;
typedef struct { double w, h; } nt_size;
typedef struct { nt_point origin; nt_size size; } nt_rect;

static nt_class (*nt_getclass)(const char *);
static nt_sel (*nt_selector)(const char *);
static void *nt_msg_raw;

/*
 * objc_msgSend is called through a correctly typed pointer at every site rather
 * than through one variadic declaration. On arm64 the two are not the same
 * thing: a variadic call places arguments differently from a normal one, and a
 * message sent the variadic way arrives with its arguments in the wrong
 * registers. This is the single most common way C code that talks to the
 * Objective-C runtime is wrong, and it is wrong at runtime only.
 */
#define NT_MSG(rt, ...) ((rt (*)(nt_id, nt_sel, ##__VA_ARGS__))nt_msg_raw)

static nt_id nt_cls(const char *name)
{
    return (nt_id)nt_getclass(name);
}

static void nt_watch_parent(int fd)
{
    char b;
    ssize_t n;

    for (;;) {
        n = read(fd, &b, 1);
        if (n == 0) {
            _exit(0);           /* the parent is gone; so is the window */
        }
        if (n < 0 && errno != EINTR) {
            _exit(0);
        }
    }
}

static void *nt_watch_thread(void *arg)
{
    nt_watch_parent((int)(long)arg);
    return NULL;
}

int nt_splash_macos_child(int deathfd, int readyfd)
{
    void *appkit;
    void *objc;
    nt_id app, win, field, str, view;
    nt_rect frame, inner;
    pthread_t tid;

    /*
     * AppKit for the classes, libobjc for the three functions that talk to
     * them. Two handles rather than one and RTLD_DEFAULT: AppKit is opened
     * RTLD_LOCAL, so its dependencies do not join the global namespace and
     * looking for objc_msgSend there would be relying on something else in the
     * process having already loaded it. Naming the library that actually
     * defines these is both more honest and one fewer assumption.
     */
    appkit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit",
                    RTLD_LAZY | RTLD_LOCAL);
    if (!appkit) {
        return 1;
    }
    objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!objc) {
        return 1;
    }
    nt_getclass = (nt_class (*)(const char *))dlsym(objc, "objc_getClass");
    nt_selector = (nt_sel (*)(const char *))dlsym(objc, "sel_registerName");
    nt_msg_raw = dlsym(objc, "objc_msgSend");
    if (!nt_getclass || !nt_selector || !nt_msg_raw) {
        return 1;
    }

    if (deathfd >= 0) {
        /*
         * Started before the run loop, because after it starts nothing else in
         * this function runs again. A failure to create it is not a reason to
         * skip the window: the parent still kills this process by pid on the
         * ordinary path, and the watch is only there for the paths where it
         * cannot.
         */
        pthread_create(&tid, NULL, nt_watch_thread, (void *)(long)deathfd);
        pthread_detach(tid);
    }

    app = NT_MSG(nt_id)(nt_cls("NSApplication"), nt_selector("sharedApplication"));
    if (!app) {
        return 1;
    }
    /*
     * 1 is NSApplicationActivationPolicyAccessory: this can show a window and
     * come forward, and it gets no Dock icon and no menu bar for doing it. A
     * process that never called this shows nothing at all, which is the trap
     * every non-bundled AppKit program falls into once.
     */
    NT_MSG(char, long)(app, nt_selector("setActivationPolicy:"), 1);

    frame.origin.x = 0.0;
    frame.origin.y = 0.0;
    frame.size.w = NT_M_WIDTH;
    frame.size.h = NT_M_HEIGHT;

    win = NT_MSG(nt_id)(nt_cls("NSWindow"), nt_selector("alloc"));
    if (!win) {
        return 1;
    }
    /* styleMask 0 is borderless; backing 2 is buffered; defer NO. */
    win = NT_MSG(nt_id, nt_rect, unsigned long, unsigned long, char)(
        win, nt_selector("initWithContentRect:styleMask:backing:defer:"),
        frame, 0UL, 2UL, 0);
    if (!win) {
        return 1;
    }
    /* 3 is NSFloatingWindowLevel: above ordinary windows, below the shell's. */
    NT_MSG(void, long)(win, nt_selector("setLevel:"), 3);
    NT_MSG(void, char)(win, nt_selector("setReleasedWhenClosed:"), 0);

    str = NT_MSG(nt_id, const char *)(nt_cls("NSString"),
                                      nt_selector("stringWithUTF8String:"),
                                      NT_M_TEXT);

    field = NT_MSG(nt_id)(nt_cls("NSTextField"), nt_selector("alloc"));
    inner.origin.x = 0.0;
    inner.origin.y = 0.0;
    inner.size.w = NT_M_WIDTH;
    inner.size.h = 20.0;
    field = NT_MSG(nt_id, nt_rect)(field, nt_selector("initWithFrame:"), inner);
    if (field && str) {
        NT_MSG(void, nt_id)(field, nt_selector("setStringValue:"), str);
        NT_MSG(void, char)(field, nt_selector("setEditable:"), 0);
        NT_MSG(void, char)(field, nt_selector("setSelectable:"), 0);
        NT_MSG(void, char)(field, nt_selector("setBezeled:"), 0);
        NT_MSG(void, char)(field, nt_selector("setDrawsBackground:"), 0);
        /*
         * Sized to the text and then placed, rather than left full width with a
         * centred alignment. NSTextAlignment's numbering changed when it was
         * unified with UIKit -- centre is 1 in the modern spelling and 2 in the
         * older one -- and picking the wrong constant here would be a silent
         * left-aligned label. Measuring and positioning uses no constant at all.
         */
        NT_MSG(void)(field, nt_selector("sizeToFit"));
        {
            nt_rect got = ((nt_rect (*)(nt_id, nt_sel))nt_msg_raw)(
                field, nt_selector("frame"));

            got.origin.x = (NT_M_WIDTH - got.size.w) / 2.0;
            got.origin.y = (NT_M_HEIGHT - got.size.h) / 2.0;
            NT_MSG(void, nt_rect)(field, nt_selector("setFrame:"), got);
        }
        view = NT_MSG(nt_id)(win, nt_selector("contentView"));
        if (view) {
            NT_MSG(void, nt_id)(view, nt_selector("addSubview:"), field);
        }
    }

    NT_MSG(void)(win, nt_selector("center"));
    /* Regardless, because this process is not the active application and has no
     * intention of becoming one. */
    NT_MSG(void)(win, nt_selector("orderFrontRegardless"));

    /*
     * Only now, and only once: everything that could have failed has not. Every
     * return above this point closes this descriptor by exiting, which is the
     * parent's other answer.
     */
    if (readyfd >= 0) {
        char ok = 1;

        while (write(readyfd, &ok, 1) < 0 && errno == EINTR) {
            /* again */
        }
        close(readyfd);
    }

    /*
     * And then the run loop, which is the whole reason this process exists. It
     * never returns: the parent kills this pid when the download ends, and the
     * watch thread ends it if the parent stops being able to.
     */
    NT_MSG(void)(app, nt_selector("run"));
    return 0;
}

#endif
