# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# appcache.ps1 - the exe is compiled once and kept, and it is kept somewhere the
# app cannot reach
#
# This suite used to assert the opposite, and the reason it did is the reason
# this one exists. The launcher compiled into `<app folder>\<name>.exe` and
# reused it while a stamp beside it -- the source's size and modification time
# -- still matched. Both files sat in the app folder, the one directory
# netinstall leaves writable, so the app could replace the exe and leave the
# stamp: measured on a runner as `poison ran=YES realapp=DOWN
# stamp_unchanged=YES`, and it went on being launched until the source itself
# changed. The answer then was to compile every launch, at 290 ms each.
#
# The placement was the defect, not the caching. netinstall puts the verified
# .cmd one level *above* the only writable directory -- "an app cannot rewrite
# the launcher it was verified from" -- so an exe kept beside the script is out
# of reach of the process the recompile was defending against. Everything else
# that can write there can write the .cmd itself and already runs as this user,
# which is everything poisoning the exe would have bought it.
#
# What this asserts, each of which fails against the commit before this one:
#
#   placement  the exe and its stamp are beside the script, and the app folder
#              -- the writable one -- holds no program at all
#   stamp      the stamp is the source's SHA-256
#   cached     a second launch does not rebuild, and still comes up
#   changed    an edited source does rebuild, and the stamp follows it
#   appfolder  an exe planted where the old one lived is never launched
#   adopt      an exe beside the script that this launcher did not write is not
#              overwritten, and the compile falls back into the app folder
#   second     a second instance still opens while the first holds its exe
#   slot       a <name>.build directory beside the script takes the program,
#              and nothing is left beside the script
#   sealed     a slot this launch cannot write is run rather than rebuilt
#
# Controls: the shipped build has to come up, and the planted exe has to be
# proven live by running it directly -- an exe that does nothing would make
# every refusal here look like a pass.
#
# Recorded and not asserted: the kept exe is trusted. Anything able to write the
# script's own directory can replace it and be launched, and that is the trade
# this placement makes rather than a gap in it -- the same writer can edit the
# .cmd, which is the program either way. Under netinstall that directory is the
# read-only shelf and this does not arise; standalone there is no pin and the
# .cmd is as writable as the exe.
#
# Usage: appcache.ps1 <app.cmd built from test/neutrinoloaders.js>

$ErrorActionPreference = "Continue"

$src = $args[0]
if (-not $src -or -not (Test-Path $src)) {
    Write-Output "usage: appcache.ps1 <app.cmd built from test/neutrinoloaders.js>"
    exit 2
}

# The six words. Twenty-eight checks, every one of them a `report:` line
# carrying the reading with an `if (bad) { Fail }` under it -- so on the run
# where the exe is compiled once, kept, and kept out of reach, this file said
# nothing any reader downstream could see. The nine sections its header names
# are the families below.
. (Join-Path $PSScriptRoot "lib\harness.ps1")

function Report($m) { nt_report $m }

