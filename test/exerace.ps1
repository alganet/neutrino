# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# exerace.ps1 - the gap between the compile and the START is not winnable
#
# PR 20 took the implant out of the Windows launch path and PR 33 put a kept exe
# back, somewhere the app cannot reach: beside the verified script rather than
# inside the writable app folder. Compiling every launch is therefore no longer
# what most launches do, and this suite measures the path where it still is.
#
# **Which path, and why it has to be arranged rather than assumed.** A launch
# that finds a kept exe and a matching stamp STARTs it without building, so
# there is no MOVE and no window to race -- and a plant that lands on that kept
# name is simply launched, no race required. That is the trade PR 33 made and
# recorded (see appcache.ps1 and Still open), not a gap in it: anything able to
# write there can edit the .cmd, which is the program either way. Asserting
# against it here would be asserting against the design.
#
# So this lane puts the launcher on its fallback: an <name>.exe beside the
# script with no stamp of ours next to it is a file the launcher will not adopt,
# and it compiles into the app folder instead -- every launch, no stamp, exactly
# PR 20's shape. That is a path the product still has, it is the one with the
# window, and this is the suite that keeps it shut.
#
# What that window is, unchanged:
#
#     MOVE /Y "%APP_NEW%" "%APP_EXE%"     <- the file reaches its final content
#     > "%MANIFEST%" ( ...twenty ECHOs... )
#     START "" /D "%APP_FOLDER%" "%APP_EXE%"
#
# Between the first line and the last, %APP_EXE% is a predictable name holding
# the program about to run, in a directory test/appcache.ps1 measured everything
# running as this user can write. The deferral's reason was that cmd cannot hand
# CreateProcess a handle the way the Qt path hands qml a descriptor -- which
# says the obvious fix is unavailable, and says nothing about whether the race
# can be won. This measured it, over three probing rounds, and the answer is no.
#
# The gap is real in time and shut in access. From the instant the file has its
# new content to the instant the process exists is about 150 ms, and across all
# of it the name is open deny-write -- the platform's real-time scan of a fresh
# executable, then the loader's own image section. A same-uid watcher that
# hammers a replacement onto the name for that whole span, both as a rename and
# as an in-place overwrite, is refused every time: some three hundred attempts
# a launch, the rename ERROR_ACCESS_DENIED (0x80070005) and the overwrite
# ERROR_SHARING_VIOLATION (0x80070020), and not one landing before the process.
#
# So this is an assertion suite, not a probe. Its one hard assertion is that no
# plant lands before the process starts -- `won=YES` on any round is a FAIL,
# because it would mean the window had opened. The day a Windows change lets a
# replacement through, the suite goes red and names which mode and which round.
#
# What it records without asserting, because each could move without the finding
# moving, and the Method file's macOS `navout` lesson is exactly this trap:
#
#   gap      the width of the window and where the manifest write falls in it
#   race     the attempt count, the Win32 code refused with, and the launcher's
#            own recovery -- the app comes up and the next launch rebuilds
#   hold     the fix space: which share modes refuse a rename, a delete and an
#            overwrite, and that cmd's own `< file` redirection -- the one
#            handle the batch region can hold -- refuses rename and delete but
#            still permits an in-place overwrite, so a redirection is not a fix
#   predict  that %RANDOM%%RANDOM% is low entropy, sometimes constant across a
#            burst, so a randomised name would not be protection either
#
# Controls, because a refusal that measured nothing is not a pass: the clean
# launch has to bring the window up, the marker exe has to write its mark when
# run directly, and the hammer has to have made real attempts -- a round with
# too few is a throttle regression and reported as one, not a silent green.
#
# Usage: exerace.ps1 <app.cmd built from test/neutrinoloaders.js --tier=testing>

$ErrorActionPreference = "Continue"

$src = $args[0]
if (-not $src -or -not (Test-Path $src)) {
    Write-Output "usage: exerace.ps1 <app.cmd built from test/neutrinoloaders.js>"
    exit 2
}

$failures = 0
function Report($m) { Write-Output "report: $m" }
function Fail($m) { Write-Output "FAIL: $m"; $script:failures++ }

