/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

/*
 * lowfetch-probe.c - what windows would cost the fetch child, measured.
 *
 * nt_fetch_confine_win has no tier branch in it: a tight build downloads the
 * payload behind a job object and a stripped token, which is a resource
 * boundary and not a filesystem one, while its run phase drops to low
 * integrity. PR 10 parked that with a reason -- low integrity needs the
 * download directory carrying a Low label, which widens who else on the
 * machine can write there -- and PR 17 parked it again. Two parkings is what
 * this repository calls a PR, and a PR needs numbers.
 *
 * Nothing here is shipped. It applies one candidate mechanism to a child and
 * gets out of the way, so the suite can put a real curl behind each one and
 * record what survives and what it costs.
 *
 * Three things the shipped code cannot answer from where it sits.
 *
 * 1. The launcher cannot lower itself. nt_fetch_confine_win runs in the
 *    netinstall process, because a job object and an adjusted token are
 *    inherited rather than applied per process -- but a process may never
 *    raise its own integrity back, and everything after the fetch (the digest,
 *    the app directory, the hard link) is work at the launcher's own level. So
 *    the mechanism has to reach the child alone, which on this platform means
 *    a derived token and CreateProcessAsUser.
 *
 * 2. CreateProcessAsUser is documented to want SeIncreaseQuotaPrivilege, and
 *    nt_strip_privileges removes every privilege but SeChangeNotify before the
 *    spawn. `strip` is therefore not a variant here, it is the control that
 *    says whether the answer generalises: a runner is an administrator and a
 *    user is not, so a spawn that works only with the privileges intact has
 *    measured the runner rather than the design.
 *
 * 3. Low integrity is not the only shape. A write-restricted token confines
 *    writes to objects whose DACL names the RESTRICTED sid (S-1-5-33), which
 *    no ordinary process carries -- so granting it is a narrower widening than
 *    a Low label, which every low-integrity process on the machine already
 *    satisfies. Both are applied here so the widening can be compared and not
 *    argued.
 *
 *   lowfetch-probe report
 *   lowfetch-probe sddl <path>
 *   lowfetch-probe label <path>        Low label, inheritable (a directory)
 *   lowfetch-probe labelfile <path>    Low label, this object only
 *   lowfetch-probe grantwr <path>      DACL ace for S-1-5-33, this object only
 *   lowfetch-probe unlabel <path>      take the mandatory label back off
 *   lowfetch-probe write <path>        create-and-write, report rc and gle
 *   lowfetch-probe hardlink <from> <to>
 *   lowfetch-probe spawn <flags> <exe> [args...]
 *
 * flags is a comma list of: plain, low, wrestricted, strip, job, opendesk.
 */

#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The one the run phase applies, spelled the same way sandbox_win.c spells it. */
#define NT_SDDL_LOW_INHERIT "S:(ML;OICI;NW;;;LW)"
#define NT_SDDL_LOW_OBJECT  "S:(ML;;NW;;;LW)"

/* WRITE RESTRICTED. Every process on the machine carries a Low label's worth of
 * authority; nothing carries this one unless it asked to be restricted. */
#define NT_SID_WRITE_RESTRICTED "S-1-5-33"

static int nt_report_label(const char *path, const char *tag)
{
    PSECURITY_DESCRIPTOR sd = NULL;
    LPSTR text = NULL;

    if (GetNamedSecurityInfoA((LPSTR)path, SE_FILE_OBJECT,
                              DACL_SECURITY_INFORMATION |
                              LABEL_SECURITY_INFORMATION,
                              NULL, NULL, NULL, NULL, &sd) != ERROR_SUCCESS) {
        printf("%s=<unreadable> gle=%lu\n", tag, (unsigned long)GetLastError());
        return 1;
    }
    if (ConvertSecurityDescriptorToStringSecurityDescriptorA(
            sd, SDDL_REVISION_1,
            DACL_SECURITY_INFORMATION | LABEL_SECURITY_INFORMATION,
            &text, NULL)) {
        printf("%s=%s\n", tag, text);
        LocalFree(text);
    } else {
        printf("%s=<unprintable> gle=%lu\n", tag, (unsigned long)GetLastError());
    }
    LocalFree(sd);
    return 0;
}

