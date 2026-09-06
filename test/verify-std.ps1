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
if (-not $AppDir) { $AppDir = Join-Path $PSScriptRoot "neutrinostd$Probe" }
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
    $js = Join-Path $PSScriptRoot "neutrinostd$Probe.js"
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

function Find-Row($rows, $prefix) {
    foreach ($r in $rows) { if ($r.Title -like "$prefix*") { return $r } }
    return $null
}

# The row immediately before a named one. Every native-call verdict is a
# comparison against the state the previous call left, not against the window's
# opening geometry -- four calls in a row each need their own before-picture.
function Prev-Row($rows, $prefix) {
    $prev = $null
    foreach ($r in $rows) {
        if ($r.Title -like "$prefix*") { return $prev }
        $prev = $r
    }
    return $null
}

# What one native call did, said in the two words that matter. "The call
# returned without throwing" is the page's half and is already in the title.
function Verdict($before, $after) {
    if (-not $after) { return "UNOBSERVED" }
    if ($before -eq $after) { return "NOOP" }
    return "EFFECTIVE"
}

function Analyse-Win($rows) {
    $names = @()
    foreach ($r in $rows) { $names += ($r.Title -split ' ')[0] }
    Note "win sequence: $($names -join ' ')"

    foreach ($st in @("EXIST", "DESC", "OVR", "OPEN", "APPREGION", "GONE")) {
        $r = Find-Row $rows "STD-WIN-$st-SELF"
        if ($r) { Note "self $st $($r.Title -replace "^STD-WIN-$st-SELF ",'')" }
    }

    # window.open, and the one shape of it the page can answer for. What an
    # external url does is not askable from inside the document -- parse.sh
    # asserts that half against the built preload with no engine. The
    # no-argument call is the launcher's own no-op, and every shape must leave
    # the document where it was. verify-std.sh carries the same two branches;
    # one spelling changed in two verifiers is one change.
    $op = Find-Row $rows "STD-WIN-OPEN-SELF"
    if (-not $op) {
        Fail "control open: STD-WIN-OPEN-SELF was never observed"
    } else {
        $on = ""
        if ($op.Title -match ' noargs=(\S+)') { $on = $Matches[1] }
        if ($on -eq "null/same") {
            Note "control open noargs=$on verdict=NOOP"
        } elseif ($on -eq "") {
            Fail "control open: STD-WIN-OPEN-SELF carried no noargs reading"
        } else {
            Fail "control open noargs=$on, wanted null/same; window.open() is not the launcher's on this lane"
        }
        foreach ($v in @("blank", "self")) {
            $ov = ""
            if ($op.Title -match " $v=(\S+)") { $ov = $Matches[1] }
            if ($ov -like "*/CHANGED") {
                Fail "control open $v=$ov; a call meant to open a window took this document somewhere"
            } elseif ($ov -ne "") {
                Note "control open $v=$ov (the engine's own, left alone)"
            }
        }
    }

    # The four. Before the launcher wrote over these, all four read NOOP on all
    # four engines. They are the shipped API now, so a NOOP here is a regression
    # and the control below says so.
    $movedAny = 0
    foreach ($st in @("RT", "RZ", "MT", "MV")) {
        $r = Find-Row $rows "STD-WIN-$st-PAIR"
        if (-not $r) { Fail "STD-WIN-$st-PAIR was never observed"; continue }
        $p = Prev-Row $rows "STD-WIN-$st-PAIR"
        if ($st -eq "RT" -or $st -eq "RZ") { $v = Verdict $p.Inner $r.Inner }
        else { $v = Verdict $p.Pos $r.Pos }
        if ($v -eq "EFFECTIVE") { $movedAny++ }
        Note "pair $st page=[$($r.Title -replace "^STD-WIN-$st-PAIR ",'')] native $($p.Inner)@$($p.Pos) -> $($r.Inner)@$($r.Pos) verdict=$v"
    }

    $fs = Find-Row $rows "STD-WIN-FS1-PAIR"
    if ($fs) {
        $p = Prev-Row $rows "STD-WIN-FS1-PAIR"
        Note "pair FS1 page=[$($fs.Title -replace '^STD-WIN-FS1-PAIR ','')] native $($p.Inner) -> $($fs.Inner) verdict=$(Verdict $p.Inner $fs.Inner)"
    } else { Fail "STD-WIN-FS1-PAIR was never observed" }

    # close is the one phase whose answer is an absence. The page's `closed`
    # flag is its own account and the engine may set it optimistically; what
    # says the window went is the record ending, and both are printed rather
    # than one standing in for the other.
    #
    # STILL_UP is a failure and used to be a note. The probe waits 1200 ms after
    # the call before it writes STD-WIN-END, so a title that arrives is a window
    # that was still there more than a second after being told to go -- not a
    # race, and not something a slow lane produces. It was a note while nothing
    # had ever been seen to survive the call, and what that cost is the reading
    # nobody took: `close()` is in the README as one of the six verbs an app
    # drives its window with, and a lane where it does nothing would have passed
    # this suite green.
    $end = Find-Row $rows "STD-WIN-END"
    if (Find-Row $rows "STD-WIN-CLOSE-PAIR") {
        if ($end) {
            Fail "pair CLOSE page=[$($end.Title -replace '^STD-WIN-END ','')] native=STILL_UP; the window was still up 1200ms after close() and reported through itself to say so"
        } else {
            Note "pair CLOSE page=[no title after the call] native=GONE"
        }
    } else { Fail "STD-WIN-CLOSE-PAIR was never observed" }

    # Control one, and it moved with the thing it is about. It used to be a
    # separate call known to work -- `neutrino.window.resize`, which no longer
    # exists -- there to tell "the engine refused" from "the window is dead".
    # Those are now one call, so the question is asked of it directly: a run in
    # which none of the four moved the window is a dead window or an override
    # that did not take, and both are regressions rather than readings.
    if ($movedAny -gt 0) {
        Note "control the standard spellings move the window: $movedAny/4 EFFECTIVE"
    } else {
        Fail "control none of resizeTo/resizeBy/moveTo/moveBy moved the window; either the override did not take or the window is dead, and this run measured neither"
    }

    # Control two: the descriptors mean something. A reader that answers the
    # same for a property this file defined and for one the spec makes
    # unforgeable is a reader whose every other answer is void.
    $d = Find-Row $rows "STD-WIN-DESC-SELF"
    $own = ""; $forged = ""
    if ($d -and $d.Title -match 'CTLown=(\S+)') { $own = $Matches[1] }
    if ($d -and $d.Title -match 'CTLforged=(\S+)') { $forged = $Matches[1] }
    if ($own -and $forged -and $own -ne $forged) {
        Note "control descriptors own=$own forged=$forged verdict=DISTINGUISHED"
    } else {
        Fail "control descriptors own=$own forged=$forged; the reader cannot tell them apart"
    }
}

