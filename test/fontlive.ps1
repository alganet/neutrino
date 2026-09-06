# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# fontlive.ps1 - does a *running* Windows app notice the desktop's fonts moving?
#
# The twin of themelive.ps1, one reading along, and it exists for the same
# reason: this lane's `fonts` step launches once and reads once, so a watcher
# that never fires produces a green launch. The Windows font watcher is a
# re-read on the driver's own message loop -- `spins % 60 === 30`, about once a
# second -- so what is asserted here is that the loop reads and the diff
# delivers.
#
# **This file carries a control themelive.ps1 does not need, and the control is
# the point.** That file's knob is the registry value the driver itself reads,
# so a write that lands is a change the app must see. This one's knob is the
# accessibility text scale, and what the driver reads is
# `System.Drawing.SystemFonts` -- which comes from SPI_GETNONCLIENTMETRICS and
# is not promised to follow a bare registry write. Windows normally moves those
# metrics through a WM_SETTINGCHANGE broadcast that the Settings app sends and a
# `Set-ItemProperty` does not.
#
# So this asks SystemFonts itself, in this process, before it blames the app:
#
#   the knob would not write            -> skip; about this machine
#   the knob wrote, SystemFonts moved,
#     the app was not told              -> FAIL; the watcher
#   the knob wrote, SystemFonts did not
#     move in here either               -> skip, loudly; there was nothing an
#                                          app could have been told about
#
# That third branch is why this could be written before the knob was known to
# work -- and on the runner it is the branch that fires. Measured:
#
#   knob before: TextScaleFactor=<absent:100>   metrics: Segoe UI/9 Segoe UI/9
#   knob after:  TextScaleFactor=150            metrics: Segoe UI/9 Segoe UI/9
#
# The value writes and the metrics do not move, which settles it: this knob
# alone does not reach SPI_GETNONCLIENTMETRICS, so on a runner this half is a
# skip and says why. The lane is live in principle -- the watcher is a re-read
# on the driver's own loop and fontsDiffer gates it, both exercised by the
# `fonts` step -- and untestable in CI until something here broadcasts
# WM_SETTINGCHANGE. A P/Invoke of SystemParametersInfo with SPIF_SENDCHANGE is
# the mechanism that would; it is a bigger change than this file and it has not
# been measured either.
#
# themeflip.sh's live half carries the same shape for the same reason -- it
# proves some knob delivers a change to a GTK of the suite's own before it
# reports a lane as broken -- and a suite that blames a launcher for a knob that
# does nothing is worse than one that says it could not tell.
param(
    [string]$Artifact = ".\test\neutrinolivefont.cmd",
    [int]$UpTimeout = 120,
    [int]$MoveTimeout = 30
)

$ErrorActionPreference = "Continue"
$key  = "HKCU:\Software\Microsoft\Accessibility"
$name = [System.IO.Path]::GetFileNameWithoutExtension($Artifact)
$rc   = 0

Add-Type -AssemblyName System.Drawing | Out-Null

function Note($t) { Write-Host "report: $t" }

function Read-Knob() {
    $v = (Get-ItemProperty -Path $key -Name TextScaleFactor -ErrorAction SilentlyContinue).TextScaleFactor
    if ($null -eq $v) { return "<absent:100>" } else { return "$v" }
}
function Set-Knob($scale) {
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name TextScaleFactor -Value $scale -Type DWord
}

# What the driver reads, read the same way, so the control and the thing being
# controlled cannot disagree about what "moved" means. Disposed for the reason
# font-windows.js gives: SystemFonts hands back a new IDisposable every time.
function Read-Metrics() {
    try {
        $m = [System.Drawing.SystemFonts]::MessageBoxFont
        $c = [System.Drawing.SystemFonts]::CaptionFont
        $t = "{0}/{1} {2}/{3}" -f $m.Name, $m.SizeInPoints, $c.Name, $c.SizeInPoints
        $m.Dispose(); $c.Dispose()
        return $t
    } catch { return "<threw: $_>" }
}

# The app's own title and not merely a window, for the reason themelive.ps1
# records: the package path puts a downloader on screen first.
function Get-Title() {
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } |
         Select-Object -First 1
    if ($p) { return [string]$p.MainWindowTitle }
    return ""
}
function Stop-App() {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

$was = Read-Knob
Note "knob before: TextScaleFactor=$was"
Note "metrics before: $(Read-Metrics)"

try {
    # Launched through cmd.exe with a working directory, for the reason
    # themelive.ps1 gives at length: Start-Process takes the child's directory
    # from [Environment]::CurrentDirectory and not from $PWD.
    Stop-App
    $null = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", $Artifact -WindowStyle Hidden `
        -WorkingDirectory (Get-Location).Path -PassThru

    $waited = 0
    while ($waited -lt $UpTimeout -and -not (Get-Title).StartsWith("STD-LIVEFONT")) {
        Start-Sleep -Seconds 1
        $waited++
    }
    $before = Get-Title
    if (-not $before.StartsWith("STD-LIVEFONT")) {
        Write-Host "FAIL: no STD-LIVEFONT window in ${UpTimeout}s; the probe never came up"
        exit 1
    }
    Note "live before: $before"
    if ($before -match 'src=null') {
        Write-Host "FAIL: the probe read no toolkit, so a flip would prove nothing"
        exit 1
    }

    Set-Knob 150
    $now = Read-Knob
    if ($now -ne "150") {
        Note "the knob would not take (reads $now); this machine refuses the write"
        Note "skipping: that is a reading about the runner and not about the watcher"
        exit 0
    }
    Note "knob after: TextScaleFactor=$now"

    # The control, and it runs before any verdict about the app. Given the same
    # budget the app gets, because SPI metrics may lag the write.
    $moved = $false
    $metricsBefore = Read-Metrics
    $waited = 0
    while ($waited -lt ($MoveTimeout * 2)) {
        if ((Read-Metrics) -ne $metricsBefore) { $moved = $true; break }
        Start-Sleep -Milliseconds 500
        $waited++
    }
    Note "metrics after: $(Read-Metrics)"
    if (-not $moved) {
        Note "SystemFonts did not move in this process either, so there was nothing"
        Note "  an app could have been told about. The knob writes the value and"
        Note "  nothing broadcasts WM_SETTINGCHANGE, which is the mechanism that"
        Note "  moves SPI_GETNONCLIENTMETRICS. Skipping rather than blaming the lane."
        exit 0
    }

    $waited = 0
    while ($waited -lt ($MoveTimeout * 2)) {
        if ((Get-Title) -match 'moved=yes') { break }
        Start-Sleep -Milliseconds 500
        $waited++
    }
    $after = Get-Title
    Note "live after: $after"

    if ($after -match 'moved=yes') {
        Write-Host "PASS: the running app was handed new fonts when the desktop's text size moved"
    } elseif ($after.StartsWith("STD-LIVEFONT")) {
        Write-Host "FAIL: SystemFonts moved under a running app and it was handed nothing; the font watcher did not fire"
        $rc = 1
    } else {
        Write-Host "FAIL: the probe stopped writing its title after the flip"
        $rc = 1
    }
} finally {
    # Put the desktop back where it was found, on every path out.
    if ($was -eq "<absent:100>") {
        Remove-ItemProperty -Path $key -Name TextScaleFactor -ErrorAction SilentlyContinue
    } else {
        Set-Knob ([int]$was)
    }
    Note "knob restored: TextScaleFactor=$(Read-Knob)"
    Stop-App
}

exit $rc
