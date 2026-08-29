# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-offline.ps1 - what `build.sh --tier=offline` actually denies (Windows).
#
# The same probe test/verify-offline.sh runs on the other three lanes, against
# the fourth engine. It is a probe and not a verifier this round: `--tier=offline`
# has never been built by anything in this repository and never run on any
# engine, so there is no measured value to assert to and asserting to a guess
# would put a PASS on one. The controls are asserted, because a probe whose
# controls go unread publishes noise -- see the shell verifier's header for what
# each of them rules out.
#
# Windows is the lane where the answer is least guessable. NavigateToString is
# how this driver hands the document over, so whether a meta policy in that
# string binds at all is a WebView2 question nobody here has asked, and the page
# script arrives through AddScriptToExecuteOnDocumentCreated, which PR 21
# measured registers on the view rather than on a document.
#
# Usage: verify-offline.ps1 <default-tier app.cmd> <offline-tier app.cmd> <outDir>

$ErrorActionPreference = "Continue"

$controlApp = $args[0]
$offlineApp = $args[1]
$outDir = $args[2]
if (-not $controlApp -or -not (Test-Path $controlApp) -or
    -not $offlineApp -or -not (Test-Path $offlineApp) -or -not $outDir) {
    Write-Output "usage: verify-offline.ps1 <default-tier app.cmd> <offline-tier app.cmd> <outDir>"
    exit 2
}
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$log = Join-Path $outDir "offline.log"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 8096
$probe = "http://127.0.0.1:$port/off-probe.html"
$work = Join-Path $env:TEMP ("verifyoffline-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
$serverLog = Join-Path $work "server.log"
$failures = 0

$shapes = @("fetch", "xhr", "img", "css", "script", "frame", "beacon", "sse", "ws")
# The shapes the default policy leaves alone. script and frame are refused by
# both policies and belong to the enforcement control instead.
$allowed = @("fetch", "xhr", "img", "css", "beacon", "sse", "ws")
# Not shapes the policy governs: the two routes out of the process. Counted
# apart so they cannot be mistaken for a subresource the tier let through.
# openExternal is ShellExecute here, so a HIT on `external` is the default
# browser having been started and having fetched the url the page chose. There
# is no navigation refusal to confuse `navout` with -- PR 21's nav sink cancels
# and does not hand anything on -- so a HIT there is that guard having failed.
$escapes = @("external", "navout")
# Ground rule 6: a platform answer that is a finding rather than a fix is
# asserted to the value it was measured at. Windows cancels in
# NavigationStarting, the target document never runs -- PR 21 asserts that -- and
# the GET still reaches the host. gjs and Qt decide before the request and
# nothing arrives there. Neither is fixable from this layer; both are written
# down so a change in either direction is a failure and not silence.
$expectNavout = "HIT"
$browserNames = @("msedge", "chrome", "firefox", "iexplore")

$lines = New-Object System.Collections.ArrayList
function Say($m) { Write-Output "report: $m"; [void]$lines.Add("report: $m") }
function Fail($m) {
    Write-Output "FAIL: $m"
    [void]$lines.Add("FAIL: $m")
    $script:failures++
}
function Save-Log { Set-Content -Path $log -Value $lines -Encoding ASCII }

function Assert-Is($what, $expected, $actual) {
    if ($expected -eq "any") {
        Say "NOTE: $what = $actual (recorded, not asserted here)"
    } elseif ($actual -eq $expected) {
        Say "PASS: $what ($actual)"
    } else {
        Fail "$what : expected $expected, got $actual"
    }
}

# Every request line the server has logged past a mark. python -m http.server
# writes them to stderr, which is why it is started with that stream redirected
# to a file rather than through a pipeline.
function Requests-Since($mark) {
    if (-not (Test-Path $serverLog)) { return @() }
    $all = @(Get-Content $serverLog -ErrorAction SilentlyContinue)
    if ($all.Count -le $mark) { return @() }
    return @($all[$mark..($all.Count - 1)])
}

function Stop-Apps {
    foreach ($n in @("neutrinooffline", "neutrinooffline-default")) {
        Get-Process -Name $n -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

# openExternal starts the default browser, and a browser left running is a
# second thing holding the port and the desktop for the next phase.
function Stop-Browsers {
    foreach ($n in @("msedge", "chrome", "firefox", "iexplore")) {
        Get-Process -Name $n -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
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
        $r = Invoke-WebRequest -Uri $probe -UseBasicParsing -TimeoutSec 2
        if ($r.Content -match "OFF-PROBE-FRAME") { $up = $true; break }
    } catch {}
    Start-Sleep -Seconds 1
}
if (-not $up) {
    Fail "nothing answering at $probe; a page reaching a closed port reads exactly like a policy that held"
    if ($server -and -not $server.HasExited) { $server.Kill() }
    Save-Log
    exit 1
}
Say "control target=UP port=$port"

# ------------------------------------------------------------------ one phase

$readyOf = @{}
$hitsOf = @{}
$browsersOf = @{}

function Run-Phase($label, $app) {
    Stop-Apps
    # Which browsers were already up before this phase launched anything. The
    # question below is whether the offline tier *started* a browser, and what
    # was asked was whether one is *running* -- a different question, and one
    # the runner can answer for you: a firefox nobody here launched was enough
    # to fail the assertion. Taken by process id rather than by name, because a
    # name cannot tell the browser this phase opened from the one that was
    # already on screen.
    $baselineBrowsers = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $browserNames -contains $_.ProcessName } |
        ForEach-Object { $_.Id })
    $mark = 0
    if (Test-Path $serverLog) { $mark = @(Get-Content $serverLog -ErrorAction SilentlyContinue).Count }

    $launch = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $app -PassThru -WindowStyle Hidden
    if (-not $launch.WaitForExit(240000)) { $launch.Kill() }

    # Two bounds, because the first launch is also the one that downloads and
    # unpacks the pinned WebView2 package and a window can be a minute away.
    $ready = ""
    $settled = ""
    $firstBy = (Get-Date).AddSeconds(240)
    $deadline = $firstBy
    while ((Get-Date) -lt $deadline) {
        $t = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like "OFFLINE-*" } |
            ForEach-Object { $_.MainWindowTitle })
        foreach ($title in $t) {
            if ($title -like "OFFLINE-READY*" -and -not $ready) {
                $ready = $title
                $deadline = (Get-Date).AddSeconds(60)
            }
            # END and not DONE: DONE is the nine-shape report, and the two
            # escapes come after it. An engine that permits the final navigation
            # loses its document and never sends END, which the outer bound
            # covers.
            if ($title -like "*END") { $settled = $title }
        }
        if ($settled) { break }
        Start-Sleep -Milliseconds 500
    }

    # The navigation is sent two seconds after END, and a browser started by
    # openExternal has to come up cold and issue a request. Round 2 measured
    # that taking longer than the grace on a lane's second launch -- external
    # read HIT under the default tier and MISS under the offline one for the
    # same unchanged code path, which is a stopwatch and not a refusal.
    Start-Sleep -Seconds 25

    if (-not $ready) {
        Fail "$label : the app never reported; a window that never came up refuses everything"
        Say "$label windows with a title when the wait gave up:"
        Get-Process | Where-Object { $_.MainWindowTitle -ne "" } |
            Select-Object -First 6 |
            ForEach-Object { Say "  $($_.ProcessName): $($_.MainWindowTitle)" }
    } else {
        Say "$label first: $ready"
        Say "$label settled: $(if ($settled) { $settled } else { '<none>' })"
    }
    $readyOf[$label] = $ready

    $seen = Requests-Since $mark
    $summary = ""
    foreach ($shape in $shapes) {
        $n = @($seen | Where-Object { $_ -match "k=$shape" }).Count
        $hitsOf["$label/$shape"] = ($n -gt 0)
        $summary += " $shape=" + $(if ($n -gt 0) { "HIT" } else { "MISS" })
    }
    Say "$label log:$summary"

    $escaped = ""
    foreach ($shape in $escapes) {
        $n = @($seen | Where-Object { $_ -match "k=$shape" }).Count
        $hitsOf["$label/$shape"] = ($n -gt 0)
        $escaped += " $shape=" + $(if ($n -gt 0) { "HIT" } else { "MISS" })
    }
    Say "$label out of process:$escaped"

    # There is no handler to instrument on this lane, so a browser having
    # started is the reading the handler's log would have been. Sampled before
    # the cleanup, because the cleanup is what takes it away.
    $preexisting = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $browserNames -contains $_.ProcessName -and $baselineBrowsers -contains $_.Id } |
        ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
    $running = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $browserNames -contains $_.ProcessName -and $baselineBrowsers -notcontains $_.Id } |
        ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
    $browsersOf[$label] = $running
    Say ("$label browsers started: " + $(if ($running.Count) { $running -join " " } else { "none" }))
    # Carried, not asserted: a browser that was up before this phase is the
    # runner's business, and saying so is what stops the line above being read
    # as "no browser was anywhere on the machine".
    if ($preexisting.Count) {
        Say ("$label browsers already up, not this phase's: " + ($preexisting -join " "))
    }

    Stop-Apps
    Stop-Browsers
}

