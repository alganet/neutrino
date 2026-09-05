# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# themelive.ps1 - does a *running* Windows app notice the desktop changing?
#
# The lane's two halves launch under one app theme each and compare what came
# back, which is the right shape for "did this value come from the desktop"
# and the wrong one for "does the watcher work" -- the palette is read once at
# startup either way, so a watcher that never fires produces two green halves.
# That is the same hole themeflip.sh's live half was written to close on the
# unix lanes, arriving here.
#
# The knob is the registry value the driver already reads, flipped under an app
# that is up. There is no notification to arrange: this lane's watcher is a
# re-read on its own message loop, once a second, so the only thing being
# asserted is that the loop reads and the diff delivers.
#
# Measured on a Windows 11 client VM before this was written, one app held
# still while the desktop moved under it -- the accent through SetSysColors,
# 0078d4 -> 6aa0bd -> b35a57 -> 0078d4, four palettes delivered; and a real
# contrast theme applied, which arrived as one more. So the mechanism works and
# what this file adds is a runner that says so.
param(
    [string]$Artifact = ".\test\neutrinolivetheme.cmd",
    [int]$UpTimeout = 120,
    [int]$MoveTimeout = 30
)

$ErrorActionPreference = "Continue"
$key  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
$name = [System.IO.Path]::GetFileNameWithoutExtension($Artifact)
$rc   = 0

function Note($t) { Write-Host "report: $t" }

function Read-Knob() {
    $v = (Get-ItemProperty -Path $key -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
    if ($null -eq $v) { return "<absent:light>" } else { return "$v" }
}
function Set-Knob($light) {
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name AppsUseLightTheme -Value $light -Type DWord
    Set-ItemProperty -Path $key -Name SystemUsesLightTheme -Value $light -Type DWord
}

# The app's own title and not merely a window. The package path puts a
# downloader on screen first, and a wait that took any window would measure
# that instead -- which is how a package-lane run once reported a title of
# "Downloading WebView2 Runtime" and was read as the app.
function Get-Title() {
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } |
         Select-Object -First 1
    if ($p) { return [string]$p.MainWindowTitle }
    return ""
}
function Stop-App() {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

$was = Read-Knob
Note "live knob before: AppsUseLightTheme=$was"

try {
    # Light first, so the flip below is a change and not a no-op on a machine
    # that was already dark.
    Set-Knob 1
    Start-Sleep -Seconds 2

    # Through cmd.exe with the working directory named, which is how
    # verify-std.ps1 launches on this lane and not a style choice:
    # Start-Process takes the child's directory from
    # [Environment]::CurrentDirectory rather than from $PWD, so a relative
    # artifact path resolves against somewhere else entirely. The two logs are
    # named .log so the lane's sheet step, which gathers ~/*.log, picks up the
    # launcher's own account beside this script's; separate paths because
    # Start-Process refuses to point both redirections at one file.
    $outLog = Join-Path $env:USERPROFILE "themelive-app-out.log"
    $errLog = Join-Path $env:USERPROFILE "themelive-app-err.log"
    Start-Process -FilePath "cmd.exe" -WorkingDirectory (Get-Location).Path `
        -ArgumentList "/c", $Artifact -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog |
        Out-Null

    $waited = 0
    $before = ""
    while ($waited -lt $UpTimeout) {
        $before = Get-Title
        if ($before -like "STD-LIVE*") { break }
        Start-Sleep -Seconds 1
        $waited++
    }
    if ($before -notlike "STD-LIVE*") {
        Write-Host "FAIL: live half: no STD-LIVE window in ${UpTimeout}s; the probe never came up"
        Stop-App; exit 1
    }
    Note "live before: $before"
    if ($before -like "*src=null*") {
        Write-Host "FAIL: live half: the probe read no toolkit, so a flip would prove nothing"
        Stop-App; exit 1
    }

    Set-Knob 0
    Note "live knob after the flip: AppsUseLightTheme=$(Read-Knob)"
    # Asked of the machine rather than assumed from the request, which is the
    # distinction Read-Knob draws for the two halves beside this one: a knob
    # that refused the write is an apparatus defect and reads exactly like a
    # watcher that did not fire.
    if ((Read-Knob) -ne "0") {
        Note "live half: the registry refused the write; no live flip to observe"
        Stop-App; exit 0
    }

    $waited = 0
    $after = ""
    while ($waited -lt ($MoveTimeout * 2)) {
        $after = Get-Title
        if ($after -like "*moved=yes*") { break }
        Start-Sleep -Milliseconds 500
        $waited++
    }
    $after = Get-Title
    Note "live after: $after"

    $n = "?"
    if ($after -match ' n=(\d+)') { $n = $Matches[1] }
    if ($after -like "*moved=yes*") {
        Write-Host "PASS: the running app was handed a new palette when the app theme changed"
        Note "live readings n=$n"
    } elseif ($after -like "STD-LIVE*") {
        Write-Host "FAIL: the app theme changed under a running app and it was handed nothing (n=$n); the theme watcher did not fire"
        $rc = 1
    } else {
        Write-Host "FAIL: live half: the probe stopped writing its title after the flip"
        $rc = 1
    }
} finally {
    Stop-App
    if ($was -eq "<absent:light>") { Set-Knob 1 } else { Set-Knob ([int]$was) }
    Note "live knob restored: AppsUseLightTheme=$(Read-Knob)"
}
exit $rc
