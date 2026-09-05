REM The first thing every launch used to do was spawn a cmd.exe to work out
REM what byte an escape is -- `FOR /F %%E IN ('ECHO PROMPT $E ^| CMD') DO SET
REM "ESC=%%E"`, and through a pipe, so two of them. Nothing ever read it. The
REM line below carries literal escape bytes instead and always has: the probe
REM was written for a %ESC% that no version of this file has ever contained,
REM measured over every commit it appears in. Two process starts an app launch,
REM ahead of everything else, for a variable with no reader.
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
REM and is not adopted. And a script directory that refuses the stamp -- under
REM netinstall this process is low integrity and the shelf is above it -- has
REM nowhere to keep anything.
REM
REM Which is why there is a third place, and netinstall is the only thing that
REM makes one. <name>.build beside the script is the build slot: netinstall
REM opens it for writing on the one launch that owes a compile and closes it
REM again when this file returns, so an exe kept there is out of reach of the
REM app on every launch after the one that built it. It is ".build" and not
REM "build" because this file finds it from %~dp0 and cannot tell netinstall's
REM shelf from a source tree, and a .cmd sitting next to an ordinary build/
REM directory is not exotic.
REM
REM Nothing is read from the environment to find it and nothing is told to this
REM file. The slot's own writability is the signal: under netinstall "this
REM directory takes a write" *is* "netinstall granted it this launch", because
REM that is the mechanism and nothing else produces it. That is the idea below
REM -- claiming the stamp is also the test of whether the directory can be
REM written -- used the other way round.
SET "CERTUTIL=%WINDIR%\System32\certutil.exe"
SET "HASH_OUT=%APP_FOLDER%\launcher.hash"
SET "SLOT=%SCRIPT_DIR%%SCRIPT_NAME%.build"
SET "APP_EXE=%SCRIPT_DIR%%SCRIPT_NAME%.exe"
SET "APP_STAMP=%SCRIPT_DIR%%SCRIPT_NAME%.stamp"
SET "MANIFEST=%APP_EXE%.manifest"
REM Both digests start empty here rather than beside the reads that fill them,
REM because the slot's branch below reaches the comparison without passing
REM either read, and an inherited variable of the same name would otherwise be
REM answering for one.
SET "SRC_HASH="
SET "CACHED_HASH="

REM The slot is asked first, and that ordering is the point rather than a
REM detail. What is beside the script is trusted -- a stamp says "this exe was
REM built from this script" and nothing says who wrote the stamp -- while what
REM is in the slot is verified, because netinstall holds a digest of every file
REM in there somewhere the app cannot reach. Under netinstall the shelf is
REM medium integrity and the .cmd on it is re-pinned every launch, so a same-user
REM process that cannot change the program *can* still put an <name>.exe and a
REM matching <name>.stamp beside it. Asking the slot first is what makes that
REM plant lose to the artifact somebody vouched for.
IF NOT EXIST "%SLOT%\" GOTO :BESIDE
SET "APP_EXE=%SLOT%\%SCRIPT_NAME%.exe"
SET "APP_STAMP="
SET "MANIFEST=%SLOT%\%SCRIPT_NAME%.exe.manifest"
SET "SLOT_PROBE=%SLOT%\.w%RANDOM%%RANDOM%"
2>NUL > "%SLOT_PROBE%" ECHO x
IF EXIST "%SLOT_PROBE%" (
    REM Granted, so this is the launch that owes the build. No stamp is kept
    REM here and none is read: netinstall holds the record, out of reach, and a
    REM stamp written beside an exe in a directory that is open right now would
    REM be exactly as writable as the exe it vouched for -- which is the defect
    REM that took the cache out in the first place.
    DEL /Q "%SLOT_PROBE%" >NUL 2>&1
    GOTO :NAMES
)
REM Sealed. The program is there, nothing can write over it, and there is
REM nothing left to check: no certutil, no stamp, no compile.
IF EXIST "%APP_EXE%" GOTO :LAUNCH
REM A slot that is neither writable nor holding a program is one this launch
REM has no use for.
SET "APP_EXE=%SCRIPT_DIR%%SCRIPT_NAME%.exe"
SET "APP_STAMP=%SCRIPT_DIR%%SCRIPT_NAME%.stamp"
SET "MANIFEST=%APP_EXE%.manifest"