/* Applies one SDDL fragment's SACL to a path. Both label forms come through here. */
static int nt_apply_label(const char *path, const char *sddl)
{
    PSECURITY_DESCRIPTOR sd = NULL;
    PACL sacl = NULL;
    BOOL present = FALSE;
    BOOL defaulted = FALSE;
    DWORD rc;

    if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(
            sddl, SDDL_REVISION_1, &sd, NULL)) {
        printf("LABEL=FAIL stage=parse gle=%lu\n", (unsigned long)GetLastError());
        return 1;
    }
    if (!GetSecurityDescriptorSacl(sd, &present, &sacl, &defaulted) || !present) {
        printf("LABEL=FAIL stage=sacl gle=%lu\n", (unsigned long)GetLastError());
        LocalFree(sd);
        return 1;
    }
    rc = SetNamedSecurityInfoA((LPSTR)path, SE_FILE_OBJECT,
                               LABEL_SECURITY_INFORMATION, NULL, NULL, NULL, sacl);
    LocalFree(sd);
    if (rc != ERROR_SUCCESS) {
        printf("LABEL=FAIL stage=set rc=%lu\n", (unsigned long)rc);
        return 1;
    }
    printf("LABEL=OK\n");
    return 0;
}

/*
 * The other half of the file-only grant, and the half that closes the window it
 * opens. An empty but valid sacl removes the mandatory label, and the object
 * falls back to the default -- so the launcher can hand one file to a low
 * integrity child, take it back the moment the child exits, and hash a file
 * nothing at that level can still reach.
 */
static int nt_unlabel(const char *path)
{
    ACL empty;
    DWORD rc;

    if (!InitializeAcl(&empty, sizeof(empty), ACL_REVISION)) {
        printf("UNLABEL=FAIL stage=init gle=%lu\n", (unsigned long)GetLastError());
        return 1;
    }
    rc = SetNamedSecurityInfoA((LPSTR)path, SE_FILE_OBJECT,
                               LABEL_SECURITY_INFORMATION, NULL, NULL, NULL, &empty);
    if (rc != ERROR_SUCCESS) {
        printf("UNLABEL=FAIL stage=set rc=%lu\n", (unsigned long)rc);
        return 1;
    }
    printf("UNLABEL=OK\n");
    return 0;
}

/*
 * The other candidate's half: an ace that means nothing to any process that is
 * not write-restricted, which is the whole reason to prefer it to a label.
 */
static int nt_grant_restricted(const char *path)
{
    PSECURITY_DESCRIPTOR sd = NULL;
    PACL dacl = NULL;
    PACL merged = NULL;
    EXPLICIT_ACCESS_A ea;
    PSID sid = NULL;
    DWORD rc;

    if (!ConvertStringSidToSidA(NT_SID_WRITE_RESTRICTED, &sid)) {
        printf("GRANTWR=FAIL stage=sid gle=%lu\n", (unsigned long)GetLastError());
        return 1;
    }
    if (GetNamedSecurityInfoA((LPSTR)path, SE_FILE_OBJECT,
                              DACL_SECURITY_INFORMATION,
                              NULL, NULL, &dacl, NULL, &sd) != ERROR_SUCCESS) {
        printf("GRANTWR=FAIL stage=get gle=%lu\n", (unsigned long)GetLastError());
        LocalFree(sid);
        return 1;
    }
    ZeroMemory(&ea, sizeof(ea));
    ea.grfAccessPermissions = FILE_GENERIC_WRITE | FILE_GENERIC_READ | DELETE;
    ea.grfAccessMode = GRANT_ACCESS;
    ea.grfInheritance = NO_INHERITANCE;
    ea.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    ea.Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
    ea.Trustee.ptstrName = (LPSTR)sid;
    rc = SetEntriesInAclA(1, &ea, dacl, &merged);
    if (rc != ERROR_SUCCESS) {
        printf("GRANTWR=FAIL stage=merge rc=%lu\n", (unsigned long)rc);
        LocalFree(sd);
        LocalFree(sid);
        return 1;
    }
    rc = SetNamedSecurityInfoA((LPSTR)path, SE_FILE_OBJECT,
                               DACL_SECURITY_INFORMATION, NULL, NULL, merged, NULL);
    LocalFree(merged);
    LocalFree(sd);
    LocalFree(sid);
    if (rc != ERROR_SUCCESS) {
        printf("GRANTWR=FAIL stage=set rc=%lu\n", (unsigned long)rc);
        return 1;
    }
    printf("GRANTWR=OK\n");
    return 0;
}

