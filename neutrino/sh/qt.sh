find_qt_runtime() {
    for cmd in qml6 qml; do
        if command -v "$cmd" >/dev/null 2>&1; then
            command -v "$cmd"
            return 0
        fi
    done
    # Not every distribution puts the QML runtime on PATH, and the ones that do
    # not do not agree on where it goes instead: Fedora uses lib64, Arch and
    # openSUSE the unsuffixed directory, and Debian and Ubuntu hang it off the
    # multiarch one. Globbing costs no process -- an unmatched pattern stays
    # literal and fails -x like any other missing path -- so there is no reason
    # for this list to be the narrowest part of the function.
    for path in /usr/lib/qt6/bin/qml /usr/lib64/qt6/bin/qml; do
        if [ -x "$path" ]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    # The multiarch directory is walked rather than named with a pattern that
    # reaches through it, and that is not a matter of taste. Everything from the
    # top of this file down to the document is one JavaScript block comment, so
    # a star followed by a slash anywhere in the shell region ends the comment
    # early and every line after it is parsed as code -- the hazard the scrub
    # above already has a paragraph about. Writing the wildcard as its own path
    # component keeps the two characters apart; test/parse.sh is what caught it
    # being written the other way.
    for path in /usr/lib/*; do
        if [ -x "$path/qt6/bin/qml" ]; then
            printf '%s\n' "$path/qt6/bin/qml"
            return 0
        fi
    done
    return 1
}

# The QML engine's document, and the fact that it has no name.
#
# It used to be two files -- window.qml and a `.pragma library` neutrino.js --
# written into app_dir, the one directory the sandbox makes writable and, under
# netinstall, the app's own. Three things were measured on a runner, each with
# the window up and the launch looking normal from outside:
#
#   - a planted neutrino.js this run could not overwrite ran anyway; the `cat`
#     failed with `Permission denied` and nothing looked at the status
#   - a planted window.qml ran as an entirely different program under the same
#     title
#   - a file this run *did* write, replaced between the write and the engine's
#     open, ran as well
#
# The third is why checking the write would not have been the fix. PR 7 met the
# same shape on macOS and answered it by putting the seatbelt profile on
# sandbox-exec's command line; qml has no -p, and it refuses a pipe outright --
# `file:///dev/stdin: File is empty` -- because the engine wants a sized,
# seekable file.
#
# An unlinked one is exactly that. The document is created under `set -C`, so a
# name planted in advance -- a symlink included -- makes the create fail rather
# than be followed; it is unlinked immediately; and the engine is handed a path
# into this shell's own descriptors. Whatever anyone puts at the name afterwards
# is a different inode, and the name is gone before the first byte is written.
#
# One document rather than two, because a relative import has nowhere to resolve
# from once there is no directory. What neutrino.js contributed is inline below,
# and the source it used to eval under `.pragma library` is evaluated in a
# Function body instead, with NeutrinoQml handed in as a parameter so the
# source's own dispatch still finds it.

# A path becomes a JavaScript string literal here, which is what nt_sbquote does
# for the seatbelt profile. Measured before this existed: a directory named
# `A");console.warn(...` closed the string and ran the statement after it. The
# newline case is folded rather than escaped away because a raw one ends the
# literal and takes the document with it.
nt_qmlquote() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
        awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

run_qt() {
    qml_runner="$1"
    [ -z "$qml_runner" ] && return 1

    script_dir="$(dirname "$script_path")"
    script_name="$(basename "$script_path")"
    script_name="${script_name%.*}"
    app_dir="$script_dir/$script_name"
    mkdir -p "$app_dir" || return 1

    # Somewhere to create the inode, and app_dir rather than a temporary
    # directory because under netinstall it is the only place a write is
    # granted. The name exists for one line.
    #
    # The directory is what gets tested, not the name: a probe that opens the
    # name to see whether it can be written would follow a symlink planted
    # there and truncate whatever it points at, which is a worse thing to do
    # than the bug this is fixing.
    [ -w "$app_dir" ] || {
        echo "neutrino: cannot write $app_dir" >&2
        return 1
    }

    # `set -C` is doing the work here: with it, creating the document fails
    # outright if the name already exists or is a symlink, rather than opening
    # whatever is on the other end. Two shells then answer a failed `exec`
    # redirection differently -- one exits, the other carries on with the
    # descriptor unopened -- and both are fine, because every path from here
    # ends at the refusal below and not at a document written where it could
    # be replaced.
    qml_doc="$app_dir/.window.$$.qml"
    set -C
    exec 8>"$qml_doc"
    set +C
    rm -f "$qml_doc"

    qml_url="file://$(nt_qmlquote "$script_path")"
    # Unquoted, and it has to be: the QML below reads $qml_url, which is this
    # shell's variable and the only way the document learns where to fetch its
    # own source from. So the shell expands what follows -- which means **no
    # backticks in the QML region**, in a comment least of all.
    #
    # That is not a style rule. A backtick pair here is a command substitution
    # run at launch, and the five that used to sit in the comments below were
    # each running a word -- `window`, `base`, `title` -- and writing "command
    # not found" to stderr on every start. Harmless, until a comment quoted
    # `<a target=_blank>` and the shell read `<a` and a trailing `>` as
    # redirections: syntax error, unexpected end of file, in the artifact
    # itself. Three lanes went red for it and none of them was Qt's -- gjs and
    # windows-launch could not parse the built .cmd at all.
    cat >&8 <<QMLEOF
@@include qml/window.qml
QMLEOF

    # Reopened read-only from the descriptor, and the write handle closed before
    # the engine starts: from here on nothing on this machine holds the inode
    # open for writing and nothing can reach it by name at all. /dev/fd first
    # because it is the spelling more than one kernel has; both were measured
    # working on the lane that runs this.
    #
    # "More than one kernel" is not every kernel, and the two spellings are not
    # the same mechanism. Linux's /proc/self/fd/N is a symlink to the file, so
    # opening it is a fresh open of the inode at offset zero -- which is what
    # this wants. macOS's /dev/fd/N is a dup of the descriptor: it carries fd
    # 8's write-only mode, so the `[ -r ]` below is false and the hand-off does
    # not happen at all. dispatch.sh no longer reaches this on macOS for that
    # reason, and it is written here as well because this loop is where the
    # assumption lives.
    qml_fd=""
    for qml_fddir in /dev/fd /proc/self/fd; do
        if [ -r "$qml_fddir/8" ] && exec 9<"$qml_fddir/8"; then
            qml_fd="$qml_fddir/9"
            break
        fi
    done
    exec 8>&-
    if [ -z "$qml_fd" ]; then
        # The reserved status and not 1, which is the difference between this
        # lane being unavailable and the whole launch being over. Nothing has
        # been created that outlives this function -- the document is already
        # unlinked and the descriptor is closed -- and no engine has been
        # started, which is exactly the condition dispatch.sh's 69 is defined
        # for. Returning 1 made a kernel whose /dev/fd cannot do this take the
        # launcher down with it rather than move it to the next lane, and on
        # macOS that meant a machine with Homebrew's qt got no window while a
        # working osascript sat two lines below.
        echo "neutrino: cannot hand the engine a document without a name here" >&2
        return "$nt_ex_noengine"
    fi

@@include sh/qt-sandbox.sh

    QML_XHR_ALLOW_FILE_READ=1 \
    QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}" \
    LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}" \
    QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS:---disable-dev-shm-usage}" \
    "$qml_runner" "$qml_fd"
}

