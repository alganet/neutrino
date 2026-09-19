# warm-windows.ps1 - the WebView2 runtime, started once before anything is timed.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: pwsh -File warm-windows.ps1 <app.cmd built --testing>
#
# Best-effort: if the warm-up itself stalls it still triggered the runtime
# init, and the real verify keeps its own bound, so this never fails the lane
# -- the row that runs it is `soft`, and it exits 0 whatever it finds. No pipe
# on the launcher: the batch STARTs a detached exe and exits, and a pipe would
# outlive it (PR 20/28).
#
# This was a `run:` block in the workflow, which is the one language a
# workflow cannot check: psparse.ps1 reads every .ps1 in the tree before any
# of them runs and could not see a script that existed only as a step.
param([string]$Artifact = "")
if (-not $Artifact) { throw "usage: warm-windows.ps1 <app.cmd>" }
$full = (Resolve-Path $Artifact).Path
$name = [System.IO.Path]::GetFileNameWithoutExtension($full)

$p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $full -PassThru -WindowStyle Hidden `
    -WorkingDirectory (Get-Location).Path
$i = 0
for (; $i -lt 180; $i++) {
    if (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "LOADERS*" }) { break }
    Start-Sleep -Seconds 1
}
$state = if ($i -lt 180) { 'UP' } else { 'DOWN' }
Write-Output "warm: window=$state after ${i}s"
# Annotate only the miss: a warm-up that came up is the quiet case and a
# warning every green run is noise. A DOWN means the runtime did not warm and
# the real verify is about to run cold -- worth surfacing.
if ($state -eq 'DOWN') { Write-Output "::warning title=warm::warm-up window never came up in ${i}s" }

# Whether the browser actually got the switches this build sets, read off the
# process table rather than inferred from a clock.
#
# WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS is documented as the runtime's
# variable, but the Evergreen path bypasses WebView2Loader.dll and calls the
# runtime's own entry point -- so whether the variable is read by the
# component this build still uses is a question about someone else's code,
# and a timing delta cannot answer it. A command line either carries
# `--no-first-run` or it does not. Reported and not asserted while it is the
# first reading; it becomes an assertion once there is a measured value to
# hold it to.
$browsers = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue)
$carrying = @($browsers | Where-Object { $_.CommandLine -like "*--no-first-run*" })
Write-Output "report: browser processes=$($browsers.Count) carrying our arguments=$($carrying.Count)"
if ($carrying.Count -gt 0) {
    $cl = $carrying[0].CommandLine
    Write-Output "report:   $($cl.Substring(0, [Math]::Min(220, $cl.Length)))"
} elseif ($browsers.Count -gt 0) {
    $cl = $browsers[0].CommandLine
    Write-Output "report:   none carried them; one command line was:"
    Write-Output "report:   $($cl.Substring(0, [Math]::Min(220, $cl.Length)))"
}

# And what the launch spent, phase by phase, which this is the only place on
# the lane that can say. It is a --testing build, so the trace channel exists
# -- the core launch is a release build where trace is an empty function --
# and it is the one app here that runs with nothing else loading the machine,
# so the numbers are the launch's own rather than the runner's. Reported and
# not asserted: what a cold WebView2 costs on a four-cpu runner is not this
# project's to hold to a number, and a threshold nobody can defend is a red
# lane nobody believes. What it is for is the shape -- how much of a launch is
# before the window, and how much is the browser starting behind it.
$trace = Join-Path (Join-Path (Split-Path -Parent $full) $name) "neutrino-trace.log"
if (Test-Path $trace) {
    Write-Output "report: the startup path, unloaded:"
    Get-Content $trace | Select-Object -First 24 | ForEach-Object { Write-Output "report:   $_" }
} else {
    Write-Output "report: the warm-up wrote no trace"
}
exit 0