/*
 * The three states this has to tell apart are the same three privs.sh needs --
 * enabled, disabled and absent -- and for the same reason: a removed privilege
 * does not appear in the list at all.
 */
static void nt_report_token(void)
{
    TOKEN_MANDATORY_LABEL *tml = NULL;
    TOKEN_PRIVILEGES *tp = NULL;
    HANDLE token = NULL;
    DWORD len = 0;
    DWORD rid = 0;
    DWORD i;

    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        printf("TOKEN=<unreadable> gle=%lu\n", (unsigned long)GetLastError());
        return;
    }
    GetTokenInformation(token, TokenIntegrityLevel, NULL, 0, &len);
    if (len && (tml = (TOKEN_MANDATORY_LABEL *)malloc(len)) != NULL &&
        GetTokenInformation(token, TokenIntegrityLevel, tml, len, &len)) {
        PUCHAR count = GetSidSubAuthorityCount(tml->Label.Sid);

        rid = *GetSidSubAuthority(tml->Label.Sid, (DWORD)(*count - 1));
    }
    free(tml);
    printf("IL=0x%lx %s restricted=%s\n", (unsigned long)rid,
           rid >= 0x3000 ? "high" : rid >= 0x2000 ? "medium" :
           rid >= 0x1000 ? "low" : "untrusted",
           IsTokenRestricted(token) ? "yes" : "no");

    len = 0;
    GetTokenInformation(token, TokenPrivileges, NULL, 0, &len);
    if (len && (tp = (TOKEN_PRIVILEGES *)malloc(len)) != NULL &&
        GetTokenInformation(token, TokenPrivileges, tp, len, &len)) {
        printf("PRIVS=");
        for (i = 0; i < tp->PrivilegeCount; i++) {
            char name[64];
            DWORD n = sizeof(name);

            if (!LookupPrivilegeNameA(NULL, &tp->Privileges[i].Luid, name, &n)) {
                continue;
            }
            /* "SeIncreaseQuotaPrivilege" is "IncreaseQuota=E" here. */
            if (n > 2 && strncmp(name, "Se", 2) == 0) {
                char *tail = strstr(name + 2, "Privilege");

                if (tail) {
                    *tail = '\0';
                }
                printf("%s=%c ", name + 2,
                       (tp->Privileges[i].Attributes & SE_PRIVILEGE_ENABLED) ? 'E' : 'D');
            }
        }
        printf("\n");
    } else {
        printf("PRIVS=<unreadable>\n");
    }
    free(tp);
    CloseHandle(token);
}

