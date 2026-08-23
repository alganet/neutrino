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

/* The fetch profile never carries it: the download is the one thing that has
 * to reach the network. */
#ifdef NEUTRINO_CONFINE_OFFLINE
#define NT_OFFLINE_NOTE " (offline)"
#else
#define NT_OFFLINE_NOTE ""
#endif

/*
 * The session tier is namespaces and the X11 SECURITY extension, and there is
 * nothing here shaped like either. Saying so beats letting a
 * -DNEUTRINO_CONFINE_NOSESSION build look like it did something.
 */
#ifdef NEUTRINO_CONFINE_NOSESSION
#define NT_SESSION_NOTE " (session tier unavailable here)"
#else
#define NT_SESSION_NOTE ""
#endif

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
    /*
     * Write xor execute, and it has to name every writable path or it means
     * nothing. Denying exec on the app dir alone left the carve-outs above --
     * the Library subtrees CFPreferences and WebKit insist on, and the Darwin
     * per-user temp dir -- both writable and executable, which is the whole
     * hole in one place. TMPDIR is not redirected on macOS, so it is a real
     * directory outside the app dir and needs saying explicitly.
     *
     * Deliberately not all of $HOME: an app running node from ~/.nvm or a tool
     * from a user prefix is not the attack, and nothing there is writable by a
     * confined app anyway.
     */
    "(deny process-exec*\n"
    "  (subpath (param \"APPDIR\"))\n"
    "  (subpath (param \"TMPDIR\"))\n"
    "  (subpath (param \"LIBCACHE\"))\n"
    "  (subpath (param \"LIBPREFS\"))\n"
    "  (subpath (param \"LIBWEBKIT\"))\n"
    "  (subpath (param \"LIBSTATE\"))\n"
    "  (subpath \"/private/var/folders\"))\n"
    /*
     * The file denials below are necessary and not sufficient. A keychain is not
     * read by opening a file -- the request goes to securityd over Mach, so
     * denying ~/Library/Keychains alone was theatre. Denying the service is what
     * actually closes it. Certificate trust lives in a different daemon
     * (com.apple.trustd) and is deliberately left reachable, or TLS inside the
     * webview would stop working.
     *
     * tccd is the gatekeeper for camera, microphone, screen recording and the
     * Documents and Desktop folders. With it unreachable those fail closed
     * instead of showing the user a consent prompt attributed to a launcher
     * they did not think was asking.
     *
     * appleevent-send is the large one: osascript driving Finder or Terminal is
     * a complete escape from any of this. The polyglot's own JXA path uses the
     * ObjC bridge rather than sending events, so it does not need this.
     */
#ifdef NEUTRINO_CONFINE_OFFLINE
    /*
     * Only IP is denied, so unix sockets and Mach are untouched -- WindowServer,
     * the pasteboard and WebKit's own helpers all talk over those, and denying
     * them takes the window down with the network.
     */
    "(deny network-outbound (remote ip))\n"
    "(deny network-inbound (local ip))\n"
#endif
    "(deny mach-lookup\n"
    "  (global-name \"com.apple.SecurityServer\")\n"
    "  (global-name \"com.apple.securityd.xpc\")\n"
    "  (global-name \"com.apple.tccd\")\n"
    "  (global-name \"com.apple.tccd.system\"))\n"
#ifdef NEUTRINO_CONFINE_TIGHT
    /*
     * LaunchServices, and the door that walks out of every profile in the
     * stack. A confined app writes an .app bundle into the directory this
     * profile makes writable, hands it to /usr/bin/open, and the spawn is done
     * by a daemon that is in nobody's sandbox. Denying the binary would settle
     * nothing: anything that can reach AppKit calls NSWorkspace.openURL
     * instead, and that door was measured open under this profile too. Both
     * had to close or neither was closed.
     *
     * Both names, and it has to be both. Measured one candidate at a time on a
     * macos-latest runner, each against a bundle written from inside the
     * sandbox, with an unconfined control after every attempt: launchservicesd
     * alone leaves it launching, quarantine-resolver alone leaves it launching,
     * and the pair shuts both doors. LaunchServices has a way round each of
     * them and no way round the two. That is also why the obvious one-line fix
     * -- launchservicesd, the daemon the escape is named after -- is not the
     * fix, and why this comment names the measurement rather than the reason:
     * the reason is Apple's and it is not documented.
     *
     * What this does not close, also measured: an app that is already installed
     * and registered still launches, and an http url still reaches the browser,
     * so shell.openExternal keeps working. The boundary is on launching a
     * bundle the app itself wrote, which is the escape, and not on
     * LaunchServices as such.
     *
     * confine.sh asserts the outcome in both tiers, so a macOS that makes
     * either name sufficient -- or neither -- is a failure and not a silence.
     */
    "(deny mach-lookup\n"
    "  (global-name \"com.apple.coreservices.launchservicesd\")\n"
    "  (global-name \"com.apple.coreservices.quarantine-resolver\"))\n"
