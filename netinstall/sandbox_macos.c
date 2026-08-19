/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 */

#ifdef __APPLE__

/* realpath is behind __DARWIN_C_LEVEL, and the build sets _POSIX_C_SOURCE. */
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "netinstall.h"
#include "sandbox.h"

/*
 * Declared here rather than included: sandbox.h is deprecated SPI and is not
 * always present in a cross-compiler's macOS headers. It still resolves from
 * libSystem.
 */
extern int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                        const char *const parameters[],
                                        char **errorbuf);
extern void sandbox_free_error(char *errorbuf);

/*
 * A deny-list, not an allow-list. A (deny default) profile that still permits
 * Cocoa, WKWebView and Metal is undocumented SBPL archaeology that rebreaks on
 * every OS minor; this gets the write confinement for a fraction of the risk.
 *
 * Every path arrives as a parameter already built and resolved in C. SBPL's
 * string-append is not relied on, and seatbelt matches resolved paths, so
 * /var/folders/... must be passed as /private/var/folders/... or it silently
 * matches nothing.
 *
 * Known gap worth stating out loud: WKWebView's WebContent helper is spawned by
 * launchd rather than forked from us, so it does not inherit this profile. It
 * carries WebKit's own stricter one instead.
 */
static const char nt_profile[] =
    "(version 1)\n"
    "(allow default)\n"
    "(deny file-write*)\n"
    "(allow file-write*\n"
    "  (subpath (param \"APPDIR\"))\n"
    "  (subpath (param \"TMPDIR\"))\n"
    "  (subpath (param \"LIBCACHE\"))\n"
    "  (subpath (param \"LIBPREFS\"))\n"
    "  (subpath (param \"LIBWEBKIT\"))\n"
    "  (subpath (param \"LIBSTATE\"))\n"
    "  (subpath \"/private/var/folders\")\n"
    "  (regex #\"^/dev/(null|zero|random|urandom|tty|dtracehelper)$\"))\n"
#ifdef NEUTRINO_CONFINE_TIGHT
    /*
     * The tight tier denies $HOME wholesale rather than naming secrets one at a
     * time, then hands back the few subtrees Cocoa and WebKit read on the way
     * up. Metadata stays readable so traversal and stat still work; only file
     * contents are withheld.
     */
    "(deny file-read* (subpath (param \"HOME\")))\n"
    "(allow file-read-metadata (subpath (param \"HOME\")))\n"
    "(allow file-read*\n"
    "  (subpath (param \"APPDIR\"))\n"
    "  (subpath (param \"SCRIPTDIR\"))\n"
    "  (subpath (param \"LIBCACHE\"))\n"
    "  (subpath (param \"LIBPREFS\"))\n"
    "  (subpath (param \"LIBWEBKIT\"))\n"
    "  (subpath (param \"LIBSTATE\"))\n"
    "  (subpath (param \"LIBFONTS\")))\n"
#endif
    "(deny process-exec* (subpath (param \"APPDIR\")))\n"
    "(deny file-read*\n"
    "  (subpath (param \"SSH\"))\n"
    "  (subpath (param \"GNUPG\"))\n"
    "  (subpath (param \"AWS\"))\n"
    "  (subpath (param \"KEYCHAINS\"))\n"
    "  (subpath (param \"MESSAGES\"))\n"
    "  (subpath (param \"MAIL\"))\n"
    "  (subpath (param \"SAFARI\")))\n";

static const char nt_fetch_profile[] =
    "(version 1)\n"
    "(allow default)\n"
    "(deny file-write*)\n"
    "(allow file-write*\n"
    "  (subpath (param \"APPDIR\"))\n"
    "  (subpath \"/private/var/folders\")\n"
    "  (regex #\"^/dev/(null|zero|random|urandom|tty)$\"))\n"
    "(deny process-exec* (subpath (param \"APPDIR\")))\n";

/* Seatbelt compares resolved paths, and /var and /tmp are both symlinks. */
static const char *nt_resolve(const char *path, char *buf, size_t len)
{
    char tmp[NT_PATH_MAX];

    if (realpath(path, tmp) && strlen(tmp) < len) {
        memcpy(buf, tmp, strlen(tmp) + 1);
        return buf;
    }
    if ((size_t)snprintf(buf, len, "%s", path) >= len) {
        return "/var/empty";
    }
    return buf;
}