# The engine half of the fonts delivery, and the twin of analyse_font in
# verify-std.sh. Five controls, mirroring Analyse-Theme's one for one.
#
# This lane has been building neutrinostdfont.cmd and never running it, because
# there was no `font` arm here to run it under. That is the gap this closes: the
# Windows reader is the one that reads SystemFonts on a clock, and until now
# nothing on this platform had ever looked at what it delivered.
function Analyse-Font($rows) {
    $names = @()
    foreach ($r in $rows) { $names += ($r.Title -split ' ')[0] }
    Note "font sequence: $($names -join ' ')"

    $map = @{ "CTL" = "engine"; "KW-A" = "keywords-a"; "KW-B" = "keywords-b";
              "GEN" = "generics"; "UNIT" = "units";
              "NT-A" = "delivered"; "NT-B" = "agreement" }
    foreach ($k in @("CTL", "KW-A", "KW-B", "GEN", "UNIT", "NT-A", "NT-B")) {
        $r = Find-Row $rows "STD-FONT-$k"
        if ($r) { Note "self $($map[$k]) $($r.Title -replace "^STD-FONT-$k ",'')" }
    }

    $ctl = Find-Row $rows "STD-FONT-CTL"
    if (-not $ctl -or $ctl.Title -notmatch 'eng=') {
        Fail "control font: STD-FONT-CTL was never observed, so nothing below is a reading"
    } else { Note "control font: the probe ran and named its engine" }

    # Whether the lane read a toolkit at all. Every comparison under this is
    # void on a lane that did not.
    $nta = Find-Row $rows "STD-FONT-NT-A"
    $src = ""
    if (-not $nta) { Fail "control fonts: STD-FONT-NT-A was never observed" }
    elseif ($nta.Title -match 'fonts=null') {
        Fail "control fonts: this lane read no toolkit, so every comparison here is void"
    } else {
        Note "control fonts read=YES"
        if ($nta.Title -match ' source=(\S+)') { $src = $Matches[1] }
    }

    # The two deliveries: the object the preload handed the page against the
    # custom properties the launcher wrote into the document's stylesheet.
    $ntb = Find-Row $rows "STD-FONT-NT-B"
    if (-not $ntb) { Fail "control delivery: STD-FONT-NT-B was never observed" }
    elseif ($ntb.Title -match 'fonts=null') { Note "control delivery not_asked: this lane read no fonts" }
    elseif ($ntb.Title -match 'match=15/15') { Note "control delivery match=15/15 verdict=DELIVERED" }
    else {
        $m = ""
        if ($ntb.Title -match ' (match=\S+)') { $m = $Matches[1] }
        Fail "control delivery: the custom properties and neutrino.fonts disagree -- $m"
    }

    # And the documented idiom on a lane that read nothing: a property the
    # launcher never sets must reach the generic named beside it.
    if ($ntb -and $ntb.Title -match ' fallback=(\S+)') {
        $fb = $Matches[1]
        if ($fb -eq "monospace") {
            Note "control fallback var(--neutrino-font-nosuchrole, monospace)=monospace verdict=RESOLVED"
        } elseif ($fb -eq "notasked") {
            Note "control fallback not_asked"
        } else {
            Fail "control fallback: an unset property reached '$fb' rather than the generic beside it"
        }
    }

    # The engine's own reading of the same desktop, where it has one. WebView2
    # is not such an engine -- Chromium's system font keywords are constants,
    # measured 16px Arial against a toolkit saying 12px -- so this lane is
    # exempt by name with the reason printed, the way Analyse-Theme exempts qt.
    if ($src -ne "gtk") {
        Note "control agree not_asked: this engine's system font keywords are not the desktop's"
    } elseif ($ntb -and $ntb.Title -match 'delta:([0-9.]+)') {
        $d = [double]$Matches[1]
        if ($d -le 1) { Note "control agree delta:$d verdict=AGREED" }
        else { Fail "control agree: the launcher and the engine read different sizes off one desktop -- delta:$d" }
    } else {
        Fail "control agree: no reading on a lane that has one"
    }

    $kwb = Find-Row $rows "STD-FONT-KW-B"
    if ($kwb -and $kwb.Title -match ' (identical=\S+)') { Note "self roles $($Matches[1])" }
    else { Note "self roles unread" }

    if (-not (Find-Row $rows "STD-FONT-END")) {
        Fail "control font: STD-FONT-END was never observed, so the probe stopped early"
    }
}

