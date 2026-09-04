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

    # Two sentences, because they were one and the one was wrong. An empty
    # profile means this shell could not produce the text -- the here-document
    # failure above was exactly that -- and seatbelt was never asked. Saying
    # "seatbelt rejected the profile" for it sent the reading of a shell bug to
    # the sandbox, which is the one place it was not.
    if [ -z "$profile" ]; then
        echo "neutrino: could not build the seatbelt profile; running unconfined" >&2
        NEUTRINO_SCRIPT_PATH="$script_path" exec osascript -l JavaScript "$script_path"
    fi

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
    if ! /usr/bin/sandbox-exec -p "$profile" /usr/bin/true >/dev/null 2>&1; then
        # Seatbelt sometimes does not nest, and the failure above cannot say
        # whether that is what happened. A process inside a profile applied by
        # sandbox-exec cannot apply a second one: sandbox_apply returns EPERM
        # for *any* profile there, `(version 1)(allow default)` included --
        # and that one cannot be rejected on its merits, so it separates "this
        # process may not confine itself at all" from "this profile is bad".
        #
        # Which is not netinstall, and that distinction cost a wrong reading
        # before it was measured. netinstall confines itself with
        # sandbox_init_with_parameters and then execs the launcher, and a
        # sandbox-exec after *that* is accepted: the launcher applies this
        # profile on top of netinstall's, and netinstall/test/e2e.sh asserts
        # the silence that says so. The two SPIs do not answer the same way.
        # So this branch is for an outer profile that came from sandbox-exec
        # -- somebody wrapping the artifact in one of their own -- and under
        # the downloader it should never be reached.
        #
        # The probe is on the failure path alone, so a launch that confines
        # itself pays nothing for it, and it is a measurement rather than a
        # marker in the environment. A marker would be the downgrade the
        # paragraph above refuses: anything that can set a variable could
        # then tell a standalone artifact it was already confined and get it
        # to skip its own profile.
        if ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' \
                /usr/bin/true >/dev/null 2>&1; then
            echo "neutrino: already inside a seatbelt profile; not nesting" >&2
        else
            echo "neutrino: seatbelt rejected the profile; running unconfined" >&2
        fi
        NEUTRINO_SCRIPT_PATH="$script_path" exec osascript -l JavaScript "$script_path"
    fi

    NEUTRINO_SCRIPT_PATH="$script_path" exec /usr/bin/sandbox-exec -p "$profile" \
        osascript -l JavaScript "$script_path"
}