Write-Output "=== default tier: what the shipped policy permits ==="
Run-Phase "default" $controlApp
Write-Output "=== offline tier: what --tier=offline denies ==="
Run-Phase "offline" $offlineApp

# ----------------------------------------------------------------- the reading

function Policy-Of($title) {
    if ($title -match "pol=([A-Z]+)") { return $Matches[1] }
    return "NONE"
}
Say ("policy carried: default=" + (Policy-Of $readyOf["default"]) +
     " offline=" + (Policy-Of $readyOf["offline"]))

$leaked = @($shapes | Where-Object { $hitsOf["offline/$_"] })
$delivered = @($allowed | Where-Object { $hitsOf["default/$_"] })
$missing = @($allowed | Where-Object { -not $hitsOf["default/$_"] })
Say ("reached the host under --tier=offline: " + $(if ($leaked.Count) { $leaked -join " " } else { "none" }))
Say ("the default tier delivered: " + $(if ($delivered.Count) { $delivered -join " " } else { "none" }))
Say ("the default tier permits but did not deliver: " + $(if ($missing.Count) { $missing -join " " } else { "none" }))

$enforced = "YES"
foreach ($shape in @("script", "frame")) {
    if ($hitsOf["default/$shape"]) { $enforced = "NO" }
}
Say "the document's own policy is enforced (script/frame refused by both): $enforced"

