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
    [string]$AppDir = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

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

function Take-Screenshot($name) {
    try {
        $b = New-Object System.Drawing.Bitmap 1280, 800
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen(0, 0, 0, 0, $b.Size)
        $b.Save("$ScreenshotDir\$name.png", [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose(); $g.Dispose()
    } catch {}
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

function Wait-ForApp() {
    $deadline = (Get-Date).AddSeconds($FirstTimeout)
    do {
        $p = Get-Process -Name $AppName -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { Note "watch pid=$($p.Id) window up"; return $p }
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
    $end = Find-Row $rows "STD-WIN-END"
    if (Find-Row $rows "STD-WIN-CLOSE-PAIR") {
        if ($end) { Note "pair CLOSE page=[$($end.Title -replace '^STD-WIN-END ','')] native=STILL_UP (a title arrived after the call)" }
        else { Note "pair CLOSE page=[no title after the call] native=GONE" }
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
    $proc = Wait-ForApp
    if (-not $proc) { Finish }
    $rec = Record $proc $RunTimeout
}

Check-Apparatus $rec $dwell
switch ($Probe) {
    "geom"  { Analyse-Geom $rec.Rows }
    "doc"   { Analyse-Doc $rec.Rows }
    "win"   { Analyse-Win $rec.Rows }
    "theme" { Analyse-Theme $rec.Rows }
    default { Fail "no analysis for probe '$Probe'" }
}

# After the loop, never inside it.
if (-not $Replay) { Take-Screenshot "std-$Probe" }
Write-Host "--- recorded transitions (ms / title / inner / pos / outer / tick) ---"
foreach ($r in $rec.Rows) {
    Write-Host "$($r.At)`t$($r.Title)`t$($r.Inner)`t$($r.Pos)`t$($r.Outer)`t$($r.Tick)"
}
Finish
