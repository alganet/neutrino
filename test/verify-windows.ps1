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

# The pixels now, the PNG later.
#
# Everything this file says about its own sampling loop comes down to one rule:
# nothing slow happens inside it. A state the app holds for two seconds is lost
# to a turn that takes longer than that, and the single operation here expensive
# enough to do it is encoding a full-screen bitmap to PNG -- about 1.4 s on a
# busy runner. That is the whole reason this lane took two pictures where every
# other takes seven: `00-initial` before the loop, one more after it, and
# nothing in between, because in between was the loop.
#
# So the two halves are separated. CopyFromScreen is a blit off the screen DC
# and costs single-digit milliseconds; Save() is the encode and the disk write
# and costs the 1.4 s. The blit runs in a turn, while the state it photographs
# is still the one on screen; the bitmaps are written after the walk is over,
# when nothing is waiting on them.
#
# What that buys is the parity this lane never had. verify-linux.sh and
# verify-macos.sh photograph all seven states -- the window as it appears, the
# four scripted steps, the palette reading, the finish -- so the resize and the
# move that the assertions at the bottom of this file have always covered in
# numbers had no picture on the one platform where those numbers are exact.
#
# The cost is carried honestly rather than hidden. The grab happens inside the
# turn, so it is inside the gap the apparatus control below measures: a blit
# slow enough to threaten the dwell fails that control instead of sneaking past
# it. Six bitmaps at 1024x768 is about 18 MB held until the walk ends, which is
# the price of not encoding them one at a time while the app is moving.
$script:Frames = New-Object System.Collections.ArrayList

function Grab-Frame($name, $x, $y, $w, $h, $how) {
    $t0 = Get-Date
    $bitmap = $null
    try {
        $bitmap = New-Object System.Drawing.Bitmap $w, $h
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($x, $y, 0, 0, $bitmap.Size)
        $graphics.Dispose()
    } catch {
        $bitmap = $null
        $how = "the grab threw: $($_.Exception.Message)"
    }
    [void]$script:Frames.Add([pscustomobject]@{
        Name   = $name
        Bitmap = $bitmap
        How    = $how
        X = $x; Y = $y; W = $w; H = $h
        GrabMs = [int]((Get-Date) - $t0).TotalMilliseconds
    })
}

# Whether a state has already been photographed. The sampler sees a title on
# every turn it is current for, not once, and a second grab of the same name
# would overwrite the first with a later picture of the same thing while paying
# the blit again.
function Have-Frame($name) {
    foreach ($f in $script:Frames) { if ($f.Name -eq $name) { return $true } }
    return $false
}

