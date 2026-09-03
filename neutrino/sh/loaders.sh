# Every name a toolkit reads as "open this file", "run this program" or "do not
# sandbox yourself", removed before any engine is launched.
#
# Under netinstall this is env.c's job and it does it with an allowlist. There
# is no netinstall here: standalone, this file hands the engine whatever it was
# given, and measurement says what that means. As shipped, GTK_MODULES loads a
# file of the caller's choosing into the gjs process; WEBKIT_INJECTED_BUNDLE_PATH
# loads one into the WebKitWebProcess, the process holding page content;
# GIO_EXTRA_MODULES loads into that and the network process; LD_AUDIT loads
# everywhere, engine included; and on the Qt branch nothing was removed at all,
# so QTWEBENGINE_CHROMIUM_FLAGS chose the program the renderer ran. Each of
# those is a measurement in test/loaders.sh, not a worry.
#
# Two of them are worse than a load, because they undo a decision this file
# makes on purpose. neutrino_webkit_sandbox below runs bubblewrap to find out
# whether WebKitGTK can be sandboxed and says of the answer that it is "never
# defaulted from the environment". It is not -- and
# WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS turned the sandbox off anyway,
# measured by the absence of a bwrap process under a launch that still came up.
# QTWEBENGINE_DISABLE_SANDBOX does the same to Chromium's.
#
# Matched by shape, not by name, which is PR 9's rule and for its reason: a list
# of the names measured would be right today and wrong the first time a toolkit
# grows a knob. The shapes are env.c's, so the two files agree by construction
# rather than by anyone remembering to edit both.
#
# Two things bound it, and both are the reason it is safe to apply to a whole
# environment rather than to an allowlisted one:
#
#   - LD_, DYLD_ and PYTHON go wholesale. The first two are dynamic-linker
#     machinery and there is nothing in them to keep. PYTHON is taken whole for
#     a different reason: the same three hazards live in it under spellings the
#     shape list does not have. PYTHONPATH chooses what the interpreter
#     imports, PYTHONHOME moves the entire installation somewhere else, and
#     PYTHONSTARTUP names a file it executes before the program -- and only the
#     first of those matches a shape below. Nothing in that namespace carries
#     data or a mode this file needs to arrive, so the namespace goes rather
#     than the shape list growing two entries that exist to catch one runtime.
#   - Everything else is tested only inside a namespace a toolkit owns. XDG_ is
#     deliberately not one of them: a session sets XDG_SESSION_PATH and
#     XDG_SEAT_PATH, both of which match "PATH" and neither of which names code,
#     and XDG_RUNTIME_DIR is where the display socket lives. Measured on a real
#     desktop, not reasoned about.
#
# What must still arrive is asserted too, and that is half the rule: DISPLAY,
# GDK_BACKEND, XDG_RUNTIME_DIR, QT_QPA_PLATFORM, LIBGL_ALWAYS_SOFTWARE and the
# locale all carry data or a mode rather than a file, and a rule that took the
# namespaces outright would satisfy every "is removed" check and leave a window
# that never opens.
nt_scrub_loaders() {
    # The names, collected before anything is removed.
    #
    # An environment value may contain a newline, so a walk over `env` output
    # sees lines that are not entries. sed is what makes that harmless: only a
    # line shaped like a variable name yields one, and a forged line can name
    # nothing outside the set being removed anyway. It is also why this is not
    # a here-document -- a value holding the terminator would end the walk
    # early and leave every name after it in place, which is a scrub an
    # attacker gets to stop. A `for` over names cannot be stopped, and names
    # have no character word-splitting or globbing would touch.
    nt_name=""
    # The trailing $ is not decoration. Everything from this file's first line
    # down to the document below is one JavaScript block comment, so a star
    # followed by a slash anywhere in the shell region closes it early and the
    # rest of the file is parsed as code -- which is what a regex ending
    # ".*" then "/" does. Anchoring with $ first is how the line above
    # already avoids it, and test/parse.sh asserts the region contains none.
    #
    # Two sequences, not one. The other is the document's doctype: it is where
    # both halves of this file are cut from, so a line up here that merely names
    # it starts the cut in the shell region -- and a document whose content
    # policy is no longer inside its own <head> is one four engines do not
    # enforce and no page can tell apart from one they do. Naming the script tag
    # up here is harmless now; naming the doctype is not. Both hazards cost a CI
    # round each, and both are checks rather than things to remember: the
    # launcher refuses a source with two of them, and test/parse.sh says so
    # before it gets that far.
    nt_names="$(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*$/\1/p')"
    for nt_name in $nt_names; do
        case "$nt_name" in
            LD_*|DYLD_*|PYTHON*) ;;
            GTK_*|GDK_*|GIO_*|GSETTINGS_*|GI_*|GJS_*|GST_*|QT_*|QTWEBENGINE_*|\
            QML_*|QML2_*|WEBKIT_*|LIBGL_*|MESA_*|EGL_*|VK_*)
                case "$nt_name" in
                    *MODULE*|*PLUGIN*|*PRELOAD*|*LIBRAR*|*LAYER*|*DRIVER*|*ICD*|\
                    *BUNDLE*|*SANDBOX*|*EXEC*|*LAUNCH*|*PROFIL*|*FLAGS*|*ARGS*|\
                    *PATH*|*PREFIX*|*AUDIT*) ;;
                    *) continue ;;
                esac ;;
            *) continue ;;
        esac
        unset "$nt_name" 2>/dev/null
    done
    unset nt_name nt_names
}

@@include sh/qt-sandbox-env.sh
nt_scrub_loaders

