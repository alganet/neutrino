/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include "netinstall.h"
#include "splash.h"

#if defined(__linux__) || defined(__OpenBSD__) || defined(__FreeBSD__) || \
    defined(__NetBSD__)

/*
 * The splash window, drawn by talking to a wayland compositor over its own
 * socket. No libwayland, for the reason splash_x11.c does not use libX11: the
 * linux binaries are static musl, where dlopen is a stub, and linking a toolkit
 * would trade a launcher that runs anywhere for one that runs where its
 * libraries are.
 *
 * This is the more expensive of the two, and the reason is worth stating
 * because it is the opposite of what one expects. X11 has PolyFillRectangle:
 * the rectangles are sent and the server fills them. Wayland has no drawing in
 * it at all -- the compositor is handed a buffer of finished pixels -- so every
 * cell is a loop over its own pixels here, and every frame is a whole new
 * buffer to attach and commit.
 *
 * It used to be worse than that, and the difference is what this file lost when
 * the window stopped saying "Loading...": a bitmap table of the eight distinct
 * characters in that word, six by eight pixels each, one bit per pixel, with a
 * rasteriser under it. That was carried in the binary because the protocol
 * offers no text, and it was also the reason the wayland window never looked
 * quite like the other four. Rectangles are the one thing this protocol and the
 * X11 one can both be asked for at exactly the same size. See splash.h.
 *
 * The rest of the difference is the protocol's shape. There is a registry to
 * enumerate before anything can be created, a shared-memory file to make and
 * pass by descriptor, a configure to acknowledge before the first buffer may be
 * attached, and a ping that must be answered or the compositor removes the
 * window as unresponsive. The last of those is why the event loop is not
 * optional, and why this ends in a fork like the X11 path does.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* Object ids. 1 is the display, and everything else is allocated from 2 up. */
#define NT_WL_DISPLAY 1

/*
 * The buffer, twice.
 *
 * A frame is written into the mapping the compositor is reading out of, so
 * writing the next one into the buffer that is currently on screen is a torn
 * cell for as long as it takes to fill twelve rectangles. Two buffers in one
 * pool, alternated, is the whole fix and costs a hundred kilobytes. The
 * protocol's own answer -- wait for wl_buffer.release before touching a buffer
 * again -- is not used: it is a fourth thing for the event loop to be right
 * about, and at eleven frames a second with two buffers the release for the one
 * about to be reused arrived a whole frame ago.
 */
#define NT_WL_SLOTS 2

static unsigned nt_wl_next_id = 2;

/* Bound globals, and the objects built out of them. */
static unsigned nt_wl_compositor = 0;
static unsigned nt_wl_shm = 0;
static unsigned nt_wl_base = 0;
static unsigned nt_wl_surface = 0;
static unsigned nt_wl_xdgsurf = 0;

/*
 * What the child redraws with, filled by nt_splash_wayland_up and read by
 * nt_splash_wayland_serve on the other side of a fork -- which copies the
 * variables and shares the mapping, since it was made MAP_SHARED on a
 * descriptor the compositor holds too.
 *
 * The mapping is deliberately not unmapped when the first frame has been
 * painted, which is what this file did when there was only ever one frame.
 */
static unsigned char *nt_wl_map = NULL;
static size_t nt_wl_slotbytes = 0;
static unsigned nt_wl_buffer[NT_WL_SLOTS] = { 0, 0 };
/* The last slot, so that the first frame lands in the first one. */
static int nt_wl_slot = NT_WL_SLOTS - 1;

static unsigned nt_wl_id(void)
{
    return nt_wl_next_id++;
}

static void nt_wl_put32(unsigned char *b, size_t *n, unsigned v)
{
    b[*n + 0] = (unsigned char)(v & 0xff);
    b[*n + 1] = (unsigned char)((v >> 8) & 0xff);
    b[*n + 2] = (unsigned char)((v >> 16) & 0xff);
    b[*n + 3] = (unsigned char)((v >> 24) & 0xff);
    *n += 4;
}

static unsigned nt_wl_get32(const unsigned char *b)
{
    return (unsigned)b[0] | ((unsigned)b[1] << 8) |
           ((unsigned)b[2] << 16) | ((unsigned)b[3] << 24);
}