$work = Join-Path $env:TEMP ("exerace-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
$lane = Join-Path $work "neutrinorace.cmd"
Copy-Item $src $lane -Force
$folder = Join-Path $work "neutrinorace"
$exe = Join-Path $folder "neutrinorace.exe"
$manifest = Join-Path $folder "neutrinorace.exe.manifest"
# The decoy that holds the launcher on its fallback. An exe beside the script
# with no stamp of ours beside it is somebody else's file: the launcher leaves
# it alone and compiles into the app folder, every launch and without writing a
# stamp -- which is the compile-every-launch shape this suite needs. It is never
# executed and never overwritten, and appcache.ps1 asserts both.
$decoy = Join-Path $work "neutrinorace.exe"
Copy-Item "$env:WINDIR\System32\certutil.exe" $decoy -Force
$mark = Join-Path $work "poison-mark.txt"
# The host this script is already running under, rather than a name off PATH.
# PR 25's finding in this suite's own spelling: a bare program name is resolved
# by a search order, and the first two entries of it are directories under test.
$psExe = (Get-Process -Id $PID).Path

Write-Output "=== exerace: the gap between the compile and the START ==="
Report "host ps=$psExe"

function Stop-App {
    Get-Process -Name "neutrinorace" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name "poison*" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Window-Up($seconds) {
    for ($i = 0; $i -lt $seconds; $i++) {
        $p = Get-Process -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowTitle -like "LOADERS*" }
        if ($p) { return "UP" }
        Start-Sleep -Seconds 1
    }
    return "DOWN"
}

# No pipeline on the launcher. The batch region STARTs a detached exe which
# inherits the standard handles, so a pipe stays open for as long as the app
# runs and these apps are written never to close -- PR 20 lost a lane to it and
# PR 28 lost a step. Start-Process waits on the launcher alone, with a bound.
function Launch($waitSeconds) {
    # Nothing to clear. The decoy beside the script keeps the launcher on its
    # fallback, where it compiles into the app folder every launch and writes no
    # stamp -- so every round here has a MOVE, which is what there is to race.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane -PassThru -WindowStyle Hidden
    $exited = $p.WaitForExit(240000)
    if (-not $exited) { $p.Kill() }
    $sw.Stop()
    $up = Window-Up $waitSeconds
    return @{ ms = $sw.ElapsedMilliseconds; window = $up; exited = $exited }
}

function Exe-Hash($p) {
    $h = Get-FileHash $p -Algorithm SHA256 -ErrorAction SilentlyContinue
    if ($h) { return $h.Hash }
    return ""
}

# =====================================================================
# The watcher, as its own process
# =====================================================================
#
# A tight poll rather than a FileSystemWatcher: what is being measured is how
# few milliseconds an attacker needs, and an event queue drained by a runspace
# would be measuring the queue. The trigger is the launcher's own rotation --
# %APP_EXE% is moved away and then moved back -- so the watcher waits for the
# name to go, then for it to return, and replaces it the moment it does.
#
# Mode `observe` replaces nothing and reports the timeline. Mode `attack`
# replaces and reports whether the replacement returned success, which is the
# control for a NO: a refused rename and a rename never attempted read alike.
$watcher = Join-Path $work "watch.ps1"
@'
param([string]$Target, [string]$Poison, [string]$Log, [string]$Mode, [int]$Deadline)
$ErrorActionPreference = "Continue"
$folder = Split-Path -Parent $Target
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lines = New-Object System.Collections.ArrayList
function L($m) { [void]$lines.Add($m) }
$names = @{}
$gone = -1; $edge = -1; $firstOk = -1; $attempts = 0; $result = "not-attempted"; $why = ""
$manifest = "$Target.manifest"
$manifestAt = -1
$procAt = -1
$pname = [System.IO.Path]::GetFileNameWithoutExtension($Target)

# Round 1 read `refused:MethodInvocationException` three times out of three,
# which is PR 25's lesson in this suite's own spelling: a catch that reports the
# wrapper reports nothing. PowerShell wraps a throwing .NET method in a
# MethodInvocationException and puts the answer in InnerException, so the chain
# is what gets walked and the Win32 code at the bottom of it is what says
# whether this was a sharing violation, a missing file or an access denial.
function Why($e) {
    $x = $e; $names = @(); $msg = ""; $hr = ""
    while ($null -ne $x -and $names.Count -lt 4) {
        $names += $x.GetType().Name
        if ($x.Message) { $msg = $x.Message }
        try { $hr = "0x" + ("{0:X8}" -f $x.HResult) } catch { }
        $x = $x.InnerException
    }
    $msg = ($msg -replace "\s+", " ")
    if ($msg.Length -gt 90) { $msg = $msg.Substring(0, 90) }
    return ($names -join "<") + "/" + $hr + "/" + $msg
}

# The edge is the file reaching its new content, and not the file going away.
#
# The launcher's two MOVEs are consecutive cmd statements, so the window where
# the name does not exist at all is a couple of milliseconds -- round 1 saw it
# once in five launches, one millisecond wide -- and Start-Sleep does not go
# below the scheduler's tick, so a polling loop with any sleep in it steps over
# that window without seeing it. Worse, triggering on the disappearance would
# lose the race by construction: a replacement written while %APP_EXE% is
# absent is overwritten by the launcher's own MOVE a moment later, and the
# watcher would report a refusal it had caused itself.
#
# So the baseline is the previous launch's file -- existence, length and last
# write -- and the edge is the first read that differs from it with the file
# present. That is exactly the state the START is about to run. The loop does
# not sleep: what is being measured is how few milliseconds an attacker needs,
# and a sleep would be measuring the scheduler.
function Stat() {
    if (-not [System.IO.File]::Exists($Target)) { return "absent" }
    $fi = New-Object System.IO.FileInfo $Target
    return "" + $fi.Length + ":" + $fi.LastWriteTimeUtc.Ticks
}
$base = Stat
$spin = 0
while ($sw.ElapsedMilliseconds -lt $Deadline) {
    $now = Stat
    if ($now -eq "absent") {
        if ($gone -lt 0) { $gone = $sw.ElapsedMilliseconds }
    } elseif ($now -ne $base) {
        $edge = $sw.ElapsedMilliseconds
        break
    }
    if ($Mode -eq "observe" -and ($spin++ % 500) -eq 0) {
        foreach ($f in [System.IO.Directory]::GetFiles($folder, "*.exe")) { $names[[System.IO.Path]::GetFileName($f)] = 1 }
    }
}

# A tight hammer from the edge, and Get-Process kept out of it. Round 2 walked
# the exception chain -- overwrite got ERROR_SHARING_VIOLATION (0x80070020),
# rename got ERROR_ACCESS_DENIED (0x80070005), so at the first instant the
# content appears the file is already open deny-write. But it attempted only
# once per launch: the proc poll's Get-Process is tens of milliseconds and ate
# the whole window, so one refused attempt is not proof the window is shut, only
# that one badly-timed syscall lost. This loop attempts every iteration with
# nothing slow in its path, and samples the process every 40th try alone -- so
# the reading becomes "N attempts across the whole startup, none landed" rather
# than "one did not".
#
# It hammers for a fixed span past the process coming up, not until it: a plant
# that lands after the image is mapped reaches only the next launch, which
# test/appcache.ps1 measures being overwritten, so those are counted as
# `late` and kept apart from a real win. `won` is a plant that landed while the
# process did not yet exist -- the only kind that runs.
$hardStop = $sw.ElapsedMilliseconds + 4000
if ($hardStop -gt $Deadline) { $hardStop = $Deadline }
$graceUntil = $hardStop
$firstHr = ""
$k = 0
while ($sw.ElapsedMilliseconds -lt $hardStop -and $sw.ElapsedMilliseconds -lt $graceUntil) {
    if ($manifestAt -lt 0 -and [System.IO.File]::Exists($manifest)) { $manifestAt = $sw.ElapsedMilliseconds }
    if (($k++ % 40) -eq 0 -and $procAt -lt 0) {
        if (@(Get-Process -Name $pname -ErrorAction SilentlyContinue).Count -gt 0 -or
            @(Get-Process -Name "poison*" -ErrorAction SilentlyContinue).Count -gt 0) {
            $procAt = $sw.ElapsedMilliseconds
            # 250 ms past the process to prove the name stays shut, then stop --
            # a plant that only lands now is the next launch's problem.
            $graceUntil = $sw.ElapsedMilliseconds + 250
        }
    }
    if ($edge -lt 0 -or $Mode -eq "observe") { continue }
    $now = $sw.ElapsedMilliseconds
    try {
        if ($Mode -eq "overwrite") {
            [System.IO.File]::Copy($Poison, $Target, $true)
        } else {
            # A fresh copy each try, because a successful Move consumes the
            # source; the copy is staging and the Move is the atomic plant that
            # is being timed. Cleaned on the failure that is the usual outcome.
            $tmp = "$Poison.stage"
            [System.IO.File]::Copy($Poison, $tmp, $true)
            try { [System.IO.File]::Move($tmp, $Target, $true) }
            catch { [System.IO.File]::Delete($tmp); throw }
        }
        $attempts++
        if ($firstOk -lt 0) { $firstOk = $now }
        break
    } catch {
        $attempts++
        if ($firstHr -eq "") { $firstHr = Why $_.Exception }
        $result = "refused"
    }
}
$won = "no"
if ($firstOk -ge 0) {
    if ($procAt -lt 0 -or $firstOk -lt $procAt) { $won = "YES"; $result = "landed" }
    else { $won = "late"; $result = "landed-late" }
}
L "gone_ms=$gone edge_ms=$edge ok_ms=$firstOk tries=$attempts manifest_ms=$manifestAt proc_ms=$procAt plant=$result won=$won"
L "why=$firstHr"
L ("names=" + (($names.Keys | Sort-Object) -join ","))
Set-Content -LiteralPath $Log -Value $lines -Encoding ASCII
'@ | Set-Content -Path $watcher -Encoding ASCII

function Start-Watcher($mode, $log, $poison) {
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    return Start-Process -FilePath $psExe `
        -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $watcher, `
                      "-Target", $exe, "-Poison", $poison, "-Log", $log, "-Mode", $mode, `
                      "-Deadline", "40000" `
        -PassThru -WindowStyle Hidden
}

function Read-Watcher($p, $log) {
    if ($p -and -not $p.HasExited) { $p.WaitForExit(90000) | Out-Null }
    if ($p -and -not $p.HasExited) { $p.Kill(); return "watcher did not finish" }
    if (Test-Path $log) { return ((Get-Content $log) -join " ") }
    return "watcher wrote no log"
}

# =====================================================================
# control: a warm folder, and a launch that comes up
# =====================================================================
#
# The first launch fetches WebView2, which is the long one and is not a reading
# of anything here. Every section below runs against a folder that already has
# the package in it.
Stop-App
$warm = Launch 240
Report "control warm window=$($warm.window) launcher_ms=$($warm.ms) launcher_exited=$($warm.exited)"
if ($warm.window -ne "UP") {
    Fail "control expected=the shipped build comes up actual=DOWN; nothing below is a reading"
}
Stop-App

# The marker exe. Built with the framework's own compiler, the way
# test/appcache.ps1 builds its own, and proven live before it is planted -- an
# exe that writes nothing makes every refusal below look like a pass.
$jsc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\jsc.exe"
if (-not (Test-Path $jsc)) { $jsc = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\jsc.exe" }
$poisonSrc = Join-Path $work "poison.js"
$markEscaped = $mark.Replace("\", "\\")
@"
import System;
import System.IO;
File.AppendAllText("$markEscaped", "poisoned " + DateTime.UtcNow.ToString("o") + "\r\n");
"@ | Set-Content -Path $poisonSrc -Encoding ASCII
$poisonExe = Join-Path $work "poison.exe"
& $jsc /nologo /t:exe "/out:$poisonExe" $poisonSrc 2>&1 | Out-Null
$poisonOk = Test-Path $poisonExe
if ($poisonOk) {
    Remove-Item $mark -Force -ErrorAction SilentlyContinue
    & $poisonExe 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $poisonOk = Test-Path $mark
}
Report "control poison built=$(Test-Path $poisonExe) live=$(if ($poisonOk) { 'YES' } else { 'NO' })"
if (-not $poisonOk) { Fail "control expected=the marker exe writes its mark when run actual=silent; the race section is unmeasured" }

# =====================================================================
# gap: how wide, and where the manifest falls
# =====================================================================
#
# Two launches, because one number is not a width. The manifest is removed
# first so its reappearance is this launch's write and not the last one's.
for ($i = 1; $i -le 2; $i++) {
    Stop-App
    Remove-Item $manifest -Force -ErrorAction SilentlyContinue
    $log = Join-Path $work "observe$i.log"
    $w = Start-Watcher "observe" $log $poisonExe
    Start-Sleep -Milliseconds 800
    $r = Launch 60
    $line = Read-Watcher $w $log
    Report "gap round=$i window=$($r.window) $line"
}

# =====================================================================
# race: a watcher that knows only the name
# =====================================================================
#
# Round 1 attempted once, was refused once, and reported NO through a catch that
# named only the wrapper -- so it read `refused` three times and could not say
# of what. Two things change. The watcher walks the exception chain to the
# Win32 code, and it retries across the whole window instead of firing one
# syscall into a seventeen-millisecond gap. And the attack is run in both
# spellings, because round 1's `hold` section measured that the answer differs
# by act: a rename and an overwrite need different sharing to refuse, so the
# launcher may be open to one and not the other.
#
# `won` is the reading, and it is stricter than `ran`: the plant has to land
# before the process exists. A rename that lands after the image is already
# mapped reaches only the next launch, which test/appcache.ps1 measures being
# overwritten, so it is `too-late` and not a win. Three rounds each, reported
# separately -- the question is whether it is reliable, not whether it is
# possible once.
$poisonHash = Exe-Hash $poisonExe
if ($poisonOk) {
    foreach ($mode in @("rename", "overwrite")) {
        for ($i = 1; $i -le 3; $i++) {
            Stop-App
            Remove-Item $mark -Force -ErrorAction SilentlyContinue
            $roundPoison = Join-Path $work "poison-$mode-r$i.exe"
            Copy-Item $poisonExe $roundPoison -Force
            $log = Join-Path $work "attack-$mode-$i.log"
            $w = Start-Watcher $mode $log $roundPoison
            Start-Sleep -Milliseconds 800
            $r = Launch 30
            $line = Read-Watcher $w $log
            Start-Sleep -Seconds 3
            $ran = Test-Path $mark
            $left = Exe-Hash $exe
            Report ("race $mode round=$i ran=" + $(if ($ran) { "YES" } else { "NO" }) +
                    " realapp=$($r.window) exe_is_poison=" +
                    $(if ($left -eq $poisonHash) { "YES" } else { "NO" }) +
                    " $line")
            # The finding, asserted: a plant that lands before the process
            # exists is a window that opened. `won=YES` and a poison exe that
            # actually ran are the same event read two ways; either is a FAIL.
            if ($line -match "won=YES") { Fail "race $mode round=$i a replacement landed before the process started ($line)" }
            if ($ran) { Fail "race $mode round=$i the planted exe ran ($line)" }
            if ($r.window -ne "UP") { Fail "race $mode round=$i the real app did not come up, so the refusal is unmeasured ($line)" }
            # The hammer has to have made real attempts, or a refusal is just a
            # loop that never ran. Round 3 measured 114 to 274 a launch; a floor
            # of 20 catches a future throttle without being flaky.
            $tries = 0
            if ($line -match "tries=(\d+)") { $tries = [int]$Matches[1] }
            if ($tries -lt 20) { Fail "race $mode round=$i only $tries attempt(s); the window was not hammered ($line)" }
        }
        # The folder is left holding whatever the last round put there; the next
        # launch is what removes it, and that is the launcher's own claim.
        Stop-App
        $rest = Launch 60
        Report "race $mode recovered window=$($rest.window) exe_rebuilt=$(if ((Exe-Hash $exe) -ne $poisonHash) { 'YES' } else { 'NO' })"
    }
} else {
    Report "race unmeasured: no marker exe"
}
Stop-App

# =====================================================================
# hold: which share modes refuse a replacement
# =====================================================================
#
# The fix space, measured away from the launcher. An open handle is the only
# thing that makes a path on this platform unreplaceable, and the batch region
# can hold exactly one kind: cmd's own `< file` redirection. Renaming and
# deleting a file both need the openers to have granted FILE_SHARE_DELETE;
# overwriting in place needs FILE_SHARE_WRITE. So the three acts are asked
# separately, because a share mode that stops two of them and not the third is
# still a narrowing and has to be readable as one.
$scratchDir = Join-Path $work "hold"
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null

function Try-Acts($label, $file) {
    $ren = "no"; $del = "no"; $ovr = "no"
    $renamed = "$file.renamed"
    try { Move-Item -LiteralPath $file -Destination $renamed -Force -ErrorAction Stop; $ren = "YES"
          Move-Item -LiteralPath $renamed -Destination $file -Force -ErrorAction SilentlyContinue } catch { $ren = "refused" }
    try { $s = [System.IO.File]::Open($file, "Open", "Write", "ReadWrite"); $s.Close(); $ovr = "YES" } catch { $ovr = "refused" }
    $copy = "$file.bak"
    Copy-Item $file $copy -Force -ErrorAction SilentlyContinue
    try { Remove-Item -LiteralPath $file -Force -ErrorAction Stop; $del = "YES"
          Copy-Item $copy $file -Force -ErrorAction SilentlyContinue } catch { $del = "refused" }
    Remove-Item $copy -Force -ErrorAction SilentlyContinue
    Report "hold $label rename=$ren overwrite=$ovr delete=$del"
}

$modes = @(
    @{ n = "none";      share = [System.IO.FileShare]::None },
    @{ n = "read";      share = [System.IO.FileShare]::Read },
    @{ n = "readwrite"; share = [System.IO.FileShare]::ReadWrite },
    @{ n = "rwdelete";  share = ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete) }
)
foreach ($m in $modes) {
    $f = Join-Path $scratchDir ("h-" + $m.n + ".exe")
    Copy-Item $poisonExe $f -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $f)) { Set-Content -LiteralPath $f -Value "not-an-exe" -Encoding ASCII }
    $stream = $null
    try { $stream = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $m.share) } catch { Report "hold $($m.n) could not open: $($_.Exception.GetType().Name)" }
    if ($stream) { Try-Acts $m.n $f; $stream.Close() }
}
# Nothing holding it at all: the control for every "refused" above.
$fFree = Join-Path $scratchDir "h-unheld.exe"
Copy-Item $poisonExe $fFree -Force -ErrorAction SilentlyContinue
Try-Acts "unheld" $fFree

