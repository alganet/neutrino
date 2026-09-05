# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# launchtime.ps1 - where a launch's seconds actually go
#
# The windows lane already prints a startup path: 6ms init, 262ms window on
# screen, 789ms title. Those numbers are the driver's, and the driver's clock
# starts at its own first line. A person waiting for the app is timing
# something else -- from the double click to the content -- and on a machine
# where that is two to four seconds, a trace ending at 789ms is not describing
# the same launch.
#
# What sits between the two is a prefix nobody has measured, in two halves:
#
#   batch    cmd.exe starting, the escape line, certutil hashing the artifact
#            through a nested cmd, the stamp compare, and START
#   runtime  the exe being created, the CLR starting, mscorlib, System,
#            System.Drawing, System.Windows.Forms and the JScript runtime
#            loading, and this program's global code running -- everything
#            before the driver writes `0ms`
#
# Neither is visible from inside the driver and neither is visible in a
# wall-clock total. This measures both, run by run, and puts the trace's own
# phases underneath them so one reading covers a launch end to end.
#
# It also measures the two things the batch half is made of, on the machine
# doing the complaining rather than by reasoning about them:
#
#   floor    `cmd.exe /c exit`, which is what a process start costs here.
#            A launch is four of them -- cmd.exe, the nested cmd the stamp's
#            hash runs in, certutil, and the exe -- so this number is charged
#            four times before the app has done anything, and two of those
#            four exist only for the stamp. On a runner it is ten
#            milliseconds and the point is academic; on a client machine with
#            a real-time scanner in front of every CreateProcess it is not,
#            and that is the difference this whole file exists to see
#   hash     `certutil -hashfile <artifact> SHA256`, which the launcher runs
#            on every launch to decide whether the cached exe matches the
#            script. It is the one piece of per-launch work in the batch
#            region that has an alternative -- the launcher's own comment
#            says size and modification time would answer the same question
#            -- so what it costs decides whether that alternative is worth
#            the staleness it would buy
#
# And two compiled controls for the other half of the prefix, because
# `runtime` is one number over four unrelated things: the CLR starting,
# Microsoft.JScript loading, System.Windows.Forms and System.Drawing loading
# -- init calls EnableVisualStyles three statements before it installs the
# trace, so the toolkit is inside this number and not inside the timeline --
# and this program's own global code, 32 parts of assignments and a 313-line
# table of COM vtable slots. A JScript.NET winexe that does nothing, and the
# same one with EnableVisualStyles in front of it, say how much of that
# belongs to anybody but us.
#
# Reported and not asserted, for the reason the warm-up step gives: what a
# launch costs on somebody's machine is not this project's to hold to a
# number, and a threshold nobody can defend is a red lane nobody believes.
# What it is for is the shape.
#
# Runs are numbered and reported separately rather than averaged, because the
# first one is a different program: it compiles the exe, it creates the
# WebView2 profile, and every file it touches is cold. The summary at the end
# is over the runs after it, which is what "opening the app again" costs.
#
# Usage:
#   bash test/mkapp.sh --testing test/neutrinoloaders.js test/neutrinotime.cmd
#   pwsh test/launchtime.ps1 -Artifact test\neutrinotime.cmd -Runs 5
#
# The app has to be a --testing build: the trace channel is what the two inner
# phases are read from, and a release build does not have one. Without it the
# outer numbers still land and the breakdown says so.

