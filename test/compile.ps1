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

$failures = 0
function Report($m) { Write-Output "report: $m" }
function Fail($m) { Write-Output "FAIL: $m"; $script:failures++ }

Write-Output "=== compile: does the artifact compile ==="

$artifact = $args[0]
if (-not $artifact) { $artifact = "test\neutrinotest.cmd" }
if (-not (Test-Path $artifact)) {
    Fail "no built artifact at '$artifact'; nothing below is a reading"
    Write-Output "=== compile: 1 failure(s) ==="
    exit 1
}

$fx = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
if (-not (Test-Path (Join-Path $fx "jsc.exe"))) { $fx = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319" }
$jsc = Join-Path $fx "jsc.exe"
if (-not (Test-Path $jsc)) {
    Fail "no jsc.exe under $env:WINDIR\Microsoft.NET; this runner cannot say"
    Write-Output "=== compile: 1 failure(s) ==="
    exit 1
}

# The artifact's own reference list, and not a second copy of it. winexec.ps1
# already asserts that this line names what the driver needs; what matters here
# is only that the compile is the launcher's compile, so a build that fails only
# under a shorter list is not reported as a build that fails.
$text = Get-Content $artifact -Raw
$refs = @([regex]::Matches($text, '/r:"%FX_DIR%\\([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value })
Report "references $(if ($refs.Count) { $refs -join ',' } else { 'none found on the jsc line' })"
if (-not $refs.Count) {
    Fail "no /r: entries in the artifact; the compile below would not be the launcher's"
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
    Report "compiled $((Get-Item $outExe).Length) bytes"
    # Warnings are not failures and are worth seeing anyway: the reserved word
    # that started this arrived alongside one, and a warning nobody prints is a
    # warning nobody reads.
    $said = ($log -replace '\s+', ' ').Trim()
    if ($said) { Report "compiler said $said" }
} else {
    Fail "the artifact does not compile"
    foreach ($line in ($log -split "`r?`n")) {
        if ($line.Trim()) { Write-Output "  $($line.Trim())" }
    }
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Output "=== compile: $failures failure(s) ==="
if ($failures -gt 0) { exit 1 }
exit 0
