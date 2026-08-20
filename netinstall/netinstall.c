/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

/* realpath is behind __DARWIN_C_LEVEL, and the build sets _POSIX_C_SOURCE. */
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#include <process.h>
#define NT_SEP '\\'
#else
#include <unistd.h>
#define NT_SEP '/'
#endif

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#if defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <sys/sysctl.h>
#endif

#include "netinstall.h"
#include "env.h"
#include "fetch.h"
#include "sandbox.h"
#include "sha256.h"

const char *nt_basename(const char *path)
{
    const char *p = path;
    const char *last = path;

    for (; *p; p++) {
        if (*p == '/' || *p == '\\') {
            last = p + 1;
        }
    }
    return last;
}

int nt_self_path(char *buf, size_t len, const char *argv0)
{
#if defined(_WIN32)
    char raw[NT_PATH_MAX];
    HANDLE h;
    DWORD n;

    (void)argv0;
    n = GetModuleFileNameA(NULL, raw, (DWORD)sizeof(raw));
    if (n == 0 || n >= sizeof(raw)) {
        return -1;
    }
    /* That is the path the image was loaded by, symlink and all. Resolve it. */
    h = CreateFileA(raw, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        char final[NT_PATH_MAX];
        DWORD m = GetFinalPathNameByHandleA(h, final, (DWORD)sizeof(final),
                                            FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        CloseHandle(h);
        if (m > 0 && m < sizeof(final)) {
            const char *p = final;
            if (strncmp(p, "\\\\?\\", 4) == 0) {
                p += 4;
            }
            return (size_t)snprintf(buf, len, "%s", p) < len ? 0 : -1;
        }
    }
    return (size_t)snprintf(buf, len, "%s", raw) < len ? 0 : -1;
#elif defined(__APPLE__)
    /* _NSGetExecutablePath hands back the path as invoked, symlinks and all. */
    char raw[NT_PATH_MAX];
    uint32_t n = (uint32_t)sizeof(raw);

    if (_NSGetExecutablePath(raw, &n) != 0) {
        return -1;
    }
    if (realpath(raw, buf)) {
        return 0;
    }
    return (size_t)snprintf(buf, len, "%s", raw) < len ? 0 : -1;
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#ifdef KERN_PROC_PATHNAME
    {
        int mib[4];
        size_t n = len;

        mib[0] = CTL_KERN;
        mib[1] = KERN_PROC;
        mib[2] = KERN_PROC_PATHNAME;
        mib[3] = -1;
        if (sysctl(mib, 4, buf, &n, NULL, 0) == 0) {
            return 0;
        }
    }
#endif
    /*
     * OpenBSD has neither KERN_PROC_PATHNAME nor /proc, so there is no way to
     * ask the kernel what is running. argv[0] is the only thing available, and
     * it is caller-controlled -- the guarantee that the name cannot be spoofed
     * simply does not hold there. Documented rather than silently pretended.
     */
    if (argv0 && *argv0 && realpath(argv0, buf)) {
        return 0;
    }
    return -1;
#else
    ssize_t n;

    (void)argv0;
    n = readlink("/proc/self/exe", buf, len - 1);
    if (n <= 0) {
        return -1;
    }
    buf[n] = '\0';
    return 0;
#endif
}

/*
 * The last segment is always the token and the first is always the name, so
 * position decides and no segment ever needs to be disambiguated by shape.
 * A '_' stands for a '-' in the resolved value; DNS labels cannot contain
 * '_', so only app names give anything up.
 */
int nt_parse_name(const char *base, nt_spec *out)
{
    char work[NT_SPEC_MAX];
    char *seg[64];
    size_t nseg = 0;
    size_t len, i;
    char *p;

    len = strlen(base);
    if (len == 0 || len >= sizeof(work)) {
        return -1;
    }
    memcpy(work, base, len + 1);

    if (len > 4 && strcmp(work + len - 4, ".exe") == 0) {
        len -= 4;
        work[len] = '\0';
    }
    if (len == 0 || len >= NT_SPEC_MAX) {
        return -1;
    }

    for (i = 0; i < len; i++) {
        char c = work[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) {
            return -1;
        }
    }

    memset(out, 0, sizeof(*out));
    memcpy(out->spec, work, len + 1);
    memcpy(out->app, work, len + 1);
    {
        char *lastdash = strrchr(out->app, '-');
        if (lastdash) {
            *lastdash = '\0';
        }
    }

    seg[nseg++] = work;
    for (p = work; *p; p++) {
        if (*p == '-') {
            *p = '\0';
            if (nseg >= sizeof(seg) / sizeof(seg[0])) {
                return -1;
            }
            seg[nseg++] = p + 1;
        }
    }
    if (nseg < 3) {
        return -1;
    }

    for (i = 0; i < nseg; i++) {
        if (seg[i][0] == '\0') {
            return -1;
        }
    }

    if (strlen(seg[0]) >= NT_NAME_MAX) {
        return -1;
    }
    strcpy(out->name, seg[0]);
    for (p = out->name; *p; p++) {
        if (*p == '_') {
            *p = '-';
        }
    }

    for (i = nseg - 2; i >= 1; i--) {
        size_t have = strlen(out->host);
        size_t add = strlen(seg[i]);
        if (have + add + 2 >= NT_HOST_MAX) {
            return -1;
        }
        if (have > 0) {
            out->host[have++] = '.';
            out->host[have] = '\0';
        }
        strcpy(out->host + have, seg[i]);
        if (i == 1) {
            break;
        }
    }
    for (p = out->host; *p; p++) {
        if (*p == '_') {
            *p = '-';
        }
    }

    if (strlen(seg[nseg - 1]) >= NT_TOKEN_MAX) {
        return -1;
    }
    strcpy(out->token, seg[nseg - 1]);
    if (out->token[0] != '0') {
        return -1;
    }
    if (strlen(out->token) - 1 < NT_TOKEN_MIN ||
        strlen(out->token) - 1 > 64) {
        return -1;
    }
    for (p = out->token + 1; *p; p++) {
        if (!((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f'))) {
            return -1;
        }
    }

    {
        const char *origin = NULL;
#ifdef NEUTRINO_TESTING
        origin = getenv("NEUTRINO_TEST_ORIGIN");
#endif
        if (origin && *origin) {
            if ((size_t)snprintf(out->url, sizeof(out->url), "%s/%s.cmd",
                                 origin, out->name) >= sizeof(out->url)) {
                return -1;
            }
        } else if ((size_t)snprintf(out->url, sizeof(out->url), "https://%s/%s.cmd",
                                    out->host, out->name) >= sizeof(out->url)) {
            return -1;
        }
    }

    return 0;
}

int nt_home(char *buf, size_t len)
{
    const char *e;

    e = getenv("NEUTRINO_HOME");
    if (e && *e) {
        return (size_t)snprintf(buf, len, "%s", e) < len ? 0 : -1;
    }
#if defined(_WIN32)
    e = getenv("LOCALAPPDATA");
    if (e && *e) {
        return (size_t)snprintf(buf, len, "%s\\neutrino", e) < len ? 0 : -1;
    }
#elif defined(__APPLE__)
    e = getenv("HOME");
    if (e && *e) {
        return (size_t)snprintf(buf, len, "%s/Library/Caches/neutrino", e) < len ? 0 : -1;
    }
#else
    e = getenv("XDG_CACHE_HOME");
    if (e && *e) {
        return (size_t)snprintf(buf, len, "%s/neutrino", e) < len ? 0 : -1;
    }
    e = getenv("HOME");
    if (e && *e) {
        return (size_t)snprintf(buf, len, "%s/.cache/neutrino", e) < len ? 0 : -1;
    }
#endif
    return -1;
}

int nt_mkdir_p(const char *path)
{
    char tmp[NT_PATH_MAX];
    char *p;

    if ((size_t)snprintf(tmp, sizeof(tmp), "%s", path) >= sizeof(tmp)) {
        return -1;
    }
    for (p = tmp + 1; *p; p++) {
        if (*p == '/' || *p == '\\') {
            char c = *p;
            *p = '\0';
#ifdef _WIN32
            _mkdir(tmp);
#else
            mkdir(tmp, 0700);
#endif
            *p = c;
        }
    }
#ifdef _WIN32
    if (_mkdir(tmp) != 0 && errno != EEXIST) {
        return -1;
    }
#else
    if (mkdir(tmp, 0700) != 0 && errno != EEXIST) {
        return -1;
    }
#endif
    return 0;
}

int nt_sha256_file(const char *path, char *hex65)
{
    static const char hexd[] = "0123456789abcdef";
    unsigned char digest[32];
    unsigned char chunk[65536];
    nt_sha256 ctx;
    size_t total = 0;
    size_t n;
    FILE *f;
    int i;

    f = fopen(path, "rb");
    if (!f) {
        return -1;
    }
    nt_sha256_init(&ctx);
    while ((n = fread(chunk, 1, sizeof(chunk), f)) > 0) {
        total += n;
        if (total > NT_MAX_PAYLOAD) {
            fclose(f);
            return -1;
        }
        nt_sha256_update(&ctx, chunk, n);
    }
    if (ferror(f)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    nt_sha256_final(&ctx, digest);

    for (i = 0; i < 32; i++) {
        hex65[i * 2] = hexd[digest[i] >> 4];
        hex65[i * 2 + 1] = hexd[digest[i] & 15];
    }
    hex65[64] = '\0';
    return 0;
}

int nt_is_text(const char *path)
{
    unsigned char chunk[65536];
    size_t n, i;
    FILE *f;

    f = fopen(path, "rb");
    if (!f) {
        return 0;
    }
    while ((n = fread(chunk, 1, sizeof(chunk), f)) > 0) {
        for (i = 0; i < n; i++) {
            if (chunk[i] == 0) {
                fclose(f);
                return 0;
            }
        }
    }
    if (ferror(f)) {
        fclose(f);
        return 0;
    }
    fclose(f);
    return 1;
}

/* Constant-time so a wrong pin leaks nothing through timing. */
static int nt_pin_ok(const char *token, const char *hex)
{
    const char *pin = token + 1;
    size_t n = strlen(pin);
    unsigned char diff = 0;
    size_t i;

    if (n > 64) {
        return 0;
    }
    for (i = 0; i < n; i++) {
        diff |= (unsigned char)(pin[i] ^ hex[i]);
    }
    return diff == 0;
}

static void nt_usage(FILE *out, const char *self)
{
    fprintf(out,
        "netinstall %s - name-addressed launcher for neutrino scripts\n"
        "\n"
        "Rename this binary to a spec and run it:\n"
        "\n"
        "    <name>-<host labels reversed>-<token>\n"
        "    neutrino-io-github-alganet-0a1b2c3d4e5f60718\n"
        "        -> https://alganet.github.io/neutrino.cmd\n"
        "        -> verified against sha256 prefix \"a1b2c3d4e5f60718\"\n"
        "\n"
        "Options:\n"
        "  --info      show what this name resolves to, then exit\n"
        "  --fetch     download and verify, but do not run\n"
        "  --verify    re-hash the cached script and report\n"
        "  --help, -h  this text\n"
        "  --version, -v\n"
        "  --          end netinstall options; the rest goes to the script\n"
        "\n"
        "Copy or hardlink the binary to rename it. Symlinks do not work: the\n"
        "real executable path is used, never argv[0].\n"
        "\n"
        "Current name: %s\n",
        NT_VERSION, self);
}

#ifdef _WIN32
/*
 * $NEUTRINO_HOME often arrives from a shell as C:/Users/..., and appending with
 * backslashes leaves a mixed path. Win32 accepts it, but cmd.exe redirection
 * and %~dp0 are less forgiving, so normalise once here.
 */
static void nt_win_slashes(char *p)
{
    for (; *p; p++) {
        if (*p == '/') {
            *p = '\\';
        }
    }
}
#endif

/* Truncation would silently point at the wrong path, so make it an error. */
static int nt_pathf(char *buf, size_t len, const char *fmt, ...)
{
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(buf, len, fmt, ap);
    va_end(ap);
    return (n < 0 || (size_t)n >= len) ? -1 : 0;
}

static long nt_pid(void)
{
#ifdef _WIN32
    return (long)GetCurrentProcessId();
#else
    return (long)getpid();
#endif
}

static void nt_setenv(const char *key, const char *val)
{
#ifdef _WIN32
    _putenv_s(key, val);
#else
    setenv(key, val, 1);
#endif
}

/*
 * Redirecting the XDG dirs and TMPDIR into the app dir is what makes "writable
 * footprint == app dir" true without needing a read allowlist, which is the
 * part that fights the webviews' own sandboxes.
 */
static void setenv_dir(const char *key, const char *appdir, const char *sub)
{
    char path[NT_PATH_MAX];

    snprintf(path, sizeof(path), "%s%c%s", appdir, NT_SEP, sub);
    nt_mkdir_p(path);
    nt_setenv(key, path);
}

#ifdef _WIN32
/*
 * _spawnv quotes for the CRT, then cmd.exe parses the result again with its own
 * metacharacters. An argument carrying any of these would be reinterpreted as
 * shell syntax rather than delivered verbatim, so refuse instead of guessing at
 * an escaping scheme that cmd does not consistently honour.
 */
static int nt_cmd_safe(const char *arg)
{
    return arg[strcspn(arg, "\"&|<>^%!()")] == '\0';
}
#endif

static int nt_exec(const char *script, int argc, char **argv, int rest)
{
    char **args;
    int n = 0;
    int i;

    args = malloc(sizeof(*args) * (size_t)(argc - rest + 4));
    if (!args) {
        fprintf(stderr, "netinstall: out of memory\n");
        return 126;
    }
#ifdef _WIN32
    args[n++] = (char *)"cmd.exe";
    args[n++] = (char *)"/c";
#else
    args[n++] = (char *)"sh";
#endif
    args[n++] = (char *)script;
    for (i = rest; i < argc; i++) {
#ifdef _WIN32
        if (!nt_cmd_safe(argv[i])) {
            fprintf(stderr, "netinstall: refusing to forward argument with cmd "
                            "metacharacters: %s\n", argv[i]);
            free(args);
            return 126;
        }
#endif
        args[n++] = argv[i];
    }
    args[n] = NULL;

#ifdef _WIN32
    {
        int rc = (int)_spawnv(_P_WAIT, "C:\\Windows\\System32\\cmd.exe",
                              (const char *const *)args);
        free(args);
        return rc;
    }
#else
    execv("/bin/sh", args);
    free(args);
    fprintf(stderr, "netinstall: cannot exec /bin/sh\n");
    return 126;
#endif
}

/*
 * The forced-off hook exists only in test builds, so a release binary has no
 * way to be talked out of confining anything.
 */
static int nt_apply_confine(nt_phase phase, const char *home, const char *appdir,
                            int enforce, char *desc, size_t desclen)
{
#ifdef NEUTRINO_TESTING
    const char *off = getenv("NEUTRINO_TEST_NO_CONFINE");

    if (off && *off == '1') {
        snprintf(desc, desclen, "none (disabled for testing)");
        return -1;
    }
#endif
    return nt_confine(phase, home, appdir, enforce, desc, desclen);
}

typedef enum {
    NT_RUN,
    NT_INFO,
    NT_FETCH_ONLY,
    NT_VERIFY
} nt_mode;

/* A read-only file cannot be removed or renamed over on Windows. */
static void nt_unlock(const char *path)
{
#ifdef _WIN32
    SetFileAttributesA(path, FILE_ATTRIBUTE_NORMAL);
#else
    (void)path;
#endif
}

static int nt_link_or_copy(const char *from, const char *to)
{
    char chunk[65536];
    FILE *a, *b;
    size_t n;

    nt_unlock(to);
    remove(to);
#ifdef _WIN32
    if (CreateHardLinkA(to, from, NULL)) {
        return 0;
    }
#else
    if (link(from, to) == 0) {
        return 0;
    }
#endif
    a = fopen(from, "rb");
    if (!a) {
        return -1;
    }
    b = fopen(to, "wb");
    if (!b) {
        fclose(a);
        return -1;
    }
    while ((n = fread(chunk, 1, sizeof(chunk), a)) > 0) {
        if (fwrite(chunk, 1, n, b) != n) {
            fclose(a);
            fclose(b);
            remove(to);
            return -1;
        }
    }
    if (ferror(a) || fclose(b) != 0) {
        fclose(a);
        remove(to);
        return -1;
    }
    fclose(a);
    return 0;
}

/*
 * A relinked blob carries the mtime of whatever launch first downloaded it, so
 * switching back to an older pin would look stale to anything comparing the
 * script against what it built. Stamp placement time instead.
 */
static void nt_touch(const char *path)
{
#ifdef _WIN32
    HANDLE h = CreateFileA(path, FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ, NULL,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        FILETIME now;
        GetSystemTimeAsFileTime(&now);
        SetFileTime(h, NULL, NULL, &now);
        CloseHandle(h);
    }
#else
    utimes(path, NULL);
#endif
}

static void nt_readonly(const char *path)
{
#ifdef _WIN32
    SetFileAttributesA(path, FILE_ATTRIBUTE_READONLY);
#else
    chmod(path, 0444);
#endif
}

static int nt_exists(const char *path)
{
    struct stat st;

    return stat(path, &st) == 0;
}

/*
 * The script sits one level above the only writable directory, so an app cannot
 * rewrite the launcher it was verified from. The pin is re-checked on every
 * launch anyway, which keeps the name-to-content binding true even where no
 * confinement is available.
 */
int main(int argc, char **argv)
{
    char home[NT_PATH_MAX], blobs[NT_PATH_MAX], approot[NT_PATH_MAX];
    char script[NT_PATH_MAX], appdir[NT_PATH_MAX], tmpdir[NT_PATH_MAX];
    char self[NT_PATH_MAX], tmpfile[NT_PATH_MAX], blob[NT_PATH_MAX];
    char shown[NT_PATH_MAX], desc[512], hex[65];
    nt_mode mode = NT_RUN;
    nt_spec spec;
    int rest = argc;
    int cached = 0;
    int i;

    if (nt_self_path(self, sizeof(self), argc > 0 ? argv[0] : NULL) != 0) {
        fprintf(stderr, "netinstall: cannot determine own path\n");
        return 2;
    }

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) {
            rest = i + 1;
            break;
        } else if (strcmp(argv[i], "--info") == 0) {
            mode = NT_INFO;
        } else if (strcmp(argv[i], "--fetch") == 0) {
            mode = NT_FETCH_ONLY;
        } else if (strcmp(argv[i], "--verify") == 0) {
            mode = NT_VERIFY;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            nt_usage(stdout, nt_basename(self));
            return 0;
        } else if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-v") == 0) {
            printf("netinstall %s\n", NT_VERSION);
            return 0;
        } else {
            rest = i;
            break;
        }
        rest = i + 1;
    }

    if (nt_parse_name(nt_basename(self), &spec) != 0) {
        fprintf(stderr, "netinstall: \"%s\" is not a valid spec\n\n",
                nt_basename(self));
        nt_usage(stderr, nt_basename(self));
        return 2;
    }

    if (nt_home(home, sizeof(home)) != 0) {
        fprintf(stderr, "netinstall: cannot determine cache directory\n");
        return 2;
    }
    if (nt_pathf(blobs, sizeof(blobs), "%s%cblobs", home, NT_SEP) != 0 ||
        nt_pathf(approot, sizeof(approot), "%s%capps%c%s", home, NT_SEP, NT_SEP, spec.app) != 0 ||
        nt_pathf(script, sizeof(script), "%s%c%s.cmd", approot, NT_SEP, spec.name) != 0 ||
        nt_pathf(appdir, sizeof(appdir), "%s%c%s", approot, NT_SEP, spec.name) != 0 ||
        nt_pathf(tmpdir, sizeof(tmpdir), "%s%ctmp", appdir, NT_SEP) != 0) {
        fprintf(stderr, "netinstall: cache path too long\n");
        return 2;
    }
#ifdef _WIN32
    nt_win_slashes(home);
    nt_win_slashes(blobs);
    nt_win_slashes(approot);
    nt_win_slashes(script);
    nt_win_slashes(appdir);
    nt_win_slashes(tmpdir);
#endif

    if (mode == NT_INFO) {
        printf("name       %s\n", spec.name);
        printf("host       %s\n", spec.host);
        printf("token      %s\n", spec.token);
        printf("app        %s\n", spec.app);
        printf("url        %s\n", spec.url);
        printf("script     %s\n", script);
        printf("appdir     %s\n", appdir);
        printf("blobs      %s\n", blobs);
        if (nt_sha256_file(script, hex) == 0) {
            printf("sha256     %s\n", hex);
            printf("cached     %s\n", nt_pin_ok(spec.token, hex) ? "yes" : "yes (pin mismatch)");
        } else {
            printf("cached     no\n");
        }
        nt_apply_confine(NT_PHASE_RUN, home, appdir, 0, desc, sizeof(desc));
        printf("confine    %s\n", desc);
        {
            int total = 0;
            int dropped = nt_env_scrub(0, &total);
            printf("env        allowlist, %d of %d variables dropped\n",
                   dropped, total);
        }
        if (nt_fetch_command(spec.url, script, shown, sizeof(shown)) == 0) {
            printf("downloader %s\n", shown);
        }
        return 0;
    }

    if (mode == NT_VERIFY) {
        if (nt_sha256_file(script, hex) != 0) {
            fprintf(stderr, "netinstall: nothing cached at %s\n", script);
            return 1;
        }
        printf("%s  %s\n", hex, script);
        if (!nt_pin_ok(spec.token, hex)) {
            fprintf(stderr, "netinstall: pin mismatch\n");
            return 1;
        }
        return 0;
    }

    if (nt_mkdir_p(blobs) != 0 || nt_mkdir_p(tmpdir) != 0) {
        fprintf(stderr, "netinstall: cannot create %s\n", home);
        return 2;
    }

    if (nt_exists(script) && nt_sha256_file(script, hex) == 0 &&
        nt_pin_ok(spec.token, hex)) {
        cached = 1;
    }

    if (!cached) {
        if (nt_pathf(tmpfile, sizeof(tmpfile), "%s%c.tmp-%ld", blobs, NT_SEP,
                     nt_pid()) != 0) {
            return 2;
        }
        remove(tmpfile);
        if (nt_fetch(spec.url, tmpfile, home, shown, sizeof(shown)) != 0) {
            remove(tmpfile);
            fprintf(stderr, "netinstall: fetch failed: %s\n", spec.url);
            return 1;
        }
        if (nt_sha256_file(tmpfile, hex) != 0) {
            remove(tmpfile);
            fprintf(stderr, "netinstall: payload too large or unreadable\n");
            return 1;
        }
        if (!nt_pin_ok(spec.token, hex)) {
            remove(tmpfile);
            fprintf(stderr, "netinstall: pin mismatch\n");
            fprintf(stderr, "  expected %s...\n  got      %s\n", spec.token + 1, hex);
            return 1;
        }
        if (!nt_is_text(tmpfile)) {
            remove(tmpfile);
            fprintf(stderr, "netinstall: payload is not text; refusing to run it\n");
            return 1;
        }
        if (nt_pathf(blob, sizeof(blob), "%s%c%s", blobs, NT_SEP, hex) != 0) {
            return 2;
        }
        if (nt_exists(blob)) {
            /* Same digest, so the existing blob is this content. Keep it. */
            remove(tmpfile);
        } else if (rename(tmpfile, blob) != 0) {
            if (!nt_exists(blob)) {
                remove(tmpfile);
                fprintf(stderr, "netinstall: cannot commit blob\n");
                return 1;
            }
            remove(tmpfile);
        }
        nt_readonly(blob);
        if (nt_link_or_copy(blob, script) != 0) {
            fprintf(stderr, "netinstall: cannot place %s\n", script);
            return 1;
        }
        nt_touch(script);
        nt_readonly(script);
    }

    if (mode == NT_FETCH_ONLY) {
        printf("%s\n", script);
        return 0;
    }

    /*
     * Before anything else the app could read: the environment is where a live
     * ssh-agent socket and most CI tokens actually live, and no filesystem
     * sandbox touches them. This runs on every platform, including the ones
     * that get no confinement at all.
     */
    nt_env_scrub(1, NULL);

    setenv_dir("XDG_CACHE_HOME", appdir, "cache");
    setenv_dir("XDG_CONFIG_HOME", appdir, "config");
    setenv_dir("XDG_DATA_HOME", appdir, "data");
    setenv_dir("XDG_STATE_HOME", appdir, "state");
#ifndef __APPLE__
    /*
     * Not on macOS: NSTemporaryDirectory() is what Cocoa actually uses and it
     * expects the Darwin per-user temp dir, which the seatbelt profile already
     * allows. Overriding TMPDIR here only moves files somewhere Foundation and
     * its callers disagree about, and buys no confinement.
     */
    setenv_dir("TMPDIR", appdir, "tmp");
#endif
#if defined(_WIN32) && defined(NEUTRINO_CONFINE_TIGHT)
    /*
     * %TEMP% does not redirect on its own at low integrity, so jsc.exe would
     * fail writing intermediates into the medium-labelled default.
     */
    setenv_dir("TEMP", appdir, "tmp");
    setenv_dir("TMP", appdir, "tmp");
#endif

    if (nt_apply_confine(NT_PHASE_RUN, home, appdir, 1, desc, sizeof(desc)) != 0) {
#ifdef NEUTRINO_STRICT_SANDBOX
        fprintf(stderr, "netinstall: refusing to run unconfined: %s\n", desc);
        return 3;
#else
        fprintf(stderr, "netinstall: warning: running unconfined: %s\n", desc);
#endif
    }

    return nt_exec(script, argc, argv, rest);
}
