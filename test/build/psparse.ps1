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
    # test/, and not this file's own room. psparse lives in build/ and the
    # suites it reads live in suite/, lib/ and probe/, so the directory it is
    # pointed at is the one those rooms are under.
    [string]$Dir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Continue"
$bad = 0

Write-Output "=== psparse: the PowerShell suites, before any of them runs ==="

# One sweep per room, named rather than -Recurse, so the listing stays in the
# order somebody reads it in and a new directory under test/ does not join this
# check without anyone deciding that it should. That was the rule when this
# swept two directories and it is why there are four entries here now rather
# than a walk of the tree.
#
# lib has to be swept at all because lib/harness.ps1 is dot-sourced by every
# converted suite: the one file whose failure to parse takes the whole lane
# down with it was the one file this did not read. The files are named by room
# -- `lib/harness.ps1` rather than `harness.ps1` -- because there is a
# harness.sh beside it and a bare basename would name neither.
#
# build is swept too, which means this file checks itself. That is not vanity:
# it is the file every lane runs first, so a parse error in it is a parse error
# nothing else would report.
$sweeps = @(
    @{ Dir = (Join-Path $Dir "suite");  Prefix = "suite/"  },
    @{ Dir = (Join-Path $Dir "lib");    Prefix = "lib/"    },
    @{ Dir = (Join-Path $Dir "probe");  Prefix = "probe/"  },
    @{ Dir = (Join-Path $Dir "build");  Prefix = "build/"  }
)

$files = @()
$empty = @()
foreach ($sweep in $sweeps) {
    if (-not (Test-Path -LiteralPath $sweep.Dir)) { $empty += $sweep.Prefix; continue }
    $found = @(Get-ChildItem -LiteralPath $sweep.Dir -Filter *.ps1 | Sort-Object Name)
    if ($found.Count -lt 1) { $empty += $sweep.Prefix }
    foreach ($f in $found) {
        $files += [pscustomobject]@{
            Path = $f.FullName
            Name = $sweep.Prefix + $f.Name
        }
    }
}

# What this file could not say until now: that it read anything.
#
# A room renamed, or moved out from under test/, and every sweep above takes its
# `continue` and finds nothing -- and the loop below then iterates an empty list,
# reports no failure, and prints "every suite parses" on the way to exit 0. A
# parse gate that swept nothing is a parse gate that passed for free, and it is
# the first step on both Windows lanes, so everything behind it would have run
# unparsed with this saying it was fine.
#
# Per room and not merely in total, because `suite/` holding nineteen files
# hides `probe/` holding none. A room that is missing entirely and a room that
# is present and empty are the same defect from here and are reported as one.
$read = $files.Count
Write-Output "report: psparse read $read file(s) across $($sweeps.Count) room(s)"

$unparseable = @()
foreach ($file in $files) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.Path, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $bad++
        $unparseable += $file.Name
        foreach ($e in $errors) {
            Write-Output ("FAIL: {0}:{1} {2}" -f $file.Name,
                $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        Write-Output "report: $($file.Name) parses"
    }
}

# The rows, and the order they are filed in is the whole of the design.
#
# This file is the one that reports on a broken lib/harness.ps1 -- that is why
# the sweep above reads lib/ at all, and the comment there says so. Dot-sourcing
# the harness to file rows would make the reporter depend on the thing it
# reports on: a parse error in harness.ps1 would take psparse down with it, and
# the lane would fail at its first step with no reading and no name.
#
# So the harness is loaded only after this file has proved it parses, which it
# has just done along with the other twenty-two. That is not a trick; it is the
# only order in which the dependency is safe, and it is available here because
# proving it is what this file already does.
#
# When it does not parse, there are no rows and there cannot be. The failure is
# already on stdout by name and line, `$bad` is non-zero, and the exit below
# makes the lane red -- which is the outcome that matters and the one this gate
# has always produced.
# From $Dir and not from $PSScriptRoot, so the harness that files these rows
# is the one out of the tree that was just swept. They are the same path for
# the only caller there is, and keeping them one expression is what stops
# them drifting apart if a second one ever passes -Dir.
$harness = Join-Path $Dir "lib\harness.ps1"
if ((Test-Path -LiteralPath $harness) -and ($unparseable -notcontains "lib/harness.ps1")) {
    . $harness
    if ($empty.Count -gt 0) {
        nt_fail psparse.read ("psparse swept no .ps1 in: {0}; those rooms moved and this check measured nothing there" -f ($empty -join " "))
    } else {
        nt_pass psparse.read "the sweep found PowerShell in every room it reads ($read file(s) across $($sweeps.Count))"
    }
    if ($unparseable.Count -gt 0) {
        nt_fail psparse.parses ("{0} file(s) would not parse: {1}" -f $unparseable.Count, ($unparseable -join " "))
    } elseif ($read -lt 1) {
        nt_skip psparse.parses "there were no files to parse, which the case above is the failure for"
    } else {
        nt_pass psparse.parses "every PowerShell file under test/ parses ($read of them)"
    }
    nt_finish
}

# Below here only when the harness could not be loaded, which is a parse error
# in harness.ps1 or its absence. Both are already on stdout above; this is the
# status, and the empty-room check has to be repeated because the row that
# normally carries it was not reachable.
if ($empty.Count -gt 0) {
    Write-Output ("FAIL: psparse swept no .ps1 in: {0}; those rooms moved and this check measured nothing there" -f ($empty -join " "))
    $bad++
}
if ($bad -gt 0) {
    Write-Output "psparse: $bad file(s) would not parse"
    exit 1
}
Write-Output "psparse: every suite parses"
exit 0