# The tenth and eleventh questions, kept out of the table above because they are
# not subresource loads and no directive in either policy governs them.
# There is no shim on this lane, so a url in the server's log may be the view or
# may be the browser openExternal started -- except for navout, which PR 21's
# nav sink cancels without forwarding anywhere.
$out = @($escapes | Where-Object { $hitsOf["offline/$_"] })
Say ("left the process under --tier=offline: " + $(if ($out.Count) { $out -join " " } else { "none" }))

# ------------------------------------------- what the fix has to be true of

$loaded = @($shapes | Where-Object { $hitsOf["offline/$_"] })
Assert-Is "the offline document loaded nothing over the network" "" ($loaded -join " ")
Assert-Is "the document's own policy is enforced" "YES" $enforced
Assert-Is "the offline build carried the offline policy" "OFFLINE" (Policy-Of $readyOf["offline"])
Assert-Is "the default build carried the default policy" "DEFAULT" (Policy-Of $readyOf["default"])

# The route no content policy can see, and the half of this PR that is a fix
# rather than a measurement. openExternal is ShellExecute here, so before the fix
# a browser started under both tiers and fetched the url the page chose.
Assert-Is "no browser started under the offline tier" "" (@($browsersOf["offline"]) -join " ")
if (-not @($browsersOf["default"]).Count) {
    Say "NOTE: no browser started under the default tier either; the line above is not a refusal"
}

# The ceiling, asserted to the value this platform was measured at.
Assert-Is "the navigation's own request, on this platform" $expectNavout `
    $(if ($hitsOf["offline/navout"]) { "HIT" } else { "MISS" })

# Recorded and not asserted: `external` arriving is a browser having started and
# won a race with the grace period, and round 2 read it both ways on this lane
# for the same unchanged code.
Assert-Is "external reached the host under the offline tier" "any" `
    $(if ($hitsOf["offline/external"]) { "HIT" } else { "MISS" })

if ($server -and -not $server.HasExited) { $server.Kill() }
Save-Log
Write-Output "=== Results: $failures failure(s) ==="
if ($failures -gt 0) { exit 1 }
exit 0