$work = Join-Path $env:TEMP ("appcache-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
$lane = Join-Path $work "neutrinocache.cmd"
Copy-Item $src $lane -Force
# Beside the script, which is the whole point.
$exe = Join-Path $work "neutrinocache.exe"
$stamp = Join-Path $work "neutrinocache.stamp"
$manifest = Join-Path $work "neutrinocache.exe.manifest"
# The app folder is still <name>/ and is still the writable one. What changed is
# that the program is no longer in it.
$folder = Join-Path $work "neutrinocache"
$folderExe = Join-Path $folder "neutrinocache.exe"
$mark = Join-Path $work "poison-mark.txt"

function Stop-App {
    Get-Process -Name "neutrinocache" -ErrorAction SilentlyContinue |
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

function Exe-Hash {
    $h = Get-FileHash $exe -Algorithm SHA256 -ErrorAction SilentlyContinue
    if ($h) { return $h.Hash }
    return ""
}

# No pipeline on the launcher, and that is the whole of this comment. The batch
# region STARTs a detached exe which inherits the standard handles, so a pipe
# stays open for as long as the *app* runs -- and this app is one that never
# closes on purpose. The first draft wrote `| Out-Null` here and hung the lane
# until the step timeout, having published one line. Start-Process waits on the
# launcher alone, and it waits with a bound.
function Launch($waitSeconds) {
    Stop-App
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane -PassThru -WindowStyle Hidden
    $exited = $p.WaitForExit(180000)
    if (-not $exited) { $p.Kill() }
    $sw.Stop()
    $up = Window-Up $waitSeconds
    return @{ ms = $sw.ElapsedMilliseconds; window = $up; exited = $exited }
}

Write-Output "=== appcache: the exe is compiled once and kept ==="

# =====================================================================
# placement: beside the script, and nothing in the writable folder
# =====================================================================
# WebView2 is fetched on a first run, so the first window wait is the long one.
$r1 = Launch 180
if (-not (Test-Path $exe)) {
    nt_fail appcache.control.compiled "no exe beside the script after a first launch; nothing below is a reading"
} else {
    nt_pass appcache.control.compiled "a first launch left an exe beside the script"
}
Report "control window=$($r1.window) build_ms=$($r1.ms) launcher_exited=$($r1.exited)"
if ($r1.window -ne "UP") {
    nt_fail appcache.control.launched "the shipped build did not come up; every reading below is unmeasured"
} else {
    nt_pass appcache.control.launched "the shipped build comes up"
}

Report "placement exe=$(Test-Path $exe) stamp=$(Test-Path $stamp) manifest=$(Test-Path $manifest) app_folder_exe=$(Test-Path $folderExe)"
if (-not (Test-Path $stamp)) {
    nt_fail appcache.placement.stamp "placement expected=a stamp beside the script actual=none"
} else {
    nt_pass appcache.placement.stamp "the stamp is beside the script"
}
if (Test-Path $folderExe) {
    nt_fail appcache.placement.appfolder-clean "placement expected=no program in the writable app folder actual=$folderExe"
} else {
    nt_pass appcache.placement.appfolder-clean "the writable app folder holds no program"
}

# What the two directories' own permissions say about who is in this threat
# model. The app folder's writers are the reason the program is not in it.
$acl = (Get-Acl $folder).Access |
       Where-Object { $_.FileSystemRights -match "Write|Modify|FullControl" } |
       ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique
Report "acl app_folder_writers=$($acl -join ',')"

# =====================================================================
# stamp: the source's digest, not its size and modification time
# =====================================================================
$srcHash = (Get-FileHash $lane -Algorithm SHA256).Hash
$stamped = ""
if (Test-Path $stamp) { $stamped = (Get-Content $stamp -Raw).Trim() }
Report "stamp matches_source=$($stamped -eq $srcHash) length=$($stamped.Length)"
if ($stamped -ne $srcHash) {
    nt_fail appcache.stamp.sha256 "stamp expected=the source's SHA-256 actual='$stamped'"
} else {
    nt_pass appcache.stamp.sha256 "the stamp is the source's SHA-256"
}

# =====================================================================
# cached: a second launch does not rebuild
# =====================================================================
$hash1 = Exe-Hash
$mtime1 = (Get-Item $exe -ErrorAction SilentlyContinue).LastWriteTimeUtc
$r2 = Launch 90
$hash2 = Exe-Hash
$mtime2 = (Get-Item $exe -ErrorAction SilentlyContinue).LastWriteTimeUtc
Report "cached rebuilt=$(if ($hash1 -ne $hash2) { 'YES' } else { 'NO' }) mtime_moved=$(if ($mtime1 -ne $mtime2) { 'YES' } else { 'NO' }) window=$($r2.window) launch_ms=$($r2.ms)"
if ($hash1 -ne $hash2) {
    nt_fail appcache.cached.reused "cached expected=the second launch reuses the exe actual=it was rebuilt"
} else {
    nt_pass appcache.cached.reused "a second launch reuses the exe"
}
if ($mtime1 -ne $mtime2) {
    nt_fail appcache.cached.untouched "cached expected=the exe is not rewritten actual=its mtime moved"
} else {
    nt_pass appcache.cached.untouched "the kept exe is not rewritten"
}
if ($r2.window -ne "UP") {
    nt_fail appcache.cached.comes-up "cached expected=the app comes up from the kept exe actual=DOWN"
} else {
    nt_pass appcache.cached.comes-up "the app comes up from the kept exe"
}

# And the digest was taken, because here it is read. This is the other half of
# the assertion netinstall/test/e2e.sh makes: there the script sits above the
# only writable directory, no stamp can be kept, nothing compares a digest with
# anything, and a launcher.hash left behind would mean a certutil ran for a
# reader that does not exist. Beside the script a stamp *is* kept and *is*
# compared, so the file has to be there -- without this arm the other one
# passes just as well against a launcher that stopped hashing entirely.
$hashFile = Join-Path $folder "launcher.hash"
Report "cached digest=$(if (Test-Path $hashFile) { 'taken' } else { 'not taken' })"
if (-not (Test-Path $hashFile)) {
    nt_fail appcache.cached.digest "cached expected=the digest is taken where a stamp is compared actual=no launcher.hash"
} else {
    nt_pass appcache.cached.digest "the digest is taken where a stamp is compared"
}

# =====================================================================
# changed: an edited source rebuilds, and the stamp follows
# =====================================================================
# The positive control for `cached`. Without it, a launcher that never rebuilt
# anything -- or never compiled in the first place -- reads the same as one that
# caches correctly.
Stop-App
# A line comment, not a REM. Everything past the batch region is what jsc
# compiles, and the file's last line is a `//` comment -- append anything that
# is not JavaScript and the rebuild this arm is testing fails to compile.
Add-Content -Path $lane -Value "`r`n// __APPCACHE_EDIT__"
$r3 = Launch 90
$hash3 = Exe-Hash
$srcHash3 = (Get-FileHash $lane -Algorithm SHA256).Hash
$stamped3 = ""
if (Test-Path $stamp) { $stamped3 = (Get-Content $stamp -Raw).Trim() }
Report "changed rebuilt=$(if ($hash3 -ne $hash2) { 'YES' } else { 'NO' }) stamp_follows=$($stamped3 -eq $srcHash3) window=$($r3.window)"
if ($hash3 -eq $hash2) {
    nt_fail appcache.changed.rebuilt "changed expected=an edited source rebuilds actual=the old exe was reused"
} else {
    nt_pass appcache.changed.rebuilt "an edited source rebuilds"
}
if ($stamped3 -ne $srcHash3) {
    nt_fail appcache.changed.stamp-follows "changed expected=the stamp names the new source actual='$stamped3'"
} else {
    nt_pass appcache.changed.stamp-follows "the stamp follows the new source"
}
if ($r3.window -ne "UP") {
    nt_fail appcache.changed.comes-up "changed expected=the rebuilt app comes up actual=DOWN"
} else {
    nt_pass appcache.changed.comes-up "the rebuilt app comes up"
}

# =====================================================================
# appfolder: nothing launches out of the writable directory any more
# =====================================================================
$jsc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\jsc.exe"
if (-not (Test-Path $jsc)) { $jsc = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\jsc.exe" }
$poisonSrc = Join-Path $work "poison.js"
$markEscaped = $mark.Replace("\", "\\")
@"
import System;
import System.IO;
File.WriteAllText("$markEscaped", "poisoned " + DateTime.UtcNow.ToString("o"));
"@ | Set-Content -Path $poisonSrc -Encoding ASCII
$poisonExe = Join-Path $work "poison.exe"
& $jsc /nologo /t:exe "/out:$poisonExe" $poisonSrc 2>&1 | Out-Null
if (-not (Test-Path $poisonExe)) {
    # "unmeasured" is the word this line already used, and it is what a skip is
    # for. The marker is not the thing under test -- it is the instrument that
    # makes the refusal below distinguishable from a pass -- so a jsc that will
    # not build it leaves three questions unanswerable rather than false.
    $why = "the marker exe would not build with jsc, so the appfolder section had no instrument"
    nt_skip appcache.control.poison-live $why
    nt_skip appcache.appfolder.not-launched $why
    nt_skip appcache.appfolder.comes-up $why
} else {
    # Proven against a program that is not under test: an exe that writes
    # nothing would make the refusal below indistinguishable from a pass.
    Remove-Item $mark -Force -ErrorAction SilentlyContinue
    & $poisonExe 2>&1 | Out-Null
    $live = Test-Path $mark
    Report "control poison live=$(if ($live) { 'YES' } else { 'NO' })"
    if (-not $live) {
        nt_fail appcache.control.poison-live "control expected=the marker exe writes its mark when run actual=silent"
    } else {
        nt_pass appcache.control.poison-live "the marker exe writes its mark when run directly"
    }

    # Where the program used to live, and where a confined app can still write.
    Stop-App
    Remove-Item $mark -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Copy-Item $poisonExe $folderExe -Force
    $r4 = Launch 90
    $ran = Test-Path $mark
    Report ("appfolder ran=" + $(if ($ran) { "YES" } else { "NO" }) + " realapp=$($r4.window)")
    if ($ran) {
        nt_fail appcache.appfolder.not-launched "appfolder expected=nothing is launched out of the writable folder actual=the planted exe ran"
    } else {
        nt_pass appcache.appfolder.not-launched "an exe planted in the writable folder is never launched"
    }
    if ($r4.window -ne "UP") {
        nt_fail appcache.appfolder.comes-up "appfolder expected=the app comes up regardless actual=DOWN"
    } else {
        nt_pass appcache.appfolder.comes-up "the app comes up regardless of the planted exe"
    }
    Remove-Item $folderExe -Force -ErrorAction SilentlyContinue
}

# =====================================================================
# adopt: a file beside the script that this launcher did not write
# =====================================================================
# The stamp is what says "this exe is ours". Without one beside it, an exe with
# the name this launcher would use belongs to somebody else, and the compile
# goes to the app folder instead of overwriting it.
Stop-App
$work2 = Join-Path $env:TEMP ("appcache2-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work2 -Force | Out-Null
$lane2 = Join-Path $work2 "neutrinocache.cmd"
Copy-Item $src $lane2 -Force
$foreign = Join-Path $work2 "neutrinocache.exe"
Copy-Item "$env:WINDIR\System32\certutil.exe" $foreign -Force
$foreignHash = (Get-FileHash $foreign -Algorithm SHA256).Hash
$p2 = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane2 -PassThru -WindowStyle Hidden
if (-not $p2.WaitForExit(180000)) { $p2.Kill() }
$up2 = Window-Up 180
$stillForeign = ((Get-FileHash $foreign -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash -eq $foreignHash)
$fellBack = Test-Path (Join-Path $work2 "neutrinocache\neutrinocache.exe")
Report "adopt foreign_untouched=$stillForeign fell_back=$fellBack window=$up2"
if (-not $stillForeign) {
    nt_fail appcache.adopt.untouched "adopt expected=a file this launcher did not write is left alone actual=it was overwritten"
} else {
    nt_pass appcache.adopt.untouched "a file this launcher did not write is left alone"
}
if (-not $fellBack) {
    nt_fail appcache.adopt.fell-back "adopt expected=the compile falls back into the app folder actual=no exe there"
} else {
    nt_pass appcache.adopt.fell-back "the compile falls back into the app folder"
}
Stop-App

# =====================================================================
# second: a running instance holds its own exe open
# =====================================================================
#
# Still measured, because the rebuild path still rotates: overwriting a running
# exe is refused by Windows and renaming it is not, so a rebuild while an
# earlier window is open would otherwise fail outright.
Stop-App
$first = Launch 90
$firstUp = $first.window
$p3 = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane -PassThru -WindowStyle Hidden
$p3Exited = $p3.WaitForExit(180000)
if (-not $p3Exited) { $p3.Kill() }
Start-Sleep -Seconds 10
$instances = @(Get-Process -Name "neutrinocache" -ErrorAction SilentlyContinue).Count
Report "second first=$firstUp launcher_exited=$p3Exited instances=$instances exit=$($p3.ExitCode)"
if ($p3.ExitCode -ne 0) {
    nt_fail appcache.second.succeeds "second expected=a second launch succeeds while the first runs actual=exit $($p3.ExitCode)"
} else {
    nt_pass appcache.second.succeeds "a second launch succeeds while the first runs"
}
if ($instances -lt 2) {
    nt_fail appcache.second.instances "second expected=two instances actual=$instances"
} else {
    nt_pass appcache.second.instances "two instances are up at once"
}

# =====================================================================
# slot: a <name>.build directory beside the script is where the program goes
# =====================================================================
#
# netinstall makes one of these and opens it for the launch that owes a build,
# and the launcher finds it from its own location with nothing in the
# environment naming it. There is no netinstall here, so what this measures is
# the half that lives in the launcher: the derivation, and which of the three
# placements wins.
#
# Writable is the granted state -- under netinstall "this directory takes a
# write" is "netinstall granted it this launch" -- so a writable slot beside a
# standalone script builds into it and keeps no stamp, because netinstall is
# what holds the record and there is no netinstall here.
Stop-App
$work3 = Join-Path $env:TEMP ("appcache3-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work3 -Force | Out-Null
$lane3 = Join-Path $work3 "neutrinocache.cmd"
Copy-Item $src $lane3 -Force
$slot3 = Join-Path $work3 "neutrinocache.build"
New-Item -ItemType Directory -Path $slot3 -Force | Out-Null
$slotExe = Join-Path $slot3 "neutrinocache.exe"

$p4 = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane3 -PassThru -WindowStyle Hidden
if (-not $p4.WaitForExit(180000)) { $p4.Kill() }
$up4 = Window-Up 180
$besideExe = Test-Path (Join-Path $work3 "neutrinocache.exe")
$besideStamp = Test-Path (Join-Path $work3 "neutrinocache.stamp")
Report "slot exe=$(Test-Path $slotExe) beside_exe=$besideExe beside_stamp=$besideStamp window=$up4"
if (-not (Test-Path $slotExe)) {
    nt_fail appcache.slot.program "slot expected=the program in the slot actual=none"
} else {
    nt_pass appcache.slot.program "the program is in the slot"
}
if ($besideExe) {
    nt_fail appcache.slot.no-exe-beside "slot expected=nothing beside the script actual=an exe"
} else {
    nt_pass appcache.slot.no-exe-beside "no exe is left beside the script"
}
if ($besideStamp) {
    nt_fail appcache.slot.no-stamp-beside "slot expected=no stamp beside the script actual=one"
} else {
    nt_pass appcache.slot.no-stamp-beside "no stamp is left beside the script"
}
if ($up4 -ne "UP") {
    nt_fail appcache.slot.comes-up "slot expected=the app comes up from the slot actual=DOWN"
} else {
    nt_pass appcache.slot.comes-up "the app comes up from the slot"
}

# =====================================================================
# sealed: a slot this launch cannot write is one it runs and does not rebuild
# =====================================================================
#
# The deny ACE is standing in for what netinstall does with a mandatory label,
# and it is the same question either way: the launcher's only signal is whether
# the write lands. Without this arm a launcher that rebuilt every launch into a
# writable slot would read exactly like one that keeps what is there.
#
# The ACE is built into a variable before icacls is handed it, and then the
# seal is checked rather than assumed. `& icacls $d /deny "$env:USERNAME:(W)"`
# does not survive PowerShell 5.1's native argument parsing -- icacls answers
# `Invalid parameter "(W)"` and exits 87, having changed nothing. Piped to
# Out-Null that is silent, so the arm went on to launch against a slot that was
# still writable, which is a *granted* slot, which is one the launcher is
# supposed to rebuild. It then failed the product for doing exactly the right
# thing: `sealed rebuilt=YES mtime_moved=YES` on the first Windows runner this
# suite ever saw, and again on a Windows 11 client.
#
# So the write is attempted before the launch is. A seal that did not take is a
# broken instrument and says so, rather than being reported as a launcher that
# will not use its cache.
if (-not (Test-Path $slotExe)) {
    # The slot section above did not leave a program to seal, so there is
    # nothing here to run rather than rebuild. Said, rather than left out: the
    # three cases below applied to this lane and would otherwise have been
    # three cells the grid could not tell from a suite that never ran.
    $why = "the slot section left no program, so there was nothing to seal and run"
    nt_skip appcache.sealed.instrument $why
    nt_skip appcache.sealed.reused $why
    nt_skip appcache.sealed.untouched $why
    nt_skip appcache.sealed.comes-up $why
} else {
    Stop-App
    $slotHash1 = (Get-FileHash $slotExe -Algorithm SHA256).Hash
    $slotMt1 = (Get-Item $slotExe).LastWriteTimeUtc
    $denyAce = '{0}:(W)' -f $env:USERNAME
    & icacls $slot3 /deny $denyAce *>&1 | Out-Null
    $sealRc = $LASTEXITCODE
    $sealed = $false
    try {
        "probe" | Set-Content (Join-Path $slot3 ".sealprobe") -ErrorAction Stop
        Remove-Item (Join-Path $slot3 ".sealprobe") -Force -ErrorAction SilentlyContinue
    } catch {
        $sealed = $true
    }
    Report "sealed seal_rc=$sealRc slot_writable=$(-not $sealed)"
    if (-not $sealed) {
        # A broken instrument and not a launcher finding, which is the whole
        # point of attempting the write before the launch: a slot that stayed
        # writable is a *granted* slot, and one the launcher is supposed to
        # rebuild. Reported as a launcher failure it failed the product for
        # doing exactly the right thing, twice, on two different machines.
        nt_fail appcache.sealed.instrument "sealed expected=the harness can close the slot actual=it stayed writable (icacls rc=$sealRc)"
        $why = "the slot could not be sealed, so what a launcher does with one was never asked"
        nt_skip appcache.sealed.reused $why
        nt_skip appcache.sealed.untouched $why
        nt_skip appcache.sealed.comes-up $why
    } else {
        nt_pass appcache.sealed.instrument "the harness closed the slot to writes"
        $p5 = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane3 -PassThru -WindowStyle Hidden
        if (-not $p5.WaitForExit(180000)) { $p5.Kill() }
        $up5 = Window-Up 180
        $slotHash2 = (Get-FileHash $slotExe -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        $slotMt2 = (Get-Item $slotExe -ErrorAction SilentlyContinue).LastWriteTimeUtc
        & icacls $slot3 /remove:d $env:USERNAME *>&1 | Out-Null
        Report ("sealed rebuilt=" + $(if ($slotHash1 -ne $slotHash2) { "YES" } else { "NO" }) +
                " mtime_moved=" + $(if ($slotMt1 -ne $slotMt2) { "YES" } else { "NO" }) +
                " window=$up5")
        if ($slotHash1 -ne $slotHash2) {
            nt_fail appcache.sealed.reused "sealed expected=the kept program is reused actual=it was rebuilt"
        } else {
            nt_pass appcache.sealed.reused "the kept program in a sealed slot is reused"
        }
        if ($slotMt1 -ne $slotMt2) {
            nt_fail appcache.sealed.untouched "sealed expected=the program is not rewritten actual=its mtime moved"
        } else {
            nt_pass appcache.sealed.untouched "the program in a sealed slot is not rewritten"
        }
        if ($up5 -ne "UP") {
            nt_fail appcache.sealed.comes-up "sealed expected=the app comes up from the sealed slot actual=DOWN"
        } else {
            nt_pass appcache.sealed.comes-up "the app comes up from the sealed slot"
        }
    }
}
Stop-App
Remove-Item $work3 -Recurse -Force -ErrorAction SilentlyContinue

# =====================================================================
# What a kept launch costs, and what is left beside the script
# =====================================================================
Stop-App
$times = @()
for ($i = 0; $i -lt 3; $i++) {
    $r = Launch 40
    $times += $r.ms
}
Report "cost kept_launch_ms=$($times -join ',')"
Report "left $(@(Get-ChildItem $work -Filter 'neutrinocache*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ',')"

Stop-App
nt_finish
