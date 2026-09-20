# reap.ps1 - reap.sh, on the platform that has no pgrep.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: pwsh -File reap.ps1 <process-name> [<window-title-prefix>]
#
# reap.sh finds its targets with `pgrep -f` and its windows with xdotool, and the
# Windows runners have neither; what they have is the idiom eleven steps spelled
# by hand -- `Get-Process -Name <slot> | Stop-Process -Force`, and for the apps
# whose exe is not named after the artifact, `Where-Object MainWindowTitle -like
# "<PREFIX>*"`. reap.sh hands over to this file where it cannot do the job
# itself, so a row's `reap=` means one thing on every lane. The name is the
# artifact's slot, because the launcher names the exe after the .cmd, which is
# the same fact the steps relied on.
#
# It waits, as reap.sh does: Stop-Process returns when the signal is sent, not
# when the window is gone, and the next suite's first capture is what finds
# the difference.
param([string]$Name = "", [string]$Prefix = "")

function Targets {
    $t = @()
    if ($Name) { $t += @(Get-Process -Name $Name -ErrorAction SilentlyContinue) }
    if ($Prefix) {
        $t += @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like "$Prefix*" })
    }
    return $t
}

$found = @(Targets)
if ($found.Count -eq 0) {
    Write-Output "  reap: '$Name' was not running"
    exit 0
}
$found | Stop-Process -Force -ErrorAction SilentlyContinue
for ($n = 0; $n -lt 50; $n++) {
    if (@(Targets).Count -eq 0) {
        Write-Output "  reap: '$Name' is gone after $($n * 100)ms of waiting"
        exit 0
    }
    Start-Sleep -Milliseconds 100
}
Write-Output "  reap: '$Name' is STILL up after Stop-Process; later captures may carry it"
exit 0
