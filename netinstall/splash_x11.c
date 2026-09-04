/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include "netinstall.h"
#include "splash.h"

#if defined(__linux__) || defined(__OpenBSD__) || defined(__FreeBSD__) || \
    defined(__NetBSD__)

/*
 * The splash window, drawn by talking to the X server over its own socket.
 *
 * No libX11, and not for the aesthetics of it: the linux binaries are static
 * musl, where dlopen is a stub that always fails, so a toolkit could only be
 * reached by linking it at build time -- which would make six cross-compiled
 * binaries depend on six sets of development headers, and would make the
 * netinstall that runs anywhere into one that runs where its libraries are. The
 * protocol has no such requirement. It is a socket and a few dozen bytes of
 * structs, frozen since X11R1, and the server on the other end is the one the
 * user is already looking at.
 *
 * The whole of it is: authenticate with the cookie the session already put in
 * XAUTHORITY, allocate two colours, make a window of the size splash.h names,
 * map it, and fill twelve rectangles -- again every NT_SPLASH_FRAME_MS, one
 * cell further along. Everything the protocol offers past that -- properties,
 * window manager hints, input, text -- is skipped, because a splash that
 * outlives one download does not need any of it.
 *
 * Text is the part that used to be here and is not. This file asked the server
 * to open `fixed` and drew "Loading..." through it with ImageText8, which was
 * the one place it leaned on the server rather than doing the work -- and it
 * came with a failure mode of its own, since a bare Xvfb with no font package
 * answers OpenFont with an error and every draw through a GC naming a font that
 * failed to open is a BadGC. Rectangles have no such question: there is nothing
 * to open, nothing to fall back to, and PolyFillRectangle is refused by no
 * server anywhere. See splash.h for why the words went.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

/*
 * What the child needs in order to redraw, set by nt_splash_x11_up and read by
 * nt_splash_x11_serve on the other side of a fork -- which copies them, so no
 * handshake is involved. They are file-static rather than arguments because the
 * alternative is a struct threaded through the platform layer for three
 * integers, and because the two functions are already one mechanism split at
 * the only point a fork can go.
 *
 * Two graphics contexts, and not one whose foreground is changed between the
 * two halves of a frame. A ChangeGC is a request like any other, so the two-GC
 * form sends two requests a frame where the other sends four -- and, the part
 * that actually matters, there is no ordering between a colour change and the
 * fill it was meant for that this file has to keep in its head.
 */
static unsigned long nt_x_wid = 0;
static unsigned long nt_x_gc_dim = 0;
static unsigned long nt_x_gc_lit = 0;

static void nt_x_put16(unsigned char *p, unsigned v)
{
    p[0] = (unsigned char)(v & 0xff);
    p[1] = (unsigned char)((v >> 8) & 0xff);
}

static void nt_x_put32(unsigned char *p, unsigned long v)
{
    p[0] = (unsigned char)(v & 0xff);
    p[1] = (unsigned char)((v >> 8) & 0xff);
    p[2] = (unsigned char)((v >> 16) & 0xff);
    p[3] = (unsigned char)((v >> 24) & 0xff);
}

static unsigned nt_x_get16(const unsigned char *p)
{
    return (unsigned)p[0] | ((unsigned)p[1] << 8);
}

static unsigned long nt_x_get32(const unsigned char *p)
{
    return (unsigned long)p[0] | ((unsigned long)p[1] << 8) |
           ((unsigned long)p[2] << 16) | ((unsigned long)p[3] << 24);
}

static size_t nt_x_pad4(size_t n)
{
    return (n + 3) & ~(size_t)3;
}

