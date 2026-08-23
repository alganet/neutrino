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
 * Namespaces that belong to this program rather than to a toolkit. Nothing here
 * is ever handed to a loader, so the name test below does not apply to them.
 */
static const char *const nt_env_own_prefixes[] = {
    "NEUTRINO_",
#ifdef _WIN32
    "PROCESSOR_",
#endif
    NULL
};

/*
 * Prefixes, so a toolkit's whole namespace comes through without this file
 * having to track every knob it grows.
 *
 * A prefix admits the namespace. It does not admit the names inside it that
 * answer "which file should I load", "which program should I run" or "should I
 * sandbox myself" -- see nt_env_loader_marks. That distinction used to be a
 * claim in this comment and it was false: LD_*, DYLD_* and GIO_MODULE_DIR are
 * indeed absent by construction, but GTK_MODULES, GDK_PIXBUF_MODULE_FILE,
 * QT_PLUGIN_PATH, QTWEBENGINE_PROCESS_PATH, WEBKIT_INJECTED_BUNDLE_PATH,
 * WEBKIT_EXEC_PATH, LIBGL_DRIVERS_PATH and VK_LAYER_PATH all came through, and
 * so did the two switches that turn the engine's own sandbox off.
 */
static const char *const nt_env_prefixes[] = {
#ifndef _WIN32
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

/*
 * The shapes a toolkit uses to name a file to load, a program to run, or a
 * sandbox to skip. Matched as substrings of a prefix-admitted name, so a knob
 * invented after this file was written is denied before anyone here hears about
 * it -- which is the only way a namespace can be admitted wholesale and still
 * mean something.
 *
 * Each of these is measured rather than assumed, in netinstall/test/env.sh:
 * GTK_MODULES loads the file it names into the app process, and
 * WEBKIT_INJECTED_BUNDLE_PATH loads one into the *web* process, the one holding
 * page content; QTWEBENGINE_CHROMIUM_FLAGS is appended to Chromium's own argv
 * by Qt, and --renderer-cmd-prefix in it chooses the program the renderer runs.
 * Neither sandbox covers for any of that: both platforms refuse to execve a
 * file the app has written and then map a library out of that same directory
 * without a word, in both tiers. This list is the defence, not a second one.
 *
 * What is deliberately not here: names that carry data rather than code.
 * GSETTINGS_SCHEMA_DIR and XDG_DATA_DIRS point at schemas and icons,
 * XDG_RUNTIME_DIR at the directory holding the session's sockets -- dropping
 * that one costs every Wayland session its display, and it buys nothing,
 * because a socket is not a thing this process dlopens.
 */
static const char *const nt_env_loader_marks[] = {
    "MODULE",   /* GTK_MODULES, GTK_IM_MODULE, GDK_PIXBUF_MODULEDIR */
    "PLUGIN",   /* QT_PLUGIN_PATH, QT_QPA_PLATFORM_PLUGIN_PATH */
    "PRELOAD",
    "LIBRAR",   /* ..._LIBRARY_PATH, ..._LIBRARIES */
    "LAYER",    /* VK_LAYER_PATH, VK_INSTANCE_LAYERS */
    "DRIVER",   /* LIBGL_DRIVERS_PATH, MESA_LOADER_DRIVER_OVERRIDE */
    "ICD",      /* VK_ICD_FILENAMES */
    "BUNDLE",   /* WEBKIT_INJECTED_BUNDLE_PATH */
    "SANDBOX",  /* QTWEBENGINE_DISABLE_SANDBOX, WEBKIT_FORCE_SANDBOX */
    "EXEC",     /* WEBKIT_EXEC_PATH */
    "LAUNCH",
    "PROFILER",
    "FLAGS",    /* QTWEBENGINE_CHROMIUM_FLAGS */
    "ARGS",
    "PATH",     /* GTK_PATH, QTWEBENGINE_PROCESS_PATH */
    "PREFIX",   /* GTK_EXE_PREFIX, GTK_DATA_PREFIX */
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

/* Does a prefix-admitted name contain one of the loader shapes above? */
static int nt_env_is_loader(const char *name, size_t namelen)
{
    size_t i, mlen, at;

    for (i = 0; nt_env_loader_marks[i]; i++) {
        mlen = strlen(nt_env_loader_marks[i]);
        if (mlen > namelen) {
            continue;
        }
        for (at = 0; at + mlen <= namelen; at++) {
            if (nt_env_eq(name + at, nt_env_loader_marks[i], mlen)) {
                return 1;
            }
        }
    }
    return 0;
}

/* name points at a "NAME=value" entry; namelen is the length up to the '='. */
static int nt_env_keep(const char *name, size_t namelen)
{
    size_t i, plen;

    /*
     * Exact names first, and they are not subject to the loader test: PATH is
     * on that list, it is the one this program cannot run without, and it was
     * vetted by being written down one at a time rather than by a prefix.
     */
    for (i = 0; nt_env_names[i]; i++) {
        if (strlen(nt_env_names[i]) == namelen &&
            nt_env_eq(name, nt_env_names[i], namelen)) {
            return 1;
        }
    }
    for (i = 0; nt_env_own_prefixes[i]; i++) {
        plen = strlen(nt_env_own_prefixes[i]);
        if (namelen >= plen && nt_env_eq(name, nt_env_own_prefixes[i], plen)) {
            return 1;
        }
    }
    for (i = 0; nt_env_prefixes[i]; i++) {
        plen = strlen(nt_env_prefixes[i]);
        if (namelen >= plen && nt_env_eq(name, nt_env_prefixes[i], plen)) {
            return !nt_env_is_loader(name, namelen);
        }
    }
    return 0;
}

#ifdef _WIN32
/*
 * Windows is the only platform that still removes a variable by name: its
 * environment is a block owned by the CRT and by Win32, not an array this
 * program may replace. So the name has to be spelled out in full.
 *
 * It used to be spelled into a 256-byte buffer with anything longer truncated,
 * which is two bugs rather than one. A truncated name is usually a name that
 * does not exist, so the variable stays -- measured, on every lane: a
 * 300-character name arrives at the app untouched. And sometimes it is the name
 * of something else: QT_ plus 252 characters is a name the allowlist keeps, the
 * same string with PATH on the end is one it drops, and truncating the second
 * produces the first exactly. Measured on all four POSIX lanes as
 * keep255=GONE -- the drop removing a variable it was told to keep.
 *
 * Every lane delivers names up to 65536 characters across execv, so there is no
 * length that would have been a safe guess. The heap is the answer, and
 * SetEnvironmentVariableA was measured taking a 4096-character name and the
 * variable going away.
 *
 * Returns 0 when the name could be spelled, -1 when it could not, because a
 * scrub that reports a count it did not deliver is the other half of this bug.
 */
static int nt_env_drop(const char *name, size_t namelen)
{
    char stack[256];
    char *buf = stack;

    if (namelen >= sizeof(stack)) {
        buf = malloc(namelen + 1);
        if (!buf) {
            return -1;
        }
    }
    memcpy(buf, name, namelen);
    buf[namelen] = '\0';
    /* Both copies: the CRT keeps its own, and the Win32 block is what a child
     * created with a NULL environment actually inherits. */
    _putenv_s(buf, "");
    SetEnvironmentVariableA(buf, NULL);
    if (buf != stack) {
        free(buf);
    }
    return 0;
}
#endif

#ifdef _WIN32
int nt_env_scrub(int enforce, int *total)
{
    char *block, *p;
    int seen = 0, dropped = 0, refused = 0;

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
        if (enforce && nt_env_drop(p, (size_t)(eq - p)) != 0) {
            refused++;
        }
    }
    FreeEnvironmentStringsA(block);
    if (total) {
        *total = seen;
    }
    return refused ? -1 : dropped;
}
#else
extern char **environ;

/*
 * Not by unsetting names one at a time, which is how this was written and why
 * it had a hole in it. unsetenv rewrites environ underneath the caller, so the
 * old walk restarted from the beginning after every removal and bounded itself
 * by the number of entries it had counted -- and a name it could not remove was
 * a name the next pass found in exactly the same place. It did not skip what it
 * could not drop; it stopped at it, and everything the allowlist was going to
 * remove after that point went to the app.
 *
 * Two entries could do that. A name over 255 characters, which nt_env_drop
 * truncated into something that did not exist; and an entry whose name is empty
 * -- strchr finds the '=' at offset zero, the allowlist says no to it, and
 * unsetenv("") is EINVAL. Measured on all four POSIX lanes: with either one in
 * front of them, nine markers including SSH_AUTH_SOCK reached the payload and
 * --info reported a hundred and sixteen of a hundred and thirty-one variables
 * dropped while nothing at all had been.
 *
 * So the array is built instead. There is no name to spell, so nothing to
 * truncate; there is one pass, so there is nothing to get stuck in; the
 * empty-name entry is simply not copied; and what the counting pass predicts is
 * what the enforcing pass delivers, which is what makes --info's number true.
 *
 * The one thing this rests on is that setenv still works on an environ this
 * program allocated rather than the libc -- main() scrubs and then sets five
 * XDG directories -- and that is measured rather than assumed: envlen.sh's
 * `setafter` assigns, calls setenv four times, execs, and has the child report
 * which survived. glibc, Darwin's libc and OpenBSD's libc all keep all four.
 *
 * The array is never freed. It is the process's environment until execv, which
 * is the whole remaining life of this process.
 */
int nt_env_scrub(int enforce, int *total)
{
    char **kept;
    int seen = 0, dropped = 0, at = 0;
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

    kept = malloc(sizeof(*kept) * (size_t)(seen - dropped + 1));
    if (!kept) {
        /* The caller is told, because a scrub that did not happen and a scrub
         * that dropped nothing to drop look identical from a count. */
        return -1;
    }
    for (i = 0; environ[i]; i++) {
        const char *eq = strchr(environ[i], '=');

        /*
         * An entry with no '=' at all is malformed and was kept by the walk
         * this replaces -- there was no name in it to unset. Kept here too:
         * changing that is a different decision than this one, and no lane has
         * been asked about it.
         */
        if (!eq || nt_env_keep(environ[i], (size_t)(eq - environ[i]))) {
            kept[at++] = environ[i];
        }
    }
    kept[at] = NULL;
    environ = kept;
    return dropped;
}
#endif
