/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifdef _WIN32

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <aclapi.h>
#include <sddl.h>

#include "netinstall.h"
#include "sandbox.h"

/*
 * The rest of the writable set, spelled where a user can read it.
 *
 * Low integrity is a label on a token, not a directory, and windows keeps two
 * places writable at that level on purpose so that low-integrity processes have
 * somewhere to put things: the LocalLow folder and the AppDataLow key. Neither
 * is the app dir and neither can be taken away from here -- they are what the
 * mechanism is, not something this program grants.
 *
 * Measured on a windows-latest runner: locallow=CT- and reglow=K-- writable,
 * against home, the user temp dir, C:\Windows\Temp and HKCU\Software all
 * refused.
 */
/* No percent signs: this is concatenated into a printf format string. */
#define NT_ALSO_WRITABLE ", the user's AppData\\LocalLow folder and " \
                         "HKCU\\Software\\AppDataLow"

/*
 * A job object is a resource boundary, not a filesystem one, so low integrity
 * is what actually confines a write here. This paragraph used to say it did not
 * work -- that WebView2 puts up a window which never draws in a low-IL host,
 * which is what Microsoft documents -- and it was wrong. On run 33674586566 the
 * suite recorded a window 23 ms after launch and then the app's whole sequence
 * through it: `neutrino` at 106 ms, a resize at 16474, the desktop palette read
 * at 22506 and the tests done at 24538. That is a view that got a surface, laid
 * a document out on it and took window calls from the page, all at low
 * integrity. jsc.exe compiles there too, once %TEMP% is redirected, which
 * netinstall.c does.
 *
 * Reads are the ceiling, not writes. Low integrity is a no-write-up rule and
 * leaves reads alone, and AppContainer -- the only mechanism that would close
 * them -- does not work either, measured rather than inferred: launched inside
 * a real one, with its capabilities granted and the app dir handed to its SID,
 * no window appears at all. Every unprivileged mechanism windows offers has now
 * been tried against a real webview, so reads staying unconfined here is a
 * ceiling rather than an omission -- and, since no platform confines reads any
 * more, it is the same ceiling everywhere rather than this one's alone.
 */
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

/*
 * Both phases lower a child rather than themselves, and until the build slot
 * the run phase did the opposite.
 *
 * nt_confine runs in the launcher, and a process may lower its own integrity
 * but never raise it back, so a phase that lowers itself gives up everything it
 * had left to do at its own level. For the fetch that was always fatal:
 * the digest, the pin, the rename, the hard link and the app directory all
 * happen after nt_fetch returns, so lowering here would trade the download's
 * confinement for the install's. The run phase had nothing left to do --
 * nt_exec was the last line -- so it lowered itself and the child inherited.
 *
 * It has something left to do now. On windows nt_exec does not exec: it spawns
 * cmd.exe and waits for it, and the build slot's Low label has to come back off
 * when that returns, before anything trusts what the payload left there. A
 * launcher that has lowered itself cannot take a label off anything. So the run
 * phase is a token handed to nt_win_spawn_as as well, which makes the two
 * phases one shape rather than two -- and it leaves the launcher at medium
 * while the app is at low, which a low child cannot open for writing.
 *
 * What follows is the fetch's, and it is why the grant there is one file.
 *
 * Measured on windows-latest, and each of these was a candidate that lost:
 *
 *   - A Low label on the blobs *directory* is what the obvious version of this
 *     does, and it is inadmissible twice over. It lets every low integrity
 *     process on the machine write there -- measured, an unrelated one did --
 *     and worse, nt_link_or_copy commits the verified payload with
 *     CreateHardLink. A hard link is a second name for one file object and the
 *     descriptor belongs to the file, so the label reached
 *     <home>/apps/<app>/<name>.cmd and an intruder rewrote the script nt_exec
 *     runs, after the digest had been checked. SCRIPT_WRITABLE.
 *
 *   - A write-restricted token (CreateRestrictedToken, WRITE_RESTRICTED) is the
 *     narrower mechanism on paper: it admits only objects whose DACL names
 *     S-1-5-33, which nothing carries unless it asked to be restricted, where a
 *     Low label is authority every low integrity process already holds. It does
 *     not survive contact with a downloader. A trivial child runs under it
 *     (restricted=yes, exit 0) once the window station and desktop are granted
 *     that sid; curl returns STATUS_DLL_INIT_FAILED under the same token with
 *     the same grants, every time. What is left to open is the session's named
 *     object directory, which is ntdll and a great deal more machinery than low
 *     integrity already delivers here.
 *
 * So: lower the child, label the one file it has to write, and take the label
 * off before anything hashes it. The last part is not tidiness. While the label
 * is on, any low integrity process on the machine can rewrite that file, and
 * netinstall does not re-read it between nt_sha256_file and the rename -- so a
 * label left on is a digest checked against content that can still change.
 */
