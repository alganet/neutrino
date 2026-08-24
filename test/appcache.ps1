# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# appcache.ps1 - the exe the Windows launch path runs was built by this launch
#
# The same finding test/appdir.sh covers on the Qt branch, in the batch
# region's own mechanism. It compiled this file into <app folder>\<name>.exe
# and reused it on every later launch as long as <name>.stamp -- the source's
# size and modification time -- still matched. Both files sit in the app
# folder, which everything running as this user can write, and the digest
# netinstall pins covers the .cmd and not the artifact compiled out of it.
#
# Measured before the fix: an exe replaced in place with the stamp left exactly
# as the launcher wrote it was launched (`poison ran=YES realapp=DOWN
# stamp_unchanged=YES`), and went on being launched until the source itself
# changed. A compile costs 340 ms against the 86 ms that reuse saved.
#
# What this asserts, each of which fails against the commit before this one:
#
#   fresh      every launch compiles: the exe is not the one the last launch
#              left, and no stamp is written at all
#   poison     an exe replaced in place is overwritten rather than run
#   manifest   a planted manifest does not survive a launch
#   second     a second instance still opens while the first holds its own exe
#
# Controls: the shipped build has to come up, and the poison exe has to be
# proven live by running it directly -- an exe that does nothing would make
# every refusal here look like a pass.
#
# Usage: appcache.ps1 <app.cmd built from test/neutrinoloaders.js>

$ErrorActionPreference = "Continue"

$src = $args[0]
if (-not $src -or -not (Test-Path $src)) {
    Write-Output "usage: appcache.ps1 <app.cmd built from test/neutrinoloaders.js>"
    exit 2
}

$failures = 0
function Report($m) { Write-Output "report: $m" }
function Fail($m) { Write-Output "FAIL: $m"; $script:failures++ }

$work = Join-Path $env:TEMP ("appcache-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
$lane = Join-Path $work "neutrinocache.cmd"
Copy-Item $src $lane -Force
$folder = Join-Path $work "neutrinocache"
$exe = Join-Path $folder "neutrinocache.exe"
$stamp = Join-Path $folder "neutrinocache.stamp"
$manifest = Join-Path $folder "neutrinocache.exe.manifest"
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

Write-Output "=== appcache: the exe that runs was built by this launch ==="

# =====================================================================
# fresh: every launch compiles, and there is no stamp to forge
# =====================================================================
# WebView2 is fetched on a first run, so the first window wait is the long one.
$r1 = Launch 180
if (-not (Test-Path $exe)) { Fail "no exe after a first launch; nothing below is a reading" }
$hash1 = Exe-Hash
$man1 = (Get-Item $manifest -ErrorAction SilentlyContinue).LastWriteTimeUtc
Report "control window=$($r1.window) compile_ms=$($r1.ms) launcher_exited=$($r1.exited) exe=$(Test-Path $exe)"
if ($r1.window -ne "UP") { Fail "the shipped build did not come up; every reading below is unmeasured" }

$r2 = Launch 60
$hash2 = Exe-Hash
$man2 = (Get-Item $manifest -ErrorAction SilentlyContinue).LastWriteTimeUtc
Report "fresh rebuilt=$(if ($hash1 -ne $hash2) { 'YES' } else { 'NO' }) stamp=$(Test-Path $stamp) window=$($r2.window) launch_ms=$($r2.ms)"
if ($hash1 -eq $hash2) { Fail "fresh expected=a launch compiles its own exe actual=the previous one was reused" }
if (Test-Path $stamp) { Fail "fresh expected=no stamp actual=$stamp still written" }
if ($r2.window -ne "UP") { Fail "fresh expected=the app comes up on a second launch actual=DOWN" }
Report "fresh manifest_rewritten=$(if ($man1 -ne $man2) { 'YES' } else { 'NO' })"

# What the folder's own permissions say about who is in this threat model.
$acl = (Get-Acl $folder).Access |
       Where-Object { $_.FileSystemRights -match "Write|Modify|FullControl" } |
       ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique
Report "acl writers=$($acl -join ',')"

# =====================================================================
# poison: an exe replaced in place
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
    Fail "could not build the marker exe with jsc; the poison section is unmeasured"
} else {
    # Proven against a program that is not under test: an exe that writes
    # nothing would make the refusal below indistinguishable from a pass.
    Remove-Item $mark -Force -ErrorAction SilentlyContinue
    & $poisonExe 2>&1 | Out-Null
    $live = Test-Path $mark
    Report "control poison live=$(if ($live) { 'YES' } else { 'NO' })"
    if (-not $live) { Fail "control expected=the marker exe writes its mark when run actual=silent" }

    Stop-App
    Remove-Item $mark -Force -ErrorAction SilentlyContinue
    Copy-Item $poisonExe $exe -Force
    $poisonHash = (Get-FileHash $exe -ErrorAction SilentlyContinue).Hash
    $r3 = Launch 90
    $ran = Test-Path $mark
    Report ("poison ran=" + $(if ($ran) { "YES" } else { "NO" }) +
            " realapp=$($r3.window) exe_still_poison=" +
            $(if ((Exe-Hash) -eq $poisonHash) { "YES" } else { "NO" }))
    if ($ran) { Fail "poison expected=a replaced exe is overwritten actual=it ran" }
    if ($r3.window -ne "UP") { Fail "poison expected=the app comes up over a replaced exe actual=DOWN" }
    if ((Exe-Hash) -eq $poisonHash) { Fail "poison expected=the exe is rebuilt actual=the planted one is still there" }
}

# =====================================================================
# manifest: written with the exe, every launch
# =====================================================================
Stop-App
Add-Content -Path $manifest -Value "<!-- __APPCACHE_PLANTED__ -->" -ErrorAction SilentlyContinue
$r4 = Launch 60
$stillThere = Select-String -Path $manifest -Pattern "__APPCACHE_PLANTED__" -Quiet -ErrorAction SilentlyContinue
Report "manifest planted_survives=$(if ($stillThere) { 'YES' } else { 'NO' }) window=$($r4.window)"
if ($stillThere) { Fail "manifest expected=rewritten by every launch actual=the planted line survived" }

# =====================================================================
# second: a running instance holds its own exe open
# =====================================================================
#
# This is what the rotation is for. Overwriting a running exe is refused by
# Windows and renaming it is not, so a launch that compiles every time would
# otherwise fail outright while an earlier window is still open.
Stop-App
$first = Launch 60
$firstUp = $first.window
$p2 = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $lane -PassThru -WindowStyle Hidden
$p2Exited = $p2.WaitForExit(180000)
if (-not $p2Exited) { $p2.Kill() }
Start-Sleep -Seconds 10
$instances = @(Get-Process -Name "neutrinocache" -ErrorAction SilentlyContinue).Count
Report "second first=$firstUp launcher_exited=$p2Exited instances=$instances exit=$($p2.ExitCode)"
if ($p2.ExitCode -ne 0) { Fail "second expected=a second launch succeeds while the first runs actual=exit $($p2.ExitCode)" }
if ($instances -lt 2) { Fail "second expected=two instances actual=$instances" }

# =====================================================================
# Cost, and what the rotation leaves behind
# =====================================================================
Stop-App
$times = @()
for ($i = 0; $i -lt 3; $i++) {
    $r = Launch 40
    $times += $r.ms
}
Report "cost compile_ms=$($times -join ',')"
Report "left $(@(Get-ChildItem $folder -Filter 'neutrinocache*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ',')"

Stop-App
Write-Output "=== appcache: $failures failure(s) ==="
if ($failures -gt 0) { exit 1 }
exit 0