/* nt_strip_privileges, exactly, so the ordering question is asked of the real shape. */
static int nt_strip(void)
{
    TOKEN_PRIVILEGES *tp = NULL;
    HANDLE token = NULL;
    DWORD len = 0;
    LUID keep;
    DWORD i;
    int ok = 0;

    if (!LookupPrivilegeValueA(NULL, "SeChangeNotifyPrivilege", &keep) ||
        !OpenProcessToken(GetCurrentProcess(),
                          TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) {
        return 0;
    }
    GetTokenInformation(token, TokenPrivileges, NULL, 0, &len);
    if (len && (tp = (TOKEN_PRIVILEGES *)malloc(len)) != NULL &&
        GetTokenInformation(token, TokenPrivileges, tp, len, &len)) {
        for (i = 0; i < tp->PrivilegeCount; i++) {
            int same = tp->Privileges[i].Luid.LowPart == keep.LowPart &&
                       tp->Privileges[i].Luid.HighPart == keep.HighPart;

            tp->Privileges[i].Attributes = same ? SE_PRIVILEGE_ENABLED
                                                : SE_PRIVILEGE_REMOVED;
        }
        ok = AdjustTokenPrivileges(token, FALSE, tp, len, NULL, NULL) &&
             GetLastError() != ERROR_NOT_ALL_ASSIGNED;
    }
    free(tp);
    CloseHandle(token);
    return ok;
}

/* A job object with the fetch phase's own limits, so the spawn is asked the
 * question inside the boundary it would really be inside. */
static int nt_join_job(void)
{
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    HANDLE job = CreateJobObjectA(NULL, NULL);

    if (!job) {
        return 0;
    }
    ZeroMemory(&limits, sizeof(limits));
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION |
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.BasicLimitInformation.ActiveProcessLimit = 8;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits)) ||
        !AssignProcessToJobObject(job, GetCurrentProcess())) {
        CloseHandle(job);
        return 0;
    }
    return 1;
}

static HANDLE nt_derive_token(int low, int wrestricted, const char **stage)
{
    HANDLE self = NULL;
    HANDLE dup = NULL;

    *stage = "open";
    /*
     * TOKEN_ADJUST_DEFAULT is here for the wrestricted+low pair.
     * CreateRestrictedToken hands back a token with the access rights the
     * source was opened with, so a source opened without it produces a
     * restricted token that cannot then be lowered -- which reads as the
     * mechanism refusing rather than as the handle being wrong.
     */
    if (!OpenProcessToken(GetCurrentProcess(),
                          TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY |
                          TOKEN_ADJUST_DEFAULT, &self)) {
        return NULL;
    }
    if (wrestricted) {
        SID_AND_ATTRIBUTES restrict_to;
        PSID sid = NULL;

        /*
         * S-1-5-33 spelled once, here and in the ace, because the two have to
         * be the same sid or the mechanism looks like it refused everything.
         * It is WRITE RESTRICTED and not S-1-5-12 RESTRICTED, which is the
         * read-and-write form and would need every trust store named in an ace.
         */
        *stage = "restrictedsid";
        if (!ConvertStringSidToSidA(NT_SID_WRITE_RESTRICTED, &sid)) {
            CloseHandle(self);
            return NULL;
        }
        restrict_to.Sid = sid;
        restrict_to.Attributes = 0;
        *stage = "restrict";
        /*
         * WRITE_RESTRICTED, not DISABLE_MAX_PRIVILEGE: the restricting list is
         * consulted for write access alone, which is the whole point -- a
         * downloader still has to read a trust store, a resolver config and a
         * proxy setting out of places nobody is going to name in an ace.
         */
        if (!CreateRestrictedToken(self, WRITE_RESTRICTED, 0, NULL, 0, NULL,
                                   1, &restrict_to, &dup)) {
            LocalFree(sid);
            CloseHandle(self);
            return NULL;
        }
        LocalFree(sid);
        CloseHandle(self);
    } else {
        *stage = "duplicate";
        if (!DuplicateTokenEx(self, TOKEN_ALL_ACCESS, NULL,
                              SecurityImpersonation, TokenPrimary, &dup)) {
            CloseHandle(self);
            return NULL;
        }
        CloseHandle(self);
    }
    if (low) {
        TOKEN_MANDATORY_LABEL tml;
        PSID sid = NULL;

        *stage = "lowsid";
        if (!ConvertStringSidToSidA("S-1-16-4096", &sid)) {
            CloseHandle(dup);
            return NULL;
        }
        ZeroMemory(&tml, sizeof(tml));
        tml.Label.Attributes = SE_GROUP_INTEGRITY;
        tml.Label.Sid = sid;
        *stage = "setil";
        if (!SetTokenInformation(dup, TokenIntegrityLevel, &tml,
                                 (DWORD)(sizeof(tml) + GetLengthSid(sid)))) {
            LocalFree(sid);
            CloseHandle(dup);
            return NULL;
        }
        LocalFree(sid);
    }
    *stage = "ok";
    return dup;
}

