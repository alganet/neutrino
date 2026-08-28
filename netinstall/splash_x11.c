/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include "splash.h"

#if defined(__linux__) || defined(__OpenBSD__) || defined(__FreeBSD__) || \
    defined(__NetBSD__)

/*
 * A Loading... window, drawn by talking to the X server over its own socket.
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
 * XAUTHORITY, ask the server how wide the string is, make a window that size,
 * map it, draw once. Everything the protocol offers past that -- colours,
 * properties, window manager hints, input -- is skipped, because a splash that
 * outlives one download does not need any of it.
 *
 * Text is the one place this leans on the server rather than doing the work:
 * ImageText8 with the "fixed" font, which every X server has carried since
 * before this was a reasonable assumption to make. That is the asymmetry with
 * the wayland path, where there is no text in the protocol at all and the
 * glyphs have to be shipped.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define NT_X_TEXT "Loading..."

/* The one font named in the core protocol's own examples, and the one every
 * server still ships. A server that has lost it fails OpenFont, which is an
 * error this reads and declines on, rather than a window with no words in it. */
#define NT_X_FONT "fixed"

/* Padding around the string, in pixels. The window is the text plus this. */
#define NT_X_PAD_X 28
#define NT_X_PAD_Y 18

/* What the server is asked for when it cannot say how wide the string is.
 * 6x13 is what "fixed" resolves to almost everywhere; being wrong here costs a
 * slightly off-centre window and nothing else. */
#define NT_X_FALLBACK_ADVANCE 6

/*
 * What the child needs in order to redraw, set by nt_splash_x11_up and read by
 * nt_splash_x11_serve on the other side of a fork -- which copies them, so no
 * handshake is involved. They are file-static rather than arguments because the
 * alternative is a struct threaded through the platform layer for three
 * integers, and because the two functions are already one mechanism split at
 * the only point a fork can go.
 */
static unsigned long nt_x_wid = 0;
static unsigned long nt_x_gc = 0;
static long nt_x_baseline = 0;

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

/* Signed, for the extents reply, whose widths are i32 and may legitimately be
 * negative for a right-to-left font. */
static long nt_x_get32s(const unsigned char *p)
{
    unsigned long v = nt_x_get32(p);

    return v & 0x80000000UL ? (long)v - 4294967296L : (long)v;
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
 * The setup handshake. Fills the four things anything below needs out of the
 * first screen: a resource id to allocate from, the root window to parent to,
 * its pixel values, and how big the screen is so the window can be centred.
 */
static int nt_x_setup(int fd, int display, unsigned long *id_base,
                      unsigned long *root, unsigned long *white,
                      unsigned long *black, unsigned *sw, unsigned *sh)
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
    *white = nt_x_get32(rest + off + 8);
    *black = nt_x_get32(rest + off + 12);
    *sw    = nt_x_get16(rest + off + 20);
    *sh    = nt_x_get16(rest + off + 22);
    free(rest);
    return 0;
}

/*
 * How wide the string is in the opened font. The reply is a fixed 32 bytes,
 * which is the only reason this is worth a round trip -- QueryFont would answer
 * the same question behind a variable-length array of per-character metrics.
 */
static int nt_x_extents(int fd, unsigned long font, long *width, long *ascent,
                        long *descent)
{
    size_t len = strlen(NT_X_TEXT);
    unsigned char req[12 + 2 * 32];
    unsigned char rep[32];
    size_t i;
    size_t body = nt_x_pad4(len * 2);

    memset(req, 0, sizeof(req));
    req[0] = 48;                                  /* QueryTextExtents */
    req[1] = (unsigned char)(len & 1);            /* odd-length flag */
    nt_x_put16(req + 2, (unsigned)(2 + body / 4));
    nt_x_put32(req + 4, font);
    /* CHAR2B: the protocol has no 8-bit form of this request. */
    for (i = 0; i < len; i++) {
        req[8 + i * 2] = 0;
        req[8 + i * 2 + 1] = (unsigned char)NT_X_TEXT[i];
    }
    if (nt_x_write(fd, req, 8 + body) != 0) {
        return -1;
    }
    if (nt_x_read(fd, rep, 32) != 0) {
        return -1;
    }
    if (rep[0] != 1) {
        return -1;                                /* an error, not a reply */
    }
    *ascent  = (long)(short)nt_x_get16(rep + 8);
    *descent = (long)(short)nt_x_get16(rep + 10);
    *width   = nt_x_get32s(rep + 16);
    return 0;
}

