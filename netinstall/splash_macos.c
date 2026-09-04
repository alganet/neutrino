/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include "splash.h"

#ifdef __APPLE__

/*
 * The splash window, drawn with AppKit, in a process of its own.
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
 *
 * Twelve boxes and no text. It was one NSTextField saying "Loading..." in
 * whatever font that control defaults to, which is the part of this file that
 * could not be made to match the other three lanes -- see splash.h. What
 * replaced it is twelve NSBoxes, which are AppKit's way of asking for a filled
 * rectangle without writing a view class, and a view class is exactly what this
 * file cannot have: subclassing from C means building one at runtime with
 * objc_allocateClassPair and hanging a C function off it as a method, which is
 * a great deal of machinery for a colour and a frame.
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

/*
 * The geometry, as the doubles AppKit takes. splash.h has them as ints, because
 * the other three platforms count pixels; a cast at each site would work and
 * this says once that the numbers are the same numbers.
 */
#define NT_M_WIDTH ((double)NT_SPLASH_WIDTH)
#define NT_M_HEIGHT ((double)NT_SPLASH_HEIGHT)

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

/*
 * One of splash.h's colours as an NSColor, retained. sRGB and not
 * colorWithCalibratedRed:, which is the older spelling of the same call and
 * means a device-dependent colour: the same three numbers, sent through a
 * calibrated space, come out as a different pixel from the one the other three
 * platforms wrote -- which is the whole thing this round is trying not to have
 * happen.
 */
static nt_id nt_m_colour(unsigned long rgb)
{
    nt_id c = NT_MSG(nt_id, double, double, double, double)(
        nt_cls("NSColor"), nt_selector("colorWithSRGBRed:green:blue:alpha:"),
        NT_SPLASH_R(rgb) / 255.0, NT_SPLASH_G(rgb) / 255.0,
        NT_SPLASH_B(rgb) / 255.0, 1.0);

    return c ? NT_MSG(nt_id)(c, nt_selector("retain")) : NULL;
}