static int nt_has(const char *flags, const char *want)
{
    const char *p = flags;
    size_t n = strlen(want);

    while (*p) {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);

        if (len == n && strncmp(p, want, n) == 0) {
            return 1;
        }
        if (!end) {
            break;
        }
        p = end + 1;
    }
    return 0;
}

/*
 * A write-restricted child dies at process initialisation, not at a file, and
 * the documented reason is the objects every process touches before main:
 * the window station, the desktop and the session's named object directory.
 * Two of the three are reachable from here. Granting them is what makes
 * "declined" a measurement rather than an assumption -- if the child still will
 * not start with these open, the remaining one is the object namespace, which
 * is ntdll territory and a great deal more machinery than the mechanism it
 * would be buying.
 */
static int nt_open_desktop_restricted(void)
{
    PSID sid = NULL;
    int ok = 1;
    int i;
    HANDLE objs[2];

    if (!ConvertStringSidToSidA(NT_SID_WRITE_RESTRICTED, &sid)) {
        return 0;
    }
    objs[0] = (HANDLE)GetProcessWindowStation();
    objs[1] = (HANDLE)GetThreadDesktop(GetCurrentThreadId());
    for (i = 0; i < 2; i++) {
        PSECURITY_DESCRIPTOR sd = NULL;
        PACL dacl = NULL;
        PACL merged = NULL;
        EXPLICIT_ACCESS_A ea;

        if (!objs[i] ||
            GetSecurityInfo(objs[i], SE_WINDOW_OBJECT, DACL_SECURITY_INFORMATION,
                            NULL, NULL, &dacl, NULL, &sd) != ERROR_SUCCESS) {
            ok = 0;
            continue;
        }
        ZeroMemory(&ea, sizeof(ea));
        ea.grfAccessPermissions = GENERIC_ALL;
        ea.grfAccessMode = GRANT_ACCESS;
        ea.grfInheritance = NO_INHERITANCE;
        ea.Trustee.TrusteeForm = TRUSTEE_IS_SID;
        ea.Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
        ea.Trustee.ptstrName = (LPSTR)sid;
        if (SetEntriesInAclA(1, &ea, dacl, &merged) != ERROR_SUCCESS ||
            SetSecurityInfo(objs[i], SE_WINDOW_OBJECT, DACL_SECURITY_INFORMATION,
                            NULL, NULL, merged, NULL) != ERROR_SUCCESS) {
            ok = 0;
        }
        LocalFree(merged);
        LocalFree(sd);
    }
    LocalFree(sid);
    return ok;
}

/*
 * The last resort of the three above: put a Low label on this process's window
 * station and desktop so a lowered child can open them. Not something the
 * shipped code would ever do -- it widens two objects the whole session shares
 * -- but a probe that cannot get its child started measures nothing, and
 * whether this was needed is itself one of the readings.
 */
