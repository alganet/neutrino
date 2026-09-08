# harness.ps1 - the vocabulary every suite in test/ speaks, in PowerShell.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Dot-sourced, never run, and dot-sourced rather than invoked on purpose:
#
#     . (Join-Path $PSScriptRoot "lib\harness.ps1")
#
# lib/harness.sh says what this is for and why an assertion carries a case id
# rather than a sentence; that argument is not repeated here. What is written
# down here is the half of it that is about this language.
#
# ------------------------------------------------------- why the same six words
#
# These are named nt_pass and not Assert-Pass, which is not what a PowerShell
# reader expects. The reason is lib/selftest.sh. Its verdict-call scan reads
# every suite in the tree with one awk pass, splitting on whitespace and
# matching the verb against a fixed list; its canary asserts that the scan found
# at least one nt_pass, nt_fail and nt_skip anywhere, because a scan that reads
# nothing and a tree with nothing wrong in it produce the same green; and its
# orphan scan asks the registry the same question from the other side.
#
# `nt_pass attack.reported "..."` is the same sequence of whitespace-separated
# tokens in both languages. So keeping the six words meant those three checks
# reached the Windows suites by widening two file globs, and nothing else --
# where a Verb-Noun spelling would have needed a second scan, a second canary,
# and a second thing that can quietly go blind. The tree has one vocabulary
# because it has one set of readers, and this file is the second speaker of it.
#
# ----------------------------------------------------- what this language costs
#
# Four decisions below are PowerShell's and not the harness's, and each one was
# measured on windows-content rather than assumed.

# The lane. As in harness.sh: CI names it per job, a developer running a suite
# by hand gets `local`, and a reading taken on a workstation should not be filed
# as a lane reading.
$script:NT_LANE = if ($env:NT_LANE) { $env:NT_LANE } else { "local" }

# The suite's own name.
#
# harness.sh derives this from $0 "because every call site would otherwise
# repeat the filename it is already in, and the one that eventually disagreed
# would be the interesting one". The same argument holds; the incantation does
# not carry over.
#
# Measured on windows-content rather than reasoned about, because three of the
# four candidates look equally plausible in the documentation. Dot-sourced from
# a script in test/ the way a suite dot-sources this one, PowerShell 7.6.5
# answered:
#
#     MyInvocation.ScriptName     ...\test\<the caller>.ps1   <- the caller
#     MyInvocation.PSCommandPath  ...\test\<the caller>.ps1   <- the caller
#     PSCommandPath               ...\test\lib\harness.ps1    <- this file
#     MyInvocation.MyCommand.Name harness.ps1                  <- this file
#
# So the two spellings that read like the obvious ones are the two that name the
# wrong script, and would have filed every Windows row under `harness`. It is
# read at load time and not inside a function because by the time nt_pass runs,
# the invocation that names a caller is the call to nt_pass.
$script:NT_SUITE = if ($env:NT_SUITE) {
    $env:NT_SUITE
} elseif ($MyInvocation.ScriptName) {
    [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.ScriptName)
} else {
    "harness"
}

# Where the rows go. Unset means prose only -- what a suite run by hand in a
# terminal wants. Both Windows jobs write NT_RESULTS_DIR into $GITHUB_ENV from a
# `shell: bash` step, so every later `shell: pwsh` step inherits it and no call
# site has to know.
$script:NT_RESULTS = $null
if ($env:NT_RESULTS) {
    $script:NT_RESULTS = $env:NT_RESULTS
} elseif ($env:NT_RESULTS_DIR) {
    try {
        $null = New-Item -ItemType Directory -Force -Path $env:NT_RESULTS_DIR
        $script:NT_RESULTS = Join-Path $env:NT_RESULTS_DIR "$($script:NT_SUITE).tsv"
    } catch {
        $script:NT_RESULTS = $null
    }
}

$script:NT_FAILURES = 0
$script:NT_PASSES = 0
$script:NT_SKIPS = 0