param(
    [string]$Artifact = (Join-Path $PSScriptRoot "neutrinotime.cmd"),
    [int]$Runs = 5,
    # The title the app sets when it has rendered. This is the only signal
    # from outside that the content is actually up: a window handle exists
    # while the frame is still empty, which is the half of the wait the
    # driver deliberately moved earlier and not the half a person is
    # complaining about.
    [string]$Ready = "LOADERS READY",
    # Delete the app folder, the exe and the stamp first, so run 1 is a
    # genuine cold start rather than whatever the last run left.
    [switch]$Fresh,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Continue"
function Report($m) { Write-Output "report: $m" }
function Fail($m) { Write-Output "FAIL: $m"; $script:failures++ }
$failures = 0

if (-not (Test-Path -LiteralPath $Artifact)) {
    Write-Output "usage: launchtime.ps1 -Artifact <app.cmd built --testing> [-Runs n]"
    exit 2
}

$Artifact = (Resolve-Path -LiteralPath $Artifact).Path
$name     = [System.IO.Path]::GetFileNameWithoutExtension($Artifact)
$dir      = [System.IO.Path]::GetDirectoryName($Artifact)
$appDir   = Join-Path $dir $name
$trace    = Join-Path $appDir "neutrino-trace.log"

Write-Output "=== launchtime: where a launch's seconds go ==="
Report "artifact $Artifact"
Report "artifact bytes=$((Get-Item -LiteralPath $Artifact).Length)"

# --- the machine ---------------------------------------------------------
#
# What is watching, because a launch is four process creations -- cmd.exe, the
# nested cmd the stamp's hash runs in, certutil, and the exe -- and on a
# machine where each of those is scanned that is the whole of the difference
# between a runner and a desktop. The `floor` reading below is the same
# question asked with a clock; this is it asked of the machine, so the two can
# agree or disagree in one report.
#
# A client SKU and a server SKU are not the same machine here, and the
# difference is not only Defender. SecurityCenter2 exists on Windows Home and
# Pro and not on Server, SmartScreen's reputation check is a client feature,
# and a file that arrived over the network carries a Zone.Identifier that a
# file built in place does not. Each is reported rather than assumed, because
# every one of them is a thing somebody would otherwise argue about.
#
# Nothing here changes a setting. The A/B that settles it is one the person
# running this can do and this script should not: exclude the app folder,
# measure again, put the exclusion back. A test that turns off a scanner is a
# test that has to remember to turn it on.
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Report "os     $($os.Caption) build $($os.BuildNumber) producttype=$($os.ProductType)"
} catch {
    Report "os     could not be read"
}
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Report "av     defender mode=$($mp.AMRunningMode) realtime=$($mp.RealTimeProtectionEnabled) antivirus=$($mp.AntivirusEnabled)"
} catch {
    Report "av     no Get-MpComputerStatus here: Defender is absent, disabled or not answering"
}
try {
    $paths = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
    Report "av     defender exclusion paths=$($paths.Count)"
} catch {
}
try {
    $products = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop)
    if ($products.Count -eq 0) {
        Report "av     SecurityCenter2 registers no product"
    } else {
        foreach ($product in $products) { Report "av     SecurityCenter2 registers $($product.displayName)" }
    }
} catch {
    Report "av     no SecurityCenter2, which is a server SKU and not a client one"
}
try {
    $null = Get-Item -LiteralPath $Artifact -Stream Zone.Identifier -ErrorAction Stop
    Report "motw   the artifact carries a Zone.Identifier, so this machine treats it as downloaded"
} catch {
    Report "motw   the artifact carries no Zone.Identifier"
}
try {
    $smart = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" `
        -Name SmartScreenEnabled -ErrorAction Stop).SmartScreenEnabled
    Report "smart  SmartScreenEnabled=$smart"
} catch {
    Report "smart  no SmartScreenEnabled value, which is this machine's default"
}

