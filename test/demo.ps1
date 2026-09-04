# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# demo.ps1 - does the app on the download page work here?
#
# The Windows half of test/demo.sh, asserting the same title against the same
# app, and it is the lane the defect was on: the published demo's Close button
# did nothing on Windows and worked everywhere else, because WebView2's only
# pre-navigation hook ran the app's script before the parser had produced
# anything and `getElementById` answered null on the first line. Nothing here
# ran that app, so nothing here could say so.
#
# It launches the app itself, unlike its Unix twin. The batch region STARTs a
# detached exe and exits, so a caller that started it would be holding a handle
# to a process that is already gone -- which is the arrangement every other
# Windows suite in this tree ends up in, and the reason verify-windows.ps1 grew
# a -Launch of its own.

param(
    [string]$Artifact = (Join-Path $PSScriptRoot "neutrinodemo.cmd"),
    [string]$ScreenshotDir = $env:USERPROFILE,
    [int]$Timeout = 240
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$Failures = 0
function Note($m) { Write-Host "report: $m" }
function Fail($m) { Write-Host "FAIL: $m"; $script:Failures++ }

$AppName = [System.IO.Path]::GetFileNameWithoutExtension($Artifact)

if (-not (Test-Path -LiteralPath $Artifact)) {
    Fail "no artifact at $Artifact; test/demoapp.sh builds it"
    exit 1
}

# Start-Process and no pipe, which is the idiom the warm-up step in ci.yml
# already carries and the reason it gives: the batch region STARTs a detached
# exe and exits, so a pipe on the launcher outlives the launcher and this would
# wait on a handle the app never closes. -WindowStyle Hidden hides the console
# cmd.exe opens, not the window the app is about to show.
Note "launching $Artifact"
Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $Artifact -WindowStyle Hidden | Out-Null

Write-Host "=== Waiting for the demo to report ==="
$title = ""
$deadline = (Get-Date).AddSeconds($Timeout)
while ((Get-Date) -lt $deadline) {
    $p = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -like "DEMOPROBE *" } |
        Select-Object -First 1
    if ($p) { $title = $p.MainWindowTitle; break }
    Start-Sleep -Milliseconds 500
}

# The picture, taken whether or not the title arrived: a run that failed is the
# one where a look at the window is worth most.
try {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
    $bmp.Save((Join-Path $ScreenshotDir "demo.png"),
        [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose(); $g.Dispose()
    Note "shot $ScreenshotDir\demo.png"
} catch {
    Note "the capture threw: $($_.Exception.Message)"
}

if (-not $title) {
    Fail "no DEMOPROBE title in ${Timeout}s; the app's own script did not reach the reporter"
    # And what did come up, because "no window with this name" and "no window at
    # all" want different fixes. The app's own account too, where it left one --
    # a release build writes neutrino-error.log and nothing else.
    foreach ($o in @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle })) {
        Note "  window up: $($o.ProcessName) [$($o.Id)] '$($o.MainWindowTitle)'"
    }
    $log = Join-Path (Join-Path $PSScriptRoot $AppName) "neutrino-error.log"
    if (Test-Path -LiteralPath $log) {
        Note "the app's own failure:"
        Get-Content -LiteralPath $log | Select-Object -Last 8 | ForEach-Object { Note "  $_" }
    } else {
        Note "no neutrino-error.log beside the app"
    }
    Get-Process -Name $AppName -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "=== Results: $Failures failure(s) ==="
    exit $Failures
}

Note "title [$title]"

function Field($name) {
    if ($title -match " $name=(\S+)") { return $Matches[1] }
    return ""
}

$eng = Field "eng"
$tx = Field "tx"
$size = Field "size"
$desktop = Field "desktop"
$bound = Field "bound"

# The reading this file was written for. UNREADABLE is the early shell missing
# at the app's first statement -- the defect as it actually shipped -- and
# UNFILLED is the app running and reporting nothing.
switch -Regex ($eng) {
    '^(WebView2|QtWebEngine|Chromium|WebKit)$' {
        Note "engine $eng -- the app read its own markup and named the engine"
    }
    '^UNREADABLE$' {
        Fail "eng=UNREADABLE: document.getElementById answered null in the app's own script, so the early shell was not on the page when it ran"
    }
    '^(UNFILLED|)$' {
        Fail "eng=$(if ($eng) { $eng } else { '<absent>' }): the app ran and never filled its own page in"
    }
    default { Fail "eng=$eng is not an engine this app knows how to name" }
}

# Windows should be WebView2 and nothing else. The generic list above is shared
# with the Unix twin; this is the one line that is about this platform.
if ($eng -eq "WebView2") {
    Note "and WebView2 is what this platform renders through"
} elseif ($eng -match '^(QtWebEngine|Chromium|WebKit)$') {
    Fail "eng=$eng on Windows; this lane renders through WebView2 and nothing else"
}

switch -Regex ($tx) {
    '^(webmessage|title)$' { Note "transport $tx" }
    '^unwired$' {
        Fail "tx=unwired: this launch has no channel to the host, so none of the window verbs on the page can work"
    }
    default { Fail "tx=$(if ($tx) { $tx } else { '<absent>' }) is not a transport this lane offers" }
}

# Against the app's own config rather than a number written here, for the reason
# every lift in this tree gives: a copy goes stale and still passes.
$cfg = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "..\pages\demo\config.json")
$wantW = if ($cfg -match '"width"\s*:\s*(\d+)') { $Matches[1] } else { "?" }
$wantH = if ($cfg -match '"height"\s*:\s*(\d+)') { $Matches[1] } else { "?" }
if ($size -eq "${wantW}_x_${wantH}") {
    Note "size $size agrees with config.json"
} else {
    # A reading and not a control: innerWidth is the content area and a window
    # manager may hand back less than was asked for. What would be a defect is
    # the app failing to read a size at all, which the engine branch covers.
    Note "size $size against config ${wantW}x${wantH} -- the window manager had the last word"
}

Note "desktop $desktop"

# The button, which is the whole of what the person on Windows Home reported.
if ($bound -eq "yes") {
    Note "the Close button has a handler on it"
} else {
    # ${bound} and not $bound. A colon after a variable in a double-quoted
    # string is PowerShell's scope qualifier -- `$bound:` is read as a
    # namespace, and the whole file then fails to parse rather than this line
    # failing to interpolate. It cost a round: nothing in demo.ps1 ran.
    Fail "bound=${bound}: the Close button on the published demo has no handler, which is exactly the defect this file was written for"
}

Get-Process -Name $AppName -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Results: $Failures failure(s) ==="
exit $Failures
