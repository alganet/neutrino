@echo off
setlocal enableextensions

set "SCRIPT_DIR=%~dp0"
set "FX_DIR=%WINDIR%\Microsoft.NET\Framework\v4.0.30319"
set "JSC=%FX_DIR%\jsc.exe"
set "WEBVIEW2_ROOT=%SCRIPT_DIR%packages\Microsoft.Web.WebView2"
set "WEBVIEW2_DIR="
set "WEBVIEW2_LOADER="
set "DEBUG_MODE="

if /i "%~1"=="--debug" set "DEBUG_MODE=1"

if not exist "%JSC%" (
  set "FX_DIR=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319"
  set "JSC=%FX_DIR%\jsc.exe"
)
if not exist "%JSC%" (
  call :fail "jsc.exe not found."
  exit /b 1
)

call :find_webview2_dir
if not defined WEBVIEW2_DIR (
  call :download_webview2
  if errorlevel 1 exit /b 1
  call :find_webview2_dir
)

if not defined WEBVIEW2_DIR (
  call :fail "WebView2 SDK assemblies not found under ""%SCRIPT_DIR%packages"" after download."
  exit /b 1
)

call :stage_webview2_runtime
if errorlevel 1 exit /b 1

"%JSC%" /nologo /debug- /t:winexe /out:"%SCRIPT_DIR%windows-app.exe" ^
  /autoref+ ^
  /lib:"%FX_DIR%" ^
  /r:"%FX_DIR%\mscorlib.dll" ^
  /r:"%FX_DIR%\System.dll" ^
  /r:"%FX_DIR%\System.Configuration.dll" ^
  /r:"%FX_DIR%\Accessibility.dll" ^
  /r:"%FX_DIR%\System.Drawing.dll" ^
  /r:"%FX_DIR%\System.Windows.Forms.dll" ^
  "%SCRIPT_DIR%windows-host.js" ^
  "%SCRIPT_DIR%webview.js"
if errorlevel 1 (
  call :fail "JScript.NET compile failed."
  exit /b 1
)

if defined DEBUG_MODE (
  echo Running windows-app.exe in debug mode...
  if exist "%SCRIPT_DIR%windows-app.log" del /q "%SCRIPT_DIR%windows-app.log" >nul 2>nul
  "%SCRIPT_DIR%windows-app.exe"
  echo windows-app.exe exited with code %ERRORLEVEL%.
  echo.
  if exist "%SCRIPT_DIR%windows-app.log" (
    echo ---- windows-app.log ----
    type "%SCRIPT_DIR%windows-app.log"
    echo -------------------------
  ) else (
    echo windows-app.log was not created.
  )
  call :pause_dbg
  exit /b 0
)

start "" /D "%SCRIPT_DIR%" "%SCRIPT_DIR%windows-app.exe"
if errorlevel 1 (
  call :fail "Failed to start windows-app.exe"
  exit /b 1
)
exit /b 0

:find_webview2_dir
set "WEBVIEW2_DIR="
if exist "%WEBVIEW2_ROOT%\lib\net45\Microsoft.Web.WebView2.Core.dll" if exist "%WEBVIEW2_ROOT%\lib\net45\Microsoft.Web.WebView2.WinForms.dll" set "WEBVIEW2_DIR=%WEBVIEW2_ROOT%\lib\net45"
if not defined WEBVIEW2_DIR if exist "%WEBVIEW2_ROOT%\lib\net462\Microsoft.Web.WebView2.Core.dll" if exist "%WEBVIEW2_ROOT%\lib\net462\Microsoft.Web.WebView2.WinForms.dll" set "WEBVIEW2_DIR=%WEBVIEW2_ROOT%\lib\net462"
if not defined WEBVIEW2_DIR (
  for /d %%D in ("%SCRIPT_DIR%packages\Microsoft.Web.WebView2.*") do (
    if not defined WEBVIEW2_DIR if exist "%%~fD\lib\net45\Microsoft.Web.WebView2.Core.dll" if exist "%%~fD\lib\net45\Microsoft.Web.WebView2.WinForms.dll" set "WEBVIEW2_DIR=%%~fD\lib\net45"
    if not defined WEBVIEW2_DIR if exist "%%~fD\lib\net462\Microsoft.Web.WebView2.Core.dll" if exist "%%~fD\lib\net462\Microsoft.Web.WebView2.WinForms.dll" set "WEBVIEW2_DIR=%%~fD\lib\net462"
  )
)
exit /b 0

