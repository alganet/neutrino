# macOS, unconfined, which is what a build without the tight overlay is.
#
# The seatbelt profile and everything that applies it are in that overlay's copy
# of this file: a profile string, sandbox-exec, and the two fallbacks for a
# macOS that will not take the profile. None of it is in a release artifact,
# where it used to sit below a `has_tier tight` that returned first.
#
# Confining a process is the app author's decision at assembly and not the
# launcher's at run time, which is the whole reason this is a file rather than
# a branch.
run_macos() {
    NEUTRINO_SCRIPT_PATH="$script_path" exec osascript -l JavaScript "$script_path"
}
