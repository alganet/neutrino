/*
 * crash-probe.c - a process that crashes, optionally at low integrity
 *
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 *
 * netinstall.c's nt_limits sets RLIMIT_CORE to zero on every POSIX platform and
 * returns NULL on _WIN32, so --info prints no `limits` line there at all. The
 * comment above it says why the call exists: core_pattern normally pipes a dump
 * to systemd-coredump or apport, a process outside the sandbox writing outside
 * the app dir, so a crash is a write no filesystem rule sees.
 *
 * Windows has the same shape of channel and nothing closing it. Whether that
 * matters is not a manual page reading -- it depends on what Windows Error
 * Reporting actually does with an unhandled exception in a low integrity
 * process whose %TEMP% has been redirected, which is the shipping condition
 * once low integrity is the tier rather than an opt-in.
 *
 *   crash-probe report              prints the integrity level it is running at
 *   crash-probe low report          lowers to S-1-16-4096 first, then reports
 *   crash-probe crash               unhandled access violation, current level
 *   crash-probe low crash           lowers first, then the same crash
 *   crash-probe job crash           inside a job object shaped like nt_confine's
 *   crash-probe low job crash       both, which is the shipping condition
 *
 * `job` is not decoration and this probe was wrong without it. nt_confine puts
 * the process in a job carrying JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
 * which is documented to make the system terminate the process rather than call
 * the default handler -- and the default handler is what invokes WER. A crash
 * measured outside that job is a crash under a different exception path than
 * any app netinstall launches will ever take, so the first run of this suite
 * measured the wrong process and said WRITES_OUTSIDE_APPDIR=yes about it.
 *
 * The modes compose so the four cells can be told apart: whether it is the
 * label or the job that closes the channel is a different fact from whether the
 * channel closes, and a suite that only ran the shipping combination could not
 * say which. `low report` stays the control that says the drop is real -- a
 * `crash` that produced no dump means nothing if the process was never
 * lowered.
 *
 * The drop is nt_drop_to_low from sandbox_win.c, copied rather than shared
 * because a probe that imports the thing it is measuring cannot fail
 * independently of it. If the two ever disagree, this file is wrong and the
 * suite around it says so by measuring an integrity level it did not ask for.
 */

#include <stdio.h>
#include <string.h>

#ifdef _WIN32

#include <windows.h>
#include <sddl.h>

/* Verbatim from sandbox_win.c -- see the header comment for why it is copied. */
static int drop_to_low(void)
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

/*
 * The level as the kernel reports it, not as we asked for it. The RID is the
 * whole answer -- 0x1000 low, 0x2000 medium, 0x3000 high -- so it is printed
 * raw rather than mapped to a word a reader would then have to trust.
 */
static void report_level(void)
{
    HANDLE token = NULL;
    DWORD len = 0;
    TOKEN_MANDATORY_LABEL *tml = NULL;
    DWORD rid = 0;

    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        printf("il=UNREADABLE err=%lu\n", (unsigned long)GetLastError());
        return;
    }
    GetTokenInformation(token, TokenIntegrityLevel, NULL, 0, &len);
    if (len > 0) {
        tml = (TOKEN_MANDATORY_LABEL *)LocalAlloc(LPTR, len);
    }
    if (tml && GetTokenInformation(token, TokenIntegrityLevel, tml, len, &len)) {
        UCHAR *count = GetSidSubAuthorityCount(tml->Label.Sid);
        if (count && *count > 0) {
            rid = *GetSidSubAuthority(tml->Label.Sid, (DWORD)(*count - 1));
        }
        printf("il=0x%lx\n", (unsigned long)rid);
    } else {
        printf("il=UNREADABLE err=%lu\n", (unsigned long)GetLastError());
    }
    if (tml) {
        LocalFree(tml);
    }
    CloseHandle(token);
}

/*
 * An unhandled access violation, and nothing standing between it and WER.
 *
 * SetErrorMode is deliberately not called. Suppressing the fault dialog would
 * also change what WER does with the report, and what this measures is the
 * default a shipped app would get -- not the default plus one call netinstall
 * does not make. The suite bounds each run with a timeout instead, so a machine
 * that does put a dialog up costs a timeout rather than a hung lane.
 *
 * volatile, or the store is undefined behaviour the compiler is entitled to
 * delete -- and a probe that exits 0 because its crash was optimised out is a
 * probe that reports "no dump" for the wrong reason.
 */
static void crash(void)
{
    volatile int *p = NULL;

    fflush(stdout);
    *p = 1;
}

/*
 * The same job nt_confine builds for the run phase, minus the UI restrictions
 * it does not apply by default: DIE_ON_UNHANDLED_EXCEPTION and an active
 * process limit. Assigned to this process, which is what nt_confine does.
 */
static int join_job(void)
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
    limits.BasicLimitInformation.ActiveProcessLimit = 64;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits)) ||
        !AssignProcessToJobObject(job, GetCurrentProcess())) {
        CloseHandle(job);
        return 0;
    }
    /* Deliberately leaked: closing it while this process is a member is the
     * one thing that could take the process down before it crashes. */
    return 1;
}

int main(int argc, char **argv)
{
    int i = 1;
    int lowered = 0;
    const char *mode = "report";

    if (i < argc && strcmp(argv[i], "low") == 0) {
        lowered = drop_to_low();
        if (!lowered) {
            /*
             * Said on stdout and exited non-zero rather than crashing anyway:
             * a crash at medium integrity recorded as a crash at low integrity
             * is the one wrong answer this probe could give.
             */
            printf("il=DROPFAILED err=%lu\n", (unsigned long)GetLastError());
            return 2;
        }
        i++;
    }
    if (i < argc && strcmp(argv[i], "job") == 0) {
        if (!join_job()) {
            /* Same rule as the drop: a crash outside the job recorded as a
             * crash inside it is an answer about the wrong process. */
            printf("il=JOBFAILED err=%lu\n", (unsigned long)GetLastError());
            return 2;
        }
        i++;
    }
    if (i < argc) {
        mode = argv[i];
    }

    if (strcmp(mode, "report") == 0) {
        report_level();
        return 0;
    }
    if (strcmp(mode, "crash") == 0) {
        report_level();
        crash();
        return 0; /* not reached */
    }

    fprintf(stderr, "usage: crash-probe [low] report|crash\n");
    return 64;
}

#else

int main(void)
{
    /*
     * Every other platform answers this question with RLIMIT_CORE, which
     * netinstall already sets and phases.sh already reads off --info's `limits`
     * line. There is nothing here to measure, and a probe that built into
     * something runnable on those platforms would invite someone to run it.
     */
    fprintf(stderr, "crash-probe: windows only\n");
    return 77;
}

#endif
