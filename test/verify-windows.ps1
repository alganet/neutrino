# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-windows.ps1 - External test verifier for Windows

param([string]$ScreenshotDir = $env:USERPROFILE)

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

$Timeout = 120
$PollInterval = 500
$Failures = 0

New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null

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

function Wait-ForTitle($pattern) {
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        $procs = Get-Process | Where-Object { $_.MainWindowTitle -like "*$pattern*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($procs) { return $procs }
        Start-Sleep -Milliseconds $PollInterval
    } while ((Get-Date) -lt $deadline)
    # A bare timeout cannot tell an app that died from two apps where the wrong
    # one was picked, and those want opposite fixes. Say what was actually on
    # screen before giving up.
    Write-Host "  windows with a title when the wait gave up:"
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($proc.MainWindowHandle -eq 0 -or -not $proc.MainWindowTitle) { continue }
            Write-Host "    $($proc.ProcessName) [$($proc.Id)] '$($proc.MainWindowTitle)'"
        } catch { continue }
    }
    throw "TIMEOUT waiting for title: $pattern"
}

function Wait-ForApp() {
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        $p = Get-Process -Name neutrinotest -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { return $p }
        Start-Sleep -Milliseconds $PollInterval
    } while ((Get-Date) -lt $deadline)
    throw "TIMEOUT waiting for the app to show a window"
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
$proc = Wait-ForTitle "STEP0"
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
Assert-WebView2Package (Join-Path $PSScriptRoot "neutrinotest.cmd") (Join-Path $PSScriptRoot "neutrinotest\Microsoft.Web.WebView2")

Write-Host ""
Write-Host "=== Results: $Failures failure(s) ==="
exit $Failures
