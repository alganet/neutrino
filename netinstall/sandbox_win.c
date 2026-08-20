/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifdef _WIN32

#include <windows.h>
#include <stdio.h>

#ifdef NEUTRINO_CONFINE_TIGHT
#include <aclapi.h>
#include <sddl.h>
#endif

#include "netinstall.h"
#include "sandbox.h"

/*
 * There is no unprivileged way to deny an app the network on windows: WFP needs
 * administrator, and a job object does not express it. Naming that is better
 * than letting an -DNEUTRINO_CONFINE_OFFLINE build look like it did something.
 */
#ifdef NEUTRINO_CONFINE_OFFLINE
#define NT_OFFLINE_NOTE " (offline tier unavailable here)"
#else
#define NT_OFFLINE_NOTE ""
#endif

/*
 * A job object is a resource boundary, not a filesystem one, and this file does
 * not pretend otherwise. Low integrity was the obvious next step
 * and does not work: it stops writes but not reads, %TEMP% does not redirect so
 * jsc.exe fails, and WebView2 is documented to break in low-IL hosts.
 * AppContainer is the only mechanism that would confine reads, but nesting it
 * inside Chromium's own lowbox tokens is unsupported.
 */
#ifdef NEUTRINO_CONFINE_TIGHT
/*
 * A low integrity process cannot write to anything that lacks a Low mandatory
 * label, so the app dir has to carry one or the app cannot write its own files.
 * OICI makes it inheritable by whatever the app creates in there.
 */
static int nt_label_low(const char *path)
{
    PSECURITY_DESCRIPTOR sd = NULL;
    PACL sacl = NULL;
    BOOL present = FALSE;
    BOOL defaulted = FALSE;
    int ok = 0;

    if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(
            "S:(ML;OICI;NW;;;LW)", SDDL_REVISION_1, &sd, NULL)) {
        return 0;
    }
    if (GetSecurityDescriptorSacl(sd, &present, &sacl, &defaulted) && present) {
        ok = SetNamedSecurityInfoA((LPSTR)path, SE_FILE_OBJECT,
                                   LABEL_SECURITY_INFORMATION,
                                   NULL, NULL, NULL, sacl) == ERROR_SUCCESS;
    }
    LocalFree(sd);
    return ok;
}

/* A process may lower its own integrity level, never raise it. Children inherit. */
static int nt_drop_to_low(void)
{
    TOKEN_MANDATORY_LABEL tml;
    HANDLE token = NULL;
    PSID low = NULL;
    int ok = 0;

    if (!ConvertStringSidToSidA("S-1-16-4096", &low)) {
        return 0;
    }
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_DEFAULT, &token)) {
        ZeroMemory(&tml, sizeof(tml));
        tml.Label.Attributes = SE_GROUP_INTEGRITY;
        tml.Label.Sid = low;
        ok = SetTokenInformation(token, TokenIntegrityLevel, &tml,
                                 (DWORD)(sizeof(tml) + GetLengthSid(low))) ? 1 : 0;
        CloseHandle(token);
    }
    LocalFree(low);
    return ok;
}
#endif

int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
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

    if (!enforce) {
#ifdef NEUTRINO_CONFINE_TIGHT
        snprintf(desc, desclen, "job object + low integrity, writes confined to %s "
                                "(reads are not confined)" NT_OFFLINE_NOTE, appdir);
#else
        snprintf(desc, desclen, "job object (process limits only; "
                                "no filesystem confinement on windows)"
                                NT_OFFLINE_NOTE);
#endif
        return 0;
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

#ifdef NEUTRINO_CONFINE_TIGHT
    /*
     * Low integrity blocks writes, not reads: this stops an app trashing the
     * profile, but it can still read ~/.ssh and browser stores. Only an
     * AppContainer would close that, and it is documented to break WebView2.
     */
    if (!nt_label_low(appdir)) {
        snprintf(desc, desclen, "job object only (could not label %s low)", appdir);
        return -1;
    }
    if (!nt_drop_to_low()) {
        snprintf(desc, desclen, "job object only (could not drop to low integrity)");
        return -1;
    }
    snprintf(desc, desclen, "job object + low integrity, writes confined to %s "
                            "(reads are not confined)" NT_OFFLINE_NOTE, appdir);
    return 0;
#else
    snprintf(desc, desclen, "job object (process limits only; "
                            "no filesystem confinement on windows)"
                            NT_OFFLINE_NOTE);
    return 0;
#endif
}

#endif
