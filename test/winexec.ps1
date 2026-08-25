# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# winexec.ps1 - the program the Windows driver runs, and the tree it deletes
#
# Sweep slice 5: createWindowsDriver's own file and process I/O, the part of
# webview.cmd nothing had read. PR 21 took its navigation and message surface,
# PR 20 took what the batch region writes, and neither touched what the driver
# itself opens, deletes and runs.
#
# extractArchiveWithPowerShell set startInfo.FileName = "powershell.exe" with
# UseShellExecute = false. .NET builds a command line and hands CreateProcess a
# null lpApplicationName, so the name went through the CreateProcess search
# order, whose first two entries are the directory the calling exe was loaded
# from and the current directory. Both of those are the app folder: the exe
# lives there and the batch region STARTs it with /D "%APP_FOLDER%", and
# test/appcache.ps1 already established that folder is one everything running
# as this user can write. Measured here, both entries independently.
#
# downloadWebView2WithProgress called Directory.Delete(packageRoot, true) on a
# directory in that same folder. That was filed as a delete of somewhere else
# through a planted junction and it is not: the framework unlinks the junction,
# empties everything else, and then throws IOException "The parameter is
# incorrect." leaving the directory behind. What it costs is a launch that
# refuses for a reason nobody can act on and a next launch that works, which is
# a failure that never gets reported.
#
# What this asserts:
#
#   refs      webview.cmd's own jsc line names both compression assemblies,
#             and an extraction built with exactly that line's /r list works
#   names     no ProcessStartInfo in the file runs a program by name
#   tree      no recursive Directory.Delete, and reparse points are tested for
#   search    the before-state: the spelling that was removed resolves to a
#             decoy planted beside the exe, and to one in the current directory
#   inproc    the before-state of the fix: the same source built without the
#             two references compiles and throws at run time
#   delete    the before-state and the fix, against a junction
#
# `refs`, `names` and `tree` fail against the commit before this one. `search`,
# `inproc` and `delete` carry their before-state as artifacts this file builds,
# the way PR 23 carries `oldspelling` and PR 24 carries `oldbuild.sh` -- so
# "it would have failed before" is measured on every push rather than claimed,
# and the day a platform moves underneath it the suite says which half.
#
# Two of the six are spelling assertions on webview.cmd rather than on its
# behaviour, and that is deliberate: what `delete` and `inproc` measure is a
# platform fact -- how this framework treats a junction, and what a missing
# reference does to a late-bound call -- and what the source assertions say is
# that the file acts on the fact. Asserting the fact twice, once here and once
# against a copy of the driver's code, is how two suites drift into disagreeing.
#
# Controls, because a refusal that measures nothing is not a pass:
#   search  with nothing planted the real powershell has to run
#   delete  the same recursive delete has to remove the same tree when no
#           junction is in it, or "it threw" is also the reading for a call
#           that never worked here
#   inproc  the archive has to carry the member name that is asked for
#
# Nothing here launches the app. It measures the mechanisms directly with
# programs it compiles, because a suite that starts a window is one that can
# outlive its step -- which is what cost PR 24 a runner.
#
# Usage: winexec.ps1 [webview.cmd]

$ErrorActionPreference = "Continue"

$failures = 0
function Report($m) { Write-Output "report: $m" }
function Fail($m) { Write-Output "FAIL: $m"; $script:failures++ }
function Section($m) { Write-Output "report: === $m" }

Write-Output "=== winexec: the program the driver runs, and the tree it deletes ==="

$webview = $args[0]
if (-not $webview) { $webview = "webview.cmd" }
if (-not (Test-Path $webview)) {
    Fail "no webview.cmd at '$webview'; nothing below is a reading"
    Write-Output "=== winexec: $failures failure(s) ==="
    exit 1
}