# Written once, after the walk, in the order they were taken -- with the grab
# cost beside each, which is the number the paragraphs above make a claim about
# and therefore the number a reader should be able to check.
function Save-Frames() {
    if ($script:Frames.Count -eq 0) { return }
    $slowest = 0
    $taken = $script:Frames.Count
    foreach ($f in $script:Frames) {
        if ($f.GrabMs -gt $slowest) { $slowest = $f.GrabMs }
        if (-not $f.Bitmap) {
            Write-Host "  shot $($f.Name): $($f.How)"
            continue
        }
        try {
            $f.Bitmap.Save("$ScreenshotDir\$($f.Name).png",
                           [System.Drawing.Imaging.ImageFormat]::Png)
            Write-Host "  shot $($f.Name): $($f.How) ($($f.W)x$($f.H) at $($f.X),$($f.Y), grabbed in $($f.GrabMs)ms)"
        } catch {
            Write-Host "  shot $($f.Name): the save threw: $($_.Exception.Message)"
        }
        $f.Bitmap.Dispose()
    }
    $script:Frames.Clear()
    Write-Host "report: frames n=$taken slowest_grab_ms=$slowest"
}

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
# How long a state is left to arrive on screen before it is photographed.
#
# The app assigns its page text and its document title in the same tick, and the
# title is what this suite watches -- so a shutter firing on the turn the title
# changed can catch the frame before the text the picture is *of* has painted.
# 02-step1, 05-theme and 06-done are all that kind of state; 03-step2 and
# 04-step3 are not, because the resize and the move happened a whole step
# earlier and the title only announces them.
#
# The unix verifiers never had to choose this number. They poll for a title with
# a sleep in the loop and then spawn `import` or `screencapture`, so a few
# hundred milliseconds pass whether anyone meant them to or not. Here the delay
# has to be picked, and picking it is better than inheriting it.
#
# 400ms: four of the sampler's own turns, a fifth of the 2000ms the app holds
# each state for, and nowhere near the boundary where the next one starts.
# Nothing sleeps for it -- the shot is queued with a due time and taken by
# whichever turn comes after it, so it costs the walk nothing.
$ShotSettle = 400
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
    # Whatever was grabbed and not yet written. Nothing reaches here holding
    # frames today -- the only caller gives up before the first shutter -- but
    # the pictures live in memory until the walk ends now, and an exit that
    # skipped this would throw away the only account of a run that got far
    # enough to photograph something and then stopped.
    Save-Frames
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
#
# This is the shutter for the pictures taken outside the sampling loop, and all
# it owns is finding the rect -- it hunts for a live window and will wait three
# seconds for one, which is exactly the kind of thing that must not happen in a
# turn. The loop reads its own rect inline and calls Grab-Frame straight. Both
# queue rather than write: see Grab-Frame above for why the encode is not here.
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
        Grab-Frame $name $x $y $w $h $how
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
        $script:Failures++
        return
    }

    foreach ($rel in $expected.Keys) {
        if (-not $onDisk.ContainsKey($rel)) {
            Write-Host "  FAIL: pinned member missing from the package: $rel"
            $script:Failures++
            continue
        }
        $got = (Get-FileHash -LiteralPath $onDisk[$rel] -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $expected[$rel]) {
            Write-Host "  FAIL: $rel hashes to $got, pinned as $($expected[$rel])"
            $script:Failures++
        } else {
            Write-Host "  PASS: $rel matches its pin"
        }
    }

    foreach ($rel in $onDisk.Keys) {
        if (-not $expected.ContainsKey($rel)) {
            Write-Host "  FAIL: the unpack wrote something nothing pinned: $rel"
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
#
# The pictures follow the geometry, and for the same reason: a state is only
# photographable while it is current. What made that impossible until now was
# the PNG encode, and it is no longer in the turn -- Grab-Frame takes the pixels
# and Save-Frames writes them once the walk is over.

# Which state each picture is a picture of.
#
# The names are verify-linux.sh's and verify-macos.sh's, character for
# character, because the sheet exists to lay the lanes beside each other and a
# Windows `03-step2` spelled any other way is a row that cannot be compared.
# `06-done` and not `05-done`: this lane numbered its last shot a digit below
# every other one, nothing recorded why, and sheet.sh quietly captioned both
# spellings -- which is how a divergence survives, by being handled.
#
# THEMEBAD sits beside THEMEOK because the picture is the entire point of that
# state. The app writes the palette it just judged onto the page, so the shot is
# the only place the actual colours can be read after the fact, and a lane that
# read no palette at all is the one worth looking at hardest. The assertion
# still wants THEMEOK; the camera does not care which verdict it was.
$script:ShotFor = @{
    "STEP0"            = "01-step0"
    "STEP1-Test Title" = "02-step1"
    "STEP2"            = "03-step2"
    "STEP3"            = "04-step3"
    "THEMEOK"          = "05-theme"
    "THEMEBAD"         = "05-theme"
    "TESTS DONE"       = "06-done"
}

function Watch-Sequence($proc, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $samples = New-Object System.Collections.ArrayList
    $last = $null
    $maxGap = 0
    $turns = 0
    $prevTurn = Get-Date
    # One shot in flight at a time, and the finish held open until it is taken.
    # States are two seconds apart and the settle is a fifth of that, so a
    # second one cannot come due before the first is spent; if the app ever
    # walked faster than its own dwell the newer state would replace the older
    # here, which is the same thing the sampler itself would do with the title.
    $pendingShot = $null
    $pendingDue = Get-Date
    $done = $false
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

            # The picture of this state -- queued here, taken a settle later.
            #
            # The `-like` widening is the break condition's, kept identical:
            # `TESTS DONE` is the one title this loop has always matched
            # loosely, and the finish has to be photographed under whichever
            # spelling the break fires on or the last picture is taken outside
            # the loop with the window already closed.
            $shot = $script:ShotFor[$title]
            if ($title -like "*TESTS DONE*") { $shot = "06-done"; $done = $true }
            if ($shot -and -not (Have-Frame $shot)) {
                $pendingShot = $shot
                $pendingDue = (Get-Date).AddMilliseconds($ShotSettle)
            } elseif ($done) {
                break
            }
        }

        # Whatever state was seen a moment ago and has now had its settle.
        # Outside the title branch on purpose: that turn is too early, and the
        # next title change is far too late.
        #
        # The rect is read again here rather than taken from the sample, because
        # this fires a few hundred milliseconds after that reading and the crop
        # has to frame the pixels actually being copied. The sample keeps the
        # geometry the assertions run on; this is the geometry of a photograph.
        if ($pendingShot -and (Get-Date) -ge $pendingDue) {
            $pr = New-Object WinAPI+RECT
            $pw = 0; $ph = 0
            if ([WinAPI]::GetWindowRect($proc.MainWindowHandle, [ref]$pr)) {
                $pw = $pr.Right - $pr.Left
                $ph = $pr.Bottom - $pr.Top
            }
            if ($pw -gt 0 -and $ph -gt 0 -and $pw -le 4096 -and $ph -le 4096) {
                Grab-Frame $pendingShot $pr.Left $pr.Top $pw $ph `
                    "the app's own window and its frame"
            } else {
                # Take-Screenshot's fallback and its confession, minus the
                # waiting: a picture of the wrong thing beats none as long as it
                # says which it is, and a turn is not the place to hunt.
                $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                Grab-Frame $pendingShot $b.X $b.Y $b.Width $b.Height `
                    "the whole screen; the window rect read ${pw}x${ph}"
            }
            $pendingShot = $null
            if ($done) { break }
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
# exists and after `00-initial` has been taken. That used to be an encode --
# about 1.4 s on a busy runner -- and is a blit now, because Grab-Frame defers
# every PNG to the end of the walk; the gap is smaller than this paragraph was
# written against, and it is not zero. An app that got through two titles inside
# it leaves a record whose *first* entry is already past the one being asked
# about, and "never observed 'STEP0'" then reads as the app having failed to do
# something it did before anyone was looking. So when the missing title is
# behind the first thing recorded, this says which of the two it is. The app now
# holds three seconds before its first step, so the case should not arise; if it
# does, the sentence names the instrument instead of accusing the app.
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
        } else {
            Write-Host "  FAIL: never observed the title '$title'; the record is empty"
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
# second apart. Nothing slow happens in here -- the per-state pictures are blits
# and their encodes are below -- and the sample gap asserted further down is
# what says so rather than this sentence.
$record = Watch-Sequence $proc $FirstTimeout
# The finish, if the walk did not reach it. Inside the loop `06-done` is taken
# on the turn that sees TESTS DONE, with the window still up; out here the app
# has had two seconds to close itself on purpose, and what this photographs is
# a desktop. That is the picture verify-std.ps1's own header calls a blank
# rectangle nobody opens a directory to look at -- so it is the fallback and not
# the rule, kept because a run that timed out or died mid-walk should still
# publish a picture of wherever it stopped.
if (-not (Have-Frame "06-done")) { Take-Screenshot "06-done" }
# Now, with the app finished and nothing being sampled, the encodes.
Save-Frames
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
    $script:Failures++
    $dwell = 1000
}
Write-Host "report: sampler turns=$($record.Turns) max_gap_ms=$($record.MaxGap) dwell_ms=$dwell"
if ($record.MaxGap -lt $dwell) {
    Write-Host "  PASS: the slowest turn ($($record.MaxGap)ms) is inside the ${dwell}ms dwell"
} else {
    Write-Host "  FAIL: the slowest turn ($($record.MaxGap)ms) is not inside the ${dwell}ms dwell -- a state could have been missed"
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
