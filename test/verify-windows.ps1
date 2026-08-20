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

Write-Host ""
Write-Host "=== Results: $Failures failure(s) ==="
exit $Failures
