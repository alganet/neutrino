# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# compile.ps1 - does the artifact compile, and what did the compiler say
#
# The launcher compiles the whole polyglot with jsc.exe on first run and starts
# the exe it produced. So an artifact that does not compile is not a broken
# feature, it is an app that never appears -- and every suite that waits for a
# window then waits for its own full timeout before saying anything.
#
# Measured, and it is why this file exists: one reserved word in the jsc region
# cost a Windows lane its runner. `core launch` spent twenty minutes, `appcache`
# fifteen, `standalone` fifteen, and the job hit its forty-minute wall in the
# middle of the one after that. Four suites reported "no window" and none of
# them reported the reason, which was sitting in jsc's output on the first
# launch of the first one. GitHub keeps no logs for a job killed that way, so
# the run that cost the most said the least.
#
# This is one step, about a second warm, and it runs before anything is
# launched. It compiles the artifact exactly as the launcher would -- with the
# reference list read out of the artifact's own jsc line rather than a copy of
# it here, so the two cannot drift -- and prints what the compiler said. A lane
# that fails here fails in one line with the error in it.
#
# It is not a substitute for launching. It says the file compiles and nothing
# about whether the app works; every suite behind it still measures what it
# always did. What it removes is the case where none of them can.
#
# Usage: compile.ps1 <built.cmd>

$ErrorActionPreference = "Continue"

# The six words. Four checks, none of which said anything when it held -- on a
# suite whose whole subject is that an artifact which does not compile is an app
# that never appears, and whose absence of a FAIL was the only sign it did.
. (Join-Path $PSScriptRoot "..\lib\harness.ps1")

function Report($m) { nt_report $m }

# The two gates say "nothing below is a reading" and "this runner cannot say" in
# as many words, and then exited with the rest unreported.
function skip_rest($why) {
    nt_skip compile.refs $why
    nt_skip compile.compiles $why
}

Write-Output "=== compile: does the artifact compile ==="

$artifact = $args[0]
# Required rather than defaulted. Every caller passes it; a default only
# survives to be wrong the day the artifact moves.
if (-not $artifact) { throw "usage: compile.ps1 <app.cmd>" }
if (-not (Test-Path $artifact)) {
    nt_fail compile.artifact "no built artifact at '$artifact'; nothing below is a reading"
    nt_skip compile.jsc "there was no artifact to compile, so the compiler was never reached for"
    skip_rest "there was no artifact to read or compile"
    nt_finish
}
nt_pass compile.artifact "there is a built artifact at '$artifact'"

$fx = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
if (-not (Test-Path (Join-Path $fx "jsc.exe"))) { $fx = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319" }
$jsc = Join-Path $fx "jsc.exe"
if (-not (Test-Path $jsc)) {
    nt_fail compile.jsc "no jsc.exe under $env:WINDIR\Microsoft.NET; this runner cannot say"
    skip_rest "there is no jsc here, so nothing could be compiled"
    nt_finish
}
nt_pass compile.jsc "jsc.exe is here to compile with"

# The artifact's own reference list, and not a second copy of it. winexec.ps1
# already asserts that this line names what the driver needs; what matters here
# is only that the compile is the launcher's compile, so a build that fails only
# under a shorter list is not reported as a build that fails.
$text = Get-Content $artifact -Raw
$refs = @([regex]::Matches($text, '/r:"%FX_DIR%\\([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value })
Report "references $(if ($refs.Count) { $refs -join ',' } else { 'none found on the jsc line' })"
if (-not $refs.Count) {
    nt_fail compile.refs "no /r: entries in the artifact; the compile below would not be the launcher's"
} else {
    nt_pass compile.refs "the artifact names its own reference list ($($refs.Count) entries)"
}

$work = Join-Path $env:TEMP ("compile-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$outExe = Join-Path $work "artifact.exe"

$argv = @("/nologo", "/debug-", "/t:winexe", "/out:$outExe", "/autoref+", "/lib:$fx")
foreach ($r in $refs) { $argv += "/r:$(Join-Path $fx $r)" }
$argv += (Resolve-Path $artifact).Path

$log = & $jsc $argv 2>&1 | Out-String
$built = Test-Path $outExe

if ($built) {
    nt_pass compile.compiles "the artifact compiles"
    Report "compiled $((Get-Item $outExe).Length) bytes"
    # Warnings are not failures and are worth seeing anyway: the reserved word
    # that started this arrived alongside one, and a warning nobody prints is a
    # warning nobody reads.
    $said = ($log -replace '\s+', ' ').Trim()
    if ($said) { Report "compiler said $said" }
} else {
    nt_fail compile.compiles "the artifact does not compile"
    foreach ($line in ($log -split "`r?`n")) {
        if ($line.Trim()) { Write-Output "  $($line.Trim())" }
    }
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
nt_finish