:stage_webview2_runtime
copy /y "%WEBVIEW2_DIR%\Microsoft.Web.WebView2.Core.dll" "%SCRIPT_DIR%Microsoft.Web.WebView2.Core.dll" >nul
if errorlevel 1 (
  call :fail "Failed to stage Microsoft.Web.WebView2.Core.dll"
  exit /b 1
)

copy /y "%WEBVIEW2_DIR%\Microsoft.Web.WebView2.WinForms.dll" "%SCRIPT_DIR%Microsoft.Web.WebView2.WinForms.dll" >nul
if errorlevel 1 (
  call :fail "Failed to stage Microsoft.Web.WebView2.WinForms.dll"
  exit /b 1
)

set "WEBVIEW2_PKG_DIR=%WEBVIEW2_DIR%\..\.."
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" if exist "%WEBVIEW2_PKG_DIR%\runtimes\win-x64\native\WebView2Loader.dll" set "WEBVIEW2_LOADER=%WEBVIEW2_PKG_DIR%\runtimes\win-x64\native\WebView2Loader.dll"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" if exist "%WEBVIEW2_PKG_DIR%\runtimes\win-arm64\native\WebView2Loader.dll" set "WEBVIEW2_LOADER=%WEBVIEW2_PKG_DIR%\runtimes\win-arm64\native\WebView2Loader.dll"
if not defined WEBVIEW2_LOADER if exist "%WEBVIEW2_PKG_DIR%\runtimes\win-x86\native\WebView2Loader.dll" set "WEBVIEW2_LOADER=%WEBVIEW2_PKG_DIR%\runtimes\win-x86\native\WebView2Loader.dll"
if not defined WEBVIEW2_LOADER if exist "%WEBVIEW2_PKG_DIR%\runtimes\win-x64\native\WebView2Loader.dll" set "WEBVIEW2_LOADER=%WEBVIEW2_PKG_DIR%\runtimes\win-x64\native\WebView2Loader.dll"
if not defined WEBVIEW2_LOADER if exist "%WEBVIEW2_PKG_DIR%\runtimes\win-arm64\native\WebView2Loader.dll" set "WEBVIEW2_LOADER=%WEBVIEW2_PKG_DIR%\runtimes\win-arm64\native\WebView2Loader.dll"

if not defined WEBVIEW2_LOADER (
  for /r "%WEBVIEW2_PKG_DIR%" %%F in (WebView2Loader.dll) do (
    if not defined WEBVIEW2_LOADER set "WEBVIEW2_LOADER=%%~fF"
  )
)

if not defined WEBVIEW2_LOADER (
  call :fail "Failed to find WebView2Loader.dll in package folder."
  exit /b 1
)

copy /y "%WEBVIEW2_LOADER%" "%SCRIPT_DIR%WebView2Loader.dll" >nul
if errorlevel 1 (
  call :fail "Failed to stage WebView2Loader.dll"
  exit /b 1
)
exit /b 0

:download_webview2
echo WebView2 SDK not found locally. Downloading package...
if not exist "%SCRIPT_DIR%packages" mkdir "%SCRIPT_DIR%packages"
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; $pkgPath = Join-Path $env:TEMP 'Microsoft.Web.WebView2.zip'; Invoke-WebRequest -UseBasicParsing -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile $pkgPath; if (Test-Path '%WEBVIEW2_ROOT%') { Remove-Item -Recurse -Force '%WEBVIEW2_ROOT%' }; Expand-Archive -Path $pkgPath -DestinationPath '%WEBVIEW2_ROOT%' -Force; Remove-Item -Force $pkgPath"
if errorlevel 1 (
  call :fail "Failed to download or extract Microsoft.Web.WebView2 package."
  exit /b 1
)
exit /b 0

:fail
echo ERROR: %~1
if defined DEBUG_MODE call :pause_dbg
exit /b 1

:pause_dbg
echo.
echo Debug mode enabled. Press any key to continue...
pause >nul
exit /b 0
