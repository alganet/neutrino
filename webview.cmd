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

REM Compiled once and kept, and the placement is the whole of why it can be.
REM
REM It used to compile every launch. The app folder is the one directory
REM netinstall leaves writable, so an exe cached there is one the app itself can
REM replace -- measured on a runner as `poison ran=YES realapp=DOWN`, with the
REM stamp that vouched for it left exactly as this file wrote it, because that
REM stamp was as writable as the exe. Recompiling closed it by making the
REM artifact too short-lived to poison: 290 ms every launch, plus a 150 ms
REM window between the MOVE and the START that test/exerace.ps1 has to go on
REM measuring shut because closing it needs a handle cmd cannot hand over.
REM
REM Beside the script is a different place with a different rule. netinstall
REM puts the verified .cmd one level *above* the only writable directory --
REM "an app cannot rewrite the launcher it was verified from" -- so an exe kept
REM there is out of reach of the one process the recompile was defending
REM against. Anything else that can write here can write the .cmd itself and is
REM already running as this user, which is everything poisoning the exe would
REM have bought it; against that adversary the compile was buying a race it
REM never needed to run.
REM
REM The stamp is the source's SHA-256. It answers "was this exe built from this
REM script", which is the only question left once the exe is somewhere the app
REM cannot reach. It is deliberately not asked to vouch for the exe: nothing
REM able to rewrite the exe here is stopped by a value written beside it, so a
REM second digest would be ceremony. Size and modification time would have done
REM the same job, and the hash is here because it costs one certutil and cannot
REM be reproduced by hand.
REM
REM Two ways this ends up in the app folder compiling every launch, which is the
REM old path kept whole rather than a degraded one. An exe already sitting
REM beside the script with no stamp of ours next to it is somebody else's file
REM and is not adopted. And a script directory that refuses the stamp -- the
REM tight tier lowers this process's integrity and the shelf is above it -- has
REM nowhere to keep anything.
SET "CERTUTIL=%WINDIR%\System32\certutil.exe"
SET "APP_EXE=%SCRIPT_DIR%%SCRIPT_NAME%.exe"
SET "APP_STAMP=%SCRIPT_DIR%%SCRIPT_NAME%.stamp"
SET "MANIFEST=%APP_EXE%.manifest"

IF EXIST "%APP_EXE%" IF NOT EXIST "%APP_STAMP%" (
    SET "APP_EXE=%APP_FOLDER%\%SCRIPT_NAME%.exe"
    SET "APP_STAMP="
    SET "MANIFEST=%APP_FOLDER%\%SCRIPT_NAME%.exe.manifest"
)

REM The digest of the file being run, which is also the file being compiled.
REM Empty if certutil is not there or would not answer, and an empty one takes
REM the compile path rather than trusting whatever is cached.
REM %CERTUTIL% is deliberately unquoted. `FOR /F usebackq` hands the backticked
REM command to a nested cmd, and one that *begins* with a quote comes back as
REM "The filename, directory name, or volume label syntax is incorrect" with no
REM output and no error the loop can see -- measured, and it is how the first
REM version of this shipped a stamp reading "ECHO is off." while everything else
REM looked right. %WINDIR%\System32 cannot contain a space, so the quotes bought
REM nothing there; "%~f0" keeps its own, and a script under a path with spaces
REM was measured hashing correctly.
SET "SRC_HASH="
IF EXIST "%CERTUTIL%" (
    FOR /F "usebackq skip=1 tokens=* delims=" %%H IN (`%CERTUTIL% -hashfile "%~f0" SHA256`) DO (
        IF NOT DEFINED SRC_HASH SET "SRC_HASH=%%H"
    )
)
IF DEFINED SRC_HASH SET "SRC_HASH=!SRC_HASH: =!"

SET "CACHED_HASH="
IF DEFINED APP_STAMP IF EXIST "%APP_STAMP%" (
    FOR /F "usebackq tokens=* delims=" %%S IN ("%APP_STAMP%") DO (
        IF NOT DEFINED CACHED_HASH SET "CACHED_HASH=%%S"
    )
)

FOR %%D IN ("%APP_EXE%") DO SET "EXE_DIR=%%~dpD"
SET "APP_NEW=%EXE_DIR%%SCRIPT_NAME%.new%RANDOM%%RANDOM%.exe"
SET "APP_OLD=%EXE_DIR%%SCRIPT_NAME%.old%RANDOM%%RANDOM%.exe"
DEL /Q "%EXE_DIR%%SCRIPT_NAME%.new*.exe" >NUL 2>&1
DEL /Q "%EXE_DIR%%SCRIPT_NAME%.old*.exe" >NUL 2>&1

IF NOT DEFINED SRC_HASH GOTO :BUILD
IF NOT DEFINED CACHED_HASH GOTO :BUILD
IF NOT EXIST "%APP_EXE%" GOTO :BUILD
IF /I NOT "!CACHED_HASH!"=="!SRC_HASH!" GOTO :BUILD
GOTO :RUN

:BUILD
REM Claiming the stamp before the compile is also the test of whether this
REM directory can be written at all, and it costs no probe file of its own. A
REM launch that dies between here and the MOVE leaves a stamp naming a digest no
REM exe matches, which is the next launch compiling again -- the safe way round.
IF DEFINED APP_STAMP (
    2>NUL > "%APP_STAMP%" ECHO building
    IF NOT EXIST "%APP_STAMP%" (
        SET "APP_STAMP="
        SET "APP_EXE=%APP_FOLDER%\%SCRIPT_NAME%.exe"
        SET "MANIFEST=%APP_FOLDER%\%SCRIPT_NAME%.exe.manifest"
        SET "APP_NEW=%APP_FOLDER%\%SCRIPT_NAME%.new%RANDOM%%RANDOM%.exe"
        SET "APP_OLD=%APP_FOLDER%\%SCRIPT_NAME%.old%RANDOM%%RANDOM%.exe"
    )
)

REM The last two references are what lets the driver take the WebView2 package
REM apart itself instead of asking powershell.exe to do it. Nothing here fails
REM if they are dropped: every call to them is late-bound through eval("System"),
REM so the build succeeds and the extraction throws "Function expected" at run
REM time, where the caller reports it as a failed download. Measured, and it is
REM why test/winexec.ps1 builds an extraction with this line's own /r list.
REM Both files sit in the framework directory on every runner measured, and the
REM PowerShell command they replace asked for the same assembly by name, so the
REM floor this launcher needs has not moved.

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
    /r:"%FX_DIR%\System.IO.Compression.dll" ^
    /r:"%FX_DIR%\System.IO.Compression.FileSystem.dll" ^
    "%~f0"
    SET "JSC_EXIT=%ERRORLEVEL%"
    IF NOT "%JSC_EXIT%"=="0" EXIT /B %JSC_EXIT%

REM Renaming a running exe is allowed where overwriting it is not, so an
REM earlier instance keeps its own file under a name the next launch deletes.
IF EXIST "%APP_EXE%" MOVE /Y "%APP_EXE%" "%APP_OLD%" >NUL 2>&1
MOVE /Y "%APP_NEW%" "%APP_EXE%" >NUL
IF ERRORLEVEL 1 EXIT /B 1

REM The stamp goes down only once the exe it names is in place, so the window
REM where a stamp vouches for something that is not there yet does not exist.
REM Redirect first: `ECHO %SRC_HASH%> file` on a digest ending in a digit is
REM parsed as a handle redirect, and the stamp loses its last character.
IF DEFINED APP_STAMP (
    > "!APP_STAMP!" ECHO !SRC_HASH!
)

:RUN
REM Written when it is missing rather than on every launch. It was rewritten
REM each time only because each launch rebuilt the exe it belongs to; now that
REM the exe is kept, so is this, and the launch that does not build has nothing
REM to say here. A GOTO rather than wrapping the block in an IF: the ECHO lines
REM below carry ^< escapes, and another level of parentheses changes what those
REM escapes mean.
IF EXIST "%MANIFEST%" GOTO :LAUNCH
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

:LAUNCH
REM No NEUTRINO_SCRIPT_PATH here any more. It named the document for the exe to
REM render, and it is an environment variable that ends at which document this
REM process executes -- reachable by anything that can set one, and kept intact
REM under netinstall, whose allowlist admits the whole NEUTRINO_ prefix. The
REM driver derives the path from its own location instead, so the launcher has
REM nothing left to hand over: see getScriptPath. Not setting it is the half of
REM that fix which lives here, and it is what makes the exe's derivation the
REM live path on every tier rather than a fallback the testing builds skip.
START "" /D "%APP_FOLDER%" "%APP_EXE%"
IF ERRORLEVEL 1 EXIT /B 1
EXIT /B 0
EXIT
script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# The tier list lives in exactly one place, the JavaScript region below, between
# the TIER_START and TIER_END sentinels, where build.sh stamps it. Reading it
# back out of the file rather than taking it from the environment means the
# shell and the JavaScript cannot disagree, and means no caller can weaken a
# build by exporting something.
#
# The sentinels are named here without their comment prefix on purpose. build.sh
# refuses a template that carries any of them more than once, and this paragraph
# spelling one in full is a second one -- caught by that check on the first
# build after it was written, which is the shape of hazard parse.sh exists for.
#
# Read between the sentinels rather than by taking the first line in the file
# that looks like a stamp. Everything below the RUNWEB_START sentinel is the
# app, it is arbitrary JavaScript, and a line of it shaped like the stamp is
# not the stamp.
# Measured on the three seds that assemble this project -- GNU, the one Git bash
# carries, and the BSD sed macOS ships -- a range address reads the same on each.
#
# An empty read used to become "default", which is the weakest tier this file
# has: an artifact stamped tight,offline would have launched with neither of
# them and said nothing about it. There is no artifact build.sh will produce
# without exactly one stamp -- it refuses to write one -- so a stamp this cannot
# read means the file is not the file it was built as. That is a refusal and not
# a fallback.
neutrino_tiers="$(sed -n '/\/\/#TIER_START/,/\/\/#TIER_END/s/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$script_path" | head -1)"
if [ -z "$neutrino_tiers" ]; then
    echo "neutrino: no readable tier stamp in $script_path; refusing to launch" >&2
    exit 1