/*
 * Built by nt_confine and spent by nt_fetch, because the fetch phase's answer
 * has one caller and one consumer and threading a handle through nt_confine's
 * signature would put a windows type in a header three other platforms include.
 */
static HANDLE nt_fetch_low_token = NULL;

/*
 * The run phase's, on the same terms and for the reason at the top of this
 * file: it is spent by nt_exec rather than by nt_fetch, and it is what keeps
 * this process at medium across the wait so nt_build_revoke can run.
 */
static HANDLE nt_run_low_token = NULL;

/*
 * A duplicate of this process's own token, lowered. Deliberately after
 * nt_strip_privileges: CreateProcessAsUser is documented to want
 * SeIncreaseQuotaPrivilege and the stripping removes it, so the order this runs
 * in is the order that had to be measured. It succeeds with every privilege but
 * SeChangeNotify gone -- which is what says the mechanism is the user's and not
 * the administrator a CI runner happens to be.
 */
static HANDLE nt_low_token(void)
{
    TOKEN_MANDATORY_LABEL tml;
    HANDLE self = NULL;
    HANDLE dup = NULL;
    PSID low = NULL;

    if (!OpenProcessToken(GetCurrentProcess(),
                          TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY |
                          TOKEN_ADJUST_DEFAULT, &self)) {
        return NULL;
    }
    if (!DuplicateTokenEx(self, TOKEN_ALL_ACCESS, NULL, SecurityImpersonation,
                          TokenPrimary, &dup)) {
        CloseHandle(self);
        return NULL;
    }
    CloseHandle(self);
    if (!ConvertStringSidToSidA("S-1-16-4096", &low)) {
        CloseHandle(dup);
        return NULL;
    }
    ZeroMemory(&tml, sizeof(tml));
    tml.Label.Attributes = SE_GROUP_INTEGRITY;
    tml.Label.Sid = low;
    if (!SetTokenInformation(dup, TokenIntegrityLevel, &tml,
                             (DWORD)(sizeof(tml) + GetLengthSid(low)))) {
        LocalFree(low);
        CloseHandle(dup);
        return NULL;
    }
    LocalFree(low);
    return dup;
}

/*
 * Takes a label back off one object, whichever of the two above put it there.
 *
 * An empty but valid sacl removes the label, and the object falls back to the
 * default -- this process's own level. Measured: while the label is on, an
 * unrelated low integrity process writes the file; the moment it is off, the
 * same process is refused, and the hard link the commit makes carries no label
 * either.
 */
static int nt_label_clear(const char *path)
{
    ACL empty;

    if (!InitializeAcl(&empty, sizeof(empty), ACL_REVISION)) {
        return 0;
    }
    return SetNamedSecurityInfoA((LPSTR)path, SE_FILE_OBJECT,
                                 LABEL_SECURITY_INFORMATION,
                                 NULL, NULL, NULL, &empty) == ERROR_SUCCESS;
}

