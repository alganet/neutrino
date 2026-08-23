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
# Usage: verify-winerr.ps1 <app.cmd>

$ErrorActionPreference = "Stop"

$AppCmd = $args[0]
if (-not $AppCmd) { throw "usage: verify-winerr.ps1 <app.cmd>" }

$AppCmd    = (Resolve-Path $AppCmd).Path
$AppName   = [System.IO.Path]::GetFileNameWithoutExtension($AppCmd)
$AppFolder = Join-Path (Split-Path -Parent $AppCmd) $AppName
$ErrorLog  = Join-Path $AppFolder "neutrino-error.log"

$Failures = 0
function Pass($m) { Write-Host "  PASS: $m" }
function Fail($m) { Write-Host "  FAIL: $m"; $script:Failures++ }

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
    Fail "the .cmd itself never returned; nothing below is about the driver"
    Write-Host "  report: winerr launcher=STUCK box=SKIPPED ended=SKIPPED recorded=SKIPPED"
    Write-Host "=== Results: $Failures failure(s) ==="
    exit 1
}

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
    Pass "a window titled 'neutrino' came up"
    $boxSeen = "SHOWN"
} else {
    Fail "no window ever came up; a fix that shows nobody anything would pass the checks below"
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
    Pass "the process ended without anyone clicking anything"
} else {
    Fail "the process is still up; this is the modal that never returns"
    Get-Process -Name $AppName -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "    still up: $($_.ProcessName) '$($_.MainWindowTitle)'" }
    Stop-Process -Name $AppName -Force -ErrorAction SilentlyContinue
}

Write-Host "=== Is the failure on disk afterwards? ==="
$recorded = "ABSENT"
if (Test-Path $ErrorLog) {
    $text = (Get-Content -Raw $ErrorLog)
    if ($text -match "WebView2") {
        Pass "neutrino-error.log names the failure"
        $recorded = "NAMED"
    } else {
        Fail "neutrino-error.log is there but does not say what failed"
        $recorded = "EMPTY"
    }
} else {
    Fail "nothing in the app folder names the failure"
    Write-Host "    app folder holds: $((Get-ChildItem -Name $AppFolder -ErrorAction SilentlyContinue) -join ',')"
}

# One line the annotator can carry out whole, on the same terms as every other
# verifier here: the job log needs a token and the checks API does not.
$endedWord = if ($ended) { "ENDED" } else { "STUCK" }
Write-Host "  report: winerr box=$boxSeen ended=$endedWord recorded=$recorded"
Write-Host "=== Results: $Failures failure(s) ==="
exit $Failures
