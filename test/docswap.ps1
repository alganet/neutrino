# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# docswap.ps1 - the document this driver renders is the one boot gave it.
#
# `boot` reads the app off disk once, extracts a document, applies the content
# policy and hands the result to `driver.loadHTML`. The Windows driver's
# loadHTML used to drop that argument, navigate to about:blank, and then --
# hundreds of lines later, inside the event loop -- read the file again off
# NEUTRINO_SCRIPT_PATH and render a document extracted from the second read.
# The three other drivers render the first.
#
# Measured before the fix, on this lane: the exe appears about 350 ms after the
# launcher starts and the second read lands between half a second and a second
# after that. A file replaced inside the gap was the one that rendered --
# content policy and all -- while the page script running in it came from the
# first read. And with the file removed instead of replaced, `File.Exists` was
# false, no navigation happened, the view stayed on the about:blank it was
# created with, and the page never reached an API to report through: a window
# with no title, no error and no log line.
#
# The instrument is two markers, because one cannot measure two reads. Each
# build carries a meta tag in the document region -- which the second read
# decided -- and a constant in the page script region, which the first read
# decided. A title reading `script=A doc=B` is the two reads disagreeing and
# nothing else produces it.
#
# What this asserts:
#
#   control     the shipped build comes up and reads its own markers
#   oldcontrol  so does the pre-fix spelling -- without this, every reading
#               below is a broken build rather than a finding
#   swap<d>     on the shipped build the two markers agree at all three delays,
#               whichever file the single read found. A disagreement is
#               impossible when there is one read, and it is what the old
#               spelling produces
#   oldswap     the defect reproduces at at least one of those delays. Each
#               delay on its own is a race and gets no PASS -- PR 22's lesson
#               about a reading that moves with load -- but if none of them
#               lands, the assertions above have nothing to compare to and
#               "it would have failed before" is a claim again
#
# `gone` and `oldgone` are recorded and not asserted, and the candidate round is
# why. Removing the file cannot pick which read it breaks: land it early and it
# beats boot's read, the app cannot read its own source at all, and no window
# comes up -- which is the same "no window title" that the second read failing
# produces. That round asserted the shipped build renders here, read `none`, and
# the reading was right while the assertion was measuring the wrong read.
#
# Usage: docswap.ps1 <app.cmd built from test/neutrinodoc.js> <outDir>

$ErrorActionPreference = "Continue"

$src = $args[0]
$outDir = $args[1]
if (-not $src -or -not (Test-Path $src) -or -not $outDir) {
    Write-Output "usage: docswap.ps1 <app.cmd built from test/neutrinodoc.js> <outDir>"
    exit 2
}
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$log = Join-Path $outDir "docswap.log"

$failures = 0
$lines = New-Object System.Collections.ArrayList
function Say($m) { Write-Output "report: $m"; [void]$lines.Add("report: $m") }
function Fail($m) { Write-Output "FAIL: $m"; [void]$lines.Add("FAIL: $m"); $script:failures++ }
function Save-Log { Set-Content -Path $log -Value $lines -Encoding ASCII }

