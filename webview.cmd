if (":" == "<!--") then : 0 /*\;:\
@ECHO OFF||:;fi;:||REM<<'EXIT'
GOTO :W
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
SPDX-License-Identifier: ISC
:W
FOR /F %%E IN ('ECHO PROMPT $E ^| CMD') DO SET "ESC=%%E"
<NUL SET /P =[1A[K[1A
SETLOCAL ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION
SET "SCRIPT_NAME=%~n0"
SET "SCRIPT_DIR=%~dp0"
SET "APP_FOLDER=%SCRIPT_DIR%%SCRIPT_NAME%"
SET "FX_DIR=%WINDIR%\Microsoft.NET\Framework\v4.0.30319"
SET "JSC=%FX_DIR%\jsc.exe"
SET "WEBVIEW2_ROOT=%APP_FOLDER%\Microsoft.Web.WebView2"

IF NOT EXIST "%JSC%" (
    SET "FX_DIR=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319"
    SET "JSC=%FX_DIR%\jsc.exe"
)

IF NOT EXIST "%JSC%" ( EXIT /B 1 )

SET "FIRST_RUN="
IF NOT EXIST "%APP_FOLDER%" (
    SET "FIRST_RUN=1"
    MKDIR "%APP_FOLDER%"
    IF ERRORLEVEL 1 EXIT /B 1
)

REM The app folder outlives any single version of this script, and everything
REM running as this user can write it -- so an exe found sitting there is not
REM evidence of anything. This used to reuse one whenever a stamp beside it, the
REM source's size and modification time, still matched. Measured on a runner: an
REM exe replaced in place with the stamp left exactly as this file wrote it was
REM launched, and went on being launched until the source itself changed. The
REM stamp is as writable as the exe it vouches for, and the digest netinstall
REM pins covers the .cmd and not the artifact compiled out of it.
REM
REM So it compiles every launch. 340 ms measured against the 86 ms the reuse
REM cost, which is the price of the thing that runs being the thing just built
REM from the source that was verified. What is left is the gap between the
REM compile and the START at the end -- cmd cannot hand CreateProcess a handle
REM the way the Qt path hands qml a descriptor -- and that is a race rather
REM than an implant that outlives every launch.
REM
REM Compiled under another name and rotated into place, because a running
REM instance holds its own exe open: Windows refuses to overwrite that file but
REM allows it to be renamed, which is what keeps a second window openable.
SET "APP_EXE=%APP_FOLDER%\%SCRIPT_NAME%.exe"
SET "APP_NEW=%APP_FOLDER%\%SCRIPT_NAME%.new%RANDOM%%RANDOM%.exe"
SET "APP_OLD=%APP_FOLDER%\%SCRIPT_NAME%.old%RANDOM%%RANDOM%.exe"
SET "MANIFEST=%APP_EXE%.manifest"
DEL /Q "%APP_FOLDER%\%SCRIPT_NAME%.new*.exe" >NUL 2>&1
DEL /Q "%APP_FOLDER%\%SCRIPT_NAME%.old*.exe" >NUL 2>&1
DEL /Q "%APP_FOLDER%\%SCRIPT_NAME%.stamp" >NUL 2>&1

REM Only on a genuinely first run. A cold .NET start makes that compile seconds
REM rather than the third of one every launch after it costs.
IF NOT DEFINED FIRST_RUN GOTO :COMPILE

SET "MSG=Your application is getting ready to run for the first time..."
SET "N=0"
FOR /F "tokens=2 delims=:" %%A IN ('MODE CON ^| FINDSTR [0-9]') DO (
    SET /A N+=1
    IF !N!==1 SET /A ROWS=%%A
    IF !N!==2 SET /A COLS=%%A
)
SET /A HALF_ROW=ROWS / 2
SET /A PAD="(COLS - 62) / 2"
SET "SPACES="
FOR /L %%I IN (1,1,!PAD!) DO SET "SPACES=!SPACES! "
CLS
<NUL SET /P =[!HALF_ROW!;1H!SPACES!!MSG!

:COMPILE
"%JSC%" /nologo /debug- /t:winexe /out:"%APP_NEW%" ^
    /autoref+ ^
    /lib:"%FX_DIR%" ^
    /r:"%FX_DIR%\mscorlib.dll" ^
    /r:"%FX_DIR%\System.dll" ^
    /r:"%FX_DIR%\System.Configuration.dll" ^
    /r:"%FX_DIR%\Accessibility.dll" ^
    /r:"%FX_DIR%\System.Drawing.dll" ^
    /r:"%FX_DIR%\System.Windows.Forms.dll" ^
    "%~f0"
    SET "JSC_EXIT=%ERRORLEVEL%"
    IF NOT "%JSC_EXIT%"=="0" EXIT /B %JSC_EXIT%

REM Renaming a running exe is allowed where overwriting it is not, so an
REM earlier instance keeps its own file under a name the next launch deletes.
IF EXIST "%APP_EXE%" MOVE /Y "%APP_EXE%" "%APP_OLD%" >NUL 2>&1
MOVE /Y "%APP_NEW%" "%APP_EXE%" >NUL
IF ERRORLEVEL 1 EXIT /B 1

> "%MANIFEST%" (
    ECHO ^<?xml version="1.0" encoding="UTF-8" standalone="yes"?^>
    ECHO ^<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"^>
    ECHO   ^<assemblyIdentity version="1.0.0.0" processorArchitecture="*" name="neutrino.webview" type="win32" /^>
    ECHO   ^<description^>neutrino webview^</description^>
    ECHO   ^<compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"^>
    ECHO     ^<application^>
    ECHO       ^<supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}" /^>
    ECHO       ^<supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}" /^>
    ECHO       ^<supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}" /^>
    ECHO       ^<supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}" /^>
    ECHO       ^<supportedOS Id="{e2011457-1546-43c5-a5fe-008deee3d3f0}" /^>
    ECHO     ^</application^>
    ECHO   ^</compatibility^>
    ECHO   ^<application xmlns="urn:schemas-microsoft-com:asm.v3"^>
    ECHO     ^<windowsSettings^>
    ECHO       ^<dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings"^>true/pm^</dpiAware^>
    ECHO       ^<dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings"^>PerMonitorV2, PerMonitor^</dpiAwareness^>
    ECHO     ^</windowsSettings^>
    ECHO   ^</application^>
    ECHO ^</assembly^>
)

SET "NEUTRINO_SCRIPT_PATH=%~f0"
START "" /D "%APP_FOLDER%" "%APP_EXE%"
IF ERRORLEVEL 1 EXIT /B 1
EXIT /B 0
EXIT
script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# The tier list lives in exactly one place, the JavaScript region below, where
# build.sh stamps it. Reading it back out of the file rather than taking it from
# the environment means the shell and the JavaScript cannot disagree, and means
# no caller can weaken a build by exporting something.
neutrino_tiers="$(sed -n 's/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$script_path" | head -1)"
[ -z "$neutrino_tiers" ] && neutrino_tiers="default"
has_tier() { case ",$neutrino_tiers," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

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
#   - LD_ and DYLD_ go wholesale. Every name in them is dynamic-linker
#     machinery; there is nothing in there to keep.
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
    # ".*" then "/" does. Anchoring with $ first is how the tier line above
    # already avoids it, and test/parse.sh asserts the region contains none.
    #
    # Two sequences, not one: the opening tag of that document is also the
    # first one extractPageScript finds, so naming it here in prose moves the
    # start of the page script two hundred lines up. Both hazards cost a CI
    # round each, and both are now checks rather than things to remember.
    nt_names="$(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*$/\1/p')"
    for nt_name in $nt_names; do
        case "$nt_name" in
            LD_*|DYLD_*) ;;
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

# Read before the scrub takes it, and used only by a testing build. CI cannot
# start Chromium in its container without it, and a release build has no way to
# reach this: the tier is stamped into the file, not taken from the caller.
neutrino_qt_disable_sandbox="${QTWEBENGINE_DISABLE_SANDBOX:-}"
nt_scrub_loaders

find_qt_runtime() {
    for cmd in qml6 qml; do
        if command -v "$cmd" >/dev/null 2>&1; then
            command -v "$cmd"
            return 0
        fi
    done
    for path in /usr/lib/qt6/bin/qml; do
        if [ -x "$path" ]; then
            printf '%s\n' "$path"
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
    cat >&8 <<QMLEOF
import QtQuick
import QtWebEngine

Window {
    id: root

    // The polyglot's own source, read once, by XHR rather than by import:
    // this document has no directory for an import to resolve against, which
    // is the point of it.
    readonly property string ntSource: ntRead()
    readonly property var nt: ntBuild(ntSource)
    readonly property var cfg: nt.config

    // Encoded for the same reason the Windows title is: a record separator is
    // a control character, and a console message is a diagnostic channel that
    // nothing promises will carry one through Chromium and out the other side
    // unchanged.
    readonly property string ntPreload: nt.buildPreloadScript(
        'function(m){console.log("__NEUTRINO__"+encodeURIComponent(m));}',
        "console")

    visible: true
    title: cfg.title + " - Qt"

    function ntRead() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "$qml_url", false)
        xhr.send()
        return xhr.responseText
    }

    // A Function body is the scope .pragma library used to provide. The flag
    // the source dispatches on goes in as a parameter, so nothing it defines
    // arrives as a global of this document's.
    function ntBuild(src) {
        return (new Function("NeutrinoQml", src + "; return NeutrinoWebview;"))(true)
    }

    function ntRoute(raw) {
        var msg = root.nt.parseMessage(raw)
        if (!msg) {
            console.warn("neutrino: refused a malformed record")
            return
        }
        if (msg.action === "setTitle") root.title = msg.title
        else if (msg.action === "resize") { root.width = msg.width; root.height = msg.height }
        else if (msg.action === "move") { root.x = msg.x; root.y = msg.y }
        else if (msg.action === "close") root.close()
        else if (msg.action === "openExternal") Qt.openUrlExternally(msg.url)
    }

    Component.onCompleted: {
        root.width = cfg.width
        root.height = cfg.height
        root.x = (Screen.width - root.width) / 2
        root.y = (Screen.height - root.height) / 2
    }

    WebEngineView {
        id: view
        anchors.fill: parent
        property bool preloadInjected: false
        property bool documentLoaded: false
        property bool contentLoaded: false
        onLoadingChanged: function(info) {
            if (info.status === WebEngineView.LoadSucceededStatus) {
                if (!preloadInjected) {
                    preloadInjected = true
                    // Before the injection, not after: from the next line on
                    // there is page script in this view that can send.
                    root.nt.rememberTrustedView(view.url)
                    // The API first, then the page's own code. Both are handed
                    // to the engine rather than carried by the document, which
                    // is what lets the document forbid script of its own.
                    view.runJavaScript(root.ntPreload)
                    view.runJavaScript(root.nt.extractPageScript(root.ntSource))
                }
                view.documentLoaded = true
            }
        }
        onJavaScriptConsoleMessage: function(level, message, lineNumber, sourceID) {
            if (String(message).indexOf("__NEUTRINO__") !== 0) {
                // Overriding this signal replaces Qt's own handler, so without
                // this every error the page reports goes nowhere and a broken
                // document looks identical to a silent one.
                console.warn("neutrino page: " + message + " (" + sourceID + ":" + lineNumber + ")")
                return
            }
            // The sender check. Qt routes a console message from whatever
            // document is loaded, and this is the only thing that asks which
            // one that is.
            if (!root.nt.isTrustedView(view.url)) {
                root.nt.note(
                    "refused a message from a document the view was not given")
                return
            }
            root.ntRoute(decodeURIComponent(String(message).substring(12)))
        }
        // The document is loaded once, from this file, and never navigates
        // again. Without this a link or a script assignment could replace it
        // with a remote origin, and that origin would then be holding the
        // channel to the native window. http and https go to the desktop's
        // handler instead, which is what a user clicking a link expects;
        // everything else is refused, including file: and the schemes the
        // platform keeps inventing.
        onNavigationRequested: function(request) {
            var target = String(request.url)
            if (root.nt.isOwnDocument(target)) {
                return
            }
            // QtWebEngine hands this file's document to the view by navigating
            // to a data: url, so exactly one of those is the app arriving and
            // every one after it is a page moving itself somewhere this cannot
            // tell apart by origin. Allowing the first and refusing the rest is
            // the difference between naming the engine's own mechanism and
            // leaving the same-null-origin hole open for anyone to walk through.
            if (target.indexOf("data:") === 0 && !view.contentLoaded) {
                view.contentLoaded = true
                return
            }
            console.warn("neutrino: refused navigation to " + request.url)
            if (typeof request.reject === "function") {
                request.reject()
            } else {
                request.action = WebEngineNavigationRequest.IgnoreRequest
            }
            // mayOpenExternal and not isExternalUrl: refusing a navigation
            // and then handing the same url to the desktop's browser is the
            // page reaching the network without having asked, which is the one
            // thing the offline tier exists to stop.
            if (root.nt.mayOpenExternal(String(request.url))) {
                Qt.openUrlExternally(request.url)
            }
        }
        Component.onCompleted: {
            view.loadHtml(root.nt.applyContentPolicy(
                root.nt.extractHtmlDocument(root.ntSource)))
        }
    }
}
QMLEOF

    # Reopened read-only from the descriptor, and the write handle closed before
    # the engine starts: from here on nothing on this machine holds the inode
    # open for writing and nothing can reach it by name at all. /dev/fd first
    # because it is the spelling more than one kernel has; both were measured
    # working on the lane that runs this.
    qml_fd=""
    for qml_fddir in /dev/fd /proc/self/fd; do
        if [ -r "$qml_fddir/8" ] && exec 9<"$qml_fddir/8"; then
            qml_fd="$qml_fddir/9"
            break
        fi
    done
    exec 8>&-
    if [ -z "$qml_fd" ]; then
        echo "neutrino: cannot hand the engine a document without a name here" >&2
        return 1
    fi

    # Chromium's own sandbox is the only thing standing between hostile page
    # content and this machine, so a release build has no way to turn it off.
    # CI needs it off because its containers cannot create user namespaces, and
    # CI builds with --tier=testing to say so out loud.
    if has_tier testing && [ "$neutrino_qt_disable_sandbox" = "1" ]; then
        QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS} --no-sandbox"
    fi

    QML_XHR_ALLOW_FILE_READ=1 \
    QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}" \
    LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}" \
    QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS:---disable-dev-shm-usage}" \
    "$qml_runner" "$qml_fd"
}

# WebKitGTK's sandbox is bubblewrap, and bubblewrap needs an unprivileged user
# namespace. Whether it can have one is not a property of this program: Ubuntu
# 24.04 and its derivatives set kernel.apparmor_restrict_unprivileged_userns to
# 1 and refuse, while the same kernel elsewhere allows it. Under netinstall it
# is refused again for an unrelated reason, since Landlock denies mount to any
# domain handling a filesystem right.
#
# None of that can be recovered from after the fact. Asking WebKitGTK to turn
# the sandbox off once a web process exists aborts the program outright --
# "Sandboxing cannot be changed after subprocesses were spawned" -- and asking
# for a sandbox that cannot start gives a window with nothing in it. So the
# question is settled here, before anything is launched, by running the actual
# mechanism rather than by looking for the parts it is made of.
#
# The value is always assigned, never defaulted from the environment, so this
# is a measurement being passed inward and not a switch anyone can set.
neutrino_webkit_sandbox=0
if command -v bwrap >/dev/null 2>&1 &&
   bwrap --unshare-user --ro-bind / / /bin/true >/dev/null 2>&1
then neutrino_webkit_sandbox=1
fi
export NEUTRINO_WEBKIT_SANDBOX="$neutrino_webkit_sandbox"

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

if command -v gjs >/dev/null 2>&1
then
    # gjs is a system binary; a bundled caller (snap, flatpak, AppImage, ...)
    # may export GLib/GTK loader overrides pointing at its own libraries,
    # which then get loaded against the system glibc and crash. Clear them so
    # gjs resolves modules from the system defaults.
    #
    # This is a compatibility rule and it predates the scrub above, which now
    # covers all but two of these by shape. Kept whole rather than reduced to
    # its remainder: the two it still adds -- GSETTINGS_SCHEMA_DIR and LOCPATH
    # -- name data and not code, so they are not the scrub's to take, and a
    # crash is a good enough reason to drop them on its own.
    unset GTK_PATH GTK_EXE_PREFIX GTK_IM_MODULE_FILE \
          GDK_PIXBUF_MODULE_FILE GDK_PIXBUF_MODULEDIR \
          GIO_MODULE_DIR GSETTINGS_SCHEMA_DIR LOCPATH \
          LD_PRELOAD LD_LIBRARY_PATH
    NEUTRINO_SCRIPT_PATH="$script_path" gjs "$script_path"
elif qt_runner="$(find_qt_runtime)"
then run_qt "$qt_runner"
elif command -v osascript >/dev/null 2>&1
then run_macos
else echo "No suitable runtime found (expected gjs, Qt QML runtime, or osascript)" >&2
fi
exit $?;:<<'//</script></head><body></body>' #-->
<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="script-src 'unsafe-eval'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'"><style> html, body { background: white; color: black; font-size: 2em; }</style></head>
<script type=text/javascript>//*/

    /*@cc_on
        @if (@_jscript_version >= 7)
            import System;
            import System.IO;
            import System.Collections;
            import System.Drawing;
            import System.Windows.Forms;
            import System.Reflection;

            // Line comments only in here. This whole block is itself a block
            // comment to every engine but jsc, and JavaScript has no nested
            // block comments -- an inner close would end the outer one and
            // spill JScript.NET syntax into three engines that cannot read it.
            //
            // The only reason this class exists is that CoreWebView2's
            // WebMessageReceived wants a delegate, and the delegate's type
            // comes from an assembly loaded at run time, so it cannot be named
            // here. Delegate.CreateDelegate binds a method to a delegate type
            // discovered at run time, and accepts a method whose parameters are
            // wider than the delegate's -- Object is wider than every event
            // args type there is -- so a method typed this way binds to
            // EventHandler of anything.
            //
            // It queues the arguments rather than calling back out. A .NET
            // static is not reachable from page script, so unlike a title the
            // queue cannot be written by the document, and draining it from the
            // existing loop avoids asking whether a JScript class method may
            // call a JScript global -- the one part of this that would fail at
            // compile time rather than at run time.
            class NeutrinoWebMessageSink {
                static var queue : ArrayList = new ArrayList();
                function Handle(sender : Object, args : Object) : void {
                    NeutrinoWebMessageSink.queue.Add(args);
                }
            }

            // The navigation policy, and it cannot use the queue above.
            // Cancel and Handled are read by the engine the moment the handler
            // returns, so a decision drained from a loop is a decision taken
            // after the navigation has already gone -- the one place in this
            // file where the work has to happen inside the handler.
            //
            // What it needs from the driver is therefore statics the loop sets
            // rather than a callback it calls: `armed` is the documentLoaded
            // gate the gjs, Qt and macOS guards all use, and the refusals are
            // drained by the loop so the note is written by the side of this
            // file that can write one.
            //
            // Measured, on the pinned runtime the driver loads: every event is
            // an EventHandler`1 so one Handle binds to all of them;
            // NavigationStartingEventArgs.Cancel and
            // NewWindowRequestedEventArgs.Handled are both writable; and
            // NavigationStarting fires for the driver's own load twice, as
            // about:blank and then as the data: url NavigateToString makes --
            // which is why the gate exists and why the url alone cannot be the
            // rule. Source stays about:blank throughout.
            class NeutrinoNavSink {
                // Set by the driver's loop the moment it has issued its own
                // NavigateToString. Everything below keys off it: the first
                // navigation after it is the app's own document, and the
                // commit of that document is what arms the guard.
                static var navIssued : boolean = false;
                // The url the driver's own NavigateToString produced, as the
                // engine spells it, fragment stripped. Not guessed: a data: url
                // is what NavigateToString makes here, and the view's Source
                // stays about:blank throughout, so the only place this can be
                // learned is the navigation event itself.
                static var ownDocument : String = "";
                // The documentLoaded gate the gjs, Qt and macOS guards all use.
                // Armed from inside the engine at the commit of the document
                // this file loaded -- the Windows spelling of gjs's COMMITTED
                // and macOS's didCommitNavigation:.
                static var armed : boolean = false;
                static var refusals : ArrayList = new ArrayList();
                var kind : String;

                function Handle(sender : Object, args : Object) : void {
                    if (this.kind == "commit") {
                        // On ownDocument and not on navIssued, so there is no
                        // ordering to get right. The about:blank the control is
                        // created with commits too, and if that commit landed
                        // after the flag were set the gate would arm one
                        // navigation early -- and the navigation it would then
                        // refuse is the app's own document. Keyed this way the
                        // gate cannot arm before the load it is meant to arm at,
                        // whatever order the engine fires these in.
                        if (NeutrinoNavSink.ownDocument != "") {
                            NeutrinoNavSink.armed = true;
                        }
                        return;
                    }
                    var going : String = NeutrinoNavSink.uriOf(args);
                    if (this.kind == "navstart" && !NeutrinoNavSink.armed) {
                        // The app's own document, on its way in. Remembered the
                        // way rememberTrustedView remembers one: the first wins
                        // and only the first, at the load this file started and
                        // before any page script exists to send anything.
                        if (NeutrinoNavSink.navIssued && NeutrinoNavSink.ownDocument == "") {
                            NeutrinoNavSink.ownDocument = NeutrinoNavSink.identity(going);
                        }
                        return;
                    }
                    if (!NeutrinoNavSink.armed) {
                        return;
                    }
                    if (this.kind == "newwindow") {
                        // Every one of them. A window opened from the app's
                        // document is a second view with no driver behind it,
                        // and the shipped build was measured handing one a real
                        // window: popup_arrived=YES opened=HANDLE, and the frame
                        // it got wore a forged __NEUTRINO__ title.
                        if (NeutrinoNavSink.setTrue(args, "Handled")) {
                            NeutrinoNavSink.refusals.Add("refused a new window for " +
                                NeutrinoNavSink.shorten(going));
                        } else {
                            NeutrinoNavSink.refusals.Add("could not refuse a new window for " +
                                NeutrinoNavSink.shorten(going));
                        }
                        return;
                    }
                    if (NeutrinoNavSink.isOwn(going)) {
                        return;
                    }
                    if (NeutrinoNavSink.setTrue(args, "Cancel")) {
                        NeutrinoNavSink.refusals.Add("refused navigation to " +
                            NeutrinoNavSink.shorten(going));
                    } else {
                        NeutrinoNavSink.refusals.Add("could not refuse navigation to " +
                            NeutrinoNavSink.shorten(going));
                    }
                }

                // isOwnDocument's rule and viewIdentity's, spelled out again
                // because a JScript.NET class cannot call a JScript global --
                // the same reason the message sink queues instead of calling
                // back out. If either of those changes this has to change with
                // it, which is why they are named here.
                //
                // The fragment is not part of the answer, and on this engine
                // that is not a nicety. The document this driver loads is a
                // data: url, so an app moving between screens with
                // location.hash produces a navigation to that same url with a
                // fragment on it -- a guard comparing whole strings would
                // refuse the app's own screen changes and report each one.
                static function identity(uri : String) : String {
                    var cut : int = uri.IndexOf("#");
                    return cut < 0 ? uri : uri.Substring(0, cut);
                }

                static function isOwn(uri : String) : boolean {
                    var id : String = NeutrinoNavSink.identity(uri);
                    if (id == "" || id == "about:blank") {
                        return true;
                    }
                    return NeutrinoNavSink.ownDocument != "" &&
                        id == NeutrinoNavSink.ownDocument;
                }

                static function uriOf(args : Object) : String {
                    try {
                        var p : PropertyInfo = args.GetType().GetProperty("Uri");
                        if (p == null) {
                            return "";
                        }
                        var v : Object = p.GetValue(args, null);
                        return v == null ? "" : String(v);
                    } catch (e) {
                        return "";
                    }
                }

                // For the note only. A data: url is longer than an annotation
                // and the part that identifies it is the scheme; the comparison
                // above is made on the whole string.
                static function shorten(uri : String) : String {
                    return uri.Length > 120 ? uri.Substring(0, 120) + "..." : uri;
                }

                static function setTrue(args : Object, name : String) : boolean {
                    try {
                        var p : PropertyInfo = args.GetType().GetProperty(name);
                        if (p == null || !p.CanWrite) {
                            return false;
                        }
                        p.SetValue(args, true, null);
                        return true;
                    } catch (e) {
                        return false;
                    }
                }
            }
        @end
    @*/

    var NeutrinoWebview = {
        // The tier list is stamped here by build.sh and read back out of this
        // file by the shell section, so all three languages in this polyglot
        // see one value and there is nothing in the environment that can be set
        // to talk any of them out of it. A release build has no way to be
        // talked into "testing".
        //#TIER_START
        tiers: "default",
        //#TIER_END

        hasTier: function (name) {
            return ("," + String(this.tiers || "default") + ",").indexOf("," + name + ",") >= 0;
        },

        config: {
            title: "neutrino",
            url: "https://alganet.github.io/",
            width: 900,
            height: 600
        },

        hasGlobalExpr: function (expression) {
            try {
                return eval(expression);
            } catch (_) {
                return false;
            }
        },

        /*
         * The document, with the script taken out of it.
         *
         * This file's JavaScript -- including whatever an author spliced into
         * runWeb -- used to be an inline script inside the document it loads,
         * which meant the document's content policy had to permit inline
         * script, which meant it could never say script-src 'none'. Every
         * driver already injects the preload through its engine, so the page's
         * own code goes the same way and the document ends up carrying no
         * executable content at all.
         *
         * What that buys is worth the trouble: an injection bug in someone's
         * app cannot run script in this document, because nothing in the
         * document is allowed to.
         */
        extractHtmlDocument: function (content) {
            var text = String(content || "");
            var lower = text.toLowerCase();
            var doctypeIndex = lower.indexOf("<!doctype html");
            if (doctypeIndex >= 0) {
                text = text.substring(doctypeIndex);
            }
            var scriptIndex = text.indexOf("<script");
            if (scriptIndex < 0) {
                return text;
            }
            return text.substring(0, scriptIndex) + "<body></body></html>";
        },

        // The other half: everything the document used to carry, handed to the
        // engine to inject instead. Stops before the closing sentinel, which is
        // markup pretending to be a comment and is not wanted in either half.
        extractPageScript: function (content) {
            var text = String(content || "");
            var start = text.indexOf("<script");
            if (start < 0) {
                return "";
            }
            start = text.indexOf(">", start);
            if (start < 0) {
                return "";
            }
            var end = text.lastIndexOf("//</script>");
            if (end < 0 || end <= start) {
                return "";
            }
            return text.substring(start + 1, end);
        },

        getMacScriptPath: function (ObjCRef, dollar) {
            var fileManager = dollar.NSFileManager.defaultManager;
            var currentDir = String(fileManager.currentDirectoryPath);

            var envPathObj = dollar.NSProcessInfo.processInfo.environment.objectForKey("NEUTRINO_SCRIPT_PATH");
            if (envPathObj) {
                var envPath = String(envPathObj);
                if (envPath && fileManager.fileExistsAtPath(envPath)) {
                    return envPath;
                }
            }

            var argv = [];
            try {
                argv = ObjCRef.deepUnwrap(dollar.NSProcessInfo.processInfo.arguments);
            } catch (_) {
                argv = [];
            }

            for (var i = argv.length - 1; i >= 0; i--) {
                var candidate = String(argv[i] || "");
                if (!candidate || /^-/.test(candidate)) {
                    continue;
                }

                if (fileManager.fileExistsAtPath(candidate)) {
                    return candidate;
                }

                var combined = currentDir + "/" + candidate;
                if (fileManager.fileExistsAtPath(combined)) {
                    return combined;
                }
            }

            throw new Error("Could not resolve current script path on macOS.");
        },

        getLinuxScriptPath: function (importsRef) {
            var GLib = importsRef["gi"]["GLib"];
            var systemRef = importsRef["system"];
            var programPath = String(systemRef.programPath);
            if (!GLib.path_is_absolute(programPath)) {
                programPath = GLib.build_filenamev([GLib.get_current_dir(), programPath]);
            }
            return programPath;
        },

        run: function () {
            if (this.hasGlobalExpr("typeof System !== 'undefined' && System && System.Windows && System.Windows.Forms && System.Windows.Forms.Application")) {
                this.runWindows();
                return;
            }
            if (this.hasGlobalExpr("typeof ObjC !== 'undefined' && typeof $ !== 'undefined'")) {
                this.runMacOS();
                return;
            }
            if (this.hasGlobalExpr("typeof imports !== 'undefined' && !!imports.gi")) {
                this.runGjs();
                return;
            }
            if (this.hasGlobalExpr("typeof NeutrinoQml !== 'undefined'")) {
                return;
            }
            if (this.hasGlobalExpr("typeof window !== 'undefined'")) {
                this.runWeb();
                return;
            }
            throw new Error("Unsupported JS runtime for webview.js");
        },

        runWeb: function () {
            //#RUNWEB_START
            var win = eval("window");
            var doc = eval("document");
            doc.write("Welcome to neutrino");
            //#RUNWEB_END
        },

        resolveLinuxWebKitVersion: function () {
            var importsRef = eval("imports");
            var GIRepository = importsRef["gi"]["GIRepository"];
            var Repository = GIRepository["Repository"];
            var repository = Repository["dup_default"]
                ? Repository["dup_default"]()
                : Repository["get_default"]();
            var versions = repository.enumerate_versions("WebKit2");

            if (versions.indexOf("4.1") !== -1) {
                return "4.1";
            }
            if (versions.indexOf("4.0") !== -1) {
                return "4.0";
            }
            throw new Error("WebKit2 introspection typelibs not found");
        },

        createMacDriver: function () {
            var ObjCRef = eval("ObjC");
            var dollar = eval("$");
            var app;
            var self = this;
            var messageCallback = null;
            var webViewRef = null;
            var windowDelegateRef = null;
            var scriptHandlerRef = null;
            var navDelegateRef = null;
            var pendingPreload = null;
            var pendingPageScript = null;
            var documentLoaded = false;

            // What the view is showing, as the view answers rather than as
            // anything that called in claims. Empty is an answer too: a view
            // that will not say is one nothing may be trusted from.
            var currentUrl = function () {
                try {
                    var u = webViewRef ? webViewRef.URL : null;
                    return u ? String(ObjCRef.unwrap(u.absoluteString) || "") : "";
                } catch (_) {
                    return "";
                }
            };

            return {
                webMessageTransport: "window.webkit.messageHandlers.neutrino.postMessage",
                transportName: "wkscriptmessage",
                init: function () {
                    ObjCRef["import"]("Cocoa");
                    ObjCRef["import"]("WebKit");
                    app = dollar.NSApplication.sharedApplication;
                    ObjCRef.registerSubclass({
                        name: "NeutrinoWindowDelegate",
                        superclass: "NSObject",
                        methods: {
                            "windowWillClose:": {
                                types: ["void", ["id"]],
                                implementation: function () {
                                    try { app.terminate(null); } catch (_) {}
                                }
                            }
                        }
                    });

                    /*
                     * A navigation guard, and deliberately not the one this
                     * looks like it should be.
                     *
                     * WKNavigationDelegate decides a navigation through
                     * -webView:decidePolicyForNavigationAction:decisionHandler:,
                     * whose third argument is a block, and JXA cannot call one.
                     * Implementing that selector here refuses nothing: it
                     * wedges every load in the view including the first.
                     * Measured -- with the selector registered, the policy
                     * callback fires once for this file's own document, six
                     * ways of calling the handler all throw, and the load never
                     * reaches didStartProvisionalNavigation at all. Naming the
                     * parameter @? or block instead does not help; it aborts
                     * the process on an uncaught NSException. All four
                     * spellings register cleanly, so nothing warns you. This
                     * comment is here because adding that selector is the
                     * obvious thing to try and it ships a window that never
                     * loads.
                     *
                     * What is left needs no block, and it is enough.
                     * didCommitNavigation: is the document this file loaded
                     * arriving, which is where the view this driver is allowed
                     * to hear from is remembered -- before the page script the
                     * engine injects at document end, exactly as gjs arms at
                     * COMMITTED. didStartProvisionalNavigation: is a navigation
                     * beginning, and -stopLoading refuses it. Measured against
                     * a page on loopback that really answers: without this the
                     * document went, the user scripts were reinjected into what
                     * arrived, and it spoke to the native window from an http
                     * origin; with it the navigation is abandoned and the app's
                     * own document is still the one there.
                     *
                     * It is later than a policy decision and that is the
                     * ceiling here, not an oversight: the request has already
                     * left. Nothing is handed to the desktop's URL handler on
                     * refusal either, unlike gjs and Qt -- opening a link the
                     * page chose is a feature this guard is not the place to
                     * add.
                     */
                    try {
                    ObjCRef.registerSubclass({
                        name: "NeutrinoNavDelegate",
                        superclass: "NSObject",
                        methods: {
                            "webView:didStartProvisionalNavigation:": {
                                types: ["void", ["id", "id"]],
                                implementation: function () {
                                    var going = currentUrl();
                                    // Until the first commit the only
                                    // navigation in flight is the one this file
                                    // started, which is the same reasoning the
                                    // gjs guard is built on.
                                    if (!documentLoaded || self.isTrustedView(going)) {
                                        return;
                                    }
                                    try {
                                        webViewRef.stopLoading();
                                        self.note("refused navigation to " + going);
                                    } catch (e) {
                                        self.note("could not refuse navigation to " +
                                            going + ": " + e);
                                    }
                                }
                            },
                            "webView:didCommitNavigation:": {
                                types: ["void", ["id", "id"]],
                                implementation: function () {
                                    self.rememberTrustedView(currentUrl());
                                    documentLoaded = true;
                                }
                            }
                        }
                    });
                    } catch (e) {
                        /*
                         * Loud, because everything downstream depends on it.
                         * With no delegate nothing is ever remembered, and the
                         * sender check no longer fails open -- so the window
                         * comes up and refuses its own app. That is inert
                         * rather than dangerous, which is the trade this driver
                         * makes everywhere, but only if it says so.
                         */
                        self.note("no navigation guard, and no message will be " +
                            "trusted: " + e);
                    }

                    /*
                     * A real message handler, replacing a timer that read
                     * document.title twenty times a second. The title was never
                     * a channel: it is a property of whatever document happens
                     * to be loaded, so any page in this webview -- including one
                     * it navigated to -- could set it and drive the native
                     * window. This has a sender attached to it, which is the
                     * thing the title could never have.
                     */
                    try {
                    ObjCRef.registerSubclass({
                        name: "NeutrinoScriptHandler",
                        superclass: "NSObject",
                        /*
                         * No protocols key. Declaring WKScriptMessageHandler
                         * here fails with "protocol does not exist": a protocol
                         * only exists as a runtime object if something in the
                         * process references it, and nothing in an osascript
                         * process does. Conformance is not what makes this
                         * work in any case -- the content controller sends the
                         * selector, and a class that implements it answers.
                         * NeutrinoWindowDelegate above is an NSWindowDelegate
                         * on exactly the same terms.
                         */
                        methods: {
                            "userContentController:didReceiveScriptMessage:": {
                                types: ["void", ["id", "id"]],
                                implementation: function (_, message) {
                                    try {
                                        if (!messageCallback) {
                                            return;
                                        }
                                        self.trace("message handler fired");
                                        if (!self.isTrustedMacSender(ObjCRef, message, webViewRef)) {
                                            return;
                                        }
                                        messageCallback(ObjCRef.unwrap(message.body));
                                    } catch (_) {}
                                }
                            }
                        }
                    });
                    } catch (e) {
                        self.note("could not register the message handler: " + e);
                    }
                },
                readFile: function (path) {
                    var data = dollar.NSData.dataWithContentsOfFile(path);
                    if (!data) {
                        throw new Error("Could not read local document: " + path);
                    }
                    var nsStr = dollar.NSString.alloc.initWithDataEncoding(data, dollar.NSUTF8StringEncoding);
                    if (!nsStr) {
                        throw new Error("Could not decode local document as UTF-8: " + path);
                    }
                    return ObjCRef.unwrap(nsStr);
                },
                getScriptPath: function () {
                    return self.getMacScriptPath(ObjCRef, dollar);
                },
                createWindow: function (config) {
                    var frame = dollar.NSMakeRect(0, 0, config.width, config.height);
                    var win = dollar.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
                        frame,
                        dollar.NSTitledWindowMask | dollar.NSClosableWindowMask | dollar.NSResizableWindowMask,
                        dollar.NSBackingStoreBuffered,
                        false
                    );
                    win.title = config.title + " - macOS";
                    try { win.center(); } catch (_) {}
                    windowDelegateRef = dollar.NeutrinoWindowDelegate.alloc.init;
                    win["delegate"] = windowDelegateRef;
                    this.writeStatus(config.title + " - macOS", win);
                    return win;
                },
                createWebView: function () {
                    var frame = dollar.NSMakeRect(0, 0, 100, 100);
                    var wkConfig = dollar.WKWebViewConfiguration.alloc.init;

                    /*
                     * Every call in here goes through the ObjC bridge, and a
                     * bridge that does not expose one of them throws. Letting
                     * that propagate means no window at all, which is the least
                     * informative thing that can happen -- there is nothing on
                     * screen and nothing said. Degrading instead leaves a
                     * window with no channel into it, which is inert rather
                     * than dangerous, and says which call was missing.
                     */
                    try {
                        var ucc = dollar.WKUserContentController.alloc.init;

                        if (messageCallback) {
                            scriptHandlerRef = dollar.NeutrinoScriptHandler.alloc.init;
                            ucc.addScriptMessageHandlerName(scriptHandlerRef, "neutrino");
                        }

                        // Both halves arrive through the engine, which is what
                        // lets the document forbid script of its own: the API at
                        // document start, the page's code once there is a
                        // document to run it against.
                        if (pendingPreload) {
                            ucc.addUserScript(
                                dollar.WKUserScript.alloc
                                    .initWithSourceInjectionTimeForMainFrameOnly(
                                        pendingPreload, 0, true
                                    )
                            );
                        }
                        if (pendingPageScript) {
                            ucc.addUserScript(
                                dollar.WKUserScript.alloc
                                    .initWithSourceInjectionTimeForMainFrameOnly(
                                        pendingPageScript, 1, true
                                    )
                            );
                        }

                        wkConfig.userContentController = ucc;
                        self.trace("message channel wired, preload " +
                            (pendingPreload ? "injected" : "MISSING"));
                    } catch (e) {
                        self.note("no message channel: " + e);
                    }

                    var wv = dollar.WKWebView.alloc.initWithFrameConfiguration(frame, wkConfig);
                    try { wv.allowsLinkPreview = false; } catch (_) {}
                    webViewRef = wv;
                    // Bracket notation for the same reason createWindow uses it
                    // on a window's delegate.
                    try {
                        navDelegateRef = dollar.NeutrinoNavDelegate.alloc.init;
                        wv["navigationDelegate"] = navDelegateRef;
                    } catch (e) {
                        self.note("no navigation guard on this view: " + e);
                    }
                    return wv;
                },

                injectPreload: function (_, js) {
                    pendingPreload = js;
                },
                injectPageScript: function (js) {
                    pendingPageScript = js;
                },
                screenHeight: function () {
                    return dollar.NSScreen.mainScreen.frame.size.height;
                },
                toMacY: function (y, winHeight) {
                    return this.screenHeight() - y - winHeight;
                },
                toTopLeftY: function (macY, winHeight) {
                    return this.screenHeight() - macY - winHeight;
                },
                writeStatus: function (title, win) {
                    // Scaffolding for verify-macos.sh, which has no other way to
                    // read a window's geometry back. It is not part of running an
                    // app, so a release build does not write it anywhere.
                    if (!self.hasTier("testing")) {
                        return;
                    }
                    try {
                        var f = win.frame;
                        var topLeftY = Math.round(this.toTopLeftY(f.origin.y, f.size.height));
                        var status = title + "\n" +
                            Math.round(f.size.width) + "x" + Math.round(f.size.height) + "\n" +
                            Math.round(f.origin.x) + "," + topLeftY;
                        var statusPath = dollar.NSTemporaryDirectory().js + "neutrino-title.txt";
                        dollar.NSString.alloc.initWithUTF8String(status)
                            .writeToFileAtomicallyEncodingError(statusPath, true, 4, null);
                    } catch (_) {}
                },
                setTitle: function (win, title) {
                    win.title = title;
                    this.writeStatus(title, win);
                },
                resize: function (win, w, h) {
                    var frame = win.frame;
                    win.setFrameDisplay(dollar.NSMakeRect(frame.origin.x, frame.origin.y, w, h), true);
                    this.writeStatus(String(win.title), win);
                },
                move: function (win, x, y) {
                    var frame = win.frame;
                    var macY = this.toMacY(y, frame.size.height);
                    win.setFrameDisplay(dollar.NSMakeRect(x, macY, frame.size.width, frame.size.height), true);
                    this.writeStatus(String(win.title), win);
                },
                "close": function (win) {
                    win.performClose(null);
                },
                openExternal: function (url) {
                    if (!self.mayOpenExternal(url)) {
                        return;
                    }
                    dollar.NSWorkspace.sharedWorkspace.openURL(
                        dollar.NSURL.URLWithString(String(url))
                    );
                },
                onWebMessage: function (cb) {
                    messageCallback = cb;
                },
                attachWebView: function (win, wv) {
                    win.contentView = wv;
                },
                loadHTML: function (wv, html, basePath) {
                    var baseUrl = dollar.NSURL.fileURLWithPath(basePath).URLByDeletingLastPathComponent;
                    self.trace("loading " + html.length + " bytes with base " + basePath);
                    wv.loadHTMLStringBaseURL(html, baseUrl);
                },
                showWindow: function (win) {
                    win.makeKeyAndOrderFront(null);
                    try { app.activateIgnoringOtherApps(true); } catch (_) {}
                },
                runEventLoop: function () {
                    dollar.NSApp.setActivationPolicy(0);
                    app.run();
                }
            };
        },

        createGjsDriver: function () {
            var importsRef = eval("imports");
            var Gtk, WebKit2, GLib, ByteArray;
            var self = this;
            var messageCallback = null;
            var pendingPreload = null;
            var pendingPageScript = null;
            var documentLoaded = false;

            return {
                webMessageTransport: "window.webkit.messageHandlers.neutrino.postMessage",
                transportName: "scriptmessage",
                init: function () {
                    importsRef["gi"]["versions"]["Gtk"] = "3.0";
                    importsRef["gi"]["versions"]["WebKit2"] = self.resolveLinuxWebKitVersion();
                    Gtk = importsRef["gi"]["Gtk"];
                    WebKit2 = importsRef["gi"]["WebKit2"];
                    GLib = importsRef["gi"]["GLib"];
                    ByteArray = importsRef["byteArray"];
                    Gtk.init(null);

                    /*
                     * WebKitGTK's own bubblewrap sandbox is opt-in, and until
                     * now neutrino never opted in -- so the process rendering
                     * whatever the page contains had nothing around it at all.
                     * This is the protection against hostile page content, and
                     * it is a different thing from netinstall's protection
                     * against the app's author.
                     *
                     * The two do not compose on Linux. netinstall's Landlock
                     * denies mount to any domain handling a filesystem right,
                     * and PR_SET_NO_NEW_PRIVS is required for Landlock, so
                     * under netinstall bubblewrap cannot initialise here. That
                     * trade is netinstall's README to explain; what this file
                     * can do is stop giving up the sandbox for nothing when it
                     * runs on its own, which is the normal case.
                     */
                    /*
                     * WebKitGTK's sandbox is bubblewrap, and bubblewrap needs
                     * an unprivileged user namespace. Whether it can have one
                     * is not a property of this program: Ubuntu 24.04 and its
                     * derivatives set kernel.apparmor_restrict_unprivileged_-
                     * userns to 1 and refuse, while the same kernel version
                     * elsewhere allows it -- netinstall's README records the
                     * same split for the same reason, and its test suite has to
                     * lift that knob to exercise the session tier at all.
                     *
                     * It also does not degrade when it cannot start. The web
                     * process simply fails and the window comes up empty, which
                     * is a worse outcome than not having asked. And it cannot
                     * be probed honestly beforehand: the helper is resolved by
                     * an absolute path compiled into WebKitGTK, so looking for
                     * it on PATH answers a different question than the one
                     * being asked.
                     *
                     * So it is asked for, and taken back if it does not arrive.
                     * That covers every reason it might not -- a missing
                     * helper, a refused namespace, a seccomp filter in front of
                     * clone -- rather than the one reason a probe could name.
                     */
                    if (GLib.getenv("NEUTRINO_WEBKIT_SANDBOX") === "1") {
                        try {
                            WebKit2.WebContext.get_default().set_sandbox_enabled(true);
                        } catch (e) {
                            self.note("webkit sandbox unavailable: " + e);
                        }
                    } else {
                        self.note("webkit sandbox off: this system refused a user namespace");
                    }
                },
                readFile: function (path) {
                    var result = GLib.file_get_contents(path);
                    if (!result[0]) {
                        throw new Error("Could not read local document: " + path);
                    }
                    return ByteArray.toString(result[1]);
                },
                getScriptPath: function () {
                    return self.getLinuxScriptPath(importsRef);
                },
                createWindow: function (config) {
                    var win = new Gtk.Window({
                        title: config.title + " - Linux",
                        default_width: config.width,
                        default_height: config.height
                    });
                    win.set_position(Gtk.WindowPosition.CENTER);
                    win.connect("destroy", function () { Gtk.main_quit(); });
                    return win;
                },
                createWebView: function () {
                    var ucm = new WebKit2.UserContentManager();

                    if (messageCallback) {
                        ucm.register_script_message_handler("neutrino");
                        ucm.connect("script-message-received::neutrino", function (_, result) {
                            // The sender check. This handler is registered on
                            // the content manager, not on a document, so it
                            // hears from whatever the view is showing -- which
                            // is the question, and the one thing a message
                            // cannot lie about.
                            var showing = "";
                            try {
                                showing = String(wv.get_uri());
                            } catch (_) {
                                showing = "";
                            }
                            if (!self.isTrustedView(showing)) {
                                self.note("refused a message from " + showing);
                                return;
                            }
                            messageCallback(result.get_js_value().to_string());
                        });
                    }

                    // Both halves go in through the engine now: the API first,
                    // at document start, then the page's own code once there is
                    // a document to run it against.
                    var inject = function (source, when) {
                        if (!source) {
                            return;
                        }
                        try {
                            ucm.add_script(WebKit2.UserScript["new"](
                                source,
                                WebKit2.UserContentInjectedFrames.TOP_FRAME,
                                when,
                                null,
                                null
                            ));
                        } catch (e) {
                            self.note("could not inject: " + e);
                        }
                    };
                    inject(pendingPreload, WebKit2.UserScriptInjectionTime.START);
                    inject(pendingPageScript, WebKit2.UserScriptInjectionTime.END);

                    var wv = new WebKit2.WebView({ user_content_manager: ucm });
                    /*
                     * COMMITTED, not FINISHED, and the difference is a hole.
                     *
                     * The author's script is injected at DOCUMENT_END, which
                     * runs after the document is committed and before its load
                     * has finished -- measured. A navigation started from there
                     * used to be decided while documentLoaded was still false,
                     * which is to say allowed. It looked closed on a document
                     * with nothing to fetch, because WebKitGTK delivers a policy
                     * decision on a later turn of the main loop and the load
                     * finished first and armed the guard in between. That is a
                     * race, and the page picks the winner: a stylesheet on a
                     * socket that never answers holds the load open for as long
                     * as it likes. Measured both ways -- allowed with the load
                     * held, refused once this armed at commit instead.
                     *
                     * The document the view committed is remembered here for
                     * the same reason: this is the load this file started, and
                     * nothing the page does has run yet.
                     */
                    wv.connect("load-changed", function (_, loadEvent) {
                        if (loadEvent === WebKit2.LoadEvent.COMMITTED) {
                            documentLoaded = true;
                            try {
                                self.rememberTrustedView(wv.get_uri());
                            } catch (_) {}
                        }
                    });

                    var settings = wv.get_settings();
                    try {
                        settings.set_enable_developer_extras(false);
                        settings.set_allow_file_access_from_file_urls(false);
                        settings.set_allow_universal_access_from_file_urls(false);
                        settings.set_javascript_can_access_clipboard(false);
                        settings.set_enable_write_console_messages_to_stdout(false);
                    } catch (_) {}

                    /*
                     * The document is loaded once, from this file, and never
                     * navigates again. Without this a link or a location
                     * assignment could replace it with a remote origin, and
                     * that origin would then be holding the channel to the
                     * native window -- the preload is registered on the user
                     * content manager, so it would be reinjected into whatever
                     * document arrived next.
                     */
                    var driverRef = this;
                    wv.connect("decide-policy", function (_, decision, decisionType) {
                        var types = WebKit2.PolicyDecisionType;
                        if (decisionType !== types.NAVIGATION_ACTION &&
                            decisionType !== types.NEW_WINDOW_ACTION) {
                            return false;
                        }
                        var uri = "";
                        try {
                            uri = String(decision.get_navigation_action().get_request().get_uri());
                        } catch (_) {
                            uri = "";
                        }
                        // Until the first document is committed, the only
                        // navigation in flight is the one this file started --
                        // measured: its decision is taken before any load event
                        // fires at all, so this is false when it matters.
                        // Keying on that rather than only on the url means an
                        // engine that spells the initial load differently
                        // cannot lock the app out of its own document.
                        if (!documentLoaded || self.isOwnDocument(uri)) {
                            return false;
                        }
                        decision.ignore();
                        self.note("refused navigation to " + uri);
                        driverRef.openExternal(uri);
                        return true;
                    });
                    return wv;
                },
                setTitle: function (win, title) {
                    win.set_title(title);
                },
                resize: function (win, w, h) {
                    win.resize(w, h);
                },
                move: function (win, x, y) {
                    win.move(x, y);
                },
                openExternal: function (url) {
                    // Checked here as well as in the splitter: this is the end
                    // of the line, and it hands a string to the desktop's URI
                    // handler, which will happily act on file: or on a .desktop
                    // entry if it is given one. It is also where the navigation
                    // refusal above arrives, so the tier half of the check
                    // closes that route as well as this one.
                    if (!self.mayOpenExternal(url)) {
                        return;
                    }
                    try {
                        var Gio = importsRef["gi"]["Gio"];
                        Gio.AppInfo.launch_default_for_uri(String(url), null);
                    } catch (_) {
                        // An argv, never a command line. The old fallback built
                        // "xdg-open " + url and handed it to a function that
                        // word-splits, so a url containing a space became two
                        // arguments and a url containing a quote became
                        // something else entirely.
                        try {
                            GLib.spawn_async(
                                null,
                                ["xdg-open", String(url)],
                                null,
                                GLib.SpawnFlags.SEARCH_PATH,
                                null
                            );
                        } catch (_) {}
                    }
                },
                "close": function (win) {
                    win.destroy();
                },
                onWebMessage: function (cb) {
                    messageCallback = cb;
                },
                injectPreload: function (_, js) {
                    pendingPreload = js;
                },
                injectPageScript: function (js) {
                    pendingPageScript = js;
                },
                attachWebView: function (win, wv) {
                    win.add(wv);
                },
                loadHTML: function (wv, html) {
                    wv.load_html(html, null);
                },
                showWindow: function (win) {
                    win.show_all();
                },
                runEventLoop: function () {
                    Gtk.main();
                }
            };
        },

        /*
         * Everything arriving on this channel was written by whatever page the
         * webview is currently showing, which makes it attacker-controlled text
         * by definition. It used to be handed to eval, which on gjs meant
         * evaluating that text in a scope holding imports.gi.GLib and Gio.
         *
         * The fix is not a JSON parser. The action set is fixed, flat and tiny,
         * so the host does not parse a message, it splits one: each action has a
         * known arity, and any free-form field is always last and takes the rest
         * of the string verbatim. A separator inside a title therefore cannot
         * invent an extra field, nothing needs escaping, and JScript.NET not
         * having a JSON global stops being a problem worth solving.
         */
        messageSeparator: String.fromCharCode(31),

        hasControlCharacters: function (value) {
            var text = String(value);
            for (var i = 0; i < text.length; i++) {
                var code = text.charCodeAt(i);
                if (code < 32 || code === 127) {
                    return true;
                }
            }
            return false;
        },

        isCoordinate: function (value) {
            return /^-?[0-9]{1,6}$/.test(String(value));
        },

        isDimension: function (value) {
            return /^[0-9]{1,6}$/.test(String(value)) && parseInt(String(value), 10) > 0;
        },

        /*
         * An allowlist, so every scheme this does not name is refused without
         * having to be enumerated -- file:, javascript:, data:, ms-settings:,
         * search-ms:, and whichever one the platform invents next. This matters
         * more than it looks: on Windows the other end of openExternal is
         * Process.Start, and on Linux it is the desktop's URI handler.
         */
        isExternalUrl: function (value) {
            var url = String(value == null ? "" : value);
            if (!url || url.length > 2048 || this.hasControlCharacters(url)) {
                return false;
            }
            return /^https?:\/\/[^\/?#]/i.test(url) || /^mailto:[^@\s]+@[^@\s]+$/i.test(url);
        },

        /*
         * Whether this build may hand a url to the machine's browser at all.
         *
         * isExternalUrl answers a question about the string. This answers one
         * about the build, and the two are separate on purpose: the allowlist
         * above is about schemes and stays true whatever tier is stamped.
         *
         * The offline tier says the page has no network. A url handed to the
         * desktop's handler is the page reaching the network in another
         * program, and it was measured going out that way on all four engines,
         * by both routes -- `neutrino.shell.openExternal`, which any page
         * script may call, and a navigation this file refuses and then forwards
         * on gjs and Qt without the page having to ask twice. Neither is
         * something a content policy can see: CSP governs subresources, and
         * this is not a load.
         *
         * So the tier closes it, and every place that was asking isExternalUrl
         * before opening asks this instead -- including the four drivers' own
         * end-of-the-line checks, which exist because that is where a string
         * becomes ShellExecute, NSWorkspace or the desktop's URI handler.
         *
         * The cost is real and is the tier's whole point: an offline app cannot
         * open a link in the user's browser. An app that wants to do that wants
         * the default tier.
         */
        mayOpenExternal: function (value) {
            if (!this.isExternalUrl(value)) {
                return false;
            }
            return !this.hasTier("offline");
        },

        /*
         * The document is loaded from this file, so it has no origin of its own
         * and every engine here reports it as about:blank. Anything else is a
         * navigation away from it.
         *
         * data: is deliberately not on this list. A data: document is same-null-
         * origin, so it would inherit the injected channel to the native window
         * while carrying content this file never wrote.
         */
        /*
         * A refusal that leaves no trace is indistinguishable from a window that
         * simply never came up, and those want opposite fixes. eval, because
         * JScript.NET resolves globals at compile time and has neither of these
         * -- the same reason the README gives for eval("window").
         */
        note: function (message) {
            try {
                eval("printerr")("neutrino: " + message);
                return;
            } catch (_) {}
            try {
                eval("console").warn("neutrino: " + message);
                return;
            } catch (_) {}
            try {
                eval("console").log("neutrino: " + message);
            } catch (_) {}
        },

        /*
         * A note worth making in a release build is a refusal or a failure.
         * Anything that is only interesting while working out why a lane is red
         * belongs here instead, where a release build never says it.
         */
        trace: function (message) {
            if (this.hasTier("testing")) {
                this.note(message);
            }
        },

        /*
         * The fragment is not part of the answer. Setting location.hash is how
         * a great many apps move between screens; it does not navigate
         * anywhere, and every engine here reports it in the uri anyway --
         * measured on all three. Without this the guard refuses a navigation
         * that is going to happen regardless and says so in a note, which is a
         * refusal that did not take place.
         */
        isOwnDocument: function (url) {
            var u = this.viewIdentity(url);
            return u === "" || u === "about:blank";
        },

        /*
         * The document a message is allowed to come from, as the engine names
         * it rather than as this file would guess.
         *
         * The three engines answer differently and an origin rule that fits one
         * mutes the others: gjs reports about:blank for a document loaded from
         * a string, QtWebEngine reports the whole data: url it navigated to in
         * order to hand the document over, and the macOS driver reports the
         * file: directory it was given as a base. All three measured. A check
         * built on schemes admits only the last, and the other two get a window
         * that comes up and then ignores its own app.
         *
         * What all three can answer is whether the view is still showing the
         * document that arrived first. So that one is remembered and every
         * later message is judged against it, which needs no per-engine table
         * and no allowlist. On macOS it is stricter than the origin rule it
         * joins rather than replaces: that one admits any file: document, which
         * is the residual its own comment names.
         */
        trustedView: null,

        viewIdentity: function (uri) {
            var text = String(uri == null ? "" : uri);
            var fragment = text.indexOf("#");
            return fragment < 0 ? text : text.substring(0, fragment);
        },

        /*
         * The first one wins and only the first. A driver calls this where it
         * knows the document is the one it loaded: at the load it started,
         * before anything the page does has run.
         *
         * A view that cannot say what it is showing has not handed over a
         * document to trust, and remembering the empty answer would pin the
         * whole session to it. Said out loud, because what follows from it is a
         * window that comes up and then refuses everything, and a refusal
         * nobody can account for is the failure this file keeps legislating
         * against.
         */
        rememberTrustedView: function (uri) {
            if (this.trustedView !== null) {
                return;
            }
            var identity = this.viewIdentity(uri);
            if (identity === "") {
                this.note("the view did not say which document it committed");
                return;
            }
            this.trustedView = identity;
        },

        /*
         * No longer fails open on a view that has committed nothing yet.
         *
         * That choice was made when the macOS driver remembered its document at
         * the *first message*, having no load event to hang one on -- so a page
         * that navigated before the app ever spoke got itself remembered as the
         * view to trust, and the guard adopted the attacker. Every driver now
         * arms at the load it started and before any page script exists to send
         * anything: gjs at COMMITTED, Qt immediately before it injects the
         * preload, macOS at didCommitNavigation:. A message arriving with
         * nothing remembered is therefore not an app that has not got going
         * yet; it is a view that never committed the document this file loaded.
         *
         * The reason the fail-open was there in the first place still holds and
         * is answered rather than dropped: every caller says why it refused, so
         * the inert window explains itself instead of merely being inert.
         */
        isTrustedView: function (uri) {
            if (this.trustedView === null) {
                return false;
            }
            return this.viewIdentity(uri) === this.trustedView;
        },

        /*
         * What counts as the app's own document is not the same on every
         * engine, and getting that wrong is silent in the worst way: gjs loads
         * with a null base url and its document has no origin at all, while
         * this driver loads with the script's directory as a file: base so that
         * an app's relative assets resolve. Demanding an empty scheme therefore
         * refused every message the app itself sent, and left a window that
         * came up and then did nothing.
         *
         * So the rule is about the host, not the scheme: a document that can
         * speak to the network has one, and neither of these has one. A page
         * the webview navigated to somewhere remote is refused, which is the
         * escape worth closing.
         *
         * The origin alone is not enough, though, because a data: document has
         * no origin either -- it is the one navigation an origin check cannot
         * tell from the app's own document, and the preload here is a user
         * script the engine reinjects into whatever loads next, so the page
         * that arrives inherits the whole API. So what the view is currently
         * showing is checked as well, which is a question a message cannot lie
         * about.
         *
         * The residual left is another file: document, which is local content
         * rather than a remote origin.
         */
        isTrustedOrigin: function (scheme, host) {
            var s = String(scheme == null ? "" : scheme);
            var h = String(host == null ? "" : host);
            return h === "" && (s === "" || s === "file");
        },

        isTrustedMacSender: function (ObjCRef, message, webView) {
            /*
             * What the view is showing, independent of what the message claims.
             *
             * Nothing here fails open any more. The document to trust is
             * remembered at didCommitNavigation: now -- the load this file
             * started, before the page script the engine injects at document
             * end can run -- so a message arriving with nothing remembered is
             * not an app still getting going. Remembering it here instead, as
             * this did while the driver had no delegate to hang one on, meant a
             * page that navigated before the app ever spoke was the one that
             * got remembered.
             *
             * A bridge that will not answer is refused for the same reason. It
             * leaves a window that does nothing, which was the objection -- so
             * it says which call would not answer, and an inert window that
             * explains itself is not the failure that objection was about.
             */
            try {
                var current = webView.URL;
                var currentScheme = current
                    ? String(ObjCRef.unwrap(current.scheme) || "") : "";
                var currentUrl = current
                    ? String(ObjCRef.unwrap(current.absoluteString) || "") : "";
                if (!this.isTrustedOrigin(currentScheme, "")) {
                    this.note("refused a message from a document at " +
                        currentScheme + ":");
                    return false;
                }
                // And the same document, not merely the same kind of one.
                if (!this.isTrustedView(currentUrl)) {
                    this.note("refused a message from " +
                        (currentUrl === "" ? "a view showing nothing" : currentUrl));
                    return false;
                }
            } catch (e) {
                this.note("refused a message: could not read what the view is " +
                    "showing: " + e);
                return false;
            }

            var frame = null;
            try {
                frame = message.frameInfo;
                if (!frame.isMainFrame) {
                    this.note("refused a message from a subframe");
                    return false;
                }
            } catch (e) {
                this.note("refused a message with no frame: " + e);
                return false;
            }

            /*
             * The sender's own account of itself, kept separate from reading
             * the frame because the two used to fail differently: a frame that
             * cannot be read is a message with no sender, while an origin that
             * cannot be read was this bridge not exposing something it was
             * expected to, and refusing on that would have muted the app over a
             * bridge quirk.
             *
             * They no longer fail differently, because the premise was
             * measured and did not hold: across every arrangement of the macOS
             * probe -- four navigation targets, a document that arrived from a
             * remote origin, and a view with nothing loaded at all -- the read
             * never once threw. A catch insuring against something that does
             * not happen, at the price of admitting everything if it ever did,
             * is not a trade this file makes anywhere else.
             */
            try {
                var origin = frame.securityOrigin;
                var scheme = String(ObjCRef.unwrap(origin.protocol) || "");
                var host = String(ObjCRef.unwrap(origin.host) || "");
                if (this.isTrustedOrigin(scheme, host)) {
                    return true;
                }
                this.note("refused a message from " + scheme + "://" + host);
                return false;
            } catch (e) {
                this.note("refused a message whose sender's origin could not " +
                    "be read: " + e);
                return false;
            }
        },

        parseMessage: function (raw) {
            var text = String(raw == null ? "" : raw);
            if (text.length > 4096) {
                return null;
            }

            var sep = this.messageSeparator;
            var cut = text.indexOf(sep);
            var action = (cut < 0) ? text : text.substring(0, cut);
            var rest = (cut < 0) ? null : text.substring(cut + 1);

            if (action === "close") {
                return (rest === null) ? { action: "close" } : null;
            }

            if (action === "setTitle") {
                if (rest === null || rest.length > 1024 || this.hasControlCharacters(rest)) {
                    return null;
                }
                return { action: "setTitle", title: rest };
            }

            if (action === "openExternal") {
                if (rest === null || !this.isExternalUrl(rest)) {
                    return null;
                }
                // Said rather than dropped, because a page whose link does
                // nothing and whose host says nothing is a build that looks
                // broken instead of a build that is offline.
                if (!this.mayOpenExternal(rest)) {
                    this.note("refused openExternal: this build is offline");
                    return null;
                }
                return { action: "openExternal", url: rest };
            }

            if (action === "resize" || action === "move") {
                if (rest === null) {
                    return null;
                }
                var parts = rest.split(sep);
                if (parts.length !== 2) {
                    return null;
                }
                if (action === "resize") {
                    if (!this.isDimension(parts[0]) || !this.isDimension(parts[1])) {
                        return null;
                    }
                    return {
                        action: "resize",
                        width: parseInt(parts[0], 10),
                        height: parseInt(parts[1], 10)
                    };
                }
                if (!this.isCoordinate(parts[0]) || !this.isCoordinate(parts[1])) {
                    return null;
                }
                return { action: "move", x: parseInt(parts[0], 10), y: parseInt(parts[1], 10) };
            }

            return null;
        },

        buildPreloadScript: function (transport, name) {
            return '(function(){' +
                'var S=String.fromCharCode(31);' +
                'var _send=function(m){try{(' + transport + ')(m);}catch(_){}};' +
                'var _n=function(v){return String(v===undefined||v===null?"":v);};' +
                'window.neutrino={' +
                // Which channel the host is actually listening on. The page can
                // work this out by feature detection anyway, so naming it costs
                // nothing and lets a test report it instead of inferring it.
                'transport:"' + String(name || "unknown") + '",' +
                'send:function(action,data){' +
                'var d=data||{};' +
                'if(action==="setTitle")_send("setTitle"+S+_n(d.title));' +
                'else if(action==="resize")_send("resize"+S+_n(d.width)+S+_n(d.height));' +
                'else if(action==="move")_send("move"+S+_n(d.x)+S+_n(d.y));' +
                'else if(action==="openExternal")_send("openExternal"+S+_n(d.url));' +
                'else if(action==="close")_send("close");' +
                '},' +
                'shell:{' +
                'openExternal:function(url){window.neutrino.send("openExternal",{url:url});}' +
                '},' +
                'window:{' +
                'setTitle:function(t){window.neutrino.send("setTitle",{title:t});},' +
                'resize:function(w,h){window.neutrino.send("resize",{width:w,height:h});},' +
                'move:function(x,y){window.neutrino.send("move",{x:x,y:y});},' +
                'close:function(){window.neutrino.send("close");}' +
                '}' +
                '};' +
                '})();';
        },

        routeMessage: function (actions, raw) {
            var msg = this.parseMessage(raw);
            if (msg && actions[msg.action]) {
                actions[msg.action](msg);
            }
        },

        /*
         * No script may load or run from this document. Nothing in it is a
         * script any more -- this file's code and the author's both arrive
         * through the engine's own injection, which measurement says is exempt
         * from the policy the document carries.
         *
         * 'unsafe-eval' is there because eval is not exempt, and this file is
         * built on it: every runtime detection here goes through eval, which is
         * the documented way to keep jsc.exe from failing at compile time on
         * globals that do not exist on Windows. With script-src 'none' the
         * injected script ran and then could not identify the runtime it was
         * running in. It reads worse than it is -- eval is reachable only to
         * script that is already executing, and no script in this document can
         * begin executing: not an inline one, not a src, not a rewritten base.
         *
         * Denying the page the network is a real change to what an app can do,
         * so it is the offline tier's business and not the default's. An app
         * that fetches from its own backend is an ordinary app, not a
         * misbehaving one.
         */
        defaultContentPolicy: "script-src 'unsafe-eval'; object-src 'none'; " +
            "base-uri 'none'; form-action 'none'; frame-src 'none'",

        /*
         * The offline tier's policy, and what it is measured to be worth.
         *
         * It holds where it applies: an app's own page script, injected by the
         * engine, was measured reaching for the network nine ways -- fetch,
         * XMLHttpRequest, img, a stylesheet link, a script src, an iframe,
         * sendBeacon, EventSource, WebSocket -- and under this policy not one
         * of the nine reached the host on any of the four engines, while all
         * nine reached it under the policy above. So the exemption the comment
         * above describes stops at *executing*: what the exempt script then
         * loads is governed. WebView2 honours it too, from a document handed
         * over by NavigateToString.
         *
         * Two things it cannot see, because neither is a subresource load.
         *
         * The first is a url handed to the machine's browser, and that one is
         * closed -- see mayOpenExternal.
         *
         * The second is the request a top-level navigation makes on its way to
         * being refused, and that one is a **ceiling and not a fix**. Measured
         * against a loopback target that logs every request: on gjs and Qt the
         * refusal happens before the request, and nothing arrives. On macOS
         * nothing refuses at all -- PR 6 measured that implementing the policy
         * selector ships a window that never loads, so the guard is
         * -stopLoading after the document has committed -- and on the runner
         * image this was measured on, not even that: the bridge has no such
         * selector and the refusal raises, which PR 22 found in the job log
         * and filed on its own. On Windows NavigationStarting
         * cancels, the target document never runs, and the GET still reaches
         * the host. So on two of four engines an offline build leaks one
         * request per navigation attempt, with whatever the page put in the
         * url. Denying the process the network is netinstall's
         * -DNEUTRINO_CONFINE_OFFLINE, which is a different mechanism at a lower
         * layer, and the two compose.
         */
        offlineContentPolicy: "default-src 'none'; script-src 'unsafe-eval'; " +
            "style-src 'unsafe-inline'; img-src data:; font-src data:; " +
            "object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'",

        applyContentPolicy: function (html) {
            if (!this.hasTier("offline")) {
                return html;
            }
            // Anchored on the attribute, so it cannot match this file's own
            // mention of the policy string further down the document -- the
            // whole script region is inside the document it is describing.
            return String(html).replace(
                'content="' + this.defaultContentPolicy + '"',
                'content="' + this.offlineContentPolicy + '"'
            );
        },

        boot: function (driver, config) {
            driver.init();
            var scriptPath = driver.getScriptPath();
            var source = driver.readFile(scriptPath);
            var html = this.applyContentPolicy(this.extractHtmlDocument(source));
            var pageScript = this.extractPageScript(source);

            var win = driver.createWindow(config);

            if (driver.onWebMessage) {
                var self = this;
                var driverRef = driver;
                var winRef = win;
                var actions = {};
                if (driverRef.setTitle) actions.setTitle = function (m) { try { driverRef.setTitle(winRef, m.title); } catch (_) {} };
                if (driverRef.resize) actions.resize = function (m) { try { driverRef.resize(winRef, m.width, m.height); } catch (_) {} };
                if (driverRef.move) actions.move = function (m) { try { driverRef.move(winRef, m.x, m.y); } catch (_) {} };
                if (typeof driverRef["close"] === "function") actions["close"] = function (m) { try { driverRef["close"](winRef); } catch (_) {} };
                if (driverRef.openExternal) actions.openExternal = function (m) { try { driverRef.openExternal(m.url); } catch (_) {} };
                driver.onWebMessage(function (json) {
                    self.routeMessage(actions, json);
                });
            }

            /*
             * Every driver injects through its engine now, so the preload is
             * never spliced into the markup as text. The old splice looked for
             * a literal "<head>" and silently injected nothing when it did not
             * find one, which meant the API could go missing without anything
             * saying so.
             */
            if (driver.webMessageTransport) {
                driver.injectPreload(null, this.buildPreloadScript(
                    driver.webMessageTransport, driver.transportName));
            }

            if (driver.injectPageScript) {
                driver.injectPageScript(pageScript);
            }

            var wv = driver.createWebView();

            driver.loadHTML(wv, html, scriptPath);
            driver.attachWebView(win, wv);
            driver.showWindow(win);
            driver.runEventLoop(win, wv);
        },

        runMacOS: function () {
            // Any one of the bridge calls in this driver failing leaves no
            // window at all, which is the least informative outcome available.
            try {
                this.boot(this.createMacDriver(), this.config);
            } catch (e) {
                this.note("could not start: " + e);
                throw e;
            }
        },

        runGjs: function () {
            this.boot(this.createGjsDriver(), this.config);
        },

        hasWebView2Assemblies: function (SystemRef, libDir) {
            if (!libDir) {
                return false;
            }
            return SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.Core.dll")) &&
                SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.WinForms.dll"));
        },

        findWebView2LibDir: function (SystemRef, appFolder) {
            /*
             * This is an environment variable that ends at Assembly.LoadFrom,
             * so anything able to set it chooses which code this process loads.
             * netinstall's environment allowlist keeps the whole NEUTRINO_
             * prefix, so it arrives intact even there. A release build does not
             * read it; the tests that need to point at a prepared package build
             * with the testing tier.
             */
            var envLibDir = this.hasTier("testing")
                ? SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR")
                : null;
            if (this.hasWebView2Assemblies(SystemRef, envLibDir)) {
                return envLibDir;
            }

            var directNet462 = SystemRef.IO.Path.Combine(appFolder, "Microsoft.Web.WebView2", "lib", "net462");
            if (this.hasWebView2Assemblies(SystemRef, directNet462)) {
                return directNet462;
            }

            var directNet45 = SystemRef.IO.Path.Combine(appFolder, "Microsoft.Web.WebView2", "lib", "net45");
            if (this.hasWebView2Assemblies(SystemRef, directNet45)) {
                return directNet45;
            }

            if (SystemRef.IO.Directory.Exists(appFolder)) {
                var packageDirs = SystemRef.IO.Directory.GetDirectories(appFolder, "Microsoft.Web.WebView2*");
                for (var i = 0; i < packageDirs.Length; i++) {
                    var candidateNet462 = SystemRef.IO.Path.Combine(packageDirs[i], "lib", "net462");
                    if (this.hasWebView2Assemblies(SystemRef, candidateNet462)) {
                        return candidateNet462;
                    }

                    var candidateNet45 = SystemRef.IO.Path.Combine(packageDirs[i], "lib", "net45");
                    if (this.hasWebView2Assemblies(SystemRef, candidateNet45)) {
                        return candidateNet45;
                    }
                }
            }

            return null;
        },

        prependLoaderPaths: function (SystemRef, webView2LibDir) {
            if (!webView2LibDir) {
                return;
            }

            var packageRoot = this.webView2PackageRootOf(SystemRef, webView2LibDir);
            var loaderPaths = "";

            var x86Loader = SystemRef.IO.Path.Combine(packageRoot, "runtimes", "win-x86", "native", "WebView2Loader.dll");
            if (SystemRef.IO.File.Exists(x86Loader)) {
                loaderPaths = SystemRef.IO.Path.GetDirectoryName(x86Loader) + ";" + loaderPaths;
            }

            var x64Loader = SystemRef.IO.Path.Combine(packageRoot, "runtimes", "win-x64", "native", "WebView2Loader.dll");
            if (SystemRef.IO.File.Exists(x64Loader)) {
                loaderPaths = SystemRef.IO.Path.GetDirectoryName(x64Loader) + ";" + loaderPaths;
            }

            var arm64Loader = SystemRef.IO.Path.Combine(packageRoot, "runtimes", "win-arm64", "native", "WebView2Loader.dll");
            if (SystemRef.IO.File.Exists(arm64Loader)) {
                loaderPaths = SystemRef.IO.Path.GetDirectoryName(arm64Loader) + ";" + loaderPaths;
            }

            if (loaderPaths) {
                var currentPath = SystemRef.Environment.GetEnvironmentVariable("PATH");
                if (!currentPath) {
                    currentPath = "";
                }
                SystemRef.Environment.SetEnvironmentVariable("PATH", loaderPaths + currentPath);
            }
        },

        escapeForSingleQuotedPowerShell: function (value) {
            if (!value) {
                return "";
            }
            return String(value).replace(/'/g, "''");
        },

        /*
         * The package this build was made against, named by version and by the
         * digest of the archive that version resolves to. Both are checked --
         * the version alone only says which name was asked for, and a name is
         * not what gets loaded.
         *
         * netinstall names every artifact it fetches by SHA-256 and re-checks
         * it on every launch. This fetch used to be "whatever nuget.org serves
         * today", which made the one directory the launcher loads code from the
         * only thing in the chain nobody was verifying.
         *
         * Bumping this means changing the version, the archive digest and every
         * member digest together. They are asserted against each other, so
         * changing one alone fails the build's own suite rather than silently
         * accepting a package nobody looked at.
         */
        webView2PinnedVersion: "1.0.4129.50",
        webView2PinnedSha256: "d3934f482d484b89fb4825df720c710664e1143a1e90f7b3a60794ef33f473d2",

        /*
         * Exactly what is taken out of the archive, and what each one has to
         * hash to. The package is ~45 MB unpacked and almost all of it is
         * native build headers and import libs for C++ hosts; these are the
         * managed assemblies and the loaders, which is everything this app ever
         * touches.
         *
         * This list replaces a regular expression, and that is the fix for the
         * zip-slip rather than a better regular expression. The old form built
         * a destination out of the name the archive supplied -- and `[^/]+`
         * admits backslashes, so `lib/net462/..\..\..\..\x.dll` matched the
         * pattern and named a file four directories above the one being
         * extracted into. Measured, twice: it wrote out of the package
         * directory and into the user's profile directory. Now the extractor
         * asks the archive for names it already holds, and the name that
         * becomes a path is one of these literals. There is no attacker-shaped
         * string on that side of the join any more.
         */
        webView2Members: [
            { path: "lib/net462/Microsoft.Web.WebView2.Core.dll",
              sha256: "958efdb7f13a6d1f3079756c96956cc96cf713ae46fa085c8b1e7f44316a4f7e" },
            { path: "lib/net462/Microsoft.Web.WebView2.WinForms.dll",
              sha256: "a7b8be525030f19d9e88c6e684bca053dc7a3b080c31c3d9428f7438e7b6768f" },
            { path: "lib/net462/Microsoft.Web.WebView2.Wpf.dll",
              sha256: "217874fcb11722cf41a11c6d0483eab3f9d9c310d63486068f194614a7778a56" },
            { path: "runtimes/win-arm64/native/WebView2Loader.dll",
              sha256: "b0bfa03347a00169903c4ef0c27579dd9e85236a6dcd637a941d20b86eeec8fc" },
            { path: "runtimes/win-x64/native/WebView2Loader.dll",
              sha256: "a9a09232c25805323d4cfb3fc8f545a190a9c8a99c93262ea99d0b88df99ec90" },
            { path: "runtimes/win-x86/native/WebView2Loader.dll",
              sha256: "cbcd9a820b23aec9d68a95fb8cfd8c7d48e5bac1129faaf87aecabf4409a2ee2" }
        ],

        /*
         * The flat container serves the archive at its final address with no
         * redirect. The v2 API this used to call answers with the same bytes
         * but by way of a CDN hop, and a pin has no use for an extra place to
         * be wrong.
         */
        webView2PackageUrl: function () {
            var v = this.webView2PinnedVersion;
            return "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/" +
                v + "/microsoft.web.webview2." + v + ".nupkg";
        },

        sha256Hex: function (SystemRef, path) {
            var hasher = SystemRef.Security.Cryptography.SHA256.Create();
            var stream = SystemRef.IO.File.OpenRead(path);
            var digest;
            try {
                digest = hasher.ComputeHash(stream);
            } finally {
                stream.Close();
            }
            return String(SystemRef.BitConverter.ToString(digest)).replace(/-/g, "").toLowerCase();
        },

        /*
         * Returns null when every pinned member is present and hashes to what
         * it should, and the path of the first one that does not otherwise. An
         * unreadable file is a failure and not an exception: the caller's answer
         * to both is the same, which is to throw the directory away and fetch
         * the package again.
         */
        firstBadWebView2Member: function (SystemRef, packageRoot) {
            for (var i = 0; i < this.webView2Members.length; i++) {
                var member = this.webView2Members[i];
                var full = SystemRef.IO.Path.Combine(packageRoot, member.path.replace(/\//g, "\\"));
                try {
                    if (!SystemRef.IO.File.Exists(full)) {
                        return member.path;
                    }
                    if (this.sha256Hex(SystemRef, full) !== member.sha256) {
                        return member.path;
                    }
                } catch (_) {
                    return member.path;
                }
            }
            return null;
        },

        extractArchiveWithPowerShell: function (SystemRef, archivePath, destinationPath) {
            var wanted = [];
            for (var i = 0; i < this.webView2Members.length; i++) {
                wanted.push("'" + this.escapeForSingleQuotedPowerShell(this.webView2Members[i].path) + "'");
            }

            var psCommand = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; " +
                "Add-Type -AssemblyName System.IO.Compression.FileSystem; " +
                "$src='" + this.escapeForSingleQuotedPowerShell(String(archivePath)) + "'; " +
                "$dst='" + this.escapeForSingleQuotedPowerShell(String(destinationPath)) + "'; " +
                "$want=@(" + wanted.join(",") + "); " +
                "$zip=[System.IO.Compression.ZipFile]::OpenRead($src); " +
                "try { foreach ($name in $want) { " +
                "$e=$zip.GetEntry($name); " +
                "if ($e -eq $null) { throw ('package is missing ' + $name) }; " +
                "$out=Join-Path $dst ($name.Replace([char]47,[char]92)); " +
                "$dir=Split-Path -Parent $out; " +
                "if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }; " +
                "[System.IO.Compression.ZipFileExtensions]::ExtractToFile($e,$out,$true) } } " +
                "finally { $zip.Dispose() }";

            var encodedCommand = SystemRef.Convert.ToBase64String(SystemRef.Text.Encoding.Unicode.GetBytes(psCommand));

            var startInfo = new SystemRef.Diagnostics.ProcessStartInfo();
            startInfo.FileName = "powershell.exe";
            startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encodedCommand;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;

            var process = SystemRef.Diagnostics.Process.Start(startInfo);
            process.WaitForExit();

            if (process.ExitCode !== 0) {
                throw new Error("WebView2 package extraction failed with exit code " + process.ExitCode + ".");
            }
        },

        /*
         * How long a failed initialisation stays on screen. A constant, because
         * it is not a caller's decision: the box has to be readable by a person
         * who is there and finite for a machine that is not, and no environment
         * gets to make it either zero or forever.
         */
        windowsErrorSeconds: 20,

        /*
         * A failed initialisation, said in both places it can be heard.
         *
         * This was MessageBox.Show and then Environment.Exit, and the box never
         * returns. Measured on a runner with nobody at it, in three shapes in
         * one step: detached -- which is the only way `START "" ... .exe` ever
         * launches this -- and with both handles redirected, the process was
         * still up holding its window when the probe gave up; and the shipped
         * driver did the same for ninety seconds after a real download threw.
         * Nobody clicks it, so the run ends on somebody's timeout rather than
         * on the error, and the error itself is never said anywhere.
         *
         * Two obvious alternatives were measured not to work.
         * Environment.UserInteractive reads true on an unattended runner, so it
         * cannot tell a machine from a person. And a /t:winexe process launched
         * detached gets NullStream for Console.Out and Console.Error both, so
         * writing the error out reaches nobody unless the caller happened to
         * hand it handles -- which the .cmd, which uses START, does not.
         *
         * So: a box that lets go by itself, and a file that stays.
         */
        showWindowsError: function (SystemRef, title, message) {
            var written = this.recordWindowsError(SystemRef, title, message);
            var shown = String(message);
            if (written) {
                shown = shown + "\n\n" + written;
            }
            this.showBoundedError(SystemRef, title, shown);
        },

        /*
         * The failure, written where it outlives the process. Measured: after a
         * real failed initialisation the app folder held the exe, its manifest
         * and the build stamp, and nothing at all that named what went wrong --
         * so a machine that hit this had no way to find out why, then or later.
         *
         * Best effort by construction, and the return value says whether it
         * worked so the box can name the file when there is one. If this throws
         * there is nowhere left to say so, and the box is still worth putting up.
         */
        recordWindowsError: function (SystemRef, title, message) {
            var written = "";
            try {
                var path = SystemRef.IO.Path.Combine(
                    SystemRef.Windows.Forms.Application.StartupPath,
                    "neutrino-error.log"
                );
                SystemRef.IO.File.WriteAllText(
                    path,
                    String(title) + "\r\n" +
                    SystemRef.DateTime.UtcNow.ToString("u") + "\r\n\r\n" +
                    String(message) + "\r\n"
                );
                written = path;
            } catch (_) {
            }
            /*
             * Free when a caller did hand this process handles, and silently
             * nothing when it did not -- which is why the file above exists and
             * this is not the whole story. Measured both ways.
             */
            try {
                SystemRef.Console.Error.WriteLine(String(title) + ": " + String(message));
                if (written) {
                    SystemRef.Console.Error.WriteLine("neutrino: written to " + written);
                }
                SystemRef.Console.Error.Flush();
            } catch (_) {
            }
            return written;
        },

        /*
         * The same box, driven by the loop this driver already runs on rather
         * than by one it cannot reach into. runEventLoop is Show() and then
         * DoEvents()/Sleep() while the window is visible; the download progress
         * form is the same; this is that with a deadline in the condition. A
         * person closing it ends the loop early, and nobody closing it ends the
         * loop anyway.
         *
         * Measured detached, with nobody at the machine: the window was on
         * screen for the whole deadline and the process was gone afterwards --
         * in the same step, on the same binary, where MessageBox.Show was still
         * up holding a window. That the window was actually painted is half the
         * measurement: a box that disposes itself before it is shown ends just
         * as promptly and is no use to the person it is for.
         */
        showBoundedError: function (SystemRef, title, message) {
            try {
                var form = new SystemRef.Windows.Forms.Form();
                form.Text = String(title);
                form.FormBorderStyle = SystemRef.Windows.Forms.FormBorderStyle.FixedDialog;
                form.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;
                form.ClientSize = new SystemRef.Drawing.Size(440, 148);
                form.MinimizeBox = false;
                form.MaximizeBox = false;
                form.TopMost = true;

                var label = new SystemRef.Windows.Forms.Label();
                label.AutoSize = false;
                label.TextAlign = SystemRef.Drawing.ContentAlignment.TopLeft;
                label.SetBounds(16, 12, 408, 120);
                label.Text = String(message);
                form.Controls.Add(label);

                form.Show();
                form.Refresh();
                SystemRef.Windows.Forms.Application.DoEvents();

                /*
                 * Ticks rather than DateTimes, so the comparison is an int
                 * comparison. TickCount wraps every 24.9 days; the subtraction
                 * is what keeps a wrap from either ending the box immediately or
                 * never ending it.
                 */
                var start = SystemRef.Environment.TickCount;
                var budget = this.windowsErrorSeconds * 1000;
                while (form.Visible && (SystemRef.Environment.TickCount - start) < budget) {
                    SystemRef.Windows.Forms.Application.DoEvents();
                    SystemRef.Threading.Thread.Sleep(16);
                }
                form.Close();
            } catch (_) {
            }
        },

        downloadWebView2WithProgress: function (SystemRef, appFolder) {
            var packageRoot = SystemRef.IO.Path.Combine(appFolder, "Microsoft.Web.WebView2");
            var tempPackagePath = SystemRef.IO.Path.Combine(
                SystemRef.IO.Path.GetTempPath(),
                "Microsoft.Web.WebView2." + SystemRef.Guid.NewGuid().ToString("N") + ".zip"
            );
            var packageUrl = this.webView2PackageUrl();

            var progressForm = new SystemRef.Windows.Forms.Form();
            progressForm.Text = "Downloading WebView2 Runtime";
            progressForm.FormBorderStyle = SystemRef.Windows.Forms.FormBorderStyle.FixedDialog;
            progressForm.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;
            progressForm.ClientSize = new SystemRef.Drawing.Size(440, 92);
            progressForm.ControlBox = false;
            progressForm.TopMost = true;

            var progressLabel = new SystemRef.Windows.Forms.Label();
            progressLabel.AutoSize = false;
            progressLabel.TextAlign = SystemRef.Drawing.ContentAlignment.MiddleLeft;
            progressLabel.SetBounds(16, 12, 408, 20);
            progressLabel.Text = "Starting download...";

            var progressBar = new SystemRef.Windows.Forms.ProgressBar();
            progressBar.SetBounds(16, 40, 408, 22);
            progressBar.Minimum = 0;
            progressBar.Maximum = 100;
            progressBar.Style = SystemRef.Windows.Forms.ProgressBarStyle.Continuous;

            progressForm.Controls.Add(progressLabel);
            progressForm.Controls.Add(progressBar);
            progressForm.Show();
            progressForm.Refresh();
            SystemRef.Windows.Forms.Application.DoEvents();

            var response = null;
            var responseStream = null;
            var fileStream = null;

            try {
                if (SystemRef.IO.Directory.Exists(packageRoot)) {
                    SystemRef.IO.Directory.Delete(packageRoot, true);
                }

                /*
                 * TLS 1.0 and 1.1 were enabled here alongside 1.2. Turning a
                 * protocol on does not make a server offer it, but it does mean
                 * this client would accept one that did, which is the whole
                 * point of a downgrade. nuget.org has not spoken either of them
                 * for years. 1.3 is set where the framework knows the value and
                 * ignored where it does not.
                 */
                try {
                    var tls12 = 3072;
                    var tls13 = 12288;
                    SystemRef.Net.ServicePointManager.SecurityProtocol = tls12 | tls13;
                } catch (_) {
                    try {
                        SystemRef.Net.ServicePointManager.SecurityProtocol = 3072;
                    } catch (_) {
                    }
                }

                var request = SystemRef.Net.WebRequest.Create(packageUrl);
                response = request.GetResponse();
                responseStream = response.GetResponseStream();

                var totalBytes = response.ContentLength;
                if (totalBytes <= 0) {
                    progressBar.Style = SystemRef.Windows.Forms.ProgressBarStyle.Marquee;
                    progressLabel.Text = "Downloading package...";
                }

                fileStream = new SystemRef.IO.FileStream(tempPackagePath, SystemRef.IO.FileMode.Create, SystemRef.IO.FileAccess.Write, SystemRef.IO.FileShare.None);
                var buffer = System.Array.CreateInstance(System.Byte, 32768);
                var downloadedBytes = 0;
                var lastPercentage = -1;
                var bytesRead = 0;

                while ((bytesRead = responseStream.Read(buffer, 0, buffer.Length)) > 0) {
                    fileStream.Write(buffer, 0, bytesRead);
                    downloadedBytes += bytesRead;

                    if (totalBytes > 0) {
                        var percentage = System.Math.Min(100, System.Convert.ToInt32((downloadedBytes * 100.0) / totalBytes));
                        if (percentage !== lastPercentage) {
                            progressBar.Value = percentage;
                            progressLabel.Text = "Downloading package... " + percentage + "%";
                            lastPercentage = percentage;
                        }
                    }

                    SystemRef.Windows.Forms.Application.DoEvents();
                }

                fileStream.Close();
                fileStream = null;
                responseStream.Close();
                responseStream = null;
                response.Close();
                response = null;

                if (totalBytes > 0) {
                    progressBar.Value = 100;
                }
                progressLabel.Text = "Verifying package...";
                SystemRef.Windows.Forms.Application.DoEvents();

                /*
                 * Before anything is taken out of it, and before anything is
                 * written where the app will later load code from. A mismatch
                 * is fatal rather than a fallback: there is no weaker thing to
                 * fall back to that is still this app.
                 */
                var digest = this.sha256Hex(SystemRef, tempPackagePath);
                if (digest !== this.webView2PinnedSha256) {
                    throw new Error("WebView2 package does not match its pin.\n\nexpected " +
                        this.webView2PinnedSha256 + "\ngot      " + digest);
                }

                progressLabel.Text = "Extracting package...";
                SystemRef.Windows.Forms.Application.DoEvents();

                this.extractArchiveWithPowerShell(SystemRef, tempPackagePath, packageRoot);
            } catch (exDownload) {
                var message = "Download/extract failed.";
                try {
                    if (exDownload && exDownload.message) {
                        message = message + "\n\n" + String(exDownload.message);
                    }
                } catch (_) {
                }
                try {
                    message = message + "\n\n" + String(exDownload);
                } catch (_) {
                }
                throw new Error(message);
            } finally {
                if (fileStream) {
                    fileStream.Close();
                }
                if (responseStream) {
                    responseStream.Close();
                }
                if (response) {
                    response.Close();
                }
                if (SystemRef.IO.File.Exists(tempPackagePath)) {
                    SystemRef.IO.File.Delete(tempPackagePath);
                }
                progressForm.Close();
                progressForm.Dispose();
            }
        },

        webView2PackageRootOf: function (SystemRef, libDir) {
            return SystemRef.IO.Path.GetFullPath(SystemRef.IO.Path.Combine(libDir, "..", ".."));
        },

        /*
         * The pin is re-checked on every launch and not only on download, which
         * is netinstall's rule for the launcher and had no counterpart here.
         * This used to return the first directory holding two files with the
         * right names, so an app directory somebody had been in was reused
         * without anything being looked at -- and what is in there is what
         * Assembly.LoadFrom loads.
         *
         * A package that does not match is not an error on its own. It is what
         * an older pin looks like after this file is updated, so the answer is
         * to fetch the one this build names; downloadWebView2WithProgress
         * deletes the directory before writing to it. It only becomes fatal
         * when a freshly extracted package is still wrong, because then it is
         * not staleness.
         */
        ensureWebView2Package: function (SystemRef, appFolder) {
            var existingLibDir = this.findWebView2LibDir(SystemRef, appFolder);
            if (existingLibDir &&
                !this.firstBadWebView2Member(SystemRef, this.webView2PackageRootOf(SystemRef, existingLibDir))) {
                return existingLibDir;
            }

            if (!SystemRef.IO.Directory.Exists(appFolder)) {
                SystemRef.IO.Directory.CreateDirectory(appFolder);
            }

            this.downloadWebView2WithProgress(SystemRef, appFolder);

            var libDir = this.findWebView2LibDir(SystemRef, appFolder);

            if (!libDir) {
                throw new Error("WebView2 package download completed but required assemblies were not found.");
            }

            var bad = this.firstBadWebView2Member(SystemRef, this.webView2PackageRootOf(SystemRef, libDir));
            if (bad) {
                throw new Error("WebView2 package member does not match its pin: " + bad);
            }
            return libDir;
        },

        /*
         * Reached by reflection because the type comes from an assembly loaded
         * at run time, and set one at a time so that a runtime too old to know
         * one property still gets the others. None of these are a sandbox --
         * WebView2 sandboxes its own renderers and that is the real boundary --
         * they close the doors this app has no use for.
         */
        hardenWebView2: function (coreWv2) {
            var settings = null;
            try {
                settings = coreWv2.GetType().GetProperty("Settings").GetValue(coreWv2, null);
            } catch (_) {
                return;
            }
            if (!settings) {
                return;
            }

            var off = [
                "AreDevToolsEnabled",
                "AreDefaultContextMenusEnabled",
                "AreHostObjectsAllowed",
                "IsStatusBarEnabled",
                "IsSwipeNavigationEnabled",
                "AreBrowserAcceleratorKeysEnabled",
                "IsGeneralAutofillEnabled",
                "IsPasswordAutosaveEnabled",
                "IsPinchZoomEnabled"
            ];

            for (var i = 0; i < off.length; i++) {
                try {
                    var prop = settings.GetType().GetProperty(off[i]);
                    if (prop && prop.CanWrite) {
                        prop.SetValue(settings, false, null);
                    }
                } catch (_) {}
            }
        },

        /*
         * Subscribe to CoreWebView2.WebMessageReceived. Everything here is
         * reflection because the types arrive with an assembly loaded at run
         * time, and the delegate is built by CreateDelegate against the event's
         * own handler type for the same reason.
         *
         * Returns true only if the subscription actually took. The caller keeps
         * reading the document title when it did not, because a Windows build
         * with no channel at all is worse than one with a channel a page can
         * write to -- but it is a real downgrade, so it is named in the report
         * rather than left to be inferred.
         */
        wireWebView2Messages: function (SystemRef, coreWv2) {
            try {
                var evt = coreWv2.GetType().GetEvent("WebMessageReceived");
                if (!evt) {
                    return false;
                }
                var sink = new NeutrinoWebMessageSink();
                var handler = SystemRef.Delegate.CreateDelegate(
                    evt.EventHandlerType, sink, sink.GetType().GetMethod("Handle")
                );
                evt.AddEventHandler(coreWv2, handler);
                return true;
            } catch (_) {
                return false;
            }
        },

        /*
         * The navigation policy, and the platform PRs 5 and 6 left out. gjs, Qt
         * and macOS each refuse a navigation away from the app's document, and
         * each comment says why: a page that moves itself to a remote origin is
         * then the document holding the channel to the native window. This
         * driver subscribed to no navigation event at all, and the preload and
         * the app author's own page script go in through
         * AddScriptToExecuteOnDocumentCreated, which registers them on the view
         * rather than on a document -- so whatever the page navigated to was
         * handed both. Measured, against a target that answered:
         * nav_arrived=YES, after_nav api=object page=number.
         *
         * Three subscriptions, and ContentLoading is one of them because the
         * gate has to be armed from inside the engine. NavigationStarting fires
         * for this driver's own load -- twice, as about:blank and then as the
         * data: url NavigateToString makes -- so a policy that refuses what it
         * does not recognise refuses the app's own document, which is PR 6's
         * lesson arriving from the other direction.
         *
         * Partial is reported rather than silently accepted: a guard that got
         * two of three is a different build from one that got all three.
         */
        wireWebView2Navigation: function (SystemRef, coreWv2) {
            var wanted = [
                ["NavigationStarting", "navstart"],
                ["NewWindowRequested", "newwindow"],
                ["ContentLoading", "commit"]
            ];
            var wired = 0;
            for (var i = 0; i < wanted.length; i++) {
                try {
                    var evt = coreWv2.GetType().GetEvent(wanted[i][0]);
                    if (!evt) {
                        continue;
                    }
                    var sink = new NeutrinoNavSink();
                    sink.kind = wanted[i][1];
                    evt.AddEventHandler(coreWv2, SystemRef.Delegate.CreateDelegate(
                        evt.EventHandlerType, sink, sink.GetType().GetMethod("Handle")
                    ));
                    wired++;
                } catch (_) {
                }
            }
            if (wired < wanted.length) {
                this.note("navigation guard wired " + wired + " of " +
                    wanted.length + " events; a navigation may not be refused here");
            }
            return wired === wanted.length;
        },

        /*
         * Whatever the guard refused, said out loud by the side of this file
         * that can say it. The decision itself is taken inside the handler --
         * Cancel and Handled are read the moment it returns -- so only the
         * telling is deferred to the loop.
         */
        drainNavRefusals: function () {
            while (NeutrinoNavSink.refusals.Count > 0) {
                var text = String(NeutrinoNavSink.refusals[0]);
                NeutrinoNavSink.refusals.RemoveAt(0);
                this.note(text);
            }
        },

        // The event args carry both the text and who sent it. Source is the url
        // of the document that called postMessage, and the document this file
        // loads through NavigateToString has none worth the name -- so a
        // message from anywhere else is from a page that was navigated to.
        readWebView2Message: function (args) {
            var source = "";
            try {
                source = String(args.GetType().GetProperty("Source").GetValue(args, null) || "");
            } catch (_) {
                return null;
            }
            if (!this.isOwnDocument(source)) {
                return null;
            }
            try {
                return String(args.GetType().GetMethod("TryGetWebMessageAsString").Invoke(args, null));
            } catch (_) {
                return null;
            }
        },

        createWindowsDriver: function () {
            var SystemRef = eval("System");
            var webViewWinFormsAssembly, webViewType;
            var appFolder, userDataDir;
            var self = this;
            var messageCallback = null;
            var lastDocTitle = "";
            var pendingPreload = null;
            var pendingPageScript = null;
            var settingsApplied = false;
            var webMessagesWired = false;

            return {
                /*
                 * A placeholder. Which transport the page is given cannot be
                 * decided here, because it depends on whether the event
                 * subscription takes, and CoreWebView2 does not exist until the
                 * event loop is running. So the preload is rebuilt there and
                 * this only has to be non-empty for boot to ask for one at all.
                 *
                 * Where it does end up being the title, the record is encoded:
                 * a record separator is a control character and a window title
                 * is not a faithful carrier for those.
                 */
                webMessageTransport: "function(m){document.title='__NEUTRINO__'+encodeURIComponent(m);}",
                transportName: "title",
                init: function () {
                    SystemRef.Windows.Forms.Application.EnableVisualStyles();
                    SystemRef.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);

                    appFolder = SystemRef.Windows.Forms.Application.StartupPath;
                    userDataDir = SystemRef.IO.Path.Combine(appFolder, "data");

                    var webView2LibDir = self.ensureWebView2Package(SystemRef, appFolder);
                    if (!webView2LibDir) {
                        SystemRef.Environment.Exit(1);
                        return;
                    }

                    SystemRef.Environment.SetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR", webView2LibDir);
                    self.prependLoaderPaths(SystemRef, webView2LibDir);

                    SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.Core.dll"));
                    webViewWinFormsAssembly = SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.WinForms.dll"));

                    webViewType = webViewWinFormsAssembly.GetType("Microsoft.Web.WebView2.WinForms.WebView2");
                    if (!webViewType) {
                        throw new Error("Could not load Microsoft.Web.WebView2.WinForms.WebView2 type.");
                    }
                },
                readFile: function (path) {
                    return SystemRef.IO.File.ReadAllText(path);
                },
                getScriptPath: function () {
                    var p = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH");
                    if (!p) {
                        throw new Error("Environment variable NEUTRINO_SCRIPT_PATH was not set.");
                    }
                    if (!SystemRef.IO.File.Exists(p)) {
                        throw new Error("Could not find local document: " + p);
                    }
                    return p;
                },
                createWindow: function (config) {
                    var win = new SystemRef.Windows.Forms.Form();
                    win.Text = config.title + " - Windows";
                    win.ClientSize = new SystemRef.Drawing.Size(config.width, config.height);
                    win.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;
                    return win;
                },
                createWebView: function () {
                    var wv = SystemRef.Activator.CreateInstance(webViewType);
                    if (userDataDir) {
                        try {
                            var cpType = webViewWinFormsAssembly.GetType("Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties");
                            if (cpType) {
                                var cp = SystemRef.Activator.CreateInstance(cpType);
                                try {
                                    cp.UserDataFolder = userDataDir;
                                    SystemRef.IO.Directory.CreateDirectory(cp.UserDataFolder);
                                    wv.CreationProperties = cp;
                                } catch (_) {}
                            }
                        } catch (_) {}
                    }
                    wv.Dock = SystemRef.Windows.Forms.DockStyle.Fill;
                    return wv;
                },
                attachWebView: function (win, wv) {
                    win.Controls.Add(wv);
                },
                loadHTML: function (wv, html) {
                    wv.Source = new SystemRef.Uri("about:blank");
                },
                setTitle: function (win, title) {
                    win.Text = title;
                },
                resize: function (win, w, h) {
                    win.ClientSize = new SystemRef.Drawing.Size(parseInt(w), parseInt(h));
                },
                move: function (win, x, y) {
                    win.Location = new SystemRef.Drawing.Point(parseInt(x), parseInt(y));
                },
                openExternal: function (url) {
                    // Process.Start on a bare string is ShellExecute, which will
                    // open a document, a .desktop-equivalent, or a registered
                    // protocol handler just as happily as a web page. The
                    // allowlist is what keeps it to web pages.
                    if (!self.mayOpenExternal(url)) {
                        return;
                    }
                    var info = new SystemRef.Diagnostics.ProcessStartInfo(String(url));
                    info.UseShellExecute = true;
                    SystemRef.Diagnostics.Process.Start(info);
                },
                showWindow: function () {},
                // Quoted for the same reason boot() reaches for it that way:
                // jsc.exe is stricter than the other three engines about names
                // that look like they might mean something.
                "close": function (win) {
                    win.Close();
                },
                onWebMessage: function (cb) {
                    messageCallback = cb;
                },
                injectPreload: function (wv, js) {
                    pendingPreload = js;
                },
                injectPageScript: function (js) {
                    pendingPageScript = js;
                },
                runEventLoop: function (win, wv) {
                    win.Show();
                    var coreWv2 = null;
                    var titleProp = null;
                    var sourceProp = null;
                    var preloadInjected = false;
                    while (win.Visible) {
                        SystemRef.Windows.Forms.Application.DoEvents();
                        SystemRef.Threading.Thread.Sleep(16);
                        try {
                            if (!coreWv2 && wv) {
                                var coreWv2Prop = wv.GetType().GetProperty("CoreWebView2");
                                if (coreWv2Prop) {
                                    coreWv2 = coreWv2Prop.GetValue(wv, null);
                                }
                            }
                            if (coreWv2 && !settingsApplied) {
                                settingsApplied = true;
                                self.hardenWebView2(coreWv2);

                                // Before the preload is built, because what the
                                // page is told to send on depends on whether
                                // this took.
                                webMessagesWired = self.wireWebView2Messages(SystemRef, coreWv2);
                                // Before anything is injected and before the
                                // app's own document is navigated to, so the
                                // gate is armed by that navigation and not
                                // after it.
                                self.wireWebView2Navigation(SystemRef, coreWv2);
                                pendingPreload = self.buildPreloadScript(
                                    webMessagesWired
                                        ? "function(m){window.chrome.webview.postMessage(m);}"
                                        : "function(m){document.title='__NEUTRINO__'+encodeURIComponent(m);}",
                                    webMessagesWired ? "webmessage" : "title"
                                );
                            }
                            if (coreWv2 && pendingPreload && !preloadInjected) {
                                preloadInjected = true;
                                var addScript = coreWv2.GetType().GetMethod("AddScriptToExecuteOnDocumentCreatedAsync");
                                if (addScript) {
                                    // The API first, then the page's own code,
                                    // both through the engine so the document
                                    // itself can forbid script.
                                    var sources = pendingPageScript
                                        ? [pendingPreload, pendingPageScript]
                                        : [pendingPreload];
                                    for (var si = 0; si < sources.length; si++) {
                                        var task = addScript.Invoke(coreWv2, [sources[si]]);
                                        if (task) {
                                            while (!task.IsCompleted) {
                                                SystemRef.Windows.Forms.Application.DoEvents();
                                                SystemRef.Threading.Thread.Sleep(10);
                                            }
                                        }
                                    }
                                }
                                var navMethod = coreWv2.GetType().GetMethod("NavigateToString");
                                var scriptPath = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH");
                                if (navMethod && scriptPath && SystemRef.IO.File.Exists(scriptPath)) {
                                    var htmlText = self.applyContentPolicy(self.extractHtmlDocument(
                                        SystemRef.IO.File.ReadAllText(scriptPath)));
                                    /*
                                     * Set before the call and not after it. The
                                     * navigation is queued here and its events
                                     * fire on the DoEvents below, so a flag set
                                     * after Invoke returns is still set in time
                                     * -- but only by luck of this method not
                                     * pumping, and the guard reads the flag
                                     * from inside the engine.
                                     */
                                    NeutrinoNavSink.navIssued = true;
                                    navMethod.Invoke(coreWv2, [htmlText]);
                                }
                            }
                            if (coreWv2) {
                                self.drainNavRefusals();
                            }
                            if (coreWv2 && messageCallback && webMessagesWired) {
                                // Drained here rather than handled in the event
                                // itself: the queue is a .NET static, which no
                                // document can reach, so nothing is lost by
                                // reading it on the same clock as everything
                                // else in this loop.
                                while (NeutrinoWebMessageSink.queue.Count > 0) {
                                    var queued = NeutrinoWebMessageSink.queue[0];
                                    NeutrinoWebMessageSink.queue.RemoveAt(0);
                                    var text = self.readWebView2Message(queued);
                                    if (text !== null) {
                                        messageCallback(text);
                                    }
                                }
                            } else if (coreWv2 && messageCallback) {
                                if (!titleProp) {
                                    titleProp = coreWv2.GetType().GetProperty("DocumentTitle");
                                    sourceProp = coreWv2.GetType().GetProperty("Source");
                                }
                                if (titleProp) {
                                    var docTitle = String(titleProp.GetValue(coreWv2, null) || "");
                                    /*
                                     * Who set it, asked the same way
                                     * readWebView2Message asks. This branch used
                                     * to ask nothing at all, which made this the
                                     * one driver that never checked a sender --
                                     * and wherever wireWebView2Messages returns
                                     * false it is the whole channel, so a page
                                     * navigated to could drive the native window
                                     * by writing its own title.
                                     *
                                     * Source is the reading that makes it
                                     * checkable and it had to be measured: the
                                     * view's Source stays about:blank across the
                                     * driver's NavigateToString, and names the
                                     * remote document once a navigation has
                                     * arrived -- polled on this same clock, a
                                     * foreign title and a foreign Source were
                                     * seen in the same pair.
                                     *
                                     * A view that cannot say what it is showing
                                     * is refused rather than trusted, which is
                                     * the rule isTrustedView already settled.
                                     */
                                    var showing = null;
                                    if (sourceProp) {
                                        try {
                                            showing = String(sourceProp.GetValue(coreWv2, null) || "");
                                        } catch (_) {
                                            showing = null;
                                        }
                                    }
                                    var mine = (showing !== null) && self.isOwnDocument(showing);
                                    if (docTitle !== lastDocTitle && docTitle.indexOf("__NEUTRINO__") === 0) {
                                        lastDocTitle = docTitle;
                                        if (mine) {
                                            try {
                                                messageCallback(decodeURIComponent(docTitle.substring(12)));
                                            } catch (_) {}
                                        } else {
                                            self.note("refused a record in the title of " +
                                                (showing === null ? "a view that did not say" : showing));
                                        }
                                    }
                                }
                            }
                        } catch (_) {}
                    }
                },
                handleError: function (ex) {
                    var detail = "Failed to initialize WebView2 package/download.";
                    try {
                        if (ex && ex.message) {
                            detail = detail + "\n\n" + String(ex.message);
                        }
                    } catch (_) {}
                    self.showWindowsError(SystemRef, "neutrino", detail);
                    SystemRef.Environment.Exit(1);
                }
            };
        },

        runWindows: function () {
            var driver = this.createWindowsDriver();
            try {
                this.boot(driver, this.config);
            } catch (ex) {
                driver.handleError(ex);
            }
        }
    };

    NeutrinoWebview.run();

//</script></head><body></body>
