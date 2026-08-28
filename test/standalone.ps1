# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# standalone.ps1 - the exe finds its own document, and the environment cannot
# choose one for it
#
# The Windows driver used to be handed the document's path in
# NEUTRINO_SCRIPT_PATH, set by the batch region just before the START. That is
# a variable that ends at which document this process executes, and netinstall's
# allowlist keeps the whole NEUTRINO_ prefix, so it arrived intact there too --
# the same shape findWebView2LibDir carries for its own variable, and the same
# answer: a release build does not read it.
#
# windowsLayout derives the path from the exe's own location instead: the script
# is <name>.cmd beside the exe where the exe was kept, and one level above it
# where the compile fell back into the app folder. Under netinstall the kept
# copy resolves to apps/<key>/<file>.cmd -- the read-only hardlink one level
# above the only writable directory, re-hashed against the pin on every launch.
#
# Two consequences, and this suite is both of them:
#
#   noset      the batch region no longer sets the variable at all
#   direct     the exe run on its own, from another working directory, with
#              nothing in the environment naming a document, comes up
#   ignored    a release build handed a bogus NEUTRINO_SCRIPT_PATH comes up
#              anyway -- ground rule 4, the fix is not reachable from the
#              environment
#   testing    and the same bogus value on a testing build *is* read and
#              refuses by name, so the gate is measured in both directions
#              rather than only in the one that would pass if it were absent
#   derived    with the document moved away the exe refuses and names both
#              paths it looked for -- the positive control for `direct`, which
#              would otherwise pass against a driver that had found its
#              document some other way
#
# Controls: each artifact has to come up through its own .cmd first, or every
# refusal below is a build that renders nothing rather than a reading.
#
# Usage: standalone.ps1 <default-tier app.cmd> <testing-tier app.cmd>
#        both built from test/neutrinoloaders.js

$ErrorActionPreference = "Continue"

$srcDefault = $args[0]
$srcTesting = $args[1]
if (-not $srcDefault -or -not (Test-Path $srcDefault) -or
    -not $srcTesting -or -not (Test-Path $srcTesting)) {
    Write-Output "usage: standalone.ps1 <default-tier app.cmd> <testing-tier app.cmd>"
    exit 2
}

$failures = 0
function Report($m) { Write-Output "report: $m" }
function Fail($m) { Write-Output "FAIL: $m"; $script:failures++ }