function Analyse-Theme($rows) {
    $names = @()
    foreach ($r in $rows) { $names += ($r.Title -split ' ')[0] }
    Note "theme sequence: $($names -join ' ')"

    $map = @{ "A" = "palette"; "B" = "cssnames"; "V" = "delivery"; "P" = "customprops"; "F" = "fonts" }
    foreach ($k in @("A", "B", "V", "P", "F")) {
        $r = Find-Row $rows "STD-THEME-$k-SELF"
        if ($r) { Note "self $($map[$k]) $($r.Title -replace "^STD-THEME-$k-SELF ",'')" }
    }

    # Everything here is the document's own account: no window property carries
    # a computed colour, so there is no outside half and none is pretended.
    # What keeps it honest is the two controls, and the palette flip in the
    # round after this -- a value that moves with the desktop is the desktop's.
    $a = Find-Row $rows "STD-THEME-A-SELF"
    if (-not $a) { Fail "control palette: STD-THEME-A-SELF was never observed" }
    elseif ($a.Title -match 'nsrc=null') { Fail "control palette: this lane read no toolkit, so every comparison here is void" }
    else { Note "control palette read=YES" }

    # The scheme, read twice on one launch: `prefers-color-scheme` is the
    # engine's answer and `neutrino.theme.scheme` is the launcher's, taken from
    # the luminance of the palette the toolkit handed over. An app may branch on
    # either, and a desktop where they disagree hands it a dark palette under a
    # light media query. Neither side is a constant, so one launch settles it.
    if ($a -and $a.Title -match ' mq=(\S+)' ) {
        $mq = $Matches[1]
        $sc = ""
        if ($a.Title -match ' nscheme=(\S+)') { $sc = $Matches[1] }
        $sr = ""
        if ($a.Title -match ' nsrc=(\S+)') { $sr = $Matches[1] }
        # `qt` is exempt by name; verify-std.sh's analyse_theme carries the
        # reason and the condition that retires it. This file never runs that
        # lane -- Windows has no QtWebEngine here -- and the branch is kept
        # anyway, because one spelling changed in two verifiers is one change,
        # and a verifier that has quietly stopped matching its twin is how step
        # 1 lost the only lane where everything worked.
        if ($sc -eq "null" -or $sc -eq "") {
            # The palette control above has already failed this run.
        } elseif ($mq -eq "unsupported" -or $mq -eq "threw" -or $mq -eq "none") {
            Note "control scheme not_asked mq=$mq; this engine states no preference"
        } elseif ($mq -eq $sc) {
            Note "control scheme mq=$mq neutrino=$sc verdict=AGREED"
        } elseif ($sr -eq "qt") {
            Note "control scheme KNOWN qt mq=$mq against neutrino=$sc; QtWebEngine does not follow the toolkit palette and QStyleHints::colorScheme is Qt 6.8+, so this lane has no knob -- delete this exemption when a runner has one"
        } else {
            Fail "control scheme mq=$mq against neutrino=$sc; the page's media query and the palette it was handed disagree about this desktop"
        }
    }

    $b = Find-Row $rows "STD-THEME-B-SELF"
    if (-not $b) { Fail "control unknown-keyword: STD-THEME-B-SELF was never observed" }
    elseif ($b.Title -match 'control=UNSUP') { Note "control unknown-keyword=UNSUP verdict=DISTINGUISHED" }
    else { Fail "control unknown-keyword resolved to a colour; every UNSUP below it is the instrument, not the engine" }

    # The delivery. Two page readings, and the assertion is that they agree:
    # the palette an app gets from `neutrino.theme` came through the preload,
    # and the palette it gets from `var(--neutrino-Canvas)` came through a
    # stylesheet the launcher put in the document. Different mechanisms, one
    # measurement, and an app is entitled to either.
    $v = Find-Row $rows "STD-THEME-V-SELF"
    if (-not $v) { Fail "control delivery: STD-THEME-V-SELF was never observed" }
    elseif ($v.Title -match ' pal=null ') { Note "control delivery not_asked: this lane read no toolkit" }
    elseif ($v.Title -match ' match=7/7 ') { Note "control delivery match=7/7 verdict=DELIVERED" }
    else { Fail "control delivery $($v.Title -replace '^.* match=','match=') -- the properties and neutrino.theme disagree" }

    # And the reason the properties are named for the keywords. A name the
    # launcher never sets has to fall through to the engine's own system
    # colour; a keyword the engine cannot resolve would leave the declaration
    # alone instead, and the page would style itself from what it inherited.
    if ($v -and $v.Title -match ' fallback=(\S+) canvas=(\S+)') {
        $fb = $Matches[1]
        $ca = $Matches[2]
        if ($fb -eq $ca -and $fb -ne "UNSUP" -and $fb -ne "threw") {
            Note "control fallback var(--neutrino-absent, Canvas)=$fb Canvas=$ca verdict=RESOLVED"
        } else {
            Fail "control fallback var(--neutrino-absent, Canvas)=$fb against Canvas=$ca; an absent property does not reach the engine's own colour on this lane"
        }
    }

    if (-not (Find-Row $rows "STD-THEME-CTL")) { Fail "control ctl was never observed; the instrument read no window" }
    if (-not (Find-Row $rows "STD-THEME-END")) { Fail "control end was never observed; the app did not finish its sequence" }
}

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