# The encoding, and it is the whole reason rows are not written with
# Add-Content or Out-File.
#
# Those two are the obvious spellings and both were measured writing the wrong
# bytes. On the pwsh 7.6.5 windows-content runs, one row through each:
#
#     AppendAllText   ... P A S S \t a   d e t a i l ... 303 241  \n
#     Add-Content     ... P A S S \t a d d - c o n t e n t  \r  \n
#     Out-File        ... P A S S \t o u t - f i l e  \r  \n
#
# Both terminate with [Environment]::NewLine, which is CRLF here -- and Windows
# PowerShell 5.1 would additionally default them to UTF-16LE, which sheet.sh
# reads as binary. sheet.sh reads these rows with `awk -F'\t'`, so that CRLF
# leaves a \r on the end of the detail field and the same sentence taken on
# Linux compares unequal to the one taken here. It is the defect nt_clean
# already strips \r for, arriving through the file writer instead of through
# the string, where no amount of cleaning the string would have caught it.
#
# AppendAllText writes the bytes it is given and appends nothing, so the newline
# below is a literal LF and the encoding is UTF-8 with no BOM. The 303 241 above
# is the accented character the probe put in the detail, arriving as UTF-8.
#
$script:NT_ENC = New-Object System.Text.UTF8Encoding($false)

# A field with a tab or a newline in it would silently move every column after
# it, so the separator is removed rather than escaped: these are human sentences
# and a stray tab in one is never load-bearing. Carriage returns go too, for the
# reason above -- and on this platform they arrive by default rather than by
# accident, because a title read through PowerShell carries whatever the window
# had.
function nt_clean($s) {
    if ($null -eq $s) { return "" }
    return ([string]$s) -replace "[`t`r`n]", ""
}

