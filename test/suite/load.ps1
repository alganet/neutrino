# load.ps1 - the launch, watched closely enough, on a runner that is busy.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: pwsh -File load.ps1 <replica-1.cmd> <replica-2.cmd> ...
#
# verify-windows used to wait for each of the app's titles in turn, and
# between one wait returning and the next beginning it asserted, reported and
# encoded a full-screen PNG. Measured here under load: that gap ran to about
# three seconds against a state the app holds for one second, so the next
# title was set and gone before anything looked for it, and the wait after it
# spent its whole bound against a process that had finished and exited. Every
# recorded symptom of the "Windows first-window stall" is that.
#
# This is the measurement kept. On an idle runner the old design and the new
# one both pass, so a green windows lane never had anything to say about it;
# under cpus*3 spinners the old one lost a state 3/3 while a 20-second dwell
# passed 3/3 under the same load
# (https://github.com/alganet/neutrino/actions/runs/33033844619). The suite
# samples one process ten times a second and asserts its own slowest turn
# against the dwell it reads out of the artifact -- so what used to be a
# timeout with no account is a number, and this is where that number is taken
# under pressure.
#
# Two replicas, because one run of one job is not a rate -- and that is what
# they were a two-runner matrix for. Sequential here, on one machine: what the
# matrix sampled and this does not is runner-to-runner variance. What it keeps
# is two independent readings, and it keeps them further apart than the matrix
# did -- separate artifacts and separate app directories, so replica 2 cannot
# read a trace replica 1 left. It asserts, so it can fail the lane; the load
# is stopped whatever happens.
#
# This was a `run:` block in the workflow until it was a file; psparse.ps1
# could not see it there, and the artifacts it runs are its arguments now
# rather than names it built for itself.
if ($args.Count -lt 1) { throw "usage: load.ps1 <replica.cmd> ..." }
$env:NEUTRINO_WEBVIEW2_LIB_DIR = $null
$rc = 0
$n = 0
foreach ($given in $args) {
    $n++
    $artifact = (Resolve-Path $given).Path
    $name     = [System.IO.Path]::GetFileNameWithoutExtension($artifact)
    $appdir   = Join-Path (Split-Path -Parent $artifact) $name
    # Its own frames. verify-windows.ps1 names a screenshot after the state it
    # caught, and the core launch runs the same script: left in $HOME every one
    # of these would land on a name something else had already written.
    $shots    = Join-Path $HOME "load-shots-$n"
    New-Item -ItemType Directory -Force -Path $shots | Out-Null
    Write-Output "report: replica $n ($name)"
    $cpus = [Environment]::ProcessorCount
    $spinners = @()
    for ($i = 0; $i -lt $cpus * 3; $i++) {
        $spinners += Start-Process -FilePath "cmd.exe" -PassThru -WindowStyle Hidden `
            -ArgumentList "/c", "for /L %i in (1,0,2) do @rem"
    }
    Write-Output "report: load cpus=$cpus spinners=$($spinners.Count)"
    # Start-Process, not the launcher inline: the batch region STARTs a
    # detached exe which inherits the standard handles, and a pipe on this
    # process would outlive it -- which is how a netinstall step once ran 37
    # minutes against a bound of 20 (PR 28). -WorkingDirectory explicitly,
    # because Start-Process takes the child's directory from
    # [Environment]::CurrentDirectory and not from $PWD.
    Start-Process -FilePath "cmd.exe" -WorkingDirectory (Get-Location).Path `
        -ArgumentList "/c", $artifact -WindowStyle Hidden | Out-Null
    $r = 0
    try {
        & (Join-Path $PSScriptRoot "verify-windows.ps1") -Artifact $artifact -AppDir $appdir `
            -ScreenshotDir $shots *>&1 | ForEach-Object { Write-Output $_ }
        $r = $LASTEXITCODE
    } catch {
        Write-Output "FAIL: verify-windows.ps1 ended by exception: $($_.Exception.Message)"
        $r = 1
    }
    foreach ($s in $spinners) {
        Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue
    }
    # The app's own clock. note() had no channel on this platform at all before
    # this -- a detached winexe process gets NullStream for Console.Error and
    # both console spellings -- so a launch that lost a state said nothing,
    # for want of anywhere to say it.
    $traceLog = Join-Path $appdir "neutrino-trace.log"
    if (Test-Path $traceLog) {
        Write-Output "report: the app's own trace:"
        Get-Content $traceLog | Select-Object -Last 16 | ForEach-Object { Write-Output "report:   $_" }
    } else {
        Write-Output "report: the app wrote no trace at all"
    }
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($r -ne 0) { $rc = $r }
}
exit $rc