fi
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
    # ".*" then "/" does. Anchoring with $ first is how the tier line above
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
        "console",
        // In the preload rather than pushed after it, so the page has the
        // palette at document start. This is a binding like everything else
        // here, so a desktop that changes its colours between this document
        // loading and the view injecting still hands over the current one.
        nt.themeLiteral(root.ntTheme))

    // The desktop's palette. On this lane the watcher is the binding:
    // SystemPalette re-evaluates when the system palette changes, so
    // everything downstream of it -- the window colour, the view colour, the
    // push below -- follows without a signal being connected anywhere.
    SystemPalette {
        id: sysPalette
        colorGroup: SystemPalette.Active
    }

    // A QML colour carries its components as reals, so it goes to the
    // launcher's own toHex and flattenColor rather than being formatted here.
    // Four other lanes read a palette and all five have to agree about what a
    // colour is.
    function ntHex(c, over) {
        return root.nt.flattenColor(
            root.nt.toHex({ red: c.r, green: c.g, blue: c.b }), c.a, over)
    }

    // Read at the binding site rather than inside, so the dependency on each
    // palette entry is captured here and cannot be lost to a refactor of the
    // function below.
    readonly property var ntTheme: root.ntReadTheme(
        sysPalette.window, sysPalette.windowText, sysPalette.base, sysPalette.text,
        sysPalette.highlight, sysPalette.highlightedText, sysPalette.mid)

    // The parameters are named for the palette entries they carry rather than
    // for the SystemPalette properties they came from -- window is a name
    // with meaning in a QML document and this is not that window.
    function ntReadTheme(bgColor, fgColor, baseColor, textColor,
                         accentColor, accentTextColor, borderColor) {
        // The background first, because the rest are flattened over it.
        var bg = root.nt.toHex({ red: bgColor.r, green: bgColor.g, blue: bgColor.b })
        return root.nt.normalizeTheme({
            source: "qt",
            background: root.ntHex(bgColor, bg),
            foreground: root.ntHex(fgColor, bg),
            base: root.ntHex(baseColor, bg),
            text: root.ntHex(textColor, bg),
            accent: root.ntHex(accentColor, bg),
            accentText: root.ntHex(accentTextColor, bg),
            border: root.ntHex(borderColor, bg)
        })
    }

    // Only the push needs saying out loud. There is no diff here and none is
    // needed: a binding does not re-evaluate unless something it reads has
    // changed, which is the check the other lanes have to make for themselves.
    onNtThemeChanged: {
        if (!view.documentLoaded) {
            // Before the commit there is no document of ours to evaluate into,
            // and nothing is lost -- the preload above carries the snapshot.
            return
        }
        var js = root.nt.buildThemeScript(root.ntTheme)
        if (js) {
            view.runJavaScript(js)
        }
    }

    visible: true
    title: cfg.title

    // Through the launcher's own predicate, the way every other value on this
    // window is: nt is this file's JavaScript and it answers the question the
    // other four lanes ask it.
    //
    // Qt.Window is named rather than left out. An unset flags property is not
    // the same as one set to Qt.Window on every platform, and a frameless hint
    // on its own is a window with no type; the pair is what Qt documents for a
    // top-level that wants no frame.
    //
    // No backticks in this comment, and none anywhere in this document: the
    // here-document that carries it is unquoted, so a backtick is a command
    // the shell runs on the way past. parse.sh checks, which is how these
    // three lines were caught.
    flags: root.nt.undecorated() ? (Qt.Window | Qt.FramelessWindowHint) : Qt.Window

    // The two surfaces that are up before the document, the same pair every
    // other lane paints. A QML colour property reads #rrggbb itself, so this
    // is the string the launcher resolves -- the config's, when the build named
    // one, and the desktop's base when it did not.
    //
    // A binding and not an assignment, which is the whole of this lane's
    // repaint: when the palette changes the window colour changes with it, and
    // the view below follows the window.
    color: root.nt.resolveBackground(root.ntTheme)

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
        if (msg.action === "resize") { root.width = msg.width; root.height = msg.height }
        else if (msg.action === "move") { root.x = msg.x; root.y = msg.y }
        // Relative, against the same properties the two above set. No reader
        // needed here: on this lane the window's geometry is the window's own
        // bindable state, which is why boot's generic pair is not what serves
        // this driver.
        else if (msg.action === "resizeBy") {
            root.width = Math.max(1, root.width + msg.width)
            root.height = Math.max(1, root.height + msg.height)
        }
        else if (msg.action === "moveBy") { root.x = root.x + msg.x; root.y = root.y + msg.y }
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
        backgroundColor: root.color
        property bool preloadInjected: false
        property bool documentLoaded: false
        property bool contentLoaded: false
        // This lane's half of the title hook. title is a WebEngineView
        // property that follows the loaded document, so the signal is the one
        // QML generates for it and nothing has to be connected by hand.
        //
        // The assignment is what breaks the binding to cfg.title above, and
        // that is the point: from the first title this document names, the
        // window is following the document. Until then the binding holds, and
        // the gate refuses the empty title a document that names nothing
        // reports.
        onTitleChanged: {
            var name = root.nt.acceptDocumentTitle(view.url, view.title)
            if (name !== null) {
                root.title = name
            }
        }
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
        // A link with a target, which on this engine is a different signal from
        // the one below and was reaching nothing.
        //
        // QtWebEngine raises it for <a target=_blank> and for window.open;
        // navigationRequested is raised for neither, so the guard underneath
        // this had never seen one. Doing nothing is already a refusal -- a
        // request never handed to a view creates none -- so what this adds is
        // the forwarding the two GTK drivers have always done with
        // NEW_WINDOW_ACTION, and the line that says it happened.
        //
        // Connected by hand rather than declared as onNewWindowRequested, and
        // the reason is a round this cost. The signal is newWindowRequested
        // here and was newViewRequested in Qt 5; a declarative handler names
        // the signal at *load* time, so the wrong name is not a hook that does
        // nothing -- it is "Cannot assign to non-existent property" and the QML
        // document does not load at all. Every suite on the lane then reports
        // that no window ever appeared, which is a true sentence pointing
        // nowhere near the cause. Connecting from script degrades instead: an
        // engine with neither name gets a note and a window.
        //
        // Both names are tried and the one that took is reported, so the log
        // carries which signal this engine actually has rather than which one
        // this file assumed.
        function ntConnectNewWindow() {
            var names = ["newWindowRequested", "newViewRequested"]
            for (var i = 0; i < names.length; i++) {
                var sig = view[names[i]]
                if (sig && typeof sig.connect === "function") {
                    sig.connect(ntOnNewWindow)
                    console.warn("neutrino: new windows arrive on " + names[i])
                    return
                }
            }
            console.warn("neutrino: this QtWebEngine raises no new-window signal this file knows;"
                + " a link with a target will open nothing and go nowhere")
        }

        // mayOpenExternal and not isExternalUrl, the same as below: refusing a
        // window and then handing its url to the desktop's browser is the page
        // reaching the network without having asked, which is the one thing the
        // offline tier exists to stop.
        //
        // userInitiated is carried and not acted on. It is the engine's own
        // answer to whether a person did this, and it is the thing that makes a
        // synthesised click and a real one different readings -- worth having
        // in the log on the one lane that offers it, and not a rule, because no
        // other lane can say it.
        function ntOnNewWindow(request) {
            var wanted = String(request.requestedUrl)
            var byUser = "?"
            try { byUser = String(request.userInitiated) } catch (e) { byUser = "?" }
            console.warn("neutrino: refused a new window for " + wanted
                + " (userInitiated=" + byUser + ")")
            if (root.nt.mayOpenExternal(wanted)) {
                Qt.openUrlExternally(request.requestedUrl)
            }
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
            // Inside a try, and that is the same lesson one line further on.
            // Whatever goes wrong while wiring a hook must not stop the
            // document from loading: this block is what puts the app on
            // screen, and a throw here is a lane with no window in any suite
            // and no line saying why.
            try { ntConnectNewWindow() } catch (e) {
                console.warn("neutrino: could not connect the new-window signal: " + e)
            }
            view.loadHtml(root.nt.themedDocument(
                root.nt.titledDocument(
                    root.nt.applyContentPolicy(
                        root.nt.extractHtmlDocument(root.ntSource)),
                    cfg.title),
                root.ntTheme))
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

# The lane of last resort, and the reason it is worth having is that it
# implements nothing.
#
# python3 with PyGObject is on far more Linux machines than any GI-capable
# JavaScript interpreter is -- it is what the desktop's own tooling is written
# in -- but this file is JavaScript, and a Python driver that re-derived
# extractHtmlDocument, applyContentPolicy, parseMessage and mayOpenExternal
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
# The shim. Every policy question in here is asked of the JavaScript this file
# was cut from; nothing in it decides anything on its own.
import json
import os
import sys

NOENGINE = 69


def unavailable(what):
    # Not a traceback. This is the one failure the launcher is waiting to hear
    # about, and it has another lane to try -- so it is one line and a status,
    # not a page of stack that reads like a crash to whoever ran the app.
    sys.stderr.write("neutrino: pygobject lane unavailable: %s\n" % (what,))
    sys.exit(NOENGINE)


try:
    import gi
except Exception as exc:
    unavailable("no PyGObject (%s)" % (exc,))

# 4.1 before 4.0, which is resolveLinuxWebKitVersion's order and has to stay
# that way: a machine carrying both must land on the same one every lane does,
# or the app is talking to a different WebKit depending on which interpreter
# happened to be installed. JavaScriptCore is versioned alongside WebKit2 and
# comes out of the same package, so it is asked for with the same number
# rather than probed separately.
WEBKIT_API = None
for candidate in ("4.1", "4.0"):
    try:
        gi.require_version("WebKit2", candidate)
        gi.require_version("JavaScriptCore", candidate)
        WEBKIT_API = candidate
        break
    except Exception:
        continue

if WEBKIT_API is None:
    unavailable("WebKit2 introspection typelibs not found")

try:
    gi.require_version("Gtk", "3.0")
    # Pinned alongside Gtk and not left to the loader. Importing it unpinned
    # writes a PyGIWarning to stderr on the way past, and this lane's stderr is
    # the app's.
    gi.require_version("Gdk", "3.0")
    from gi.repository import GLib, Gdk, Gio, Gtk, JavaScriptCore, WebKit2
except Exception as exc:
    unavailable("%s" % (exc,))

script_path = os.environ.get("NEUTRINO_SCRIPT_PATH", "")
if not script_path:
    unavailable("NEUTRINO_SCRIPT_PATH was not set")

try:
    handle = open(script_path, "rb")
    try:
        source = handle.read().decode("utf-8", "replace")
    finally:
        handle.close()
except Exception as exc:
    unavailable("could not read %s (%s)" % (script_path, exc))

if GLib.getenv("NEUTRINO_WEBKIT_SANDBOX") == "1":
    try:
        WebKit2.WebContext.get_default().set_sandbox_enabled(True)
    except Exception as exc:
        sys.stderr.write("neutrino: webkit sandbox unavailable: %s\n" % (exc,))
else:
    sys.stderr.write(
        "neutrino: webkit sandbox off: this system refused a user namespace\n")

# Without this the window's WM_CLASS is taken from argv[0], which on this lane
# is the descriptor the document was handed on -- a window belonging to an
# application called "9". The name is what a window manager groups, labels and
# hangs an icon off, so it is set before the first window exists.

ucm = WebKit2.UserContentManager()
view_holder = {}
committed = {"done": False}


def showing():
    view = view_holder.get("view")
    if view is None:
        return ""
    try:
        return view.get_uri() or ""
    except Exception:
        return ""


def on_message(_ucm, result):
    # The sender check. This handler hangs off the content manager rather than
    # off a document, so it hears from whatever the view is currently showing,
    # which is the one thing a message cannot lie about.
    where = showing()
    if not call("isTrustedView", js_string(where)).to_boolean():
        sys.stderr.write("neutrino: refused a message from %s\n" % (where,))
        return
    try:
        raw = result.get_js_value().to_string()
    except Exception:
        raw = ""
    route(raw)


def route(raw):
    message = call("parseMessage", js_string(raw))
    if message is None or not message.is_object():
        sys.stderr.write("neutrino: refused a malformed record\n")
        return
    action = message.object_get_property("action").to_string()
    if action == "resize":
        window.resize(
            message.object_get_property("width").to_int32(),
            message.object_get_property("height").to_int32(),
        )
    elif action == "move":
        window.move(
            message.object_get_property("x").to_int32(),
            message.object_get_property("y").to_int32(),
        )
    elif action == "resizeBy":
        # Against get_size, which is the pair to the resize above. The floor is
        # one pixel and it is here for the same reason it is in boot: the
        # splitter sees a delta and cannot know what it is a delta from.
        current_w, current_h = window.get_size()
        window.resize(
            max(1, current_w + message.object_get_property("width").to_int32()),
            max(1, current_h + message.object_get_property("height").to_int32()),
        )
    elif action == "moveBy":
        current_x, current_y = window.get_position()
        window.move(
            current_x + message.object_get_property("x").to_int32(),
            current_y + message.object_get_property("y").to_int32(),
        )
    elif action == "close":
        window.destroy()
    elif action == "openExternal":
        open_external(message.object_get_property("url").to_string())


def open_external(url):
    # Asked again here as well as in the splitter, because this is the end of
    # the line and it hands a string to the desktop's URI handler, which will
    # act on a file: url or a .desktop entry given one. It is also where the
    # navigation refusal below arrives, so the tier half of the question closes
    # that route as well as this one.
    if not call("mayOpenExternal", js_string(url)).to_boolean():
        return
    try:
        Gio.AppInfo.launch_default_for_uri(url, None)
    except Exception:
        # An argv and never a command line: a url holding a space would
        # otherwise become two arguments and one holding a quote something
        # else entirely.
        try:
            GLib.spawn_async(
                None, ["xdg-open", url], None, GLib.SpawnFlags.SEARCH_PATH, None)
        except Exception:
            pass


ucm.register_script_message_handler("neutrino")
ucm.connect("script-message-received::neutrino", on_message)


def inject(text, when):
    if not text:
        return
    try:
        ucm.add_script(WebKit2.UserScript.new(
            text, WebKit2.UserContentInjectedFrames.TOP_FRAME, when, None, None))
    except Exception as exc:
        sys.stderr.write("neutrino: could not inject: %s\n" % (exc,))


# The API first, at document start, then the page's own code once there is a
# document to run it against. Both go in through the engine rather than being
# spliced into the markup, which is what lets the document forbid script of
# its own.
view = WebKit2.WebView(user_content_manager=ucm)

# The JavaScriptCore context is built here, after the WebView and not before it,
# and that ordering is the whole reason this lane renders anything.
#
# Measured: a JSC.Context created before the first WebKit2.WebView leaves the
# view loading forever. The window comes up, the main loop runs, the view is
# mapped, is_loading() stays True and the progress sticks at 0.1 -- and no
# load-changed event is ever emitted, not even STARTED, because the web process
# is never spawned at all. Only WebKitNetworkProcess appears beside it. Every
# reading looked like a healthy app with an empty window.
#
# Constructing the WebView first is what settles it; a context made after that
# point, or after the load, or seconds later, all render normally. Bisected
# against a bare PyGObject WebView: the same script differs only in when the
# context is made, and that alone decides whether the page ever loads.
#
# So nothing above this line may touch JavaScriptCore, and the user scripts are
# added to the content manager below rather than before the view exists -- the
# manager applies them to loads that have not started yet, and the load is the
# last thing this file does.
ctx = JavaScriptCore.Context.new()


def raised():
    exc = ctx.get_exception()
    if exc is None:
        return None
    ctx.clear_exception()
    return exc.get_message()


def js_string(text):
    return JavaScriptCore.Value.new_string(ctx, text)


def js_number(value):
    return JavaScriptCore.Value.new_number(ctx, value)


def js_null():
    return JavaScriptCore.Value.new_null(ctx)


# The palette is the one thing this lane hands over as an object rather than as
# a string or a number, and it goes through JSON rather than through
# Value.new_object and a walk of set_property calls. Not for brevity: the walk
# is a second place where a key can be spelled differently from the way
# normalizeTheme reads it, and json.dumps is the only quoting rule involved.
def js_json(value):
    return JavaScriptCore.Value.new_from_json(ctx, json.dumps(value))


# The source arrives with a parameter named NeutrinoPy defined, which is how
# run() at the bottom of it knows not to go looking for a driver of its own.
# It is a parameter and not a global for the reason the QML document gives:
# nothing this file defines should land in the shim's scope.
ctx.evaluate(
    "var NT = (function (NeutrinoPy) {\n"
    + source
    + "\n; return NeutrinoWebview; })(true);\n"
    "var NTNOTES = [];\n"
    "NT.noteSink = function (m) { NTNOTES.push(String(m)); };\n",
    -1,
)
failed = raised()
if failed is not None:
    unavailable("could not evaluate the app source (%s)" % (failed,))

nt = ctx.get_value("NT")
notes = ctx.get_value("NTNOTES")
if nt is None or not nt.is_object():
    unavailable("the app source did not yield a NeutrinoWebview")


def drain():
    # note() has no channel of its own here: printerr is gjs's and console is
    # the page's, and neither exists in a bare JavaScriptCore context. Without
    # the sink installed above, every refusal the shared code reports -- an
    # openExternal an offline build declined, a view that did not say which
    # document it committed -- would happen silently on this lane and on no
    # other. So they are collected there and emptied here, after every call
    # that could have produced one.
    count = notes.object_get_property("length").to_int32()
    for index in range(count):
        sys.stderr.write(notes.object_get_property_at_index(index).to_string() + "\n")
    if count:
        notes.object_invoke_method("splice", [js_number(0), js_number(count)])


def call(name, *args):
    result = nt.object_invoke_method(name, list(args))
    failure = raised()
    drain()
    if failure is not None:
        raise RuntimeError("%s: %s" % (name, failure))
    return result


config = nt.object_get_property("config")
title = config.object_get_property("title").to_string()
width = config.object_get_property("width").to_int32()
height = config.object_get_property("height").to_int32()
# Through the shared predicate rather than by comparing the string here, which
# is this lane's whole rule: the launcher's own JavaScript decides, and Python
# asks it. A second spelling of `== "none"` on the one lane that does not have
# to have one is exactly the drift the other four are protected from.
decorated = not call("undecorated").to_boolean()


# The desktop's palette, and the one thing this lane does reimplement: the walk
# over a Gtk style context, because a Gtk widget cannot be handed to
# JavaScriptCore and the launcher's own reader takes one.
#
# Nothing that decides anything is written twice. The names come out of the
# launcher's gtkColorNames, in its order; each colour goes back through its
# toHex and its flattenColor; and the result is judged by its normalizeTheme.
# What is duplicated is the loop, and a loop cannot disagree about a colour.
#
# A Gtk.Box for the reason createGjsDriver's readTheme gives: these are
# theme-level names, measured identical on Box, Label and Window, and building a
# toplevel to read a colour would be a second window in a launcher whose whole
# job is the first one.
def read_theme():
    try:
        style = Gtk.Box().get_style_context()
    except Exception as exc:
        sys.stderr.write("neutrino: could not read the desktop theme: %s\n" % (exc,))
        return None
    names = nt.object_get_property("gtkColorNames").to_string().split(",")
    keys = nt.object_get_property("themeKeys").to_string().split(",")
    if len(names) != len(keys):
        sys.stderr.write("neutrino: the palette and its GTK names are different lengths\n")
        return None
    hexes = []
    alphas = []
    for name in names:
        found = style.lookup_color(name)
        if not found[0]:
            sys.stderr.write("neutrino: this theme defines no %s\n" % (name,))
            return None
        rgba = found[1]
        hexes.append(call("toHex", js_json({
            "red": rgba.red, "green": rgba.green, "blue": rgba.blue,
        })).to_string())
        alphas.append(rgba.alpha)
    # Flattened against the background, which is why it is read first. A
    # translucent border over white is a light border on a dark desktop.
    raw = {"source": "gtk"}
    for index in range(len(keys)):
        raw[keys[index]] = call(
            "flattenColor", js_string(hexes[index]),
            js_number(alphas[index]), js_string(hexes[0]),
        ).to_string()
    return raw


# Held as the JavaScript value the launcher returned rather than as anything of
# this lane's own, so that themesDiffer is comparing what it built to what it
# built. `theme` on the launcher object is set alongside it for the same reason
# every other value here is read back out of that object: one truth.
theme_state = {"value": js_null()}


def take_theme():
    raw = read_theme()
    if raw is None:
        return False
    taken = call("normalizeTheme", js_json(raw))
    if taken.is_null() or taken.is_undefined():
        return False
    if not call("themesDiffer", theme_state["value"], taken).to_boolean():
        return False
    theme_state["value"] = taken
    nt.object_set_property("theme", taken)
    return True


if not take_theme():
    sys.stderr.write("neutrino: could not read the desktop palette; using %s\n" % (
        call("resolveBackground", theme_state["value"]).to_string(),))


# The scheme, and this lane asks the launcher whether to raise the flag rather
# than looking at the palette itself -- gtkPreferDark says why it is raised and
# never lowered, and a second copy of that reasoning here is a second thing that
# can drift from the gjs driver's.
#
# Called before the window for the reason boot calls it there: the media query
# is a value the first paint is already styled by.
def force_scheme():
    if not call("gtkPreferDark", theme_state["value"]).to_boolean():
        return
    settings = Gtk.Settings.get_default()
    if settings is None:
        return
    try:
        if settings.get_property("gtk-application-prefer-dark-theme"):
            return
        settings.set_property("gtk-application-prefer-dark-theme", True)
    except Exception as exc:
        sys.stderr.write("neutrino: could not force the colour scheme: %s\n" % (exc,))


force_scheme()


# The two surfaces GTK puts up before the document, and the colour comes out of
# the launcher's own resolveBackground rather than being decided again here.
# This lane reimplements nothing on purpose, and a second reading of the same
# value is a second thing that can disagree with the other four.
#
# Both calls are allowed to fail. A background that will not paint is a window
# in the theme colour, which is where this started -- worth a line on stderr,
# not worth refusing to launch over.
def paint(widget_window, web_view, background):
    rgb = call("parseColor", js_string(background))
    if rgb.is_null() or rgb.is_undefined():
        return
    red = rgb.object_get_property("red").to_double()
    green = rgb.object_get_property("green").to_double()
    blue = rgb.object_get_property("blue").to_double()
    try:
        rgba = Gdk.RGBA()
        rgba.red, rgba.green, rgba.blue, rgba.alpha = red, green, blue, 1.0
        web_view.set_background_color(rgba)
    except Exception as exc:
        sys.stderr.write("neutrino: could not paint the view: %s\n" % (exc,))
    try:
        # On the widget and not on the screen: the screen-wide call reaches
        # every window in the process, and there is one here only by accident
        # of there being one window.
        provider = Gtk.CssProvider()
        provider.load_from_data(
            ("window, .background { background-color: rgb(%d,%d,%d); }" % (
                round(red * 255), round(green * 255), round(blue * 255))).encode("utf-8"))
        widget_window.get_style_context().add_provider(
            provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    except Exception as exc:
        sys.stderr.write("neutrino: could not paint the window: %s\n" % (exc,))

html = call(
    "themedDocument",
    call(
        "titledDocument",
        call("applyContentPolicy", call("extractHtmlDocument", js_string(source))),
        js_string(title),
    ),
    theme_state["value"],
).to_string()
page_script = call("extractPageScript", js_string(source)).to_string()
preload = call(
    "buildPreloadScript",
    js_string("window.webkit.messageHandlers.neutrino.postMessage"),
    js_string("scriptmessage"),
    # In the preload rather than pushed after it, so the page has the palette
    # at document start and never paints once in the wrong colours first.
    call("themeLiteral", theme_state["value"]),
).to_string()

# Asked for before a WebView exists, and taken back if it does not arrive.
# Both halves matter and the comment in createGjsDriver's init records why:
# WebKitGTK aborts outright if sandboxing is changed once a web process has
# been spawned, and a sandbox that cannot start gives a window with nothing in
# it. The value is a measurement the launcher took with bwrap itself, never a
# switch read from the environment.
inject(preload, WebKit2.UserScriptInjectionTime.START)
inject(page_script, WebKit2.UserScriptInjectionTime.END)

GLib.set_prgname("neutrino")

window = Gtk.Window(
    title=title,
    default_width=width,
    default_height=height,
    decorated=decorated,
)
window.set_position(Gtk.WindowPosition.CENTER)
window.connect("destroy", lambda _w: Gtk.main_quit())
paint(window, view, call("resolveBackground", theme_state["value"]).to_string())
view_holder["view"] = view


# The watcher, and the same signal the gjs lane uses: `style-updated` is what
# GTK emits when the style behind a widget changes for any reason, rather than
# one of the several settings that can cause it.
#
# take_theme's diff is what makes this safe to connect at all. Painting the
# window adds a CssProvider to it, which emits this signal -- so without the
# diff the first theme change would be the last thing this process did.
def on_style_updated(_widget):
    if not take_theme():
        return
    # Before the paint, because raising the flag is a thing GTK may answer by
    # changing the palette, and a paint that ran first would be painting the
    # one it was about to replace.
    force_scheme()
    if call("followsTheme").to_boolean():
        paint(window, view, call("resolveBackground", theme_state["value"]).to_string())
    # Before the commit there is no document of ours to evaluate into. Nothing
    # is lost: the page starts from the preload's snapshot either way.
    if not committed["done"]:
        return
    js = call("buildThemeScript", theme_state["value"])
    if js.is_null() or js.is_undefined():
        return
    try:
        # run_javascript and not evaluate_javascript, because this lane resolves
        # WebKit2 to 4.1 or 4.0 and only the first carries the newer spelling.
        view.run_javascript(js.to_string(), None, None, None)
    except Exception as exc:
        sys.stderr.write("neutrino: could not deliver the theme: %s\n" % (exc,))


window.connect("style-updated", on_style_updated)


def on_load_changed(_view, event):
    # COMMITTED and not FINISHED, and the difference is a hole: the author's
    # script runs at document end, which is after the commit and before the
    # load finishes, so a navigation started from there would be decided while
    # this was still false. A stylesheet on a socket that never answers holds
    # the load open for as long as the page likes.
    if event == WebKit2.LoadEvent.COMMITTED:
        committed["done"] = True
        try:
            call("rememberTrustedView", js_string(view.get_uri() or ""))
        except Exception:
            pass


view.connect("load-changed", on_load_changed)

settings = view.get_settings()
try:
    settings.set_enable_developer_extras(False)
    settings.set_allow_file_access_from_file_urls(False)
    settings.set_allow_universal_access_from_file_urls(False)
    settings.set_javascript_can_access_clipboard(False)
    settings.set_enable_write_console_messages_to_stdout(False)
except Exception:
    pass


def on_decide_policy(_view, decision, kind):
    # The document is loaded once, from this file, and never navigates again.
    # Without this a link or a location assignment could replace it with a
    # remote origin, and that origin would then be holding the channel to the
    # native window -- the preload is registered on the content manager, so it
    # is reinjected into whatever document arrives next.
    types = WebKit2.PolicyDecisionType
    if kind != types.NAVIGATION_ACTION and kind != types.NEW_WINDOW_ACTION:
        return False
    try:
        uri = decision.get_navigation_action().get_request().get_uri() or ""
    except Exception:
        uri = ""
    # Until the first document is committed the only navigation in flight is
    # the one this file started, and its decision is taken before any load
    # event fires. Keying on that as well as on the url means an engine that
    # spells the initial load differently cannot lock the app out of its own
    # document.
    if not committed["done"] or call("isOwnDocument", js_string(uri)).to_boolean():
        return False
    decision.ignore()
    sys.stderr.write("neutrino: refused navigation to %s\n" % (uri,))
    open_external(uri)
    return True


view.connect("decide-policy", on_decide_policy)


# This lane's half of the title hook, and the same signal the gjs lane connects.
# `notify::title` is GObject's own, so it fires for a `<title>` the parser met
# and for an assignment the page made alike, and the value read back is the
# engine's rather than anything the page handed over.
#
# showing() is the reader the message handler already uses, so the sender check
# here and the sender check there cannot drift apart.
def on_title(view_object, _pspec):
    name = call("acceptDocumentTitle", js_string(showing()),
                js_string(view_object.get_title() or ""))
    if not name.is_null():
        window.set_title(name.to_string())


view.connect("notify::title", on_title)

view.load_html(html, None)
window.add(view)
window.show_all()
Gtk.main()
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

if qt_runner="$(find_qt_runtime)"
then
    run_qt "$qt_runner"
    nt_status=$?
    [ "$nt_status" = "$nt_ex_noengine" ] || exit "$nt_status"
fi

# Above python3 rather than below it, and that ordering is the whole reason a
# Mac never pays for the lane after it: osascript is always present there, so
# the walk stops here; on Linux osascript never exists, so the miss is a
# builtin lookup and Python is reached immediately.
if command -v osascript >/dev/null 2>&1
then run_macos
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
exit $?;:<<'//</script></body></html>' #-->
<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="script-src 'unsafe-eval'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'"><style>html,body{background:white;color:black;font-size:2em}</style></head><body>Welcome to neutrino
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
                // Urls a refused new window was heading for, for the loop to
                // hand to the machine's browser. A second list rather than a
                // flag on the first, because the two are drained through
                // different calls and one of them is a note.
                static var externals : ArrayList = new ArrayList();
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
                            // And forwarded, which is what the two GTK drivers
                            // have always done with NEW_WINDOW_ACTION and this
                            // one did not: refusing a `<a target=_blank>` and
                            // then dropping it means a link that works in every
                            // browser does nothing here and says nothing.
                            //
                            // Queued and not opened. mayOpenExternal is a
                            // JScript global and this is a JScript.NET class,
                            // which cannot call one -- the same reason the
                            // message sink queues instead of calling back out.
                            // So the string goes to the loop and the loop asks.
                            //
                            // Only on the branch where Handled took. If it did
                            // not, the engine is opening its own window and
                            // forwarding as well would open the url twice.
                            NeutrinoNavSink.externals.Add(going);
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

        /*
         * What the native window needs before there is a document to read it
         * from, and nothing else. createWindow runs on every lane before
         * loadHTML, so these three cannot come from the markup the way the
         * style and the body now do -- there is no document yet when they are
         * asked for.
         *
         * `url` used to sit here and had not been read by anything since the
         * launcher stopped navigating to a remote page. It is gone rather than
         * kept, because a config entry nothing consumes reads as a feature.
         *
         * `background` is the fourth for the same reason the other three are
         * here: it is wanted before there is a document. Two surfaces are up
         * ahead of the first paint -- the native window, and the view inside it
         * -- and neither of them can be reached from a stylesheet. Measured on
         * WebKitGTK with the load held back: the window is the theme's bare
         * background, #F6F5F4 under Adwaita, and the view adds about two frames
         * of its own on top. Both of them are white on a default desktop, and
         * both are what the app was seen through before it painted.
         *
         * It does not touch the document. An author sets it to whatever their
         * own CSS paints, and the two are deliberately separate: this is the
         * colour of the frame the app has not arrived in yet, not a rule in
         * anybody's stylesheet.
         *
         * `auto` is the value that is not a colour, and it is what a build that
         * names no background carries. It means the colour is not known at
         * assembly because it is not a property of the app: it is a property of
         * the desktop the app is launched on, and resolveBackground reads it
         * there, from the palette readTheme took off the running toolkit. An
         * author who wants one fixed colour on every machine says so with
         * --background and gets exactly that, on every machine, forever.
         *
         * `decorations` is the fifth, and it is here because a frame is chosen
         * when a window is constructed rather than adjusted afterwards: a style
         * mask, a GtkWindow construct property, a QML `flags` value and a
         * FormBorderStyle are each read once, at the call createWindow makes.
         *
         * `none` takes the title bar and the borders, and it takes the drag
         * handle, the resize edge and the window manager's snapping with them,
         * because those are things the frame was providing. An app that asks
         * for it draws its own and moves itself with `moveBy` and `resizeBy`,
         * which every lane already carries -- that is the whole of what is
         * offered here, and the launcher adds no verb for it. `auto` is the
         * frame the desktop would have given the window anyway.
         *
         * Stamped by build.sh between the sentinels, the way the tier list is,
         * and for the same reason: one value, read by five lanes, with nothing
         * in the environment able to talk any of them out of it.
         */
        //#CONFIG_START
        config: {
            title: "neutrino",
            width: 900,
            height: 600,
            background: "auto",
            decorations: "auto"
        },
        //#CONFIG_END

        /*
         * A colour, as the four toolkits want it.
         *
         * Three of the five lanes take the string as written -- Gdk.RGBA.parse,
         * a QML colour property and ColorTranslator.FromHtml all read `#rrggbb`
         * themselves -- so this exists for the one that does not. NSColor is
         * built from components, and a lane that parsed its own would be a
         * second reading of the same value that could disagree with the others.
         *
         * `#rgb` and `#rrggbb` and nothing else, and a value it cannot read
         * comes back null rather than as black. A background nobody can parse
         * is a build that should have been refused, and build.sh refuses it;
         * this returning null is what lets each lane leave its surface alone
         * instead of painting it a colour nobody asked for.
         */
        parseColor: function (value) {
            var text = String(value || "");
            if (!/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(text)) {
                return null;
            }
            var hex = text.substring(1);
            if (hex.length === 3) {
                hex = hex.charAt(0) + hex.charAt(0) +
                      hex.charAt(1) + hex.charAt(1) +
                      hex.charAt(2) + hex.charAt(2);
            }
            return {
                red: parseInt(hex.substring(0, 2), 16) / 255,
                green: parseInt(hex.substring(2, 4), 16) / 255,
                blue: parseInt(hex.substring(4, 6), 16) / 255
            };
        },
        // The palette the desktop is using, as normalizeTheme returns it, or
        // null on a lane that could not read one. Written once at boot and
        // again by applyTheme, and read by everything that paints.
        theme: null,

        /*
         * A note that is worth making once and not once a second.
         *
         * Everything the theme watchers report is on a path that repeats: the
         * Windows lane re-reads the palette on a clock, and the GTK lanes read
         * it on every style-updated, which is emitted rather more often than
         * the theme actually changes. A toolkit that cannot be read is a
         * standing condition, so saying so on every attempt would bury the rest
         * of this file's stderr under one sentence -- and stderr is the app's,
         * not this file's, on four of the five lanes.
         *
         * Once per distinct message for the life of the process, which means a
         * condition that clears and returns is reported only the first time.
         * That is the trade, and it is the right way round: the first one is
         * the one that says what happened.
         */
        notedOnce: null,

        noteOnce: function (message) {
            if (!this.notedOnce) {
                this.notedOnce = {};
            }
            // Prefixed, so a message that happens to read like a name on
            // Object.prototype -- "constructor" is the one that bites -- is a
            // key of this set and not a truthy thing it inherited.
            var key = " " + String(message);
            if (this.notedOnce[key]) {
                return;
            }
            this.notedOnce[key] = true;
            this.note(message);
        },

        /*
         * The other direction: components back to the spelling every lane and
         * the page both read. parseColor takes `#rgb` and `#rrggbb` and hands
         * back components; this hands back `#rrggbb`, lower case, always six
         * digits. One spelling out means themesDiffer can compare strings and
         * that the payload check below is a real check rather than a formality.
         */
        toHex: function (rgb) {
            var pair = function (value) {
                var n = Math.round(value * 255);
                n = (n < 0) ? 0 : ((n > 255) ? 255 : n);
                return (n < 16 ? "0" : "") + n.toString(16);
            };
            return "#" + pair(rgb.red) + pair(rgb.green) + pair(rgb.blue);
        },

        /*
         * A colour with alpha, over the surface behind it.
         *
         * The palette below is `#rrggbb` throughout, and some of what the
         * toolkits hand over is not: GTK's `insensitive_fg_color` came back
         * `rgba(218,218,218,0.5)` on the desk this was written at, and macOS
         * spells `separatorColor` the same way. Every reader has the alpha its
         * own toolkit gave it, so the readers pass it here rather than each
         * flattening it their own way -- the rule is one rule for the same
         * reason parseColor is one parser.
         *
         * Over the surface behind it and not over white: a translucent border
         * flattened against white is a light border on a dark desktop, which is
         * the one thing this whole file is trying not to do.
         */
        flattenColor: function (hex, alpha, overHex) {
            var top = this.parseColor(hex);
            if (!top) {
                return null;
            }
            var a = Number(alpha);
            if (!(a >= 0 && a <= 1)) {
                a = 1;
            }
            var under = this.parseColor(overHex);
            if (a >= 1 || !under) {
                return this.toHex(top);
            }
            return this.toHex({
                red: top.red * a + under.red * (1 - a),
                green: top.green * a + under.green * (1 - a),
                blue: top.blue * a + under.blue * (1 - a)
            });
        },

        /*
         * sRGB relative luminance, the standard curve. What it is for is the
         * one question every lane has to answer the same way: is the desktop
         * dark?
         *
         * Not the toolkit's own flag, and that is a measurement rather than a
         * preference. On the desk this was written at
         * `gtk-application-prefer-dark-theme` reads False while the theme is
         * `Mint-L-Dark` -- the flag says light and the window is dark grey. The
         * XDG portal gets it right and `gsettings ... color-scheme` returns
         * `default`, so there is no one flag to read even on one desktop.
         *
         * The palette is what is on screen, so the luminance of the palette is
         * the truth about it. That makes this the definition rather than a
         * fallback, and it means five lanes answer with one rule instead of
         * five APIs that can each drift.
         */
        relativeLuminance: function (rgb) {
            var linear = function (u) {
                return (u <= 0.03928) ? (u / 12.92) : Math.pow((u + 0.055) / 1.055, 2.4);
            };
            return 0.2126 * linear(rgb.red) +
                0.7152 * linear(rgb.green) +
                0.0722 * linear(rgb.blue);
        },

        /*
         * And the threshold, which is not a number written down here.
         *
         * A surface is dark when it takes light text better than dark text, so
         * the two contrast ratios are computed and compared. That puts the
         * crossing at a luminance of about 0.179 -- mid grey `#808080` is 0.216
         * and comes out light, which is right, and a fixed 0.5 would have
         * called it dark. The rule says what it means and there is no constant
         * to get wrong.
         */
        isDarkSurface: function (rgb) {
            var lum = this.relativeLuminance(rgb);
            var againstWhite = 1.05 / (lum + 0.05);
            var againstBlack = (lum + 0.05) / 0.05;
            return againstWhite > againstBlack;
        },

        // The palette, in one place, because five readers and one normalizer
        // and one payload check all have to agree on it. A string rather than
        // an array literal walk: JScript.NET is the engine that has to compile
        // this file, and hasTier already reads a set this way.
        themeKeys: "background,foreground,base,text,accent,accentText,border",
        themeSources: "gtk,qt,macos,windows",

        /*
         * The same seven, spelled as CSS. In themeKeys order and read
         * positionally, because two lists that have to stay parallel are safer
         * as two lists in one order than as a map anyone can add half an entry
         * to.
         *
         * These are the non-deprecated `<system-color>` keywords, and the names
         * are the keywords exactly so that the fallback idiom reads itself:
         *
         *     background: var(--neutrino-Canvas, Canvas);
         *     color:      var(--neutrino-CanvasText, CanvasText);
         *
         * The desktop's real colour where a lane read one, the engine's own
         * system colour where it did not -- said at the point of use, with no
         * branch in script, which is strictly better than an app testing
         * `theme === null` and picking something.
         *
         * `Highlight` and not `AccentColor` for the accent pair, and the flip
         * is what decided it. `AccentColor` matched the desktop only on macOS.
         * `Highlight` matched WebView2 and came within one unit on WebKitGTK --
         * *and that near-match was a coincidence*: it stayed `3484e4` when the
         * desktop's accent moved to `15539e`. So neither keyword is the
         * desktop's accent anywhere but one lane, the custom property carries
         * the measured value in either spelling, and what is left to choose on
         * is the fallback. `Highlight` and `HighlightText` are CSS2 and resolve
         * on all four engines; `AccentColor` is newer and does not everywhere.
         * A fallback that resolves to nothing leaves the previous value in
         * place, which is the one failure this delivery must not have.
         *
         * It is also the more honest name for what is being read: on three of
         * the four lanes the source is literally the selection colour, and only
         * macOS asks for `controlAccentColor` first.
         */
        systemColorNames: "ButtonFace,ButtonText,Canvas,CanvasText," +
            "Highlight,HighlightText,ButtonBorder",

        inSet: function (set, name) {
            return ("," + set + ",").indexOf("," + String(name) + ",") >= 0;
        },

        themeKeyList: function () {
            return String(this.themeKeys).split(",");
        },

        /*
         * What a lane hands over, checked, and what every consumer sees.
         *
         * A reader returns a flat object -- seven colours and the name of the
         * lane that read them -- and nothing else in this file trusts it. Each
         * colour goes through parseColor, which is the same reading the
         * background has always had, and comes back out through toHex so the
         * palette is one spelling however the toolkit spelled it. The scheme is
         * derived here rather than reported by the lane, for the reason
         * relativeLuminance gives.
         *
         * A raw object with a colour nobody can parse returns null, whole. Not
         * a palette with a hole in it and not one with white where a value
         * should be: a half-read palette is worse than no palette, because an
         * app would style itself from it and have no way to tell. The caller
         * keeps whatever it had, which at launch is nothing and afterwards is
         * the last palette that did parse.
         */
        normalizeTheme: function (raw) {
            if (!raw || typeof raw !== "object") {
                return null;
            }
            var source = String(raw.source || "");
            if (!this.inSet(this.themeSources, source)) {
                return null;
            }
            var keys = this.themeKeyList();
            var colors = {};
            for (var i = 0; i < keys.length; i++) {
                var rgb = this.parseColor(raw[keys[i]]);
                if (!rgb) {
                    return null;
                }
                colors[keys[i]] = this.toHex(rgb);
            }
            return {
                scheme: this.isDarkSurface(this.parseColor(colors.background)) ? "dark" : "light",
                source: source,
                colors: colors
            };
        },

        /*
         * The colour the two pre-document surfaces are painted, once the
         * desktop has been read.
         *
         * `base` and not `background`, and it is the one judgement call in
         * here. The view is very nearly the whole window, and an app that
         * follows the desktop paints its body like a content surface -- white
         * under GNOME light, where the window chrome is #F6F5F4. Borrowing the
         * chrome colour would put the app's own body colour a shade away from
         * the frame it arrives in, which is a seam rather than a flash but
         * still something to look at. The chrome colour is in the palette for
         * an app that wants it.
         *
         * A build that named a colour is answered from the config and never
         * from the desktop -- that is what naming one means. The white at the
         * end is not a default anybody chooses; it is what is left when a lane
         * could not read its toolkit at all, and it is the colour this file
         * shipped before any of it existed.
         */
        followsTheme: function () {
            return !this.parseColor(this.config.background);
        },

        /*
         * One question, asked by five drivers, so a sixth spelling of the same
         * comparison cannot drift from the other five. The equality is against
         * the one value that means it and not against anything falsy: `auto` is
         * a value here, not an absence, and a config that somehow carried
         * neither word keeps the frame rather than losing it -- removing a
         * window's only handle is not the safe side of an unreadable value.
         */
        undecorated: function () {
            return this.config.decorations === "none";
        },

        resolveBackground: function (theme) {
            if (!this.followsTheme()) {
                return this.config.background;
            }
            if (theme && theme.colors && this.parseColor(theme.colors.base)) {
                return theme.colors.base;
            }
            return "#ffffff";
        },

        /*
         * Whether anything actually changed, and it is load-bearing rather than
         * tidy. The GTK watcher is `style-updated` on the window, and painting
         * the window is adding a CssProvider to it, which emits `style-updated`
         * -- so a watcher that pushed whatever it was handed would feed itself
         * for as long as the app was open. Every lane goes through here for
         * that reason, and the Windows lane can re-read on a timer at all
         * because of it.
         */
        themesDiffer: function (a, b) {
            if (!a || !b) {
                return a !== b;
            }
            if (a.scheme !== b.scheme || a.source !== b.source) {
                return true;
            }
            var keys = this.themeKeyList();
            for (var i = 0; i < keys.length; i++) {
                if (a.colors[keys[i]] !== b.colors[keys[i]]) {
                    return true;
                }
            }
            return false;
        },

        /*
         * The palette as a JavaScript object literal, for the two places that
         * need one: the preload, where it is the snapshot the page starts with,
         * and the push below, where it is an update.
         *
         * Everything in it is checked again here even though normalizeTheme
         * built it, and that is the point rather than belt and braces. This is
         * the only string this file ever evaluates *into* a page -- every other
         * direction is the page talking to the host -- so the rule parseMessage
         * holds coming in is held going out: a fixed shape, a known key set, and
         * values that match one anchored pattern or the whole update is dropped.
         * There is no escaping scheme here for the same reason there is none
         * there, and nothing that fails this can reach a page as text.
         */
        themeLiteral: function (theme) {
            if (!theme || !theme.colors) {
                return null;
            }
            if (theme.scheme !== "dark" && theme.scheme !== "light") {
                return null;
            }
            if (!this.inSet(this.themeSources, theme.source)) {
                return null;
            }
            var values = this.themeColorList(theme);
            if (!values) {
                return null;
            }
            var keys = this.themeKeyList();
            var parts = [];
            for (var i = 0; i < keys.length; i++) {
                parts[parts.length] = keys[i] + ':"' + values[i] + '"';
            }
            return '{scheme:"' + theme.scheme + '",source:"' + theme.source +
                '",colors:{' + parts.join(",") + '}}';
        },

        /*
         * The seven colours, in themeKeys order, or null for the whole palette.
         *
         * Two deliveries read this now -- the object the page gets and the CSS
         * the document carries -- and they have to agree about what a
         * presentable palette is. A palette that is good enough to hand to
         * script and not good enough to put in a stylesheet would be a window
         * whose two accounts of the desktop disagree.
         *
         * The check is the anchored one this file has always applied. It is
         * also what makes themeCssText closed by construction: every value that
         * reaches a stylesheet matched `^#[0-9a-f]{6}$`, and every property
         * name came from a constant in this file.
         */
        themeColorList: function (theme) {
            if (!theme || !theme.colors) {
                return null;
            }
            var keys = this.themeKeyList();
            var out = [];
            for (var i = 0; i < keys.length; i++) {
                var value = String(theme.colors[keys[i]]);
                if (!/^#[0-9a-f]{6}$/.test(value)) {
                    return null;
                }
                out[out.length] = value;
            }
            return out;
        },

        buildThemeScript: function (theme) {
            var literal = this.themeLiteral(theme);
            if (!literal) {
                return null;
            }
            return "window.neutrino&&window.neutrino._theme&&window.neutrino._theme(" +
                literal + ");";
        },

        /*
         * One place every lane's watcher ends up, so the order is the same on
         * all five: check what was read, drop it if it is not different,
         * repaint the native surfaces if this build follows the desktop, then
         * tell the page.
         *
         * The native repaint is first because it is the surface the page is
         * about to be drawn over, and it is skipped entirely for a build that
         * named its own colour -- an author who said #12141a means it through a
         * theme change as much as through a launch.
         *
         * The push is allowed to fail. A page that did not get an update still
         * has the palette it started with, which is a window one theme change
         * out of date rather than a window that is gone.
         */
        applyTheme: function (driver, win, wv, raw) {
            var next = this.normalizeTheme(raw);
            if (!next) {
                this.noteOnce("could not read the desktop palette");
                return false;
            }
            if (!this.themesDiffer(this.theme, next)) {
                return false;
            }
            this.theme = next;
            /*
             * Before the repaint, because on GTK the flag that carries this is
             * one the toolkit may answer by changing the palette -- and a
             * repaint that ran first would be painting the palette the flag was
             * about to replace.
             */
            if (driver.forceScheme) {
                try {
                    driver.forceScheme(next);
                } catch (e0) {
                    this.noteOnce("could not force the colour scheme: " + e0);
                }
            }
            if (this.followsTheme() && driver.repaint) {
                try {
                    driver.repaint(win, wv, this.resolveBackground(next));
                } catch (e) {
                    this.noteOnce("could not repaint for the new theme: " + e);
                }
            }
            var js = this.buildThemeScript(next);
            if (js && driver.evaluate) {
                try {
                    driver.evaluate(wv, js);
                } catch (e2) {
                    this.noteOnce("could not deliver the theme: " + e2);
                }
            }
            return true;
        },

        /*
         * The GTK named colours, in themeKeys order.
         *
         * One list, walked by the two lanes that drive GTK -- this file's gjs
         * driver and the PyGObject shim, which reads the string back out of
         * here rather than carrying a second copy of it. A palette that
         * disagreed between the two would be a desktop that looked different
         * depending on which interpreter the launcher happened to find.
         *
         * The GTK3 spellings, because they are the ones measured present. Under
         * Mint-L-Dark every name below answered, while libadwaita's newer
         * `accent_bg_color`, `window_bg_color` and `view_bg_color` all came back
         * not found. Those are an upgrade for a later round and never the only
         * read: a lane that asked for them alone would report nothing on a
         * desktop that is working perfectly well.
         */
        gtkColorNames: "theme_bg_color,theme_fg_color,theme_base_color,theme_text_color," +
            "theme_selected_bg_color,theme_selected_fg_color,borders",

        /*
         * The palette, off any realized-or-not widget's style context.
         *
         * A style context and not a window, because the read happens before
         * there is a window: boot asks for the theme ahead of createWindow, so
         * the caller hands in a throwaway widget. Measured on Gtk.Box, Gtk.Label
         * and Gtk.Window -- all three answer identically, because these are
         * theme-level names and not widget-level ones -- so the cheapest of the
         * three is what the driver builds.
         *
         * `borders` is the one that comes back translucent on some themes and
         * `insensitive_fg_color` always does, which is why the alpha travels
         * with each colour to flattenColor rather than being dropped here. The
         * background is read first so there is something to flatten against.
         *
         * One name failing means null, not a palette with six colours in it:
         * normalizeTheme would refuse it anyway, and refusing here says which
         * name was missing.
         */
        readGtkTheme: function (styleContext) {
            if (!styleContext) {
                return null;
            }
            var keys = this.themeKeyList();
            var names = String(this.gtkColorNames).split(",");
            var hex = [];
            var alpha = [];
            for (var i = 0; i < names.length; i++) {
                var found = null;
                try {
                    found = styleContext.lookup_color(names[i]);
                } catch (e) {
                    this.noteOnce("could not look up " + names[i] + ": " + e);
                    return null;
                }
                if (!found || !found[0] || !found[1]) {
                    this.noteOnce("this theme defines no " + names[i]);
                    return null;
                }
                hex[i] = this.toHex(found[1]);
                alpha[i] = found[1].alpha;
            }
            var raw = { source: "gtk" };
            for (var j = 0; j < keys.length; j++) {
                raw[keys[j]] = this.flattenColor(hex[j], alpha[j], hex[0]);
            }
            return raw;
        },

        /*
         * Whether GTK's prefer-dark flag should be raised for this palette,
         * asked by both lanes that drive GTK so that neither decides it.
         *
         * It is not a preference being restated. `prefers-color-scheme` in the
         * page is the engine's own answer and on WebKitGTK it is a *name*: the
         * flag below, or a theme whose name carries the dark variant. It is not
         * the palette. Measured on this desk, one launch per row, the media
         * query beside `neutrino.theme.scheme`:
         *
         *   GTK_THEME=Adwaita            f6f5f4   mq=light   scheme=light
         *   GTK_THEME=Adwaita:dark       353535   mq=dark    scheme=dark
         *   GTK_THEME=Adwaita-dark       353535   mq=dark    scheme=dark
         *   GTK_THEME=Mint-Y-Dark        2e2e33   mq=dark    scheme=dark
         *   GTK_THEME=Mint-Y-Dark-Grey   2e2e33   mq=light   scheme=dark
         *   GTK_THEME=Mint-L-Dark-Blue   383838   mq=light   scheme=dark
         *
         * The last two are stock Mint themes, installed by the distribution and
         * selectable from its settings panel. `Mint-Y-Dark-Grey` is the same
         * dark grey as `Mint-Y-Dark` and the engine calls it light, because the
         * name ends in the colour and not in the variant -- and the `-Dark-`
         * families are twenty-odd themes shipped that way. So this is a defect
         * an ordinary desktop reaches by picking a theme from a list.
         *
         * `gtk-application-prefer-dark-theme` reads False on every row above,
         * including the three the engine calls dark, which is the flag this
         * file's luminance rule already refuses to trust for the palette. What
         * is measured here is that *writing* it moves the media query, both
         * before the web process exists and after it is up.
         *
         * Raised and never lowered, and the asymmetry is the engine's. Setting
         * it False under `Adwaita-dark` left the query at dark: the rule there
         * is the flag OR the name, so the name cannot be argued with. The half
         * that can be fixed is the one that occurs -- a dark desktop reported
         * light -- and the half that cannot is a theme named for a variant it
         * does not have, which no distribution ships.
         *
         * Raising it can move the palette, and only in the direction this never
         * asks for: on a light theme with a dark variant, GTK switches to the
         * variant, and `Adwaita` went f6f5f4 to 353535 under it. This returns
         * true only where the palette already measured dark, and on the three
         * dark themes above the flag moved nothing. A theme that did move would
         * be re-read by the watcher, measure dark again, and ask for the same
         * flag -- one repaint, not a loop.
         */
        gtkPreferDark: function (theme) {
            return !!theme && theme.scheme === "dark";
        },

        /*
         * The two surfaces GTK puts up before the document, painted from one
         * value, on the two lanes that drive GTK -- this one and the PyGObject
         * one, which calls in here rather than reading the colour itself.
         *
         * The window is styled through its own style context and not through
         * add_provider_for_screen: the screen-wide call reaches every window in
         * the process, and there is one here today only by accident of there
         * being one window. A provider on the widget cannot grow that reach.
         *
         * Neither of these throws. A background that will not paint is a window
         * that comes up in the theme colour, which is exactly where this
         * started -- worth a note on stderr and not worth a launch.
         */
        paintGtkWindow: function (Gtk, Gdk, win, background) {
            var rgb = this.parseColor(background);
            if (!rgb || !Gtk || !Gdk) {
                return false;
            }
            var css = "window, .background { background-color: rgb(" +
                Math.round(rgb.red * 255) + "," +
                Math.round(rgb.green * 255) + "," +
                Math.round(rgb.blue * 255) + "); }";
            try {
                var provider = new Gtk.CssProvider();
                provider.load_from_data(css);
                win.get_style_context().add_provider(
                    provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
                return true;
            } catch (e) {
                this.note("could not paint the window: " + e);
                return false;
            }
        },

        paintWebKitView: function (Gdk, wv, background) {
            var rgb = this.parseColor(background);
            if (!rgb || !Gdk) {
                return false;
            }
            try {
                var rgba = new Gdk.RGBA();
                rgba.red = rgb.red;
                rgba.green = rgb.green;
                rgba.blue = rgb.blue;
                rgba.alpha = 1;
                wv.set_background_color(rgba);
                return true;
            } catch (e) {
                this.note("could not paint the view: " + e);
                return false;
            }
        },

        /*
         * The macOS palette, in themeKeys order, with the fallbacks each entry
         * needs spelled after a `|`.
         *
         * The fallbacks are versions and not preferences. `controlAccentColor`
         * and `separatorColor` are 10.14, `labelColor` is 10.10, and a lane that
         * asked for the newest spelling alone would report nothing at all on a
         * Mac where everything else works. First one the runtime answers to
         * wins.
         */
        macColorNames: "windowBackgroundColor," +
            "labelColor|controlTextColor," +
            "textBackgroundColor," +
            "textColor," +
            "controlAccentColor|selectedContentBackgroundColor|alternateSelectedControlColor," +
            "alternateSelectedControlTextColor|selectedMenuItemTextColor," +
            "separatorColor|gridColor",

        readMacColor: function (dollar, names) {
            var list = String(names).split("|");
            for (var i = 0; i < list.length; i++) {
                try {
                    var color = dollar.NSColor[list[i]];
                    if (!color) {
                        continue;
                    }
                    // Through sRGB rather than off the colour as it stands: a
                    // catalog colour has no components at all until it is
                    // converted, and asking one for redComponent raises.
                    var srgb = color.colorUsingColorSpace(dollar.NSColorSpace.sRGBColorSpace);
                    if (!srgb) {
                        continue;
                    }
                    return {
                        hex: this.toHex({
                            red: srgb.redComponent,
                            green: srgb.greenComponent,
                            blue: srgb.blueComponent
                        }),
                        alpha: srgb.alphaComponent
                    };
                } catch (_) {}
            }
            return null;
        },

        /*
         * And the read, which is also a correctness fix rather than a feature.
         *
         * NSColor's system colours are *dynamic*: they resolve against
         * NSAppearance.currentAppearance at the moment they are asked. A JXA
         * script has no drawing context, so currentAppearance is nil, and nil
         * resolves to Aqua -- which means reading windowBackgroundColor without
         * doing anything about it reports **light colours on a dark Mac**. Not
         * an error, not empty, just wrong, and wrong in exactly the direction
         * that would make an app paint white on a dark desktop.
         *
         * So the appearance is set here, from AppleInterfaceStyle, before a
         * single colour is read. That default is the plainest reading macOS
         * offers -- the string "Dark", or nothing at all for light -- and it is
         * used to *choose the appearance to resolve under*, never to report the
         * scheme: the scheme still comes from the luminance of what came back,
         * on this lane as on every other.
         */
        readMacTheme: function (ObjCRef, dollar) {
            try {
                var style = dollar.NSUserDefaults.standardUserDefaults
                    .stringForKey("AppleInterfaceStyle");
                var wantsDark = String(ObjCRef.unwrap(style) || "").indexOf("Dark") === 0;
                // The constants are these strings. Written out rather than
                // taken from $.NSAppearanceNameDarkAqua, which is a global the
                // bridge does not always carry, and a nil name here would give
                // a nil appearance and put the read straight back where it
                // started.
                var appearance = dollar.NSAppearance.appearanceNamed(
                    wantsDark ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua");
                if (appearance) {
                    dollar.NSAppearance.currentAppearance = appearance;
                }
            } catch (e) {
                this.noteOnce("could not set the drawing appearance: " + e);
            }
            var keys = this.themeKeyList();
            var names = String(this.macColorNames).split(",");
            var found = [];
            for (var i = 0; i < names.length; i++) {
                found[i] = this.readMacColor(dollar, names[i]);
                if (!found[i]) {
                    this.noteOnce("no NSColor answered to " + names[i]);
                    return null;
                }
            }
            var raw = { source: "macos" };
            for (var j = 0; j < keys.length; j++) {
                raw[keys[j]] = this.flattenColor(found[j].hex, found[j].alpha, found[0].hex);
            }
            return raw;
        },

        /*
         * The same pair on macOS, where the colour has to be taken apart
         * because NSColor is built from components and reads no string.
         * parseColor is where that happens, so this lane and the four that hand
         * a string to a toolkit are all reading one value.
         *
         * The view is the harder half. WKWebView draws an opaque white behind
         * the page and the property that says otherwise is not public: the
         * supported spelling, underPageBackgroundColor, is macOS 12 and later,
         * and drawsBackground is a key that has answered to setValue:forKey:
         * for far longer. Both are tried, neither is required, and the window
         * underneath is painted either way -- so the worst outcome here is the
         * white this was opened to close, and never a lane that will not start.
         */
        paintMacWindow: function (win, background) {
            var dollar = eval("$");
            var rgb = this.parseColor(background);
            if (!rgb) {
                return false;
            }
            try {
                win.backgroundColor = dollar.NSColor.colorWithSRGBRedGreenBlueAlpha(
                    rgb.red, rgb.green, rgb.blue, 1.0);
                return true;
            } catch (e) {
                this.note("could not paint the window: " + e);
                return false;
            }
        },

        paintMacView: function (wv, background) {
            var dollar = eval("$");
            var rgb = this.parseColor(background);
            if (!rgb) {
                return false;
            }
            var painted = false;
            try {
                wv.underPageBackgroundColor = dollar.NSColor.colorWithSRGBRedGreenBlueAlpha(
                    rgb.red, rgb.green, rgb.blue, 1.0);
                painted = true;
            } catch (_) {}
            // Lets the window's own colour through instead of the view's
            // white, which is the older answer and the one that covers the
            // releases the property above does not exist on.
            try {
                wv.setValueForKey(false, "drawsBackground");
                painted = true;
            } catch (_) {}
            if (!painted) {
                this.note("could not paint the view; it will show its own background");
            }
            return painted;
        },

        /*
         * The Windows palette, and the one lane where half of it is this file's
         * choice rather than the system's answer.
         *
         * System.Drawing.SystemColors is the obvious read and it is only half
         * right: on Windows 10 and 11 those are still the **classic light**
         * values whatever the app theme is set to. Reading them alone reports a
         * light desktop on a dark one -- the same failure the macOS lane has,
         * arrived at from the other direction and with no appearance to set to
         * fix it.
         *
         * So the scheme comes from the registry, which is where Windows keeps
         * the answer, and a dark reading takes the four surface colours from
         * the constants below. Those are this file's, not the system's: there
         * is no API that reports them, and inventing them by inverting the
         * light ones would be worse -- a desktop nobody is running. They are
         * the values Explorer and WinUI use, so an app that follows them
         * matches what is next to it on screen.
         *
         * The accent pair is read from SystemColors in both schemes, because
         * COLOR_HIGHLIGHT does track the user's accent colour on Windows 10 and
         * later. That is the part the system will actually tell you.
         */
        windowsDarkSurfaces: "background:#202020,foreground:#ffffff," +
            "base:#2b2b2b,text:#ffffff,border:#3d3d3d",

        /*
         * Where that scheme is read from, and why the obvious spelling of it
         * was wrong for as long as it existed.
         *
         * `eval("Microsoft")` resolves nothing. The import block at the top of
         * the jsc region brings in `System` and five namespaces under it and
         * nothing else, so the name is not in scope, the read throws, and the
         * catch turns it into `true` -- a light desktop reported on a dark one.
         * Not an error and not empty, just wrong, and in exactly the direction
         * that paints a white app on a dark machine. Every runner this has
         * built on is light, so nothing that ran here could ever have caught
         * it; flipping the desktop is what did, and the tell was that
         * `prefers-color-scheme` followed the registry while every colour this
         * file reports stayed at its light value.
         *
         * The type is reached by name instead. `Registry` is in mscorlib, so
         * `System.Type.GetType` resolves it with no import to add, through the
         * `eval("System")` every other late-bound call here already uses, and
         * `GetValue` has one public static overload so `GetMethod` needs no
         * signature to pick it out. The same reflected shape the WebView2 calls
         * below are built from.
         */
        windowsAppsUseLightTheme: function () {
            try {
                var SystemRef = eval("System");
                var type = SystemRef.Type.GetType("Microsoft.Win32.Registry");
                if (!type) {
                    this.noteOnce("no Microsoft.Win32.Registry in this runtime; " +
                        "taking the desktop for light");
                    return true;
                }
                var method = type.GetMethod("GetValue");
                if (!method) {
                    this.noteOnce("Microsoft.Win32.Registry carries no GetValue here; " +
                        "taking the desktop for light");
                    return true;
                }
                var value = method.Invoke(null, [
                    "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\" +
                        "CurrentVersion\\Themes\\Personalize",
                    "AppsUseLightTheme", null]);
                // Absent is light, and that is Windows' own default rather than
                // a guess: the value is written when the setting is changed, so
                // a machine that has never been switched to dark does not carry
                // it at all.
                if (value === null || value === undefined) {
                    this.noteOnce("no AppsUseLightTheme on this machine; " +
                        "taking Windows' own default of light");
                    return true;
                }
                // Once per distinct value, so a flip leaves two lines and a
                // steady desktop leaves one. This is the reading the surface
                // override turns on, and it was unattributable while the only
                // record of it was the colour that came out the other end.
                this.noteOnce("AppsUseLightTheme=" + value);
                return Number(value) !== 0;
            } catch (e) {
                this.noteOnce("could not read the app theme setting: " + e);
                return true;
            }
        },

        readWindowsTheme: function (SystemRef) {
            var nt = this;
            // Through Convert rather than off the Byte directly, for the reason
            // makeWindowsColor gives about the other direction: JScript.NET
            // picks an overload from the types it is handed.
            var hexOf = function (color) {
                return nt.toHex({
                    red: SystemRef.Convert.ToInt32(color.R) / 255,
                    green: SystemRef.Convert.ToInt32(color.G) / 255,
                    blue: SystemRef.Convert.ToInt32(color.B) / 255
                });
            };
            try {
                var system = SystemRef.Drawing.SystemColors;
                var raw = {
                    source: "windows",
                    background: hexOf(system.Control),
                    foreground: hexOf(system.ControlText),
                    base: hexOf(system.Window),
                    text: hexOf(system.WindowText),
                    accent: hexOf(system.Highlight),
                    accentText: hexOf(system.HighlightText),
                    border: hexOf(system.ControlDark)
                };
                if (!this.windowsAppsUseLightTheme()) {
                    var overrides = String(this.windowsDarkSurfaces).split(",");
                    for (var i = 0; i < overrides.length; i++) {
                        var cut = overrides[i].indexOf(":");
                        raw[overrides[i].substring(0, cut)] = overrides[i].substring(cut + 1);
                    }
                }
                return raw;
            } catch (e) {
                this.noteOnce("could not read the desktop palette: " + e);
                return null;
            }
        },

        /*
         * And on Windows, where both surfaces take a System.Drawing.Color.
         *
         * The Form paints the moment it is shown. The WebView2 control paints
         * white until it has content, and DefaultBackgroundColor is the
         * supported way to say otherwise -- it is a property of the WinForms
         * control rather than of CoreWebView2, which matters here because
         * CoreWebView2 does not exist until the runtime has finished starting
         * and the window is on screen well before that.
         *
         * Reached by reflection because the type is loaded at run time and
         * cannot be named at compile time, and because the property is not in
         * every WebView2 version this may be running against. A control that
         * does not carry it keeps its white and the Form underneath is still
         * painted.
         */
        makeWindowsColor: function (SystemRef, background) {
            var rgb = this.parseColor(background);
            if (!rgb) {
                return null;
            }
            try {
                // Through Convert rather than by handing doubles to an
                // overload set: JScript.NET picks an overload from the types it
                // is given, and Math.round hands it a Number.
                return SystemRef.Drawing.Color.FromArgb(
                    255,
                    SystemRef.Convert.ToInt32(Math.round(rgb.red * 255)),
                    SystemRef.Convert.ToInt32(Math.round(rgb.green * 255)),
                    SystemRef.Convert.ToInt32(Math.round(rgb.blue * 255)));
            } catch (e) {
                this.note("could not read the background: " + e);
                return null;
            }
        },

        paintWindowsView: function (wv, color) {
            if (!color) {
                return false;
            }
            try {
                var prop = wv.GetType().GetProperty("DefaultBackgroundColor");
                if (!prop || !prop.CanWrite) {
                    return false;
                }
                prop.SetValue(wv, color, null);
                return true;
            } catch (e) {
                return false;
            }
        },

        hasGlobalExpr: function (expression) {
            try {
                return eval(expression);
            } catch (_) {
                return false;
            }
        },

        /*
         * Where this file's document begins and where it ends -- decided once,
         * so that the two halves cut out of it below cannot come from different
         * places.
         *
         * This file's JavaScript, including whatever an author spliced into
         * runWeb, used to be an inline script inside the document it loads,
         * which meant the document's content policy had to permit inline script
         * and could never say script-src 'none'. Every driver injects the
         * preload through its engine, so the page's own code goes the same way
         * and the document carries no executable content at all. What that buys
         * is worth the trouble: an injection bug in someone's app cannot run
         * script in this document, because nothing in the document is allowed
         * to.
         *
         * All of which rests on the cut being in the right place, and the two
         * cuts used to be taken independently -- the document from the first
         * `<script` after the doctype, the page script from the first one in
         * the whole file. They agreed because a test said they had to.
         *
         * Every index below is found or the source is refused, and refusing is
         * the point. There used to be a fallback: no doctype meant "return the
         * whole file cut at the first `<script`", and no script tag or no
         * terminator meant an empty page script that every driver injected
         * without a word. Neither of those is ever the right answer, and on
         * this file the first is not even a near miss -- the string being
         * searched for appears in the source of the function searching for it,
         * a few lines below, inside the page script region. Measured: the
         * document that came out was 186 bytes of this function, it carried no
         * content policy at all on any of the four engines, and the page script
         * was injected into it whole.
         */
        locateDocument: function (content) {
            var text = String(content || "");
            var lower = text.toLowerCase();

            var start = lower.indexOf("<!doctype html");
            if (start < 0) {
                return { error: "there is no <!doctype html> in it" };
            }

            // Anchored at the doctype, which is what makes the two halves agree
            // by construction rather than by anyone remembering to check.
            var tag = text.indexOf("<script", start);
            if (tag < 0) {
                return { error: "nothing opens a script after the doctype" };
            }

            // Exactly one, and this is the guard for the shape that measured
            // worst. A doctype above the document -- a line in the shell region
            // naming it is enough -- starts the cut there, and the document that
            // comes out has the launcher's own text ahead of its <head>. A
            // content policy meta that is not a child of head is in the DOM and
            // is not a policy: Chromium enforced none of it, WebKit enforced
            // only the element-driven half, and the page reported the policy it
            // could see the whole time. Nothing downstream can tell that apart
            // from a policy that held, so it is refused here.
            var second = lower.indexOf("<!doctype html", start + 1);
            if (second >= 0 && second < tag) {
                return { error: "the document names its doctype more than once" };
            }

            var open = text.indexOf(">", tag);
            if (open < 0) {
                return { error: "the script tag after the doctype is never closed" };
            }

            var end = text.lastIndexOf("//</script>");
            if (end <= open) {
                return { error: "nothing closes the page script" };
            }

            return { start: start, tag: tag, open: open, end: end };
        },

        // Both halves go through it, so a file this launcher cannot split fails
        // once, in one place, saying which part of the shape was missing --
        // rather than twice, silently, in opposite directions.
        splitOrThrow: function (content) {
            var at = this.locateDocument(content);
            if (at.error) {
                throw new Error(
                    "neutrino: cannot tell this file's document from its script: " + at.error);
            }
            return at;
        },

        /*
         * The document, with the script taken out of it.
         *
         * The tail used to be fabricated -- "<body></body></html>" appended to
         * whatever the head cut produced -- so the document every engine loaded
         * had an empty body no matter what the file said. That is why the demo
         * blinked: the first paint was this launcher's default style over
         * nothing, and the app's own markup arrived a frame or more later, from
         * script.
         *
         * The body now opens on the document line, above the script tag, which
         * is where the head cut already ends. So the markup an author builds in
         * is in the first paint rather than after it, and this function no
         * longer invents a document that is not in the file -- it returns the
         * file's own, minus the script element. `<script>` inside `<body>` is
         * valid HTML, so the file read directly by a browser is still the same
         * document.
         */
        extractHtmlDocument: function (content) {
            var text = String(content || "");
            var at = this.splitOrThrow(text);
            return text.substring(at.start, at.tag) + "</body></html>";
        },

        // The other half: everything the document used to carry, handed to the
        // engine to inject instead. Stops before the closing sentinel, which is
        // markup pretending to be a comment and is not wanted in either half.
        extractPageScript: function (content) {
            var text = String(content || "");
            var at = this.splitOrThrow(text);
            return text.substring(at.open + 1, at.end);
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
            /*
             * The PyGObject lane's shim, which hosts this source in a
             * JavaScriptCore context and drives GTK from Python. It gets a flag
             * of its own rather than borrowing NeutrinoQml: this dispatch
             * exists to say which engine is running, and two lanes answering to
             * one name would make it say the wrong thing in the one place
             * anybody reads to find out.
             */
            if (this.hasGlobalExpr("typeof NeutrinoPy !== 'undefined'")) {
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
            // No app is spliced in here yet, and this template's own greeting
            // is markup on the document line rather than something written
            // from script -- which is the whole of what the early shell is
            // for. Unbuilt, this file paints its greeting and does nothing.
            //#RUNWEB_END
        },

        /*
         * The difference between "this lane cannot start" and "this program
         * failed", which the launcher reads as the difference between trying
         * the next engine and stopping. Tagged rather than matched on its
         * message, because the shell's decision must not depend on the spelling
         * of a sentence anyone might reword.
         */
        engineUnavailable: function (message) {
            var err = new Error(message);
            err.neutrinoEngineUnavailable = true;
            return err;
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
            throw this.engineUnavailable("WebKit2 introspection typelibs not found");
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
            // Whether init got the NSWindow subclass registered. Read by
            // createWindow, which is the only place that can act on it.
            var macKeyableWindow = false;
            var pendingPreload = null;
            var pendingPageScript = null;
            var documentLoaded = false;
            // The theme observer is an ObjC object with no arguments to its
            // selector, so what it needs to reach has to be here rather than
            // passed in. Both are null until the launch has got that far, and
            // the observer is not attached until it has.
            var driverRef = null;
            var windowRef = null;
            var observerRef = null;
            // Held for the same reason observerRef is: an NSTimer's target is
            // an object this script created, and nothing else refers to it.
            var tickerRef = null;
            // The status file's line 7, and the whole of what separates "the
            // window has stopped changing" from "the thing writing this file
            // has stopped". Both are testing-tier only.
            var statusTicks = 0;
            // The last title this lane read off the view. The clock below is a
            // poll and this is what makes it an edge: without it every tick
            // would set the window's title again, and writeStatus with it.
            var lastDocumentTitle = "";

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
                     * The one subclass here that is not an NSObject, and the
                     * only reason it exists: AppKit answers NO to both of these
                     * for a borderless window, so a window built with an empty
                     * style mask cannot become key and the web view inside it
                     * never sees a keystroke. There is no property to set and
                     * no flag to raise -- the answer is a method, so overriding
                     * it is the whole mechanism.
                     *
                     * Registered unconditionally rather than under the config,
                     * because a class that fails to register should say so on
                     * the launch that would have used it and not on some later
                     * one; `undecorated` decides which class createWindow
                     * allocates, not whether this one exists.
                     *
                     * Degraded and not fatal, by the rule createWebView's
                     * message channel already follows on this lane: a
                     * borderless window nothing can type into is inert, and a
                     * launch with no window at all says less. The note names
                     * the call that was missing.
                     */
                    macKeyableWindow = false;
                    try {
                        ObjCRef.registerSubclass({
                            name: "NeutrinoKeyableWindow",
                            superclass: "NSWindow",
                            methods: {
                                "canBecomeKeyWindow": {
                                    types: ["bool", []],
                                    implementation: function () { return true; }
                                },
                                "canBecomeMainWindow": {
                                    types: ["bool", []],
                                    implementation: function () { return true; }
                                }
                            }
                        });
                        macKeyableWindow = true;
                    } catch (e) {
                        self.note("no keyable window subclass: " + e);
                    }

                    /*
                     * The theme watcher, and on this lane it has to be a real
                     * object: -run never returns, so there is no loop to
                     * re-read from the way the Windows driver has. A subclass
                     * with a selector is the same shape the two delegates
                     * either side of this use, and for the same reason -- the
                     * block-taking spellings of these APIs are the ones JXA
                     * cannot supply.
                     *
                     * Registered here and attached in runEventLoop, because
                     * what it reaches -- the driver, the window, the view --
                     * does not exist yet.
                     */
                    try {
                        ObjCRef.registerSubclass({
                            name: "NeutrinoAppearanceObserver",
                            superclass: "NSObject",
                            methods: {
                                "desktopThemeChanged:": {
                                    types: ["void", ["id"]],
                                    implementation: function () {
                                        if (!driverRef) {
                                            return;
                                        }
                                        self.applyTheme(driverRef, windowRef, webViewRef,
                                            driverRef.readTheme());
                                    }
                                }
                            }
                        });
                    } catch (e) {
                        self.note("no theme watcher on this lane: " + e);
                    }

                    /*
                     * This lane's clock, in the same shape and for the same
                     * reason: -run never returns, so a clock here has to be an
                     * ObjC object with a selector, and NSTimer's block-taking
                     * spelling is one JXA cannot supply.
                     *
                     * It used to be registered only under the testing tier,
                     * because writeStatus was all it did and writeStatus
                     * refuses to write in a release build. It now also carries
                     * the title hook, which every build needs, so the tier gate
                     * moved down into writeStatus alone -- where it already
                     * was.
                     *
                     * A clock and not a signal, on the one lane where that is a
                     * choice this file did not get to make. The hook the other
                     * four use is the engine's own title-changed notification;
                     * WKWebView's is KVO, whose observer selector takes a
                     * `void *` context, and the JXA bridge has no type string
                     * for a pointer -- a registered method whose types cannot
                     * name its last argument marshals whatever happens to be in
                     * the register. Two hundred milliseconds against a property
                     * read is the price of not writing that.
                     */
                    try {
                        ObjCRef.registerSubclass({
                            name: "NeutrinoStatusTicker",
                            superclass: "NSObject",
                            methods: {
                                "tick:": {
                                    types: ["void", ["id"]],
                                    implementation: function () {
                                        if (driverRef) {
                                            driverRef.statusTick();
                                        }
                                    }
                                }
                            }
                        });
                    } catch (e) {
                        self.note("no clock on this lane: " + e);
                    }

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
                     *
                     * -stopLoading is read and not called, and that is not a
                     * typo. JXA runs a zero-argument selector when the property
                     * is *read*: -stopLoading returns void, so the read stops
                     * the load and yields undefined, and a `()` after it throws
                     * having already had its effect. This shipped as
                     * `stopLoading()` from PR 6 until PR 23 -- refusing the
                     * navigation every time and logging "could not refuse
                     * navigation to ..." every time, which is why nobody
                     * noticed for four PRs. Measured, on the same artifact one
                     * line apart: with this line deleted the page takes the
                     * window, and with the read -- either spelling -- the app
                     * keeps its own document. The same rule reaches win.center
                     * in createWindow and app.run in runEventLoop, and both
                     * carry a note. test/navrefuse.sh asserts this one from
                     * both sides, because a guard that says it failed while
                     * succeeding and one that says it succeeded while failing
                     * read the same from any single lane.
                     */
                    /*
                     * And the other half of a page trying to leave -- a link
                     * with a target, which is not a navigation of this view --
                     * is not handled on this lane, and this is what was
                     * measured rather than what was assumed.
                     *
                     * It is not a hole. WKUIDelegate.h: "If you do not
                     * implement this method, the web view will cancel the
                     * navigation." So the window is already refused. What the
                     * other four lanes add on top -- saying so, and handing the
                     * url to the desktop -- is what is missing here.
                     *
                     * The selector is not the one the essay below warns about,
                     * and that much worked. -webView:decidePolicyForNavigation-
                     * Action:decisionHandler: takes a block JXA cannot call;
                     * this one takes four objects and returns one:
                     *
                     *   - (nullable WKWebView *)webView:(WKWebView *)webView
                     *       createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
                     *       forNavigationAction:(WKNavigationAction *)navigationAction
                     *       windowFeatures:(WKWindowFeatures *)windowFeatures;
                     *
                     * Registered as NeutrinoUIDelegate and attached to the
                     * view's UIDelegate, it was called, and the url read
                     * cleanly off navigationAction.request.URL:
                     *
                     *   refused a new window for about:blank
                     *   returning nil for the refused window
                     *
                     * Both lines present, in that order, and then the process
                     * ends. No exception, no further output, and stdwin's OPEN,
                     * FS1 and CLOSE phases never observed -- three failures in a
                     * suite that was green. The second line was added precisely
                     * to split the two candidates, and it says the body ran to
                     * the end: what does not survive is the *return*.
                     *
                     * `return null` is the reason. JXA turns a JS null into
                     * NSNull rather than nil in an ObjC context -- visible in
                     * this same lane's log, where the theme watcher raises
                     * "-[NSNull length]: unrecognized selector" for the same
                     * conversion -- so WebKit is handed an NSNull where a
                     * WKWebView or nil was promised, and sends it messages.
                     *
                     * Every method in this file returns void, and this was the
                     * first that would not. No spelling of nil that JXA can
                     * return from a registerSubclass implementation is known
                     * here, and this desk has no macOS to find one on. Two
                     * rounds of CI went to learning the above; a third spent
                     * guessing at a return value would be the thing this file's
                     * Method section already refuses. The refusal works without
                     * any of it, so what is left undone is a log line and a
                     * forward, and it is written down instead of shipped.
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
                                        webViewRef.stopLoading;
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
                readTheme: function () {
                    return self.readMacTheme(ObjCRef, dollar);
                },
                repaint: function (win, wv, background) {
                    self.paintMacWindow(win, background);
                    if (wv) {
                        self.paintMacView(wv, background);
                    }
                },
                evaluate: function (wv, js) {
                    // Before the commit there is no document of ours to
                    // evaluate into, and the preload already carries the
                    // snapshot, so nothing is lost by dropping this.
                    if (!documentLoaded) {
                        return;
                    }
                    // A nil completion handler, which is the one thing JXA can
                    // do with a block parameter: it cannot call one, and the
                    // navigation delegate above records what happens when a
                    // selector requires it. Nothing here needs the result.
                    wv.evaluateJavaScriptCompletionHandler(js, null);
                },
                createWindow: function (config) {
                    var frame = dollar.NSMakeRect(0, 0, config.width, config.height);
                    /*
                     * NSBorderlessWindowMask is zero, so this is the mask with
                     * nothing in it rather than a mask with a bit cleared. The
                     * three names are still spelled out on the decorated side
                     * because they are the frame this launcher has always
                     * opened, and a reader should not have to know what a
                     * default mask contains to know what was asked for.
                     *
                     * The class is the other half. A borderless NSWindow that
                     * is a plain NSWindow cannot become key; if the subclass
                     * did not register, init has already said so, and this
                     * opens the window anyway rather than opening nothing.
                     */
                    var mask = self.undecorated()
                        ? dollar.NSBorderlessWindowMask
                        : (dollar.NSTitledWindowMask | dollar.NSClosableWindowMask |
                           dollar.NSResizableWindowMask);
                    var windowClass = (self.undecorated() && macKeyableWindow)
                        ? dollar.NeutrinoKeyableWindow
                        : dollar.NSWindow;
                    var win = windowClass.alloc.initWithContentRectStyleMaskBackingDefer(
                        frame,
                        mask,
                        dollar.NSBackingStoreBuffered,
                        false
                    );
                    win.title = config.title;
                    self.paintMacWindow(win, self.resolveBackground(self.theme));
                    windowRef = win;
                    // Read and not called, by the rule the navigation
                    // guard's comment sets out. This was win.center(), which
                    // centred the window and then threw into this catch on
                    // every launch it ever made. Measured: deleting the line
                    // moves the window, keeping it in either spelling does not.
                    try { win.center; } catch (_) {}
                    windowDelegateRef = dollar.NeutrinoWindowDelegate.alloc.init;
                    win["delegate"] = windowDelegateRef;
                    this.writeStatus(win);
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
                    self.paintMacView(wv, self.resolveBackground(self.theme));
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
                /*
                 * The one height the flip below is allowed to measure against,
                 * and it is the primary display's -- the screen whose frame
                 * origin is 0,0. Cocoa's global coordinate space grows upward
                 * from that screen's bottom-left corner and the top-left space
                 * every caller here speaks grows downward from its top-left, so
                 * the two differ by that one screen's height and by nothing
                 * else, whichever display a window is actually on.
                 *
                 * This was NSScreen.mainScreen, which is not the primary
                 * display: it is the screen holding the window with keyboard
                 * focus, so on a second monitor of a different height it
                 * answered a number that has no part in this conversion, and
                 * answered a different one as focus moved. Every window on this
                 * machine is on the only screen there is, which is why both
                 * spellings measure 1024 here and why nothing caught it.
                 *
                 * screens is documented never to be empty, and mainScreen is
                 * kept as the fallback rather than letting the arithmetic go on
                 * with undefined if it ever is.
                 */
                primaryScreenHeight: function () {
                    var screens = dollar.NSScreen.screens;
                    if (screens && screens.count > 0) {
                        return screens.objectAtIndex(0).frame.size.height;
                    }
                    return dollar.NSScreen.mainScreen.frame.size.height;
                },
                toMacY: function (y, winHeight) {
                    return this.primaryScreenHeight() - y - winHeight;
                },
                toTopLeftY: function (macY, winHeight) {
                    return this.primaryScreenHeight() - macY - winHeight;
                },
                /*
                 * Scaffolding for verify-macos.sh, which has no other way to
                 * read a window's geometry back. It is not part of running an
                 * app, so a release build does not write it anywhere.
                 *
                 * Seven lines now, and the last four are what makes this an
                 * instrument rather than a receipt. The first three were only
                 * ever written from inside setTitle, resize and move -- so they
                 * report what this driver was *asked* to do, and a window moved
                 * by anything else on the platform produced no write at all.
                 * That is enough to check an IPC call landed and not enough to
                 * ask what `window.resizeTo` or an assignment to
                 * `document.title` did, because neither of those comes through
                 * here. statusTick below calls this on a clock for exactly that
                 * reason.
                 *
                 * It still reads NSWindow and never the DOM: `win.title` is the
                 * title bar, `win.frame` is the frame the window server has.
                 * That keeps it standing outside the document in the same way
                 * xdotool stands outside it on X11 -- in the app's process, but
                 * not the page's account of itself. A reading taken from the
                 * document belongs in the title as a -SELF field, not in here.
                 *
                 * Line 7 is a counter and not a clock. A file that has stopped
                 * being written and a window that has stopped changing are the
                 * same three lines otherwise, and the difference between them
                 * is `close()` working and the poller having died.
                 *
                 * It takes the window and not a title, and that is a repair.
                 * `resize` and `move` have called this as
                 * `writeStatus(String(win.title), win)` since they were
                 * written, and on this bridge `String()` of an ObjC wrapper is
                 * the wrapper's description -- `[id __NSCFString]` -- and not
                 * the string. Nothing noticed for as long as a setTitle always
                 * followed and overwrote it. Put a clock on the same function
                 * and it writes that text over the good title several times a
                 * second, which starved every suite on this platform that polls
                 * this file: measured, five red steps and a lane that could not
                 * say why. Every other reader of an ObjC string in this file
                 * goes through unwrap, and now so does this one -- taking the
                 * window rather than a title is what stops a fifth caller
                 * getting it wrong again.
                 */
                windowTitle: function (win) {
                    try {
                        return String(ObjCRef.unwrap(win.title) || "");
                    } catch (_) {
                        return "";
                    }
                },
                writeStatus: function (win) {
                    if (!self.hasTier("testing")) {
                        return;
                    }
                    try {
                        var title = this.windowTitle(win);
                        var f = win.frame;
                        var topLeftY = Math.round(this.toTopLeftY(f.origin.y, f.size.height));
                        var inner = "?x?";
                        try {
                            var cv = win.contentView.frame;
                            inner = Math.round(cv.size.width) + "x" + Math.round(cv.size.height);
                        } catch (_) {}
                        /*
                         * Widened, not renumbered: this line carried the work
                         * area's size and now carries its top-left corner too.
                         * Appending to this file or widening a line is safe and
                         * inserting into it is not -- verify-std.sh reads the
                         * seven lines positionally as l1..l7, so a line added
                         * in the middle silently reassigns every one below it.
                         * Nothing reads l5 today, which is what makes this the
                         * cheap line to widen.
                         *
                         * The conversion is here and not in the verifier
                         * because toTopLeftY is here. `visibleFrame` is in
                         * AppKit's bottom-left coordinates and its *top* edge
                         * is what a window cannot be placed above -- the menu
                         * bar is the thing the fifty-pixel position tolerance
                         * in verify-macos.sh has been paying for. Deriving
                         * that in bash would be a second copy of a coordinate
                         * flip that already exists, and the two would be free
                         * to disagree.
                         */
                        var work = "?x?";
                        try {
                            var vf = dollar.NSScreen.mainScreen.visibleFrame;
                            work = Math.round(vf.size.width) + "x" + Math.round(vf.size.height) +
                                "+" + Math.round(vf.origin.x) +
                                "+" + Math.round(this.toTopLeftY(vf.origin.y, vf.size.height));
                        } catch (_) {}
                        var windows = "?";
                        try { windows = String(dollar.NSApp.windows.count); } catch (_) {}
                        statusTicks = statusTicks + 1;
                        var status = title + "\n" +
                            Math.round(f.size.width) + "x" + Math.round(f.size.height) + "\n" +
                            Math.round(f.origin.x) + "," + topLeftY + "\n" +
                            inner + "\n" +
                            work + "\n" +
                            windows + "\n" +
                            statusTicks;
                        var statusPath = dollar.NSTemporaryDirectory().js + "neutrino-title.txt";
                        dollar.NSString.alloc.initWithUTF8String(status)
                            .writeToFileAtomicallyEncodingError(statusPath, true, 4, null);
                    } catch (_) {}
                },

                /*
                 * What the clock calls, and it has two jobs.
                 *
                 * The first is this lane's half of the title hook: the view's
                 * `title` is WKWebView's own reading of the document it has
                 * loaded, and comparing it against the last one accepted is
                 * what turns a poll into an edge. The url comes from
                 * currentUrl, which is the reader isTrustedMacSender already
                 * uses, so the two sender checks on this lane cannot drift
                 * apart.
                 *
                 * The second is writeStatus, which is scaffolding and gates
                 * itself on the tier. The title goes first so that a tick which
                 * moves the window's name writes the file with the new name in
                 * it rather than one tick behind -- setTitle writes it again on
                 * the way past, and a second write of the same seven lines
                 * costs nothing.
                 */
                statusTick: function () {
                    if (!windowRef) {
                        return;
                    }
                    try {
                        // The same rule the WebView2 loop follows, for the same
                        // reason: this is a poll, lastDocumentTitle is what makes
                        // it an edge, and latching a title before there is a
                        // document to judge it against would swallow that title
                        // for the rest of the run.
                        //
                        // hasCommittedDocument is one gate and acceptDocumentTitle
                        // is a second, and the latch used to sit between them --
                        // so a title refused by the second was latched as seen
                        // and never offered again. That is the same defect this
                        // comment was written about, one gate further down.
                        //
                        // Measured: `macos-stdwin` lost STD-WIN-OPEN-SELF in two
                        // rounds out of four. The probe calls
                        // open("ftp://neutrino.invalid/probe","_self"), which asks
                        // the engine to navigate this view, and acceptDocumentTitle
                        // refuses every title while the view is not showing the
                        // launcher's own document. The refusal is right and it is
                        // brief; the latch was what made it permanent, because the
                        // next read equalled the last and there was no edge left.
                        //
                        // So only an accepted title is latched. A refused one is
                        // re-judged on the next tick, which is what lets it land
                        // once the view is back on its own document -- the gate is
                        // a pure function of two reads and costs nothing to ask
                        // again, and noteOnce keeps a standing refusal quiet.
                        if (webViewRef && self.hasCommittedDocument()) {
                            var raw = "";
                            try {
                                raw = String(ObjCRef.unwrap(webViewRef.title) || "");
                            } catch (_) {
                                raw = "";
                            }
                            if (raw !== lastDocumentTitle) {
                                var name = self.acceptDocumentTitle(currentUrl(), raw);
                                if (name !== null) {
                                    lastDocumentTitle = raw;
                                    this.setTitle(windowRef, name);
                                }
                            }
                        }
                    } catch (_) {}
                    try { this.writeStatus(windowRef); } catch (_) {}
                },
                setTitle: function (win, title) {
                    win.title = title;
                    this.writeStatus(win);
                },
                resize: function (win, w, h) {
                    var frame = win.frame;
                    /*
                     * The top edge is held, not the origin, and it is held
                     * through the same two converters move and writeStatus use
                     * rather than by arithmetic of its own. AppKit measures a
                     * frame from its bottom-left corner, so reusing origin.y
                     * across a size change pins the bottom and lets the title
                     * bar fall by the difference -- which is a move, and the one
                     * move here nobody asked for.
                     *
                     * Measured on the published demo, which opens at the 900x600
                     * default and resizes itself to 520x300 once its page is
                     * ready: the window arrived at top-left 368,98 and 380 ms
                     * later a smaller window sat at 368,430. Same NSWindow, same
                     * window number -- but 332 px down the screen, retitled, and
                     * now carrying content it had none of before. It reads as
                     * the first window closing and a second one opening
                     * somewhere else, which is exactly what it was reported as.
                     *
                     * The other three drivers already hold the top-left, none of
                     * them by choosing to: Forms.ClientSize leaves Location
                     * alone, Gtk.resize leaves the position to the window
                     * manager, and a QML Window's x and y are its top-left.
                     * Cocoa's corner was the only one that leaked, and this
                     * driver had already decided not to speak it.
                     */
                    var target = this.frameSizeForContent(win, w, h);
                    var top = this.toTopLeftY(frame.origin.y, frame.size.height);
                    win.setFrameDisplay(
                        dollar.NSMakeRect(frame.origin.x,
                            this.toMacY(top, target.height),
                            target.width, target.height), true);
                    this.writeStatus(win);
                },

                /*
                 * The content size a caller asked for, in the frame size AppKit
                 * needs to produce it.
                 *
                 * This driver had already decided what a size means, at the one
                 * place it opens a window:
                 * `initWithContentRectStyleMaskBackingDefer` takes a **content**
                 * rect, so `--size 900x600` gives a 900x600 web view inside a
                 * frame 32 px taller. `resize` then set the frame to the numbers
                 * it was handed, so one app asking for one size got two
                 * different windows depending on when it asked -- 900x600 of
                 * content at launch and 900x568 afterwards. Measured:
                 * `resize(640,480)` produced `inner=640x448 outer=640x480`,
                 * against `640x480` of content on all three other lanes.
                 *
                 * So this is not a change of definition, it is the resize path
                 * catching up with the creation path beside it, and with Windows
                 * (`ClientSize`), GTK (`gtk_window_resize`) and QML
                 * (`root.width`/`height`), which all size content already.
                 * Content is also the only definition a page can check for
                 * itself: `innerWidth === w` after the call.
                 *
                 * `frameRectForContentRect:` is AppKit's own conversion and
                 * accounts for the chrome this window actually has rather than a
                 * constant this file would have to keep true. If the bridge
                 * cannot answer, the current frame and content view give the
                 * same difference by subtraction -- exact as long as the chrome
                 * does not change between the two reads, which is the same
                 * assumption the first route makes and states less openly. If
                 * neither answers, sizing the frame is what this did for its
                 * whole life and is better than refusing to resize.
                 */
                frameSizeForContent: function (win, w, h) {
                    try {
                        var r = win.frameRectForContentRect(dollar.NSMakeRect(0, 0, w, h));
                        var fw = Math.round(r.size.width);
                        var fh = Math.round(r.size.height);
                        if (fw > 0 && fh > 0) {
                            return { width: fw, height: fh };
                        }
                    } catch (e) {
                        self.noteOnce("frameRectForContentRect did not answer: " + e);
                    }
                    try {
                        var frame = win.frame;
                        var cv = win.contentView.frame;
                        var dw = Math.round(frame.size.width - cv.size.width);
                        var dh = Math.round(frame.size.height - cv.size.height);
                        if (dw >= 0 && dh >= 0) {
                            return { width: w + dw, height: h + dh };
                        }
                    } catch (e2) {
                        self.noteOnce("could not measure the window chrome: " + e2);
                    }
                    self.noteOnce("sizing the frame instead of the content; " +
                        "the chrome is unmeasurable on this window");
                    return { width: w, height: h };
                },

                // The content size, by the same route writeStatus reads it --
                // the WKWebView is this window's contentView, so its frame is
                // what the page sees as innerWidth/innerHeight.
                contentSize: function (win) {
                    try {
                        var cv = win.contentView.frame;
                        return {
                            width: Math.round(cv.size.width),
                            height: Math.round(cv.size.height)
                        };
                    } catch (_) {
                        var f = win.frame;
                        return {
                            width: Math.round(f.size.width),
                            height: Math.round(f.size.height)
                        };
                    }
                },
                move: function (win, x, y) {
                    var frame = win.frame;
                    var macY = this.toMacY(y, frame.size.height);
                    win.setFrameDisplay(dollar.NSMakeRect(x, macY, frame.size.width, frame.size.height), true);
                    this.writeStatus(win);
                },
                /*
                 * Two units in one struct, on purpose: each half is in the units
                 * of the verb that consumes it. `resizeBy` adds its delta to
                 * `width`/`height` and hands the sum to `resize`, which now
                 * speaks content; `moveBy` adds to `x`/`y` and hands the sum to
                 * `move`, which speaks the frame's top-left. Reporting the frame
                 * size here after `resize` switched to content would have made
                 * every `resizeBy` on this lane wrong by the height of the title
                 * bar, and wrong cumulatively -- each call shrinking the window
                 * by the chrome it double-counted.
                 */
                getBounds: function (win) {
                    var f = win.frame;
                    var size = this.contentSize(win);
                    return {
                        width: size.width,
                        height: size.height,
                        x: Math.round(f.origin.x),
                        y: Math.round(this.toTopLeftY(f.origin.y, f.size.height))
                    };
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
                    /*
                     * Two notifications, and the second is not redundancy.
                     *
                     * AppleInterfaceThemeChangedNotification is the one that
                     * says the desktop switched, and it is known to arrive
                     * before NSColor has finished resolving to the new
                     * appearance -- so the palette read from it can be the old
                     * one. NSSystemColorsDidChangeNotification arrives when the
                     * colours themselves have changed, which is the event this
                     * actually cares about. Whichever is right, applyTheme's
                     * diff means the other one costs nothing: a second read
                     * returning the same palette is not an update.
                     */
                    driverRef = this;
                    try {
                        observerRef = dollar.NeutrinoAppearanceObserver.alloc.init;
                        dollar.NSDistributedNotificationCenter.defaultCenter
                            .addObserverSelectorNameObject(
                                observerRef, "desktopThemeChanged:",
                                "AppleInterfaceThemeChangedNotification", null);
                        dollar.NSNotificationCenter.defaultCenter
                            .addObserverSelectorNameObject(
                                observerRef, "desktopThemeChanged:",
                                "NSSystemColorsDidChangeNotification", null);
                    } catch (e) {
                        self.note("no theme watcher on this lane: " + e);
                    }
                    /*
                     * Two hundred milliseconds, against a probe that holds each
                     * state for fifteen hundred. Seven turns inside the
                     * shortest thing being measured is the margin, and it is
                     * the number the verifier's own completeness control is
                     * checked against -- not a rate chosen for feeling about
                     * right.
                     */
                    try {
                        tickerRef = dollar.NeutrinoStatusTicker.alloc.init;
                        dollar.NSTimer
                            .scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(
                                0.2, tickerRef, "tick:", null, true);
                    } catch (e) {
                        self.note("could not start the clock on this lane: " + e);
                    }
                    dollar.NSApp.setActivationPolicy(0);
                    // Left as a call on purpose. By the same rule, reading
                    // `run` is what enters the event loop, and that does not
                    // return -- so the `()` after it is code that has never run
                    // and never can. Right by accident rather than wrong, and
                    // this PR changed the two lines it measured breaking.
                    app.run();
                }
            };
        },

        createGjsDriver: function () {
            var importsRef = eval("imports");
            var Gtk, WebKit2, GLib, ByteArray, Gdk;
            var self = this;
            var messageCallback = null;
            var pendingPreload = null;
            var pendingPageScript = null;
            var documentLoaded = false;
            // The window the title hook writes to. boot creates the window
            // before the view, so this is set by the time createWebView
            // connects anything to it.
            var windowRef = null;

            return {
                webMessageTransport: "window.webkit.messageHandlers.neutrino.postMessage",
                transportName: "scriptmessage",
                init: function () {
                    /*
                     * Only the typelib acquisition is inside this. Gtk.init
                     * below is deliberately outside it, because a display that
                     * will not open is not this lane being unavailable -- no
                     * other lane would fare better, and turning it into a
                     * fallthrough would replace "cannot open display" with a
                     * walk that tries everything and then reports that no
                     * runtime exists, which is both slower and untrue.
                     */
                    try {
                        importsRef["gi"]["versions"]["Gtk"] = "3.0";
                        importsRef["gi"]["versions"]["WebKit2"] = self.resolveLinuxWebKitVersion();
                        Gtk = importsRef["gi"]["Gtk"];
                        WebKit2 = importsRef["gi"]["WebKit2"];
                        GLib = importsRef["gi"]["GLib"];
                        ByteArray = importsRef["byteArray"];
                        // Pinned to match Gtk rather than left to the loader.
                        // Gdk 3 and Gdk 4 are different libraries and only one
                        // of them belongs in a process running Gtk 3; the
                        // PyGObject lane pins it for the same reason and gets a
                        // warning on stderr when it does not.
                        importsRef["gi"]["versions"]["Gdk"] = "3.0";
                        Gdk = importsRef["gi"]["Gdk"];
                    } catch (e) {
                        if (e && e.neutrinoEngineUnavailable) {
                            throw e;
                        }
                        throw self.engineUnavailable(String(e && e.message ? e.message : e));
                    }
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
                /*
                 * Off a Gtk.Box, which is a widget and not a window: this is
                 * asked before createWindow, and the names being looked up are
                 * the theme's rather than any widget's -- measured identical on
                 * Box, Label and Window. Building a toplevel just to read a
                 * colour would be a second window in a launcher whose whole
                 * point is the first one.
                 */
                readTheme: function () {
                    try {
                        return self.readGtkTheme(new Gtk.Box().get_style_context());
                    } catch (e) {
                        self.noteOnce("could not read the desktop theme: " + e);
                        return null;
                    }
                },
                createWindow: function (config) {
                    // A construct property and not a set_decorated call after
                    // the fact: GTK maps the decoration request onto the window
                    // before it is realised, and a toplevel that is decorated
                    // and then undecorated is one the window manager has
                    // already framed once.
                    var win = new Gtk.Window({
                        title: config.title,
                        default_width: config.width,
                        default_height: config.height,
                        decorated: !self.undecorated()
                    });
                    windowRef = win;
                    win.set_position(Gtk.WindowPosition.CENTER);
                    win.connect("destroy", function () { Gtk.main_quit(); });
                    self.paintGtkWindow(Gtk, Gdk, win, self.resolveBackground(self.theme));
                    return win;
                },
                /*
                 * The scheme, on the toolkit's flag rather than on anything the
                 * document can reach: CSS `color-scheme` was measured against
                 * this engine first and moves nothing -- `:root{color-scheme:
                 * dark}` in the markup, the same declaration through CSSOM, and
                 * a `<meta name=color-scheme>` all left `prefers-color-scheme`
                 * where it was. There is no in-page spelling of this.
                 *
                 * The default settings object and not the widget's, because
                 * this runs before there is a widget -- boot forces the scheme
                 * between reading the palette and creating the window. Both
                 * resolve to the same GtkSettings for the default screen, and
                 * only one of them exists at that moment.
                 *
                 * Read before it is written, and not for the write's sake:
                 * GTK emits the settings change whether or not the value moved,
                 * and once there is a window the style-updated handler is
                 * listening for exactly that. applyTheme's themesDiffer gate is
                 * what stops the second pass, so asking first is the difference
                 * between never entering that path and entering it once.
                 */
                forceScheme: function (theme) {
                    if (!self.gtkPreferDark(theme)) {
                        return;
                    }
                    var settings = Gtk.Settings.get_default();
                    if (!settings) {
                        return;
                    }
                    if (settings.gtk_application_prefer_dark_theme) {
                        return;
                    }
                    settings.gtk_application_prefer_dark_theme = true;
                },
                // Both surfaces again, from the colour the new palette resolves
                // to. Only ever reached for a build that named no background --
                // applyTheme holds that gate, not this.
                repaint: function (win, wv, background) {
                    self.paintGtkWindow(Gtk, Gdk, win, background);
                    if (wv) {
                        self.paintWebKitView(Gdk, wv, background);
                    }
                },
                evaluate: function (wv, js) {
                    // The same gate the navigation guard arms at, and for a
                    // near reason: before the commit there is no document of
                    // ours to evaluate into, and a theme change during the
                    // launch would otherwise be delivered to about:blank and
                    // lost. The palette is in the preload, so nothing is
                    // missing -- the page starts with whatever this would have
                    // told it.
                    if (!documentLoaded) {
                        return;
                    }
                    // run_javascript and not evaluate_javascript: this lane
                    // resolves WebKit2 to 4.1 or 4.0 and only the first has the
                    // newer spelling. Deprecated in 4.1, present in both.
                    wv.run_javascript(js, null, null, null);
                },
                createWebView: function () {
                    var ucm = new WebKit2.UserContentManager();

                    /*
                     * This lane's half of the title hook. `notify::title` is
                     * GObject's own signal on the view's own property, so it
                     * fires for a `<title>` the parser met and for an
                     * assignment the page made alike, and what is read back is
                     * WebKit's answer rather than anything the page handed
                     * over.
                     *
                     * The uri is read off the view and not off the event, the
                     * same way the message handler below reads it, so the two
                     * sender checks on this lane cannot drift apart.
                     */
                    var titleWatcher = function (view) {
                        if (!windowRef) {
                            return;
                        }
                        var showing = "";
                        try {
                            showing = String(view.get_uri());
                        } catch (_) {
                            showing = "";
                        }
                        var name = self.acceptDocumentTitle(showing, view.get_title());
                        if (name !== null) {
                            windowRef.set_title(name);
                        }
                    };

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
                    self.paintWebKitView(Gdk, wv, self.resolveBackground(self.theme));
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
                    wv.connect("notify::title", titleWatcher);
                    return wv;
                },
                resize: function (win, w, h) {
                    win.resize(w, h);
                },
                move: function (win, x, y) {
                    win.move(x, y);
                },
                // The units this driver's own resize and move speak, so the
                // relative verbs above compose with them exactly.
                getBounds: function (win) {
                    var size = win.get_size();
                    var pos = win.get_position();
                    return { width: size[0], height: size[1], x: pos[0], y: pos[1] };
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
                runEventLoop: function (win, wv) {
                    // `this` is the driver: boot calls every one of these as
                    // driver.runEventLoop(...), which is also how applyTheme
                    // gets back to repaint and evaluate below.
                    var driver = this;
                    /*
                     * `style-updated` on the window, which is what GTK emits
                     * when the style context behind a widget changes for any
                     * reason -- a new theme name, a dark-preference flip, a
                     * provider added. It is the signal for the thing being
                     * reported rather than for one of the settings that can
                     * cause it, so a desktop that changes its colours some way
                     * nobody here anticipated still arrives.
                     *
                     * Which is also why applyTheme's diff is not optional:
                     * repainting the window adds a CssProvider to it, and that
                     * emits this. Without the diff the first theme change would
                     * be the last thing this process ever did.
                     */
                    try {
                        win.connect("style-updated", function () {
                            self.applyTheme(driver, win, wv, driver.readTheme());
                        });
                    } catch (e) {
                        self.note("no theme watcher on this lane: " + e);
                    }
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
        /*
         * Set by a driver that has somewhere durable to write. Null everywhere
         * else, and null in every release build: the one installer is gated on
         * the testing tier, which is stamped into the artifact by build.sh and
         * cannot be reached from the environment.
         */
        noteSink: null,

        note: function (message) {
            /*
             * A driver may install a sink, and on Windows one has to. A
             * /t:winexe process launched detached gets NullStream for
             * Console.Error and for both console spellings, so every line below
             * reaches nobody there -- which is why an app that stalled has
             * always "said nothing", rather than having had nothing to say.
             * recordWindowsError covers the one path that throws; a refusal,
             * and everything trace() reports, had no channel at all.
             *
             * Best effort, and deliberately not a `return`: where a caller did
             * hand this process handles, the stderr line is still worth having.
             */
            try {
                if (this.noteSink) { this.noteSink("neutrino: " + message); }
            } catch (_) {}
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
         * The Windows driver's own account, on disk, under the testing tier.
         *
         * Everything this file has ever learned about the Windows first-window
         * stall was read from outside, because from inside the app said nothing
         * -- not for want of lines, but because note() had no channel on this
         * platform at all. This gives it one, timestamped from the moment the
         * driver started, so "the title was set and not seen" and "the title
         * was never set" stop being the same reading.
         *
         * The file is truncated at install: a stale trace from an earlier
         * launch answering questions about this one is the same defect PR 7
         * fixed for the seatbelt profile.
         */
        installWindowsTrace: function (SystemRef, appFolder) {
            var path = SystemRef.IO.Path.Combine(appFolder, "neutrino-trace.log");
            var started = SystemRef.DateTime.UtcNow;
            try {
                SystemRef.IO.File.WriteAllText(path, "");
            } catch (_) {
                return;
            }
            this.noteSink = function (message) {
                try {
                    var ms = Math.round(
                        SystemRef.DateTime.UtcNow.Subtract(started).TotalMilliseconds);
                    SystemRef.IO.File.AppendAllText(path, ms + "ms " + message + "\r\n");
                } catch (_) {}
            };
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
         * preload, macOS at didCommitNavigation:, WebView2 at the turn of its
         * loop where the navigation sink says the document arrived. A message
         * arriving with nothing remembered is therefore not an app that has not
         * got going yet; it is a view that never committed the document this
         * file loaded.
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
         * Whether there is a document to judge a title against yet, asked
         * separately from judging one.
         *
         * The two lanes that read the title on a clock have to know the
         * difference before they record what they read. Both keep a last-seen
         * title so that a poll becomes an edge, and a poll that latches a value
         * the gate then refuses for "nothing has committed" would swallow that
         * title for the rest of the run -- the next read is equal to the last
         * one and never fires again. So they ask this first and read nothing
         * until it is true.
         */
        hasCommittedDocument: function () {
            return this.trustedView !== null;
        },

        /*
         * The transport's marker, as a value rather than as a literal.
         *
         * It is written five times in this file and only two of those can read
         * it from here: the WebView2 loop, which decides whether a document
         * title is a record or a name, and the gate below, which has to refuse
         * exactly what that loop accepts. The other three are page-side or
         * QML-side source being built as a string, where a literal is what
         * there is.
         *
         * So this is not "the marker in one place". It is the pair that has to
         * agree about it not having two spellings between them, which is the
         * disagreement that would matter: a record delivered as a window title.
         */
        recordPrefix: "__NEUTRINO__",

        /*
         * What a document is allowed to do to the name of the window it is in.
         *
         * `document.title` is the standard spelling of the verb this file used
         * to expose as `neutrino.window.setTitle`, and every one of the four
         * engines raises a signal when it changes -- `notify::title`,
         * `onTitleChanged`, `WKWebView.title`, `DocumentTitleChanged`.
         * Measured, all four: the DOM takes the value and the native window
         * never sees it, so connecting those signals is the whole change. What
         * each lane connects differs; what any of them may pass through does
         * not, which is why the rule is here and not written five times.
         *
         * It is a gate rather than a passthrough for four reasons, and each of
         * them is a reading rather than a precaution.
         *
         * The view has to be the one this launcher handed a document to. The
         * old spelling arrived over the IPC surface, which every driver
         * sender-checks; a title arrives from whatever the engine currently has
         * loaded, and on lanes whose preload the engine reinjects, a page that
         * got navigated to inherits the API and the document alike. The window
         * title is also the channel every verifier in this tree reads, so a
         * foreign document writing it is a foreign document filing this run's
         * report. A view that has committed nothing is a third case and is
         * neither: it is answered below, before the refusal, because two of
         * the five lanes ask this question on a clock that starts first.
         *
         * A record is never a title. Where the title *is* the transport --
         * WebView2 with no `postMessage` wired -- a record and a title share
         * one property, and the marker is what tells them apart. Refusing the
         * marker on every lane rather than only on that one keeps
         * `test/neutrinoattack.js`'s planted record reading the same
         * everywhere, and costs an app nothing it would ever want.
         *
         * An empty title is not a title. A document that never named itself
         * reports one on some engines and nothing on others, and a window whose
         * name disappears because its author wrote no `<title>` is worse than
         * the name the build gave it. `boot` puts the build's title into the
         * document for the same reason, so this is the second of two answers to
         * the same question and the one that does not need the markup to
         * cooperate.
         *
         * Neither is the document's own url, and that rule needed two spellings
         * rather than one. WebView2 documents `DocumentTitle` as falling back
         * to the URI of the document. QtWebEngine was then measured reporting
         * `about:blank` as the view's title the moment the page set
         * `document.title` to the empty string -- on a view whose own url is
         * the `data:` document Qt navigated to, so comparing the title against
         * what the view says it is showing let it straight through and the
         * window took `about:blank` for a name. Both are refused: the identity
         * the view reports, and the placeholder every driver here loads its
         * content into.
         *
         * The bounds are the ones `parseMessage` already put on a title, for
         * the same reason it had them: this ends up in a window title that
         * shell and PowerShell verifiers read line by line, and a control
         * character in it breaks the reader rather than the window.
         */
        acceptDocumentTitle: function (showing, title) {
            /*
             * Nothing committed yet is silence and not a refusal. Two lanes
             * read the title on a clock -- macOS off the view, WebView2 off
             * CoreWebView2 -- and both of those clocks start before the
             * document arrives, so every launch would otherwise open with a
             * note saying the app was refused its own window.
             */
            if (this.trustedView === null) {
                return null;
            }
            if (!this.isTrustedView(showing)) {
                this.noteOnce("refused a window title from a document the view " +
                    "was not given");
                return null;
            }
            var text = String(title == null ? "" : title);
            if (text === "") {
                return null;
            }
            if (text.indexOf(this.recordPrefix) === 0) {
                return null;
            }
            if (text === "about:blank" || text === this.viewIdentity(showing)) {
                return null;
            }
            if (text.length > 1024 || this.hasControlCharacters(text)) {
                this.noteOnce("refused a window title this launcher cannot carry");
                return null;
            }
            return text;
        },

        /*
         * The build's title, put where a browser would look for it.
         *
         * Every engine here reports the loaded document's title, and an app
         * whose markup names nothing therefore reports nothing -- which would
         * make the first title-changed signal of every launch an instruction to
         * blank the window's name. Naming the document is what stops that being
         * a special case: the first signal now carries the title the window was
         * already created with, so it changes nothing, and every signal after
         * it is the app's own.
         *
         * It also makes the read side true. An app that assigns
         * `document.title` expects to be able to read it back, and before this
         * the answer was the empty string until the app itself wrote one.
         *
         * A document that named itself keeps its name, and the window takes it:
         * that is what `<title>` means everywhere else, and an author who wrote
         * one meant it more recently than whoever passed `--title`.
         *
         * Escaped for markup rather than trusted. `build.sh` refuses a title
         * carrying a quote, a backslash or a control character, because it is
         * stamped into a JavaScript string literal -- `<` and `&` were never
         * its problem and are this one's.
         */
        /*
         * The palette as a stylesheet, or null where there is no palette to
         * write. `:root` because these have to inherit into everything the app
         * draws, and one declaration per key in the fixed order above.
         *
         * Nothing here can escape the element it lands in: every value matched
         * the anchored hex check in themeColorList and every property name is a
         * substring of a constant in this file. There is no path from a
         * toolkit's answer to markup.
         */
        themeCssText: function (theme) {
            var values = this.themeColorList(theme);
            if (!values) {
                return null;
            }
            var names = String(this.systemColorNames).split(",");
            var parts = [];
            for (var i = 0; i < names.length; i++) {
                parts[parts.length] = "--neutrino-" + names[i] + ":" + values[i];
            }
            return ":root{" + parts.join(";") + "}";
        },

        /*
         * The launch palette, delivered as markup rather than as a script that
         * runs at document start.
         *
         * The measured mechanism for an *update* is
         * `documentElement.style.setProperty`, which works and reads back on
         * all four engines, and that is what `_theme` uses. The launch is a
         * different question and it is the one the flash exists in: the values
         * have to be there before the first paint, and a document-start script
         * has an element to set them on only if the parser has produced one.
         * `document.title` taught this file that lesson at the cost of a round
         * -- on WebView2 the page script's first statement runs at `loading`,
         * with no `<head>` yet -- and a stylesheet in the markup has no such
         * moment. It is parsed with the document that carries it.
         *
         * Permitted under both tiers, by the policy this file writes: the
         * default tier restricts no styles at all, and the offline tier's
         * carries `style-src 'unsafe-inline'`, which is what an inline
         * `<style>` needs and what an external one is denied.
         *
         * Placed immediately before the document's own `<style>`, and both
         * halves of that are load-bearing.
         *
         * *Before* the author's stylesheet, because an author who writes
         * `:root{--neutrino-Canvas:#123}` means it, and two `:root` rules of
         * equal specificity are decided by which comes last. Overriding the
         * desktop is the app's to do and this must not be the thing that stops
         * it.
         *
         * *After* the head's meta elements, because one of them is the content
         * policy, and a policy governs what follows it in the document rather
         * than what precedes it. Injecting at the top of the head would put the
         * launcher's own stylesheet outside the policy the launcher wrote,
         * which is a small hole and an embarrassing one.
         *
         * A document with no `<style>` of its own gets the rule at the end of
         * the head, which is the same anchor titledDocument uses. That loses
         * the author-wins property and keeps the policy one; a document with no
         * stylesheet has no author declarations to lose to.
         *
         * A lane that read no palette gets no rule, which is the whole point of
         * naming the properties after the keywords: `var(--neutrino-Canvas,
         * Canvas)` then falls through to the engine's own system colour.
         */
        themedDocument: function (html, theme) {
            var text = String(html);
            var css = this.themeCssText(theme);
            if (!css) {
                return text;
            }
            var head = text.indexOf("</head>");
            if (head < 0) {
                this.noteOnce("this document has no <head>, so the palette is " +
                    "on window.neutrino.theme and not in its stylesheet");
                return text;
            }
            var at = text.substring(0, head).indexOf("<style");
            if (at < 0) {
                at = head;
            }
            return text.substring(0, at) + "<style>" + css + "</style>" +
                text.substring(at);
        },

        titledDocument: function (html, title) {
            var text = String(html);
            var name = String(title == null ? "" : title);
            if (name === "" || /<title[\s>]/i.test(text)) {
                return text;
            }
            var head = text.indexOf("</head>");
            if (head < 0) {
                this.noteOnce("this document has no <head>, so the window keeps " +
                    "its own name whatever the page calls itself");
                return text;
            }
            var escaped = name.replace(/&/g, "&amp;")
                .replace(/</g, "&lt;")
                .replace(/>/g, "&gt;");
            return text.substring(0, head) + "<title>" + escaped + "</title>" +
                text.substring(head);
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

            /*
             * The two relative verbs, and both carry signed deltas rather than
             * sizes -- so they are checked with isCoordinate and never with
             * isDimension, which refuses everything at or below zero. A resize
             * of -40 is a legitimate request and the clamp that keeps the
             * result positive belongs where the current size is known, which is
             * the host and not here.
             *
             * They exist because neither could be computed in the page.
             * `screenX` is truthful on one engine of four, so `moveBy` had no
             * arithmetic available to it. `resizeBy` looked like it did --
             * innerWidth matched the native content size everywhere -- but
             * `resizeTo` means the content area on three lanes and the frame on
             * macOS, so a page-side sum would compound that difference. Asking
             * the driver for bounds in its own units is right on either side of
             * the PR that settles it.
             */
            if (action === "resizeBy" || action === "moveBy") {
                if (rest === null) {
                    return null;
                }
                var deltas = rest.split(sep);
                if (deltas.length !== 2) {
                    return null;
                }
                if (!this.isCoordinate(deltas[0]) || !this.isCoordinate(deltas[1])) {
                    return null;
                }
                if (action === "resizeBy") {
                    return {
                        action: "resizeBy",
                        width: parseInt(deltas[0], 10),
                        height: parseInt(deltas[1], 10)
                    };
                }
                return { action: "moveBy", x: parseInt(deltas[0], 10), y: parseInt(deltas[1], 10) };
            }

            return null;
        },

        buildPreloadScript: function (transport, name, themeLiteral) {
            return '(function(){' +
                'var S=String.fromCharCode(31);' +
                'var _send=function(m){try{(' + transport + ')(m);}catch(_){}};' +
                'var _n=function(v){return String(v===undefined||v===null?"":v);};' +
                /*
                 * The update half of the palette's CSS delivery. The launch
                 * half is a stylesheet in the document -- see themedDocument,
                 * which says why a document-start script is the wrong mechanism
                 * for a value that has to be there before the first paint.
                 *
                 * This is the mechanism that was measured: setProperty on
                 * documentElement works and reads back on all four engines. By
                 * the time it runs there is certainly a document, because
                 * `_theme` is only ever reached through a driver's evaluate,
                 * and every one of those is gated on the commit.
                 *
                 * Both lists are written from this file's own two constants, in
                 * one order, so the mapping from a neutrino key to a CSS
                 * keyword exists once. Neither needs escaping: one is a list of
                 * identifiers and the other a list of CSS keywords, and both
                 * are constants here rather than anything a toolkit answered.
                 */
                'var _K=["' + this.themeKeyList().join('","') + '"];' +
                'var _P=["' + String(this.systemColorNames).split(",").join('","') + '"];' +
                'var _css=function(t){' +
                'var e=document.documentElement;' +
                'if(!e||!t||!t.colors){return;}' +
                'for(var i=0;i<_K.length;i++){' +
                'try{e.style.setProperty("--neutrino-"+_P[i],t.colors[_K[i]]);}catch(_){}' +
                '}' +
                '};' +
                'window.neutrino={' +
                // Which channel the host is actually listening on. The page can
                // work this out by feature detection anyway, so naming it costs
                // nothing and lets a test report it instead of inferring it.
                'transport:"' + String(name || "unknown") + '",' +
                /*
                 * The desktop's palette, in the preload rather than pushed
                 * after it. An app that has to wait for an event to learn the
                 * colours it launched into would paint once in the wrong ones
                 * first, which is the flash this whole thing exists to close,
                 * arrived at from the other side.
                 *
                 * `null` on a lane whose toolkit could not be read. Said out
                 * loud rather than filled in with white, so an app finds out by
                 * asking instead of by styling itself from a palette nobody's
                 * desktop is using.
                 */
                'theme:' + (themeLiteral || "null") + ',' +
                /*
                 * Where an update lands. Replaced and not mutated: an app that
                 * captured the object keeps a stable snapshot of the palette it
                 * had, and one that reads window.neutrino.theme gets the
                 * current one. The property is current before the event fires,
                 * so a handler may read either.
                 *
                 * Nothing else in this file evaluates into a page, and nothing
                 * reaches here that themeLiteral did not build.
                 */
                '_theme:function(t){' +
                'window.neutrino.theme=t;' +
                '_css(t);' +
                'try{window.dispatchEvent(new CustomEvent("neutrino:themechange",{detail:t}));}catch(_){}' +
                '},' +
                'send:function(action,data){' +
                'var d=data||{};' +
                'if(action==="resize")_send("resize"+S+_n(d.width)+S+_n(d.height));' +
                'else if(action==="resizeBy")_send("resizeBy"+S+_n(d.width)+S+_n(d.height));' +
                'else if(action==="move")_send("move"+S+_n(d.x)+S+_n(d.y));' +
                'else if(action==="moveBy")_send("moveBy"+S+_n(d.x)+S+_n(d.y));' +
                'else if(action==="openExternal")_send("openExternal"+S+_n(d.url));' +
                'else if(action==="close")_send("close");' +
                '},' +
                /*
                 * All that is left of the bespoke namespace, and it is waiting
                 * on step 6 rather than kept as an alias.
                 *
                 * Its standard spelling is window.open, which is now written
                 * over below. setTitle used to sit beside it; that spelling is
                 * an assignment to document.title and it reaches the native
                 * window on all five lanes, so there is nothing left here to
                 * alias it with either.
                 */
                'shell:{' +
                'openExternal:function(url){window.neutrino.send("openExternal",{url:url});}' +
                '}' +
                '};' +
                /*
                 * And the five that do have a spelling, written over the
                 * engine's own.
                 *
                 * Measured on WebKitGTK, QtWebEngine, WKWebView and WebView2:
                 * all five exist, all five are writable and configurable own
                 * properties of window, and all five do nothing. Four engines
                 * refuse to resize or move a window a script did not open, and
                 * report no error for it -- so an app calling the standard
                 * spelling today gets silence. What is being replaced is that
                 * silence, and nothing else: these emit the identical record
                 * the bespoke names emitted and meet the identical host-side
                 * guard, which is why this is a spelling change and not a
                 * policy one.
                 *
                 * Plain assignment rather than defineProperty, because the
                 * descriptor was read on all four and all four said writable.
                 * Each in its own try: a lane that ever refuses one should lose
                 * that verb and not the four beside it.
                 *
                 * close() returns nothing and does not set window.closed. The
                 * engines disagree about that flag already -- three set it true
                 * while the window stays up, WebView2 leaves it false -- so
                 * there is no value here that would be true everywhere, and
                 * inventing one is the thing this file refuses to do.
                 */
                'var _def=function(n,f){try{window[n]=f;}catch(_){}};' +
                '_def("resizeTo",function(w,h){window.neutrino.send("resize",{width:w,height:h});});' +
                '_def("resizeBy",function(w,h){window.neutrino.send("resizeBy",{width:w,height:h});});' +
                '_def("moveTo",function(x,y){window.neutrino.send("move",{x:x,y:y});});' +
                '_def("moveBy",function(x,y){window.neutrino.send("moveBy",{x:x,y:y});});' +
                '_def("close",function(){window.neutrino.send("close");});' +
                /*
                 * And the sixth, which is not like the other five: they were
                 * silent everywhere and this one is silent in one direction and
                 * working in the other.
                 *
                 * Measured on WebKitGTK, one launch per row, with the driver's
                 * own refusal note read off stderr beside the call's return:
                 *
                 *   open(u)            null    no policy decision reached
                 *   open(u,"_blank")   null    no policy decision reached
                 *   open(u,"name")     null    no policy decision reached
                 *   open(u,"_self")    object  refused and forwarded
                 *   <a target=_blank>  --      refused and forwarded
                 *
                 * Two paths inside the engine and this file was on one of them.
                 * A link with a target raises `decide-policy` with
                 * NEW_WINDOW_ACTION, which both GTK drivers already forward.
                 * `window.open` raises the `create` signal instead, nothing is
                 * connected to it, and the call returns null having reached no
                 * guard here at all -- so the one spelling an app author would
                 * reach for was the one spelling that did nothing.
                 *
                 * **What is routed is the url, not the target**, and that is
                 * the whole of what this round claims. A url bound for the
                 * machine's browser goes there; everything else is handed to
                 * the engine exactly as it arrived.
                 *
                 * The alternative was to key on the target -- `_blank` and any
                 * name to the browser, `_self` and its two siblings to the
                 * engine -- and it is wrong in the direction that costs the
                 * most later. `window.open("panel.html")` is an app asking for
                 * a second window of its own, and the only thing that can hand
                 * a page a real WindowProxy is the engine actually creating the
                 * view: WebKitGTK's `create`, Qt's newViewRequested, WebView2's
                 * NewWindowRequested, WKWebView's
                 * createWebViewWithConfiguration:. An override that answered
                 * every target would mean those signals are never raised at
                 * all, and the second window becomes unreachable from inside
                 * this file rather than merely unbuilt. So the default is the
                 * engine's, and this steps in front of one case only.
                 *
                 * Nothing is opened for a call with no url. The web platform's
                 * answer there is about:blank in a new window, which is the
                 * second-window case and not this one; sending it as a record
                 * would be `openExternal("")` for the host to refuse, which is
                 * a no-op with a wire message in front of it. It is a no-op
                 * without one until there is a window to open.
                 *
                 * The three targets that mean *this* window are still checked,
                 * and before the url, because they are not an opening at all.
                 * `_self` returns the window and navigates, and that navigation
                 * meets the guard every location change meets -- which already
                 * forwards an external url to the browser. Routing it here as
                 * well would take a measured path away and give back a
                 * different one. The match is case-insensitive: the target is a
                 * keyword, and `_SELF` reaching the machine's browser is the
                 * opposite of what it asked for.
                 *
                 * The scheme test here is a *routing* question and not a
                 * security one, which is why it is allowed to be this small.
                 * isExternalUrl still decides what may leave -- length, control
                 * characters, the shape of the host -- and mayOpenExternal
                 * still decides whether this build may let anything leave at
                 * all. Both run on the host, on the record this sends. What
                 * this picks is only which of two paths the call takes; a url
                 * that gets the wrong one is refused at the other end either
                 * way.
                 *
                 * null is returned rather than a window-shaped object. Three of
                 * four engines already answer null here and QtWebEngine answers
                 * an object; nothing this file can hand back is a window in this
                 * page's process, because the url went to the machine's browser.
                 * A truthful null beats a proxy that would answer questions
                 * about a window that does not exist.
                 *
                 * The record is the one openExternal has always emitted, so an
                 * offline build refuses this exactly as it refuses the bespoke
                 * spelling. A spelling change, not a policy change.
                 */
                'var _open=window.open;' +
                'var _eng=function(u,t){try{return _open.call(window,u,t);}catch(_){return null;}};' +
                '_def("open",function(url,target){' +
                'var u=(url==null)?"":String(url);' +
                'if(u===""){return null;}' +
                'var t=String(target==null?"":target).toLowerCase();' +
                'if(t==="_self"||t==="_parent"||t==="_top"){return _eng(url,target);}' +
                'if(!/^(https?|mailto):/i.test(u)){return _eng(url,target);}' +
                'window.neutrino.send("openExternal",{url:u});' +
                'return null;' +
                '});' +
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
            var text = String(html);
            var wanted = 'content="' + this.defaultContentPolicy + '"';
            // A string replace has no failure path, and this one is the whole
            // of the offline tier: a document that does not carry the policy
            // being replaced used to come back unchanged, shipping the default
            // policy under a build that says it denies the network. The tier is
            // stamped into this file and cannot be got wrong from outside it,
            // so a build asking for it and a document that cannot take it is a
            // launcher that has no business coming up.
            if (text.indexOf(wanted) < 0) {
                throw new Error("neutrino: this build is offline and its document " +
                    "does not carry the policy the tier replaces");
            }
            return text.replace(wanted, 'content="' + this.offlineContentPolicy + '"');
        },

        boot: function (driver, config) {
            driver.init();

            /*
             * Before the window, because the window is painted from it and
             * there is exactly one chance to get that right -- a window
             * repainted after it is on screen is the flash, in a different
             * colour.
             *
             * A lane with no reader, or a reader that could not reach its
             * toolkit, leaves this null. That is a build that paints white and
             * hands the page `neutrino.theme === null`, which is what this file
             * did before any of this existed: no worse than it was, and the
             * page can tell.
             */
            if (driver.readTheme) {
                this.theme = this.normalizeTheme(driver.readTheme());
                if (!this.theme) {
                    this.note("could not read the desktop palette; using " +
                        this.resolveBackground(null));
                }
            }

            /*
             * And here for the same reason the read is here: before the window,
             * because `prefers-color-scheme` is a value the page's first paint
             * is already styled by. A media query corrected after the document
             * has laid out is the flash again, in the other direction -- the
             * app's dark stylesheet arriving over a light one it already drew.
             *
             * Ungated by followsTheme, unlike the repaint below it. That gate
             * asks whether this build named its own background, and a build
             * that did still gets `neutrino.theme.scheme` and still gets the
             * palette pushed to the page. The scheme the desktop is at is the
             * same reading however this window is painted.
             */
            if (driver.forceScheme) {
                try {
                    driver.forceScheme(this.theme);
                } catch (e) {
                    this.note("could not force the colour scheme: " + e);
                }
            }

            var scriptPath = driver.getScriptPath();
            var source = driver.readFile(scriptPath);
            var html = this.themedDocument(
                this.titledDocument(
                    this.applyContentPolicy(this.extractHtmlDocument(source)),
                    config.title),
                this.theme);
            var pageScript = this.extractPageScript(source);

            var win = driver.createWindow(config);

            if (driver.onWebMessage) {
                var self = this;
                var driverRef = driver;
                var winRef = win;
                var actions = {};
                if (driverRef.resize) actions.resize = function (m) { try { driverRef.resize(winRef, m.width, m.height); } catch (_) {} };
                if (driverRef.move) actions.move = function (m) { try { driverRef.move(winRef, m.x, m.y); } catch (_) {} };
                /*
                 * The relative pair, resolved here rather than in five drivers.
                 * One arithmetic and one clamp, against a reading each driver
                 * supplies in whatever units its own resize and move already
                 * speak -- which is what lets this be right on macOS both
                 * before and after the PR that switches that lane from sizing
                 * its frame to sizing its content.
                 *
                 * The clamp is here and not in the splitter because the
                 * splitter sees a delta and cannot know what it is a delta
                 * from. A width of zero is a refused window on some toolkits
                 * and a crash on others, so the floor is one pixel.
                 */
                if (driverRef.getBounds && driverRef.resize) actions.resizeBy = function (m) {
                    try {
                        var b = driverRef.getBounds(winRef);
                        if (!b) { return; }
                        var w = b.width + m.width;
                        var h = b.height + m.height;
                        driverRef.resize(winRef, w < 1 ? 1 : w, h < 1 ? 1 : h);
                    } catch (_) {}
                };
                if (driverRef.getBounds && driverRef.move) actions.moveBy = function (m) {
                    try {
                        var p = driverRef.getBounds(winRef);
                        if (!p) { return; }
                        driverRef.move(winRef, p.x + m.x, p.y + m.y);
                    } catch (_) {}
                };
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
                    driver.webMessageTransport, driver.transportName,
                    this.themeLiteral(this.theme)));
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
            /*
             * An interpreter with imports.gi is not an interpreter that can
             * reach GTK and WebKit2: the typelibs are separate packages, and a
             * GNOME box without gir1.2-webkit2 has the first and not the
             * second. That used to be a traceback and the end of the launch,
             * with the shell's `elif` chain already committed -- so a machine
             * with a working qml6 sitting next to a broken gjs got no window at
             * all. One line and the reserved status instead, and the walk
             * carries on to the engine that does work.
             *
             * Anything not tagged is the app's own failure and keeps its
             * traceback, because that is a program to debug and not a lane to
             * skip.
             */
            try {
                this.boot(this.createGjsDriver(), this.config);
            } catch (e) {
                if (!e || !e.neutrinoEngineUnavailable) {
                    throw e;
                }
                this.note("this interpreter cannot reach GTK and WebKit2: " +
                    (e.message ? e.message : e));
                eval("imports")["system"]["exit"](69);
            }
        },

        hasWebView2Assemblies: function (SystemRef, libDir) {
            if (!libDir) {
                return false;
            }
            return SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.Core.dll")) &&
                SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.WinForms.dll"));
        },

        windowsLayoutCache: null,

        /*
         * Where this program is, and therefore where everything else is. One
         * rule, answered once, because the document's path and the app folder
         * used to be decided by two different mechanisms that only agreed by
         * accident: the document came from an environment variable the launcher
         * set, and the app folder from Application.StartupPath. Moving the exe
         * out of the app folder broke the second and would have left the first
         * pointing somewhere the exe no longer lives.
         *
         * The batch region compiles to <dir>\<name>.exe beside the script and
         * keeps it, and falls back to <dir>\<name>\<name>.exe when the script's
         * own directory will not take a file. Both layouts name the same app
         * folder, <dir>\<name>, and in both the script is <name>.cmd -- beside
         * the exe in the first, one level above it in the second. So the exe
         * looks beside itself first and above itself second, and what it finds
         * decides which of the two it is in.
         *
         * Two extensions, because %~n0 has already dropped the real one by the
         * time the batch region names anything: netinstall always writes .cmd,
         * cmd.exe will run a .bat as readily, and it will run nothing else.
         */
        windowsLayout: function (SystemRef) {
            if (this.windowsLayoutCache) {
                return this.windowsLayoutCache;
            }
            var exe = SystemRef.Windows.Forms.Application.ExecutablePath;
            var name = SystemRef.IO.Path.GetFileNameWithoutExtension(exe);
            var exeDir = SystemRef.IO.Path.GetDirectoryName(exe);
            if (exeDir == null || String(exeDir) === "" ||
                    name == null || String(name) === "") {
                throw new Error("neutrino: this program is not where a neutrino " +
                    "launcher puts it (" + String(exe) + ")");
            }

            var beside = this.windowsScriptIn(SystemRef, exeDir, name);
            if (beside != null) {
                this.windowsLayoutCache = {
                    script: beside,
                    appFolder: SystemRef.IO.Path.Combine(exeDir, name)
                };
                return this.windowsLayoutCache;
            }

            // GetDirectoryName answers null at a volume root, and Path.Combine
            // throws on a null rather than returning one.
            var parent = SystemRef.IO.Path.GetDirectoryName(exeDir);
            if (parent != null && String(parent) !== "") {
                var above = this.windowsScriptIn(SystemRef, parent, name);
                if (above != null) {
                    this.windowsLayoutCache = { script: above, appFolder: exeDir };
                    return this.windowsLayoutCache;
                }
            }

            throw new Error("neutrino: could not find the document this program " +
                "was compiled from; looked for " + name + ".cmd and " + name +
                ".bat beside it in " + exeDir + " and one level above");
        },

        windowsScriptIn: function (SystemRef, dir, name) {
            var asCmd = SystemRef.IO.Path.Combine(dir, name + ".cmd");
            if (SystemRef.IO.File.Exists(asCmd)) {
                return asCmd;
            }
            var asBat = SystemRef.IO.Path.Combine(dir, name + ".bat");
            if (SystemRef.IO.File.Exists(asBat)) {
                return asBat;
            }
            return null;
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

        /*
         * In process, and that is the whole of the fix. This used to build a
         * PowerShell command, base64 it, and hand `powershell.exe` to
         * ProcessStartInfo with UseShellExecute false -- so .NET gave
         * CreateProcess a null lpApplicationName and the name went through the
         * CreateProcess search order, whose first two entries are the directory
         * the calling exe was loaded from and the current directory. Both of
         * those are the app folder: the exe lives there, and the batch region
         * STARTs it with /D "%APP_FOLDER%". Measured on a runner, both entries
         * independently: a program named powershell.exe planted beside the exe
         * ran, one planted in the current directory ran, and the real one runs
         * only when neither is there.
         *
         * That folder is one everything running as this user can write -- the
         * sentence test/appcache.ps1 already carries -- and under netinstall
         * that includes the confined app. So this is PR 3's finding in Windows
         * spelling: write xor execute stops an app running what it wrote, and
         * does not stop it asking someone else to run it.
         *
         * An absolute path under Environment.SystemDirectory, with a working
         * directory beside it, was measured to refuse both plants and is not
         * what shipped. The command being sent was two calls out of
         * System.IO.Compression, so the answer available here is to name no
         * program at all, which is also the one that cannot be got wrong again
         * by a later edit. The assemblies come from the batch region's jsc
         * line; every call below is late-bound, so dropping them builds and
         * fails at run time -- see the comment there.
         *
         * The member names are literals from webView2Members, which is what
         * keeps Path.Combine from being handed an archive-supplied string. That
         * was PR 8's decision and it is unchanged: this iterates the pinned
         * list and asks the archive for each name.
         */
        extractWebView2Members: function (SystemRef, archivePath, destinationPath) {
            var archive = null;
            try {
                archive = SystemRef.IO.Compression.ZipFile.OpenRead(String(archivePath));
                for (var i = 0; i < this.webView2Members.length; i++) {
                    var name = this.webView2Members[i].path;
                    var entry = archive.GetEntry(name);
                    if (entry == null) {
                        throw new Error("WebView2 package is missing " + name + ".");
                    }
                    var out = SystemRef.IO.Path.Combine(
                        String(destinationPath),
                        name.replace(/\//g, "\\")
                    );
                    var dir = SystemRef.IO.Path.GetDirectoryName(out);
                    if (!SystemRef.IO.Directory.Exists(dir)) {
                        SystemRef.IO.Directory.CreateDirectory(dir);
                    }
                    SystemRef.IO.Compression.ZipFileExtensions.ExtractToFile(entry, out, true);
                }
            } finally {
                if (archive) {
                    archive.Dispose();
                }
            }
        },

        /*
         * A recursive Directory.Delete and a directory junction: measured, and
         * not what it was expected to be. The framework does not walk through
         * the junction -- the target directory and its file were untouched --
         * it unlinks it, deletes everything else, and then throws
         * System.IO.IOException "The parameter is incorrect." having left the
         * directory itself behind, empty. So there is no delete of somewhere
         * else here, and this is not a boundary fix.
         *
         * What it is: that call sits inside the download's try, so a junction
         * planted anywhere under the package directory turns the next launch
         * into "Download/extract failed" for a reason nobody can act on, and
         * the launch after that succeeds because the directory is now empty.
         * A failure that repairs itself is a failure nothing ever reports,
         * which is why four PRs of CI never saw it.
         *
         * The walk below does what the framework was already doing about
         * reparse points and does not depend on the half that threw. 1024 is
         * FILE_ATTRIBUTE_REPARSE_POINT.
         *
         * test/winexec.ps1 asserts that no call in this file passes a recursive
         * flag, by reading the file -- so this paragraph deliberately does not
         * spell the call it is about. That is the third kind of hazard this
         * polyglot has where prose is structure, after PR 19's two sequences
         * and PR 24's sentinel; as there, the check is what catches it, on the
         * first run after somebody writes it.
         */
        deleteTree: function (SystemRef, dir) {
            var files = SystemRef.IO.Directory.GetFiles(dir);
            for (var i = 0; i < files.Length; i++) {
                SystemRef.IO.File.Delete(files[i]);
            }
            var subs = SystemRef.IO.Directory.GetDirectories(dir);
            for (var j = 0; j < subs.Length; j++) {
                var attrs = SystemRef.Convert.ToInt32(SystemRef.IO.File.GetAttributes(subs[j]));
                if ((attrs & 1024) !== 0) {
                    SystemRef.IO.Directory.Delete(subs[j], false);
                } else {
                    this.deleteTree(SystemRef, subs[j]);
                }
            }
            SystemRef.IO.Directory.Delete(dir, false);
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
        /*
         * Where to write a failure down when the failure may be that there is
         * no layout. windowsLayout throws when the document cannot be found,
         * and that is the one refusal most worth recording -- so this does not
         * get to depend on it. Both layouts put the app folder either beside
         * this program or at it, and an existing <exe dir>\<name> tells them
         * apart without asking where the document is.
         */
        windowsErrorFolder: function (SystemRef) {
            try {
                return this.windowsLayout(SystemRef).appFolder;
            } catch (_) {
            }
            var exe = SystemRef.Windows.Forms.Application.ExecutablePath;
            var exeDir = SystemRef.IO.Path.GetDirectoryName(exe);
            var name = SystemRef.IO.Path.GetFileNameWithoutExtension(exe);
            var beside = SystemRef.IO.Path.Combine(exeDir, name);
            if (SystemRef.IO.Directory.Exists(beside)) {
                return beside;
            }
            return exeDir;
        },

        recordWindowsError: function (SystemRef, title, message) {
            var written = "";
            try {
                var path = SystemRef.IO.Path.Combine(
                    this.windowsErrorFolder(SystemRef),
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
                    this.deleteTree(SystemRef, packageRoot);
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

                this.extractWebView2Members(SystemRef, tempPackagePath, packageRoot);
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
        drainNavRefusals: function (driver) {
            while (NeutrinoNavSink.refusals.Count > 0) {
                var text = String(NeutrinoNavSink.refusals[0]);
                NeutrinoNavSink.refusals.RemoveAt(0);
                this.note(text);
            }
            // The guard's other half, and the tier check is here rather than in
            // the handler because this is the side of the file that can ask.
            // driver.openExternal asks again at the end of the line, which is
            // the same belt-and-braces every other lane has: one check where
            // the decision is made and one where the string becomes
            // ShellExecute.
            while (NeutrinoNavSink.externals.Count > 0) {
                var url = String(NeutrinoNavSink.externals[0]);
                NeutrinoNavSink.externals.RemoveAt(0);
                if (driver && driver.openExternal && this.mayOpenExternal(url)) {
                    try {
                        driver.openExternal(url);
                    } catch (e) {
                        this.noteOnce("could not open the refused window's url: " + e);
                    }
                }
            }
        },

        // The event args carry both the text and who sent it. Source is the url
        // of the document that called postMessage, and the document this file
        // loads through NavigateToString has none worth the name -- so a
        // message from anywhere else is from a page that was navigated to.
        /*
         * What the view says it is showing, off the view and not off an event.
         *
         * Two things in the WebView2 loop need it and they used to be one, so
         * it lived inline: the turn that remembers the committed document, and
         * every title change judged against it. They have to be the same
         * reading -- remembering one and comparing another is a guard that
         * cannot pass -- and a function is how that stops being a thing to
         * remember. `null` is "the view would not say", which is refused rather
         * than trusted everywhere it reaches.
         */
        readWebView2Source: function (coreWv2, sourceProp) {
            if (!sourceProp) {
                return null;
            }
            try {
                return String(sourceProp.GetValue(coreWv2, null) || "");
            } catch (_) {
                return null;
            }
        },

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
            var pendingDocument = null;
            var settingsApplied = false;
            var webMessagesWired = false;
            // Kept because evaluate needs it and the loop is the only place it
            // can be got: CoreWebView2 does not exist until the runtime has
            // finished starting, which is well after the window is on screen.
            var coreWebView2 = null;

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

                    // Not StartupPath. The exe is kept beside the script now
                    // rather than inside the app folder, so where this program
                    // sits and where it may write are two different places --
                    // windowsLayout is the one rule that answers both.
                    appFolder = self.windowsLayout(SystemRef).appFolder;
                    if (!SystemRef.IO.Directory.Exists(appFolder)) {
                        SystemRef.IO.Directory.CreateDirectory(appFolder);
                    }
                    userDataDir = SystemRef.IO.Path.Combine(appFolder, "data");

                    // Before the package, because the package phase is one of
                    // the two halves a stalled launch has to be split into.
                    if (self.hasTier("testing")) {
                        self.installWindowsTrace(SystemRef, appFolder);
                    }
                    self.trace("init: app folder " + appFolder);

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
                    self.trace("init: assemblies loaded from " + webView2LibDir);
                },
                readFile: function (path) {
                    return SystemRef.IO.File.ReadAllText(path);
                },
                /*
                 * Derived, not received. This used to take the document's path
                 * from NEUTRINO_SCRIPT_PATH -- an environment variable that
                 * ends at "which document does this process execute", which is
                 * the same shape findWebView2LibDir carries for its own
                 * variable and gets the same answer here. netinstall's
                 * allowlist keeps the whole NEUTRINO_ prefix, so it arrived
                 * intact there too; a release build no longer reads it, and the
                 * tests that need to point at another document build with the
                 * testing tier. The batch region has stopped setting it, so on
                 * both launch paths the name an attacker would set is one
                 * nothing reads.
                 *
                 * The derivation itself is windowsLayout, which the app folder
                 * is resolved from too -- see the comment there. It also makes
                 * the exe runnable on its own, which it was not.
                 */
                getScriptPath: function () {
                    // Named for what it is. `override` is a member modifier in
                    // JScript.NET, and this file has already been caught once
                    // by a name that means something to jsc and nothing to the
                    // other three -- see the quoted "close" below.
                    if (self.hasTier("testing")) {
                        var fromEnv = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH");
                        // Tested against null and "" rather than for truth.
                        // Every value here is a .NET String arriving through a
                        // late-bound call, and whether an empty one is falsy is
                        // a question the four engines do not have to answer the
                        // same way. Nothing below asks.
                        if (fromEnv != null && String(fromEnv) !== "") {
                            if (!SystemRef.IO.File.Exists(fromEnv)) {
                                throw new Error("neutrino: NEUTRINO_SCRIPT_PATH names no file: " + fromEnv);
                            }
                            return fromEnv;
                        }
                    }
                    return self.windowsLayout(SystemRef).script;
                },
                readTheme: function () {
                    return self.readWindowsTheme(SystemRef);
                },
                repaint: function (win, wv, background) {
                    var color = self.makeWindowsColor(SystemRef, background);
                    if (!color) {
                        return;
                    }
                    try {
                        win.BackColor = color;
                    } catch (e) {
                        self.note("could not repaint the window: " + e);
                    }
                    if (wv) {
                        self.paintWindowsView(wv, color);
                    }
                },
                evaluate: function (wv, js) {
                    // The gate every lane holds, spelled the way this one keeps
                    // it: `armed` is set from inside the engine at the commit of
                    // the document this file navigated to.
                    if (!coreWebView2 || !NeutrinoNavSink.armed) {
                        return;
                    }
                    var run = coreWebView2.GetType().GetMethod("ExecuteScriptAsync");
                    if (!run) {
                        return;
                    }
                    run.Invoke(coreWebView2, [js]);
                },
                createWindow: function (config) {
                    var win = new SystemRef.Windows.Forms.Form();
                    win.Text = config.title;
                    /*
                     * Before ClientSize and not after it. A Form recomputes one
                     * of the two sizes when its border style changes, and which
                     * one it keeps is not a promise worth relying on -- setting
                     * the frame first leaves ClientSize as the last word, which
                     * is the quantity this lane is asked for and the quantity
                     * every other lane sets.
                     */
                    if (self.undecorated()) {
                        win.FormBorderStyle = SystemRef.Windows.Forms.FormBorderStyle.None;
                    }
                    win.ClientSize = new SystemRef.Drawing.Size(config.width, config.height);
                    win.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;
                    var winColor = self.makeWindowsColor(SystemRef, self.resolveBackground(self.theme));
                    if (winColor) {
                        try { win.BackColor = winColor; } catch (e) { self.note("could not paint the window: " + e); }
                    }
                    return win;
                },
                createWebView: function () {
                    var wv = SystemRef.Activator.CreateInstance(webViewType);
                    self.paintWindowsView(wv,
                        self.makeWindowsColor(SystemRef, self.resolveBackground(self.theme)));
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
                    // Kept, not dropped. This driver used to throw the document
                    // boot had extracted and applied the content policy to on
                    // the floor, and read the file off NEUTRINO_SCRIPT_PATH a
                    // second time inside the event loop to make another one.
                    // Measured: the exe appears about 350 ms in and the second
                    // read lands between half a second and a second after that,
                    // so a file replaced inside the gap was the one that
                    // rendered -- content policy and all -- while the page
                    // script running in it came from the first read. The folder
                    // it sits in is one appcache.ps1 measured this account can
                    // write.
                    //
                    // about:blank still has to come first: CoreWebView2 does
                    // not exist yet and nothing can be handed a string until it
                    // does. What changes is where the string comes from then.
                    pendingDocument = html;
                    wv.Source = new SystemRef.Uri("about:blank");
                },
                setTitle: function (win, title) {
                    win.Text = title;
                    // The app's own clock on the one thing the verifier watches
                    // for. A title the suite never saw and a title never set
                    // are the same reading from outside and different ones
                    // here.
                    self.trace("title -> " + title);
                },
                resize: function (win, w, h) {
                    win.ClientSize = new SystemRef.Drawing.Size(parseInt(w), parseInt(h));
                },
                move: function (win, x, y) {
                    win.Location = new SystemRef.Drawing.Point(parseInt(x), parseInt(y));
                },
                // ClientSize and Location, matching the two above: this lane
                // sizes the content and positions the frame, and a relative
                // verb has to be relative to the same thing its absolute
                // sibling sets.
                getBounds: function (win) {
                    return {
                        width: SystemRef.Convert.ToInt32(win.ClientSize.Width),
                        height: SystemRef.Convert.ToInt32(win.ClientSize.Height),
                        x: SystemRef.Convert.ToInt32(win.Location.X),
                        y: SystemRef.Convert.ToInt32(win.Location.Y)
                    };
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
                    self.trace("loop: window shown");
                    var driver = this;
                    var coreWv2 = null;
                    var titleProp = null;
                    var sourceProp = null;
                    var preloadInjected = false;
                    var trustedRemembered = false;
                    // Heartbeat and first-exception state. The loop body below
                    // is one big try/catch that discards what it catches, so a
                    // build whose every iteration threw would spin in silence
                    // and look exactly like one waiting patiently.
                    var spins = 0;
                    var beats = 0;
                    var loopExNoted = false;
                    while (win.Visible) {
                        SystemRef.Windows.Forms.Application.DoEvents();
                        SystemRef.Threading.Thread.Sleep(16);
                        try {
                            if (!coreWv2 && wv) {
                                var coreWv2Prop = wv.GetType().GetProperty("CoreWebView2");
                                if (coreWv2Prop) {
                                    coreWv2 = coreWv2Prop.GetValue(wv, null);
                                    // Kept where evaluate can reach it. This
                                    // is the only place it can be got.
                                    coreWebView2 = coreWv2;
                                }
                            }
                            if (coreWv2 && !settingsApplied) {
                                settingsApplied = true;
                                self.trace("loop: CoreWebView2 available after " + spins + " turns");
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
                                    webMessagesWired ? "webmessage" : "title",
                                    // This lane builds its preload here rather
                                    // than in boot, so the palette has to be
                                    // put in here too. Left out, every Windows
                                    // app would read neutrino.theme as null
                                    // while the window it is sitting in was
                                    // painted from a palette that was read
                                    // perfectly well.
                                    self.themeLiteral(self.theme)
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
                                if (navMethod && pendingDocument) {
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
                                    self.trace("loop: navigating to the app document");
                                    navMethod.Invoke(coreWv2, [pendingDocument]);
                                } else {
                                    // The other half of the same finding, and
                                    // the quieter one. When the second read
                                    // found no file the condition above was
                                    // simply false: no navigation, the view
                                    // left on the about:blank it was created
                                    // with, and the page script never reached
                                    // an API to report through. Measured twice
                                    // as a window with no title, no error and
                                    // no log line at all. There is no read to
                                    // fail any more, and if this is ever
                                    // reached it says so.
                                    self.note("the view was given no document; the window will stay blank");
                                }
                            }
                            if (coreWv2) {
                                self.drainNavRefusals(driver);
                            }
                            /*
                             * The theme watcher, and on this lane it is a
                             * re-read rather than a subscription.
                             *
                             * This loop already spins at 16 ms doing reflection
                             * on every turn, so reading two SystemColors and
                             * one registry value once a second is nothing next
                             * to what it is already paying -- and it needs no
                             * delegate bound to an event whose handler type
                             * would be one more thing to discover at run time.
                             * applyTheme's diff is what makes a re-read safe to
                             * do on a clock: a palette that has not changed is
                             * not an update, so the page hears nothing until
                             * something actually happens.
                             *
                             * SystemEvents.UserPreferenceChanged is the real
                             * mechanism if this ever measures badly. It was not
                             * taken first because it is strictly more moving
                             * parts for an answer this loop can already reach.
                             */
                            if (spins % 60 === 0) {
                                self.applyTheme(driver, win, wv, driver.readTheme());
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
                            }
                            /*
                             * The document's title, read on the same clock and
                             * now read whatever the transport is.
                             *
                             * One property with two meanings, and the marker is
                             * what separates them. Where wireWebView2Messages
                             * returned false the title *is* the channel, so a
                             * marked value is a record and is handed to the
                             * callback. Everything else is a name the document
                             * chose, and this lane's half of the title hook is
                             * to put it on the Form -- which is why this read
                             * moved out of the branch it used to live in: with
                             * webmessages wired, which is every run on this
                             * lane that CI has ever recorded, it never ran.
                             *
                             * Who set it, asked the same way readWebView2Message
                             * asks. This used to ask nothing at all, which made
                             * this the one driver that never checked a sender --
                             * and wherever the title is the whole channel, a
                             * page navigated to could drive the native window by
                             * writing its own.
                             *
                             * Source is the reading that makes it checkable and
                             * it had to be measured: the view's Source stays
                             * about:blank across the driver's NavigateToString,
                             * and names the remote document once a navigation
                             * has arrived -- polled on this same clock, a
                             * foreign title and a foreign Source were seen in
                             * the same pair.
                             *
                             * A view that cannot say what it is showing is
                             * refused rather than trusted, which is the rule
                             * isTrustedView already settled.
                             */
                            if (coreWv2) {
                                if (!titleProp) {
                                    titleProp = coreWv2.GetType().GetProperty("DocumentTitle");
                                    sourceProp = coreWv2.GetType().GetProperty("Source");
                                }
                                /*
                                 * The fifth lane arming the way the other four
                                 * do, and remembering the reading it is going to
                                 * compare.
                                 *
                                 * NeutrinoNavSink.armed is this lane's commit --
                                 * the document this file navigated to has
                                 * arrived. What gets remembered is `Source`, and
                                 * that is the whole of the fix: the sink's
                                 * `ownDocument` is the `data:` url the
                                 * navigation event reported, while `Source`
                                 * stays `about:blank` for the life of the view.
                                 * Remembering the first and checking the second
                                 * is a guard that can never pass, and it shipped
                                 * once: every title on this lane was refused,
                                 * and since the title is the only report channel
                                 * here, every suite on the platform went dark at
                                 * the same moment.
                                 *
                                 * Remembered here rather than inside the sink,
                                 * which stays a .NET static with no reach into
                                 * this object -- the arrangement that makes it
                                 * unreachable from any document.
                                 */
                                if (!trustedRemembered && NeutrinoNavSink.armed) {
                                    var committed = self.readWebView2Source(coreWv2, sourceProp);
                                    if (committed !== null && committed !== "") {
                                        trustedRemembered = true;
                                        self.rememberTrustedView(committed);
                                    }
                                }
                                // Nothing is read until there is a document to
                                // judge it against. lastDocTitle is what turns
                                // this poll into an edge, so latching a title
                                // that would be refused for arriving too early
                                // would swallow it for the rest of the run.
                                //
                                // And that is true one gate further down as well.
                                // `trustedRemembered` is not the only thing that
                                // can refuse a title here: acceptDocumentTitle
                                // refuses any title while the view is not showing
                                // this launcher's own document, and the latch used
                                // to be taken before it was asked -- so a title
                                // refused once was recorded as seen and never
                                // offered again. Measured on the macOS poll, which
                                // had the identical shape and lost a probe state in
                                // two rounds out of four; this lane has not been
                                // seen to lose one, and is exposed the same way.
                                //
                                // A record is different and still latches where it
                                // is handled. It is consumed rather than judged --
                                // re-reading one would deliver the same message to
                                // the page's channel twice, which is worse than
                                // dropping it. Only the *name* branch waits for an
                                // acceptance before it latches.
                                if (titleProp && trustedRemembered) {
                                    var docTitle = String(titleProp.GetValue(coreWv2, null) || "");
                                    if (docTitle !== lastDocTitle) {
                                        var showing = self.readWebView2Source(coreWv2, sourceProp);
                                        if (docTitle.indexOf(self.recordPrefix) === 0) {
                                            lastDocTitle = docTitle;
                                            var mine = (showing !== null) && self.isOwnDocument(showing);
                                            if (!messageCallback || webMessagesWired) {
                                                // A record on a lane whose
                                                // channel is elsewhere. Nothing
                                                // is listening for it here and
                                                // it is not a name either, so it
                                                // goes no further in either
                                                // direction.
                                                self.trace("a record arrived in the title and the channel is " +
                                                    (webMessagesWired ? "webmessage" : "unwired"));
                                            } else if (mine) {
                                                try {
                                                    messageCallback(decodeURIComponent(
                                                        docTitle.substring(self.recordPrefix.length)));
                                                } catch (_) {}
                                            } else {
                                                self.note("refused a record in the title of " +
                                                    (showing === null ? "a view that did not say" : showing));
                                            }
                                        } else {
                                            var name = self.acceptDocumentTitle(
                                                showing === null ? "" : showing, docTitle);
                                            if (name !== null) {
                                                lastDocTitle = docTitle;
                                                driver.setTitle(win, name);
                                            }
                                        }
                                    }
                                }
                            }
                        } catch (loopEx) {
                            /*
                             * Still swallowed -- this loop has always been
                             * allowed to outlive a bad turn -- but no longer in
                             * silence. Once, and only under the testing tier.
                             *
                             * String() and not a typed catch: `catch (ex :
                             * Exception)` is the spelling that reaches the CLR
                             * exception (PR 25) and it is JScript.NET syntax,
                             * which the three engines that also parse this file
                             * would refuse. So this names that something threw
                             * and roughly what; the type may arrive wrapped.
                             */
                            if (!loopExNoted) {
                                loopExNoted = true;
                                // Guarded, like everything else on this path:
                                // an instrument that can end the loop it is
                                // watching is worse than no instrument.
                                try {
                                    self.trace("loop: raised " + String(loopEx));
                                } catch (_) {}
                            }
                        }
                        /*
                         * A heartbeat while the engine has not arrived. Sixteen
                         * milliseconds a turn, so this is about every five
                         * seconds, and it stops after forty -- long enough to
                         * cover a 240s wait, bounded so a wedged launch cannot
                         * write an unbounded file.
                         */
                        spins++;
                        if (!coreWv2 && beats < 40 && spins % 300 === 0) {
                            beats++;
                            try {
                                self.trace("loop: still no CoreWebView2 after " +
                                    spins + " turns");
                            } catch (_) {}
                        }
                    }
                },
                handleError: function (ex) {
                    var message = "";
                    try {
                        if (ex && ex.message) { message = String(ex.message); }
                    } catch (_) {}
                    /*
                     * The heading used to be "Failed to initialize WebView2
                     * package/download." whatever had gone wrong. That was true
                     * of the one failure that could reach here and it is not
                     * true of the ones that can now: a file this launcher
                     * cannot split, and a document the offline tier cannot make
                     * offline, both refuse before any download starts. An error
                     * this file raises says so in its own words and keeps them.
                     */
                    var detail;
                    if (message.indexOf("neutrino:") === 0) {
                        detail = message;
                    } else {
                        detail = "Failed to initialize WebView2 package/download.";
                        if (message) { detail = detail + "\n\n" + message; }
                    }
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

//</script></body></html>