function Analyse-Geom($rows) {
    $a = Find-Row $rows "STD-GEOM-A-PAIR"
    $b = Find-Row $rows "STD-GEOM-B-PAIR"
    $c = Find-Row $rows "STD-GEOM-C-PAIR"
    $r = Find-Row $rows "STD-GEOM-R-SELF"

    if (-not $a) { Fail "STD-GEOM-A-PAIR was never observed" }
    if (-not $b) { Fail "STD-GEOM-B-PAIR was never observed" }
    if (-not $c) { Fail "STD-GEOM-C-PAIR was never observed" }

    if ($a) { Note "pair A page=[$($a.Title -replace '^STD-GEOM-A-PAIR ','')] native inner=$($a.Inner) outer=$($a.Outer) pos=$($a.Pos)" }
    if ($b) { Note "pair B page=[$($b.Title -replace '^STD-GEOM-B-PAIR ','')] native inner=$($b.Inner) outer=$($b.Outer) pos=$($b.Pos)" }
    if ($c) { Note "pair C page=[$($c.Title -replace '^STD-GEOM-C-PAIR ','')] native inner=$($c.Inner) outer=$($c.Outer) pos=$($c.Pos)" }
    if ($r) { Note "self $($r.Title -replace '^STD-GEOM-R-SELF ','')" }

    # The one -SELF reading this file asserts; the shell verifier carries the
    # reasoning. In short: whether the API was in scope at the app's own first
    # statement is the one question no instrument outside the document can be
    # pointed at, and pages/demo.js stopped polling for the API on the strength
    # of the answer.
    if (-not $r) {
        Fail "control STD-GEOM-R-SELF was never observed; readiness went unmeasured this run"
    } elseif ($r.Title -match 'nt0=yes') {
        Note "control the API was in scope at the app's first statement (nt0=yes)"
    } else {
        $seen = if ($r.Title -match 'nt0=(\S+)') { $Matches[1] } else { '<absent>' }
        Fail "control nt0=$seen; window.neutrino was not in scope at the app's first statement, and pages/demo.js no longer waits for it"
    }

    # This driver sets ClientSize where macOS sets the outer frame and the two
    # GTK lanes set the toplevel. The pair of numbers here is the half of that
    # disagreement this platform contributes.
    if ($b) { Note "sizing req=640x480 native_inner=$($b.Inner) native_outer=$($b.Outer)" }
    if ($c) { Note "moving req=120,90 native_pos=$($c.Pos)" }

    # The positive control. Without it every "the page's number is wrong"
    # reading above is equally explained by a window that never moved.
    if ($a -and $b -and $a.Inner -ne $b.Inner) {
        Note "control resize A->B inner $($a.Inner) -> $($b.Inner) verdict=MOVED"
    } else {
        Fail "control resize A->B inner $($a.Inner) -> $($b.Inner); the instrument saw no size change"
    }
    if ($b -and $c -and $b.Pos -ne $c.Pos) {
        Note "control move B->C pos $($b.Pos) -> $($c.Pos) verdict=MOVED"
    } else {
        Fail "control move B->C pos $($b.Pos) -> $($c.Pos); the instrument saw no position change"
    }
}

