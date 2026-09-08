# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# themeflip.ps1 - two launches of the theme probe with the desktop flipped
# between them, on the one platform whose knob is a registry value.
#
# Usage: themeflip.ps1 [-Artifact <path>] [-ScreenshotDir <dir>] [-LogDir <dir>]
#
# The unix half of this is test/suite/themeflip.sh, and the sequencing it owns is the
# sequencing this owns: the knob is set from outside the app and read back from
# outside it, and the second half refuses to start while the first half's window
# is still up. Both halves answer to the same title prefix, so a window that
# outlived its kill is one the next verifier would attach to and report about --
# a stale reading that looks exactly like a real one.
#
# It lived in .github/workflows/ci.yml as fifty-odd lines of inline pwsh. That
# is the one language in this tree a workflow cannot check: test/build/parse.sh covers
# the artifact's five, and test/build/psparse.ps1 covers every .ps1 in this directory
# before any of them runs -- but neither can see a script that exists only as a
# `run:` block. A PowerShell file that does not parse has shipped twice here,
# both times found by a runner eighteen minutes in. A file in this directory
# cannot be one of those.
#
# It does not analyse. The two halves are recorded and test/suite/themediff.sh reads
# them, which is the same division verify-std.ps1 keeps with analyse.sh and
# verify-windows.ps1 with walk.sh: PowerShell records natively, and the verdicts
# are taken once, in one language, for every lane.

param(
    [string]$Artifact = ".\test\neutrinostdtheme.cmd",
    [string]$ScreenshotDir = $env:USERPROFILE,
    [string]$LogDir = $HOME
)

$key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

function Set-AppsTheme($light) {
  New-Item -Path $key -Force | Out-Null
  Set-ItemProperty -Path $key -Name AppsUseLightTheme -Value $light -Type DWord
  Set-ItemProperty -Path $key -Name SystemUsesLightTheme -Value $light -Type DWord
}

# What the machine says the knob is at, asked after it was set and from outside
# the app -- the same reading themeflip.sh takes on the unix lanes, and for the
# same reason. Without it a half reports the value it *wrote*, and a lane where
# nothing moved cannot say whether the registry refused the write or the app
# never read it. Those are an apparatus defect and a finding, and they look
# identical.
function Read-Knob($tag) {
  $apps = (Get-ItemProperty -Path $key -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
  $sys  = (Get-ItemProperty -Path $key -Name SystemUsesLightTheme -ErrorAction SilentlyContinue).SystemUsesLightTheme
  $ctl  = [System.Drawing.SystemColors]::Control
  # The classic palette is carried too, because on Windows it is the one thing
  # expected *not* to move: SystemColors stays at its light values in either
  # scheme, which is why the driver overrides the surfaces from the registry
  # rather than reading them. A round that sees it move has found something
  # nobody here predicted.
  "report: knob $tag AppsUseLightTheme=$(if ($null -eq $apps) {'<absent:light>'} else {$apps}) " +
    "SystemUsesLightTheme=$(if ($null -eq $sys) {'<absent:light>'} else {$sys}) " +
    "SystemColors.Control=$($ctl.R),$($ctl.G),$($ctl.B)"
}

function Run-Half($tag, $shot) {
  Add-Type -AssemblyName System.Drawing
  Read-Knob $tag | Tee-Object -FilePath "$LogDir\flip-knobs.log" -Append | Write-Host
  & .\test\suite\verify-std.ps1 -Probe theme -ScreenshotDir $ScreenshotDir `
    -ShotName "theme-$shot" -Launch -Artifact $Artifact *>&1 |
    Tee-Object -FilePath "$LogDir\flip-$tag.log" | Out-Null
  Get-Process -Name neutrinostdtheme -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  # The precondition the unix half states out loud: the next launch must not
  # find this one's window.
  $n = 0
  while ($n -lt 60 -and (Get-Process -Name neutrinostdtheme -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 500; $n++
  }
}

Set-AppsTheme 1
Run-Half a light
Set-AppsTheme 0
Run-Half b dark
Set-AppsTheme 1

# `exit 0`, on purpose, and it is the one thing about this file a reader should
# not have to guess at.
#
# Run-Half discards each half's $LASTEXITCODE, which for every other suite in
# this tree would be a defect: test/run.sh adds a lane up by summing exit codes
# and never parsing, so a step that always exits 0 is a step that can never
# redden its lane. What makes it right here is that this file asserts nothing.
# It sets a knob, runs the verifier twice and keeps two logs -- and the verifier
# it runs is verify-std.ps1, which files the std.theme.* rows through
# lib/analyse.sh on its own account. Those rows are the signal; a second exit
# code carrying the same failures would double-count them in the lane total.
#
# So this is the sequencer and not the judge, which is the same division the
# header states for the analysis. The thing it would be worth failing on is a
# half that never ran at all, and that is not visible from an exit code either:
# it looks like a verifier that ran and found nothing, which is exactly what a
# hole in the grid is for.
exit 0