static int nt_open_desktop_low(void)
{
    PSECURITY_DESCRIPTOR sd = NULL;
    PACL sacl = NULL;
    BOOL present = FALSE;
    BOOL defaulted = FALSE;
    HWINSTA winsta = GetProcessWindowStation();
    HDESK desk = GetThreadDesktop(GetCurrentThreadId());
    int ok = 0;

    if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(
            NT_SDDL_LOW_INHERIT, SDDL_REVISION_1, &sd, NULL)) {
        return 0;
    }
    if (GetSecurityDescriptorSacl(sd, &present, &sacl, &defaulted) && present) {
        ok = (winsta && SetSecurityInfo(winsta, SE_WINDOW_OBJECT,
                                        LABEL_SECURITY_INFORMATION,
                                        NULL, NULL, NULL, sacl) == ERROR_SUCCESS) &&
             (desk && SetSecurityInfo(desk, SE_WINDOW_OBJECT,
                                      LABEL_SECURITY_INFORMATION,
                                      NULL, NULL, NULL, sacl) == ERROR_SUCCESS);
    }
    LocalFree(sd);
    return ok;
}

/* Quoting is not the question here, so the command line is joined the simple
 * way and the suite is careful not to hand it a path with a space in it. */
static int nt_spawn(const char *flags, int argc, char **argv)
{
    PROCESS_INFORMATION pi;
    STARTUPINFOA si;
    HANDLE token = NULL;
    const char *stage = "none";
    char cmdline[4096];
    size_t used = 0;
    DWORD code = 126;
    BOOL ok;
    int i;

    for (i = 0; i < argc; i++) {
        int n = snprintf(cmdline + used, sizeof(cmdline) - used, "%s\"%s\"",
                         i ? " " : "", argv[i]);

        if (n < 0 || (size_t)n >= sizeof(cmdline) - used) {
            printf("SPAWN=FAIL stage=cmdline\n");
            return 1;
        }
        used += (size_t)n;
    }

    if (nt_has(flags, "job")) {
        printf("JOB=%s\n", nt_join_job() ? "OK" : "FAIL");
    }
    /*
     * Before the token, because the objects a child touches before main are
     * opened on its way in and there is no second chance at them.
     */
    if (nt_has(flags, "opendesk")) {
        printf("OPENDESK=%s\n", nt_open_desktop_restricted() ? "OK" : "FAIL");
    }
    /*
     * Before the spawn, because that is where nt_fetch_confine_win does it and
     * the order is the thing under test: CreateProcessAsUser is documented to
     * want SeIncreaseQuotaPrivilege, and this takes it away.
     */
    if (nt_has(flags, "strip")) {
        printf("STRIP=%s\n", nt_strip() ? "OK" : "FAIL");
    }

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);

    if (nt_has(flags, "plain")) {
        ok = CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL,
                            &si, &pi);
    } else {
        token = nt_derive_token(nt_has(flags, "low"),
                                nt_has(flags, "wrestricted"), &stage);
        if (!token) {
            printf("SPAWN=FAIL stage=%s gle=%lu\n", stage,
                   (unsigned long)GetLastError());
            return 1;
        }
        /*
         * Three attempts, because a lowered token fails at the desktop before
         * it ever reaches a file, and the three causes are told apart nowhere
         * else. A derived token opens the window station and the desktop on its
         * own account; the interactive desktop does not admit low integrity
         * unless something labels it, which is what a protected mode browser
         * arranges for itself at install time.
         *
         * A failure here is not an answer about the filesystem, and one round
         * of CI spent discovering that would be a round wasted -- so the
         * fallbacks run in the same process and the reading says which one
         * carried it.
         */
        ok = CreateProcessAsUserA(token, NULL, cmdline, NULL, NULL, TRUE, 0,
                                  NULL, NULL, &si, &pi);
        if (ok) {
            printf("DESKTOP=inherited\n");
        } else {
            DWORD first = GetLastError();

            si.lpDesktop = (LPSTR)"WinSta0\\Default";
            ok = CreateProcessAsUserA(token, NULL, cmdline, NULL, NULL, TRUE, 0,
                                      NULL, NULL, &si, &pi);
            if (ok) {
                printf("DESKTOP=winsta0 first_gle=%lu\n", (unsigned long)first);
            } else {
                printf("DESKTOP=labelled first_gle=%lu grant=%s\n",
                       (unsigned long)first, nt_open_desktop_low() ? "OK" : "FAIL");
                ok = CreateProcessAsUserA(token, NULL, cmdline, NULL, NULL, TRUE,
                                          0, NULL, NULL, &si, &pi);
            }
        }
    }
    if (!ok) {
        printf("SPAWN=FAIL stage=create gle=%lu\n", (unsigned long)GetLastError());
        if (token) {
            CloseHandle(token);
        }
        return 1;
    }
    printf("SPAWN=OK\n");
    fflush(stdout);
    WaitForSingleObject(pi.hProcess, 120000);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (token) {
        CloseHandle(token);
    }
    printf("CHILDRC=%lu\n", (unsigned long)code);
    return code == 0 ? 0 : 1;
}