function Analyse-Doc($rows) {
    $ctl = Find-Row $rows "STD-DOC-CTL"
    $end = Find-Row $rows "STD-DOC-END"
    $rb = Find-Row $rows "STD-DOC-RB-SELF"
    $d1 = Find-Row $rows "STD-DOC-DOM1"
    $d2 = Find-Row $rows "STD-DOC-DOM2"

    $names = @()
    foreach ($r in $rows) { $names += ($r.Title -split ' ')[0] }
    Note "doc sequence: $($names -join ' ')"
    if ($rb) { Note "self $($rb.Title -replace '^STD-DOC-RB-SELF ','')" }

    # The early shell, asked for at the app's first statement.
    #
    # An app's markup is included into the document by the assembler so that it
    # is in the first paint, and the whole point of that is an app that can read
    # it. Four lanes got that from their engine and Windows did not: its one
    # pre-navigation hook runs before the parser has produced anything, so
    # `getElementById` answered null on the first line and an app written the way
    # the other four allow failed silently on this one. It shipped in the sample
    # app on the download page, where the Close button did nothing on Windows.
    # So this is an assertion and not a note: `body0=yes` is the promise, and the
    # lane that cannot keep it is the lane that has to say so.
    $b0 = ""
    if ($rb -and $rb.Title -match ' body0=(\S+)') { $b0 = $Matches[1] }
    if ($b0 -eq "yes") {
        Note "control the early shell was on the page at the app's first statement (body0=yes)"
    } else {
        Fail "control body0=$(if ($b0) { $b0 } else { '<absent>' }); document.body was not there when the app's first statement ran, so an app cannot read its own markup on this lane"
    }

    # The name the window came up wearing, before the app wrote anything. The
    # launcher puts the build's title into the document, so this is also the
    # first title-changed signal of the launch and it has to be a no-op. A note
    # and not an assertion: this loop starts when the window appears, and a lane
    # slow to hand the recorder its first read would be reporting its own
    # scheduling.
    $opened = if ($rows.Count -gt 0) { $rows[0].Title } else { $null }
    Note "opened native=[$(if ($opened) { $opened } else { '<nothing recorded>' })]"

    # The change this suite exists for. Both writes are plain assignments to
    # document.title and both have to reach the native window; a lane where they
    # do not is a lane whose title hook is not connected.
    #
    # On this lane there is a second reading behind the first. Where the
    # WebMessageReceived subscription does not take, the host polls
    # DocumentTitle and the title *is* the wire -- the marker is what separates
    # a record from a name there, and the transport on the self line above says
    # which case this run is.
    if ($d1) { Note "pair dom1 native=seen" } else { Fail "pair dom1 native=absent; an assignment to document.title did not reach the window" }
    if ($d2) { Note "pair dom2 native=seen" } else { Fail "pair dom2 native=absent; an assignment to document.title did not reach the window" }

    # And the two the gate refuses, asked as one question: what the window was
    # showing after them. DOM2 is the last title that may reach it, so the next
    # recorded state has to be the report at the end of the sequence.
    if ($d2) {
        $after = $null
        $seen = $false
        foreach ($r in $rows) {
            if ($seen) { $after = $r.Title; break }
            if ($r.Title -like "STD-DOC-DOM2*") { $seen = $true }
        }
        if (-not $after) {
            Fail "pair refused after_dom2_native=[nothing recorded]; the sequence stopped at DOM2"
        } elseif ($after -like "STD-DOC-RB-SELF*") {
            Note "pair refused after_dom2_native=[held DOM2 through both]"
        } else {
            Fail "pair refused after_dom2_native=[$after]; the window took a title the gate refuses"
        }
    } else {
        Note "pair refused not_asked: no DOM write reached the window to hold"
    }

    if ($ctl) { Note "control ctl observed=YES" } else { Fail "control ctl was never observed; the instrument read no window" }
    if ($end) { Note "control end observed=YES" } else { Fail "control end was never observed; the app did not finish its sequence" }
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
switch ($Probe) {
    "geom"  { Analyse-Geom $rec.Rows }
    "doc"   { Analyse-Doc $rec.Rows }
    "win"   { Analyse-Win $rec.Rows }
    "theme" { Analyse-Theme $rec.Rows }
    "font"  { Analyse-Font $rec.Rows }
    default { Fail "no analysis for probe '$Probe'" }
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
