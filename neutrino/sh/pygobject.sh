# The lane of last resort, and the reason it is worth having is that it
# implements nothing.
#
# python3 with PyGObject is on far more Linux machines than any GI-capable
# JavaScript interpreter is -- it is what the desktop's own tooling is written
# in -- but this file is JavaScript, and a Python driver that re-derived
# extractHtmlDocument, parseMessage and mayOpenExternal
# would be a second copy of every decision the other three lanes share. Two
# copies of a content policy is one copy that is wrong, and test/parse.sh
# exists because this project has already paid for cross-engine divergence.
#
# It does not need one. JavaScriptCore ships with WebKitGTK -- the same source
# package as the WebKit2 typelib this lane already requires, so it is present
# wherever the lane can run at all -- and it is a JavaScript engine reachable
# through introspection. So Python does what the QML document does: it
# evaluates this file's own source, keeps the NeutrinoWebview object, and calls
# into it for every decision. What is written in Python is toolkit calls and
# nothing else.
#
# The document is shipped the way run_qt ships its QML, and the paragraphs
# there are the reasons: a planted window.qml ran as an entirely different
# program under a launch that looked normal from outside, and a planted
# read-only one could not be overwritten and ran anyway with the failure on
# stderr that nothing looked at. Same inode-with-no-name, same set -C, same
# refusal if no descriptor spelling works.
run_pygobject() {
    script_dir="$(dirname "$script_path")"
    script_name="$(basename "$script_path")"
    script_name="${script_name%.*}"
    app_dir="$script_dir/$script_name"
    mkdir -p "$app_dir" || return 1

    # The directory is what gets tested, not the name: a probe that opened the
    # name to see whether it could be written would follow a symlink planted
    # there and truncate whatever it points at.
    [ -w "$app_dir" ] || {
        echo "neutrino: cannot write $app_dir" >&2
        return 1
    }

    py_doc="$app_dir/.window.$$.py"
    set -C
    exec 8>"$py_doc"
    set +C
    rm -f "$py_doc"

    cat >&8 <<'PYGIEOF'
@@include py/shim.py
PYGIEOF

    # Reopened read-only from the descriptor and the write handle closed before
    # the interpreter starts: from here on nothing holds the inode open for
    # writing and nothing can reach it by name at all.
    py_fd=""
    for py_fddir in /dev/fd /proc/self/fd; do
        if [ -r "$py_fddir/8" ] && exec 9<"$py_fddir/8"; then
            py_fd="$py_fddir/9"
            break
        fi
    done
    exec 8>&-
    if [ -z "$py_fd" ]; then
        echo "neutrino: cannot hand the engine a document without a name here" >&2
        return 1
    fi

    # -I and -B, and neither is decoration. -I makes the interpreter ignore
    # PYTHONPATH, PYTHONHOME and the user site directory, and stops sys.path[0]
    # from becoming the descriptor's directory -- the scrub above already takes
    # that namespace, and this is the same answer said again by the program
    # that reads it, which is what "measured rather than remembered" means when
    # the two mechanisms are independent. -B writes no bytecode, because under
    # netinstall the app directory is the only writable place there is and a
    # cache written into it is a file the next launch reads back.
    nt_unset_gtk_loaders
    NEUTRINO_SCRIPT_PATH="$script_path" python3 -I -B "$py_fd"
}