/* One object, no inheritance: this is a file, and nothing is created under it. */
static int nt_label_file_low(const char *path)
{
    PSECURITY_DESCRIPTOR sd = NULL;
    PACL sacl = NULL;
    BOOL present = FALSE;
    BOOL defaulted = FALSE;
    int ok = 0;

    if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(
            "S:(ML;;NW;;;LW)", SDDL_REVISION_1, &sd, NULL)) {
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

void *nt_fetch_token(void)
{
    return (void *)nt_fetch_low_token;
}

/*
 * What the run phase's sentence has to say beyond the app dir, set by the
 * caller because nt_confine cannot work it out: whether this launch owes a
 * build is a question about a record on disk and a digest, and answering it
 * here would put both in a file three other platforms include.
 *
 * A sealed launch leaves the sentence exactly as it was before any of this, to
 * the byte, which is what keeps writable.sh's reading of it a reading of the
 * same thing.
 */
static const char *nt_slot_shown = NULL;
static int nt_slot_granting = 0;

void nt_build_slot(const char *slot, int owed)
{
    nt_slot_shown = slot;
    nt_slot_granting = owed;
}

/* The writable set the sentence names, which is one directory or two. */
static void nt_slot_where(char *buf, size_t len, const char *appdir)
{
    if (nt_slot_granting && nt_slot_shown) {
        snprintf(buf, len, "%s and %s for this build", appdir, nt_slot_shown);
        return;
    }
    snprintf(buf, len, "%s", appdir);
}

void *nt_run_token(void)
{
    return (void *)nt_run_low_token;
}

/*
 * The build slot's grant, and the two ways it is not the fetch's.
 *
 * It is a directory. The fetch grants one file -- narrower, and possible there
 * because netinstall knows the name and can create it first. Here it cannot:
 * the launcher compiles to <name>.new<RANDOM>.exe and MOVEs, because windows
 * refuses to overwrite a running image but allows renaming one, so the payload
 * needs create and delete in the directory itself. What that costs is written
 * down rather than reasoned away: for the length of a build run, any low
 * integrity process on the machine can create, delete and rename in here.
 *
 * And a failure is not fatal. Everywhere else in this file a confinement that
 * did not apply is a refusal, because what was promised did not happen. This is
 * the other direction: the slot is a *relaxation*, so a launch that does not
 * get one is more confined than one that does, not less. The caller carries on
 * and the launcher falls back to compiling every launch, which is what it did
 * before any of this existed.
 */
int nt_build_grant(const char *slot)
{
    if (!nt_run_low_token) {
        /* Nothing was lowered, so there is nothing to widen for. */
        return 1;
    }
    return nt_label_low(slot);
}

/*
 * And back off again, from the container *and* from everything in it.
 *
 * nt_label_low writes OICI -- object and container inherit -- so every file the
 * payload created in there carries a Low label of its own, and clearing the
 * directory's does not touch them. The fetch's revoke is one call because the
 * fetch grants one file; this one is a walk, and a missed entry is a file that
 * stays writable by every low integrity process on the machine for as long as
 * it exists. So it answers, on sandbox.h's rule, and the caller wipes the slot
 * rather than sealing a directory it could not close.
 *
 * Flat, matching the seal: a subdirectory here is refused by nt_slot_read
 * rather than descended into, so a tree cannot make this walk unbounded.
 */
int nt_build_revoke(const char *slot)
{
    WIN32_FIND_DATAA fd;
    char pattern[NT_PATH_MAX];
    char full[NT_PATH_MAX];
    HANDLE h;
    int ok = 1;

    if (!nt_run_low_token) {
        return 1;
    }
    if (GetFileAttributesA(slot) == INVALID_FILE_ATTRIBUTES) {
        /* Never created, or already gone: the same absence either way. */
        return 1;
    }
    if (!nt_label_clear(slot)) {
        return 0;
    }
    snprintf(pattern, sizeof(pattern), "%s\\*", slot);
    h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) {
        return ok;
    }
    do {
        if (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0) {
            continue;
        }
        snprintf(full, sizeof(full), "%s\\%s", slot, fd.cFileName);
        if (!nt_label_clear(full)) {
            ok = 0;
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    return ok;
}

int nt_fetch_grant(const char *dest)
{
    HANDLE h;

    if (!nt_fetch_low_token) {
        /* Nothing was lowered, so there is nothing to widen for. */
        return 1;
    }
    /*
     * Created here rather than by the downloader. A low integrity child cannot
     * add a file to a directory it has no write on, and the directory is
     * exactly what must not be granted -- so the file has to exist before the
     * child does. curl's -o writes into it; measured on four grants, this is
     * the only one a lowered curl completes a transfer through.
     */
    h = CreateFileA(dest, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        return 0;
    }
    CloseHandle(h);
    if (!nt_label_file_low(dest)) {
        remove(dest);
        return 0;
    }
    return 1;
}

int nt_fetch_revoke(const char *dest)
{
    if (!nt_fetch_low_token) {
        return 1;
    }
    /*
     * Nothing there is nothing to take back. The grant removes the file when it
     * cannot label it, and a fetch that never wrote leaves the same absence --
     * neither is a failure of this, and reporting one would send whoever reads
     * it looking for the wrong thing.
     */
    if (GetFileAttributesA(dest) == INVALID_FILE_ATTRIBUTES) {
        return 1;
    }
    return nt_label_clear(dest);
}

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
 *
 * commit = 0 does everything up to the one call that cannot be undone and
 * stops. That is what --info runs, so the description it prints is conditional
 * on a token that opened and read rather than on nothing at all -- the shape
 * sandbox_linux.c already uses, where --info builds the ruleset and reports
 * "landlock unavailable" when it cannot.
 */
static int nt_strip_privileges(int commit)
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
        ok = 1;
    }
    if (ok && commit) {
        for (i = 0; i < tp->PrivilegeCount; i++) {
            if (tp->Privileges[i].Luid.LowPart == keep.LowPart &&
                tp->Privileges[i].Luid.HighPart == keep.HighPart) {
                /*
                 * Not 0. AdjustTokenPrivileges reads 0 as "disable", so the
                 * attribute that looks like "leave this one alone" is the one
                 * that turns off the privilege this function exists to keep.
                 * Measured on windows-latest: with 0 the payload's token has
                 * SeChangeNotify present but Disabled, and a read through a
                 * directory it has no traverse right on is refused. With
                 * SE_PRIVILEGE_ENABLED, in this same mixed list, the privilege
                 * comes out Enabled and the read succeeds.
                 */
                tp->Privileges[i].Attributes = SE_PRIVILEGE_ENABLED;
            } else {
                tp->Privileges[i].Attributes = SE_PRIVILEGE_REMOVED;
            }
        }
        ok = AdjustTokenPrivileges(token, FALSE, tp, len, NULL, NULL) ? 1 : 0;
        /*
         * TRUE and ERROR_NOT_ALL_ASSIGNED means it applied some of the list and
         * dropped the rest, and GetLastError is the only place it says so.
         * Measured gle=0 with both the old attribute and the new one, so this
         * has never fired here: it is the difference between a description that
         * happens to be true and one that is checked.
         */
        if (ok && GetLastError() == ERROR_NOT_ALL_ASSIGNED) {
            ok = 0;
        }
    }
    free(tp);
    CloseHandle(token);
    return ok;
}