function Stop-App {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    # The browser goes with its host, but not instantly, and a run that
    # started while the last one's browser was still exiting is measuring
    # the exit as well.
    for ($i = 0; $i -lt 100; $i++) {
        if (-not (Get-Process -Name $name -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Milliseconds 500
}

# --- the floor -----------------------------------------------------------
#
# Two process creations are the irreducible part of every launch here: the
# cmd.exe that reads the batch region, and the exe it STARTs. Anything the
# launcher does on top of that is only interesting next to this number.
$floor = @()
for ($i = 0; $i -lt 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & cmd.exe /c exit
    $sw.Stop()
    $floor += $sw.Elapsed.TotalMilliseconds
}
$floorMs = [int](($floor | Measure-Object -Minimum).Minimum)
Report "floor  cmd.exe /c exit, best of 5: ${floorMs}ms"

# --- the hash ------------------------------------------------------------
#
# What the launcher's stamp costs per launch. Two process creations of its
# own, because `FOR /F usebackq` with a backticked command hands it to a
# nested cmd -- so this reading is a floor for it, not the whole of it.
$certutil = Join-Path $env:WINDIR "System32\certutil.exe"
if (Test-Path -LiteralPath $certutil) {
    $hash = @()
    for ($i = 0; $i -lt 5; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $certutil -hashfile $Artifact SHA256 *> $null
        $sw.Stop()
        $hash += $sw.Elapsed.TotalMilliseconds
    }
    $hashMs = [int](($hash | Measure-Object -Minimum).Minimum)
    Report "hash   certutil -hashfile, best of 5: ${hashMs}ms (the launcher also pays a nested cmd for it)"
} else {
    $hashMs = -1
    Report "hash   no certutil on this machine, so the launcher does not run one either"
}

# --- what the CLR and the runtime cost before a line of ours runs ---------
#
# `runtime` below is everything between the exe being created and the driver's
# first line: the CLR starting, mscorlib and Microsoft.JScript loading, this
# program's global code running, and -- because init calls EnableVisualStyles
# three statements before it installs the trace -- System.Windows.Forms and
# System.Drawing loading too. One number over four very different things, and
# which of them it mostly is decides whether any of it is ours to fix.
#
# So two controls, compiled by the compiler the launcher uses, with the
# reference list read off the artifact's own jsc line: a JScript.NET winexe
# that does nothing but report how long it took to reach its first line, and
# the same program with EnableVisualStyles in front of it. The first is what
# a .NET process costs on this machine and nothing here can change it. The
# difference to the second is what a WinForms app pays to have a toolkit. What
# is left over, against the app's own `runtime`, is this program's global code
# -- 32 parts of assignments and one 313-line table of COM vtable slots.
#
# A floor and not an attribution: these are tiny assemblies and the app's is
# 705 KB, so its own load and JIT are larger than theirs by an amount this
# does not measure.
$floors = @{}
$fx = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
if (-not (Test-Path (Join-Path $fx "jsc.exe"))) {
    $fx = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
}
$jsc = Join-Path $fx "jsc.exe"
if (Test-Path -LiteralPath $jsc) {
    $text = Get-Content -LiteralPath $Artifact -Raw
    $refs = @([regex]::Matches($text, '/r:"%FX_DIR%\\([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $work = Join-Path $env:TEMP ("launchtime-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $probes = @(
        @{ Name = "empty"; Head = "" },
        @{ Name = "winforms"; Head = "System.Windows.Forms.Application.EnableVisualStyles();" }
    )
    foreach ($probe in $probes) {
        $src = Join-Path $work "$($probe.Name).js"
        $exe = Join-Path $work "$($probe.Name).exe"
        $out = Join-Path $work "$($probe.Name).txt"
        @(
            $probe.Head,
            "var ms = Math.round(System.DateTime.UtcNow.Subtract(",
            "    System.Diagnostics.Process.GetCurrentProcess()",
            "        .StartTime.ToUniversalTime()).TotalMilliseconds);",
            "System.IO.File.WriteAllText(",
            "    System.Environment.GetCommandLineArgs()[1], String(ms));"
        ) | Set-Content -LiteralPath $src -Encoding ASCII
        $argv = @("/nologo", "/debug-", "/t:winexe", "/out:$exe", "/autoref+", "/lib:$fx")
        foreach ($r in $refs) { $argv += "/r:$(Join-Path $fx $r)" }
        $argv += $src
        & $jsc $argv *> $null
        if (-not (Test-Path -LiteralPath $exe)) {
            Report "floor  the $($probe.Name) control would not compile"
            continue
        }
        $best = $null
        for ($i = 0; $i -lt 3; $i++) {
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            Start-Process -FilePath $exe -ArgumentList $out -Wait -WindowStyle Hidden
            if (Test-Path -LiteralPath $out) {
                $v = [int]((Get-Content -LiteralPath $out -Raw).Trim())
                if ($null -eq $best -or $v -lt $best) { $best = $v }
            }
        }
        if ($null -ne $best) { $floors[$probe.Name] = $best }
    }
    if ($floors.ContainsKey("empty")) {
        Report "floor  a jsc winexe that does nothing: $($floors['empty'])ms to its first line"
    }
    if ($floors.ContainsKey("winforms")) {
        Report "floor  the same with EnableVisualStyles: $($floors['winforms'])ms"
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Report "floor  no jsc.exe under $env:WINDIR\Microsoft.NET, so the runtime half has no control"
}

if ($Fresh) {
    Stop-App
    Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $dir "$name.exe") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $dir "$name.stamp") -Force -ErrorAction SilentlyContinue
    Report "fresh  the app folder, the exe and the stamp are gone; run 1 is cold"
}

# --- the runs ------------------------------------------------------------

function Read-Trace {
    # The driver's own account, as pairs of milliseconds and message. Absent
    # on a release build, which is a reading and not a failure.
    if (-not (Test-Path -LiteralPath $trace)) { return @() }
    $out = @()
    foreach ($line in @(Get-Content -LiteralPath $trace -ErrorAction SilentlyContinue)) {
        if ($line -match '^(-?\d+)ms neutrino: (.*)$') {
            $out += [pscustomobject]@{ Ms = [int]$matches[1]; Text = $matches[2] }
        }
    }
    return $out
}

$rows = @()
for ($run = 1; $run -le $Runs; $run++) {
    Stop-App
    Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue
    # Beside the script is where the launcher keeps it, and inside the app
    # folder is where it falls back to; either one means this run does not
    # compile.
    $cached = (Test-Path -LiteralPath (Join-Path $dir "$name.exe")) -or
              (Test-Path -LiteralPath (Join-Path $appDir "$name.exe"))

    # No pipe on the launcher: the batch STARTs a detached exe and exits, and
    # a pipe would outlive it (PR 20/28).
    $fallback = Get-Date
    $cmd = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$Artifact`"" `
        -PassThru -WindowStyle Hidden
    # The kernel's own reading where it can be had. A batch region short enough
    # to have exited already still answers, because the object holds the
    # handle; anything that does not is not worth ending the run over.
    try { $t0 = $cmd.StartTime } catch { $t0 = $fallback }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    # The exe existing is the end of the batch region: everything cmd.exe was
    # going to do it has done, including the compile when there is one.
    $app = $null
    while ((Get-Date) -lt $deadline) {
        $live = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($live.Count -gt 0) { $app = $live[0]; break }
        Start-Sleep -Milliseconds 2
    }
    if (-not $app) {
        Fail "run ${run}: no $name process within ${TimeoutSeconds}s"
        continue
    }
    $tExe = $app.StartTime

    # A handle, which is the empty frame, and then the title, which is the
    # content. Polled rather than hooked, so both carry the poll's own few
    # milliseconds; against a launch measured in hundreds it does not matter,
    # and a hook would need an Add-Type and a compiler on the path.
    $tWindow = $null
    $tTitle = $null
    while ((Get-Date) -lt $deadline) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if (-not $tWindow -and $p.MainWindowHandle -ne 0) { $tWindow = Get-Date }
            if ($Ready -and $p.MainWindowTitle -eq $Ready) { $tTitle = Get-Date; break }
        }
        if ($tTitle) { break }
        if (-not $Ready -and $tWindow) { break }
        Start-Sleep -Milliseconds 5
    }

    $lines = @(Read-Trace)
    $clr = $null
    foreach ($l in $lines) {
        if ($l.Text -match '^start: (\d+)ms') { $clr = [int]$matches[1] }
    }
    $last = if ($lines.Count -gt 0) { $lines[$lines.Count - 1].Ms } else { $null }

    $batch  = [int]($tExe - $t0).TotalMilliseconds
    $window = if ($tWindow) { [int]($tWindow - $t0).TotalMilliseconds } else { $null }
    $title  = if ($tTitle)  { [int]($tTitle  - $t0).TotalMilliseconds } else { $null }

    $kind = if ($cached) { "cached" } else { "compile" }
    Write-Output ""
    Report "run $run ($kind)"
    Report "  batch    ${batch}ms   cmd.exe, the stamp, and START"
    if ($null -ne $clr) {
        Report "  runtime  ${clr}ms   the exe, the CLR and the global code, before the driver's first line"
    } else {
        Report "  runtime  --      no trace: build the app with --testing to see this half"
    }
    foreach ($l in $lines) {
        if ($l.Text -match '^start: ') { continue }
        Report ("    {0,6}ms {1}" -f $l.Ms, $l.Text)
    }
    if ($null -ne $window) { Report "  window   ${window}ms  a frame on screen, from the launch" }
    if ($null -ne $title)  { Report "  content  ${title}ms  the app's own title, from the launch" }
    else { Fail "run ${run}: the title '$Ready' never arrived" }

    $rows += [pscustomobject]@{
        Run = $run; Kind = $kind; Batch = $batch; Clr = $clr;
        Driver = $last; Window = $window; Content = $title
    }
}
Stop-App

# --- the summary ---------------------------------------------------------

function Median($values) {
    $v = @($values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    return [int]$v[[int]([Math]::Floor($v.Count / 2))]
}

$warm = @($rows | Where-Object { $_.Kind -eq "cached" })
Write-Output ""
if ($warm.Count -eq 0) {
    Report "summary: no cached run to summarise"
} else {
    $b = Median ($warm | ForEach-Object { $_.Batch })
    $c = Median ($warm | ForEach-Object { $_.Clr })
    $d = Median ($warm | ForEach-Object { $_.Driver })
    $w = Median ($warm | ForEach-Object { $_.Window })
    $t = Median ($warm | ForEach-Object { $_.Content })
    Report "summary over $($warm.Count) cached runs, medians:"
    Report "  batch    ${b}ms   against a ${floorMs}ms floor for one process start"
    if ($null -ne $hashMs -and $hashMs -ge 0) {
        Report "           of which the stamp's hash is at least ${hashMs}ms, plus the nested cmd it runs in"
    }
    if ($null -ne $c) {
        Report "  runtime  ${c}ms   the CLR, the toolkit and the global code"
        if ($floors.ContainsKey("winforms")) {
            $mine = $c - $floors["winforms"]
            Report "           of which ${mine}ms is this program's own, over a $($floors['winforms'])ms control"
        }
    }
    if ($null -ne $d) { Report "  driver   ${d}ms   the driver's own last mark" }
    if ($null -ne $w) { Report "  window   ${w}ms   an empty frame, from the launch" }
    if ($null -ne $t) { Report "  content  ${t}ms   the app, from the launch" }
    if ($null -ne $t -and $null -ne $c -and $null -ne $d) {
        $tail = $t - $b - $c - $d
        Report "  tail     ${tail}ms  between the driver's last mark and the title being visible"
    }
}

if ($failures -gt 0) { Write-Output "FAILURES: $failures" }
exit 0
