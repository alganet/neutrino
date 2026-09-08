# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-attack.ps1 - Asserts what neutrinoattack.js measured (Windows).
#
# The app reports one final title and then leaves it alone, so this does not
# have to keep pace with anything -- it waits for a report and reads it.
#
# All twelve are asserted here, and the header that stood in this place said
# two of them could not be: that the transport was still the document title, so
# writing one was sending a message rather than forging one, and that there was
# no navigation refusal to refuse with. Neither is true any more. This lane
# reports tx=webmessage and refuses the navigation, and the file already knew
# it -- the comment at the nav assertion says so in as many words while the
# header above it still said the opposite.
#
# Which is why the forge assertion keys off the transport the build reports
# rather than off this platform's history: the expectation follows the code, so
# the day either of those moves back it shows up as a failure instead of as a
# comment nobody reread.

$ErrorActionPreference = "Stop"

# The six words, and the first PowerShell suite to speak them. This file and
# test/suite/verify-attack.sh have always been a twin pair -- same probe, same
# settled-title protocol, same field names, comments that quote each other --
# and they asserted the same twelve facts in two sets of sentences that no
# reader downstream could line up. The ids are what say the two lanes asserted
# one thing; see lib/harness.ps1 for why they are spelled the way they are.
. (Join-Path $PSScriptRoot "..\lib\harness.ps1")

$Timeout = 120
$PollInterval = 500

# The nine cases below the two title checks all read one field out of the
# settled title. Where there is no title to read them from, each says so: an
# escape and a no-show are both answers to the two cases above them and to none
# of these, and a case that files nothing is a hole the grid cannot tell from a
# suite that stopped early. Ported from verify-attack.sh, which needed it for
# the same three branches.
function nt_skip_fields($why) {
    nt_skip attack.wire.control $why
    nt_skip attack.raw.refused $why
    nt_skip attack.base.pinned $why
    nt_skip attack.inline.blocked $why
    nt_skip attack.eval.blocked $why
    nt_skip attack.frame.api $why
    nt_skip attack.forge.refused $why
    nt_skip attack.nav.refused $why
    nt_skip attack.postnav.channel $why
}

Write-Host "=== Waiting for the attack app to report ==="
# Two reports arrive: a snapshot taken before the navigation attempt, and the
# settled one after it. There is no navigation refusal on this platform, so the
# settled one is not expected to come at all -- waiting for DONE here would fail
# every run while the report sat on screen the whole time, which is what it did.
function Read-Report {
    $proc = Get-Process |
        Where-Object { $_.MainWindowTitle -like "ATTACK *" } |
        Select-Object -First 1
    if ($proc) { return $proc.MainWindowTitle }
    return $null
}

$deadline = (Get-Date).AddSeconds($Timeout)
$title = $null
do {
    $title = Read-Report
    if ($title) { break }
    Start-Sleep -Milliseconds $PollInterval
} while ((Get-Date) -lt $deadline)

if ($title) {
    $settle = (Get-Date).AddSeconds(15)
    while (((Get-Date) -lt $settle) -and ($title -notlike "*DONE*")) {
        Start-Sleep -Milliseconds $PollInterval
        $latest = Read-Report
        if ($latest) { $title = $latest }
    }
}

# A data: document that got the channel says so in the title itself, which is
# not a result to be weighed against others -- it is the escape having happened.
if ($title -eq "ATTACK-FRAME-ESCAPED") {
    nt_pass attack.reported "the attack app reported a settled title"
    nt_fail attack.frame.title-escape ("a frame drove the native window: the " +
        "content policy let it run and the host took its messages, which is a " +
        "same-null-origin escape and not a residual")
    nt_skip attack.data.escape ("a frame escaped first, so what a data: " +
        "document would have done was never reached")
    nt_skip_fields ("a frame drove the window, so the fields of a settled " +
        "report were never read")
    nt_finish
}

if ($title -eq "ATTACK-DATA-ESCAPED") {
    nt_pass attack.reported "the attack app reported a settled title"
    # Reaching here means the title was not the frame's, which is the whole of
    # what that case asks.
    nt_pass attack.frame.title-escape "no frame's title reached the native window"
    nt_fail attack.data.escape ("a data: document drove the native window: the " +
        "navigation was permitted and the host obeyed the page that arrived, " +
        "which is a same-null-origin escape and not a residual")
    nt_skip_fields ("a data: document drove the window, so the fields of a " +
        "settled report were never read")
    nt_finish
}

if (-not $title) {
    nt_fail attack.reported ("the attack app never reported: a build that " +
        "renders nothing would refuse every attack by doing nothing at all, so " +
        "no report is a failure and not a pass")
    nt_skip attack.frame.title-escape ("nothing reported, so no title was read " +
        "and no escape could be seen in one")
    nt_skip attack.data.escape ("nothing reported, so no title was read and no " +
        "escape could be seen in one")
    nt_skip_fields "nothing reported, so there were no fields to read"
    Write-Host "  windows with a title when the wait gave up:"
    Get-Process | Where-Object { $_.MainWindowTitle -ne "" } |
        ForEach-Object { Write-Host "    $($_.ProcessName): $($_.MainWindowTitle)" }
    nt_finish
}

nt_pass attack.reported "the attack app reported a settled title"

Write-Host "  report: $title"

