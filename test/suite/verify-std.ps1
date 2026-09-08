# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-std.ps1 - the instrument outside the page, Windows half.
#
# The same probe, the same vocabulary and the same controls as verify-std.sh; a
# reading in an annotation should not need to say which platform wrote it before
# it can be compared. What differs is only the instrument: MainWindowTitle and
# GetWindowRect where the other has xdotool, GetClientRect where it has
# _NET_FRAME_EXTENTS.
#
# It records first and asserts afterwards, which on this platform is not a new
# idea but a rule already paid for: verify-windows.ps1 sampled a one-second
# title with a loop it left to assert, report and encode a full-screen PNG, the
# gap ran to three seconds under load, and four PRs read the result as a product
# stall. Nothing slow goes in the loop.
#
# It never leaves by exception. A verifier that speaks in PASS and FAIL has to
# end that way too, or $ErrorActionPreference unwinds past the step's own log
# assembly and the annotations carry whatever had been printed before it.

param(
    [string]$Probe = "geom",
    [string]$AppName = "",
    [string]$ScreenshotDir = $env:USERPROFILE,
    # Round zero: analyse a record captured earlier, with no window and no
    # engine, so the assertions below get run before they are pushed.
    [string]$Replay = "",
    # Where the launcher compiles and unpacks. Only read when a wait gives up.
    [string]$AppDir = "",
    # What the picture is called, which is not what the probe is called. The
    # shell half carries the whole account of why in its own header; the short
    # version is that decoflip and the theme flip each launch this probe twice
    # and both launches wrote one filename, so the pair was never shipped. A
    # lone launch keeps the name the eye already knows.
    [string]$ShotName = "",
    # The artifact to launch, and the switch that says to launch it. Off by
    # default so every caller that starts the app itself keeps working.
    [string]$Artifact = "",
    # Start the app from here rather than from the step, which is the same fix
    # verify-windows.ps1 carries and for the same reading.
    #
    # This script loads two assemblies and compiles a C# type before it looks
    # for a window, and the app it is watching has been running the whole time.
    # Measured on this lane: the doc probe's first state is held 1500ms and the
    # record opened on it with 2ms to spare on one run and 498ms on another --
    # a margin that is a property of how long Add-Type took, not of anything
    # this project controls. Then the app got faster and the margin went
    # negative: `control ctl was never observed`, on a state the app had
    # performed correctly with nobody watching.
    #
    # A dwell cannot win that. Raising it buys one more runner and one more
    # speed-up takes it back, which is what verify-windows.ps1 says it paid for
    # three times before fixing the order instead. So the order is fixed here
    # too: everything expensive happens first, and the app is started by the
    # process that is about to watch it.
    [switch]$Launch
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
# For Screen.PrimaryScreen: the capture below is of the whole desktop, and
# the desktop's size is a thing to ask for rather than a constant to carry.
Add-Type -AssemblyName System.Windows.Forms

# Set once the window is found, read by Take-Screenshot. Script-scoped because
# the two are called from different places and a parameter would have to be
# threaded through the whole main flow to reach one of them.
$script:shotHwnd = [IntPtr]::Zero

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class StdWinAPI {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

if (-not $AppName) { $AppName = "neutrinostd$Probe" }
if (-not $AppDir) { $AppDir = Join-Path $PSScriptRoot "..\neutrinostd$Probe" }
$FirstTimeout = 240
# Thirteen states at 1500 ms, plus the settles and the fullscreen wait, is over
# twenty seconds before the first window is even counted. Sized to the app
# rather than copied from the probe beside it.
$RunTimeout = if ($Probe -eq "win") { 150 } else { 90 }
$PollMs = 50
$script:Failures = 0

function Note($m) { Write-Host "report: $m" }
function Fail($m) { Write-Host "FAIL: $m"; $script:Failures++ }

function Finish() {
    Note "totals probe=$Probe failures=$script:Failures"
    exit $script:Failures
}

# Lifted out of the artifact, never copied. A suite that samples something
# transient has to check its own slowest turn against the dwell, and a number
# repeated in two files goes stale in one of them and still passes.
function Get-Dwell() {
    $js = Join-Path $PSScriptRoot "..\probe\neutrinostd$Probe.js"
    if (Test-Path -LiteralPath $js) {
        foreach ($line in (Get-Content -LiteralPath $js)) {
            if ($line -match '^var DWELL = (\d+);') { return [int]$Matches[1] }
        }
    }
    Fail "could not read the dwell out of $js"
    return 1500
}

# The whole desktop, and not just the probe's own window.
#
# This cropped to the window for a round. The complaint that got it cropped was
# that every picture carried the runner's wallpaper, its taskbar, the "Windows
# Server 2025 Datacenter / Test Mode" watermark and whatever console happened to
# be open behind the app -- one of them a window of raw JSON, which is what a
# reader's eye lands on first.
#
# All of that is true and none of it is a reason to crop. A sheet is read to
# find out what the machine was doing, and a console full of JSON sitting over
# the probe is a fact about the run, not noise to be framed out; a picture that
# hides it makes the lane look tidier than it was. The window is still in the
# shot, with its frame, which is what the decoration pair compares.
#
# It also drops the fixed 1280x800 this used to grab -- the desktop's real
# bounds are one call away, and a hardcoded size that is wrong on a runner
# quietly crops or letterboxes instead of saying so.
#
# The rect hunt stays, and is now only a wait plus a caption. It is re-resolved
# from the live process rather than trusted from Wait-ForApp, because the handle
# is taken when the window is first seen and the shutter fires much later: four
# of seven captures in the run that added this had a stale handle and fell back
# with "window up" in the same log. Knowing whether the window was actually on
# screen when the shutter fired is the thing worth keeping from it, and the
# normal end of the `win` probe -- which closes its own window on purpose -- is
# the case where the honest answer is no.
function Take-Screenshot($name) {
    try {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $how = "the whole desktop; no window of the probe was up to wait for"
        # StdWinAPI+RECT: the struct is nested inside the class, which is the
        # spelling the two callers below already use.
        $waited = 0
        while ($waited -lt 24) {
            $hwnd = $script:shotHwnd
            $r = New-Object StdWinAPI+RECT
            if (-not ($hwnd -and $hwnd -ne [IntPtr]::Zero -and [StdWinAPI]::GetWindowRect($hwnd, [ref]$r))) {
                $live = Get-Process -Name $AppName -ErrorAction SilentlyContinue |
                        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
                if ($live) { $hwnd = $live.MainWindowHandle; $script:shotHwnd = $hwnd }
            }
            if ($hwnd -and $hwnd -ne [IntPtr]::Zero -and [StdWinAPI]::GetWindowRect($hwnd, [ref]$r)) {
                $rw = $r.Right - $r.Left
                $rh = $r.Bottom - $r.Top
                if ($rw -gt 0 -and $rh -gt 0 -and $rw -le 4096 -and $rh -le 4096) {
                    $how = "the whole desktop, with the probe's window (${rw}x${rh} at $($r.Left),$($r.Top)) on it after $($waited * 250)ms"
                    break
                }
            }
            $waited++
            Start-Sleep -Milliseconds 250
        }
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
        $bmp.Save("$ScreenshotDir\$name.png", [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose(); $g.Dispose()
        Write-Host "  shot: $how ($($b.Width)x$($b.Height) at $($b.X),$($b.Y))"
    } catch {
        Write-Host "  shot: the capture threw: $($_.Exception.Message)"
    }
}

# What the launcher had to say when a wait gives up. Written because this
# verifier has already spent a round saying only "no window from
# 'neutrinostdwin' within 240s" -- the cause was a name jsc.exe reserves, the
# app failed to compile, and it had recorded exactly that in a file nothing
# read. A step is only as readable as its least-instrumented failure.
function Report-AppAccount() {
    foreach ($pair in @(@("neutrino-error.log", "the app's own failure"),
                        @("neutrino-trace.log", "the app's own trace"))) {
        $path = Join-Path $AppDir $pair[0]
        if (Test-Path -LiteralPath $path) {
            Note "$($pair[1]):"
            Get-Content -LiteralPath $path | Select-Object -Last 8 |
                ForEach-Object { Note "  $_" }
        } else {
            Note "$($pair[1]): no $($pair[0]) in $AppDir"
        }
    }
    # The residue, not a boolean. "No log in that folder" and "no folder at all"
    # are different failures with different fixes -- one is an app that started
    # and fell over, the other is one that never got as far as making its own
    # directory, which on this platform means the compile refused. That
    # distinction cost a round: the report said only that two logs were absent,
    # and the answer was in which of the two shapes the absence had.
    if (Test-Path -LiteralPath $AppDir) {
        $kids = @(Get-ChildItem -LiteralPath $AppDir -Force -ErrorAction SilentlyContinue)
        Note "app folder exists with $($kids.Count) entr$(if ($kids.Count -eq 1) { 'y' } else { 'ies' })"
        foreach ($k in ($kids | Select-Object -First 8)) { Note "  $($k.Name)" }
    } else {
        Note "app folder $AppDir was never created; the launcher did not reach init"
    }

    # And what did come up, because "no window with this name" and "no window at
    # all" want different fixes.
    $titled = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle })
    if ($titled.Count -eq 0) { Note "no process on this machine has a titled window" }
    foreach ($o in $titled) { Note "  window up: $($o.ProcessName) [$($o.Id)] '$($o.MainWindowTitle)'" }
}

<#
Which of the two Windows engines rendered this launch, and whether it hardened
what the other one hardens.

Both paths are exercised by this suite already and neither said which it was.
That is not an academic gap: the Evergreen path is the one almost every real
machine takes -- the runtime ships with Windows 11 and reached 10 through
Windows Update -- while the package path is the fallback for a machine without
one. So the common case was the unlabelled case, and a difference between them
could only be found by someone reading both implementations.

Two readings. Which view came up, printed either way; and, from the same trace,
how many of the settings that path closed. The two halves of the driver now say
that in the same words on purpose, so this compares them rather than asserting
one of them: nine doors on the package path are nine properties on a managed
wrapper, and on the Evergreen path they are spread over five interface
revisions, each a separate QueryInterface. Four of the nine used to be all this
path could reach.

A build with no trace channel is not a failure here. Only a testing build
carries one, and every caller of this file builds with --testing -- but the
netinstall suites reuse the verifier against builds that do not, and an app that
renders correctly is not less correct for being quiet.
#>
function Report-EnginePath() {
    $path = Join-Path $AppDir "neutrino-trace.log"
    if (-not (Test-Path -LiteralPath $path)) {
        Note "engine: no trace in $AppDir, so this build does not say which view rendered"
        return
    }
    $trace = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)
    $which = ""
    $closed = -1
    $wanted = -1
    foreach ($line in $trace) {
        if ($line -match 'loop: (\w+) view ready') { $which = $Matches[1] }
        if ($line -match 'closed (\d+) of (\d+) settings') {
            $closed = [int]$Matches[1]
            $wanted = [int]$Matches[2]
        }
    }
    if (-not $which) {
        Note "engine: the trace never named a view"
        return
    }
    Note "engine: this launch rendered through the $which view"
    if ($closed -lt 0) {
        Fail "engine: the $which view never said how much it hardened; both paths report that in one spelling and a launch that says nothing is a launch nobody can compare"
        return
    }
    if ($closed -eq $wanted) {
        Note "engine: the $which view closed all $wanted settings"
    } else {
        Fail "engine: the $which view closed $closed of $wanted settings; the other Windows path closes all of them, and a promise that holds on one of two paths is a support matrix"
    }
}

function Wait-ForApp() {
    $deadline = (Get-Date).AddSeconds($FirstTimeout)
    do {
        $p = Get-Process -Name $AppName -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) {
            Note "watch pid=$($p.Id) window up"
            $script:shotHwnd = $p.MainWindowHandle
            return $p
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    Fail "no window from '$AppName' within ${FirstTimeout}s"
    Report-AppAccount
    return $null
}

# One turn asks one process for one property and takes two rects in the same
# turn. Geometry has to be sampled *with* the title: a resize is only observable
# while the state that caused it is current, and reading it a turn later reads a
# window that has moved on.
function Record($proc, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $rows = New-Object System.Collections.ArrayList
    $start = Get-Date
    $prev = $start
    $last = $null
    $maxGap = 0
    $turns = 0
    while ((Get-Date) -lt $deadline) {
        $turns++
        $now = Get-Date
        $gap = [int]($now - $prev).TotalMilliseconds
        if ($gap -gt $maxGap) { $maxGap = $gap }
        $prev = $now
        try { $proc.Refresh() } catch { break }
        if ($proc.HasExited) {
            [void]$rows.Add([pscustomobject]@{
                At = [int]($now - $start).TotalMilliseconds
                Title = "<gone>"; Inner = "0x0"; Pos = "0,0"; Outer = "0x0"; Tick = $turns })
            break
        }
        $title = ""
        try { $title = [string]$proc.MainWindowTitle } catch { $title = "" }
        if (-not $title) { $title = "<none>" }
        if ($title -ne $last) {
            $last = $title
            $wr = New-Object StdWinAPI+RECT
            $cr = New-Object StdWinAPI+RECT
            [void][StdWinAPI]::GetWindowRect($proc.MainWindowHandle, [ref]$wr)
            [void][StdWinAPI]::GetClientRect($proc.MainWindowHandle, [ref]$cr)
            [void]$rows.Add([pscustomobject]@{
                At    = [int]($now - $start).TotalMilliseconds
                Title = $title
                Inner = "$($cr.Right - $cr.Left)x$($cr.Bottom - $cr.Top)"
                Pos   = "$($wr.Left),$($wr.Top)"
                Outer = "$($wr.Right - $wr.Left)x$($wr.Bottom - $wr.Top)"
                Tick  = $turns
            })
            if ($title -like "*-END") { break }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return [pscustomobject]@{ Rows = $rows; MaxGap = $maxGap; Turns = $turns }
}

# Find-Row, Prev-Row, Verdict and the five Analyse-* functions are gone.
# They were a second implementation of test/lib/analyse.sh -- the same
# controls over a record with the same columns, and the two files
# cross-referenced each other six times asking a reader to keep them in step.
# One of them carried a check it described as a no-op kept only so the pair
# could not drift, which is the arrangement stating its own price.
#
# The sampler stays here, because GetWindowRect is not xdotool and never will
# be. What crosses is the reading of the record it produced, which is the same
# question on every lane. decoflip.ps1 has ended with `bash test/suite/decodiff.sh`
# for as long as it has existed; this is that, for the larger half.


function Check-Apparatus($rec, $dwell) {
    Note "sampler platform=windows turns=$($rec.Turns) transitions=$($rec.Rows.Count) dwell_ms=$dwell max_turn_gap_ms=$($rec.MaxGap)"
    # The decoration, named, in the spelling verify-std.sh reports it -- so a
    # differential reading either platform's log looks for one line.
    #
    # `via=live` and not `read`: both numbers here come from a rect this file
    # asked Windows for in the turn that read the title, so there is no hint to
    # be absent and no fallback to mistake for a reading. That is a real
    # difference between the platforms and it is what this word carries. x11
    # derives its outer from a property the window manager may simply not set.
    #
    # Only the rows the app had arrived in. This lane finds its window by
    # process and starts recording immediately, so the record opens with
    # `Downloading`, `<none>` and `neutrino` -- states from before the frame
    # settles, and measured: `6x29 0x0 16x39` in one run, where only `16x39` is
    # the window. The frame of a window the app has not arrived in is not the
    # frame anything here is asking about. x11 never showed this because it
    # finds its window by the prefix in the first place.
    $prefix = "STD-" + $Probe.ToUpper() + "-"
    $extents = @()
    foreach ($row in $rec.Rows) {
        if (-not $row.Title.StartsWith($prefix)) { continue }
        if ($row.Inner -match '^(\d+)x(\d+)$') {
            $iw = [int]$Matches[1]; $ih = [int]$Matches[2]
            if ($row.Outer -match '^(\d+)x(\d+)$') {
                $e = "$([int]$Matches[1] - $iw)x$([int]$Matches[2] - $ih)"
                if ($extents -notcontains $e) { $extents += $e }
            }
        }
    }
    if ($extents.Count -eq 0) { Note "sampler extent none via=live" }
    else { Note "sampler extent $($extents -join ' ') via=live" }
    # The same name verify-std.sh emits, and the same choice of turn: the
    # probe's first state, before it moves anything. Pos here is GetWindowRect's
    # Left/Top, which is the frame's outside corner -- the quantity x11 derives
    # by subtracting the reparent offset, arrived at directly.
    $firstPos = "none"
    foreach ($row in $rec.Rows) {
        if ($row.Title.StartsWith($prefix)) { $firstPos = $row.Pos; break }
    }
    Note "sampler framepos $firstPos"
    if ($rec.Rows.Count -lt 2) {
        Fail "the instrument recorded $($rec.Rows.Count) transition(s); it saw no window change at all"
    }
    if ($rec.MaxGap -ge $dwell) {
        Fail "the slowest turn was $($rec.MaxGap)ms against a ${dwell}ms dwell; this run sampled, it did not watch"
    }
}


# ------------------------------------------------------------------------ main

Write-Host "verify-std.ps1: probe=$Probe platform=windows"
$dwell = Get-Dwell
$shotName = if ($ShotName) { $ShotName } else { "std-$Probe" }

if ($Replay) {
    if (-not (Test-Path -LiteralPath $Replay)) { Fail "no record at '$Replay'"; Finish }
    $rows = New-Object System.Collections.ArrayList
    foreach ($line in (Get-Content -LiteralPath $Replay)) {
        if (-not $line.Trim()) { continue }
        $f = $line -split "`t"
        [void]$rows.Add([pscustomobject]@{
            At = [int]$f[0]; Title = $f[1]; Inner = $f[2]; Pos = $f[3]; Outer = $f[4]; Tick = $f[5] })
    }
    $rec = [pscustomobject]@{ Rows = $rows; MaxGap = 0; Turns = $rows.Count }
    Write-Host "verify-std.ps1: replaying $Replay -- apparatus checks are not a measurement here"
} else {
    # -WorkingDirectory explicitly: Start-Process takes the child's directory
    # from [Environment]::CurrentDirectory and not from $PWD.
    if ($Launch) {
        if (-not $Artifact) {
            Fail "-Launch needs -Artifact"
            Finish
        }
        # Two files and both named `.log`, so the lane's sheet step -- which
        # gathers `~/*.log` -- picks up the launcher's account beside this
        # script's. Separate paths because Start-Process refuses to point both
        # redirections at one file.
        $launchLog = Join-Path $ScreenshotDir "launch-$AppName-out.log"
        $launchErr = Join-Path $ScreenshotDir "launch-$AppName-err.log"
        Write-Host "=== Launching $Artifact ==="
        Start-Process -FilePath "cmd.exe" -WorkingDirectory (Get-Location).Path `
            -ArgumentList "/c", $Artifact -WindowStyle Hidden `
            -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr |
            Out-Null
    }
    $proc = Wait-ForApp
    if (-not $proc) { Finish }
    # `win` is photographed here, with its window up, and every other probe
    # after the analysis. That is what the probes do rather than a preference:
    # the window probe's last state is STD-WIN-CLOSE-PAIR, where it closes its
    # own window on purpose because close() is one of the verbs under test. A
    # shutter that fires after the analysis photographs an empty desktop, and
    # std-win.png has been a blank rectangle in every artifact on every lane
    # since that probe landed -- which survived because nobody opens a directory
    # of PNGs to look at one they did not come for.
    if ($Probe -eq "win") { Take-Screenshot $shotName }
    $rec = Record $proc $RunTimeout
}

Check-Apparatus $rec $dwell

# The analysis, in the copy every lane runs.
#
# The record goes to a file and bash reads it, which is the same shape
# decoflip.ps1 has used to reach decodiff.sh since it was written: the exit
# status is the failure count and it adds into this script's.
#
# WriteAllText and not Set-Content, for two reasons that both showed up as
# corrupted columns before they showed up as reasoning. PowerShell writes CRLF,
# and a \r riding on the last field is a sixth column awk cannot parse as a
# tick; and -Encoding utf8 on Windows PowerShell prepends a BOM, which lands in
# the first field of the first row and makes its milliseconds unreadable. An
# explicit UTF8Encoding($false) and an explicit "`n" settle both. UTF-8 and not
# ASCII because a font family name is not necessarily either.
$recPath = Join-Path $ScreenshotDir "std-$Probe-record.tsv"
if (-not (Test-Path -LiteralPath $ScreenshotDir)) {
    New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
}
$recLines = foreach ($r in $rec.Rows) {
    "$($r.At)`t$($r.Title)`t$($r.Inner)`t$($r.Pos)`t$($r.Outer)`t$($r.Tick)"
}
[System.IO.File]::WriteAllText(
    $recPath,
    (($recLines -join "`n") + "`n"),
    (New-Object System.Text.UTF8Encoding($false)))

# Named, so the rows land under the suite a reader knows rather than under
# `analyse` -- harness.sh takes the suite from $0, and $0 there is analyse.sh.
$env:NT_SUITE = "verify-std"
& bash (Join-Path $PSScriptRoot "../lib/analyse.sh") $Probe $recPath
$analysed = $LASTEXITCODE
if ($null -eq $analysed) { $analysed = 0 }
# A bash that could not start is not an analysis that found nothing. 127 is the
# shell's own "command not found" and it would otherwise read as 127 failures,
# which is at least loud; anything below that is counted as what it says.
if ($analysed -eq 127) {
    Fail "could not run test/lib/analyse.sh; bash is not on PATH for this step"
} else {
    $script:Failures += $analysed
}

# Which engine rendered all of that, and how much of the door list it shut.
# After the analysis, because it reads a file the app wrote rather than the
# window it wrote it from -- and a replay has no app folder to read.
if (-not $Replay) { Report-EnginePath }

# After the loop, never inside it -- a full-screen bitmap encode is exactly the
# slow thing this file's header forbids in the sampling loop.
if (-not $Replay -and $Probe -ne "win") { Take-Screenshot $shotName }
Write-Host "--- recorded transitions (ms / title / inner / pos / outer / tick) ---"
foreach ($r in $rec.Rows) {
    Write-Host "$($r.At)`t$($r.Title)`t$($r.Inner)`t$($r.Pos)`t$($r.Outer)`t$($r.Tick)"
}
Finish
