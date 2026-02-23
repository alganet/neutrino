@echo off
setlocal enableextensions

set "SCRIPT_DIR=%~dp0"
set "FX_DIR=%WINDIR%\Microsoft.NET\Framework\v4.0.30319"
set "JSC=%FX_DIR%\jsc.exe"
set "WEBVIEW2_ROOT=%SCRIPT_DIR%packages\Microsoft.Web.WebView2"

if not exist "%JSC%" (
  set "FX_DIR=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319"
  set "JSC=%FX_DIR%\jsc.exe"
)
if not exist "%JSC%" (
  exit /b 1
)

if not exist "%WEBVIEW2_ROOT%\" (
  call :download_webview2
)

if not exist "%WEBVIEW2_ROOT%\" (
  exit /b 1
)

"%JSC%" /nologo /debug- /t:winexe /out:"%SCRIPT_DIR%webview.exe" ^
  /autoref+ ^
  /lib:"%FX_DIR%" ^
  /r:"%FX_DIR%\mscorlib.dll" ^
  /r:"%FX_DIR%\System.dll" ^
  /r:"%FX_DIR%\System.Configuration.dll" ^
  /r:"%FX_DIR%\Accessibility.dll" ^
  /r:"%FX_DIR%\System.Drawing.dll" ^
  /r:"%FX_DIR%\System.Windows.Forms.dll" ^
  "%SCRIPT_DIR%webview.js"
if errorlevel 1 exit /b 1

start "" /D "%SCRIPT_DIR%" "%SCRIPT_DIR%webview.exe"
if errorlevel 1 exit /b 1
exit /b 0

:download_webview2
if not exist "%SCRIPT_DIR%packages" mkdir "%SCRIPT_DIR%packages"
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; $pkgPath = Join-Path $env:TEMP 'Microsoft.Web.WebView2.zip'; Invoke-WebRequest -UseBasicParsing -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile $pkgPath; if (Test-Path '%WEBVIEW2_ROOT%') { Remove-Item -Recurse -Force '%WEBVIEW2_ROOT%' }; Expand-Archive -Path $pkgPath -DestinationPath '%WEBVIEW2_ROOT%' -Force; Remove-Item -Force $pkgPath"
if errorlevel 1 exit /b 1
exit /b 0