static int nt_x_write(int fd, const void *buf, size_t len)
{
    const char *p = (const char *)buf;

    while (len > 0) {
        ssize_t n = write(fd, p, len);

        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int nt_x_read(int fd, void *buf, size_t len)
{
    char *p = (char *)buf;

    while (len > 0) {
        ssize_t n = read(fd, p, len);

        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

/*
 * DISPLAY is [host][:unix]:<display>[.<screen>]. Only the local forms are
 * admitted: a hostname means a TCP connection to another machine, which is a
 * network this program has no business opening on the strength of an
 * environment variable it did not set. Returns the display number, or -1.
 */
static int nt_x_display_number(const char *disp)
{
    const char *colon = strrchr(disp, ':');
    int n = 0;
    int any = 0;

    if (!colon) {
        return -1;
    }
    /* Anything before the colon that is not "unix" is a remote host. */
    if (colon != disp) {
        size_t hostlen = (size_t)(colon - disp);

        if (!(hostlen == 4 && memcmp(disp, "unix", 4) == 0)) {
            return -1;
        }
    }
    colon++;
    while (*colon >= '0' && *colon <= '9') {
        n = n * 10 + (*colon - '0');
        any = 1;
        colon++;
        if (n > 65535) {
            return -1;
        }
    }
    if (!any || (*colon != '\0' && *colon != '.')) {
        return -1;
    }
    return n;
}

static int nt_x_connect(int display)
{
    struct sockaddr_un sa;
    char path[64];
    int fd;

    snprintf(path, sizeof(path), "/tmp/.X11-unix/X%d", display);

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    /* -1 for the terminator the struct is entitled to keep. */
    strncpy(sa.sun_path, path, sizeof(sa.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
        return fd;
    }
#ifdef __linux__
    /*
     * The abstract namespace, where a linux server binds as well as -- and
     * sometimes instead of -- the filesystem. A leading NUL in sun_path is the
     * whole difference, and the length has to stop at the end of the name
     * rather than at the end of the struct, or the kernel matches a name with
     * a hundred trailing NULs in it against one without.
     */
    {
        size_t len = strlen(path);

        memset(&sa, 0, sizeof(sa));
        sa.sun_family = AF_UNIX;
        sa.sun_path[0] = '\0';
        memcpy(sa.sun_path + 1, path, len);
        if (connect(fd, (struct sockaddr *)&sa,
                    (socklen_t)(sizeof(sa.sun_family) + 1 + len)) == 0) {
            return fd;
        }
    }
#endif
    close(fd);
    return -1;
}

/*
 * The MIT-MAGIC-COOKIE-1 for this display, out of the file the session set up.
 * Entries are big-endian, which is the one place in this file where that is
 * true -- the wire protocol itself is whatever byte order the client declares,
 * and this declares little.
 *
 * Not finding one is not an error here. A server may be listening with no
 * access control at all, and the connection attempt is the thing that knows;
 * this returning 0 means "send no authorisation", which is a request the server
 * is free to refuse.
 */
static size_t nt_x_cookie(int display, unsigned char *out, size_t outlen)
{
    const char *xa = getenv("XAUTHORITY");
    char home[512];
    unsigned char hdr[2];
    FILE *f;
    size_t got = 0;
    char want[16];
    int wantlen;

    if (!xa || !*xa) {
        const char *h = getenv("HOME");

        if (!h || !*h) {
            return 0;
        }
        snprintf(home, sizeof(home), "%s/.Xauthority", h);
        xa = home;
    }
    f = fopen(xa, "rb");
    if (!f) {
        return 0;
    }
    wantlen = snprintf(want, sizeof(want), "%d", display);

    while (fread(hdr, 1, 2, f) == 2) {
        unsigned char buf[4][512];
        size_t len[4];
        int i;
        int bad = 0;

        /* family in hdr; then address, number, name, data, each u16-prefixed. */
        for (i = 0; i < 4; i++) {
            unsigned char l[2];
            unsigned n;

            if (fread(l, 1, 2, f) != 2) {
                bad = 1;
                break;
            }
            n = ((unsigned)l[0] << 8) | (unsigned)l[1];
            if (n >= sizeof(buf[0])) {
                bad = 1;
                break;
            }
            if (n > 0 && fread(buf[i], 1, n, f) != n) {
                bad = 1;
                break;
            }
            len[i] = n;
        }
        if (bad) {
            break;
        }
        /*
         * Match on the display number and the protocol name, and deliberately
         * not on the address. A session writes its entry under the machine's
         * hostname, and a machine that has been renamed since login -- or a
         * container that reports a different one -- would otherwise have a
         * perfectly good cookie sitting in a file this refused to read. The
         * cost of being wrong is a refused connection, which is the same thing
         * that happens if no cookie is sent at all.
         */
        if (len[1] == (size_t)wantlen && memcmp(buf[1], want, len[1]) == 0 &&
            len[2] == 18 && memcmp(buf[2], "MIT-MAGIC-COOKIE-1", 18) == 0 &&
            len[3] > 0 && len[3] <= outlen) {
            memcpy(out, buf[3], len[3]);
            got = len[3];
            break;
        }
    }
    fclose(f);
    return got;
}

/*
 * The setup handshake. Fills the five things anything below needs out of the
 * first screen: a resource id to allocate from, the root window to parent to,
 * its default colormap, its pixel values, and how big the screen is so the
 * window can be centred.
 */
static int nt_x_setup(int fd, int display, unsigned long *id_base,
                      unsigned long *root, unsigned long *cmap,
                      unsigned long *white, unsigned long *black,
                      unsigned *sw, unsigned *sh)
{
    unsigned char cookie[64];
    unsigned char req[12 + 24 + 64];
    unsigned char head[8];
    unsigned char *rest;
    size_t clen = nt_x_cookie(display, cookie, sizeof(cookie));
    size_t namelen = clen ? 18 : 0;
    size_t n = 0;
    size_t extra;
    size_t vendor;
    size_t formats;
    size_t off;

    memset(req, 0, sizeof(req));
    req[0] = 0x6c;              /* little-endian, which is what put32 writes */
    nt_x_put16(req + 2, 11);    /* protocol major */
    nt_x_put16(req + 4, 0);     /* protocol minor */
    nt_x_put16(req + 6, (unsigned)namelen);
    nt_x_put16(req + 8, (unsigned)clen);
    n = 12;
    if (clen) {
        memcpy(req + n, "MIT-MAGIC-COOKIE-1", 18);
        n += nt_x_pad4(18);
        memcpy(req + n, cookie, clen);
        n += nt_x_pad4(clen);
    }
    if (nt_x_write(fd, req, n) != 0) {
        return -1;
    }
    if (nt_x_read(fd, head, 8) != 0) {
        return -1;
    }
    /* 1 is success. 0 is refused and 2 is "authenticate further", and neither
     * is a thing to keep talking to a socket about. */
    if (head[0] != 1) {
        return -1;
    }
    extra = (size_t)nt_x_get16(head + 6) * 4;
    if (extra < 32) {
        return -1;
    }
    rest = (unsigned char *)malloc(extra);
    if (!rest) {
        return -1;
    }
    if (nt_x_read(fd, rest, extra) != 0) {
        free(rest);
        return -1;
    }
    *id_base = nt_x_get32(rest + 4);
    vendor = nt_x_get16(rest + 16);
    formats = (size_t)rest[21] * 8;
    off = 32 + nt_x_pad4(vendor) + formats;
    /* The first screen begins there, and is 40 bytes before its depth list. */
    if (off + 40 > extra) {
        free(rest);
        return -1;
    }
    *root  = nt_x_get32(rest + off);
    *cmap  = nt_x_get32(rest + off + 4);
    *white = nt_x_get32(rest + off + 8);
    *black = nt_x_get32(rest + off + 12);
    *sw    = nt_x_get16(rest + off + 20);
    *sh    = nt_x_get16(rest + off + 22);
    free(rest);
    return 0;
}

/*
 * A pixel value for one of splash.h's colours, out of the screen's default
 * colormap.
 *
 * AllocColor and not a pixel composed by hand out of the visual's masks. On the
 * TrueColor visual every machine this runs on actually has, the two agree and
 * the arithmetic would be free -- but the masks live in the depth and visual
 * lists this file skips past to reach the screen's fixed part, and reading them
 * correctly is more protocol than one round trip is worth. AllocColor is one
 * request with a fixed 32-byte reply, and every visual class there is answers
 * it.
 *
 * The components are 16-bit, so each byte is repeated rather than shifted:
 * 0xc8 is 0xc8c8 and not 0xc800, which would be a colour half as bright as the
 * one asked for.
 */
static int nt_x_alloc(int fd, unsigned long cmap, unsigned long rgb,
                      unsigned long *pixel)
{
    unsigned char req[16];
    unsigned char rep[32];
    int r = NT_SPLASH_R(rgb), g = NT_SPLASH_G(rgb), b = NT_SPLASH_B(rgb);

    memset(req, 0, sizeof(req));
    req[0] = 84;                                  /* AllocColor */
    nt_x_put16(req + 2, 4);
    nt_x_put32(req + 4, cmap);
    nt_x_put16(req + 8, (unsigned)((r << 8) | r));
    nt_x_put16(req + 10, (unsigned)((g << 8) | g));
    nt_x_put16(req + 12, (unsigned)((b << 8) | b));
    if (nt_x_write(fd, req, sizeof(req)) != 0) {
        return -1;
    }
    if (nt_x_read(fd, rep, 32) != 0) {
        return -1;
    }
    if (rep[0] != 1) {
        return -1;                                /* an error, not a reply */
    }
    *pixel = nt_x_get32(rep + 16);
    return 0;
}

/*
 * One frame: every cell filled, in two requests.
 *
 * All twelve every time, and not only the three that changed. The diff is four
 * rectangles rather than twelve, which is a saving of two hundred bytes a
 * second and would cost this function a memory of what it drew last -- a memory
 * that then has to be right across a fork, across an Expose from a window that
 * was covered, and on the first frame after nothing at all. Twelve rectangles
 * is one code path for all three.
 *
 * Nothing here clears anything. The window's background-pixel is the light one,
 * the server paints it over the exposed area before it sends the Expose, and
 * every cell is fully repainted by one of the two passes below -- so there is
 * no third colour on this window and no state a frame could leave behind.
 */
static int nt_x_frame(int fd, int phase)
{
    unsigned char req[12 + NT_SPLASH_CELLS * 8];
    int pass;

    for (pass = 0; pass < 2; pass++) {
        size_t n = 12;
        int count = 0;
        int i;

        for (i = 0; i < NT_SPLASH_CELLS; i++) {
            if (nt_splash_cell_lit(phase, i) != pass) {
                continue;
            }
            nt_x_put16(req + n, (unsigned)NT_SPLASH_CELL_X(i));
            nt_x_put16(req + n + 2, (unsigned)NT_SPLASH_TRACK_Y);
            nt_x_put16(req + n + 4, NT_SPLASH_CELL_W);
            nt_x_put16(req + n + 6, NT_SPLASH_CELL_H);
            n += 8;
            count++;
        }
        if (count == 0) {
            continue;
        }
        memset(req, 0, 12);
        req[0] = 70;                              /* PolyFillRectangle */
        nt_x_put16(req + 2, (unsigned)(n / 4));
        nt_x_put32(req + 4, nt_x_wid);
        nt_x_put32(req + 8, pass ? nt_x_gc_lit : nt_x_gc_dim);
        if (nt_x_write(fd, req, n) != 0) {
            return -1;
        }
    }
    /*
     * And the edge, in the same request shape and the darker of the two GCs.
     * PolyRectangle draws an outline rather than a fill, one pixel wide at the
     * GC's default line-width, and it draws *on* the rectangle it is given --
     * so the far edge is at w-1 and not at w, which would be a line outside the
     * window and no line at all.
     */
    {
        unsigned char edge[20];

        memset(edge, 0, sizeof(edge));
        edge[0] = 67;                             /* PolyRectangle */
        nt_x_put16(edge + 2, 5);
        nt_x_put32(edge + 4, nt_x_wid);
        nt_x_put32(edge + 8, nt_x_gc_lit);
        nt_x_put16(edge + 12, 0);
        nt_x_put16(edge + 14, 0);
        nt_x_put16(edge + 16, NT_SPLASH_WIDTH - 1);
        nt_x_put16(edge + 18, NT_SPLASH_HEIGHT - 1);
        if (nt_x_write(fd, edge, sizeof(edge)) != 0) {
            return -1;
        }
    }
    return 0;
}

int nt_splash_x11_up(char *desc, size_t desclen)
{
    const char *disp = getenv("DISPLAY");
    unsigned long id_base = 0, root = 0, cmap = 0, white = 0, black = 0;
    unsigned long dim = 0, lit = 0;
    unsigned long wid, gcd, gcl;
    unsigned sw = 0, sh = 0;
    unsigned w = NT_SPLASH_WIDTH, h = NT_SPLASH_HEIGHT;
    int coloursok = 1;
    int which;
    int x, y;
    int display;
    int fd;
    unsigned char req[64];

    if (!disp || !*disp) {
        snprintf(desc, desclen, "none (no DISPLAY)");
        return -1;
    }
    display = nt_x_display_number(disp);
    if (display < 0) {
        snprintf(desc, desclen, "none (DISPLAY is not a local server)");
        return -1;
    }
    fd = nt_x_connect(display);
    if (fd < 0) {
        snprintf(desc, desclen, "none (no X server on :%d)", display);
        return -1;
    }
    if (nt_x_setup(fd, display, &id_base, &root, &cmap, &white, &black,
                   &sw, &sh) != 0) {
        close(fd);
        snprintf(desc, desclen, "none (X server refused the connection)");
        return -1;
    }

    wid = id_base;
    gcd = id_base + 1;
    gcl = id_base + 2;

    /*
     * The two colours, or the two the screen came with. A colormap with nothing
     * free is what the fallback is for -- an 8-bit PseudoColor server with a
     * full map, which is rare and is not a reason to decline a window. Black on
     * white still moves; it is only the track that stops being distinguishable
     * from the background, and the moving run is the half carrying the message.
     */
    if (nt_x_alloc(fd, cmap, NT_SPLASH_RGB_DIM, &dim) != 0 ||
        nt_x_alloc(fd, cmap, NT_SPLASH_RGB_LIT, &lit) != 0) {
        coloursok = 0;
        dim = white;
        lit = black;
    }

    x = sw > w ? (int)((sw - w) / 2) : 0;
    y = sh > h ? (int)((sh - h) / 2) : 0;

    /*
     * CreateWindow, override-redirect. That bit is what makes this a splash
     * rather than an application window: the window manager does not frame it,
     * does not place it somewhere of its own choosing, does not put it in a
     * task list, and does not make the user's next alt-tab land on a thing that
     * will be gone in a moment. It is also the only way this can honour the
     * centring it just worked out.
     */
    memset(req, 0, sizeof(req));
    req[0] = 1;
    req[1] = 0;                                   /* depth: CopyFromParent */
    nt_x_put16(req + 2, 8 + 4);                   /* request length, in words */
    nt_x_put32(req + 4, wid);
    nt_x_put32(req + 8, root);
    nt_x_put16(req + 12, (unsigned)x);
    nt_x_put16(req + 14, (unsigned)y);
    nt_x_put16(req + 16, w);
    nt_x_put16(req + 18, h);
    nt_x_put16(req + 20, 0);                      /* border width: see the edge */
    nt_x_put16(req + 22, 1);                      /* class: InputOutput */
    nt_x_put32(req + 24, 0);                      /* visual: CopyFromParent */
    /* background-pixel | border-pixel | override-redirect | event-mask */
    nt_x_put32(req + 28, 0x02 | 0x08 | 0x200 | 0x800);
    nt_x_put32(req + 32, white);
    nt_x_put32(req + 36, black);
    nt_x_put32(req + 40, 1);                      /* override-redirect */
    nt_x_put32(req + 44, 0x8000);                 /* event-mask: Exposure */
    if (nt_x_write(fd, req, 48) != 0) {
        close(fd);
        snprintf(desc, desclen, "none (X server closed during CreateWindow)");
        return -1;
    }

    /* One GC per colour, foreground and background both, so that a server asked
     * to fill through either has nothing left to default. */
    for (which = 0; which < 2; which++) {
        memset(req, 0, sizeof(req));
        req[0] = 55;                              /* CreateGC */
        nt_x_put16(req + 2, 6);
        nt_x_put32(req + 4, which ? gcl : gcd);
        nt_x_put32(req + 8, wid);
        nt_x_put32(req + 12, 0x04 | 0x08);        /* foreground | background */
        nt_x_put32(req + 16, which ? lit : dim);
        nt_x_put32(req + 20, white);
        if (nt_x_write(fd, req, 24) != 0) {
            close(fd);
            snprintf(desc, desclen, "none (X server closed during CreateGC)");
            return -1;
        }
    }

    /* MapWindow. */
    memset(req, 0, sizeof(req));
    req[0] = 8;
    nt_x_put16(req + 2, 2);
    nt_x_put32(req + 4, wid);
    if (nt_x_write(fd, req, 8) != 0) {
        close(fd);
        snprintf(desc, desclen, "none (X server closed during MapWindow)");
        return -1;
    }

    nt_x_wid = wid;
    nt_x_gc_dim = gcd;
    nt_x_gc_lit = gcl;

    /*
     * One eager frame, which may well be discarded: a window is not viewable
     * until the server says so, and a request that arrives first paints
     * nothing. It is sent anyway because on a server that does keep it, it is
     * the difference between the window appearing with its track already in it
     * and appearing empty for one round trip. The Expose that follows is what
     * actually guarantees the pixels; servicing that, and the clock, is the
     * child's whole job.
     */
    if (nt_x_frame(fd, 0) != 0) {
        close(fd);
        snprintf(desc, desclen, "none (X server closed during the first frame)");
        return -1;
    }

    /* The colours are named when they are not the ones that were asked for,
     * because a lane that quietly fell back to black and white is a lane whose
     * window looks different for a reason nobody would otherwise be told. */
    snprintf(desc, desclen, "x11 (:%d, %ux%u%s)", display, w, h,
             coloursok ? "" : ", default colours");
    return fd;
}

/*
 * The child. Two things have to keep happening for the window to be what it
 * claims. A redraw on every Expose, or it goes blank the first time anything
 * passes over it -- that part was always here. And a step of the animation
 * every NT_SPLASH_FRAME_MS, or it is a picture of an indicator rather than one.
 *
 * poll and not a blocking read, because the frame falls due whether or not the
 * server has anything to say, and on an ordinary X session it has nothing to
 * say for the whole of a download. The phase is advanced against the clock and
 * not against the number of times poll returned: an X connection that does
 * carry traffic -- a window manager probing, an Expose storm behind a moving
 * window -- would otherwise run the animation at the speed of the traffic.
 *
 * There is no teardown in here and no exit path that matters. The parent kills
 * this process, which closes the last descriptor on the connection, and the
 * server destroys every resource the connection owned -- the window and both
 * GCs -- without being asked. That is why nothing above bothers to keep their
 * ids around.
 */
void nt_splash_x11_serve(int fd)
{
    unsigned char ev[32];
    int phase = 0;
    long last = nt_now_ms();
    long due = NT_SPLASH_FRAME_MS;

    for (;;) {
        struct pollfd pfd;
        long now;
        int ready;

        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        ready = poll(&pfd, 1, (int)due);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            _exit(0);
        }
        if (ready > 0) {
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                _exit(0);
            }
            if (nt_x_read(fd, ev, 32) != 0) {
                _exit(0);
            }
            /*
             * 12 is Expose. The high bit marks a SendEvent, which is neither a
             * thing to trust nor a thing this needs, and everything else on
             * this connection is an error reply to a request one of the two
             * functions here got wrong -- which is a thing to ignore rather
             * than to act on.
             *
             * The connection owns exactly one window, so an Expose can only be
             * ours; an event carrying someone else's id would mean the stream
             * is not where this thinks it is, and drawing into a stranger's
             * window on that basis is worse than drawing nothing.
             */
            if ((ev[0] & 0x7f) == 12 && nt_x_get32(ev + 4) == nt_x_wid &&
                nt_x_frame(fd, phase) != 0) {
                _exit(0);
            }
        }
        now = nt_now_ms();
        if (now - last < NT_SPLASH_FRAME_MS) {
            /* Woken early by an event. What is left of the frame is what the
             * next poll waits for, so an uncovered window does not make the
             * indicator jump. */
            due = NT_SPLASH_FRAME_MS - (now - last);
            continue;
        }
        last = now;
        due = NT_SPLASH_FRAME_MS;
        phase = (phase + 1) % NT_SPLASH_CELLS;
        if (nt_x_frame(fd, phase) != 0) {
            _exit(0);
        }
    }
}

#endif
