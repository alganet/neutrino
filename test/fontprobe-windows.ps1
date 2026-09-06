# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# fontprobe-windows.ps1 - what Windows will tell a launcher about the desktop's
# fonts, and the one role it has no answer for at all.
#
# PROBE. The Windows half of the round fontprobe-gtk.js opens.
#
# Usage: powershell -ExecutionPolicy Bypass -File test/fontprobe-windows.ps1 [watch-seconds]
#
# PowerShell rather than a jsc.exe artifact, and the reason is the same one that
# put the other three probes outside the launcher: the question is what the
# toolkit answers. System.Drawing.SystemFonts is the same class the launcher's
# JScript.NET region would reach, reached from a shell that can print.
#
# The expected findings, which this exists to confirm or refute:
#
#   - SystemFonts distinguishes a caption font, a menu font and a status font,
#     so `ui`, `titlebar` and `small` all have real answers here.
#   - There is no monospace system font. Windows has no user-facing setting for
#     one; the nearest thing is the console's face, which is a different program's
#     preference and is read below only to say what it contains.
#   - Unlike SystemColors -- which the palette round found frozen at their
#     classic light values whatever the app theme says -- these *do* follow the
#     user's text size. Which is why the watch half exists.

$ErrorActionPreference = "Continue"
$watch = 0
if ($args.Count -ge 1) { [void][int]::TryParse($args[0], [ref]$watch) }

function Say($s) { [Console]::Error.WriteLine("FONTPROBE $s") }

Add-Type -AssemblyName System.Drawing | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null

function Describe($font) {
    if ($null -eq $font) { return "<nil>" }
    try {
        # SizeInPoints and Size are not the same number. Size is in the font's
        # own Unit, which for a system font is usually Point but is not promised
        # to be -- a launcher reading Size and assuming points would be wrong on
        # exactly the machines that are configured unusually, which is the worst
        # place to be wrong. Both are reported so the round can see whether they
        # ever diverge.
        $style = $font.Style.ToString()
        return ('family="{0}" sizeInPoints={1} size={2} unit={3} style={4} bold={5} height={6}' -f `
            $font.Name, $font.SizeInPoints, $font.Size, $font.Unit, $style, $font.Bold, $font.Height)
    } catch { return "<threw: $_>" }
}

function TryFont($label, $block) {
    try { Say ("  {0} {1}" -f $label.PadRight(14), (Describe (& $block))) }
    catch { Say ("  {0} <threw: {1}>" -f $label.PadRight(14), $_) }
}

Say "start os=$([System.Environment]::OSVersion.VersionString) clr=$([System.Environment]::Version)"

# The DPI the process believes in, which decides whether a point size read here
# is the one WebView2's CSS pixels are relative to. The launcher's exe carries
# no DPI-awareness manifest, so this is expected to read 96 even on a scaled
# desktop -- and if it does, the pt->px conversion is the flat 96/72 and needs
# no scaling term, which is the same shape the GTK lane measured for a different
# reason.
try {
    $g = [System.Drawing.Graphics]::FromHwnd([System.IntPtr]::Zero)
    Say ("graphics dpiX={0} dpiY={1}" -f $g.DpiX, $g.DpiY)
    Say ("ptToPx={0}" -f ($g.DpiX / 72))
    $g.Dispose()
} catch { Say "graphics <threw: $_>" }

TryFont "messageBox"   { [System.Drawing.SystemFonts]::MessageBoxFont }
TryFont "caption"      { [System.Drawing.SystemFonts]::CaptionFont }
TryFont "smallCaption" { [System.Drawing.SystemFonts]::SmallCaptionFont }
TryFont "menu"         { [System.Drawing.SystemFonts]::MenuFont }
TryFont "status"       { [System.Drawing.SystemFonts]::StatusFont }
TryFont "iconTitle"    { [System.Drawing.SystemFonts]::IconTitleFont }
TryFont "dialog"       { [System.Drawing.SystemFonts]::DialogFont }
TryFont "default"      { [System.Drawing.SystemFonts]::DefaultFont }

# The accessibility text scale, which is the knob that moves everything above.
# Absent on a machine that has never been scaled, which is Windows' own default
# rather than a missing reading -- the same shape as AppsUseLightTheme.
try {
    $ts = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Accessibility" -Name "TextScaleFactor" -ErrorAction SilentlyContinue
    if ($null -eq $ts) { Say "textScaleFactor absent (Windows' own default of 100)" }
    else { Say ("textScaleFactor={0}" -f $ts.TextScaleFactor) }
} catch { Say "textScaleFactor <threw: $_>" }

# The nearest thing Windows has to a monospace preference, which is not one: it
# is the console host's face, set per-application, and no part of the shell or
# the desktop reads it for anything else. Reported so the round can say out loud
# that the `monospace` role has no system answer on this platform and has to
# fall back -- to `ui`, or to the engine's own `monospace`, which is the choice
# the page probe's half informs.
try {
    $c = Get-ItemProperty -Path "HKCU:\Console" -ErrorAction SilentlyContinue
    if ($null -ne $c -and $c.FaceName) { Say ('console FaceName="{0}" (not a desktop setting)' -f $c.FaceName) }
    else { Say "console FaceName absent" }
} catch { Say "console <threw: $_>" }

if ($watch -le 0) { Say "done watch=0"; exit 0 }

# The live half, done by polling rather than by a message pump, and that is the
# measurement rather than a shortcut. The launcher's Windows lane already
# re-reads the palette on its event loop -- there is no registry watcher and
# never was -- so what matters is whether a re-read of SystemFonts *sees* a
# change at all, and whether the class caches. SystemFonts hands back a new Font
# each call and the underlying read is SPI_GETNONCLIENTMETRICS, which is not
# promised to be free; the elapsed time per poll is printed so the round can say
# what riding the existing tick would cost.
Say "watching for ${watch}s"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$last = ""
$polls = 0
$fired = 0
$totalTicks = 0
while ($sw.Elapsed.TotalSeconds -lt $watch) {
    $t0 = [System.Diagnostics.Stopwatch]::StartNew()
    $now = (Describe ([System.Drawing.SystemFonts]::MessageBoxFont)) + " | " + `
           (Describe ([System.Drawing.SystemFonts]::CaptionFont))
    $t0.Stop()
    $totalTicks += $t0.Elapsed.Ticks
    $polls++
    if ($now -ne $last) {
        if ($last -ne "") { $fired++; Say "fired#$fired $now" }
        $last = $now
    }
    Start-Sleep -Milliseconds 250
}
$avgMs = if ($polls -gt 0) { [math]::Round(($totalTicks / $polls) / 10000.0, 4) } else { 0 }
Say "done watch=$watch fired=$fired polls=$polls avgReadMs=$avgMs"
Say "final $last"
