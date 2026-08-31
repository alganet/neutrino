# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-nav.ps1 - the Windows driver refuses a navigation away from its own
# document, and refuses the window a page asks for.
#
# This was a probe before it was a verifier, and every assertion below is a
# reading it took. Against this same target, on the same lane, the driver
# without a guard answered nav_arrived=YES, popup_arrived=YES opened=HANDLE and
# after_nav api=object page=number: the app's window really did become a remote
# page, carrying the injected API and the app author's own page script, because
# AddScriptToExecuteOnDocumentCreated registers on the view rather than on a
# document. So each of these would have failed before the guard landed, which is
# what the suite is for.
#
# The instrument is the target server's own request log. The page reports out of
# band, through a GET per fact, because what a document inherits after it has
# replaced the app's own cannot be reported through any channel that is itself
# under test -- a page that could only say "I have the API" by using the API
# answers NO for a build where the API is present and merely unusable.
#
# Three positive controls, because a refusal and a window that never came up
# read the same, and because a guard that refuses the app's own document would
# otherwise pass every assertion here by refusing everything:
#
#   target=UP      the server answers an ordinary GET before the app is launched
#   NAV-READY      the app came up, ran its page script and drove its native
#                  window -- the exact thing an over-broad guard would break.
#                  NavigationStarting fires for this driver's own load, as
#                  about:blank and then as the data: url NavigateToString makes,
#                  so "refuses the app" is a live failure mode and not a
#                  hypothetical
#   NAV-POPUP      the page got as far as asking for a window, so popup_arrived
#                  is about the refusal and not about a page that never asked.
#                  It asks twice now: `window.open`, which since that verb was
#                  given its standard meaning no longer reaches the engine for
#                  an external url, and a `<a target=_blank>` click, which is
#                  what still raises NewWindowRequested and is therefore what
#                  the refusal below is about
#
# The app is built `--tier=offline`, and that is load-bearing rather than a
# preference. A refused new window now has its url forwarded to the machine's
# browser, which is the correct behaviour and would be ruinous here: the browser
# would fetch the url this suite's instrument is a request log for, and every
# assertion below would be answering a question about a browser. Offline closes
# mayOpenExternal, so a beacon can only arrive if a *document* was created to
# fetch it -- which is the question. The cost is that the default tier's
# forwarding is exercised on no lane.
#
# Usage: verify-nav.ps1 <app.cmd built from test/neutrinonav.js> <outDir>

$ErrorActionPreference = "Continue"