int nt_splash_macos_child(int deathfd, int readyfd)
{
    void *appkit;
    void *objc;
    nt_id app, win, view, mode;
    nt_id dim, lit, bg;
    nt_id boxes[NT_SPLASH_CELLS];
    nt_rect frame, inner;
    pthread_t tid;
    int phase;
    int i;

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

    /*
     * The two colours, retained. Everything AppKit hands back here is
     * autoreleased into a pool this process does not have -- a bundle-less main
     * has none until the loop below makes one per frame -- and these two have
     * to outlive every one of those.
     */
    dim = nt_m_colour(NT_SPLASH_RGB_DIM);
    lit = nt_m_colour(NT_SPLASH_RGB_LIT);
    bg = nt_m_colour(NT_SPLASH_RGB_BG);
    if (!dim || !lit || !bg) {
        return 1;
    }
    NT_MSG(void, nt_id)(win, nt_selector("setBackgroundColor:"), bg);

    view = NT_MSG(nt_id)(win, nt_selector("contentView"));
    if (!view) {
        return 1;
    }
    /*
     * The edge, as a box the size of the window added before the cells so that
     * it is behind them. Borderless is the only NSWindow style this can use --
     * a titled one has a title bar -- so the line the other three platforms
     * draw has to be drawn here too rather than asked of the frame.
     *
     * 1 is NSLineBorder. The fill is the background, so this box is the
     * window's whole surface and the cells sit on top of it.
     */
    {
        nt_id edge = NT_MSG(nt_id)(nt_cls("NSBox"), nt_selector("alloc"));

        inner.origin.x = 0.0;
        inner.origin.y = 0.0;
        inner.size.w = NT_M_WIDTH;
        inner.size.h = NT_M_HEIGHT;
        edge = edge ? NT_MSG(nt_id, nt_rect)(edge, nt_selector("initWithFrame:"),
                                             inner)
                    : NULL;
        if (!edge) {
            return 1;
        }
        NT_MSG(void, long)(edge, nt_selector("setBoxType:"), 4);
        NT_MSG(void, long)(edge, nt_selector("setBorderType:"), 1);
        NT_MSG(void, long)(edge, nt_selector("setTitlePosition:"), 2);
        NT_MSG(void, double)(edge, nt_selector("setBorderWidth:"), 1.0);
        NT_MSG(void, nt_id)(edge, nt_selector("setBorderColor:"), lit);
        NT_MSG(void, nt_id)(edge, nt_selector("setFillColor:"), bg);
        NT_MSG(void, nt_id)(view, nt_selector("addSubview:"), edge);
    }

    for (i = 0; i < NT_SPLASH_CELLS; i++) {
        nt_id box = NT_MSG(nt_id)(nt_cls("NSBox"), nt_selector("alloc"));

        inner.origin.x = NT_SPLASH_CELL_X(i);
        /*
         * AppKit measures from the bottom of the window and splash.h from the
         * top. The track is centred, so the two happen to agree -- which is
         * exactly why the conversion is written out rather than left as the
         * constant: the next person to move the track by ten pixels should find
         * the flip here instead of discovering it.
         */
        inner.origin.y = NT_SPLASH_HEIGHT - NT_SPLASH_TRACK_Y - NT_SPLASH_CELL_H;
        inner.size.w = NT_SPLASH_CELL_W;
        inner.size.h = NT_SPLASH_CELL_H;
        box = NT_MSG(nt_id, nt_rect)(box, nt_selector("initWithFrame:"), inner);
        if (!box) {
            return 1;
        }
        /*
         * 4 is NSBoxCustom, which is the one box type that draws a fill colour
         * of its own; 0 is NSNoBorder, and 2 is NSNoTitle. Left at their
         * defaults an NSBox is a bezelled group box with the word "Title" in
         * the top left of it.
         */
        NT_MSG(void, long)(box, nt_selector("setBoxType:"), 4);
        NT_MSG(void, long)(box, nt_selector("setBorderType:"), 0);
        NT_MSG(void, long)(box, nt_selector("setTitlePosition:"), 2);
        NT_MSG(void, nt_id)(box, nt_selector("setFillColor:"),
                            nt_splash_cell_lit(0, i) ? lit : dim);
        NT_MSG(void, nt_id)(view, nt_selector("addSubview:"), box);
        boxes[i] = box;
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
     * And then the loop, which is the whole reason this process exists. It
     * never returns: the parent kills this pid when the download ends, and the
     * watch thread ends it if the parent stops being able to.
     *
     * -[NSApplication run] is what this used to be and cannot be any more. It
     * owns the thread and hands control back only through a delegate or a timer
     * -- and a timer means a target object, which means a class built at
     * runtime, which is the machinery this file avoided by using NSBox in the
     * first place. Pumping the events by hand costs four messages and puts the
     * frame clock in an ordinary C loop, where the other three platforms have
     * theirs.
     *
     * finishLaunching first, because it is the half of `run` that is still
     * wanted: it is what posts the app-did-launch notification AppKit's own
     * machinery waits on before it will service a window.
     */
    NT_MSG(void)(app, nt_selector("finishLaunching"));
    /*
     * NSDefaultRunLoopMode, which is a string constant this process has no
     * symbol for -- dlopening AppKit gets the classes, not the exported
     * NSString globals. Its value is documented to be the Core Foundation mode
     * of the same meaning, so the string is spelled out. Retained for the
     * reason the colours are.
     */
    mode = NT_MSG(nt_id, const char *)(nt_cls("NSString"),
                                       nt_selector("stringWithUTF8String:"),
                                       "kCFRunLoopDefaultMode");
    if (!mode) {
        return 1;
    }
    NT_MSG(nt_id)(mode, nt_selector("retain"));

    for (phase = 0; ; phase = (phase + 1) % NT_SPLASH_CELLS) {
        nt_id pool = NT_MSG(nt_id)(nt_cls("NSAutoreleasePool"),
                                   nt_selector("alloc"));
        nt_id until;
        nt_id ev;

        /*
         * A pool per frame, and this is the one place it matters. Each pass
         * makes an NSDate and however many NSEvents the window server sent, all
         * autoreleased -- and this loop runs for as long as a download does. A
         * process with no pool at all does not crash, it accumulates, and the
         * one that accumulates here is the one holding a window open for two
         * minutes.
         */
        pool = pool ? NT_MSG(nt_id)(pool, nt_selector("init")) : NULL;

        for (i = 0; i < NT_SPLASH_CELLS; i++) {
            NT_MSG(void, nt_id)(boxes[i], nt_selector("setFillColor:"),
                                nt_splash_cell_lit(phase, i) ? lit : dim);
            NT_MSG(void, char)(boxes[i], nt_selector("setNeedsDisplay:"), 1);
        }
        NT_MSG(void)(win, nt_selector("displayIfNeeded"));

        /*
         * Everything the window server has, until the frame is up.
         * nextEventMatchingMask: returns nil when the date passes with nothing
         * left, so the inner loop is both the drain and the wait -- and an
         * event that arrives early does not shorten the frame, because the date
         * was fixed before the first one was asked for.
         */
        until = NT_MSG(nt_id, double)(nt_cls("NSDate"),
                                      nt_selector("dateWithTimeIntervalSinceNow:"),
                                      (double)NT_SPLASH_FRAME_MS / 1000.0);
        while (until) {
            ev = NT_MSG(nt_id, unsigned long, nt_id, nt_id, char)(
                app, nt_selector("nextEventMatchingMask:untilDate:inMode:dequeue:"),
                ~0UL, until, mode, 1);
            if (!ev) {
                break;
            }
            NT_MSG(void, nt_id)(app, nt_selector("sendEvent:"), ev);
        }
        if (pool) {
            NT_MSG(void)(pool, nt_selector("drain"));
        }
    }
    /* Not reached. The loop above has no exit and this function's callers --
     * main(), on the --splash path -- treat a return as a failure to draw. */
}

#endif