/* A string is its length including the terminator, the bytes, then padding. */
static void nt_wl_putstr(unsigned char *b, size_t *n, const char *s)
{
    size_t len = strlen(s) + 1;
    size_t pad = (4 - (len & 3)) & 3;

    nt_wl_put32(b, n, (unsigned)len);
    memcpy(b + *n, s, len);
    *n += len;
    memset(b + *n, 0, pad);
    *n += pad;
}

/*
 * The target object, then a placeholder for the word that pairs the opcode with
 * the message size. nt_wl_finish replaces it once the size exists; every send
 * here is head, arguments, finish, in that order.
 */
static void nt_wl_head(unsigned char *b, size_t *n, unsigned obj, unsigned op)
{
    nt_wl_put32(b, n, obj);
    nt_wl_put32(b, n, op);
}

static int nt_wl_finish(int fd, unsigned char *b, size_t n, unsigned op, int passfd)
{
    /*
     * The second word carries the size and the opcode together, and the size is
     * only known once the arguments are in -- so nt_wl_head leaves the opcode
     * there alone and this writes over it with both.
     */
    size_t at = 4;

    nt_wl_put32(b, &at, ((unsigned)n << 16) | (op & 0xffff));

    if (passfd < 0) {
        const char *p = (const char *)b;
        size_t left = n;

        while (left > 0) {
            ssize_t k = write(fd, p, left);

            if (k < 0) {
                if (errno == EINTR) {
                    continue;
                }
                return -1;
            }
            p += k;
            left -= (size_t)k;
        }
        return 0;
    }
    /*
     * A descriptor does not travel in the message body -- it travels beside it,
     * in the control data of one sendmsg, and the compositor pairs it with the
     * next request whose signature says it takes one. Which is why this is the
     * only send here that cannot be a plain write.
     */
    {
        struct msghdr msg;
        struct iovec io;
        char control[CMSG_SPACE(sizeof(int))];
        struct cmsghdr *cm;

        memset(&msg, 0, sizeof(msg));
        memset(control, 0, sizeof(control));
        io.iov_base = b;
        io.iov_len = n;
        msg.msg_iov = &io;
        msg.msg_iovlen = 1;
        msg.msg_control = control;
        msg.msg_controllen = sizeof(control);
        cm = CMSG_FIRSTHDR(&msg);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cm), &passfd, sizeof(int));
        while (sendmsg(fd, &msg, 0) < 0) {
            if (errno != EINTR) {
                return -1;
            }
        }
        return 0;
    }
}

