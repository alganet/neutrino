/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifdef _WIN32

#include <windows.h>
#include <stdio.h>

#include "netinstall.h"
#include "sandbox.h"

/*
 * A job object is a resource boundary, not a filesystem one, and this file does
 * not pretend otherwise. Low integrity was the obvious next step
 * and does not work: it stops writes but not reads, %TEMP% does not redirect so
 * jsc.exe fails, and WebView2 is documented to break in low-IL hosts.
 * AppContainer is the only mechanism that would confine reads, but nesting it
 * inside Chromium's own lowbox tokens is unsupported.
 */
int nt_confine(nt_phase phase, const char *home, const char *appdir,
               char *desc, size_t desclen)
{
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    HANDLE job;

    (void)home;
    (void)appdir;

    if (phase == NT_PHASE_FETCH) {
        snprintf(desc, desclen, "none (fetch runs unconfined on windows)");
        return -1;
    }

    job = CreateJobObjectA(NULL, NULL);
    if (!job) {
        snprintf(desc, desclen, "none (job object unavailable)");
        return -1;
    }

    /*
     * Deliberately no KILL_ON_JOB_CLOSE. The windows polyglot compiles itself,
     * STARTs the result and returns, so this launcher exits while the app is
     * still coming up; killing the job on close takes the app down with it.
     */
    ZeroMemory(&limits, sizeof(limits));
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION |
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.BasicLimitInformation.ActiveProcessLimit = 64;

    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits)) ||
        !AssignProcessToJobObject(job, GetCurrentProcess())) {
        CloseHandle(job);
        snprintf(desc, desclen, "none (job object rejected)");
        return -1;
    }

    snprintf(desc, desclen, "job object (process limits only; "
                            "no filesystem confinement on windows)");
    return 0;
}

#endif
