# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# probe-window.ps1 - did the app get a window, and did its content run?
#
# Three outcomes, because the difference between them is the whole finding:
#   NO_WINDOW         nothing ever showed a window
#   WINDOW_NO_CONTENT a window appeared but the page never set a title
#   CONTENT_OK        the page ran and drove the title
#
# Console hosts are skipped, and that is not a detail. The launcher runs
# "cmd.exe /c ...\neutrinotest.cmd", whose console window carries the script
# path in its title and a real MainWindowHandle -- so without this, a launch
# where the app never started at all scores WINDOW_NO_CONTENT off the console
# alone, and reads as a webview whose renderer died.

param([int]$TimeoutSeconds = 30)

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$sawWindow = $false

do {
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($p.MainWindowHandle -eq 0) { continue }
            if ($p.ProcessName -in @("cmd", "conhost", "powershell", "pwsh",
                                     "WindowsTerminal", "mintty", "bash")) { continue }
            $t = $p.MainWindowTitle
        } catch { continue }
        if (-not $t) { continue }
        if ($t -like "*STEP*" -or $t -like "*TESTS DONE*") {
            Write-Output "CONTENT_OK"
            exit 0
        }
        if ($t -like "*neutrino*") { $sawWindow = $true }
    }
    Start-Sleep -Milliseconds 400
} while ((Get-Date) -lt $deadline)

if ($sawWindow) { Write-Output "WINDOW_NO_CONTENT" } else { Write-Output "NO_WINDOW" }
exit 0