/* Reads exactly one event: the eight byte header, then its body. */
static int nt_wl_event(int fd, unsigned *obj, unsigned *op, unsigned char *body,
                       size_t bodymax, size_t *bodylen)
{
    unsigned char head[8];
    unsigned word;
    size_t size;
    char *p = (char *)head;
    size_t left = 8;

    while (left > 0) {
        ssize_t k = read(fd, p, left);

        if (k < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (k == 0) {
            return -1;
        }
        p += k;
        left -= (size_t)k;
    }
    *obj = nt_wl_get32(head);
    word = nt_wl_get32(head + 4);
    *op = word & 0xffff;
    size = word >> 16;
    if (size < 8 || size - 8 > bodymax) {
        return -1;
    }
    *bodylen = size - 8;
    left = *bodylen;
    p = (char *)body;
    while (left > 0) {
        ssize_t k = read(fd, p, left);

        if (k < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (k == 0) {
            return -1;
        }
        p += k;
        left -= (size_t)k;
    }
    return 0;
}

static int nt_wl_connect(void)
{
    const char *disp = getenv("WAYLAND_DISPLAY");
    const char *dir = getenv("XDG_RUNTIME_DIR");
    struct sockaddr_un sa;
    int fd;

    if (!disp || !*disp) {
        return -1;
    }
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    if (disp[0] == '/') {
        /* An absolute WAYLAND_DISPLAY is used as-is and needs no runtime dir. */
        strncpy(sa.sun_path, disp, sizeof(sa.sun_path) - 1);
    } else {
        if (!dir || !*dir) {
            return -1;
        }
        if ((int)snprintf(sa.sun_path, sizeof(sa.sun_path), "%s/%s", dir, disp) >=
            (int)sizeof(sa.sun_path)) {
            return -1;
        }
    }
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/*
 * Everything the compositor offers, announced one event at a time, ending when
 * the sync callback this asked for comes back. Only three of them matter: one
 * to make a surface with, one to make shared memory with, and the shell that
 * turns a surface into a window.
 */
static int nt_wl_globals(int fd)
{
    unsigned char buf[512];
    unsigned char body[4096];
    size_t n, blen;
    unsigned registry = nt_wl_id();
    unsigned sync = nt_wl_id();

    n = 0;
    nt_wl_head(buf, &n, NT_WL_DISPLAY, 1);      /* get_registry */
    nt_wl_put32(buf, &n, registry);
    if (nt_wl_finish(fd, buf, n, 1, -1) != 0) {
        return -1;
    }
    n = 0;
    nt_wl_head(buf, &n, NT_WL_DISPLAY, 0);      /* sync */
    nt_wl_put32(buf, &n, sync);
    if (nt_wl_finish(fd, buf, n, 0, -1) != 0) {
        return -1;
    }

    for (;;) {
        unsigned obj, op;

        if (nt_wl_event(fd, &obj, &op, body, sizeof(body), &blen) != 0) {
            return -1;
        }
        if (obj == sync && op == 0) {
            break;                              /* done: the list is complete */
        }
        if (obj == NT_WL_DISPLAY && op == 0) {
            return -1;                          /* wl_display.error */
        }
        if (obj == registry && op == 0 && blen >= 12) {
            unsigned name = nt_wl_get32(body);
            unsigned len = nt_wl_get32(body + 4);
            const char *iface = (const char *)(body + 8);
            unsigned padded;
            unsigned version;
            unsigned want = 0;
            unsigned *slot = NULL;

            /*
             * The length is checked against what actually arrived before it is
             * used for anything, and rounding it up is done only after that.
             * A length of 0xffffffff rounds up to zero -- so a check written
             * the other way round admits the message, and strcmp then runs off
             * the end of a body that was never terminated. This is the one
             * place in this file that reads a size chosen by the other end.
             */
            if (len == 0 || len > blen - 8) {
                continue;
            }
            if (body[8 + len - 1] != '\0') {
                continue;
            }
            padded = (len + 3) & ~3u;
            if (blen < (size_t)8 + padded + 4) {
                continue;
            }
            version = nt_wl_get32(body + 8 + padded);

            if (strcmp(iface, "wl_compositor") == 0) {
                slot = &nt_wl_compositor; want = 1;
            } else if (strcmp(iface, "wl_shm") == 0) {
                slot = &nt_wl_shm; want = 1;
            } else if (strcmp(iface, "xdg_wm_base") == 0) {
                slot = &nt_wl_base; want = 1;
            }
            if (!slot || *slot) {
                continue;
            }
            /*
             * Version 1 of each, deliberately. Every request this file sends
             * exists in the first version of its interface, and asking for more
             * than is used is how a client stops working on a compositor that
             * is merely older.
             */
            (void)version;
            *slot = nt_wl_id();
            n = 0;
            nt_wl_head(buf, &n, registry, 0);   /* bind */
            nt_wl_put32(buf, &n, name);
            nt_wl_putstr(buf, &n, iface);
            nt_wl_put32(buf, &n, want);
            nt_wl_put32(buf, &n, *slot);
            if (nt_wl_finish(fd, buf, n, 0, -1) != 0) {
                return -1;
            }
        }
    }
    return nt_wl_compositor && nt_wl_shm && nt_wl_base ? 0 : -1;
}

/*
 * One frame of pixels, into one of the two slots.
 *
 * No bounds checks in the inner loop, unlike the rasteriser this replaced. The
 * track is NT_SPLASH_TRACK_W wide inside a window NT_SPLASH_WIDTH wide and both
 * are constants in splash.h, so a cell that ran off the edge would be a
 * compile-time arithmetic error and not a runtime one -- and a clamp here would
 * hide it rather than prevent it.
 */
static void nt_wl_paint(unsigned *px, int phase)
{
    int i, x, y;

    for (i = 0; i < NT_SPLASH_WIDTH * NT_SPLASH_HEIGHT; i++) {
        px[i] = (unsigned)NT_SPLASH_RGB_BG;
    }
    /* The edge, which on this platform is four runs of the background loop's
     * own pixels rather than anything the compositor is asked for. */
    for (x = 0; x < NT_SPLASH_WIDTH; x++) {
        px[x] = (unsigned)NT_SPLASH_RGB_EDGE;
        px[(NT_SPLASH_HEIGHT - 1) * NT_SPLASH_WIDTH + x] = (unsigned)NT_SPLASH_RGB_EDGE;
    }
    for (y = 0; y < NT_SPLASH_HEIGHT; y++) {
        px[y * NT_SPLASH_WIDTH] = (unsigned)NT_SPLASH_RGB_EDGE;
        px[y * NT_SPLASH_WIDTH + NT_SPLASH_WIDTH - 1] = (unsigned)NT_SPLASH_RGB_EDGE;
    }
    for (i = 0; i < NT_SPLASH_CELLS; i++) {
        unsigned colour = nt_splash_cell_lit(phase, i)
                              ? (unsigned)NT_SPLASH_RGB_LIT
                              : (unsigned)NT_SPLASH_RGB_DIM;

        for (y = 0; y < NT_SPLASH_CELL_H; y++) {
            unsigned *row = px + (NT_SPLASH_TRACK_Y + y) * NT_SPLASH_WIDTH +
                            NT_SPLASH_CELL_X(i);

            for (x = 0; x < NT_SPLASH_CELL_W; x++) {
                row[x] = colour;
            }
        }
    }
}

/*
 * Paint the next phase into the slot that is not on screen and put it there:
 * attach, damage, commit, which is the three-request sequence any change to a
 * wayland surface is. Used for the first frame in the parent and for every one
 * after it in the child, so that the two cannot disagree about what a frame is.
 */
static int nt_wl_frame(int fd, int phase)
{
    unsigned char buf[64];
    size_t n;

    nt_wl_slot = (nt_wl_slot + 1) % NT_WL_SLOTS;
    nt_wl_paint((unsigned *)(nt_wl_map + (size_t)nt_wl_slot * nt_wl_slotbytes),
                phase);

    n = 0;
    nt_wl_head(buf, &n, nt_wl_surface, 1);      /* attach */
    nt_wl_put32(buf, &n, nt_wl_buffer[nt_wl_slot]);
    nt_wl_put32(buf, &n, 0);
    nt_wl_put32(buf, &n, 0);
    if (nt_wl_finish(fd, buf, n, 1, -1) != 0) {
        return -1;
    }
    n = 0;
    nt_wl_head(buf, &n, nt_wl_surface, 2);      /* damage */
    nt_wl_put32(buf, &n, 0);
    nt_wl_put32(buf, &n, 0);
    nt_wl_put32(buf, &n, NT_SPLASH_WIDTH);
    nt_wl_put32(buf, &n, NT_SPLASH_HEIGHT);
    if (nt_wl_finish(fd, buf, n, 2, -1) != 0) {
        return -1;
    }
    n = 0;
    nt_wl_head(buf, &n, nt_wl_surface, 6);      /* commit */
    return nt_wl_finish(fd, buf, n, 6, -1);
}

/*
 * A file the compositor can map. Unlinked the moment it exists, so what is
 * shared is the descriptor and nothing on disk carries a name anyone else could
 * open.
 */
static int nt_wl_shmfile(size_t size)
{
    const char *dir = getenv("XDG_RUNTIME_DIR");
    char path[512];
    int fd;

    if (!dir || !*dir) {
        dir = "/tmp";
    }
    if ((int)snprintf(path, sizeof(path), "%s/nt-splash-XXXXXX", dir) >=
        (int)sizeof(path)) {
        return -1;
    }
    fd = mkstemp(path);
    if (fd < 0) {
        return -1;
    }
    unlink(path);
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int nt_splash_wayland_up(char *desc, size_t desclen)
{
    unsigned char buf[512];
    unsigned char body[4096];
    size_t n, blen;
    unsigned toplevel, pool;
    size_t stride = (size_t)NT_SPLASH_WIDTH * 4;
    size_t slotbytes = stride * NT_SPLASH_HEIGHT;
    size_t size = slotbytes * NT_WL_SLOTS;
    int slot;
    unsigned serial = 0;
    int shmfd;
    void *map;
    int fd;

    fd = nt_wl_connect();
    if (fd < 0) {
        snprintf(desc, desclen, "none (no wayland socket)");
        return -1;
    }
    if (nt_wl_globals(fd) != 0) {
        close(fd);
        snprintf(desc, desclen, "none (compositor offers no xdg_wm_base)");
        return -1;
    }

    nt_wl_surface = nt_wl_id();
    n = 0;
    nt_wl_head(buf, &n, nt_wl_compositor, 0);   /* create_surface */
    nt_wl_put32(buf, &n, nt_wl_surface);
    if (nt_wl_finish(fd, buf, n, 0, -1) != 0) {
        goto fail;
    }

    nt_wl_xdgsurf = nt_wl_id();
    n = 0;
    nt_wl_head(buf, &n, nt_wl_base, 2);         /* get_xdg_surface */
    nt_wl_put32(buf, &n, nt_wl_xdgsurf);
    nt_wl_put32(buf, &n, nt_wl_surface);
    if (nt_wl_finish(fd, buf, n, 2, -1) != 0) {
        goto fail;
    }

    toplevel = nt_wl_id();
    n = 0;
    nt_wl_head(buf, &n, nt_wl_xdgsurf, 1);      /* get_toplevel */
    nt_wl_put32(buf, &n, toplevel);
    if (nt_wl_finish(fd, buf, n, 1, -1) != 0) {
        goto fail;
    }

    n = 0;
    nt_wl_head(buf, &n, toplevel, 2);           /* set_title */
    nt_wl_putstr(buf, &n, "netinstall");
    if (nt_wl_finish(fd, buf, n, 2, -1) != 0) {
        goto fail;
    }
    n = 0;
    nt_wl_head(buf, &n, toplevel, 3);           /* set_app_id */
    nt_wl_putstr(buf, &n, "netinstall");
    if (nt_wl_finish(fd, buf, n, 3, -1) != 0) {
        goto fail;
    }

    /*
     * The first commit carries no buffer on purpose. It is what asks the
     * compositor to configure the surface, and a buffer attached before that
     * configure is acknowledged is a protocol error rather than an early
     * window.
     */
    n = 0;
    nt_wl_head(buf, &n, nt_wl_surface, 6);      /* commit */
    if (nt_wl_finish(fd, buf, n, 6, -1) != 0) {
        goto fail;
    }

    for (;;) {
        unsigned obj, op;

        if (nt_wl_event(fd, &obj, &op, body, sizeof(body), &blen) != 0) {
            goto fail;
        }
        if (obj == NT_WL_DISPLAY && op == 0) {
            goto fail;
        }
        if (obj == nt_wl_base && op == 0 && blen >= 4) {
            /* A ping may arrive before the configure does. */
            n = 0;
            nt_wl_head(buf, &n, nt_wl_base, 3); /* pong */
            nt_wl_put32(buf, &n, nt_wl_get32(body));
            if (nt_wl_finish(fd, buf, n, 3, -1) != 0) {
                goto fail;
            }
            continue;
        }
        if (obj == nt_wl_xdgsurf && op == 0 && blen >= 4) {
            serial = nt_wl_get32(body);
            break;
        }
    }
    n = 0;
    nt_wl_head(buf, &n, nt_wl_xdgsurf, 4);      /* ack_configure */
    nt_wl_put32(buf, &n, serial);
    if (nt_wl_finish(fd, buf, n, 4, -1) != 0) {
        goto fail;
    }

    shmfd = nt_wl_shmfile(size);
    if (shmfd < 0) {
        close(fd);
        snprintf(desc, desclen, "none (no shared memory for the buffer)");
        return -1;
    }
    map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, shmfd, 0);
    if (map == MAP_FAILED) {
        close(shmfd);
        close(fd);
        snprintf(desc, desclen, "none (cannot map the buffer)");
        return -1;
    }
    /* Kept, not unmapped: the child paints every frame after this one through
     * it, and the fork below shares it rather than copying it. */
    nt_wl_map = (unsigned char *)map;
    nt_wl_slotbytes = slotbytes;

    pool = nt_wl_id();
    n = 0;
    nt_wl_head(buf, &n, nt_wl_shm, 0);          /* create_pool */
    nt_wl_put32(buf, &n, pool);
    nt_wl_put32(buf, &n, (unsigned)size);
    if (nt_wl_finish(fd, buf, n, 0, shmfd) != 0) {
        close(shmfd);
        goto fail;
    }
    close(shmfd);

    /* Both buffers out of the one pool, at their two offsets into it. They are
     * made here rather than as each is first needed because the child has no
     * way to allocate an object id the parent does not already know about. */
    for (slot = 0; slot < NT_WL_SLOTS; slot++) {
        nt_wl_buffer[slot] = nt_wl_id();
        n = 0;
        nt_wl_head(buf, &n, pool, 0);           /* create_buffer */
        nt_wl_put32(buf, &n, nt_wl_buffer[slot]);
        nt_wl_put32(buf, &n, (unsigned)((size_t)slot * slotbytes));
        nt_wl_put32(buf, &n, NT_SPLASH_WIDTH);
        nt_wl_put32(buf, &n, NT_SPLASH_HEIGHT);
        nt_wl_put32(buf, &n, (unsigned)stride);
        nt_wl_put32(buf, &n, 1);                /* xrgb8888 */
        if (nt_wl_finish(fd, buf, n, 0, -1) != 0) {
            goto fail;
        }
    }

    if (nt_wl_frame(fd, 0) != 0) {
        goto fail;
    }

    snprintf(desc, desclen, "wayland (%dx%d)", NT_SPLASH_WIDTH, NT_SPLASH_HEIGHT);
    return fd;

fail:
    close(fd);
    /* The mapping too, on the paths that made it. There is no child on this
     * side of the label, so nothing is left that would have read it -- and this
     * function's caller goes on to run a download in this process. */
    if (nt_wl_map) {
        munmap(nt_wl_map, size);
        nt_wl_map = NULL;
    }
    snprintf(desc, desclen, "none (compositor closed the connection)");
    return -1;
}

/*
 * The child. Three things now, where the X11 child has two.
 *
 * Answering ping is the part that is not optional: a compositor that does not
 * get a pong back within its own timeout is entitled to tell the user this
 * window is not responding, and to remove it. Configure is answered too,
 * because one arrives whenever the window is resized or moved between outputs,
 * and an unacknowledged configure is a protocol error. And a frame falls due
 * every NT_SPLASH_FRAME_MS whether or not either of those has arrived, which is
 * why this waits in poll rather than in the read it used to sit in.
 *
 * The phase is advanced against the clock and not against the number of times
 * poll returned, for the reason splash_x11.c says at more length: a compositor
 * that sends anything at all -- and one that has released a buffer sends
 * something on every frame -- would otherwise set the speed of the animation.
 */
void nt_splash_wayland_serve(int fd)
{
    unsigned char buf[64];
    unsigned char body[4096];
    size_t n, blen;
    int phase = 0;
    long last = nt_now_ms();
    long due = NT_SPLASH_FRAME_MS;

    for (;;) {
        struct pollfd pfd;
        unsigned obj, op;
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
            if (nt_wl_event(fd, &obj, &op, body, sizeof(body), &blen) != 0) {
                _exit(0);
            }
            if (obj == NT_WL_DISPLAY && op == 0) {
                _exit(0);
            }
            if (obj == nt_wl_base && op == 0 && blen >= 4) {
                n = 0;
                nt_wl_head(buf, &n, nt_wl_base, 3);
                nt_wl_put32(buf, &n, nt_wl_get32(body));
                if (nt_wl_finish(fd, buf, n, 3, -1) != 0) {
                    _exit(0);
                }
            } else if (obj == nt_wl_xdgsurf && op == 0 && blen >= 4) {
                n = 0;
                nt_wl_head(buf, &n, nt_wl_xdgsurf, 4);
                nt_wl_put32(buf, &n, nt_wl_get32(body));
                if (nt_wl_finish(fd, buf, n, 4, -1) != 0) {
                    _exit(0);
                }
                /*
                 * A bare commit, which shows the buffer already attached.
                 * Painting a fresh frame here instead would work and was the
                 * first spelling of this -- but a configure is the compositor's
                 * to send as often as it likes, and a handler that flips the
                 * buffer on each one can write into the buffer being read from
                 * if two arrive inside a frame. The clock below owes a frame
                 * within NT_SPLASH_FRAME_MS regardless, so there is nothing for
                 * this path to be in a hurry about.
                 */
                n = 0;
                nt_wl_head(buf, &n, nt_wl_surface, 6);
                if (nt_wl_finish(fd, buf, n, 6, -1) != 0) {
                    _exit(0);
                }
            }
            /* Everything else, wl_buffer.release included, is the compositor
             * saying something this does not need to act on. */
        }
        now = nt_now_ms();
        if (now - last < NT_SPLASH_FRAME_MS) {
            due = NT_SPLASH_FRAME_MS - (now - last);
            continue;
        }
        last = now;
        due = NT_SPLASH_FRAME_MS;
        phase = (phase + 1) % NT_SPLASH_CELLS;
        if (nt_wl_frame(fd, phase) != 0) {
            _exit(0);
        }
    }
}

#endif
