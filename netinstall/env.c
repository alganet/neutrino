/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

#include "env.h"

/*
 * The app inherits an environment, and an environment carries secrets that
 * exist nowhere else on disk: SSH_AUTH_SOCK is a live agent that will sign
 * anything, and CI tokens and cloud keys are frequently nothing but a variable
 * in a shell. A filesystem sandbox does not touch any of it.
 *
 * So this is an allowlist, not a denylist. A denylist would have to enumerate
 * every secret-shaped name anyone has ever invented and would silently pass the
 * next one; an allowlist passes only what a toolkit is known to need and drops
 * whatever it has not heard of.
 *
 * Being honest about the ceiling: socket paths are guessable, so dropping
 * SSH_AUTH_SOCK and DBUS_SESSION_BUS_ADDRESS raises the bar rather than closing
 * the door -- and on Linux /proc/<pid>/environ of your other same-uid processes
 * stays readable, so a determined app can harvest what it was not handed. What
 * this does close completely is the secret that lives only in a variable.
 */

/*
 * Prefixes, so a toolkit's whole namespace comes through without this file
 * having to track every knob it grows. Nothing here can name a file that gets
 * loaded into another process: LD_*, DYLD_* and GIO_MODULE_DIR are absent by
 * construction.
 */
static const char *const nt_env_prefixes[] = {
    "NEUTRINO_",
#ifdef _WIN32
    "PROCESSOR_",
#else
    "LC_",
    "XDG_",
    "GDK_",
    "GTK_",
    "GSETTINGS_",
    "QT_",
    "QTWEBENGINE_",
    "WEBKIT_",
    "LIBGL_",
    "MESA_",
    "EGL_",
    "VK_",
#endif
    NULL
};

static const char *const nt_env_names[] = {
    "HOME",
    "PATH",
    "USER",
    "LOGNAME",
    "SHELL",
    "TERM",
    "COLORTERM",
    "TZ",
    "LANG",
    "LANGUAGE",
    "PWD",
#ifdef _WIN32
    /* cmd.exe and the CRT do not start without these. */
    "ALLUSERSPROFILE",
    "APPDATA",
    "CommonProgramFiles",
    "CommonProgramFiles(x86)",
    "CommonProgramW6432",
    "ComSpec",
    "COMPUTERNAME",
    "DriverData",
    "HOMEDRIVE",
    "HOMEPATH",
    "LOCALAPPDATA",
    "NUMBER_OF_PROCESSORS",
    "OS",
    "PATHEXT",
    "ProgramData",
    "ProgramFiles",
    "ProgramFiles(x86)",
    "ProgramW6432",
    "PUBLIC",
    "SESSIONNAME",
    "SystemDrive",
    "SystemRoot",
    "TEMP",
    "TMP",
    "USERNAME",
    "USERPROFILE",
    "windir",
#else
    "TMPDIR",
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "XMODIFIERS",
    "DESKTOP_SESSION",
    /* Cocoa reads both of these on the way up and misbehaves without them. */
    "__CF_USER_TEXT_ENCODING",
    "SECURITYSESSIONID",
#endif
    NULL
};

#ifdef _WIN32
/* Windows variable names are case-insensitive, and the casing of the
 * well-known ones is not consistent between shells. */
static int nt_env_eq(const char *a, const char *b, size_t n)
{
    size_t i;

    for (i = 0; i < n; i++) {
        char ca = a[i], cb = b[i];
        if (ca >= 'A' && ca <= 'Z') { ca = (char)(ca - 'A' + 'a'); }
        if (cb >= 'A' && cb <= 'Z') { cb = (char)(cb - 'A' + 'a'); }
        if (ca != cb) {
            return 0;
        }
    }
    return 1;
}
#else
static int nt_env_eq(const char *a, const char *b, size_t n)
{
    return strncmp(a, b, n) == 0;
}
#endif

/* name points at a "NAME=value" entry; namelen is the length up to the '='. */
static int nt_env_keep(const char *name, size_t namelen)
{
    size_t i, plen;

    for (i = 0; nt_env_names[i]; i++) {
        if (strlen(nt_env_names[i]) == namelen &&
            nt_env_eq(name, nt_env_names[i], namelen)) {
            return 1;
        }
    }
    for (i = 0; nt_env_prefixes[i]; i++) {
        plen = strlen(nt_env_prefixes[i]);
        if (namelen >= plen && nt_env_eq(name, nt_env_prefixes[i], plen)) {
            return 1;
        }
    }
    return 0;
}

static void nt_env_drop(const char *name, size_t namelen)
{
    char buf[256];

    if (namelen >= sizeof(buf)) {
        namelen = sizeof(buf) - 1;
    }
    memcpy(buf, name, namelen);
    buf[namelen] = '\0';
#ifdef _WIN32
    /* Both copies: _spawnv passes the CRT block, and the Win32 block is what
     * anything spawned with a NULL environment would inherit. */
    _putenv_s(buf, "");
    SetEnvironmentVariableA(buf, NULL);
#else
    unsetenv(buf);
#endif
}

#ifdef _WIN32
int nt_env_scrub(int enforce, int *total)
{
    char *block, *p;
    int seen = 0, dropped = 0;

    block = GetEnvironmentStringsA();
    if (!block) {
        if (total) {
            *total = 0;
        }
        return 0;
    }
    /* The block is our own copy, so deleting as we walk it is safe. */
    for (p = block; *p; p += strlen(p) + 1) {
        const char *eq;

        /* cmd.exe keeps "=C:" style drive-cwd entries; leave them alone. */
        if (*p == '=') {
            continue;
        }
        eq = strchr(p, '=');
        if (!eq) {
            continue;
        }
        seen++;
        if (nt_env_keep(p, (size_t)(eq - p))) {
            continue;
        }
        dropped++;
        if (enforce) {
            nt_env_drop(p, (size_t)(eq - p));
        }
    }
    FreeEnvironmentStringsA(block);
    if (total) {
        *total = seen;
    }
    return dropped;
}
#else
extern char **environ;

int nt_env_scrub(int enforce, int *total)
{
    int seen = 0, dropped = 0;
    int i;

    for (i = 0; environ[i]; i++) {
        const char *eq = strchr(environ[i], '=');
        seen++;
        if (eq && !nt_env_keep(environ[i], (size_t)(eq - environ[i]))) {
            dropped++;
        }
    }
    if (total) {
        *total = seen;
    }
    if (!enforce) {
        return dropped;
    }

    /*
     * unsetenv rewrites environ underneath us, so restart the scan after every
     * removal rather than trusting the index. The list is short and this runs
     * once per launch; the bound is only there so a libc that fails to remove a
     * name cannot spin forever.
     */
    for (i = 0; i <= seen; i++) {
        const char *eq;
        int j, found = -1;

        for (j = 0; environ[j]; j++) {
            eq = strchr(environ[j], '=');
            if (eq && !nt_env_keep(environ[j], (size_t)(eq - environ[j]))) {
                found = j;
                break;
            }
        }
        if (found < 0) {
            break;
        }
        eq = strchr(environ[found], '=');
        nt_env_drop(environ[found], (size_t)(eq - environ[found]));
    }
    return dropped;
}
#endif
