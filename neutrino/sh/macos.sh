# Seatbelt compares resolved paths, and /tmp and /var are both symlinks on
# macOS -- a rule written against /var/folders matches nothing, because the
# kernel sees /private/var/folders.
nt_resolve() {
    ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

# The tight tier, and the only platform in this file that has one. Linux gets
# nothing here on purpose: the mechanism a script could reach is bubblewrap, and
# this file just spent a great deal of effort turning WebKitGTK's *own*
# bubblewrap on. Wrapping that in another user namespace is the nesting problem
# netinstall already measured from the other side, and losing the renderer's
# sandbox to gain confinement against the app's author is a trade this file is
# not entitled to make silently. Windows gets nothing because nothing is
# available: job UI limits, low integrity and AppContainer have each been
# measured against a real WebView2 and each breaks it.
#
# Deny-list shaped, like netinstall's, because an allow-list around a webview is
# an open-ended argument with WindowServer, CoreText, the pasteboard and every
# XPC service WebKit decides it needs this release.
#
# What it does NOT do is netinstall's wholesale $HOME read denial. netinstall
# knows what it launched -- a pinned script it fetched itself. This file is a
# launcher for whatever an author wrote, and an app that reads a file the user
# picked is an ordinary app. Confining writes, refusing to execute what was
# written, and closing the services that hand out secrets is the part that holds
# regardless of what the app legitimately does.
#
# Write xor execute has a second door and it is not a file rule. An app can
# write an .app bundle into the directory this profile makes writable, hand it
# to /usr/bin/open or to NSWorkspace.openURL, and LaunchServices does the spawn
# from a daemon that is in nobody's sandbox -- so the bundle runs outside every
# profile in the stack. Denying the binary settles nothing, because the AppKit
# call is right there; the service is the boundary.
#
# It takes two names, measured one candidate at a time on a macos runner with an
# unconfined control after every attempt: launchservicesd alone leaves the
# bundle launching, quarantine-resolver alone leaves it launching, the pair
# shuts both doors. What stays open, also measured: an already-installed app
# still launches and an http url still reaches the browser, so
# shell.openExternal is unaffected. This is only in the tight tier because that
# is the only tier this function is reached from.
#
# Every path below lands inside an s-expression string literal, and a directory
# name may legally contain a `"`. Unescaped, one closes the string it is in and
# everything after it is profile source: TMPDIR set to `/tmp/x") (subpath "$HOME`
# produced `(subpath "/tmp/x") (subpath "/Users/runner")` -- a second, wider
# grant that seatbelt accepted without a word and that nothing anywhere would
# have noticed. Measured, with a benign-path control that stayed narrow.
#
# nt_sbquote is the answer rather than refusing such a path, because SBPL string
# literals do honour a backslash -- also measured, and not something to take on
# faith: if they did not, `\"` would end the string at the quote and escaping
# would be a no-op that reads like a fix. The escaped form was checked for still
# naming the directory it is supposed to, since a path mangled into naming
# nothing also refuses to widen. An embedded newline is accepted as-is.
nt_sbquote() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

nt_macos_profile() {
    appdir_r="$(nt_sbquote "$(nt_resolve "$1")")"
    tmpdir_r="$(nt_sbquote "$(nt_resolve "${TMPDIR:-/tmp}")")"
    home_r="$(nt_sbquote "$(nt_resolve "$HOME")")"
    cat <<PROFILE
(version 1)
(allow default)

(deny file-write*)
(allow file-write*
  (subpath "$appdir_r")
  (subpath "$tmpdir_r")
  (subpath "$home_r/Library/Caches")
  (subpath "$home_r/Library/Preferences")
  (subpath "$home_r/Library/WebKit")
  (subpath "$home_r/Library/Saved Application State")
  (subpath "/private/var/folders")
  (regex #"^/dev/(null|zero|random|urandom|tty|dtracehelper)\$"))

(deny process-exec*
  (subpath "$appdir_r")
  (subpath "$tmpdir_r")
  (subpath "$home_r/Library/Caches")
  (subpath "$home_r/Library/Preferences")
  (subpath "$home_r/Library/WebKit")
  (subpath "$home_r/Library/Saved Application State")
  (subpath "/private/var/folders"))

(deny mach-lookup
  (global-name "com.apple.SecurityServer")
  (global-name "com.apple.securityd.xpc")
  (global-name "com.apple.tccd")
  (global-name "com.apple.tccd.system"))

; LaunchServices. Both names, and it has to be both -- see the comment above
; this function. Denying either one on its own leaves an .app bundle written
; from inside the sandbox launching normally.
(deny mach-lookup
  (global-name "com.apple.coreservices.launchservicesd")
  (global-name "com.apple.coreservices.quarantine-resolver"))
(deny appleevent-send)
(deny mach-priv-task-port)
(deny signal (target others))

(deny file-read*
  (subpath "$home_r/.ssh")
  (subpath "$home_r/.gnupg")
  (subpath "$home_r/.aws")
  (subpath "$home_r/Library/Keychains")
  (subpath "$home_r/Library/Messages")
  (subpath "$home_r/Library/Mail")
  (subpath "$home_r/Library/Safari"))
PROFILE
}

run_macos() {
    if ! has_tier tight; then
        NEUTRINO_SCRIPT_PATH="$script_path" exec osascript -l JavaScript "$script_path"
    fi

    script_dir="$(dirname "$script_path")"
    script_name="$(basename "$script_path")"
    script_name="${script_name%.*}"
    app_dir="$script_dir/$script_name"
    mkdir -p "$app_dir" 2>/dev/null

    if [ ! -x /usr/bin/sandbox-exec ]; then
        echo "neutrino: sandbox-exec not found; running unconfined" >&2
        NEUTRINO_SCRIPT_PATH="$script_path" exec osascript -l JavaScript "$script_path"
    fi

    # The profile is a string and never a file, and that is the whole of this
    # change. It used to be written to neutrino.sb inside app_dir -- the one
    # directory the profile itself makes writable -- with the write unchecked
    # and the next line asking only whether the file was non-empty and whether
    # seatbelt would take it. Neither question is "did this run write it".
    #
    # Both halves of that were reachable, measured on a runner:
    #
    #   - plant a permissive profile, chmod 0444, and the rewrite fails with
    #     `Permission denied` on stderr that nothing acts on. The app launched
    #     under the planted text -- said by the launched process itself, which
    #     found the planted profile's fingerprint denial in force and could
    #     write $HOME.
    #   - plant a *directory* named neutrino.sb and seatbelt refuses it, at
    #     which point the fallback below runs the app with no profile at all.
    #
    # sandbox-exec -p was measured against -f before being trusted with this:
    # it accepts the profile verbatim, comments, `#"..."` regex literal and
    # spaced paths included; the same read, write, exec and LaunchServices
    # checks come back identical under both; a real WebKit window comes up; and
    # the profile does not linger in ps, because sandbox-exec execs and the
    # argv goes with it.
    profile="$(nt_macos_profile "$app_dir")"

    # Proven against a program that does nothing before it is trusted with one
    # that matters. A rejected profile makes sandbox-exec exit immediately, and
    # once the app is the thing being launched there is no way to tell that
    # apart from an app that failed on its own.
    #
    # The fallback stays "warn and run unconfined" rather than becoming fatal.
    # With the file gone there is no longer an input anyone can supply to
    # trigger it, so it is what it was always meant to be -- a compatibility
    # answer for a macOS that will not take this profile -- and not a downgrade
    # a same-uid process can reach for.
    if [ -z "$profile" ] || ! /usr/bin/sandbox-exec -p "$profile" /usr/bin/true >/dev/null 2>&1; then
        echo "neutrino: seatbelt rejected the profile; running unconfined" >&2
        NEUTRINO_SCRIPT_PATH="$script_path" exec osascript -l JavaScript "$script_path"
    fi

    NEUTRINO_SCRIPT_PATH="$script_path" exec /usr/bin/sandbox-exec -p "$profile" \
        osascript -l JavaScript "$script_path"
}

