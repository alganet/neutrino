# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-windows.ps1 - External test verifier for Windows

param(
    [string]$ScreenshotDir = $env:USERPROFILE,
    # The neutrinotest artifact and the folder it compiles and unpacks into.
    # Default to this script's own dir, which is where the standalone windows
    # lane builds and runs `test\neutrinotest.cmd`. The netinstall e2e installs
    # the same app into a temp HOME and runs it from there, so it passes those
    # in: the WebView2 package sits beside the exe, wherever the exe is.
    [string]$Artifact = (Join-Path $PSScriptRoot "neutrinotest.cmd"),
    [string]$AppDir = (Join-Path $PSScriptRoot "neutrinotest")
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinAPI {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

# Two budgets, because the first window on this lane is not like the others.
# This app folder is cold: the Windows driver downloads and unpacks the pinned
# WebView2 package before CoreWebView2 exists, and all of that happens *after*
# the Form is on screen and before the page can set a title. The two suites
# beside this one already budget for it -- appcache.ps1 waits 180 seconds on its
# first launch and says why, verify-offline.ps1 waits 240 -- and this one waited
# 120 for the whole thing and went red three times in a row on exactly that
# stretch, saying `=== Step 0: Ready ===` and no more.
$FirstTimeout = 240
$Timeout = 60
$PollInterval = 500
$Failures = 0

New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null

# A verifier that speaks in PASS and FAIL should not leave by exception. The
# waits below used to `throw` on a timeout; with $ErrorActionPreference = Stop
# that propagates out of the script, past the step's own log assembly, and the
# annotations get whatever had been printed before it -- two section headers,
# three runs running. Ending here instead means the log always finishes with a
# Results line and the exit code is always the failure count.
function Fail-Now($message) {
    Write-Host "FAIL: $message"
    $script:Failures++
    Write-Host ""
    Write-Host "=== Results: $script:Failures failure(s) ==="
    exit $script:Failures
}

# What the driver had managed to fetch when a wait gave up. Every failure so far
# has been a wait ending at its bound with nothing else said, and the two
# explanations want opposite fixes: the package download never finished, or it
# finished and the page never ran. One line separates them.
function Report-PackageState {
    $root = Join-Path $AppDir "Microsoft.Web.WebView2"
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Host "report: no WebView2 package directory at $root"
        return
    }
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    Write-Host "report: WebView2 package: $($files.Count) file(s), $bytes byte(s)"
}

function Take-Screenshot($name) {
    try {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bounds.Size)
        $bitmap.Save("$ScreenshotDir\$name.png", [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose(); $graphics.Dispose()
    } catch {}
}

function Wait-ForTitle($pattern, $seconds) {
    if (-not $seconds) { $seconds = $Timeout }
    $deadline = (Get-Date).AddSeconds($seconds)
    do {
        $procs = Get-Process | Where-Object { $_.MainWindowTitle -like "*$pattern*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($procs) { return $procs }
        Start-Sleep -Milliseconds $PollInterval
    } while ((Get-Date) -lt $deadline)
    # A bare timeout cannot tell an app that died from two apps where the wrong
    # one was picked, and those want opposite fixes. Say what was actually on
    # screen before giving up.
    # `report:` and not two spaces: this dump is the reason the wait says
    # anything at all when it gives up, and the annotate pattern this lane uses
    # did not match it -- so the one thing written to explain a timeout was the
    # one thing that never left the job log.
    Report-PackageState
    Write-Host "report: windows with a title when the wait gave up:"
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($proc.MainWindowHandle -eq 0 -or -not $proc.MainWindowTitle) { continue }
            Write-Host "report:   $($proc.ProcessName) [$($proc.Id)] '$($proc.MainWindowTitle)'"
        } catch { continue }
    }
    Fail-Now "TIMEOUT after ${seconds}s waiting for title: $pattern"
}

function Wait-ForApp() {
    $deadline = (Get-Date).AddSeconds($FirstTimeout)
    do {
        $p = Get-Process -Name neutrinotest -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { return $p }
        Start-Sleep -Milliseconds $PollInterval
    } while ((Get-Date) -lt $deadline)
    Report-PackageState
    Fail-Now "TIMEOUT after ${FirstTimeout}s waiting for the app to show a window"
}

function Assert-Title($proc, $expected) {
    $proc.Refresh()
    $actual = $proc.MainWindowTitle
    if ($actual -eq $expected) {
        Write-Host "  PASS: title = '$expected'"
    } else {
        Write-Host "  FAIL: title expected='$expected' actual='$actual'"
        $script:Failures++
    }
}

function Assert-Geometry($hwnd, $expectedW, $expectedH, $tolerance) {
    if (-not $tolerance) { $tolerance = 80 }
    $rect = New-Object WinAPI+RECT
    [WinAPI]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
    $actualW = $rect.Right - $rect.Left
    $actualH = $rect.Bottom - $rect.Top
    $dw = [Math]::Abs($actualW - $expectedW)
    $dh = [Math]::Abs($actualH - $expectedH)
    if ($dw -le $tolerance -and $dh -le $tolerance) {
        Write-Host "  PASS: geometry ~= ${expectedW}x${expectedH} (actual: ${actualW}x${actualH})"
    } else {
        Write-Host "  FAIL: geometry expected ~= ${expectedW}x${expectedH} actual=${actualW}x${actualH}"
        $script:Failures++
    }
}

function Assert-Position($hwnd, $expectedX, $expectedY, $tolerance) {
    if (-not $tolerance) { $tolerance = 10 }
    $rect = New-Object WinAPI+RECT
    [WinAPI]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
    $dx = [Math]::Abs($rect.Left - $expectedX)
    $dy = [Math]::Abs($rect.Top - $expectedY)
    if ($dx -le $tolerance -and $dy -le $tolerance) {
        Write-Host "  PASS: position ~= ${expectedX},${expectedY} (actual: $($rect.Left),$($rect.Top))"
    } else {
        Write-Host "  FAIL: position expected ~= ${expectedX},${expectedY} actual=$($rect.Left),$($rect.Top)"
        $script:Failures++
    }
}

# --- Test steps ---

Write-Host "=== Waiting for window ==="
# By process, not by title: whether a window appeared has nothing to do with
# which scripted step the app happens to be on, and matching the initial title
# made this fail whenever the app got ahead of the verifier.
$proc = Wait-ForApp
Take-Screenshot "00-initial"

# The Windows driver downloads its engine assemblies and calls Assembly.LoadFrom
# on them, so what landed in the package directory is code this app runs and is
# part of what this verifier is for. Two things are asserted: every pinned member
# is there and hashes to its pin, and *nothing else is there* -- the unpack used
# to build its destination out of the name the archive supplied, which walked out
# of this directory entirely.
#
# The pinned list is read out of the artifact under test rather than repeated
# here, for the same reason parse.sh lifts the splitter: a copy can go stale and
# still pass.
function Assert-WebView2Package($artifact, $packageRoot) {
    if (-not (Test-Path -LiteralPath $packageRoot)) {
        Write-Host "  FAIL: no package directory at $packageRoot"
        Write-Host "::warning title=windows-package::no package directory at $packageRoot"
        $script:Failures++
        return
    }

    $lines = Get-Content -LiteralPath $artifact
    $start = -1; $stop = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -eq '    var NeutrinoWebview = {') { $start = $i; continue }
        if ($start -ge 0 -and $lines[$i] -eq '    };') { $stop = $i; break }
    }
    if ($start -lt 0 -or $stop -lt 0) {
        Write-Host "  FAIL: could not lift the pinned member list out of $artifact"
        Write-Host "::warning title=windows-package::could not lift the pinned member list"
        $script:Failures++
        return
    }

    $work = Join-Path $env:TEMP 'neutrino-package-assert'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    ($lines[$start..$stop] + 'module.exports = NeutrinoWebview;') |
        Set-Content -LiteralPath (Join-Path $work 'obj.js') -Encoding UTF8
    'console.log(JSON.stringify(require("./obj.js").webView2Members));' |
        Set-Content -LiteralPath (Join-Path $work 'members.js') -Encoding UTF8

    Push-Location $work
    $members = (& node members.js) | ConvertFrom-Json
    Pop-Location

    $expected = @{}
    foreach ($m in $members) { $expected[$m.path.Replace('/', '\')] = $m.sha256 }

    $onDisk = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File)) {
        $onDisk[$f.FullName.Substring($packageRoot.Length).TrimStart('\')] = $f.FullName
    }

    # A pin nobody checked would pass this whole function, so say how many were
    # checked and fail on zero.
    if ($expected.Count -eq 0) {
        Write-Host "  FAIL: the artifact pins no package members at all"
        Write-Host "::warning title=windows-package::the artifact pins no package members at all"
        $script:Failures++
        return
    }

    foreach ($rel in $expected.Keys) {
        if (-not $onDisk.ContainsKey($rel)) {
            Write-Host "  FAIL: pinned member missing from the package: $rel"
            Write-Host "::warning title=windows-package::pinned member missing: $rel"
            $script:Failures++
            continue
        }
        $got = (Get-FileHash -LiteralPath $onDisk[$rel] -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $expected[$rel]) {
            Write-Host "  FAIL: $rel hashes to $got, pinned as $($expected[$rel])"
            Write-Host "::warning title=windows-package::$rel does not match its pin"
            $script:Failures++
        } else {
            Write-Host "  PASS: $rel matches its pin"
        }
    }

    foreach ($rel in $onDisk.Keys) {
        if (-not $expected.ContainsKey($rel)) {
            Write-Host "  FAIL: the unpack wrote something nothing pinned: $rel"
            Write-Host "::warning title=windows-package::unpinned file in the package directory: $rel"
            $script:Failures++
        }
    }
    Write-Host "  PASS: the package directory holds the $($expected.Count) pinned members and nothing else"
}

Write-Host "=== Step 0: Ready ==="
# The long budget again, and this is the wait that needed it: the Form is on
# screen from Wait-ForApp, and everything between that and this title is the
# WebView2 package being fetched and unpacked. Every wait after this one is a
# scripted step a second apart and gets the short budget.
$proc = Wait-ForTitle "STEP0" $FirstTimeout
Assert-Title $proc "STEP0"
Take-Screenshot "01-step0"

Write-Host "=== Step 1: setTitle ==="
$proc = Wait-ForTitle "STEP1-Test Title"
Assert-Title $proc "STEP1-Test Title"
Take-Screenshot "02-step1"

Write-Host "=== Step 2: resize ==="
$proc = Wait-ForTitle "STEP2"
$hwnd = $proc.MainWindowHandle
Assert-Geometry $hwnd 500 400
Take-Screenshot "03-step2"

Write-Host "=== Step 3: move ==="
$proc = Wait-ForTitle "STEP3"
$hwnd = $proc.MainWindowHandle
Assert-Position $hwnd 0 0
Take-Screenshot "04-step3"

Write-Host "=== Waiting for TESTS DONE ==="
$proc = Wait-ForTitle "TESTS DONE"
Take-Screenshot "05-done"

Write-Host "=== WebView2 package: pinned, and nothing else unpacked ==="
Assert-WebView2Package $Artifact (Join-Path $AppDir "Microsoft.Web.WebView2")

Write-Host ""
Write-Host "=== Results: $Failures failure(s) ==="
exit $Failures