$work = Join-Path $env:TEMP ("standalone-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null

# Two apps under two names, so each gets its own app folder and neither reads
# the other's error log. The names are what the derivation walks, so they are
# also what a wrong derivation would get wrong.
$laneRel = Join-Path $work "ntrelease.cmd"
$laneTest = Join-Path $work "nttesting.cmd"
Copy-Item $srcDefault $laneRel -Force
Copy-Item $srcTesting $laneTest -Force
# The app folder is still <name>/, but the exe is no longer in it: the launcher
# compiles beside the script and keeps it there, which is what lets it be kept
# at all. The error log follows the app folder, not the exe.
$folderRel = Join-Path $work "ntrelease"
$folderTest = Join-Path $work "nttesting"
$exeRel = Join-Path $work "ntrelease.exe"
$exeTest = Join-Path $work "nttesting.exe"

# Somewhere that is not the app folder and not where either .cmd lives, so a
# driver that resolved its document relative to the current directory would be
# measured doing it rather than passing by accident.
$elsewhere = Join-Path $work "elsewhere"
New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null

function Stop-Apps {
    foreach ($n in @("ntrelease", "nttesting")) {
        Get-Process -Name $n -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

function Window-Up($seconds) {
    for ($i = 0; $i -lt $seconds; $i++) {
        $p = Get-Process -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowTitle -like "LOADERS*" }
        if ($p) { return "UP" }
        Start-Sleep -Seconds 1
    }
    return "DOWN"
}

# No pipeline on the launcher: the batch region STARTs a detached exe that
# inherits the standard handles, and this app never closes on purpose, so a
# pipe would outlive the launcher and hang the step. appcache.ps1 carries the
# same comment for the same reason (PR 20/28).
function Launch-Cmd($lane, $waitSeconds) {
    Stop-Apps
    $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(180000)) { $p.Kill() }
    return Window-Up $waitSeconds
}

# The exe on its own. No cmd.exe, no launcher, and a working directory that is
# neither the app folder nor the document's.
function Launch-Exe($exe, $scriptPathValue, $waitSeconds) {
    Stop-Apps
    if ($null -eq $scriptPathValue) {
        Remove-Item Env:NEUTRINO_SCRIPT_PATH -ErrorAction SilentlyContinue
    } else {
        $env:NEUTRINO_SCRIPT_PATH = $scriptPathValue
    }
    try {
        # Not -WindowStyle Hidden. appcache.ps1 passes that to cmd.exe, which is
        # a launcher with a console; here the process being started is the app
        # itself, and hiding it is hiding the one thing Window-Up reads.
        Start-Process -FilePath $exe -WorkingDirectory $elsewhere
        return Window-Up $waitSeconds
    } finally {
        Remove-Item Env:NEUTRINO_SCRIPT_PATH -ErrorAction SilentlyContinue
    }
}

function Error-Log($folder) {
    $p = Join-Path $folder "neutrino-error.log"
    if (Test-Path $p) { return (Get-Content $p -Raw) }
    return ""
}

function Clear-Error-Log($folder) {
    Remove-Item (Join-Path $folder "neutrino-error.log") -Force -ErrorAction SilentlyContinue
}

Write-Output "=== standalone: the exe finds its own document ==="

# =====================================================================
# noset: the launcher hands nothing over
# =====================================================================
# Half the fix lives in the batch region, and it is the half that decides
# whether the derivation is the live path or a fallback the tier builds skip.
$setsIt = Select-String -Path $laneRel -Pattern 'SET "NEUTRINO_SCRIPT_PATH=' -Quiet -ErrorAction SilentlyContinue
Report "noset batch_sets_it=$(if ($setsIt) { 'YES' } else { 'NO' })"
if ($setsIt) { Fail "noset expected=the batch region names no document actual=it still SETs NEUTRINO_SCRIPT_PATH" }

# =====================================================================
# control: both builds come up the ordinary way
# =====================================================================
# WebView2 is fetched on a first run, so this is the long wait.
$ctlRel = Launch-Cmd $laneRel 240
Report "control release window=$ctlRel exe=$(Test-Path $exeRel)"
if ($ctlRel -ne "UP") { Fail "control expected=the release build comes up actual=$ctlRel; nothing below is a reading" }

# The testing build gets the package copied rather than downloaded again: 45 MiB
# and a second cold fetch buy nothing here, and firstBadWebView2Member re-hashes
# every member on the way in, so a copy that is wrong is refused exactly as a
# download that is wrong would be.
$pkg = Join-Path $folderRel "Microsoft.Web.WebView2"
if (Test-Path $pkg) {
    New-Item -ItemType Directory -Path $folderTest -Force | Out-Null
    Copy-Item $pkg (Join-Path $folderTest "Microsoft.Web.WebView2") -Recurse -Force
}
$ctlTest = Launch-Cmd $laneTest 240
Report "control testing window=$ctlTest exe=$(Test-Path $exeTest)"
if ($ctlTest -ne "UP") { Fail "control expected=the testing build comes up actual=$ctlTest; the gate below is unmeasured" }

# =====================================================================
# direct: the exe on its own, nothing naming a document
# =====================================================================
Clear-Error-Log $folderRel
$direct = Launch-Exe $exeRel $null 120
Report "direct window=$direct cwd=$elsewhere"
if ($direct -ne "UP") {
    Fail "direct expected=the exe run on its own comes up actual=$direct :: $(Error-Log $folderRel)"
}

# =====================================================================
# ignored: a release build does not read the variable
# =====================================================================
$bogus = Join-Path $work "no-such-document.cmd"
Clear-Error-Log $folderRel
$ignored = Launch-Exe $exeRel $bogus 120
Report "ignored window=$ignored value=$bogus"
if ($ignored -ne "UP") {
    Fail "ignored expected=a release build comes up with NEUTRINO_SCRIPT_PATH set to a file that does not exist actual=$ignored :: $(Error-Log $folderRel)"
}

# =====================================================================
# testing: the same value on a testing build is read, and refuses by name
# =====================================================================
# The other direction. Without this the gate would pass by being absent: a
# driver that read the variable on no tier at all reports `ignored` exactly as
# one that reads it on the right tier does.
Clear-Error-Log $folderTest
$gated = Launch-Exe $exeTest $bogus 60
$gatedLog = Error-Log $folderTest
Report ("testing window=$gated named_the_variable=" +
        $(if ($gatedLog -match "NEUTRINO_SCRIPT_PATH names no file") { "YES" } else { "NO" }))
if ($gated -ne "DOWN") { Fail "testing expected=a testing build reads the variable and refuses actual=window $gated" }
if ($gatedLog -notmatch "NEUTRINO_SCRIPT_PATH names no file") {
    Fail "testing expected=the refusal names the variable actual=$gatedLog"
}

# =====================================================================
# derived: with the document moved away, the exe refuses and says where it looked
# =====================================================================
# The positive control for `direct`. A driver that had found its document some
# other way -- a copy in the app folder, a path baked at compile time, the
# current directory -- would pass `direct` and fail here.
Stop-Apps
$moved = Join-Path $work "ntrelease.moved"
Move-Item $laneRel $moved -Force
Clear-Error-Log $folderRel
$derived = Launch-Exe $exeRel $null 45
$derivedLog = Error-Log $folderRel
Move-Item $moved $laneRel -Force
Report ("derived window=$derived named_both_paths=" +
        $(if (($derivedLog -match "ntrelease\.cmd") -and ($derivedLog -match "ntrelease\.bat")) { "YES" } else { "NO" }))
if ($derived -ne "DOWN") { Fail "derived expected=no document, no window actual=window $derived" }
if ($derivedLog -notmatch "could not find the document") {
    Fail "derived expected=the refusal says the document was not found actual=$derivedLog"
}
if (($derivedLog -notmatch "ntrelease\.cmd") -or ($derivedLog -notmatch "ntrelease\.bat")) {
    Fail "derived expected=the refusal names both paths it looked for actual=$derivedLog"
}

# And back up again, which is what says the refusal was about the document and
# not about anything the four launches above left behind in the app folder.
$again = Launch-Exe $exeRel $null 120
Report "derived restored=$again"
if ($again -ne "UP") { Fail "derived expected=the document back, the exe comes up again actual=$again" }

Stop-Apps
Write-Output "=== standalone: $failures failure(s) ==="
if ($failures -gt 0) { exit 1 }
exit 0