$work = Join-Path $env:TEMP ("docswap-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
$lane = Join-Path $work "neutrinodoc.cmd"

# The old spelling read its second document off NEUTRINO_SCRIPT_PATH, and the
# batch region no longer sets it -- getScriptPath derives the path from the
# exe's own location now, and standalone.ps1 is where that is measured. So this
# suite supplies the variable itself, for the reconstruction below and for
# nothing else: the shipped build ignores it, every phase launches $lane, and
# reconstructing the defect through the derivation instead would change what is
# being reproduced. `gone` in particular depends on this spelling -- the old
# guard answers File.Exists("") on a removed file, where a derivation throws.
$env:NEUTRINO_SCRIPT_PATH = $lane

# ------------------------------------------------------------- the three builds
#
# Derived here rather than in the workflow, for the reason navrefuse.sh derives
# its own: the before-state belongs beside the assertion that needs it, and a
# substitution that stops matching has to fail loudly rather than quietly ship a
# duplicate of the build under test.
$utf8 = New-Object System.Text.UTF8Encoding $false
$missing = @()
# No output of its own, deliberately: everything a PowerShell function writes is
# part of its return value, so a Fail in here would come back as text instead of
# as a failure. What it cannot substitute it records, and the report comes after.
function ReplaceOnce($text, $from, $to, $what) {
    if (-not $text.Contains($from)) {
        $script:missing += @("$what needs " + $from.Substring(0, [Math]::Min(60, $from.Length)))
        return $text
    }
    return $text.Replace($from, $to)
}

$docAnchor = '<!doctype html><html><head>'
$scriptAnchor = 'var BUILD = "X";'
# The spelling this PR replaced, as two substitutions rather than as a sentence.
# The condition and the string handed to NavigateToString both went back to the
# file; putting them back is what makes "it would have failed before" a thing
# that runs on every push instead of a claim.
# The current spelling, which is what the reconstruction substitutes *out*. It
# moved when the driver stopped reaching for CoreWebView2 by reflection and
# started asking a view: there is no navMethod to test any more, and the call is
# view.navigateToString. What is being reproduced is unchanged -- the old driver
# went back to the file for the document it was about to render instead of using
# the one boot had already prepared -- and this is the second time these anchors
# have had to follow the driver, which is what a frozen spelling costs.
$navGuardNew = 'if (pendingDocument) {'
# Without the `navMethod &&` it used to carry, because there is no navMethod in
# this driver any more and a reconstruction that names one does not compile --
# which is a before-state that fails for the wrong reason and reports it as the
# right one. What the guard is about is the second read, and that is the half
# that stays.
$navGuardOld = 'if (SystemRef.IO.File.Exists(String(SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH") || ""))) {'
$navCallNew = 'view.navigateToString(pendingDocument);'
# The reconstruction lost its applyContentPolicy call, and that is a repair
# rather than a change of subject. The offline tier used to swap the document's
# content policy at run time, and the old spelling applied it here because here
# is where it built the document. The policy is html/policy.html now, included
# at assembly, so there is no such function in any build -- and a reconstruction
# calling one throws before the window opens. Measured: `oldcontrol = none`,
# `<no window title>`, and every reading below it comparing against nothing.
#
# What is being reproduced is untouched. The defect is that this went back to
# the *file* for the document it was about to render, instead of using the one
# already prepared; `extractHtmlDocument(ReadAllText(...))` is that, and the
# policy call was never part of it.
$navCallOld = 'view.navigateToString(self.extractHtmlDocument(SystemRef.IO.File.ReadAllText(SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH"))));'

$appA = Join-Path $work "a.cmd"
$appB = Join-Path $work "b.cmd"
$appOld = Join-Path $work "old.cmd"

$srcText = [System.IO.File]::ReadAllText($src)

$aText = ReplaceOnce $srcText $docAnchor ($docAnchor + '<meta name="nt-doc" content="A">') "a.cmd"
$aText = ReplaceOnce $aText $scriptAnchor 'var BUILD = "A";' "a.cmd"
[System.IO.File]::WriteAllText($appA, $aText, $utf8)

$bText = ReplaceOnce $srcText $docAnchor ($docAnchor + '<meta name="nt-doc" content="B">') "b.cmd"
$bText = ReplaceOnce $bText $scriptAnchor 'var BUILD = "B";' "b.cmd"
[System.IO.File]::WriteAllText($appB, $bText, $utf8)

# Derived from A, so the old build differs from the shipped one in the driver
# and in nothing else.
$oldText = ReplaceOnce $aText $navGuardNew $navGuardOld "old.cmd"
$oldText = ReplaceOnce $oldText $navCallNew $navCallOld "old.cmd"
[System.IO.File]::WriteAllText($appOld, $oldText, $utf8)

function Markers-In($path) {
    if (-not (Test-Path $path)) { return "gone" }
    $d = Select-String -Path $path -Pattern 'name="nt-doc" content="([A-Z])"' -ErrorAction SilentlyContinue |
         Select-Object -First 1
    $s = Select-String -Path $path -Pattern 'var BUILD = "([A-Z])";' -ErrorAction SilentlyContinue |
         Select-Object -First 1
    $dv = $(if ($d) { $d.Matches[0].Groups[1].Value } else { "?" })
    $sv = $(if ($s) { $s.Matches[0].Groups[1].Value } else { "?" })
    return "script=$sv doc=$dv"
}

Write-Output "=== docswap: the document this driver renders ==="
if ($missing.Count) {
    foreach ($m in $missing) { Fail "a build could not be derived: $m" }
    Say "nothing below is a reading"
    Save-Log
    Write-Output "=== docswap: $failures failure(s) ==="
    exit 1
}
Say "builds: a[$(Markers-In $appA)] b[$(Markers-In $appB)] old[$(Markers-In $appOld)]"
if ((Get-FileHash $appA).Hash -eq (Get-FileHash $appOld).Hash) {
    Fail "the old-spelling build is byte-identical to the shipped one; its readings are the shipped one's"
}

function Stop-App {
    Get-Process -Name "neutrinodoc" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Title-Now {
    $p = @(Get-Process -ErrorAction SilentlyContinue |
           Where-Object { $_.MainWindowTitle -like "DOCSWAP*" } |
           ForEach-Object { $_.MainWindowTitle })
    if ($p.Count) { return $p[0] }
    return ""
}

# One launch, and everything that has to happen while it is starting.
#
# No pipeline on the launcher: the batch region STARTs a detached exe that
# inherits the standard handles, so a pipe stays open for as long as the app
# lives and this app is one that never closes. The launcher is waited on as a
# process, with a bound -- appcache.ps1's lesson, and PR 20's.
#
# `act` runs once, `delayMs` after the compiled exe first appears in the process
# table. Not after the launcher exits: the launcher is still reading the .cmd
# until it does, and overwriting a batch file cmd.exe is executing is a
# different experiment from this one.
function Run-Phase($label, $build, $delayMs, $act, $waitSeconds) {
    # A phase may not begin while the last one's window is still up. This is a
    # precondition and not tidiness: PR 22's round 2 read one build's answer off
    # the previous build's title, and it looked exactly like a real reading.
    Stop-App
    $waited = 0
    while ($waited -lt 30 -and (Title-Now)) { Stop-App; $waited += 3 }
    if (Title-Now) {
        Fail "$label : a window from the previous phase would not go; the reading below is its"
    }
    Copy-Item $build $lane -Force
    $t0 = [System.Diagnostics.Stopwatch]::StartNew()
    $launch = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane -PassThru -WindowStyle Hidden

    $appearMs = -1
    while ($t0.ElapsedMilliseconds -lt 120000) {
        if (@(Get-Process -Name "neutrinodoc" -ErrorAction SilentlyContinue).Count -gt 0) {
            $appearMs = $t0.ElapsedMilliseconds
            break
        }
        Start-Sleep -Milliseconds 20
    }

    $actedMs = -1
    $after = "not attempted"
    if ($act -and $appearMs -ge 0) {
        while ($t0.ElapsedMilliseconds -lt ($appearMs + $delayMs)) { Start-Sleep -Milliseconds 10 }
        # The launcher has to be gone before the file under it is touched. It
        # exits right after the START, so this is a formality on a healthy run
        # and a reason the reading is unusable on an unhealthy one.
        $launcherGone = $launch.WaitForExit(20000)
        & $act
        $actedMs = $t0.ElapsedMilliseconds
        # What the act did to the file, read back rather than assumed. Round 1
        # of this probe could not tell a delete that never happened from a
        # document that had already been read.
        $after = Markers-In $lane
        if (-not $launcherGone) { Fail "$label : the launcher was still running when the file was touched" }
    }

    if (-not $launch.WaitForExit(240000)) { $launch.Kill() }

    $seen = New-Object System.Collections.ArrayList
    $last = ""
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    while ((Get-Date) -lt $deadline) {
        $t = Title-Now
        if ($t -and $t -ne $last) { $last = $t; [void]$seen.Add("$($t0.ElapsedMilliseconds)ms $t") }
        Start-Sleep -Milliseconds 100
    }
    Say "$label appear_ms=$appearMs acted_ms=$actedMs lane_after[$after] settled=$(if ($last) { $last } else { '<no window title>' })"
    Stop-App
    Save-Log
    # Left in a script variable rather than returned. Everything a PowerShell
    # function writes is its return value, and Say writes -- so assigning this
    # call would capture the readings instead of publishing them.
    $script:settledTitle = $last
}

# The two markers out of a settled title, or "none" where there was no title.
function Read-Markers($title) {
    if ($title -match "script=([A-Z]) doc=([A-Za-z]+)") { return "script=$($Matches[1]) doc=$($Matches[2])" }
    return "none"
}

$settledTitle = ""
$swapB = { Copy-Item $appB $lane -Force }
$remove = { Remove-Item $lane -Force -ErrorAction SilentlyContinue }

# Warm first: a first run on this runner unpacks the pinned WebView2 package,
# and no timing measured across that is the timing anything would be racing.
Run-Phase "warm" $appA 0 $null 90

Run-Phase "control" $appA 0 $null 45
$control = Read-Markers $settledTitle
Say "control = $control"
if ($control -ne "script=A doc=A") {
    Fail "control expected=script=A doc=A actual=$control -- nothing below is a reading"
}

# The before-state's own control. Without it, the old build rendering the wrong
# document and the old build not running at all are the same reading.
Run-Phase "oldcontrol" $appOld 0 $null 45
$oldControl = Read-Markers $settledTitle
Say "oldcontrol = $oldControl"
if ($oldControl -ne "script=A doc=A") {
    Fail "oldcontrol expected=script=A doc=A actual=$oldControl -- the old spelling does not run, so nothing below compares to it"
}

# Three delays, because the gap between the two reads is a few hundred
# milliseconds and it moves: the file has to be replaced after boot has read it
# -- otherwise both reads see B and the phase says nothing -- and before the
# navigation, which is what the old spelling read again. Two rounds landed in it
# at 745 and 862 ms absolute against an exe that appears near 330, so these
# bracket the delay that worked twice.
$delays = @(300, 400, 500)

# The shipped build's property, and it holds at every delay because there is
# only one read: whatever file that read found, both markers come from it. A
# disagreement is impossible here and is exactly what the old spelling produces.
foreach ($d in $delays) {
    Run-Phase "swap$d" $appA $d $swapB 45
    $got = Read-Markers $settledTitle
    Say "swap$d = $got"
    if ($got -eq "none") {
        Fail "swap$d expected=a window actual=none"
    } elseif ($got -ne "script=A doc=A" -and $got -ne "script=B doc=B") {
        Fail "swap$d expected=both markers from one read actual=$got"
    }
}

# The same three delays against the spelling this PR replaced. Each one on its
# own is a race and gets no PASS -- PR 22's lesson about a reading that moves
# with load -- but the defect has to reproduce at least once across them, or the
# comparison above has one side and "it would have failed before" is a claim
# again. If this ever goes red, the two reads stopped being far enough apart to
# get between, and that is worth being told rather than passing quietly.
$reproduced = ""
foreach ($d in $delays) {
    Run-Phase "oldswap$d" $appOld $d $swapB 45
    $got = Read-Markers $settledTitle
    Say "oldswap$d = $got"
    if ($got -eq "script=A doc=B") { $reproduced = "$reproduced $d" }
}
Say ("the old spelling rendered the second read at: " +
     $(if ($reproduced) { $reproduced.Trim() } else { "none of the delays tried" }))
if (-not $reproduced) {
    Fail "the defect did not reproduce at any of $($delays -join ',') ms; the swap assertions above have nothing to compare to"
}

# Recorded and not asserted, and this round is why. Removing the file cannot
# pick which read it breaks: at a short delay it beats boot's read, the app
# cannot read its own source, and the window never comes up -- which is the
# same "no window title" the second read failing produces. The candidate round
# asserted the shipped build renders here and read `none`, and the reading was
# right while the assertion was measuring the wrong read. Both are kept because
# the pair is still informative; neither is a pass or a fail.
Run-Phase "gone" $appA 500 $remove 45
Say "NOTE: gone = $(Read-Markers $settledTitle) (recorded, not asserted)"
Run-Phase "oldgone" $appOld 500 $remove 45
Say "NOTE: oldgone = $(Read-Markers $settledTitle) (recorded, not asserted)"

Stop-App
Save-Log
Write-Output "=== docswap: $failures failure(s) ==="
if ($failures -gt 0) { exit 1 }
exit 0