int nt_splash_x11_up(char *desc, size_t desclen)
{
    const char *disp = getenv("DISPLAY");
    unsigned long id_base = 0, root = 0, white = 0, black = 0;
    unsigned long wid, gc, font;
    unsigned sw = 0, sh = 0;
    long tw = 0, ascent = 0, descent = 0;
    int fontok = 1;
    unsigned w, h;
    int x, y;
    int display;
    int fd;
    unsigned char req[64];
    size_t tlen = strlen(NT_X_TEXT);

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
    if (nt_x_setup(fd, display, &id_base, &root, &white, &black, &sw, &sh) != 0) {
        close(fd);
        snprintf(desc, desclen, "none (X server refused the connection)");
        return -1;
    }

    wid  = id_base;
    gc   = id_base + 1;
    font = id_base + 2;

    /* OpenFont. */
    memset(req, 0, sizeof(req));
    req[0] = 45;
    nt_x_put16(req + 2, (unsigned)(3 + nt_x_pad4(strlen(NT_X_FONT)) / 4));
    nt_x_put32(req + 4, font);
    nt_x_put16(req + 8, (unsigned)strlen(NT_X_FONT));
    memcpy(req + 12, NT_X_FONT, strlen(NT_X_FONT));
    if (nt_x_write(fd, req, 12 + nt_x_pad4(strlen(NT_X_FONT))) != 0) {
        close(fd);
        snprintf(desc, desclen, "none (X server closed during OpenFont)");
        return -1;
    }

    /*
     * The extents query doubles as the question "did OpenFont work". A server
     * with no "fixed" -- a bare Xvfb with no font package is the one everybody
     * meets -- answers both requests with an error, and this reads the first of
     * them here.
     *
     * That answer is then used twice: for a fallback width, and to decide
     * whether the GC below may name a font at all. Naming one that failed to
     * open makes the GC itself invalid, and every draw through it a BadGC --
     * which is a mapped window with nothing in it, and a splash that says
     * nothing is worse than one in the server's default font.
     */
    if (nt_x_extents(fd, font, &tw, &ascent, &descent) != 0) {
        fontok = 0;
        tw = (long)tlen * NT_X_FALLBACK_ADVANCE;
        ascent = 10;
        descent = 3;
    }
    if (tw <= 0) {
        tw = (long)tlen * NT_X_FALLBACK_ADVANCE;
    }

    w = (unsigned)tw + 2 * NT_X_PAD_X;
    h = (unsigned)(ascent + descent) + 2 * NT_X_PAD_Y;
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
    nt_x_put16(req + 20, 1);                      /* border width */
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

    /* CreateGC: foreground, background, and the font only if there is one. */
    memset(req, 0, sizeof(req));
    req[0] = 55;
    nt_x_put16(req + 2, (unsigned)(4 + (fontok ? 3 : 2)));
    nt_x_put32(req + 4, gc);
    nt_x_put32(req + 8, wid);
    nt_x_put32(req + 12, 0x04 | 0x08 | (fontok ? 0x4000 : 0));
    nt_x_put32(req + 16, black);
    nt_x_put32(req + 20, white);
    if (fontok) {
        nt_x_put32(req + 24, font);
    }
    if (nt_x_write(fd, req, fontok ? 28 : 24) != 0) {
        close(fd);
        snprintf(desc, desclen, "none (X server closed during CreateGC)");
        return -1;
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

    /*
     * One eager draw, which may well be discarded: a window is not viewable
     * until the server says so, and a request that arrives first paints
     * nothing. It is sent anyway because on a server that does keep it, it is
     * the difference between the window appearing with its word already in it
     * and appearing empty for one round trip. The Expose that follows is what
     * actually guarantees the text, and servicing that is the child's whole
     * job.
     */
    memset(req, 0, sizeof(req));
    req[0] = 76;                                  /* ImageText8 */
    req[1] = (unsigned char)tlen;
    nt_x_put16(req + 2, (unsigned)(4 + nt_x_pad4(tlen) / 4));
    nt_x_put32(req + 4, wid);
    nt_x_put32(req + 8, gc);
    nt_x_put16(req + 12, (unsigned)NT_X_PAD_X);
    nt_x_put16(req + 14, (unsigned)(NT_X_PAD_Y + ascent));
    memcpy(req + 16, NT_X_TEXT, tlen);
    if (nt_x_write(fd, req, 16 + nt_x_pad4(tlen)) != 0) {
        close(fd);
        snprintf(desc, desclen, "none (X server closed during ImageText8)");
        return -1;
    }

    nt_x_wid = wid;
    nt_x_gc = gc;
    nt_x_baseline = NT_X_PAD_Y + ascent;

    /* The font is named because a lane that quietly fell back to the server's
     * default is a lane whose window looks different for a reason nobody would
     * otherwise be told. */
    snprintf(desc, desclen, "x11 (:%d, %ux%u, %s)", display, w, h,
             fontok ? NT_X_FONT : "default font");
    return fd;
}

/*
 * The child. Reads events forever and redraws on each Expose, which is the one
 * thing that has to keep happening for the window to stay legible while the
 * parent is blocked in waitpid.
 *
 * There is no teardown in here and no exit path that matters. The parent kills
 * this process, which closes the last descriptor on the connection, and the
 * server destroys every resource the connection owned -- the window, the GC and
 * the font -- without being asked. That is why nothing above bothers to keep
 * their ids around.
 */
void nt_splash_x11_serve(int fd)
{
    unsigned char ev[32];
    unsigned char req[32];
    size_t tlen = strlen(NT_X_TEXT);

    for (;;) {
        if (nt_x_read(fd, ev, 32) != 0) {
            _exit(0);
        }
        /* 12 is Expose. The high bit marks a SendEvent, which is neither a
         * thing to trust nor a thing this needs. */
        if ((ev[0] & 0x7f) != 12) {
            continue;
        }
        /*
         * The connection owns exactly one window, so this can only be ours --
         * but an event carrying someone else's id would mean the stream is not
         * where this thinks it is, and drawing into a stranger's window on that
         * basis is worse than drawing nothing.
         */
        if (nt_x_get32(ev + 4) != nt_x_wid) {
            continue;
        }
        memset(req, 0, sizeof(req));
        req[0] = 76;
        req[1] = (unsigned char)tlen;
        nt_x_put16(req + 2, (unsigned)(4 + nt_x_pad4(tlen) / 4));
        nt_x_put32(req + 4, nt_x_wid);
        nt_x_put32(req + 8, nt_x_gc);
        nt_x_put16(req + 12, (unsigned)NT_X_PAD_X);
        nt_x_put16(req + 14, (unsigned)nt_x_baseline);
        memcpy(req + 16, NT_X_TEXT, tlen);
        if (nt_x_write(fd, req, 16 + nt_x_pad4(tlen)) != 0) {
            _exit(0);
        }
    }
}

#endif
