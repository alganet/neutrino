# Seatbelt compares resolved paths, and /tmp and /var are both symlinks on
# macOS -- a rule written against /var/folders matches nothing, because the
# kernel sees /private/var/folders.
nt_resolve() {
    ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

# The seatbelt profile, and the only platform in this file that gets one. Linux gets
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
# shell.openExternal is unaffected. It is here because this is the only place
# the profile is built.
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

@@include sh/macos-confine.sh

