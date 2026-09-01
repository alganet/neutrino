# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-windows.ps1 - External test verifier for Windows

param(
    [string]$ScreenshotDir = $env:USERPROFILE,
    # The neutrinotest artifact and the folder it compiles and unpacks into.
    # Default to this script's own dir, which is where the standalone windows
    # lane builds and runs `test\neutrinotest.cmd`. The netinstall e2e installs
    # the same app into a temp HOME and runs it from there, so it passes those
    # in: the WebView2 package sits beside the exe, wherever the exe is.
    [string]$Artifact = (Join-Path $PSScriptRoot "neutrinotest.cmd"),
    [string]$AppDir = (Join-Path $PSScriptRoot "neutrinotest"),
    # The process to watch. Derived from the artifact, because the wait below
    # used to name `neutrinotest` outright and the probe lanes launch the same
    # verifier against a build with a different name. Both callers that exist
    # today install an app called neutrinotest, so this is the value they were
    # already getting.
    [string]$AppName = [System.IO.Path]::GetFileNameWithoutExtension($Artifact)
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# Set once the window is found, read by Take-Screenshot, which runs later and
# re-resolves it if it has gone stale. Declared here so the capture works even
# when it happens before Wait-ForApp has run.
$script:shotHwnd = [IntPtr]::Zero

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinAPI {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

# One budget, covering the window and everything the app does in it. This app
# folder is cold: the Windows driver downloads and unpacks the pinned WebView2
# package before CoreWebView2 exists, and all of that happens *after* the Form
# is on screen and before the page can set a title. The two suites beside this
# one already budget for it -- appcache.ps1 waits 180 seconds on its first
# launch and says why, verify-offline.ps1 waits 240.
#
# It used to be two, a long one for the first title and 60 seconds for each
# scripted step after it. That shape is gone with the waits it belonged to:
# there is one sampling loop now, so there is one deadline, and a step that is
# never reached is a missing sample rather than a wait that expires. Which also
# means this number stopped being interesting -- raising it was the wrong fix
# twice, at 120 and again at 240, because nothing that was waiting was ever
# going to arrive.
$FirstTimeout = 240
$PollInterval = 500
# The sampler's turn. Ten looks a second against a state the app holds for one,
# so a state has to be missed ten times over before it is lost -- and the suite
# asserts the slowest turn it actually managed rather than trusting this number.
$SampleInterval = 100
$Failures = 0

New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null

# --- The watch -------------------------------------------------------------
#
# Diagnostics, not assertions: every line here is a `report:`.
#
# What a failure of this suite needs to say, and could not before: how closely
# the app was actually being watched, whether it was still there, and whether
# the engine ever came up. A wait that ended at its bound used to be the whole
# account, and four different things produce it -- the view never got a
# document, the page's timers were throttled, the app died, or it did
# everything right and nobody was looking. The last of those is what this suite
# was measured doing.
$script:WatchPid = 0
$script:WatchStart = $null
$script:WatchPolls = New-Object System.Collections.ArrayList
$script:WatchGoneAt = $null
$script:WatchCpu = -1

function Watch-Elapsed {
    if (-not $script:WatchStart) { return 0 }
    return [int]((Get-Date) - $script:WatchStart).TotalMilliseconds
}

function Report-Watch($what) {
    $n = $script:WatchPolls.Count
    if ($n -gt 0) {
        $sorted = @($script:WatchPolls | Sort-Object)
        $sum = ($script:WatchPolls | Measure-Object -Sum).Sum
        Write-Host ("report: watch[$what] turns={0} turn_ms min={1} med={2} max={3} sum={4}" -f `
            $n, $sorted[0], $sorted[[int]($n / 2)], $sorted[$n - 1], $sum)
    } else {
        Write-Host "report: watch[$what] no turns recorded"
    }
    $alive = $false
    if ($script:WatchPid) {
        $alive = [bool](Get-Process -Id $script:WatchPid -ErrorAction SilentlyContinue)
    }
    $gone = "-"
    if ($script:WatchGoneAt) { $gone = "$($script:WatchGoneAt)ms" }
    # cpu_s separates a process sitting in the driver's DoEvents loop from one
    # that is merely present: that loop never sleeps longer than 16ms, so a
    # stalled-but-running app accumulates seconds and a wedged one does not.
    Write-Host ("report: watch[$what] pid={0} alive={1} gone_at={2} cpu_s={3} t={4}ms" -f `
        $script:WatchPid, $alive, $gone, $script:WatchCpu, (Watch-Elapsed))
    $edge = @(Get-Process -Name msedgewebview2 -ErrorAction SilentlyContinue).Count
    Write-Host "report: watch[$what] msedgewebview2 processes now=$edge"
}

# A verifier that speaks in PASS and FAIL should not leave by exception. The
# waits below used to `throw` on a timeout; with $ErrorActionPreference = Stop
# that propagates out of the script, past the step's own log assembly, and the
# annotations get whatever had been printed before it -- two section headers,
# three runs running. Ending here instead means the log always finishes with a
# Results line and the exit code is always the failure count.
function Fail-Now($message) {
    Write-Host "FAIL: $message"
    $script:Failures++
    Write-Host ""
    Write-Host "=== Results: $script:Failures failure(s) ==="
    exit $script:Failures
}

# What the driver had managed to fetch when a wait gave up. Every failure so far
# has been a wait ending at its bound with nothing else said, and the two
# explanations want opposite fixes: the package download never finished, or it
# finished and the page never ran. One line separates them.
function Report-PackageState {
    $root = Join-Path $AppDir "Microsoft.Web.WebView2"
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Host "report: no WebView2 package directory at $root"
        return
    }
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    Write-Host "report: WebView2 package: $($files.Count) file(s), $bytes byte(s)"
}

# The app's own window, with its frame, and not the whole screen.
#
# verify-std.ps1 was changed to crop two rounds ago and this file was not, so
# the two Windows verifiers photographed the same machine differently: every
# other lane's sheet came down to 200-550 KB of cropped windows while
# `windows-launch` stayed at 1.8 MB of desktop, wallpaper, taskbar and the
# "Test Mode" watermark. A sheet is for comparing lanes, and two lanes framed
# differently cannot be compared.
#
# GetWindowRect and not GetClientRect: the frame is part of what a launch
# screenshot is showing. Falls back to the full screen and says which it did,
# because 00-initial is taken the moment a window handle exists and that is
# earlier than the window being on screen.
function Take-Screenshot($name) {
    try {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $x = $bounds.X; $y = $bounds.Y
        $w = $bounds.Width; $h = $bounds.Height
        $how = "the whole screen"
        $waited = 0
        while ($waited -lt 12) {
            $hwnd = $script:shotHwnd
            $r = New-Object WinAPI+RECT
            if (-not ($hwnd -and $hwnd -ne [IntPtr]::Zero -and [WinAPI]::GetWindowRect($hwnd, [ref]$r))) {
                $live = Get-Process -Name $AppName -ErrorAction SilentlyContinue |
                        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
                if ($live) { $hwnd = $live.MainWindowHandle; $script:shotHwnd = $hwnd }
            }
            if ($hwnd -and $hwnd -ne [IntPtr]::Zero -and [WinAPI]::GetWindowRect($hwnd, [ref]$r)) {
                $rw = $r.Right - $r.Left
                $rh = $r.Bottom - $r.Top
                if ($rw -gt 0 -and $rh -gt 0 -and $rw -le 4096 -and $rh -le 4096) {
                    $x = $r.Left; $y = $r.Top; $w = $rw; $h = $rh
                    $how = "the app's own window and its frame"
                    break
                }
            }
            $waited++
            Start-Sleep -Milliseconds 250
        }
        $bitmap = New-Object System.Drawing.Bitmap $w, $h
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($x, $y, 0, 0, $bitmap.Size)
        $bitmap.Save("$ScreenshotDir\$name.png", [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose(); $graphics.Dispose()
        Write-Host "  shot ${name}: $how ($($w)x$($h) at $x,$y)"
    } catch {
        Write-Host "  shot ${name}: the capture threw: $($_.Exception.Message)"
    }
}

function Wait-ForApp() {
    $script:WatchStart = Get-Date
    $script:WatchPolls = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds($FirstTimeout)
    do {
        $t0 = Get-Date
        $p = Get-Process -Name $AppName -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        [void]$script:WatchPolls.Add([int]((Get-Date) - $t0).TotalMilliseconds)
        if ($p) {
            # From here the watch has something to follow. The pid is taken
            # once: a second process of the same name arriving later is a
            # different question, and re-reading the name every poll would
            # silently start reporting about it.
            $script:WatchPid = $p.Id
            # Held for Take-Screenshot, which runs much later and re-resolves
            # this if it has gone stale.
            $script:shotHwnd = $p.MainWindowHandle
            Write-Host "report: watch[window] pid=$($p.Id) window at $(Watch-Elapsed)ms"
            return $p
        }
        Start-Sleep -Milliseconds $PollInterval
    } while ((Get-Date) -lt $deadline)
    Report-PackageState
    Report-Watch "window"
    Write-Host "report: windows with a title when the wait gave up:"
    foreach ($other in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($other.MainWindowHandle -eq 0 -or -not $other.MainWindowTitle) { continue }
            Write-Host "report:   $($other.ProcessName) [$($other.Id)] '$($other.MainWindowTitle)'"
        } catch { continue }
    }
    Fail-Now "TIMEOUT after ${FirstTimeout}s waiting for the app to show a window"
}

# The Windows driver downloads its engine assemblies and calls Assembly.LoadFrom
# on them, so what landed in the package directory is code this app runs and is
# part of what this verifier is for. Two things are asserted: every pinned member
# is there and hashes to its pin, and *nothing else is there* -- the unpack used
# to build its destination out of the name the archive supplied, which walked out
# of this directory entirely.
#
# The pinned list is read out of the artifact under test rather than repeated
# here, for the same reason parse.sh lifts the splitter: a copy can go stale and
# still pass.
function Assert-WebView2Package($artifact, $packageRoot) {
    if (-not (Test-Path -LiteralPath $packageRoot)) {
        Write-Host "  FAIL: no package directory at $packageRoot"
        Write-Host "::warning title=windows-package::no package directory at $packageRoot"
        $script:Failures++
        return
    }
    # Canonicalise to the long-name form before any Substring math below. The
    # netinstall e2e installs under a temp path with an 8.3 component
    # (RUNNER~1), and Get-ChildItem returns FullName expanded (runneradmin) --
    # three characters longer -- so a Substring by the short root's length left
    # every member spelled `ew2\lib\...`, the tail of "WebView2". The standalone
    # lane never saw it: its checkout path has no short name to expand.
    $packageRoot = (Get-Item -LiteralPath $packageRoot).FullName

    $lines = Get-Content -LiteralPath $artifact
    $start = -1; $stop = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -eq '    var NeutrinoWebview = {') { $start = $i; continue }
        if ($start -ge 0 -and $lines[$i] -eq '    };') { $stop = $i; break }
    }
    if ($start -lt 0 -or $stop -lt 0) {
        Write-Host "  FAIL: could not lift the pinned member list out of $artifact"
        Write-Host "::warning title=windows-package::could not lift the pinned member list"
        $script:Failures++
        return
    }

    $work = Join-Path $env:TEMP 'neutrino-package-assert'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    ($lines[$start..$stop] + 'module.exports = NeutrinoWebview;') |
        Set-Content -LiteralPath (Join-Path $work 'obj.js') -Encoding UTF8
    'console.log(JSON.stringify(require("./obj.js").webView2Members));' |
        Set-Content -LiteralPath (Join-Path $work 'members.js') -Encoding UTF8

    Push-Location $work
    $members = (& node members.js) | ConvertFrom-Json
    Pop-Location

    $expected = @{}
    foreach ($m in $members) { $expected[$m.path.Replace('/', '\')] = $m.sha256 }

    $onDisk = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File)) {
        $onDisk[$f.FullName.Substring($packageRoot.Length).TrimStart('\')] = $f.FullName
    }

    # A pin nobody checked would pass this whole function, so say how many were
    # checked and fail on zero.
    if ($expected.Count -eq 0) {
        Write-Host "  FAIL: the artifact pins no package members at all"
        Write-Host "::warning title=windows-package::the artifact pins no package members at all"
        $script:Failures++
        return
    }

    foreach ($rel in $expected.Keys) {
        if (-not $onDisk.ContainsKey($rel)) {
            Write-Host "  FAIL: pinned member missing from the package: $rel"
            Write-Host "::warning title=windows-package::pinned member missing: $rel"
            $script:Failures++
            continue
        }
        $got = (Get-FileHash -LiteralPath $onDisk[$rel] -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $expected[$rel]) {
            Write-Host "  FAIL: $rel hashes to $got, pinned as $($expected[$rel])"
            Write-Host "::warning title=windows-package::$rel does not match its pin"
            $script:Failures++
        } else {
            Write-Host "  PASS: $rel matches its pin"
        }
    }

    foreach ($rel in $onDisk.Keys) {
        if (-not $expected.ContainsKey($rel)) {
            Write-Host "  FAIL: the unpack wrote something nothing pinned: $rel"
            Write-Host "::warning title=windows-package::unpinned file in the package directory: $rel"
            $script:Failures++
        }
    }
    Write-Host "  PASS: the package directory holds the $($expected.Count) pinned members and nothing else"
}

# --- The sequence ----------------------------------------------------------
#
# One loop, and nothing slow inside it.
#
# This suite used to wait for each title in turn -- and between one wait
# returning and the next beginning it asserted, reported and encoded a
# full-screen PNG. Measured under load: that gap ran to about three seconds
# against a state the app holds for one, so the next title was set and gone
# before anything looked for it, and the wait after it then spent its entire
# bound against a process that had finished and exited. Every recorded symptom
# of the "first-window stall" is that, including the ones a larger bound could
# not fix.
#
# So the app's states are recorded as they happen and asserted afterwards. Two
# things follow from that and both matter.
#
# Geometry is sampled *with* the title, in the same turn, because resize and
# move are only observable while the step that made them is current -- reading
# them later would be reading a window that has moved on, or closed.
#
# And the sampler asks one process for one property. The old poll called
# Get-Process with no arguments and touched MainWindowTitle on every process on
# the machine, which is what made a turn expensive enough to lose a state in.
function Watch-Sequence($proc, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $samples = New-Object System.Collections.ArrayList
    $last = $null
    $maxGap = 0
    $turns = 0
    $prevTurn = Get-Date
    while ((Get-Date) -lt $deadline) {
        $turns++
        $now = Get-Date
        $gap = [int]($now - $prevTurn).TotalMilliseconds
        if ($gap -gt $maxGap) { $maxGap = $gap }
        $prevTurn = $now
        [void]$script:WatchPolls.Add($gap)
        try { $proc.Refresh() } catch { break }
        try { $script:WatchCpu = [math]::Round($proc.TotalProcessorTime.TotalSeconds, 2) } catch {}
        if ($proc.HasExited) {
            if (-not $script:WatchGoneAt) { $script:WatchGoneAt = Watch-Elapsed }
            Write-Host "report: seq $(Watch-Elapsed)ms <the process is gone>"
            break
        }
        $title = ""
        try { $title = [string]$proc.MainWindowTitle } catch { $title = "" }
        if ($title -ne $last) {
            $last = $title
            # Both rects, in the turn that read the title, for the reason the
            # comment above gives about sampling geometry with the title: a
            # frame read now and a client read a turn later is a difference
            # between two windows, and the difference is what this is for.
            #
            # GetClientRect is the one this file never had. resizeTo sets
            # ClientSize on this lane, and every size assertion below was
            # comparing that request against GetWindowRect -- a frame -- with
            # an eighty-pixel tolerance quietly paying the caption and the
            # borders. The frame stays because the difference between the two
            # is the decoration, and that is a reading worth having; what
            # changes is which one the assertions are pointed at.
            $rect = New-Object WinAPI+RECT
            $crect = New-Object WinAPI+RECT
            [WinAPI]::GetWindowRect($proc.MainWindowHandle, [ref]$rect) | Out-Null
            [WinAPI]::GetClientRect($proc.MainWindowHandle, [ref]$crect) | Out-Null
            [void]$samples.Add([pscustomobject]@{
                At     = [int]((Get-Date) - $script:WatchStart).TotalMilliseconds
                Title  = $title
                Width  = $crect.Right - $crect.Left
                Height = $crect.Bottom - $crect.Top
                OuterW = $rect.Right - $rect.Left
                OuterH = $rect.Bottom - $rect.Top
                Left   = $rect.Left
                Top    = $rect.Top
            })
            $s = $samples[$samples.Count - 1]
            Write-Host "report: seq $($s.At)ms '$title' inner $($s.Width)x$($s.Height) outer $($s.OuterW)x$($s.OuterH) extent $($s.OuterW - $s.Width)x$($s.OuterH - $s.Height) at $($s.Left),$($s.Top)"
            if ($title -like "*TESTS DONE*") { break }
        }
        Start-Sleep -Milliseconds $SampleInterval
    }
    return [pscustomobject]@{
        Samples = $samples
        MaxGap  = $maxGap
        Turns   = $turns
    }
}

function Find-Sample($record, $title) {
    foreach ($s in $record.Samples) {
        if ($s.Title -eq $title) { return $s }
    }
    return $null
}

# A title that was never observed and a step that never ran are different
# readings, and this used to report both as the second one.
#
# The record starts when the sequence loop starts, which is after the window
# exists and after `00-initial` is encoded -- about 1.4 s on a busy runner. An
# app that got through two titles inside that gap leaves a record whose *first*
# entry is already past the one being asked about, and "never observed 'STEP0'"
# then reads as the app having failed to do something it did before anyone was
# looking. So when the missing title is behind the first thing recorded, this
# says which of the two it is. The app now holds three seconds before its first
# step, so the case should not arise; if it does, the sentence names the
# instrument instead of accusing the app.
function Assert-Reached($record, $title) {
    $s = Find-Sample $record $title
    if ($s) {
        Write-Host "  PASS: reached '$title' at $($s.At)ms"
    } else {
        $first = $null
        if ($record -and $record.Samples -and $record.Samples.Count -gt 0) {
            $first = $record.Samples[0]
        }
        if ($first) {
            Write-Host "  FAIL: never observed the title '$title'; the record opens on '$($first.Title)' at $($first.At)ms, so the watch may have started after this step"
            Write-Host "::warning title=windows-sequence::never observed '$title'; record opens on '$($first.Title)' at $($first.At)ms"
        } else {
            Write-Host "  FAIL: never observed the title '$title'; the record is empty"
            Write-Host "::warning title=windows-sequence::never observed the title '$title'"
        }
        $script:Failures++
    }
    return $s
}

# The requested size, exactly, unless a caller asks for slack -- which is the
# rule verify-linux.sh's own comment already sets out, arrived at here by the
# same route and about a year late.
#
# `resizeTo` sets ClientSize on this lane, so the client area is the quantity
# that was asked for and the quantity this reads. While it read GetWindowRect
# the numbers it compared were a frame against a client request, and the eighty
# pixels below were what let the two look equal: a caption and two borders fit
# inside eighty with room to spare, so this passed whichever rect the driver
# was setting, and would have gone on passing if the driver had got it
# backwards. The sampler still records the frame, and the difference between
# them is printed on every turn as `extent`; nothing here says the frame is
# uninteresting, only that it is not what resizeTo was asked for.
#
# Zero, and `-eq 0` rather than `-not` on the parameter, because a caller
# asking for a tolerance of zero and a caller asking for none are the same
# request and PowerShell reads both as falsy.
function Assert-GeometryAt($sample, $title, $expectedW, $expectedH, $tolerance) {
    if (-not $sample) { return }
    if (-not $tolerance) { $tolerance = 0 }
    $dw = [Math]::Abs($sample.Width - $expectedW)
    $dh = [Math]::Abs($sample.Height - $expectedH)
    if ($dw -le $tolerance -and $dh -le $tolerance) {
        Write-Host "  PASS: geometry at '$title' ~= ${expectedW}x${expectedH} (actual: $($sample.Width)x$($sample.Height))"
    } else {
        Write-Host "  FAIL: geometry at '$title' expected ~= ${expectedW}x${expectedH} actual=$($sample.Width)x$($sample.Height)"
        $script:Failures++
    }
}

# Frame against frame, which is the half of this that was always right:
# GetWindowRect's Left/Top is the frame's outside corner and `move` sets
# Form.Location, which is the same corner. So a decoration cannot move this
# number and the ten pixels were never paying for a title bar.
#
# Nor for anything else. Measured across three runs of this suite in one job --
# windows-test and both windows-load replicas -- `moveTo(0,0)` put the frame at
# `0,0` every time, and the per-state `seq` lines this file already printed had
# been carrying that reading since before the tolerance was questioned. Zero,
# and `-eq 0` rather than `-not`, because a caller asking for a tolerance of
# zero and a caller asking for none are the same request and PowerShell reads
# both as falsy.
#
# Windows is the platform where this is simply exact. macOS clamps a move to
# the work area and the two x11 window managers disagree with each other about
# what a move means at all; here the request is honoured.
function Assert-PositionAt($sample, $title, $expectedX, $expectedY, $tolerance) {
    if (-not $sample) { return }
    if (-not $tolerance) { $tolerance = 0 }
    $dx = [Math]::Abs($sample.Left - $expectedX)
    $dy = [Math]::Abs($sample.Top - $expectedY)
    if ($dx -le $tolerance -and $dy -le $tolerance) {
        Write-Host "  PASS: position at '$title' ~= ${expectedX},${expectedY} (actual: $($sample.Left),$($sample.Top))"
    } else {
        Write-Host "  FAIL: position at '$title' expected ~= ${expectedX},${expectedY} actual=$($sample.Left),$($sample.Top)"
        $script:Failures++
    }
}

# --- Test steps ---

Write-Host "=== Waiting for window ==="
# By process, not by title: whether a window appeared has nothing to do with
# which scripted step the app happens to be on, and matching the initial title
# made this fail whenever the app got ahead of the verifier.
$proc = Wait-ForApp
Take-Screenshot "00-initial"

Write-Host "=== Recording the app's sequence ==="
# One loop over both halves. Everything between the Form appearing and the first
# title is the WebView2 package being fetched and unpacked, which is why the
# budget is what it is; from the first title on, the app walks its steps a
# second apart. Nothing slow happens in here, and the sample gap asserted below
# is what says so.
$record = Watch-Sequence $proc $FirstTimeout
Take-Screenshot "05-done"
Report-Watch "sequence"

# The property the old design violated, asserted directly rather than left to
# luck: a sampler whose slowest turn is not comfortably inside the dwell can
# miss a state, and then nothing downstream means anything. Measured at about
# three seconds against a one-second dwell, which is what this suite spent four
# PRs calling a stall.
#
# The dwell is lifted out of the artifact under test, for the same reason
# Assert-WebView2Package lifts the pinned member list: a copy of a number that
# lives in another file goes stale and still passes. Not being able to read it
# is a failure and not a default -- a fallback would quietly assert against a
# dwell the app does not have. And the smallest of the matches, not the first:
# the app arms runNext twice, once to wait for its audience and once between
# steps, and which one the file spells first is not something this suite should
# depend on.
$dwell = 0
foreach ($line in (Get-Content -LiteralPath $Artifact)) {
    if ($line -match 'setTimeout\(runNext,\s*(\d+)\)') {
        $found = [int]$Matches[1]
        if ($dwell -eq 0 -or $found -lt $dwell) { $dwell = $found }
    }
}
Write-Host "=== The sampler kept up with the app ==="
if ($dwell -le 0) {
    Write-Host "  FAIL: could not read the step dwell out of $Artifact"
    Write-Host "::warning title=windows-sequence::could not read the step dwell out of the artifact"
    $script:Failures++
    $dwell = 1000
}
Write-Host "report: sampler turns=$($record.Turns) max_gap_ms=$($record.MaxGap) dwell_ms=$dwell"
if ($record.MaxGap -lt $dwell) {
    Write-Host "  PASS: the slowest turn ($($record.MaxGap)ms) is inside the ${dwell}ms dwell"
} else {
    Write-Host "  FAIL: the slowest turn ($($record.MaxGap)ms) is not inside the ${dwell}ms dwell -- a state could have been missed"
    Write-Host "::warning title=windows-sequence::sampler max gap $($record.MaxGap)ms against a ${dwell}ms dwell"
    $script:Failures++
}

Write-Host "=== Every step the app reported ==="
$null = Assert-Reached $record "STEP0"
$null = Assert-Reached $record "STEP1-Test Title"
$step2 = Assert-Reached $record "STEP2"
$step3 = Assert-Reached $record "STEP3"
# The app checks its own palette and reports a verdict, because it is the only
# side that can see one. A lane that reached no toolkit reports null and titles
# itself THEMEBAD, which this does not find -- and the sample log above carries
# the reading either way.
$null = Assert-Reached $record "THEMEOK"
$null = Assert-Reached $record "TESTS DONE"

Write-Host "=== Step 2: resize ==="
Assert-GeometryAt $step2 "STEP2" 500 400

Write-Host "=== Step 3: move ==="
Assert-PositionAt $step3 "STEP3" 0 0

Write-Host "=== WebView2 package: pinned, and nothing else unpacked ==="
Assert-WebView2Package $Artifact (Join-Path $AppDir "Microsoft.Web.WebView2")

Write-Host ""
Write-Host "=== Results: $Failures failure(s) ==="
exit $Failures
