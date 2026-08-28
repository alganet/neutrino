/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include "splash.h"

#ifdef _WIN32

/*
 * A Loading... window, drawn by this process with no help and no child.
 *
 * The other platforms reach for something the machine already has -- an X
 * server, a compositor, AppKit -- because a static musl binary cannot dlopen
 * and a cross-compile cannot link a framework. Windows has neither problem:
 * user32 is an import library that zig already ships, so the window is thirty
 * lines of the same C as everything else here. It is also the platform where
 * spawning something would be worst: an unsigned binary that a browser
 * downloaded ten seconds ago, launching mshta.exe or powershell.exe to draw a
 * box, is the exact shape every EDR product is built to notice.
 *
 * The pump runs on a thread of its own, and that is the one structural choice
 * worth explaining. nt_win_spawn ends in WaitForSingleObject(INFINITE) -- it is
 * shared by the fetch and by the payload launch, and turning it into a message
 * loop would put a window's redraw schedule inside the function that runs the
 * app. So the window gets a thread, the main line keeps its blocking wait, and
 * the two do not know about each other.
 */

#include <windows.h>
#include <stdio.h>

#define NT_W_TEXT "Loading..."
#define NT_W_CLASS "netinstall_splash"
#define NT_W_WIDTH 260
#define NT_W_HEIGHT 96

static HANDLE nt_w_thread = NULL;
static HANDLE nt_w_ready = NULL;
static DWORD nt_w_tid = 0;
static HWND nt_w_hwnd = NULL;

static LRESULT CALLBACK nt_w_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        RECT r;
        HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
        HGDIOBJ old = font ? SelectObject(dc, font) : NULL;

        GetClientRect(hwnd, &r);
        /*
         * The class brush already painted the background, so the text is drawn
         * straight onto it -- opaque drawing here would stamp a rectangle of
         * whatever the device context's background colour happens to be over
         * the top of it.
         */
        SetBkMode(dc, TRANSPARENT);
        DrawTextA(dc, NT_W_TEXT, -1, &r,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        if (old) {
            SelectObject(dc, old);
        }
        EndPaint(hwnd, &ps);
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
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
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

    x = (GetSystemMetrics(SM_CXSCREEN) - NT_W_WIDTH) / 2;
    y = (GetSystemMetrics(SM_CYSCREEN) - NT_W_HEIGHT) / 2;
    if (x < 0) {
        x = 0;
    }
    if (y < 0) {
        y = 0;
    }

    /*
     * WS_POPUP | WS_BORDER: no title bar, no buttons, no resize, no entry in
     * the task list. WS_EX_TOPMOST because the thing it is covering for has not
     * started yet and there is nothing else of this program's to be above.
     * WS_EX_NOACTIVATE, with SW_SHOWNA below, so that appearing does not take
     * the keyboard away from whatever the user is actually typing into -- a
     * download is not a reason to interrupt someone.
     */
    nt_w_hwnd = CreateWindowExA(WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                                NT_W_CLASS, NT_W_TEXT, WS_POPUP | WS_BORDER,
                                x, y, NT_W_WIDTH, NT_W_HEIGHT,
                                NULL, NULL, wc.hInstance, NULL);
    if (!nt_w_hwnd) {
        UnregisterClassA(NT_W_CLASS, wc.hInstance);
        SetEvent(nt_w_ready);
        return 0;
    }
    ShowWindow(nt_w_hwnd, SW_SHOWNA);
    UpdateWindow(nt_w_hwnd);

    /* Only now: the caller's answer is "there is a window", and until this
     * point that would not have been true. */
    SetEvent(nt_w_ready);

    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }

    DestroyWindow(nt_w_hwnd);
    nt_w_hwnd = NULL;
    UnregisterClassA(NT_W_CLASS, wc.hInstance);
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
    snprintf(desc, desclen, "win32 (%dx%d)", NT_W_WIDTH, NT_W_HEIGHT);
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
