/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include "splash.h"

#ifdef _WIN32

/*
 * The splash window, drawn by this process with no help and no child.
 *
 * The other platforms reach for something the machine already has -- an X
 * server, a compositor, AppKit -- because a static musl binary cannot dlopen
 * and a cross-compile cannot link a framework. Windows has neither problem:
 * user32 and gdi32 are import libraries that zig already ships, so the window
 * is a few dozen lines of the same C as everything else here. It is also the
 * platform where spawning something would be worst: an unsigned binary that a
 * browser downloaded ten seconds ago, launching mshta.exe or powershell.exe to
 * draw a box, is the exact shape every EDR product is built to notice.
 *
 * The pump runs on a thread of its own, and that is the one structural choice
 * worth explaining. nt_win_spawn ends in WaitForSingleObject(INFINITE) -- it is
 * shared by the fetch and by the payload launch, and turning it into a message
 * loop would put a window's redraw schedule inside the function that runs the
 * app. So the window gets a thread, the main line keeps its blocking wait, and
 * the two do not know about each other. The animation needs nothing added to
 * that: a WM_TIMER is a message like any other, and the pump was already there
 * to deliver it.
 */

#include <windows.h>
#include <stdio.h>

#define NT_W_CLASS "netinstall_splash"
/*
 * The timer's id, which is per-window and needs only to be a number this file
 * uses once. WM_TIMER carries it back so that a window with two timers can tell
 * them apart; this one has one.
 */
#define NT_W_TIMER 1

/*
 * COLORREF is 0x00bbggrr -- the bytes the other way round from the 0xRRGGBB
 * splash.h writes -- so it is assembled from the components rather than cast.
 * The RGB macro would do it, and is spelled out here because the difference
 * between the two orders is invisible in a hex literal and produces a window
 * that is merely the wrong colour.
 */
#define NT_W_COLOUR(c) \
    RGB(NT_SPLASH_R(c), NT_SPLASH_G(c), NT_SPLASH_B(c))

static HANDLE nt_w_thread = NULL;
static HANDLE nt_w_ready = NULL;
static DWORD nt_w_tid = 0;
static HWND nt_w_hwnd = NULL;
/* Which step of the animation is on screen, advanced by the timer and read by
 * the paint. Both run on the window's thread, so there is nothing to guard. */
static int nt_w_phase = 0;
/*
 * The window's background, which is a brush this file owns rather than
 * COLOR_WINDOW + 1. The system colour is what the class used to carry and it is
 * whatever the user's theme says -- dark on a dark desktop, which turned a
 * light window with dark cells into a dark window with dark cells. Every other
 * platform paints NT_SPLASH_RGB_BG, and the point of this round is that the
 * four lanes photograph the same window.
 */
static HBRUSH nt_w_bg = NULL;

