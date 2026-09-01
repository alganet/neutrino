# The seatbelt profile, and the launch that applies it. This whole file is the
# tight tier on macOS: a build assembled without this overlay has none of it --
# not the profile, not sandbox-exec, and not the two fallbacks below.
#
# It used to be one `if ! has_tier tight` at the top of run_macos, with every
# line of it shipped in every artifact and skipped at launch.

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