#endif
    "(deny appleevent-send)\n"
    /* The macOS spelling of ptrace: a task port is read and write access to
     * another process's memory. Signals are scoped to our own sandbox, which is
     * what LANDLOCK_SCOPE_SIGNAL buys on the other side. */
    "(deny mach-priv-task-port)\n"
    "(deny signal (target others))\n"
    "(deny file-read*\n"
    "  (subpath (param \"SSH\"))\n"
    "  (subpath (param \"GNUPG\"))\n"
    "  (subpath (param \"AWS\"))\n"
    "  (subpath (param \"KEYCHAINS\"))\n"
    "  (subpath (param \"MESSAGES\"))\n"
    "  (subpath (param \"MAIL\"))\n"
    "  (subpath (param \"SAFARI\")))\n";

/*
 * The per-user temp dir is deliberately *not* writable here, unlike in the run
 * profile above. The downloader writes one file, into the directory named by
 * APPDIR, and measured on CI it needs nothing else: with this allow removed the
 * fetch still succeeds and the child can no longer write anywhere under
 * /private/var/folders. Leaving it in made "writes confined to <blobs>" a false
 * sentence, which matters now that --info prints it.
 *
 * The exec denial keeps that subpath, because it costs nothing and w^x is not
 * what was being narrowed.
 */
static const char nt_fetch_profile[] =
    "(version 1)\n"
    "(allow default)\n"
    "(deny file-write*)\n"
    "(allow file-write*\n"
    "  (subpath (param \"APPDIR\"))\n"
    "  (regex #\"^/dev/(null|zero|random|urandom|tty)$\"))\n"
    "(deny process-exec*\n"
    "  (subpath (param \"APPDIR\"))\n"
    "  (subpath \"/private/var/folders\"))\n";

/*
 * The rest of the writable set, spelled where a user can read it.
 *
 * The profile above grants every one of these deliberately -- the Library
 * subtrees because CFPreferences and WebKit write there on every launch and
 * denying them takes the window down, /private/var/folders because macOS is the
 * one platform where TMPDIR is deliberately not redirected, and the device
 * nodes because a shell script that cannot open /dev/null is a script whose
 * every redirection fails. None of that is new and all of it has a comment.
 * What was wrong is that "writes confined to <appdir>" was the only one of
 * those a user ever saw, and it named one of six.
 *
 * Measured on a macos-latest runner, both tiers: tmpdir=CTO darwin=CTO
 * libcache=CTO libprefs=CTO, against home=--- and tmp=--- beside them.
 */
#define NT_ALSO_WRITABLE ", /private/var/folders, " \
    "~/Library/{Caches,Preferences,WebKit,Saved Application State} " \
    "and six /dev nodes"

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

int nt_confine(nt_phase phase, const char *home, const char *appdir, int enforce,
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

    /*
     * No early return for --info, and that is the fix rather than a tidy-up.
     * The description used to be written twice: once here from `home` and
     * `appdir` as handed in, and once below from the directory the profile is
     * actually built around. They said different things, and only the one
     * nobody applies was printed. Measured on a macos-latest runner: --info's
     * fetch line named the cache root while the profile confined the downloader
     * to the blobs directory inside it, and a tight build claimed "reads and
     * writes confined to" for a fetch profile that confines no reads at all.
     *
     * So the description is built once, at the bottom of each phase, from the
     * same resolved path the profile got -- which is what linux has always done
     * and why linux was the one platform saying the right thing here.
     */
    if (phase == NT_PHASE_FETCH) {
        snprintf(blobs, sizeof(blobs), "%s/blobs", home);
        dir = nt_resolve(blobs, dirbuf, sizeof(dirbuf));
        if (enforce) {
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
        }
        /* The fetch profile makes no read claim, in either tier, because it
         * imposes no read rule. It grants the blobs directory and five device
         * nodes and that is the whole of it. */
        snprintf(desc, desclen,
                 "seatbelt, writes confined to %s and five /dev nodes", dir);
        return 0;
    }

    userhome = getenv("HOME");
    if (!userhome || !*userhome) {
        userhome = "/var/empty";
    }
    /* Every caller passes an appdir for the run phase; realpath would take a
     * null one personally, and this path is now walked by --info too. */
    dir = nt_resolve(appdir ? appdir : "/var/empty", dirbuf, sizeof(dirbuf));
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
    if (enforce &&
        sandbox_init_with_parameters(nt_profile, 0, params, &err) != 0) {
        snprintf(desc, desclen, "none (seatbelt rejected: %s)", err ? err : "?");
        if (err) {
            sandbox_free_error(err);
        }
        return -1;
    }

#ifdef NEUTRINO_CONFINE_TIGHT
    /* Not "reads confined to the app dir": the tight profile denies reads under
     * $HOME and hands back the subtrees Cocoa and WebKit read on the way up,
     * and everything outside $HOME is readable as it is in the default tier. */
    snprintf(desc, desclen, "seatbelt%s" NT_SESSION_NOTE ", reads denied under "
                            "$HOME, writes confined to %s" NT_ALSO_WRITABLE,
             NT_OFFLINE_NOTE, dir);
#else
    snprintf(desc, desclen, "seatbelt%s" NT_SESSION_NOTE ", writes confined to "
                            "%s" NT_ALSO_WRITABLE,
             NT_OFFLINE_NOTE, dir);
#endif
    return 0;
}

#endif