/*
 * The payload for both halves: the confined child proving it cannot write out,
 * and an unrelated low integrity process proving what a Low label handed it.
 * CreateFile rather than fopen, because the gle is the answer.
 */
static int nt_write(const char *path)
{
    HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD wrote = 0;

    if (h == INVALID_HANDLE_VALUE) {
        printf("WRITE=REFUSED path=%s gle=%lu\n", path,
               (unsigned long)GetLastError());
        return 1;
    }
    WriteFile(h, "LOWFETCH\n", 9, &wrote, NULL);
    CloseHandle(h);
    printf("WRITE=OK path=%s bytes=%lu\n", path, (unsigned long)wrote);
    return 0;
}

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "report";

    setvbuf(stdout, NULL, _IONBF, 0);

    if (strcmp(cmd, "report") == 0) {
        nt_report_token();
        return 0;
    }
    if (strcmp(cmd, "sddl") == 0 && argc > 2) {
        return nt_report_label(argv[2], "SDDL");
    }
    if (strcmp(cmd, "label") == 0 && argc > 2) {
        return nt_apply_label(argv[2], NT_SDDL_LOW_INHERIT);
    }
    if (strcmp(cmd, "labelfile") == 0 && argc > 2) {
        return nt_apply_label(argv[2], NT_SDDL_LOW_OBJECT);
    }
    if (strcmp(cmd, "grantwr") == 0 && argc > 2) {
        return nt_grant_restricted(argv[2]);
    }
    if (strcmp(cmd, "unlabel") == 0 && argc > 2) {
        return nt_unlabel(argv[2]);
    }
    if (strcmp(cmd, "write") == 0 && argc > 2) {
        return nt_write(argv[2]);
    }
    /*
     * The hazard a Low label on the blobs directory carries and a label on one
     * file does not. netinstall commits a verified payload with CreateHardLink,
     * and a hard link is a second name for one file object -- so the label the
     * blob inherited from its directory is the label the script the app runs
     * has too, and the digest was checked before the link, not after.
     */
    if (strcmp(cmd, "hardlink") == 0 && argc > 3) {
        if (!CreateHardLinkA(argv[3], argv[2], NULL)) {
            printf("HARDLINK=FAIL gle=%lu\n", (unsigned long)GetLastError());
            return 1;
        }
        printf("HARDLINK=OK\n");
        nt_report_label(argv[2], "SDDL_BLOB");
        nt_report_label(argv[3], "SDDL_LINK");
        return 0;
    }
    if (strcmp(cmd, "spawn") == 0 && argc > 3) {
        return nt_spawn(argv[2], argc - 3, argv + 3);
    }
    fprintf(stderr, "usage: lowfetch-probe report|sddl|label|labelfile|grantwr|"
                    "unlabel|write|hardlink|spawn <flags> <exe> [args...]\n");
    return 2;
}
