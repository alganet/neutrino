# The seatbelt profile, and the launch that applies it. Every artifact carries
# it; there is nothing to turn on and nothing to choose.
#
# This was the tight overlay's copy of this file until the tiers went. The base
# copy it replaces was a bare `exec osascript` -- so a standalone app, the one
# case where nothing else is confining anything, was the case that got no
# confinement at all.
#
# The read denials that were here -- ~/.ssh, ~/.gnupg, ~/.aws, Keychains,
# Messages, Mail, Safari -- went with netinstall's copy of the same list, and
# for the same reason: windows cannot confine a read, so no platform promises
# to. Leaving them here would have made the two halves of one product disagree
# about what an app may read, which is worse than either answer.

# printf and not a here-document, and on this platform that is a correctness
# rule rather than a style one.
#
# /bin/sh on macOS is bash 3.2, and its here-document goes to a temp file whose
# directory is `/tmp` -- not $TMPDIR, which it does not consult for this one
# thing. Under netinstall the launcher is already inside the fetch-and-run
# seatbelt profile, and that profile does not make /tmp writable: it grants the
# app dir, $TMPDIR, the four Library subtrees and six /dev nodes, deliberately
# and with `--info` printing the list. So the redirection failed with
#
#   line NNN: cannot create temp file for here document: Operation not permitted
#
# `cat` then wrote nothing, $profile came back empty, and the check below --
# which asks whether the profile is empty -- took the unconfined fallback and
# said "seatbelt rejected the profile". Seatbelt had not seen it. Every
# netinstall launch on macOS lost this profile, and the message named the wrong
# half of the failure while doing it.
#
# What was not lost is the confinement itself: netinstall had already applied
# its own profile, which is this one with the same rules and its own
# parameters, so the app was confined throughout and the line saying otherwise
# was the defect a user actually saw.
#
# Widening the outer profile to include /tmp was the other way to fix this, and
# it is the wrong one: it would hand every confined app a writable directory
# outside its own, to buy back a shell feature this function is the only macOS
# user of. So the here-document goes instead. printf writes to the pipe and
# needs no file anywhere.
nt_macos_profile() {
    appdir_r="$(nt_sbquote "$(nt_resolve "$1")")"
    tmpdir_r="$(nt_sbquote "$(nt_resolve "${TMPDIR:-/tmp}")")"
    home_r="$(nt_sbquote "$(nt_resolve "$HOME")")"
    printf '%s\n' \
'(version 1)' \
'(allow default)' \
'' \
'(deny file-write*)' \
'(allow file-write*' \
"  (subpath \"$appdir_r\")" \
"  (subpath \"$tmpdir_r\")" \
"  (subpath \"$home_r/Library/Caches\")" \
"  (subpath \"$home_r/Library/Preferences\")" \
"  (subpath \"$home_r/Library/WebKit\")" \
"  (subpath \"$home_r/Library/Saved Application State\")" \
'  (subpath "/private/var/folders")' \
'  (regex #"^/dev/(null|zero|random|urandom|tty|dtracehelper)$"))' \
'' \
'(deny process-exec*' \
"  (subpath \"$appdir_r\")" \
"  (subpath \"$tmpdir_r\")" \
"  (subpath \"$home_r/Library/Caches\")" \
"  (subpath \"$home_r/Library/Preferences\")" \
"  (subpath \"$home_r/Library/WebKit\")" \
"  (subpath \"$home_r/Library/Saved Application State\")" \
'  (subpath "/private/var/folders"))' \
'' \
'(deny mach-lookup' \
'  (global-name "com.apple.SecurityServer")' \
'  (global-name "com.apple.securityd.xpc")' \
'  (global-name "com.apple.tccd")' \
'  (global-name "com.apple.tccd.system"))' \
'' \
'; LaunchServices. Both names, and it has to be both -- see the comment above' \
'; this function. Denying either one on its own leaves an .app bundle written' \
'; from inside the sandbox launching normally.' \
'(deny mach-lookup' \
'  (global-name "com.apple.coreservices.launchservicesd")' \
'  (global-name "com.apple.coreservices.quarantine-resolver"))' \
'(deny appleevent-send)' \
'(deny mach-priv-task-port)' \
'(deny signal (target others))' \
''
}

run_macos() {
    script_dir="$(dirname "$script_path")"
    script_name="$(basename "$script_path")"
    script_name="${script_name%.*}"
    app_dir="$script_dir/$script_name"
    mkdir -p "$app_dir" 2>/dev/null

    # The profile is built here and applied by the driver, and the order is the
    # whole of this change.
    #
    # It used to be `exec sandbox-exec -p "$profile" osascript`, so osascript
    # started already confined. On macOS 26 that costs the window. AppKit
    # registers a process as an application through LaunchServices, and this
    # profile denies com.apple.coreservices.launchservicesd -- deliberately,
    # because that is half of what closes the write-a-bundle-and-launch-it
    # escape. Under it NSApp.setActivationPolicy(Regular) returns false and the
    # process never enters the application list: it runs, its WKWebView renders,
    # its page's own probe reports back, and nothing appears on screen. Measured
    # against the same artifact with no profile, which registers policy=0 and
    # shows its window.
    #
    # There is no way to fix that from out here. So the profile goes to the
    # driver instead, which registers with LaunchServices first and applies this
    # to itself immediately afterwards -- before it reads a theme, opens a
    # window or loads a line of the app's document. See createMacDriver's init.
    #
    # Nothing is given up by moving it. This function is part of the artifact,
    # so an artifact that did not want to be confined has always been able to
    # ship without it; the launcher's layer was cooperative before this change
    # and is cooperative after it. The layer that is not -- netinstall's -- is
    # applied by a binary the artifact does not write, and it stays exactly
    # where it was.
    #
    # The variable is set on the exec line rather than exported, and it is set
    # unconditionally, so a value inherited from outside cannot survive to be
    # read as this launch's profile.
    profile="$(nt_macos_profile "$app_dir")"

    # An empty profile means this shell could not produce the text -- the
    # here-document failure this file's header describes was exactly that. The
    # driver would have nothing to apply, so say which of the two happened here
    # rather than leaving it to a note about sandbox_init.
    if [ -z "$profile" ]; then
        echo "neutrino: could not build the seatbelt profile; running unconfined" >&2
        NEUTRINO_SCRIPT_PATH="$script_path" exec osascript -l JavaScript "$script_path"
    fi

    NEUTRINO_SCRIPT_PATH="$script_path" NEUTRINO_MACOS_PROFILE="$profile" \
        exec osascript -l JavaScript "$script_path"
}
