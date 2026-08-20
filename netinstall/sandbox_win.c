/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifdef _WIN32

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

/*
 * Job UI restrictions, by name rather than by bit, because the whole point of
 * this table is that the suite drives it and CI output has to be readable.
 *
 * The job object is the only thing on windows that reaches the app at all: the
 * polyglot compiles itself, STARTs the result and returns, so job membership is
 * inherited across that hop where a per-process mitigation policy would land on
 * cmd.exe and stop there. That is why it is worth this much trouble.
 */
static const struct {
    const char *name;
    DWORD bit;
} nt_job_ui_flags[] = {
    { "handles",          JOB_OBJECT_UILIMIT_HANDLES },
    { "readclipboard",    JOB_OBJECT_UILIMIT_READCLIPBOARD },
    { "writeclipboard",   JOB_OBJECT_UILIMIT_WRITECLIPBOARD },
    { "systemparameters", JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS },
    { "displaysettings",  JOB_OBJECT_UILIMIT_DISPLAYSETTINGS },
    { "globalatoms",      JOB_OBJECT_UILIMIT_GLOBALATOMS },
    { "desktop",          JOB_OBJECT_UILIMIT_DESKTOP },
    { "exitwindows",      JOB_OBJECT_UILIMIT_EXITWINDOWS },
    { NULL, 0 }
};

/*
 * Empty until the bisect says which of these a webview survives. Two rounds of
 * CI have shown the answer is not "all of them" and not obvious, so nothing
 * ships here on a guess; test/job-ui.sh is what fills this in.
 */
#define NT_JOB_UI_DEFAULT ""

static DWORD nt_job_ui_parse(const char *list, char *shown, size_t shownlen)
{
    DWORD mask = 0;
    size_t used = 0;
    const char *p = list;

    if (shown && shownlen) {
        shown[0] = '\0';
    }
    while (*p) {
        const char *end = strchr(p, ',');
        size_t n = end ? (size_t)(end - p) : strlen(p);
        int i;

        for (i = 0; nt_job_ui_flags[i].name; i++) {
            if (strlen(nt_job_ui_flags[i].name) != n ||
                strncmp(p, nt_job_ui_flags[i].name, n) != 0) {
                continue;
            }
            mask |= nt_job_ui_flags[i].bit;
            if (shown && used + n + 2 < shownlen) {
                if (used) {
                    shown[used++] = ',';
                }
                memcpy(shown + used, p, n);
                used += n;
                shown[used] = '\0';
            }
            break;
        }
        if (!end) {
            break;
        }
        p = end + 1;
    }
    return mask;
}

/*
 * A release binary has no way to be talked into a different set: the override
 * is compiled in only under -DNEUTRINO_TESTING, exactly like the test origin.
 */
static DWORD nt_job_ui_mask(char *shown, size_t shownlen)
{
    const char *list = NT_JOB_UI_DEFAULT;
#ifdef NEUTRINO_TESTING
    const char *over = getenv("NEUTRINO_TEST_JOB_UI");

    if (over && *over) {
        list = strcmp(over, "none") == 0 ? "" : over;
    }
#endif
    return nt_job_ui_parse(list, shown, shownlen);
}

static int nt_job_ui(HANDLE job, DWORD mask)
{
    JOBOBJECT_BASIC_UI_RESTRICTIONS ui;

    if (mask == 0) {
        return 1;
    }
    ZeroMemory(&ui, sizeof(ui));
    ui.UIRestrictionsClass = mask;
    return SetInformationJobObject(job, JobObjectBasicUIRestrictions,
                                   &ui, sizeof(ui)) ? 1 : 0;
}

/*
 * Every privilege but SeChangeNotifyPrivilege, which path traversal needs.
 * Removed rather than disabled, so nothing downstream can turn them back on,
 * and the token is inherited by everything the launcher starts.
 *
 * A standard user token carries few privileges to begin with, so this is a
 * small win rather than a large one. What makes it worth having is that it
 * survives the hop to the real app, which a per-process mitigation policy set
 * here would not: the polyglot compiles itself, STARTs the result and returns.
 */
static int nt_strip_privileges(void)
{
    TOKEN_PRIVILEGES *tp = NULL;
    HANDLE token = NULL;
    DWORD len = 0;
    LUID keep;
    DWORD i;
    int ok = 0;

    if (!LookupPrivilegeValueA(NULL, "SeChangeNotifyPrivilege", &keep)) {
        return 0;
    }
    if (!OpenProcessToken(GetCurrentProcess(),
                          TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) {
        return 0;
    }
    GetTokenInformation(token, TokenPrivileges, NULL, 0, &len);
    if (len) {
        tp = (TOKEN_PRIVILEGES *)malloc(len);
    }
    if (tp && GetTokenInformation(token, TokenPrivileges, tp, len, &len)) {
        for (i = 0; i < tp->PrivilegeCount; i++) {
            if (tp->Privileges[i].Luid.LowPart == keep.LowPart &&
                tp->Privileges[i].Luid.HighPart == keep.HighPart) {
                tp->Privileges[i].Attributes = 0;
            } else {
                tp->Privileges[i].Attributes = SE_PRIVILEGE_REMOVED;
            }
        }
        ok = AdjustTokenPrivileges(token, FALSE, tp, len, NULL, NULL) ? 1 : 0;
    }
    free(tp);
    CloseHandle(token);
    return ok;
}

int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen)
{
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    char uishown[256];
    char uinote[288];
    DWORD uimask;
    const char *privs;
    HANDLE job;

    (void)home;
    (void)appdir;

    if (phase == NT_PHASE_FETCH) {
        snprintf(desc, desclen, "none (fetch runs unconfined on windows)");
        return -1;
    }

    uimask = nt_job_ui_mask(uishown, sizeof(uishown));
    if (uimask) {
        snprintf(uinote, sizeof(uinote), " + ui restrictions (%s)", uishown);
    } else {
        uinote[0] = '\0';
    }

    if (!enforce) {
#ifdef NEUTRINO_CONFINE_TIGHT
        snprintf(desc, desclen, "job object%s + privileges stripped + low "
                                "integrity, writes confined to %s (reads are "
                                "not confined)" NT_OFFLINE_NOTE,
                 uinote, appdir);
#else
        snprintf(desc, desclen, "job object%s + privileges stripped (process "
                                "limits only; no filesystem confinement on "
                                "windows)" NT_OFFLINE_NOTE, uinote);
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
        !nt_job_ui(job, uimask) ||
        !AssignProcessToJobObject(job, GetCurrentProcess())) {
        CloseHandle(job);
        snprintf(desc, desclen, "none (job object rejected)");
        return -1;
    }

    /* Best effort: a token that refuses to shed its privileges is not a reason
     * to give up the job object, but --info must not then claim it. */
    privs = nt_strip_privileges() ? " + privileges stripped" : "";

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
    snprintf(desc, desclen, "job object%s%s + low integrity, writes confined to "
                            "%s (reads are not confined)" NT_OFFLINE_NOTE,
             uinote, privs, appdir);
    return 0;
#else
    snprintf(desc, desclen, "job object%s%s (process limits only; "
                            "no filesystem confinement on windows)"
                            NT_OFFLINE_NOTE, uinote, privs);
    return 0;
#endif
}

#endif