/*
 * The fetch phase gets the same mechanism the run phase does, and for the same
 * reason a strict build accepts it there: a job object plus a stripped token is
 * what this platform offers an unprivileged process, and the alternative here
 * was nothing at all. The job and the adjusted token are both inherited, so the
 * downloader runs inside them without the launcher having to reach into it.
 *
 * Measured, because two things could have gone wrong and neither is obvious:
 * the downloader still works inside it, and the run phase still gets a job
 * object of its own afterwards -- that second one is a nested job, which
 * windows has only allowed since 8.
 *
 * Low integrity goes on the child rather than here -- see nt_fetch_token above
 * for why the launcher cannot take it itself, and for the two narrower-looking
 * mechanisms that lost. Reads are not confined; see the run phase for why that
 * is a ceiling rather than an omission.
 */
/*
 * The sentence, built once from the same three answers both callers have. Kept
 * out of the two snprintf sites because it has to name what the run phase's
 * NT_ALSO_WRITABLE names -- a low integrity child can write LocalLow and
 * AppDataLow whatever this program grants -- and PR 16 is what happens when a
 * "writes confined to" sentence names less than it means.
 */
static void nt_fetch_desc(char *desc, size_t desclen, const char *privs,
                          int lowered)
{
    if (lowered) {
        snprintf(desc, desclen, "job object%s + low integrity, writes confined "
                                "to the payload file" NT_ALSO_WRITABLE
                                " (reads are not confined)", privs);
        return;
    }
    snprintf(desc, desclen, "job object%s (process limits only; the low "
                            "integrity token was unavailable)", privs);
}