# The reading this file takes, out of the title it settled on. The regex was
# this file's own and it named the hazard it guards -- an unanchored "nav"
# reading the tail of "postnav" -- while leaving the subject unanchored, so a
# key in the first column would have read as MISSING. The harness carries both
# halves; what stays here is the word this file asserts against for an absent
# field.
function Get-Field($name) {
    $v = nt_field $name $title
    if ($v) { return $v }
    return "MISSING"
}

# assert_*, and named that way for the registry scan: the id arrives in a
# variable here, and the prefix is the convention that scan knows.
#
# `any` was a NOTE, which is prose nothing reads. It is the platform saying it
# cannot ask this one, which is what a skip is for.
function assert_field($id, $label, $expected, $actual) {
    if ($expected -eq "any") {
        nt_skip $id "$label = $actual, which this platform records rather than asserts"
    } elseif ($actual -eq $expected) {
        nt_pass $id "$label = $actual"
    } else {
        nt_fail $id "$label expected=$expected actual=$actual"
    }
}

# Without this the rest is worthless: it says a well-formed record sent down the
# same path the attacks used was obeyed, so the refusals are refusals and not a
# transport that drops everything.
assert_field attack.wire.control "wire (control)" "LIVE" (Get-Field "wire")

assert_field attack.raw.refused    "malformed records refused" "REFUSED" (Get-Field "raw")
assert_field attack.base.pinned    "base-uri pinned"           "REFUSED" (Get-Field "base")
assert_field attack.inline.blocked "inline script refused"     "BLOCKED" (Get-Field "inline")
# The other half of script-src, and it has no markup to point at. The document
# said 'unsafe-eval' for as long as the engine dispatch went through eval; it
# says 'none' now, and this is what says so on every engine rather than in a
# comment. RANEVAL, RANFUNCTION and RANBOTH each name which call compiled.
assert_field attack.eval.blocked   "eval refused"              "BLOCKED" (Get-Field "evl")

# What a frame reached, measured from the parent. The frame is handed this
# build's API, so it attempts the same verb every other check here attempts;
# the size of the window afterwards is the answer, and the parent is the only
# realm that can read it. The title check below is the second half and asks a
# different question -- whether a subframe's title reached the native window,
# which no engine here is supposed to let happen at all.
assert_field attack.frame.api "a frame could not drive it" "REFUSED" (Get-Field "frame")

# A forged title is only refusable where the title is not the channel. This
# build reports which one it wired, so the assertion follows the code rather
# than this platform's history: if the real message channel came up, a forged
# title has to be refused like anywhere else, and if it fell back to the title
# then writing one is sending a message rather than forging one.
#
# Hoisted to a variable so there is one call and one case, which is the shape
# verify-attack.sh has: two calls under a branch file the id twice on the lanes
# that take both arms over a run, and matrix.py folds repeats FAIL-over-PASS.
$transport = Get-Field "tx"
Write-Host "  transport: $transport"
$expectForge = "REFUSED"
if ($transport -eq "title") {
    nt_report "fell back to the document title; any page here can drive the window"
    $expectForge = "OBEYED"
}
assert_field attack.forge.refused "forged title" $expectForge (Get-Field "forge")

# There is a navigation refusal on Windows now, so this is asserted like
# everywhere else. What it is worth here is limited by the lane and not by the
# guard: this page aims at a host that never resolves, so the load would fail on
# its own and a REFUSED here does not by itself prove a guard ran. The suite
# that proves it is test/suite/verify-nav.ps1, against a target that answers.
$expectNav = "REFUSED"
assert_field attack.nav.refused "navigation refused" $expectNav (Get-Field "nav")

# A frame whose *title* reached the native window would have said so in that
# title, and that is checked before any of this is read. Reaching here means
# it did not, and the field above says the API it was handed reached nothing
# either.
nt_pass attack.frame.title-escape "no frame drove the window"

# Refusing the top-frame data: navigation is not this project's doing -- every
# engine here already answers "not allowed to navigate top frame to data URL".
# Recorded so the difference is visible, not claimed as a control.
nt_pass attack.data.escape "no data: document drove the native window"

if ((Get-Field "navdata") -eq "REFUSED") {
    nt_report "top-frame data: navigation refused (the engine does this)"
} else {
    nt_report ("data: navigation was permitted; the document that arrived " +
        "could not drive the window, so it is contained and not closed")
}

# A refusal that also broke the channel would look like a pass everywhere else
# on this line, so what happens after one is asserted rather than assumed --
# the same rule verify-attack.sh applies on the other three engines. The
# navigation is refused, this document is therefore still the app's own, and a
# well-formed record from it has to be obeyed: OBEYED is the right answer and
# REFUSED would be the app unable to drive its own window.
#
# Where the navigation is not refused, the document answering afterwards is not
# the app's and the same OBEYED would be an escape -- so this is asserted only
# where the refusal above was, which is the condition verify-attack.sh states
# and this file used to leave implicit in a platform fact.
if ($expectNav -eq "REFUSED") {
    assert_field attack.postnav.channel "the refusal left the channel working" `
        "OBEYED" (Get-Field "postnav")
} else {
    nt_skip attack.postnav.channel ("postnav = $(Get-Field 'postnav'), and with " +
        "no navigation refusal to follow it OBEYED would be an escape rather " +
        "than a working channel")
}

# The count, and not whether there was one.
nt_finish