# One row, appended and not held, so a suite killed by its timeout still leaves
# behind everything it had established up to that point.
#
# The try/catch is this language's `|| true`. These suites run under
# $ErrorActionPreference = "Stop", where a failed write is a terminating error:
# a reporter that can end the run it is reporting on would take the totals line
# down with it, which is the one line that says how many failures there were.
# harness.sh makes the same promise with `2>/dev/null || true` and by having
# every reporter return 0. Measured: a write into a path that does not exist
# raises MethodInvocationException, and the catch holds it.
function nt_row($id, $verdict, $detail) {
    if (-not $script:NT_RESULTS) { return }
    $line = "{0}`t{1}`t{2}`t{3}`t{4}`n" -f `
        (nt_clean $script:NT_LANE), (nt_clean $script:NT_SUITE),
        (nt_clean $id), $verdict, (nt_clean $detail)
    try {
        [System.IO.File]::AppendAllText($script:NT_RESULTS, $line, $script:NT_ENC)
    } catch {
        # Deliberately silent, and deliberately not re-thrown.
    }
}

# The three verdicts and the reading.
#
# Every one of them prints with Write-Host, and that is not a style choice.
# PowerShell's success stream is a function's return value: a reporter written
# with Write-Output, called from inside a function that also returns something,
# prepends its prose to that return value and the caller reads a two-element
# array where it expected a field. verify-attack.ps1 reports from inside
# assert_field and reads fields out of Get-Field in the same file, so this is
# the shape that file already has. The CI steps capture it -- every one of them
# runs the suite as `& .\test\suite\<name>.ps1 *>&1 | Tee-Object`, and `*>&1` merges
# the information stream Write-Host writes to. Both halves were measured: a
# probe function that reported twice and then returned a value handed its caller
# THE-RETURN-VALUE alone, and the prose reached the tee'd log intact.
function nt_pass($id, $detail) {
    $script:NT_PASSES++
    Write-Host "  PASS: $detail"
    nt_row $id "PASS" $detail
}

function nt_fail($id, $detail) {
    $script:NT_FAILURES++
    Write-Host "  FAIL: $detail"
    nt_row $id "FAIL" $detail
    # Opt-in, for the reason harness.sh gives at length: GitHub keeps thirty
    # annotations per job and drops the rest silently, oldest first, so a
    # reporter that annotated by default would refill the bucket that was
    # emptied to make room for these.
    if ($env:NT_ANNOTATE -and $env:GITHUB_ACTIONS) {
        Write-Host "::error title=$($env:NT_ANNOTATE)::$($script:NT_SUITE): $detail"
    }
}

# SKIP, which no PowerShell suite in this tree could say until now. The nearest
# things were a `NOTE:` prefix nothing consumes, the word SKIPPED inside a
# report line, and two suites that skipped by printing a sentence and calling
# exit 0 -- which is indistinguishable, to every reader downstream, from a lane
# that asserted the thing and was happy.
function nt_skip($id, $reason) {
    $script:NT_SKIPS++
    Write-Host "  SKIP: $reason"
    nt_row $id "SKIP" $reason
}

# A measurement, never a verdict, and so it takes no case id: `report:` lines
# are the standing evidence a later round reads, and filing them as assertions
# would put readings in the cross-lane matrix, where every row is supposed to be
# something that can be true or false.
function nt_report($m) { Write-Host "report: $m" }

# The two comparisons that account for most of the assertions in the tree, in
# the spelling assemble.sh's eq() established: `name (value)` passing, and
# `name expected=... actual=...` failing.
function nt_eq($id, $name, $actual, $expected) {
    if ($actual -eq $expected) {
        nt_pass $id "$name ($actual)"
    } else {
        nt_fail $id "$name expected=$expected actual=$actual"
    }
}

# -like and not -match, because harness.sh's nt_match takes a glob and the two
# lanes have to be able to be handed the same pattern.
function nt_match($id, $name, $value, $pattern) {
    if ($value -like $pattern) {
        nt_pass $id "$name ($value)"
    } else {
        nt_fail $id "$name did not match $pattern; actual=$value"
    }
}

# One ` key=value` field out of a report, the way harness.sh spells it. Three
# copies on this side -- verify-attack.ps1, demo.ps1 and themelive.ps1 -- in
# three dialects, against twenty-three copies and three dialects in bash. Two of
# them take this; themelive.ps1 does not dot-source the harness yet and keeps
# its own until it does.
#
# `\S+` is `[^ ]*`: the narrower classes the other two carried truncate a value
# with a character they do not list, and a truncated reading compares unequal to
# itself without saying why.
#
# The space is prepended to the subject as well as written into the pattern, and
# both halves matter. In the pattern it is what separates one field from the
# next: without it `nav` also matches the tail of `postnav`, and both of those
# sit in one attack title answering different questions. Prepended, it is what
# lets the first field on a line match at all.
#
# One difference from the bash word, and it cannot be removed: -match takes the
# leftmost match where sed's greedy `.*` takes the rightmost, so a subject
# carrying one key twice would answer differently in the two languages. Nothing
# in this tree writes one, and the anchor above is what makes the distinct-key
# case agree.
#
# Empty for absent, which is harness.sh's answer too. The suites that want a
# word there say so themselves: verify-attack.ps1 asserts against MISSING.
function nt_field($name, $text) {
    if (" $text" -match " $name=(\S+)") { return $Matches[1] }
    return ""
}

# The last line of a suite, and its exit status.
#
# The status is the count of failed cases, which is the contract verify-std.sh
# established and test/run.sh relies on to add a lane up without parsing
# anything. Nine of the PowerShell suites end `if ($Failures -gt 0) { exit 1 }`
# instead, which reports one failure whether there was one or twenty -- and on
# the day these lanes join the manifest, run.sh would add that 1 to the lane.
function nt_finish() {
    nt_report ("totals {0} passes={1} failures={2} skips={3}" -f `
        $script:NT_SUITE, $script:NT_PASSES, $script:NT_FAILURES, $script:NT_SKIPS)
    exit $script:NT_FAILURES
}