static int nt_fetch_confine_win(int enforce, char *desc, size_t desclen)
{
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    const char *privs;
    HANDLE job;
    int lowered = 1;

    if (!enforce) {
        privs = nt_strip_privileges(0) ? " + privileges stripped" : "";
        /*
         * Built and dropped, so --info reports a token that this machine really
         * produced rather than one this file promises -- the shape nt_confine
         * already uses for the privilege stripping on the line above, and for
         * the landlock ruleset on linux.
         */
        {
            HANDLE probe = nt_low_token();

            lowered = probe != NULL;
            if (probe) {
                CloseHandle(probe);
            }
        }
        nt_fetch_desc(desc, desclen, privs, lowered);
        return lowered ? 0 : -1;
    }
    job = CreateJobObjectA(NULL, NULL);
    if (!job) {
        snprintf(desc, desclen, "none (job object unavailable)");
        return -1;
    }
    /*
     * Eight, where the run phase allows sixty-four: this one holds a launcher
     * and a downloader, and nothing either of them starts has any business
     * here.
     */
    ZeroMemory(&limits, sizeof(limits));
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION |
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.BasicLimitInformation.ActiveProcessLimit = 8;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits)) ||
        !AssignProcessToJobObject(job, GetCurrentProcess())) {
        CloseHandle(job);
        snprintf(desc, desclen, "none (job object rejected)");
        return -1;
    }
    /* Best effort, and --info must not claim it happened when it did not --
     * the same rule the run phase follows two screens down. */
    privs = nt_strip_privileges(1) ? " + privileges stripped" : "";
    /*
     * After the stripping, which is the order that had to be measured:
     * CreateProcessAsUser is documented to want SeIncreaseQuotaPrivilege and the
     * line above has just removed it. It works anyway, on a token with nothing
     * left but SeChangeNotify -- so this does not depend on privileges the user
     * this ships to would not have had in the first place.
     */
    nt_fetch_low_token = nt_low_token();
    lowered = nt_fetch_low_token != NULL;
    nt_fetch_desc(desc, desclen, privs, lowered);
    /*
     * A build whose token could not be made has a job object and nothing that
     * confines a write, and must say so as a failure rather than as a quieter
     * sentence: the caller refuses on it, which is the whole point of the phase
     * having an answer at all.
     */
    return lowered ? 0 : -1;
}

int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
               char *desc, size_t desclen)
{
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    char uishown[256];
    char uinote[288];
    char where[NT_PATH_MAX * 2 + 32];
    DWORD uimask;
    const char *privs;
    HANDLE job;

    (void)home;
    (void)appdir;

    if (phase == NT_PHASE_FETCH) {
        return nt_fetch_confine_win(enforce, desc, desclen);
    }

    uimask = nt_job_ui_mask(uishown, sizeof(uishown));
    if (uimask) {
        snprintf(uinote, sizeof(uinote), " + ui restrictions (%s)", uishown);
    } else {
        uinote[0] = '\0';
    }

    if (!enforce) {
        /*
         * The same phrase the enforcing path builds, from the same call, minus
         * the adjustment. It used to be a constant inside the format string, so
         * --info promised a stripping whatever the token turned out to be.
         */
        privs = nt_strip_privileges(0) ? " + privileges stripped" : "";
        /*
         * Built and dropped, so this reports a token this machine really
         * produced rather than one this file promises -- the shape
         * nt_fetch_confine_win already uses two screens up, and the shape the
         * privilege stripping on the line above has always used. It described a
         * low integrity launch unconditionally while the mechanism was a drop
         * this branch never attempted.
         */
        {
            HANDLE probe = nt_low_token();

            if (!probe) {
                snprintf(desc, desclen, "job object%s%s (process limits only; "
                                        "the low integrity token was "
                                        "unavailable)", uinote, privs);
                return -1;
            }
            CloseHandle(probe);
        }
        nt_slot_where(where, sizeof(where), appdir);
        snprintf(desc, desclen, "job object%s%s + low integrity, writes "
                                "confined to %s" NT_ALSO_WRITABLE
                                " (reads are not confined)"
                               ,
                 uinote, privs, where);
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
    privs = nt_strip_privileges(1) ? " + privileges stripped" : "";

    /*
     * Low integrity blocks writes, not reads: this stops an app trashing the
     * profile, but it can still read ~/.ssh and browser stores. Only an
     * AppContainer would close that, and a webview does not come up inside one.
     *
     * Both steps are fatal. Without the label the app cannot write its own
     * files, and without the drop nothing confines a write at all -- and a
     * process that is only in a job object is one whose --info line would have
     * to say so, which is the same thing as failing. The caller decides what to
     * do with -1; what this must not do is return 0 for either.
     */
    if (!nt_label_low(appdir)) {
        snprintf(desc, desclen, "job object only (could not label %s low)", appdir);
        return -1;
    }
    nt_run_low_token = nt_low_token();
    if (!nt_run_low_token) {
        snprintf(desc, desclen, "job object only (the low integrity token was "
                                "unavailable)");
        return -1;
    }
    nt_slot_where(where, sizeof(where), appdir);
    snprintf(desc, desclen, "job object%s%s + low integrity, writes confined to "
                            "%s" NT_ALSO_WRITABLE " (reads are not confined)"
                           ,
             uinote, privs, where);
    return 0;
}

#endif
