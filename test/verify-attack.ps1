# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-attack.ps1 - Asserts what neutrinoattack.js measured (Windows).
#
# Two of these are expected to differ from the other platforms, and both
# differences are measured facts about this build rather than oversights:
# the transport here is still the document title, so a page that writes one is
# writing on the channel, and there is no navigation refusal to refuse with.
# They are asserted to the value that was measured so a change either way shows
# up instead of passing quietly.

$ErrorActionPreference = "Stop"

$Timeout = 120
$PollInterval = 500
$Failures = 0

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
    Write-Host "FAIL: a frame drove the native window"
    Write-Host "      the content policy let it run and the host took its"
    Write-Host "      messages, which is an escape and not a residual"
    exit 1
}

if ($title -eq "ATTACK-DATA-ESCAPED") {
    Write-Host "FAIL: a data: document drove the native window"
    Write-Host "      the navigation was permitted and the host obeyed the page"
    Write-Host "      that arrived, which is an escape and not a residual"
    exit 1
}

if (-not $title) {
    Write-Host "FAIL: the attack app never reported"
    Write-Host "      a build that renders nothing would refuse every attack by"
    Write-Host "      doing nothing at all, so no report is a failure and not a pass"
    Write-Host "  windows with a title when the wait gave up:"
    Get-Process | Where-Object { $_.MainWindowTitle -ne "" } |
        ForEach-Object { Write-Host "    $($_.ProcessName): $($_.MainWindowTitle)" }
    exit 1
}

Write-Host "  report: $title"

function Get-Field($name) {
    # Anchored on the space that separates one field from the next.
    # -match takes the leftmost match, so an unanchored "nav" reads the
    # tail of "postnav" instead -- a different question whose answer is
    # the same often enough to go unnoticed.
    if ($title -match " $name=([A-Za-z]+)") { return $Matches[1] }
    return "MISSING"
}

function Assert-Field($label, $expected, $actual) {
    if ($expected -eq "any") {
        Write-Host "  NOTE: $label = $actual (recorded, not asserted on this platform)"
    } elseif ($actual -eq $expected) {
        Write-Host "  PASS: $label = $actual"
    } else {
        Write-Host "  FAIL: $label expected=$expected actual=$actual"
        $script:Failures++
    }
}

# Without this the rest is worthless: it says a well-formed record sent down the
# same path the attacks used was obeyed, so the refusals are refusals and not a
# transport that drops everything.
Assert-Field "wire (control)" "LIVE" (Get-Field "wire")

Assert-Field "malformed records refused" "REFUSED" (Get-Field "raw")
Assert-Field "base-uri pinned"           "REFUSED" (Get-Field "base")
Assert-Field "inline script refused"     "BLOCKED" (Get-Field "inline")

# A forged title is only refusable where the title is not the channel. This
# build reports which one it wired, so the assertion follows the code rather
# than this platform's history: if the real message channel came up, a forged
# title has to be refused like anywhere else, and if it fell back to the title
# then writing one is sending a message rather than forging one.
$transport = Get-Field "tx"
Write-Host "  transport: $transport"
if ($transport -eq "title") {
    Write-Host "  NOTE: fell back to the document title; any page here can drive the window"
    Assert-Field "forged title" "OBEYED" (Get-Field "forge")
} else {
    Assert-Field "forged title" "REFUSED" (Get-Field "forge")
}

# There is a navigation refusal on Windows now, so this is asserted like
# everywhere else. What it is worth here is limited by the lane and not by the
# guard: this page aims at a host that never resolves, so the load would fail on
# its own and a REFUSED here does not by itself prove a guard ran. The suite
# that proves it is test/verify-nav.ps1, against a target that answers.
Assert-Field "navigation refused" "REFUSED" (Get-Field "nav")

# A frame that drove the window would have said so in the title, and that is
# checked before any of this is read. Reaching here means it did not.
Write-Host "  PASS: no frame drove the window"

# Refusing the top-frame data: navigation is not this project's doing -- every
# engine here already answers "not allowed to navigate top frame to data URL".
if ((Get-Field "navdata") -eq "REFUSED") {
    Write-Host "  NOTE: top-frame data: navigation refused (the engine does this)"
} else {
    Write-Host "  NOTE: data: navigation was permitted; the document that arrived"
    Write-Host "        could not drive the window, so it is contained not closed"
}

# A refusal that also broke the channel would look like a pass everywhere else
# on this line, so what happens after one is asserted rather than assumed --
# the same rule verify-attack.sh applies on the other three engines. The
# navigation is refused, this document is therefore still the app's own, and a
# well-formed record from it has to be obeyed: OBEYED is the right answer and
# REFUSED would be the app unable to drive its own window.
#
# This field was `any` while the guard did not exist, and the comment that stood
# here said the day one landed the change should show up instead of passing
# quietly. It landed; the page no longer leaves, so a settled report arrives and
# the question can be answered here at last.
Assert-Field "the refusal left the channel working" "OBEYED" (Get-Field "postnav")

Write-Host "=== Results: $Failures failure(s) ==="
if ($Failures -gt 0) { exit 1 }
exit 0
