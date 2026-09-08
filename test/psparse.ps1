# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# psparse.ps1 - every suite in this directory parses, before any of them runs
#
# parse.sh does this for the artifact's five languages: `node --check` on each
# js part, `bash -n` on each sh part, python compiles the shim. The suites that
# drive the artifact on Windows are a sixth language and nothing checked them,
# so a PowerShell file that does not parse was found by running it -- which on
# this lane means eighteen minutes in, with everything behind it skipped.
#
# It has happened twice, the same way both times. `$run:` and `$app:` are not
# variables followed by a colon; a colon is a scope qualifier, so `"run $run: no
# process"` is a reference to a variable named `run:` and the file will not
# parse. demo.ps1 shipped it once and launchtime.ps1 shipped it again, and both
# were caught by a runner rather than by a check that costs a second.
#
# The parser is the one PowerShell uses on itself, so this is not a lint with
# an opinion: a file it accepts is a file the shell would have accepted, and a
# file it rejects would not have run. It says nothing about whether a suite is
# correct, which is what the suite is for.
#
# Usage: psparse.ps1 [-Dir <directory>]

param(
    [string]$Dir = $PSScriptRoot
)

$ErrorActionPreference = "Continue"
$bad = 0

Write-Output "=== psparse: the PowerShell suites, before any of them runs ==="

# The suites in this directory, and then the library underneath it. `lib` is a
# second sweep and not -Recurse, so the listing stays in the order somebody
# reads it in and a new directory under test/ does not join this check without
# anyone deciding that it should.
#
# lib has to be swept at all because lib/harness.ps1 is dot-sourced by every
# converted suite: the one file whose failure to parse takes the whole lane
# down with it was the one file this did not read. The suites it checks are
# named `lib/harness.ps1` rather than `harness.ps1`, because there is a
# harness.sh beside it and a bare basename would name neither.
$sweeps = @(
    @{ Dir = $Dir;                   Prefix = "" },
    @{ Dir = (Join-Path $Dir "lib"); Prefix = "lib/" }
)

$files = @()
foreach ($sweep in $sweeps) {
    if (-not (Test-Path -LiteralPath $sweep.Dir)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $sweep.Dir -Filter *.ps1 |
            Sort-Object Name)) {
        $files += [pscustomobject]@{
            Path = $f.FullName
            Name = $sweep.Prefix + $f.Name
        }
    }
}

foreach ($file in $files) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.Path, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $bad++
        foreach ($e in $errors) {
            Write-Output ("FAIL: {0}:{1} {2}" -f $file.Name,
                $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        Write-Output "report: $($file.Name) parses"
    }
}

if ($bad -gt 0) {
    Write-Output "psparse: $bad file(s) would not parse"
    exit 1
}
Write-Output "psparse: every suite parses"
exit 0