int nt_confine(nt_phase phase, const char *home, const char *appdir,
               char *desc, size_t desclen)
{
    char dirbuf[NT_PATH_MAX], tmpbuf[NT_PATH_MAX], blobs[NT_PATH_MAX];
    char scriptdir[NT_PATH_MAX];
    char *cut;
    char under[12][NT_PATH_MAX];
    const char *params[40];
    const char *userhome;
    const char *dir;
    char *err = NULL;
    int n = 0;
    int i;

    static const char *const subdirs[12] = {
        "/Library/Caches", "/Library/Preferences", "/Library/WebKit",
        "/Library/Saved Application State", "/.ssh", "/.gnupg", "/.aws",
        "/Library/Keychains", "/Library/Messages", "/Library/Mail",
        "/Library/Safari", "/Library/Fonts"
    };

    if (phase == NT_PHASE_FETCH) {
        snprintf(blobs, sizeof(blobs), "%s/blobs", home);
        dir = nt_resolve(blobs, dirbuf, sizeof(dirbuf));
        params[n++] = "APPDIR";
        params[n++] = dir;
        params[n] = NULL;
        if (sandbox_init_with_parameters(nt_fetch_profile, 0, params, &err) != 0) {
            snprintf(desc, desclen, "none (seatbelt rejected: %s)", err ? err : "?");
            if (err) {
                sandbox_free_error(err);
            }
            return -1;
        }
        snprintf(desc, desclen, "seatbelt, writes confined to %s", dir);
        return 0;
    }

    userhome = getenv("HOME");
    if (!userhome || !*userhome) {
        userhome = "/var/empty";
    }
    dir = nt_resolve(appdir, dirbuf, sizeof(dirbuf));
    snprintf(tmpbuf, sizeof(tmpbuf), "%s/tmp", dir);

    for (i = 0; i < 12; i++) {
        snprintf(under[i], sizeof(under[i]), "%s%s", userhome, subdirs[i]);
    }

    params[n++] = "APPDIR";     params[n++] = dir;
    params[n++] = "TMPDIR";     params[n++] = tmpbuf;
    params[n++] = "LIBCACHE";   params[n++] = under[0];
    params[n++] = "LIBPREFS";   params[n++] = under[1];
    params[n++] = "LIBWEBKIT";  params[n++] = under[2];
    params[n++] = "LIBSTATE";   params[n++] = under[3];
    params[n++] = "SSH";        params[n++] = under[4];
    params[n++] = "GNUPG";      params[n++] = under[5];
    params[n++] = "AWS";        params[n++] = under[6];
    params[n++] = "KEYCHAINS";  params[n++] = under[7];
    params[n++] = "MESSAGES";   params[n++] = under[8];
    params[n++] = "MAIL";       params[n++] = under[9];
    params[n++] = "SAFARI";     params[n++] = under[10];
    params[n++] = "LIBFONTS";   params[n++] = under[11];
    params[n++] = "HOME";       params[n++] = userhome;

    /*
     * The script sits one level above the app dir, and the default cache lives
     * under $HOME -- which the tight tier denies. Without this the launcher
     * would be unreadable to sh, exactly as it was on linux.
     */
    snprintf(scriptdir, sizeof(scriptdir), "%s", dir);
    cut = strrchr(scriptdir, '/');
    if (cut && cut != scriptdir) {
        *cut = '\0';
    }
    params[n++] = "SCRIPTDIR";  params[n++] = scriptdir;
    params[n] = NULL;

    /*
     * The Library carve-outs are not optional: CFPreferences and WebKit write
     * there on every launch, and denying them takes the window down with them.
     */
    if (sandbox_init_with_parameters(nt_profile, 0, params, &err) != 0) {
        snprintf(desc, desclen, "none (seatbelt rejected: %s)", err ? err : "?");
        if (err) {
            sandbox_free_error(err);
        }
        return -1;
    }

#ifdef NEUTRINO_CONFINE_TIGHT
    snprintf(desc, desclen, "seatbelt, reads and writes confined to %s", dir);
#else
    snprintf(desc, desclen, "seatbelt, writes confined to %s", dir);
#endif
    return 0;
}

#endif
