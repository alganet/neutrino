# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# decoflip.ps1 - decoflip.sh's job on the lane that launches from PowerShell.
#
# Usage: decoflip.ps1 -Decorated <app> -Chromeless <app> [-ScreenshotDir <dir>]
#   where each app is a base name, not a path: `neutrinostdgeom`.
#
# This is the sequencing only. The differential is `decodiff.sh` and is *not*
# ported -- bash is on this runner already (the step above this one builds both
# artifacts with it), and a second spelling of the rule that decides what a
# chromeless extent means is exactly the thing that would drift. One file
# decides; two files launch.
#
# What differs from the bash flip is only how a window is found and reaped.
# This lane has no _NET_CLIENT_LIST and no status file: it asks the process
# table, which it can do precisely here because the two halves are two
# artifacts with two names -- `neutrinostdgeom` and `neutrinostdgeom-none`.
# That is a stronger precondition than the bash side can write, not a weaker
# one: there the two halves share a name and only the window prefix separates
# them.
param(
    [string]$Decorated = "neutrinostdgeom",
    [string]$Chromeless = "neutrinostdgeom-none",
    [string]$ScreenshotDir = $env:USERPROFILE
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$logdir = if ($env:NT_FLIP_LOGDIR) { $env:NT_FLIP_LOGDIR } else { $env:USERPROFILE }
$halfFailures = 0
# Whether a half could not be started at all, which is different from a half
# whose verifier failed. Script-scoped rather than returned, for the reason
# Run-Half's own comment gives.
$halfBroken = $false

function Note($m) { Write-Host "report: $m" }

function App-Up($name) {
    $null -ne (Get-Process -Name $name -ErrorAction SilentlyContinue |
               Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
}

function Reap($name) {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# The precondition, not a courtesy sleep -- the same one the bash flip states.
# A window left up by the half before is one the next verifier attaches to, and
# the reading it takes looks exactly like a real one.
function Wait-Gone($name) {
    for ($i = 0; $i -lt 60; $i++) {
        if (-not (App-Up $name)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# The artifact is started with handles of its own, and that is the whole of
# what this function had to learn.
#
# It hung twice. `& $artifact *>&1 | Out-File` hung, and calling it bare hung
# too -- because bare is only safe if this script's stdout is a console, and it
# is not: the step pipes decoflip.ps1 into Tee-Object, so `&` here inherits
# *that* pipe. The launcher spawns a detached process which keeps the write end
# open after cmd exits, Tee-Object never sees EOF, and the pipeline never
# completes. The step it replaces got away with a bare call because its stdout
# went straight to the runner's console, where there is no EOF to wait for.
#
# So the fix is neither the pipe nor the bareness: it is that the child must
# not hold a handle this script's caller is reading. Start-Process with
# explicit redirection gives it files instead, and returns as soon as it has
# spawned.
#
# Nothing is returned either. A PowerShell function returns everything it did
# not capture, so `if (-not (Run-Half ...))` would be testing an array rather
# than a boolean -- hence a script-scoped flag, and a call that is a statement
# rather than a condition.
# $shot is what the picture is called. It is passed rather than derived from the
# tag because `deco-b` says nothing to a reader looking at a sheet, and because
# both halves wrote one filename until this round -- so the decorated window,
# which is the control this whole differential rests on, was never shipped.
function Run-Half($app, $tag, $shot) {
    $artifact = Join-Path $root "test\$app.cmd"
    if (-not (Test-Path $artifact)) {
        Write-Host "FAIL: no artifact at '$artifact'; the $tag half cannot run"
        $script:halfBroken = $true
        return
    }
    # Launched by the verifier rather than here, which is the same ordering
    # fix verify-std.ps1's own -Launch header describes: that script loads two
    # assemblies and compiles a type before it looks for a window, and an app
    # started first spends all of it running unwatched. Doing it there also
    # keeps the two log files this used to write, under the verifier's naming.
    & (Join-Path $root "test\verify-std.ps1") -Probe geom -AppName $app `
        -ScreenshotDir $ScreenshotDir -ShotName "frame-$shot" `
        -Launch -Artifact $artifact *>&1 |
        Tee-Object -FilePath (Join-Path $logdir "deco-$tag.log") | Out-Null
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = 0 }
    Reap $app
    Note "half $tag artifact=$app verifier=$rc"
    $script:halfFailures += $rc
}

Write-Host "decoflip.ps1: decorated=$Decorated chromeless=$Chromeless platform=windows"

foreach ($n in @($Decorated, $Chromeless)) {
    if (App-Up $n) {
        Write-Host "FAIL: '$n' was already up before the first half started"
        Write-Host "report: totals decoflip failures=1"
        exit 1
    }
}

# Decorated first, because it is the control: a chromeless extent of zero means
# nothing without a non-zero one beside it, and a half that wedges having run
# first would publish the reading and never the thing that makes it evidence.
Run-Half $Decorated "a" "decorated"
if ($halfBroken) { Write-Host "report: totals decoflip failures=1"; exit 1 }

if (-not (Wait-Gone $Decorated)) {
    Write-Host "FAIL: the decorated half is still up; the chromeless half would read it"
    Write-Host "report: totals decoflip failures=1"
    exit 1
}
Note "the decorated half's window is gone; the chromeless half may start"

Run-Half $Chromeless "b" "chromeless"
if ($halfBroken) { Write-Host "report: totals decoflip failures=1"; exit 1 }

& bash (Join-Path $root "test/decodiff.sh") `
    (Join-Path $logdir "deco-a.log") (Join-Path $logdir "deco-b.log")
$diffFailures = $LASTEXITCODE
if ($null -eq $diffFailures) { $diffFailures = 0 }

Note "totals decoflip halves=$halfFailures differential=$diffFailures"
exit ($halfFailures + $diffFailures)