static LRESULT CALLBACK nt_w_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        HBRUSH dim = CreateSolidBrush(NT_W_COLOUR(NT_SPLASH_RGB_DIM));
        HBRUSH lit = CreateSolidBrush(NT_W_COLOUR(NT_SPLASH_RGB_LIT));
        RECT client;
        int i;

        /* The edge first, and drawn rather than asked of the style: WS_BORDER
         * is a line in whatever colour the system says, and this window is
         * supposed to look like the same window on four platforms. FrameRect
         * takes the outer rectangle and draws one pixel inside it. */
        GetClientRect(hwnd, &client);
        if (lit) {
            FrameRect(dc, &client, lit);
        }

        /*
         * The cells and nothing else. The class brush has already painted the
         * background -- and goes on painting it, because the invalidation the
         * timer asks for below erases -- so every pixel of this window is
         * either the background or one of the twelve rectangles, and there is
         * no third thing for a frame to leave behind.
         */
        for (i = 0; dim && lit && i < NT_SPLASH_CELLS; i++) {
            RECT cell;

            cell.left = NT_SPLASH_CELL_X(i);
            cell.top = NT_SPLASH_TRACK_Y;
            cell.right = cell.left + NT_SPLASH_CELL_W;
            cell.bottom = cell.top + NT_SPLASH_CELL_H;
            FillRect(dc, &cell, nt_splash_cell_lit(nt_w_phase, i) ? lit : dim);
        }
        /*
         * Both, and on every paint. A GDI brush is a handle out of a finite
         * table, and a window that paints eleven times a second for two minutes
         * is fourteen hundred paints -- so a leak that would be invisible in a
         * splash drawn once is a process running out of objects while the
         * download it is decorating is still going.
         */
        if (dim) {
            DeleteObject(dim);
        }
        if (lit) {
            DeleteObject(lit);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    if (msg == WM_TIMER && wp == NT_W_TIMER) {
        nt_w_phase = (nt_w_phase + 1) % NT_SPLASH_CELLS;
        /*
         * TRUE, so the background is erased before the paint. The cells are
         * fully repainted either way and FALSE would be one fewer fill -- but
         * the window is 260 by 96, the saving is nothing, and an erase is what
         * makes this correct if a future cell is ever drawn somewhere the next
         * frame does not cover.
         */
        InvalidateRect(hwnd, NULL, TRUE);
        return 0;
    }
    /*
     * There is no close button and nothing to close it with -- the window is
     * WS_POPUP -- but a WM_CLOSE can still arrive from outside, and honouring
     * it by destroying the window would leave this thread pumping messages for
     * a window that no longer exists. The window's lifetime belongs to
     * nt_splash_platform_down and to nothing else.
     */
    if (msg == WM_CLOSE) {
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static DWORD WINAPI nt_w_run(LPVOID arg)
{
    WNDCLASSA wc;
    MSG msg;
    int x, y;

    (void)arg;

    ZeroMemory(&wc, sizeof(wc));
    wc.lpfnWndProc = nt_w_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, IDC_ARROW);
    nt_w_bg = CreateSolidBrush(NT_W_COLOUR(NT_SPLASH_RGB_BG));
    wc.hbrBackground = nt_w_bg;
    wc.lpszClassName = NT_W_CLASS;
    /*
     * A failed registration is very nearly always "already registered", which
     * cannot happen here -- one process, one splash -- so it is treated as
     * fatal to the window rather than worked around. The event is set either
     * way, or the caller waits for a thread that has already given up.
     */
    if (!RegisterClassA(&wc)) {
        SetEvent(nt_w_ready);
        return 0;
    }

    x = (GetSystemMetrics(SM_CXSCREEN) - NT_SPLASH_WIDTH) / 2;
    y = (GetSystemMetrics(SM_CYSCREEN) - NT_SPLASH_HEIGHT) / 2;
    if (x < 0) {
        x = 0;
    }
    if (y < 0) {
        y = 0;
    }

    /*
     * WS_POPUP alone: no title bar, no buttons, no resize, no entry in the
     * task list, and no border either -- the edge is painted with the rest of
     * the window, so that WS_BORDER's system colour is not the one thing about
     * this window that windows chooses. WS_EX_TOPMOST because the thing it is covering for has not
     * started yet and there is nothing else of this program's to be above.
     * WS_EX_NOACTIVATE, with SW_SHOWNA below, so that appearing does not take
     * the keyboard away from whatever the user is actually typing into -- a
     * download is not a reason to interrupt someone.
     */
    nt_w_hwnd = CreateWindowExA(WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                                NT_W_CLASS, "netinstall", WS_POPUP,
                                x, y, NT_SPLASH_WIDTH, NT_SPLASH_HEIGHT,
                                NULL, NULL, wc.hInstance, NULL);
    if (!nt_w_hwnd) {
        UnregisterClassA(NT_W_CLASS, wc.hInstance);
        SetEvent(nt_w_ready);
        return 0;
    }
    ShowWindow(nt_w_hwnd, SW_SHOWNA);
    UpdateWindow(nt_w_hwnd);
    /*
     * After the window exists and before the caller is told about it, so that
     * there is no window on screen that is not yet moving. A timer that fails
     * to be created is not a reason to withdraw the window: a still indicator
     * is worse than a moving one and better than nothing, and the download it
     * is covering for is what the user is actually waiting on.
     */
    SetTimer(nt_w_hwnd, NT_W_TIMER, (UINT)NT_SPLASH_FRAME_MS, NULL);

    /* Only now: the caller's answer is "there is a window", and until this
     * point that would not have been true. */
    SetEvent(nt_w_ready);

    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }

    KillTimer(nt_w_hwnd, NT_W_TIMER);
    DestroyWindow(nt_w_hwnd);
    nt_w_hwnd = NULL;
    UnregisterClassA(NT_W_CLASS, wc.hInstance);
    /* After the class that names it is gone, and not before: a class brush is
     * the class's for as long as the class exists. */
    if (nt_w_bg) {
        DeleteObject(nt_w_bg);
        nt_w_bg = NULL;
    }
    return 0;
}

int nt_splash_platform_up(char *desc, size_t desclen)
{
    nt_w_ready = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!nt_w_ready) {
        snprintf(desc, desclen, "none (cannot create the ready event)");
        return -1;
    }
    nt_w_thread = CreateThread(NULL, 0, nt_w_run, NULL, 0, &nt_w_tid);
    if (!nt_w_thread) {
        CloseHandle(nt_w_ready);
        nt_w_ready = NULL;
        snprintf(desc, desclen, "none (cannot start the window thread)");
        return -1;
    }
    /*
     * Bounded, because this is on the way to a download and not on the way to
     * a window. If the thread has not managed to put something on screen in two
     * seconds it is not going to, and the right outcome is a silent download
     * rather than a launcher that hangs deciding how to say it is busy.
     */
    WaitForSingleObject(nt_w_ready, 2000);
    if (!nt_w_hwnd) {
        /* Nothing came up. The thread has already unwound or is about to. */
        WaitForSingleObject(nt_w_thread, 2000);
        CloseHandle(nt_w_thread);
        CloseHandle(nt_w_ready);
        nt_w_thread = NULL;
        nt_w_ready = NULL;
        snprintf(desc, desclen, "none (the window did not come up)");
        return -1;
    }
    snprintf(desc, desclen, "win32 (%dx%d)", NT_SPLASH_WIDTH, NT_SPLASH_HEIGHT);
    return 0;
}

void nt_splash_platform_down(void)
{
    if (!nt_w_thread) {
        return;
    }
    /*
     * To the thread and not to the window: the loop below ends on WM_QUIT, and
     * PostMessage to a HWND would have to be answered by a window procedure
     * that then had to decide to quit. One message, one meaning.
     */
    PostThreadMessage(nt_w_tid, WM_QUIT, 0, 0);
    /*
     * Bounded for the same reason as above, and then let go of regardless. A
     * pump that will not stop must not become a launcher that will not start;
     * the window belongs to a thread of a process that is about to run the app
     * and then exit, and both of those take it away.
     */
    WaitForSingleObject(nt_w_thread, 2000);
    CloseHandle(nt_w_thread);
    if (nt_w_ready) {
        CloseHandle(nt_w_ready);
    }
    nt_w_thread = NULL;
    nt_w_ready = NULL;
    nt_w_tid = 0;
}

#endif
