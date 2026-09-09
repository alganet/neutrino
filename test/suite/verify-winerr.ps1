# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-winerr.ps1 - Asserts that a failed initialisation ends, and says so.
#
# The Windows driver used to answer a failed WebView2 initialisation with a
# modal MessageBox and nothing else. Measured on a runner: the box never
# returns, so an unattended machine sat holding a window ninety seconds after
# the download threw and ended on somebody's timeout rather than on the error --
# and the app folder afterwards held the exe, its manifest and the build stamp
# and nothing at all that named what went wrong.
#
# Three things have to hold and none of them is worth anything without the
# others. The box has to come up, or "it ended promptly" is satisfied by a fix
# that shows nobody anything. The process has to end, or the box is the old one.
# And the failure has to be on disk afterwards, or nobody who was not watching
# the screen can ever find out why.
#
# The failure is provoked by pinning a version that does not exist, so the
# package URL 404s and the download throws the way a digest mismatch would.
# Nothing about the driver is modified: this is the real path into handleError.
#
# It takes two of those to get there now, and the second is worth as much as the
# first. The driver renders through the WebView2 runtime the machine already has
# and only fetches the package when it cannot, so a build carrying nothing but a
# bad pin never reaches the pin -- it comes up, and this suite passes while
# measuring nothing. Naming an entry point that does not exist is what puts the
# download back in front of it.
#
# Which makes this the one suite that measures the fallback. An Evergreen path
# that fails has to arrive on the package path, and the proof of it is a build
# that gets all the way to the 404 this file is waiting for.
#
# Both are overlay parts, not edits to a built file. The line above saying
# nothing about the driver is modified was not true until they were: the
# workflow ran two `sed -i` over the assembled .cmd, each with a `grep -q` after
# it standing in for the failure path a substitution does not have, and this was
# the one artifact in the tree no single assemble.sh run had produced. It is now
# a row in test/apps.tsv naming test/probe/winerr/, which replaces
# js/webview2-pin.js and js/evergreen-export.js the way every other variation in
# this tree replaces a part.
#
# Usage: verify-winerr.ps1 <app.cmd>

$ErrorActionPreference = "Stop"

$AppCmd = $args[0]
if (-not $AppCmd) { throw "usage: verify-winerr.ps1 <app.cmd>" }

$AppCmd    = (Resolve-Path $AppCmd).Path
$AppName   = [System.IO.Path]::GetFileNameWithoutExtension($AppCmd)
$AppFolder = Join-Path (Split-Path -Parent $AppCmd) $AppName
$ErrorLog  = Join-Path $AppFolder "neutrino-error.log"

# The six words. The three checks below were the right three and reached
# nothing: this suite printed the only spelling in the tree that already matched
# harness.sh's, and still filed no row, so the lane could say a failed
# initialisation ends and be believed only by someone reading the log.
. (Join-Path $PSScriptRoot "..\lib\harness.ps1")

if (Test-Path $AppFolder) { Remove-Item -Recurse -Force $AppFolder -ErrorAction SilentlyContinue }

Write-Host "=== Launching a build whose package cannot be fetched ==="
# Started with a deadline rather than waited on. `cmd /c ... > file` would hand
# the redirected handles to the detached GUI process START spawns, and that
# process holds them for as long as it lives -- measured, and it hangs the
# caller rather than the app.
$launcher = Start-Process -FilePath "cmd.exe" -ArgumentList "/c",$AppCmd -PassThru -NoNewWindow
$launcher | Wait-Process -Timeout 180 -ErrorAction SilentlyContinue
if ($launcher.HasExited) {
    Write-Host "  (the .cmd returned rc=$($launcher.ExitCode); START reports on the launch, not on what it launched)"
} else {
    nt_fail winerr.launcher.returned "the .cmd itself never returned; nothing below is about the driver"
    # The three words that used to be spelled SKIPPED inside a report line.
    # sheet.sh has counted a skip column since it was written and this was one
    # of the two places in the tree that had something to put in it, said in a
    # way nothing could read.
    $why = "the .cmd never returned, so the driver was never reached"
    nt_skip winerr.box.shown $why
    nt_skip winerr.process.ended $why
    nt_skip winerr.recorded $why
    nt_finish
}
nt_pass winerr.launcher.returned "the .cmd returned and the driver was reached"

function Get-Box {
    Get-Process -Name $AppName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -eq "neutrino" } |
        Select-Object -First 1
}

# Without this the rest is worthless: an app that renders nothing ends promptly
# and leaves no window, which is exactly what the two checks below want to see.
Write-Host "=== Does the failure reach the screen at all? ==="
$box = $null
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    $box = Get-Box
    if ($box) { break }
    Start-Sleep -Milliseconds 500
}
if ($box) {
    nt_pass winerr.box.shown "a window titled 'neutrino' came up"
    $boxSeen = "SHOWN"
} else {
    nt_fail winerr.box.shown "no window ever came up; a fix that shows nobody anything would pass the checks below"
    $boxSeen = "ABSENT"
}

Write-Host "=== Does it let go on its own? ==="
# Generously longer than windowsErrorSeconds. What is being asserted is that the
# box is bounded at all, not what the bound is -- a run that is merely slow must
# not read as the modal that never returns.
$ended = $false
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Name $AppName -ErrorAction SilentlyContinue)) { $ended = $true; break }
    Start-Sleep -Milliseconds 500
}
if ($ended) {
    nt_pass winerr.process.ended "the process ended without anyone clicking anything"
} else {
    nt_fail winerr.process.ended "the process is still up; this is the modal that never returns"
    Get-Process -Name $AppName -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "    still up: $($_.ProcessName) '$($_.MainWindowTitle)'" }
    Stop-Process -Name $AppName -Force -ErrorAction SilentlyContinue
}

Write-Host "=== Is the failure on disk afterwards? ==="
$recorded = "ABSENT"
if (Test-Path $ErrorLog) {
    $text = (Get-Content -Raw $ErrorLog)
    if ($text -match "WebView2") {
        nt_pass winerr.recorded "neutrino-error.log names the failure"
        $recorded = "NAMED"
    } else {
        nt_fail winerr.recorded "neutrino-error.log is there but does not say what failed"
        $recorded = "EMPTY"
    }
} else {
    nt_fail winerr.recorded "nothing in the app folder names the failure"
    Write-Host "    app folder holds: $((Get-ChildItem -Name $AppFolder -ErrorAction SilentlyContinue) -join ',')"
}

# One line the annotator can carry out whole, on the same terms as every other
# verifier here: the job log needs a token and the checks API does not.
$endedWord = if ($ended) { "ENDED" } else { "STUCK" }
nt_report "winerr box=$boxSeen ended=$endedWord recorded=$recorded"
nt_finish