$work = Join-Path $env:TEMP ("winexec-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null

# The batch region prefers the 32-bit framework directory and falls back to the
# 64-bit one. This follows it, because the compile under test is that one.
$fx32 = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
$fx64 = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$fx = $fx32
if (-not (Test-Path (Join-Path $fx "jsc.exe"))) { $fx = $fx64 }
$jsc = Join-Path $fx "jsc.exe"
Report "env jsc=$(Test-Path $jsc) fx=$fx sysdir=$([System.Environment]::SystemDirectory) ps=$($PSVersionTable.PSVersion)"
if (-not (Test-Path $jsc)) {
    Fail "no jsc; nothing below is a reading"
    Write-Output "=== winexec: $failures failure(s) ==="
    exit 1
}

# Runs a compiled console program with a chosen working directory and a bound.
# Start-Process and not a pipeline, for the reason PR 20 wrote down: a pipe on
# something that may detach never closes.
#
# Nothing in this file returns a value from a function that also reports. A
# PowerShell function returns everything written to the output stream, so a
# `return $true` under a Report line comes back as a two-element array and every
# `if` on it is true. Results land in $script: variables instead.
function Run-Probe($exe, $cwd, $probeArgs, $label) {
    $out = Join-Path $work "$label.out"
    $err = Join-Path $work "$label.err"
    if ($probeArgs -and $probeArgs.Count -gt 0) {
        $p = Start-Process -FilePath $exe -ArgumentList $probeArgs -WorkingDirectory $cwd `
            -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
    } else {
        $p = Start-Process -FilePath $exe -WorkingDirectory $cwd `
            -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
    }
    $exited = $p.WaitForExit(60000)
    if (-not $exited) { $p.Kill(); Start-Sleep -Seconds 1 }
    $text = ""
    if (Test-Path $out) { $text = "" + (Get-Content $out -Raw -ErrorAction SilentlyContinue) }
    $etext = ""
    if (Test-Path $err) { $etext = "" + (Get-Content $err -Raw -ErrorAction SilentlyContinue) }
    $script:runCode = $(if ($exited) { "$($p.ExitCode)" } else { "killed" })
    $script:runOut = ($text -replace '\s+', ' ').Trim()
    $script:runErr = ($etext -replace '\s+', ' ').Trim()
}

function Build-Js($name, $source, $outExe, $refs) {
    $src = Join-Path $work $name
    Set-Content -Path $src -Value $source -Encoding ASCII
    $argv = @("/nologo", "/t:exe", "/out:$outExe")
    foreach ($r in $refs) { $argv += "/r:$r" }
    $argv += $src
    $log = & $jsc $argv 2>&1 | Out-String
    $script:buildOk = (Test-Path $outExe)
    if (-not $script:buildOk) {
        Report "build $name FAILED $(($log -replace '\s+', ' ').Trim())"
    }
}

function Esc($p) { return ("" + $p).Replace("\", "\\") }

# What is left under a directory, relative and flattened, with junctions marked.
# "root still exists" is not a reading on its own: it does not separate a call
# that refused before touching anything from one that deleted its way to the
# junction and gave up, and those are different bugs.
function Residue($root) {
    if (-not (Test-Path $root)) { return "gone" }
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart("\")
            if ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { "$rel<J>" } else { $rel }
        })
    if ($items.Count -eq 0) { return "empty" }
    return ($items -join ",")
}

$source = Get-Content -LiteralPath $webview -Raw

# =====================================================================
Section "refs - the reference list the driver is compiled with"
# =====================================================================
#
# Taken out of the file rather than written here, so this is the list the
# launcher actually uses. Every call into System.IO.Compression in the driver is
# late-bound through eval("System"), which means dropping a /r line builds
# cleanly and throws at run time -- there is no compile error to catch it, and
# this is the check that does.

$compileBlock = [regex]::Match($source, '(?s):COMPILE(.*?)"%~f0"')
$refNames = @()
if ($compileBlock.Success) {
    $refNames = @([regex]::Matches($compileBlock.Groups[1].Value, '/r:"%FX_DIR%\\([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value })
}
Report "refs list=$($refNames -join ',')"
if ($refNames.Count -eq 0) {
    Fail "refs expected=a /r list in the :COMPILE block actual=none found; the sections below are unmeasured"
}
foreach ($needed in @("System.IO.Compression.dll", "System.IO.Compression.FileSystem.dll")) {
    if ($refNames -notcontains $needed) {
        Fail "refs expected=$needed on the jsc line actual=absent"
    }
}

$absent = @($refNames | Where-Object { -not (Test-Path (Join-Path $fx $_)) })
Report "refs present=$($refNames.Count - $absent.Count)/$($refNames.Count) absent=$($absent -join ',')"
if ($absent.Count -gt 0) {
    Fail "refs expected=every named assembly present in the framework directory actual=$($absent -join ',') absent"
}

# =====================================================================
Section "names - no program is run by name"
# =====================================================================
#
# The fix is not a better spelling of powershell.exe, it is naming no program:
# the only ProcessStartInfo left in the file is openExternal's, which is a url
# handed to ShellExecute behind PR 22's allowlist.
$byName = @([regex]::Matches($source, 'startInfo\.FileName|UseShellExecute\s*=\s*false'))
$shellTrue = @([regex]::Matches($source, 'UseShellExecute\s*=\s*true'))
Report "names by_name=$($byName.Count) shellexecute_true=$($shellTrue.Count)"
if ($byName.Count -gt 0) {
    Fail "names expected=no process started by name actual=$($byName.Count) occurrence(s)"
}

# =====================================================================
Section "tree - the delete tests for reparse points"
# =====================================================================
$recursive = @([regex]::Matches($source, 'Directory\.Delete\([^)]*,\s*true\s*\)'))
$reparse = @([regex]::Matches($source, 'attrs & 1024'))
Report "tree recursive_deletes=$($recursive.Count) reparse_tests=$($reparse.Count)"
if ($recursive.Count -gt 0) {
    Fail "tree expected=no recursive Directory.Delete actual=$($recursive.Count) occurrence(s)"
}
if ($reparse.Count -eq 0) {
    Fail "tree expected=the walk tests FILE_ATTRIBUTE_REPARSE_POINT actual=no such test"
}

# =====================================================================
Section "search - the before-state: a bare program name"
# =====================================================================
#
# resolver.js is extractArchiveWithPowerShell's ProcessStartInfo as it shipped,
# one field at a time and nothing else. `bare` is the spelling that was removed;
# `full` is the narrower one that was measured and not taken, kept because it
# says the two readings differ for the reason claimed and not by accident.

$binClean = Join-Path $work "binClean"
$binPlant = Join-Path $work "binPlant"
$cwdClean = Join-Path $work "cwdClean"
$cwdPlant = Join-Path $work "cwdPlant"
foreach ($d in @($binClean, $binPlant, $cwdClean, $cwdPlant)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$realMark = Join-Path $work "mark-real.txt"
$decoyMark = Join-Path $work "mark-decoy.txt"

$resolverSrc = @"
import System;
import System.Diagnostics;
import System.IO;
import System.Text;

var argv : String[] = Environment.GetCommandLineArgs();
var mode : String = argv[1];
var mark : String = argv[2];

var si : ProcessStartInfo = new ProcessStartInfo();
if (mode == "bare") {
    si.FileName = "powershell.exe";
} else {
    si.FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell\\v1.0\\powershell.exe");
    si.WorkingDirectory = Environment.SystemDirectory;
}
var cmd : String = "Set-Content -LiteralPath '" + mark + "' -Value 'real'";
var enc : String = Convert.ToBase64String(Encoding.Unicode.GetBytes(cmd));
si.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + enc;
si.UseShellExecute = false;
si.CreateNoWindow = true;

Console.WriteLine("filename=" + si.FileName);
try {
    var p : Process = Process.Start(si);
    p.WaitForExit();
    Console.WriteLine("rc=" + p.ExitCode);
} catch (ex : Exception) {
    Console.WriteLine("rc=threw " + ex.GetType().FullName + ": " + ex.Message);
}
Console.WriteLine("bits=" + (System.IntPtr.Size * 8) + " cwd=" + Directory.GetCurrentDirectory());
"@

$decoySrc = @"
import System;
import System.IO;

File.WriteAllText("$(Esc $decoyMark)", Environment.GetCommandLineArgs()[0]);
Console.WriteLine("decoy ran");
"@

$resolverClean = Join-Path $binClean "resolver.exe"
$resolverPlant = Join-Path $binPlant "resolver.exe"
$decoyStage = Join-Path $work "decoy.exe"

$okSearch = $true
Build-Js "resolver.js" $resolverSrc $resolverClean @()
if (-not $script:buildOk) { $okSearch = $false }
if ($okSearch) {
    Copy-Item $resolverClean $resolverPlant -Force
    Build-Js "decoy.js" $decoySrc $decoyStage @()
    if (-not $script:buildOk) { $okSearch = $false }
}

function Case-Search($label, $exe, $cwd, $mode) {
    Remove-Item $realMark -Force -ErrorAction SilentlyContinue
    Remove-Item $decoyMark -Force -ErrorAction SilentlyContinue
    Run-Probe $exe $cwd @($mode, $realMark) $label
    $who = "none"
    if (Test-Path $decoyMark) { $who = "decoy" }
    elseif (Test-Path $realMark) { $who = "real" }
    Report "$label who=$who rc=$($script:runCode) out=$($script:runOut)"
    if ($script:runErr) { Report "$label stderr=$($script:runErr)" }
    $script:caseWho = $who
}

if (-not $okSearch) {
    Fail "search did not build; its readings are absent, not negative"
} else {
    Copy-Item $decoyStage (Join-Path $binPlant "powershell.exe") -Force
    Copy-Item $decoyStage (Join-Path $cwdPlant "powershell.exe") -Force

    # Proven live by running it directly: an exe that writes nothing would make
    # every "the decoy did not run" below indistinguishable from a pass.
    Remove-Item $decoyMark -Force -ErrorAction SilentlyContinue
    Run-Probe $decoyStage $work @() "decoylive"
    Report "control decoy live=$(Test-Path $decoyMark) rc=$($script:runCode)"
    if (-not (Test-Path $decoyMark)) {
        Fail "control expected=the decoy writes its mark when run actual=silent"
    }

    Case-Search "control-bare" $resolverClean $cwdClean "bare"
    if ($script:caseWho -ne "real") {
        Fail "control expected=the real powershell runs when nothing is planted actual=$($script:caseWho)"
    }

    # The two entries in the search order, measured apart. In the launcher they
    # are the same folder, and each on its own is enough.
    Case-Search "appdir-bare" $resolverPlant $cwdClean "bare"
    $whoAppdir = $script:caseWho
    if ($whoAppdir -ne "decoy") {
        Fail "appdir-bare expected=a program planted beside the exe is what runs actual=$whoAppdir"
    }
    Case-Search "cwd-bare" $resolverClean $cwdPlant "bare"
    $whoCwd = $script:caseWho
    if ($whoCwd -ne "decoy") {
        Fail "cwd-bare expected=a program planted in the current directory is what runs actual=$whoCwd"
    }

    Case-Search "fixed-full" $resolverPlant $cwdPlant "full"
    $whoFixed = $script:caseWho
    if ($whoFixed -ne "real") {
        Fail "fixed-full expected=an absolute path refuses both plants actual=$whoFixed"
    }
    Report "search summary appdir=$whoAppdir cwd=$whoCwd fixed=$whoFixed"
}

# Not a finding of its own: the sentence appcache.ps1 already carries, taken
# again because this section's premise is that a same-uid process can put a file
# called powershell.exe next to the exe.
$acl = (Get-Acl $binPlant).Access |
    Where-Object { $_.FileSystemRights -match "Write|Modify|FullControl" } |
    ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique
Report "acl writers=$($acl -join ',')"

# =====================================================================
Section "inproc - the extraction, with and without the references"
# =====================================================================
#
# The driver's own reach into the framework: no import of the namespace, every
# call late-bound through the object eval("System") returns, compiled with the
# reference list read out of webview.cmd above.

$nestedZip = Join-Path $work "nested.zip"
$entryName = "lib/net462/member.txt"
$entryBytes = 30
$nestedOk = $false
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $za = [System.IO.Compression.ZipFile]::Open($nestedZip, [System.IO.Compression.ZipArchiveMode]::Create)
    $ze = $za.CreateEntry($entryName)
    $zw = New-Object System.IO.StreamWriter($ze.Open())
    $zw.Write("the member this suite extracts")
    $zw.Dispose()
    $za.Dispose()
    $zr = [System.IO.Compression.ZipFile]::OpenRead($nestedZip)
    $names = @($zr.Entries | ForEach-Object { $_.FullName })
    $zr.Dispose()
    $nestedOk = ($names -contains $entryName)
    Report "control archive entries=$($names -join ',') asked=$entryName"
} catch {
    Report "control archive FAILED $($_.Exception.Message)"
}

$drvSrc = @"
import System;

var SystemRef = eval("System");
var argv : String[] = Environment.GetCommandLineArgs();
var zip = null;
try {
    zip = SystemRef.IO.Compression.ZipFile.OpenRead(argv[1]);
    var entry = zip.GetEntry(argv[2]);
    if (entry == null) {
        Console.WriteLine("entry=missing");
    } else {
        var dir : String = SystemRef.IO.Path.GetDirectoryName(argv[3]);
        if (!SystemRef.IO.Directory.Exists(dir)) {
            SystemRef.IO.Directory.CreateDirectory(dir);
        }
        SystemRef.IO.Compression.ZipFileExtensions.ExtractToFile(entry, argv[3], true);
        Console.WriteLine("entry=ok len=" + SystemRef.IO.File.ReadAllBytes(argv[3]).Length);
    }
} catch (ex : Exception) {
    Console.WriteLine("threw " + ex.GetType().FullName + ": " + ex.Message);
} finally {
    if (zip != null) {
        zip.Dispose();
    }
}
"@

$drvFile = Join-Path $work "drv.js"
Set-Content -Path $drvFile -Value $drvSrc -Encoding ASCII

function Variant($label, $names) {
    $exe = Join-Path $work "drv-$label.exe"
    $argv = @("/nologo", "/t:exe", "/autoref+", "/lib:$fx", "/out:$exe")
    foreach ($r in $names) { $argv += "/r:$(Join-Path $fx $r)" }
    $argv += $drvFile
    $log = & $jsc $argv 2>&1 | Out-String
    $script:variantBuilt = (Test-Path $exe)
    if (-not $script:variantBuilt) {
        Report "inproc $label built=False log=$(($log -replace '\s+', ' ').Trim())"
        return
    }
    $dest = Join-Path $work "out-$label\lib\net462\member.txt"
    Run-Probe $exe $work @($nestedZip, $entryName, $dest) "drv$label"
    $script:variantLen = -1
    if (Test-Path $dest) { $script:variantLen = (Get-Item $dest).Length }
    Report "inproc $label built=True rc=$($script:runCode) len=$($script:variantLen) out=$($script:runOut)"
}

if (-not $nestedOk) {
    Fail "control expected=an archive with a forward-slash member name actual=not built; inproc is unmeasured"
} else {
    # The shipped list. This is the assertion that the /r lines are not only
    # present but sufficient.
    Variant "shipped" $refNames
    if (-not $script:variantBuilt) {
        Fail "inproc expected=the driver's reference list compiles the extraction actual=it did not build"
    } elseif ($script:variantLen -ne $entryBytes) {
        Fail "inproc expected=the member extracted whole ($entryBytes bytes) actual=$($script:variantLen)"
    }

    # The before-state, carried as an artifact: the same source, the same list
    # with the two compression assemblies taken out. It builds -- which is the
    # point -- and throws where the caller reports a failed download.
    $withoutCompression = @($refNames | Where-Object { $_ -notlike "System.IO.Compression*" })
    Variant "nocompression" $withoutCompression
    if (-not $script:variantBuilt) {
        Fail "before expected=dropping the references still compiles actual=it failed to build"
    } elseif ($script:variantLen -ne -1) {
        Fail "before expected=dropping the references breaks the extraction actual=it extracted $($script:variantLen) bytes"
    }
}

# =====================================================================
Section "delete - a recursive delete and a directory junction"
# =====================================================================

$delSrc = @"
import System;
import System.IO;

var argv : String[] = Environment.GetCommandLineArgs();
var mode : String = argv[1];
var target : String = argv[2];

// The shipped walk, in the same spelling. 1024 is
// FILE_ATTRIBUTE_REPARSE_POINT.
function SafeDelete(dir : String) {
    var files : String[] = Directory.GetFiles(dir);
    for (var i : int = 0; i < files.Length; i++) {
        File.Delete(files[i]);
    }
    var subs : String[] = Directory.GetDirectories(dir);
    for (var j : int = 0; j < subs.Length; j++) {
        var at : int = Convert.ToInt32(File.GetAttributes(subs[j]));
        if ((at & 1024) != 0) {
            Directory.Delete(subs[j], false);
        } else {
            SafeDelete(subs[j]);
        }
    }
    Directory.Delete(dir, false);
}

// Typed, and this PR's first round is why. `catch (e)` hands JScript its own
// Error wrapper, whose `.Message` is undefined -- so the reading came back
// `delete=threw undefined`, which says something refused and nothing about what.
try {
    if (mode == "plain") {
        Directory.Delete(target, true);
    } else {
        SafeDelete(target);
    }
    Console.WriteLine("delete=OK");
} catch (ex : Exception) {
    Console.WriteLine("delete=threw " + ex.GetType().FullName + ": " + ex.Message);
}
"@

$delExe = Join-Path $work "deltest.exe"
Build-Js "deltest.js" $delSrc $delExe @()
$okDelete = $script:buildOk

# <name>-root with a file, a real subdirectory, and optionally a junction to
# <name>-victim, which holds a file nothing under root should be able to reach.
function New-Scene($name, $withJunction) {
    $victim = Join-Path $work "$name-victim"
    $root = Join-Path $work "$name-root"
    New-Item -ItemType Directory -Path $victim -Force | Out-Null
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root "real") -Force | Out-Null
    Set-Content -Path (Join-Path $victim "keep.txt") -Value "keep"
    Set-Content -Path (Join-Path $root "member.txt") -Value "member"
    Set-Content -Path (Join-Path $root "real\nested.txt") -Value "nested"
    $script:sceneVictim = $victim
    $script:sceneRoot = $root
    if (-not $withJunction) {
        $script:sceneOk = $true
        Report "$name scene junction=none"
        return
    }
    $sub = Join-Path $root "sub"
    $mk = cmd /c mklink /J "$sub" "$victim" 2>&1 | Out-String
    $script:sceneOk = (Test-Path (Join-Path $sub "keep.txt"))
    Report "$name junction resolves=$($script:sceneOk) mklink=$(($mk -replace '\s+', ' ').Trim())"
}

if (-not $okDelete) {
    Fail "delete did not build; its readings are absent, not negative"
} else {
    # The control that says what the junction did, and not the runner.
    New-Scene "nojunc" $false
    $r0 = $script:sceneRoot
    Run-Probe $delExe $work @("plain", $r0) "delnojunc"
    $r0Gone = -not (Test-Path $r0)
    Report "control plain-nojunction root_removed=$r0Gone out=$($script:runOut)"
    if (-not $r0Gone) {
        Fail "control expected=a plain recursive delete removes a tree with no junction in it actual=it is still there"
    }

    # The before-state, asserted to what was measured, all three halves: the
    # target is spared, the directory it was given is emptied, and the call
    # throws anyway.
    New-Scene "plain" $true
    $v1 = $script:sceneVictim
    $r1 = $script:sceneRoot
    if (-not $script:sceneOk) {
        Fail "control expected=a junction a normal account can create actual=mklink /J did not"
    } else {
        Run-Probe $delExe $work @("plain", $r1) "delplain"
        $keep1 = Test-Path (Join-Path $v1 "keep.txt")
        $residue1 = Residue $r1
        Report "before plain root=$(Test-Path $r1) victim_keep=$keep1 residue=$residue1 out=$($script:runOut)"
        if (-not $keep1) {
            Fail "before expected=the junction's target is spared actual=it was deleted through"
        }
        if ($script:runOut -notlike "*System.IO.IOException*") {
            Fail "before expected=the recursive delete throws IOException on a junction actual=$($script:runOut)"
        }
        if ($residue1 -ne "empty") {
            Fail "before expected=it empties the directory and leaves it actual=residue=$residue1"
        }
    }

    # The fix.
    New-Scene "safe" $true
    $v2 = $script:sceneVictim
    $r2 = $script:sceneRoot
    if (-not $script:sceneOk) {
        Fail "control expected=a junction for the shipped walk actual=mklink /J did not"
    } else {
        Run-Probe $delExe $work @("safe", $r2) "delsafe"
        $rootGone = -not (Test-Path $r2)
        $keep2 = Test-Path (Join-Path $v2 "keep.txt")
        Report "safe root_removed=$rootGone victim_keep=$keep2 out=$($script:runOut)"
        if (-not $rootGone) {
            Fail "safe expected=the walk removes the tree it is given actual=residue=$(Residue $r2)"
        }
        if (-not $keep2) {
            Fail "safe expected=the junction's target is spared actual=it was deleted through"
        }
    }
}

Write-Output "=== winexec: $failures failure(s) ==="
if ($failures -gt 0) { exit 1 }
exit 0
