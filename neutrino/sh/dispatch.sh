# The engine search, and what it costs is the thing that shaped it.
#
# It used to name one binary. `command -v gjs` succeeded or the file went
# looking for Qt, and on a Cinnamon desktop -- where the interpreter is called
# cjs, and Gtk 3.0 and WebKit2 4.1 are both installed and working -- neither
# branch was taken and nobody got a window. The launcher was refusing a machine
# that could run it, over a name.
#
# Widening a name list is free. Every test below is `command -v`, which is a
# builtin: a desktop carrying the first candidate does exactly what it did
# before this paragraph was written, and one carrying the fourth pays three
# more lookups and no processes at all. What is emphatically not free is asking
# each candidate whether it *works* before choosing it, because that is an
# interpreter start per candidate on every launch, paid by every machine, to
# answer a question almost none of them have.
#
# So the engine is not probed. It is started, and it says. 69 is EX_UNAVAILABLE
# and it means this lane could not reach its engine -- reported by the lane
# itself, after looking, and before it has created anything. A gjs with no
# WebKit2 typelib exits 69 here where it used to print a traceback and take the
# whole launch down with it; the walk moves on and finds the qml6 that was
# sitting there the entire time.
#
# The status is not forgeable by an app. Nothing on the IPC surface -- resize,
# move, close, openExternal -- sets an exit code, so an app that fails on its
# own says so with its own status and the walk stops. That distinction is the
# difference between falling through to the next engine and running someone
# else's program a second time.
nt_ex_noengine=69

# A bundled caller (snap, flatpak, AppImage, ...) may export GLib/GTK loader
# overrides pointing at its own libraries, which then get loaded against the
# system glibc and crash. Cleared for the lanes that load GTK, which is now
# three of them rather than one -- PyGObject loads the same GTK a JavaScript
# interpreter does.
#
# This is a compatibility rule and it predates the scrub above, which now
# covers all but two of these by shape. Kept whole rather than reduced to its
# remainder: the two it still adds -- GSETTINGS_SCHEMA_DIR and LOCPATH -- name
# data and not code, so they are not the scrub's to take, and a crash is a good
# enough reason to drop them on its own.
nt_unset_gtk_loaders() {
    unset GTK_PATH GTK_EXE_PREFIX GTK_IM_MODULE_FILE \
          GDK_PIXBUF_MODULE_FILE GDK_PIXBUF_MODULEDIR \
          GIO_MODULE_DIR GSETTINGS_SCHEMA_DIR LOCPATH \
          LD_PRELOAD LD_LIBRARY_PATH
}

# Upstream before the fork, and the plain name before the -console spelling,
# which is the order in which a machine that has more than one of them should
# be read. cjs is Cinnamon's fork of gjs and needs nothing from the JavaScript
# below: run() dispatches on imports.gi, which it has, and its programPath is
# an absolute path when it is handed a script.
#
# The clearing happens inside a subshell so that the variables go to the engine
# and not to this shell, which still has Qt and Python ahead of it.
for nt_engine in gjs gjs-console cjs cjs-console; do
    command -v "$nt_engine" >/dev/null 2>&1 || continue
    ( nt_unset_gtk_loaders
      NEUTRINO_SCRIPT_PATH="$script_path" exec "$nt_engine" "$script_path" )
    nt_status=$?
    # 127 as well as the reserved status: `command -v` found a name, and a name
    # that cannot be executed -- a dangling symlink, a wrapper pointing at an
    # interpreter that was removed -- is this lane being unavailable too, said
    # by the kernel instead of by the engine.
    [ "$nt_status" = "$nt_ex_noengine" ] || [ "$nt_status" = 127 ] || exit "$nt_status"
done

# Above Qt and python3 both, and that ordering is the whole reason a Mac never
# pays for either lane after it: osascript is always present there, so the walk
# stops here; on Linux osascript never exists, so the miss is a builtin lookup
# and Qt is reached immediately. The rule was already written for python3 and
# this is the same sentence with one more lane inside it.
#
# It moved above Qt because a Mac that reached Qt got no window at all, and not
# because the lane is merely unlikely there. run_qt hands the engine a document
# with no name: it creates one, unlinks it, and reopens the descriptor through
# /dev/fd or /proc/self/fd. Linux's /proc/self/fd/N is a symlink to the file, so
# reopening it is a fresh open of the inode at offset zero. macOS's /dev/fd/N is
# a *dup* of the descriptor, and both halves of that break this:
#
#   - fd 8 is opened write-only, so /dev/fd/8 is mode --w-------, the `[ -r ]`
#     test fails and there is nothing to hand over. Measured: the lane prints
#     "cannot hand the engine a document without a name here" and returns.
#   - opening 8 read-write instead gets past that and still does not work: a dup
#     shares the file offset, which is at end-of-file after the document is
#     written, so the engine reads nothing. `set -C` also does not cover `<>` --
#     measured, it followed a planted symlink and created its target -- so that
#     spelling would trade the whole planted-document defence for a lane that
#     still does not run.
#
# So there is no macOS Qt lane to lose, and the Qt lane's own QT_QPA_PLATFORM
# default of xcb says the same thing more quietly. What was actually happening
# is that find_qt_runtime succeeded on any Mac with Homebrew's qt installed,
# run_qt failed, and the walk exited with its status instead of reaching the
# lane that works. test/lanes.sh asserts the order.
if command -v osascript >/dev/null 2>&1
then run_macos
fi

if qt_runner="$(find_qt_runtime)"
then
    run_qt "$qt_runner"
    nt_status=$?
    [ "$nt_status" = "$nt_ex_noengine" ] || exit "$nt_status"
fi

if command -v python3 >/dev/null 2>&1
then
    run_pygobject
    nt_status=$?
    [ "$nt_status" = "$nt_ex_noengine" ] || exit "$nt_status"
fi

# Non-zero, and it took a while to notice it was not. The last command in this
# branch used to be the echo, so `exit $?` on the seam below exited 0 -- a
# launch that opened no window at all reporting success to whoever started it.
# Under netinstall that is worse than cosmetic: nt_exec execs /bin/sh on the
# script it just downloaded and verified, so the whole fetch-verify-launch
# cycle came back successful with nothing on screen and no non-zero status
# anywhere in it to notice.
echo "neutrino: no runtime here can open a window (looked for gjs, cjs, a Qt QML runtime, osascript, and python3 with PyGObject)" >&2
exit 1