:BESIDE
IF EXIST "%APP_EXE%" IF NOT EXIST "%APP_STAMP%" (
    SET "APP_EXE=%APP_FOLDER%\%SCRIPT_NAME%.exe"
    SET "APP_STAMP="
    SET "MANIFEST=%APP_FOLDER%\%SCRIPT_NAME%.exe.manifest"
)

REM The stamp, and only the stamp. The digest it is compared with is asked for
REM below, once there is something to compare it against.
REM
REM Every launch used to run a certutil here, and on the two paths that matter
REM most nothing read what it produced. Under netinstall the script sits one
REM level above the only writable directory, so the stamp cannot be written,
REM APP_STAMP ends up empty, and `IF NOT DEFINED APP_STAMP GOTO :BUILD` below
REM is reached before any comparison -- and the slot's sealed branch leaves for
REM :LAUNCH earlier still. A process and a file write an app launch, for a
REM value with no reader, which is the shape this file opened with in the
REM escape-byte probe.
IF DEFINED APP_STAMP IF EXIST "%APP_STAMP%" (
    FOR /F "usebackq tokens=* delims=" %%S IN ("%APP_STAMP%") DO (
        IF NOT DEFINED CACHED_HASH SET "CACHED_HASH=%%S"
    )
)

:NAMES
FOR %%D IN ("%APP_EXE%") DO SET "EXE_DIR=%%~dpD"
SET "APP_NEW=%EXE_DIR%%SCRIPT_NAME%.new%RANDOM%%RANDOM%.exe"
SET "APP_OLD=%EXE_DIR%%SCRIPT_NAME%.old%RANDOM%%RANDOM%.exe"
DEL /Q "%EXE_DIR%%SCRIPT_NAME%.new*.exe" >NUL 2>&1
DEL /Q "%EXE_DIR%%SCRIPT_NAME%.old*.exe" >NUL 2>&1

REM The slot's granted branch arrives here with no stamp and no digests, having
REM skipped both reads above, and the first line is what sends it to the
REM compile. Nowhere to keep a digest is nowhere to have read one from.
IF NOT DEFINED APP_STAMP GOTO :BUILD
IF NOT DEFINED CACHED_HASH GOTO :BUILD
IF NOT EXIST "%APP_EXE%" GOTO :BUILD
CALL :HASH
IF NOT DEFINED SRC_HASH GOTO :BUILD
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
REM And the digest is asked for here, once the directory has proved it will
REM take the stamp -- so a build with nowhere to write one, which is every
REM granted slot, does not pay for a value it is about to drop.
IF DEFINED APP_STAMP (
    CALL :HASH
    IF DEFINED SRC_HASH > "!APP_STAMP!" ECHO !SRC_HASH!
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

REM The digest, in one place because there are two callers and they want it at
REM different moments: the launch that has a stamp to compare against, and the
REM build that has somewhere to write one. Neither is the slot, which keeps no
REM stamp and needs no digest.
REM
REM Through a file rather than a pipe. `FOR /F usebackq` with a backticked
REM command hands it to a nested cmd, so asking for one digest created two
REM processes; over a quoted *path* it opens a file and starts nothing. On the
REM machine this was measured on -- a Windows 11 client, Defender on -- a
REM process start is 18 to 59 ms and certutil is 34 to 65.
REM
REM Unreachable by falling through: every path above leaves with EXIT /B.
:HASH
IF DEFINED SRC_HASH GOTO :EOF
IF NOT EXIST "%CERTUTIL%" GOTO :EOF
2>NUL >"%HASH_OUT%" "%CERTUTIL%" -hashfile "%~f0" SHA256
IF NOT EXIST "%HASH_OUT%" GOTO :EOF
FOR /F "usebackq skip=1 tokens=* delims=" %%H IN ("%HASH_OUT%") DO (
    IF NOT DEFINED SRC_HASH SET "SRC_HASH=%%H"
)
IF DEFINED SRC_HASH SET "SRC_HASH=!SRC_HASH: =!"
GOTO :EOF