$lane = $args[0]
$outDir = $args[1]
if (-not $lane -or -not (Test-Path $lane) -or -not $outDir) {
    Write-Output "usage: verify-nav.ps1 <app.cmd> <outDir>"
    exit 2
}
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$log = Join-Path $outDir "nav.log"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 8097
$target = "http://127.0.0.1:$port/nav-target.html"
$work = Join-Path $env:TEMP ("verifynav-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
$serverLog = Join-Path $work "server.log"
$failures = 0

$lines = New-Object System.Collections.ArrayList
function Say($m) { Write-Output "report: $m"; [void]$lines.Add("report: $m") }
function Fail($m) {
    Write-Output "FAIL: $m"
    [void]$lines.Add("FAIL: $m")
    $script:failures++
}
function Save-Log { Set-Content -Path $log -Value $lines -Encoding ASCII }

function Assert-Is($what, $expected, $actual) {
    if ($actual -eq $expected) {
        Say "PASS: $what ($actual)"
    } else {
        Fail "$what : expected $expected, got $actual"
    }
}

# Every GET this server saw, in order. python -m http.server logs to stderr,
# which is why the process is started with that stream redirected rather than
# with a pipeline -- and the file is read fresh each time because the readings
# are "did this arrive by now", not "did it ever".
function Beacons($pattern) {
    if (-not (Test-Path $serverLog)) { return @() }
    return @(Get-Content $serverLog -ErrorAction SilentlyContinue |
        Where-Object { $_ -match $pattern })
}

function Beacon-Field($pattern, $name) {
    foreach ($line in (Beacons $pattern)) {
        if ($line -match "[?&]$name=([^&\s""]+)") { return $Matches[1] }
    }
    return "NONE"
}

function Stop-Apps {
    Get-Process -Name "neutrinonav" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# ---------------------------------------------------------------- the target

$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) { $python = (Get-Command python3 -ErrorAction SilentlyContinue) }
if (-not $python) {
    Fail "no python on this runner; the target cannot be served and nothing below means anything"
    Save-Log
    exit 1
}

$server = Start-Process -FilePath $python.Source `
    -ArgumentList "-m", "http.server", "--bind", "127.0.0.1", "--directory", $here, "$port" `
    -PassThru -WindowStyle Hidden -RedirectStandardError $serverLog `
    -RedirectStandardOutput (Join-Path $work "server.out")

$up = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $r = Invoke-WebRequest -Uri $target -UseBasicParsing -TimeoutSec 2
        if ($r.Content -match "NAV-TARGET") { $up = $true; break }
    } catch {}
    Start-Sleep -Seconds 1
}
if (-not $up) {
    Fail "nothing answering at $target; a page that navigates into a closed port measures nothing"
    if ($server -and -not $server.HasExited) { $server.Kill() }
    Save-Log
    exit 1
}
Say "control target=UP url=$target"

# ------------------------------------------------------------------ the app

Stop-Apps
$launch = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane -PassThru -WindowStyle Hidden
if (-not $launch.WaitForExit(180000)) { $launch.Kill() }

# Every distinct title the app's window wore, in order. The escape cases name
# themselves in the title, so the sequence is the finding and the last value on
# its own is not.
#
# Two bounds, because the first launch is also the one that downloads and
# unpacks the pinned WebView2 package and a window can be a minute away. Wait up
# to three minutes for the first title, then forty-five seconds more for the
# rest of the sequence -- a fixed total would either time out on a cold runner
# or spend the whole budget waiting on a warm one.
$titles = New-Object System.Collections.ArrayList
$firstBy = (Get-Date).AddSeconds(180)
$deadline = $firstBy
while ((Get-Date) -lt $deadline) {
    $p = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -like "NAV-*" -or $_.MainWindowTitle -like "__NEUTRINO__*" }
    foreach ($proc in $p) {
        $t = $proc.MainWindowTitle
        if ($t -and -not $titles.Contains($t)) {
            [void]$titles.Add($t)
            if ($deadline -eq $firstBy) { $deadline = (Get-Date).AddSeconds(45) }
        }
    }
    Start-Sleep -Milliseconds 500
}

foreach ($t in $titles) { Say "title $t" }

if ($titles.Count -eq 0) {
    Fail "the app never reported; a build that renders nothing refuses everything by doing nothing"
    Say "windows with a title when the wait gave up:"
    Get-Process | Where-Object { $_.MainWindowTitle -ne "" } |
        ForEach-Object { Say "  $($_.ProcessName): $($_.MainWindowTitle)" }
}

# The controls first, and the run is over if either fails: everything after them
# is a refusal, and a refusal only means something once the thing that would
# have been refused is known to have happened.
Assert-Is "the app came up and drove its own window (control)" $true `
    (@($titles | Where-Object { $_ -like "NAV-READY*" }).Count -gt 0)
Assert-Is "the page asked for a window (control)" $true `
    (@($titles | Where-Object { $_ -like "NAV-POPUP*" }).Count -gt 0)

# What window.open returned is reported, not asserted. Handled=true was measured
# to suppress the window; what the engine hands back to the caller was not, and
# an assertion on an unmeasured value is a guess with a PASS on it.
Say "popup $(($titles | Where-Object { $_ -like 'NAV-POPUP*' } |
    Select-Object -First 1) -replace '^NAV-POPUP ', '')"

# ------------------------------------------------------------ the refusals

Assert-Is "the navigation was refused" "NO" `
    $(if ((Beacons "probe%3Dnav&").Count -gt 0) { "YES" } else { "NO" })
# Neither route may produce a document. `window.open` cannot reach the engine
# with this url any more, so what this now asserts is the anchor's half: a
# `<a target=_blank>` must not become a view that fetches. Under the offline
# tier there is no other way for that url to be requested, which is what keeps
# the reading unambiguous.
Assert-Is "the new window was refused" "NO" `
    $(if ((Beacons "probe%3Dpopup&").Count -gt 0) { "YES" } else { "NO" })

# Said whichever way it goes, because "the document that would have arrived was
# handed the API" is the sentence this guard exists to make untrue, and a run
# where the refusal broke should print what leaked rather than only that a
# count was wrong.
Say ("would-have-carried api=" + (Beacon-Field "probe%3Dnav&" "api") +
     " page=" + (Beacon-Field "probe%3Dnav&" "page") +
     " tx=" + (Beacon-Field "probe%3Dnav&" "tx"))

# No route to the native window. NAV-ESCAPED-API is a document that was
# navigated to naming the window it is in -- the standard spelling, which the
# host connects to each engine's title-changed signal, and which the gate
# admits only for the document this launcher loaded. It was two routes while a
# forged record could carry a setTitle; that record is gone and this is what it
# probed. The title branch reading Source is what answers both.
$escaped = @($titles | Where-Object { $_ -match "NAV-ESCAPED" })
Assert-Is "no document that was navigated to drove the window" 0 $escaped.Count
foreach ($e in $escaped) { Say "ESCAPE $e" }

# One window, not two. Counted over the browser process as well as the app's:
# a WebView2 popup's frame belongs to msedgewebview2, so a list of the app's own
# pids cannot see it and answers 1 whatever happened -- which is the same blind
# spot MainWindowTitle had.
Add-Type -Namespace NtWin -Name Enum -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, System.IntPtr lParam);
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)] public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder text, int count);
'@ -ErrorAction SilentlyContinue

function App-Windows {
    $found = New-Object System.Collections.ArrayList
    try {
        $pids = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -eq "neutrinonav" -or $_.ProcessName -eq "msedgewebview2" } |
            ForEach-Object { [uint32]$_.Id })
        if ($pids.Count -eq 0) { return $found }
        $cb = [NtWin.Enum+EnumWindowsProc] {
            param([System.IntPtr]$h, [System.IntPtr]$l)
            $owner = [uint32]0
            [void][NtWin.Enum]::GetWindowThreadProcessId($h, [ref]$owner)
            if (($pids -contains $owner) -and [NtWin.Enum]::IsWindowVisible($h)) {
                $sb = New-Object System.Text.StringBuilder 512
                [void][NtWin.Enum]::GetWindowText($h, $sb, 512)
                [void]$found.Add($sb.ToString())
            }
            return $true
        }
        [void][NtWin.Enum]::EnumWindows($cb, [System.IntPtr]::Zero)
    } catch {
        # A reading that could not be taken, said as one. An empty list here
        # would read as "no second window" and mean "no instrument".
        [void]$found.Add("<enumwindows unavailable: $_>")
    }
    return $found
}

$wins = App-Windows
foreach ($w in ($wins | Select-Object -First 6)) { Say "window [$w]" }
Assert-Is "the app owns one window" 1 $wins.Count

Say "server saw $((Beacons 'GET').Count) request(s), $((Beacons 'neutrino-beacon').Count) of them beacons"

Stop-Apps
if ($server -and -not $server.HasExited) { $server.Kill() }
Save-Log

Write-Output "=== Results: $failures failure(s) ==="
if ($failures -gt 0) { exit 1 }
exit 0