# cmd's own redirection, which is the only handle the batch region has. The
# block keeps stdin open for its whole duration, so the acts are tried while a
# ping is running inside it.
$fCmd = Join-Path $scratchDir "h-cmd.exe"
Copy-Item $poisonExe $fCmd -Force -ErrorAction SilentlyContinue
$cmdHold = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c", "(ping -n 8 127.0.0.1 >NUL) < `"$fCmd`"" `
    -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 1200
if ($cmdHold.HasExited) {
    Report "hold cmdredir unmeasured: the holder exited early (exit $($cmdHold.ExitCode))"
} else {
    Try-Acts "cmdredir" $fCmd
}
if (-not $cmdHold.HasExited) { $cmdHold.WaitForExit(20000) | Out-Null }
if (-not $cmdHold.HasExited) { $cmdHold.Kill() }

# =====================================================================
# predict: what a name-guessing attacker would have to guess
# =====================================================================
#
# %RANDOM% is cmd's own generator and the launcher concatenates two of them.
# If STARTing the compiled name instead of rotating into a fixed one is on the
# table, what it buys is exactly the entropy of that string -- so it is read
# rather than assumed. Read out of cmd directly, and the observer rounds above
# also collected the names that appeared in the folder.
$rands = @()
for ($i = 0; $i -lt 6; $i++) {
    $rands += ((& cmd.exe /c "ECHO %RANDOM%%RANDOM%" | Out-String).Trim())
}
Report "predict cmd_random=$($rands -join ',')"
$obs = @()
foreach ($f in Get-ChildItem $work -Filter "observe*.log" -ErrorAction SilentlyContinue) {
    $obs += ((Get-Content $f.FullName | Where-Object { $_ -like "names=*" }) -join "")
}
Report "predict seen=$($obs -join ' ')"

Stop-App
Write-Output "=== exerace: $failures failure(s) ==="
if ($failures -gt 0) { exit 1 }
exit 0
