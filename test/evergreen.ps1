# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# evergreen.ps1 - can this driver reach the WebView2 already on the machine?
#
# The Windows lane downloads a 20 MB NuGet package on first run and loads
# `Microsoft.Web.WebView2.WinForms.WebView2` out of it. That package is the
# *SDK*, not the runtime: what actually renders is the Evergreen Runtime, a
# machine-wide component that ships with Windows 11 and reached Windows 10
# through Windows Update. On almost every machine the thing being downloaded is
# a wrapper around something already installed.
#
# The managed wrapper is the only part that has to come from NuGet, because it
# is the only part the runtime does not carry. Skipping the download therefore
# means not using it -- driving `CreateCoreWebView2EnvironmentWithOptions` and
# the COM interfaces behind it from the JScript.NET the launcher already
# compiles. Whether jsc.exe can express that is the question, and it is not one
# that can be answered anywhere but on Windows.
#
# So this file measures, and asserts nothing about the driver. It is the reading
# the design is owed before a line of the driver changes:
#
#   runtime   the Evergreen Runtime: installed, which version, where, and what
#             is in that directory -- named, not assumed
#   managed   the runtime carries a `Microsoft.Web.WebView2.Core.dll` of its
#             own. If it were a managed assembly the whole question would be
#             over, so it is asked rather than reasoned about
#   idl       the IIDs and the vtable order, read out of the pinned package's
#             own WebView2.h. Nothing below guesses a GUID or a slot: what the
#             live section compiles is generated from this
#   dllimport whether jsc.exe accepts [DllImport] at all, in four spellings,
#             with Reflection.Emit as the control that must work
#   cominterop whether jsc.exe accepts a ComImport interface and a class
#             implementing it -- the callback the loader QueryInterfaces for
#   exports   what the installed runtime offers to be called through, read out
#             of the PE export table rather than searched for in the bytes
#   emitted   the same two constructs built with Reflection.Emit instead, with
#             no WebView2 anywhere near them
#   drive     a window, a document and a message back from the page -- the three
#             things beyond an environment that the driver would need
#   create    the whole hypothesis, live: a JScript.NET program with no package
#             anywhere near it creates a WebView2 environment against the
#             installed runtime and reads its version string back
#
# What the first run of this said, and what changed because of it:
#
#   jsc.exe will not declare a P/Invoke. A function with no body has to be
#   abstract, a static one cannot be, and the attribute itself is a syntax
#   error where it was put -- three errors, one answer. DefinePInvokeMethod
#   builds the same stub out of arguments and worked, so that is what `create`
#   uses now and what the driver would use.
#
#   jsc.exe does not appear to do the shorthand that lets [Foo] mean
#   FooAttribute: ComImport and InterfaceType came back "has not been declared"
#   and Guid came back "Type mismatch", which is System.Guid answering to a
#   name meant for GuidAttribute. `interface` itself drew no complaint. So the
#   cominterop section asks in four spellings now, and asks the finished type
#   whether it is actually imported rather than trusting that it compiled.
#
#   The runtime is installed on the runner and every EdgeUpdate registry key
#   this file knew to read is absent. A detection that believes `pv` would
#   report "not installed" on a machine that has it, which is a finding about
#   the product and not about the probe; the keys are enumerated now.
#
#   Two bugs of this file's own. It chose the runtime directory by taking the
#   last name in sorted order and got `SetupMetrics`, a bookkeeping folder
#   sitting beside the versioned one -- so the loader and the Core.dll were
#   reported absent from a directory that never had them, and `create` failed
#   on that. And the vtable parse dropped every property accessor, because the
#   MIDL annotation sits between `virtual` and `HRESULT`: ICoreWebView2Settings
#   came back with zero methods and every printed slot order was short.
#
# What the third run said, which is that the whole thing stands up:
#
#   The runtime's own EBWebView\x64\EmbeddedBrowserWebView.dll exports eight
#   things, and one of them is CreateWebViewEnvironmentWithOptionsInternal.
#   Called with a leading BOOL it returned S_OK, the emitted callback fired on
#   the same turn, and the environment answered get_BrowserVersionString with
#   151.0.4129.101 -- the installed runtime's own version, with no package on
#   disk. Called in the documented four-argument shape it returned E_NOINTERFACE,
#   which is the arguments shifting by one and is how the leading flag is known
#   to be there.
#
#   The emitted interop works: isimport true, the Guid preserved through
#   CustomAttributeBuilder, the four-instruction shim called, and a real
#   QueryInterface for the emitted IID answered.
#
#   The runtime client id is {F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}, named
#   "Microsoft Edge WebView2 Runtime", and its pv agrees with the directory.
#   Matching on the name rather than the GUID is what found it.
#
#   The entry point is undocumented, and that is the cost of this design rather
#   than a detail of it. What makes it affordable is that the package path stays
#   -- a runtime that stops answering is a download, not a broken app.
#
# What the second run added, with the directory and the parse fixed:
#
#   The installed runtime carries no WebView2Loader.dll. It carries
#   msedgewebview2.exe and EBWebView\x64\EmbeddedBrowserWebView.dll, which is
#   what the loader loads -- the loader is an SDK component and is one of the
#   things only the package has. So "reuse what is installed" needs an entry
#   point that is not the documented one, and `exports` reads the export table
#   to find out whether there is one.
#
#   The client id this file read was wrong in its last two groups. EdgeUpdate
#   has three children on the runner and none of them was the GUID being
#   probed, which is why round 1 reported a machine with no runtime while
#   standing in its install directory. Nothing is probed by name now.
#
#   jsc has no attribute syntax in this position at all. `[ComImportAttribute]`
#   drew no error while `[GuidAttribute("...")]` drew "Type mismatch" at the
#   column the string starts on -- which is `[X]` read as a one-element array
#   and `X("...")` as a cast. The spelling that looked like it worked was an
#   array being built and thrown away.
#
#   So both halves are emitted now. `emitted` is that technique on its own,
#   with no WebView2 in it, so that a failure there is about the technique and
#   a failure in `create` is about the runtime.
#
# `create` is the only section that can fail the lane. The rest are readings,
# and a reading that "fails" would only be saying the runner is not what we
# thought -- which is exactly what the log is for.
#
# Controls, because a probe that measures nothing also prints "ok":
#   dllimport  Reflection.Emit has to produce a working call, or "jsc cannot"
#              is indistinguishable from "this runner cannot"
#   idl        the header has to yield a plausible interface count, or an empty
#              parse reads as a clean one
#   create     the environment pointer has to be non-null *and* answer with a
#              version string, since S_OK with nothing behind it is the shape a
#              wrong vtable slot returns
#
# It starts no window and nothing it starts outlives the step: the live section
# creates an environment, not a controller, so there is no HWND and no view.
# That is deliberate -- PR 24 lost a runner to a suite that launched something.
#
# Usage: evergreen.ps1 [built.cmd]

$ErrorActionPreference = "Continue"

$failures = 0
function Report($m) { Write-Output "report: $m" }
function Fail($m) { Write-Output "FAIL: $m"; $script:failures++ }
function Section($m) { Write-Output "report: === $m" }

Write-Output "=== evergreen: the runtime already on the machine ==="

$work = Join-Path $env:TEMP ("evergreen-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$fx = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
if (-not (Test-Path (Join-Path $fx "jsc.exe"))) { $fx = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319" }
$jsc = Join-Path $fx "jsc.exe"
Report "env jsc=$(Test-Path $jsc) fx=$fx os=$([Environment]::Is64BitOperatingSystem) proc64=$([Environment]::Is64BitProcess)"

# Compiles one JScript.NET source and says whether it built, keeping the
# compiler's own words when it did not. Results land in $script: variables for
# the reason winexec.ps1 writes down: a PowerShell function returns everything
# written to the output stream, so a `return` under a Report line comes back as
# an array.
function Build-Js($name, $source, $outExe, $refs, $target) {
    $src = Join-Path $work $name
    Set-Content -Path $src -Value $source -Encoding ASCII
    $argv = @("/nologo", "/t:$target", "/autoref+", "/lib:$fx", "/out:$outExe")
    foreach ($r in $refs) { $argv += "/r:$(Join-Path $fx $r)" }
    $argv += $src
    $log = & $jsc $argv 2>&1 | Out-String
    $script:buildOk = (Test-Path $outExe)
    $script:buildLog = ($log -replace '\s+', ' ').Trim()
}

function Run-Probe($exe, $label, $timeoutMs) {
    $out = Join-Path $work "$label.out"
    $err = Join-Path $work "$label.err"
    $p = Start-Process -FilePath $exe -WorkingDirectory $work -PassThru -NoNewWindow `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $exited = $p.WaitForExit($timeoutMs)
    if (-not $exited) { $p.Kill(); Start-Sleep -Seconds 1 }
    $script:runCode = $(if ($exited) { "$($p.ExitCode)" } else { "killed" })
    $script:runOut = ""
    if (Test-Path $out) { $script:runOut = (("" + (Get-Content $out -Raw -EA SilentlyContinue)) -replace '\s+', ' ').Trim() }
    $script:runErr = ""
    if (Test-Path $err) { $script:runErr = (("" + (Get-Content $err -Raw -EA SilentlyContinue)) -replace '\s+', ' ').Trim() }
}

# =====================================================================
Section "runtime - what is installed, and where"
# =====================================================================
#
# The client id is the WebView2 Runtime's, and it is the same one Microsoft's
# own detection sample reads. Three keys because there are three ways it can be
# installed: machine-wide on a 64-bit OS (under WOW6432Node, because EdgeUpdate
# is a 32-bit component), machine-wide on a 32-bit OS, and per-user. `pv` of
# 0.0.0.0 means "not installed" and is not the same as the key being absent.

# Round 2 enumerated what is actually under EdgeUpdate and the client id this
# file was reading is not one of them. The children are
# {56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}, {F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}
# and {F3C4FE00-EFD5-403B-9569-398A20F1BA4A} -- and the second differs from what
# was being probed in its last two groups, which is a transcription error of
# mine and not a machine without a runtime. So nothing is probed by name any
# more: every child is enumerated and asked for its version and its display
# name, and which one is the runtime is a reading rather than a constant.
$edgeUpdateRoots = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate",
    "HKLM:\SOFTWARE\Microsoft\EdgeUpdate",
    "HKCU:\SOFTWARE\Microsoft\EdgeUpdate"
)
$runtimeVersion = ""
foreach ($base in $edgeUpdateRoots) {
    if (-not (Test-Path $base)) { Report "edgeupdate $base absent"; continue }
    foreach ($sub in @("Clients", "ClientState")) {
        $path = Join-Path $base $sub
        if (-not (Test-Path $path)) { Report "edgeupdate $path absent"; continue }
        foreach ($child in @(Get-ChildItem -Path $path -EA SilentlyContinue)) {
            $pv = $null
            $nm = $null
            try { $pv = (Get-ItemProperty -LiteralPath $child.PSPath -Name pv -EA Stop).pv } catch { }
            try { $nm = (Get-ItemProperty -LiteralPath $child.PSPath -Name name -EA Stop).name } catch { }
            Report "edgeupdate $sub $($child.PSChildName) pv=$(if ($pv) { $pv } else { 'absent' }) name=$(if ($nm) { $nm } else { 'absent' })"
            # The runtime names itself, and that is a sturdier key than a GUID
            # copied out of a document. A GUID that has to be right is exactly
            # what was wrong here.
            if ($pv -and $pv -ne "0.0.0.0" -and -not $runtimeVersion -and
                    $nm -and $nm -match "WebView2" -and $nm -notmatch "Beta|Dev|Canary") {
                $runtimeVersion = $pv
            }
        }
    }
}
Report "runtime version=$(if ($runtimeVersion) { $runtimeVersion } else { 'NONE' })"

# The registry says which version, not where. The install path is a convention
# and the convention is what is being tested, so it is searched for rather than
# built: a runtime somewhere else is a finding and not a crash.
#
# Only directories whose name is a version are candidates, and that is round 1's
# other correction. This took the last name in sorted order and got
# `SetupMetrics`, because the Application directory holds bookkeeping folders
# beside the versioned one -- so the section went on to report an absent loader
# and an absent Core.dll from a directory that was never going to have either,
# and `create` failed on a reading that was about this loop.
$runtimeDir = ""
$runtimeFound = @()
$roots = @(
    "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application",
    "$env:ProgramFiles\Microsoft\EdgeWebView\Application",
    "$env:LOCALAPPDATA\Microsoft\EdgeWebView\Application"
)
foreach ($r in $roots) {
    if (-not (Test-Path $r)) { Report "root $r absent"; continue }
    $all = @(Get-ChildItem -Path $r -Directory -EA SilentlyContinue | ForEach-Object { $_.Name })
    $versioned = @(Get-ChildItem -Path $r -Directory -EA SilentlyContinue |
        Where-Object { $_.Name -match '^\d+(\.\d+)+$' })
    Report "root $r all=$(if ($all.Count) { $all -join ',' } else { 'none' }) versioned=$(if ($versioned.Count) { ($versioned | ForEach-Object { $_.Name }) -join ',' } else { 'none' })"
    foreach ($d in $versioned) { $runtimeFound += $d }
}
foreach ($d in $runtimeFound) {
    if ($runtimeVersion -and $d.Name -eq $runtimeVersion) { $runtimeDir = $d.FullName }
}
if (-not $runtimeDir -and $runtimeFound.Count) {
    $runtimeDir = (@($runtimeFound | Sort-Object { [version]$_.Name }))[-1].FullName
}
Report "runtime dir=$(if ($runtimeDir) { $runtimeDir } else { 'NONE' })"

# Named, not assumed. The two files the design would depend on are the loader
# and whatever the loader loads, and neither is documented as being here.
$loaderPath = ""
$ebwPath = ""
if ($runtimeDir) {
    $interesting = @("WebView2Loader.dll", "Microsoft.Web.WebView2.Core.dll",
                     "EmbeddedBrowserWebView.dll", "msedgewebview2.exe")
    foreach ($n in $interesting) {
        $hits = @(Get-ChildItem -Path $runtimeDir -Filter $n -Recurse -File -EA SilentlyContinue |
            ForEach-Object { $_.FullName.Substring($runtimeDir.Length).TrimStart("\") })
        Report "file $n = $(if ($hits.Count) { $hits -join ',' } else { 'absent' })"
        if ($n -eq "WebView2Loader.dll" -and $hits.Count) {
            $loaderPath = Join-Path $runtimeDir $hits[0]
        }
        if ($n -eq "EmbeddedBrowserWebView.dll" -and $hits.Count) {
            # x64 first: this process is 64-bit on every runner measured, and a
            # loader is not something to pick by whichever the walk saw first.
            $pick = @($hits | Where-Object { $_ -like "*x64*" })
            if (-not $pick.Count) { $pick = $hits }
            $ebwPath = Join-Path $runtimeDir $pick[0]
        }
    }
    $top = @(Get-ChildItem -Path $runtimeDir -File -EA SilentlyContinue | ForEach-Object { $_.Name })
    Report "runtime top-level count=$($top.Count) dlls=$(@($top | Where-Object { $_ -like '*.dll' }).Count)"
    $subs = @(Get-ChildItem -Path $runtimeDir -Directory -EA SilentlyContinue | ForEach-Object { $_.Name })
    Report "runtime subdirs=$(if ($subs.Count) { $subs -join ',' } else { 'none' })"
}
Report "loader path=$(if ($loaderPath) { $loaderPath } else { 'NONE' })"
Report "embedded path=$(if ($ebwPath) { $ebwPath } else { 'NONE' })"

# =====================================================================
Section "exports - what the runtime offers to be called through"
# =====================================================================
#
# Round 2's largest finding: the installed runtime carries no WebView2Loader.dll.
# The loader is an SDK component, so the file the whole design was going to load
# by full path is one of the things only the package has. What the runtime does
# carry is EBWebView\x64\EmbeddedBrowserWebView.dll -- which is what the loader
# loads, and the reason the loader is 150 KB and not 150 MB.
#
# So the entry point is the question. If that DLL exports something an
# environment can be created through, the Evergreen path needs nothing shipped
# and nothing downloaded. If it does not, the design's floor is carrying the
# loader itself, and this stops being "reuse what is installed".
#
# The export table is read here rather than dumped with a tool, because there is
# no dumpbin on a runner and a string search through the file would answer a
# different question -- a name appearing in the bytes is not a name in the
# export directory.

function Get-PEExports($path) {
    $names = @()
    try {
        $b = [IO.File]::ReadAllBytes($path)
    } catch {
        return @("<unreadable: $($_.Exception.GetType().Name)>")
    }
    if ($b.Length -lt 0x40) { return @("<too small>") }
    $peOff = [BitConverter]::ToInt32($b, 0x3C)
    if ($peOff -le 0 -or $peOff + 24 -ge $b.Length) { return @("<no PE header>") }
    if ($b[$peOff] -ne 0x50 -or $b[$peOff + 1] -ne 0x45) { return @("<not PE>") }
    $numSections = [BitConverter]::ToUInt16($b, $peOff + 6)
    $optSize = [BitConverter]::ToUInt16($b, $peOff + 20)
    $optOff = $peOff + 24
    $magic = [BitConverter]::ToUInt16($b, $optOff)
    # PE32+ puts the data directories 16 bytes further along than PE32 does.
    $ddOff = if ($magic -eq 0x20b) { $optOff + 112 } else { $optOff + 96 }
    $expRva = [BitConverter]::ToUInt32($b, $ddOff)
    if ($expRva -eq 0) { return @("<no export directory>") }
    $secOff = $optOff + $optSize

    $sections = @()
    for ($i = 0; $i -lt $numSections; $i++) {
        $so = $secOff + $i * 40
        $sections += [pscustomobject]@{
            VirtualSize    = [BitConverter]::ToUInt32($b, $so + 8)
            VirtualAddress = [BitConverter]::ToUInt32($b, $so + 12)
            RawSize        = [BitConverter]::ToUInt32($b, $so + 16)
            RawAddress     = [BitConverter]::ToUInt32($b, $so + 20)
        }
    }
    $toOff = {
        param($rva)
        foreach ($sec in $sections) {
            $span = [Math]::Max($sec.VirtualSize, $sec.RawSize)
            if ($rva -ge $sec.VirtualAddress -and $rva -lt ($sec.VirtualAddress + $span)) {
                return $sec.RawAddress + ($rva - $sec.VirtualAddress)
            }
        }
        return 0
    }

    $expOff = & $toOff $expRva
    if ($expOff -eq 0 -or $expOff + 40 -ge $b.Length) { return @("<export directory unmapped>") }
    $nameCount = [BitConverter]::ToUInt32($b, $expOff + 24)
    $namesRva = [BitConverter]::ToUInt32($b, $expOff + 32)
    $namesOff = & $toOff $namesRva
    if ($namesOff -eq 0) { return @("<export names unmapped>") }
    for ($i = 0; $i -lt $nameCount; $i++) {
        $strRva = [BitConverter]::ToUInt32($b, $namesOff + $i * 4)
        $strOff = & $toOff $strRva
        if ($strOff -le 0 -or $strOff -ge $b.Length) { continue }
        $end = $strOff
        while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
        $names += [Text.Encoding]::ASCII.GetString($b, $strOff, $end - $strOff)
    }
    return $names
}

$entryDll = ""
$entryName = ""
foreach ($cand in @(@("loader", $loaderPath), @("embedded", $ebwPath))) {
    $label = $cand[0]
    $path = $cand[1]
    if (-not $path) { Report "exports $label absent, nothing to read"; continue }
    $names = @(Get-PEExports $path)
    Report "exports $label $path count=$($names.Count)"
    # The whole list when it is short, and the interesting ones when it is not.
    if ($names.Count -le 40) {
        Report "exports $label all=$($names -join ',')"
    } else {
        $hits = @($names | Where-Object { $_ -match 'WebView|Environment|Compare|Available' })
        Report "exports $label matching=$(if ($hits.Count) { $hits -join ',' } else { 'none' })"
    }
    if (-not $entryName) {
        $create = @($names | Where-Object { $_ -match '^Create.*(WebView|Environment)' })
        if ($create.Count) {
            $entryDll = $path
            $entryName = $create[0]
            Report "exports $label candidate entry point=$entryName"
        }
    }
}
Report "exports entry=$(if ($entryName) { "$entryName in $entryDll" } else { 'NONE' })"

# =====================================================================
Section "managed - is the runtime's Core.dll the wrapper we download?"
# =====================================================================
#
# It has the same file name as the managed assembly the driver loads out of the
# package, and that is the whole reason to ask: if it were the same thing there
# would be nothing left to build. GetAssemblyName throws BadImageFormatException
# on a native image, which is the answer either way.

if ($runtimeDir) {
    $cores = @(Get-ChildItem -Path $runtimeDir -Filter "Microsoft.Web.WebView2.Core.dll" -Recurse -File -EA SilentlyContinue)
    if ($cores.Count -eq 0) {
        Report "managed no Microsoft.Web.WebView2.Core.dll under the runtime"
    }
    foreach ($c in $cores) {
        $verdict = ""
        try {
            $an = [Reflection.AssemblyName]::GetAssemblyName($c.FullName)
            $verdict = "MANAGED $($an.FullName)"
        } catch {
            $verdict = "native ($($_.Exception.GetType().Name))"
        }
        Report "managed $($c.FullName) = $verdict"
    }
} else {
    Report "managed skipped, no runtime directory"
}

# =====================================================================
Section "idl - the IIDs and the vtable order, from the pinned package"
# =====================================================================
#
# Every GUID and every slot index below comes out of the header in the package
# this build already pins. That is the point: a hand-copied IID is a wrong
# QueryInterface at run time and a hand-counted slot is a call into the wrong
# function, and neither says which it was. The package is fetched here, at test
# time, and nothing that ships depends on it -- what would ship is the constants
# this section prints.
#
# The pin is read out of the built artifact rather than out of the repository,
# so this is measuring the same package the driver would.

$artifact = $args[0]
if (-not $artifact) { $artifact = "test\neutrinotest.cmd" }
$pinVersion = ""
$pinSha = ""
if (Test-Path $artifact) {
    $text = Get-Content $artifact -Raw
    $m = [regex]::Match($text, 'webView2PinnedVersion\s*=\s*"([0-9.]+)"')
    if ($m.Success) { $pinVersion = $m.Groups[1].Value }
    $m = [regex]::Match($text, 'webView2PinnedSha256\s*=\s*"([0-9a-f]{64})"')
    if ($m.Success) { $pinSha = $m.Groups[1].Value }
}
Report "pin artifact=$artifact version=$(if($pinVersion){$pinVersion}else{'NONE'})"

$envIid = ""
$envSlots = @()
$iidOf = @{}
$slotsOf = @{}
$handlerIid = ""
$idlFile = Join-Path $work "webview2-idl.txt"

if ($pinVersion) {
    $nupkg = Join-Path $work "webview2.nupkg"
    $url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$pinVersion/microsoft.web.webview2.$pinVersion.nupkg"
    $got = $false
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing
        $got = $true
    } catch {
        Report "idl fetch FAILED $($_.Exception.Message)"
    }
    if ($got) {
        $sha = (Get-FileHash -Path $nupkg -Algorithm SHA256).Hash.ToLower()
        Report "idl fetched bytes=$((Get-Item $nupkg).Length) sha=$($sha.Substring(0,16)) pinned=$(if ($sha -eq $pinSha) { 'YES' } else { 'NO' })"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
        $entry = $zip.GetEntry("build/native/include/WebView2.h")
        if (-not $entry) {
            Report "idl no build/native/include/WebView2.h; entries=$(($zip.Entries | Where-Object { $_.FullName -like '*.h' } | ForEach-Object { $_.FullName }) -join ',')"
        } else {
            $reader = New-Object IO.StreamReader($entry.Open())
            $header = $reader.ReadToEnd()
            $reader.Close()
            $zip.Dispose()
            Report "idl header bytes=$($header.Length)"

            # MIDL_INTERFACE("<guid>") sits immediately above the C++ interface
            # declaration, and the `virtual HRESULT STDMETHODCALLTYPE Name(`
            # lines inside it are the vtable, in order, after IUnknown's three.
            $wanted = @(
                "ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler",
                "ICoreWebView2Environment",
                "ICoreWebView2CreateCoreWebView2ControllerCompletedHandler",
                "ICoreWebView2Controller",
                "ICoreWebView2Controller2",
                "ICoreWebView2",
                "ICoreWebView2Settings",
                "ICoreWebView2WebMessageReceivedEventHandler",
                "ICoreWebView2WebMessageReceivedEventArgs",
                "ICoreWebView2NavigationStartingEventHandler",
                "ICoreWebView2NavigationStartingEventArgs",
                "ICoreWebView2NewWindowRequestedEventHandler",
                "ICoreWebView2NewWindowRequestedEventArgs",
                "ICoreWebView2ContentLoadingEventHandler",
                "ICoreWebView2DocumentTitleChangedEventHandler",
                "ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler",
                "ICoreWebView2ExecuteScriptCompletedHandler"
            )
            $lines = @()
            $found = 0
            foreach ($name in $wanted) {
                $pat = 'MIDL_INTERFACE\("([0-9a-fA-F-]{36})"\)\s*\r?\n\s*' + [regex]::Escape($name) + '\s*:\s*public\s+(\w+)'
                $mi = [regex]::Match($header, $pat)
                if (-not $mi.Success) {
                    $lines += "$name = NOT FOUND"
                    continue
                }
                $found++
                $iid = $mi.Groups[1].Value
                $base = $mi.Groups[2].Value
                # The body runs from the match to the closing brace of the
                # struct; the next MIDL_INTERFACE is a safe bound.
                $start = $mi.Index
                $nextm = [regex]::Match($header.Substring($start + 10), 'MIDL_INTERFACE\(')
                $len = if ($nextm.Success) { $nextm.Index + 10 } else { 4000 }
                if ($start + $len -gt $header.Length) { $len = $header.Length - $start }
                $body = $header.Substring($start, $len)
                # The MIDL annotation sits between `virtual` and `HRESULT`, and
                # round 1's regex did not allow for it -- so every propget and
                # propput was dropped and the slot numbers came out wrong while
                # looking perfectly plausible. ICoreWebView2Settings, which is
                # nothing but properties, reported four interfaces' worth of
                # confidence and zero methods; that is the control below.
                $methods = @([regex]::Matches($body, 'virtual\s+(?:/\*[^*]*\*/\s*)?HRESULT\s+STDMETHODCALLTYPE\s+(\w+)\s*\(') |
                    ForEach-Object { $_.Groups[1].Value })
                $lines += "$name iid=$iid base=$base slots=$($methods.Count) order=$($methods -join ',')"
                $iidOf[$name] = $iid
                $slotsOf[$name] = $methods
                if ($name -eq "ICoreWebView2Environment") {
                    $envIid = $iid
                    $envSlots = $methods
                }
                if ($name -eq "ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler") {
                    $handlerIid = $iid
                }
            }
            $colour = [regex]::Match($header,
                'typedef\s+struct\s+COREWEBVIEW2_COLOR\s*\{(.*?)\}\s*COREWEBVIEW2_COLOR',
                [Text.RegularExpressions.RegexOptions]::Singleline)
            if ($colour.Success) {
                $fields = @([regex]::Matches($colour.Groups[1].Value, '(\w+)\s+(\w+)\s*;') |
                    ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
                $lines += "COREWEBVIEW2_COLOR fields=$($fields -join ',')"
            } else {
                $lines += "COREWEBVIEW2_COLOR = NOT FOUND"
            }
            Set-Content -Path $idlFile -Value ($lines -join "`n") -Encoding UTF8
            foreach ($l in $lines) { Report "idl $l" }
            if ($found -lt 10) {
                Fail "idl parsed only $found of $($wanted.Count) interfaces; the parse, not the header, is the likely fault"
            }
            # An interface made entirely of properties. Zero slots for it means
            # the method regex is dropping accessors, which is a slot count that
            # is wrong everywhere and says so nowhere -- round 1 shipped exactly
            # that, and every vtable order it printed was short.
            $settings = @($lines | Where-Object { $_ -like "ICoreWebView2Settings *" })
            if ($settings.Count -and $settings[0] -match 'slots=0') {
                Fail "idl ICoreWebView2Settings parsed as 0 slots; it is all properties, so the parse is dropping accessors and every order above is short"
            }
        }
    }
} else {
    Report "idl skipped, no pin readable from the artifact"
}

# =====================================================================
Section "dllimport - can jsc.exe declare a native call at all"
# =====================================================================
#
# The one construct the whole design needs and the one nobody can promise:
# JScript.NET has no `extern` modifier, so a P/Invoke has to be a function with
# an attribute and no body, and whether the compiler accepts that is a fact
# about jsc.exe. Four spellings, because the failure of one is not the failure
# of the idea.
#
# Reflection.Emit is the control and also the fallback: DefinePInvokeMethod
# builds the same stub through API calls that need no syntax at all. If that
# fails too, the reading is about this runner and not about jsc.

$styles = @{}

$srcA = @'
import System;
import System.Runtime.InteropServices;
class Native {
    [DllImport("kernel32.dll")]
    static function GetCurrentProcessId() : int;
}
print("pid=" + Native.GetCurrentProcessId());
'@

$srcB = @'
import System;
import System.Runtime.InteropServices;
class Native {
    [DllImport("kernel32.dll")] static function GetCurrentProcessId() : int;
}
print("pid=" + Native.GetCurrentProcessId());
'@

$srcC = @'
import System;
class Native {
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static function GetCurrentProcessId() : int;
}
print("pid=" + Native.GetCurrentProcessId());
'@

$srcD = @'
import System;
import System.Runtime.InteropServices;
class Native {
    [DllImport("kernel32.dll")]
    public static function GetCurrentProcessId() : int;
}
print("pid=" + Native.GetCurrentProcessId());
'@

# The control. Nothing here is syntax: a transient assembly, a type, a stub
# described entirely by arguments. It cannot be refused by the compiler because
# the compiler never sees it.
$srcEmit = @'
import System;
import System.Reflection;
import System.Reflection.Emit;
import System.Runtime.InteropServices;
var an : AssemblyName = new AssemblyName("NeutrinoNative");
var ab : AssemblyBuilder = AppDomain.CurrentDomain.DefineDynamicAssembly(an, AssemblyBuilderAccess.Run);
var mb : ModuleBuilder = ab.DefineDynamicModule("m");
var tb : TypeBuilder = mb.DefineType("Native", TypeAttributes.Public);
var pm : MethodBuilder = tb.DefinePInvokeMethod(
    "GetCurrentProcessId", "kernel32.dll",
    MethodAttributes.Public | MethodAttributes.Static | MethodAttributes.PinvokeImpl,
    CallingConventions.Standard, int, null,
    CallingConvention.Winapi, CharSet.Auto);
pm.SetImplementationFlags(pm.GetMethodImplementationFlags() | MethodImplAttributes.PreserveSig);
var t : Type = tb.CreateType();
print("pid=" + t.GetMethod("GetCurrentProcessId").Invoke(null, null));
'@

# Ordered, because the first spelling that works is the one the driver would
# use and "first" has to mean something.
$cases = [ordered]@{
    "A-own-line"  = $srcA
    "B-same-line" = $srcB
    "C-qualified" = $srcC
    "D-public"    = $srcD
    "E-emit"      = $srcEmit
}
foreach ($label in @($cases.Keys)) {
    $exe = Join-Path $work "dllimport-$label.exe"
    Build-Js "dllimport-$label.js" $cases[$label] $exe @() "exe"
    if (-not $buildOk) {
        Report "dllimport $label build=NO $buildLog"
        $styles[$label] = $false
        continue
    }
    Run-Probe $exe "dllimport-$label" 30000
    $ok = ($runOut -match 'pid=\d+' -and $runCode -eq "0")
    $styles[$label] = $ok
    Report "dllimport $label build=YES run=$runCode out='$runOut' err='$runErr' ok=$ok"
}
if (-not $styles["E-emit"]) {
    Fail "dllimport the Reflection.Emit control did not work; nothing above separates 'jsc cannot' from 'this runner cannot'"
}

$pinvokeStyle = ""
foreach ($k in @("A-own-line", "B-same-line", "C-qualified", "D-public")) {
    if ($styles[$k]) { $pinvokeStyle = $k; break }
}
Report "dllimport usable-attribute-spelling=$(if ($pinvokeStyle) { $pinvokeStyle } else { 'NONE, emit only' })"

# =====================================================================
Section "cominterop - can jsc.exe declare and implement a COM callback"
# =====================================================================
#
# The loader does not call a function pointer, it QueryInterfaces an object for
# ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler and calls Invoke on
# it. That means a real interface with a real IID and a class implementing it,
# and if jsc will not express one the environment can never be created from
# JScript.NET however the P/Invoke is emitted.
#
# Round 1 asked this once, in the spelling C# uses, and got back
# "Variable 'ComImport' has not been declared" for ComImport and
# InterfaceType, and "Type mismatch" for Guid. Those are three different
# errors for one cause: jsc does not appear to do the shorthand that lets
# [Foo] mean FooAttribute, so `ComImport` resolved as a variable and did not
# exist, while `Guid` resolved as System.Guid and was the wrong kind of thing.
# `interface` itself drew no complaint at all, which is the encouraging half.
#
# Round 2 asked in four spellings and all four were refused, but the shape of
# the refusal is the answer. `[ComImportAttribute]` alone drew no error at all
# while `[GuidAttribute("...")]` drew "Type mismatch" at the column the string
# argument starts on -- which is what an array literal holding a *conversion*
# looks like: jsc reads `[X]` as an array of one element, `X("...")` as a cast
# of a String to X, and refuses the cast. So the bracket is not attribute
# syntax here at all; the spelling that "worked" was an array being built and
# discarded. That is why the section below stops asking the compiler.
#
# It is kept because it is the before-state, and because the day jsc is not the
# compiler on the other end of this the reading changes.
#
# `Invoke` returns void on purpose. A ComImport method returning void gets the
# default HRESULT translation, so the CLR hands the caller S_OK when the body
# returns and a failure HRESULT when it throws -- exactly a callback's
# contract, and it avoids needing a [PreserveSig] whose spelling would be one
# more unknown.

$attrSpellings = [ordered]@{
    "1-csharp" = @'
[ComImport]
[Guid("@IID@")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
'@
    "2-suffixed" = @'
[ComImportAttribute]
[GuidAttribute("@IID@")]
[InterfaceTypeAttribute(ComInterfaceType.InterfaceIsIUnknown)]
'@
    "3-qualified" = @'
[System.Runtime.InteropServices.ComImportAttribute]
[System.Runtime.InteropServices.GuidAttribute("@IID@")]
[System.Runtime.InteropServices.InterfaceTypeAttribute(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
'@
    "4-onebracket" = @'
[ComImportAttribute, GuidAttribute("@IID@"), InterfaceTypeAttribute(ComInterfaceType.InterfaceIsIUnknown)]
'@
}

$srcCom = @'
import System;
import System.Reflection;
import System.Runtime.InteropServices;

@ATTRS@interface IEnvHandler {
    function Invoke(errorCode : int, createdEnvironment : Object) : void;
}

class EnvSink implements IEnvHandler {
    static var seen : boolean = false;
    function Invoke(errorCode : int, createdEnvironment : Object) : void {
        EnvSink.seen = true;
    }
}

var sink : EnvSink = new EnvSink();
// The compiler agreeing to this is the first half: a class that does not
// implement the interface will not assign to one.
var asItf : IEnvHandler = sink;
print("assignable=" + (asItf != null));

// And this is the half that cannot be faked. An attribute jsc parsed as an
// expression and threw away leaves a type that compiles and is not a COM
// interface, and IsImport is where the difference shows.
var itf : Type = sink.GetType().GetInterfaces()[0];
print("interface=" + itf.FullName);
print("isimport=" + itf.IsImport);
var found : Object[] = itf.GetCustomAttributes(Type.GetType("System.Runtime.InteropServices.GuidAttribute"), false);
if (found.Length > 0) {
    var v : Object = found[0].GetType().GetProperty("Value").GetValue(found[0], null);
    print("guid=" + v);
} else {
    print("guid=none");
}
var unk : IntPtr = Marshal.GetIUnknownForObject(sink);
print("iunknown=" + (unk != IntPtr.Zero));
Marshal.Release(unk);
'@

$attrStyle = ""
$attrTemplate = ""
if ($handlerIid) {
    foreach ($label in @($attrSpellings.Keys)) {
        $attrs = ($attrSpellings[$label] -replace '@IID@', $handlerIid) + "`n"
        $exe = Join-Path $work "cominterop-$label.exe"
        Build-Js "cominterop-$label.js" ($srcCom -replace '@ATTRS@', $attrs) $exe @() "exe"
        if (-not $buildOk) {
            Report "cominterop $label build=NO $buildLog"
            continue
        }
        Run-Probe $exe "cominterop-$label" 30000
        Report "cominterop $label build=YES run=$runCode out='$runOut' err='$runErr'"
        if (-not $attrStyle -and $runOut -match 'isimport=True' -and $runOut -match [regex]::Escape("guid=$handlerIid")) {
            $attrStyle = $label
            $attrTemplate = $attrSpellings[$label]
        }
    }
} else {
    Report "cominterop skipped, no handler IID from the idl section"
}
Report "cominterop usable-spelling=$(if ($attrStyle) { $attrStyle } else { 'NONE' })"

# =====================================================================
Section "emitted - a COM interface and a callback built without the compiler"
# =====================================================================
#
# Both constructs the design needs are refused by jsc: a P/Invoke has nowhere to
# hang its attribute, and the bracket that would carry ComImport is an array
# literal. Reflection.Emit answers both, and this section is that machinery on
# its own, with no WebView2 anywhere near it -- so a failure here is about the
# technique and a failure in `create` is about the runtime.
#
# An interface has no method bodies, so emitting one costs nothing but the
# attributes; TypeAttributes.Import is the flag ComImportAttribute would have
# set, applied directly. The implementing class is the part that needs IL, and
# it needs four instructions: push both arguments, call a JScript.NET static,
# return. Everything that thinks stays in JScript.NET, which is the point --
# the emitted class is a shim whose whole job is to exist and be callable.
#
# GetComInterfaceForObject is the reading that matters. It is a QueryInterface
# for the emitted IID against the emitted class, which is exactly what the
# loader would do, and it throws rather than lying if the type is not really a
# COM interface.

$srcEmitted = @'
import System;
import System.Reflection;
import System.Reflection.Emit;
import System.Runtime.InteropServices;

// What makeSink hands back. Two typed fields rather than an Object[], so
// nothing downstream has to cast an element back to a Type.
class Sink {
    var itf : Type;
    var obj : Object;
}

class Bridge {
    static var calls : int = 0;
    static var hr : int = -1;
    static var env : Object = null;
    static function OnEnv(errorCode : int, environment : Object) : void {
        Bridge.calls++;
        Bridge.hr = errorCode;
        Bridge.env = environment;
    }
}

var intType : Type = Type.GetType("System.Int32");
var ptrType : Type = Type.GetType("System.IntPtr");
var objType : Type = Type.GetType("System.Object");
var strType : Type = Type.GetType("System.String");

var ab : AssemblyBuilder = AppDomain.CurrentDomain.DefineDynamicAssembly(
    new AssemblyName("NeutrinoCom"), AssemblyBuilderAccess.Run);
var mb : ModuleBuilder = ab.DefineDynamicModule("m");

// tdImport is what ComImportAttribute sets, and it can be asked for directly.
var itb : TypeBuilder = mb.DefineType("IEnvHandler",
    TypeAttributes.Public | TypeAttributes.Interface | TypeAttributes.Abstract | TypeAttributes.Import);

var guidAttrType : Type = Type.GetType("System.Runtime.InteropServices.GuidAttribute");
var guidCtorArgs : Type[] = [strType];
var guidValues : Object[] = ["@HANDLERIID@"];
itb.SetCustomAttribute(new CustomAttributeBuilder(guidAttrType.GetConstructor(guidCtorArgs), guidValues));

var itfAttrType : Type = Type.GetType("System.Runtime.InteropServices.InterfaceTypeAttribute");
var itfCtorArgs : Type[] = [Type.GetType("System.Runtime.InteropServices.ComInterfaceType")];
var itfValues : Object[] = [ComInterfaceType.InterfaceIsIUnknown];
itb.SetCustomAttribute(new CustomAttributeBuilder(itfAttrType.GetConstructor(itfCtorArgs), itfValues));

var invokeArgs : Type[] = [intType, objType];
itb.DefineMethod("Invoke",
    MethodAttributes.Public | MethodAttributes.Virtual | MethodAttributes.Abstract |
    MethodAttributes.HideBySig | MethodAttributes.NewSlot,
    null, invokeArgs);

var ifaceType : Type = itb.CreateType();
print("iface=" + ifaceType.FullName + " isimport=" + ifaceType.IsImport);
var got : Object[] = ifaceType.GetCustomAttributes(guidAttrType, false);
if (got.Length > 0) {
    print("guid=" + got[0].GetType().GetProperty("Value").GetValue(got[0], null));
} else {
    print("guid=none");
}

// The shim. Four instructions, and nothing in it decides anything.
var ctb : TypeBuilder = mb.DefineType("EnvSink", TypeAttributes.Public);
ctb.AddInterfaceImplementation(ifaceType);
var impl : MethodBuilder = ctb.DefineMethod("Invoke",
    MethodAttributes.Public | MethodAttributes.Virtual | MethodAttributes.HideBySig |
    MethodAttributes.NewSlot | MethodAttributes.Final,
    null, invokeArgs);
var bridgeType : Type = (new Bridge()).GetType();
var onEnv : MethodInfo = bridgeType.GetMethod("OnEnv");
print("bridge=" + bridgeType.FullName + " method=" + (onEnv != null));
var il : ILGenerator = impl.GetILGenerator();
il.Emit(OpCodes.Ldarg_1);
il.Emit(OpCodes.Ldarg_2);
il.Emit(OpCodes.Call, onEnv);
il.Emit(OpCodes.Ret);
ctb.DefineMethodOverride(impl, ifaceType.GetMethod("Invoke"));
var sinkType : Type = ctb.CreateType();
print("sink=" + sinkType.FullName);

var sink : Object = Activator.CreateInstance(sinkType);
print("implements=" + ifaceType.IsInstanceOfType(sink));

// Called the managed way first, so a failure below is COM's and not the shim's.
var direct : Object[] = [7, null];
ifaceType.GetMethod("Invoke").Invoke(sink, direct);
print("shim calls=" + Bridge.calls + " hr=" + Bridge.hr);

// And the reading that matters: a QueryInterface for the emitted IID.
var itfPtr : IntPtr = Marshal.GetComInterfaceForObject(sink, ifaceType);
print("queryinterface=" + (itfPtr != IntPtr.Zero));
Marshal.Release(itfPtr);
'@

$emittedOk = $false
if ($handlerIid) {
    $exe = Join-Path $work "emitted.exe"
    Build-Js "emitted.js" ($srcEmitted -replace '@HANDLERIID@', $handlerIid) $exe @() "exe"
    if (-not $buildOk) {
        Fail "emitted build=NO $buildLog"
    } else {
        Run-Probe $exe "emitted" 60000
        Report "emitted build=YES run=$runCode out='$runOut' err='$runErr'"
        if ($runOut -match 'isimport=True' -and $runOut -match 'queryinterface=True' -and $runOut -match 'shim calls=1') {
            $emittedOk = $true
        } else {
            Fail "emitted the technique did not stand up; nothing the driver would need can be built this way"
        }
    }
} else {
    Report "emitted skipped, no handler IID from the idl section"
}
Report "emitted usable=$emittedOk"

# =====================================================================
Section "create - the hypothesis, live and with no package in reach"
# =====================================================================
#
# Everything above, pointed at the runtime. Two emitted interfaces, an emitted
# shim behind the callback, two emitted P/Invoke stubs, and no package on disk.
#
# The entry point is whatever the exports section found. On a machine with the
# SDK's loader that is CreateCoreWebView2EnvironmentWithOptions in
# WebView2Loader.dll; on this runner there is no loader, so it is whatever
# EmbeddedBrowserWebView.dll offers -- and that call is undocumented, which is a
# cost the design has to weigh rather than a detail. Both argument shapes are
# tried, because the internal entry is documented nowhere and the difference
# between them is one leading flag.
#
# The environment interface is generated from the header parse: placeholders
# holding their index up to the slot being called, then get_BrowserVersionString
# itself, whose LPWSTR* out becomes the return under the default HRESULT
# translation.

if (-not $emittedOk) {
    Report "create not attempted: the emitted-interop technique did not stand up above,"
    Report "create so nothing here would be a reading about the runtime."
} elseif (-not $entryName) {
    Fail "create no entry point in either the loader or the runtime's own DLL; the Evergreen path has nothing to call"
} elseif (-not $envIid -or -not $handlerIid) {
    Fail "create no IIDs from the idl section; nothing below would be a reading"
} elseif ($envSlots -notcontains "get_BrowserVersionString") {
    Fail "create the header's ICoreWebView2Environment has no get_BrowserVersionString; slots=$($envSlots -join ',')"
} else {
    # The environment interface, in the header's own order. Placeholders are
    # named for their index and not for the method they stand for: an uncalled
    # slot only has to be in the right place, and the real names are in the idl
    # report above.
    $envDefs = ""
    $slotIndex = 0
    foreach ($slot in $envSlots) {
        if ($slot -eq "get_BrowserVersionString") {
            $envDefs += "// slot $slotIndex after IUnknown: $slot`n"
            $envDefs += "etb.DefineMethod(`"BrowserVersionStringOut`", ABSTRACT, ptrType, noArgs);`n"
            break
        }
        $envDefs += "// slot $slotIndex after IUnknown: $slot`n"
        $envDefs += "etb.DefineMethod(`"slot$slotIndex`", ABSTRACT, null, fourPtrs);`n"
        $slotIndex++
    }

    $srcCreate = @'
import System;
import System.IO;
import System.Reflection;
import System.Reflection.Emit;
import System.Runtime.InteropServices;
import System.Windows.Forms;

// What makeSink hands back. Two typed fields rather than an Object[], so
// nothing downstream has to cast an element back to a Type.
class Sink {
    var itf : Type;
    var obj : Object;
}

class Bridge {
    static var done : boolean = false;
    static var hr : int = -1;
    static var env : Object = null;
    static function OnEnv(errorCode : int, environment : Object) : void {
        Bridge.hr = errorCode;
        Bridge.env = environment;
        Bridge.done = true;
    }
}

print("apartment=" + System.Threading.Thread.CurrentThread.GetApartmentState());

var intType : Type = Type.GetType("System.Int32");
var ptrType : Type = Type.GetType("System.IntPtr");
var objType : Type = Type.GetType("System.Object");
var strType : Type = Type.GetType("System.String");
var boolType : Type = Type.GetType("System.Boolean");
var noArgs : Type[] = new Type[0];
var fourPtrs : Type[] = [ptrType, ptrType, ptrType, ptrType];
var ABSTRACT : MethodAttributes = MethodAttributes.Public | MethodAttributes.Virtual |
    MethodAttributes.Abstract | MethodAttributes.HideBySig | MethodAttributes.NewSlot;

var guidAttrType : Type = Type.GetType("System.Runtime.InteropServices.GuidAttribute");
var guidCtorArgs : Type[] = [strType];
var itfAttrType : Type = Type.GetType("System.Runtime.InteropServices.InterfaceTypeAttribute");
var itfCtorArgs : Type[] = [Type.GetType("System.Runtime.InteropServices.ComInterfaceType")];
var itfValues : Object[] = [ComInterfaceType.InterfaceIsIUnknown];

var ab : AssemblyBuilder = AppDomain.CurrentDomain.DefineDynamicAssembly(
    new AssemblyName("NeutrinoCom"), AssemblyBuilderAccess.Run);
var mb : ModuleBuilder = ab.DefineDynamicModule("m");

// ICoreWebView2Environment.
var etb : TypeBuilder = mb.DefineType("IEnv",
    TypeAttributes.Public | TypeAttributes.Interface | TypeAttributes.Abstract | TypeAttributes.Import);
var envGuid : Object[] = ["@ENVIID@"];
etb.SetCustomAttribute(new CustomAttributeBuilder(guidAttrType.GetConstructor(guidCtorArgs), envGuid));
etb.SetCustomAttribute(new CustomAttributeBuilder(itfAttrType.GetConstructor(itfCtorArgs), itfValues));
@ENVDEFS@var envType : Type = etb.CreateType();
print("envtype=" + envType.FullName + " isimport=" + envType.IsImport);

// The completed handler the entry point QueryInterfaces for.
var htb : TypeBuilder = mb.DefineType("IEnvHandler",
    TypeAttributes.Public | TypeAttributes.Interface | TypeAttributes.Abstract | TypeAttributes.Import);
var hGuid : Object[] = ["@HANDLERIID@"];
htb.SetCustomAttribute(new CustomAttributeBuilder(guidAttrType.GetConstructor(guidCtorArgs), hGuid));
htb.SetCustomAttribute(new CustomAttributeBuilder(itfAttrType.GetConstructor(itfCtorArgs), itfValues));
var invokeArgs : Type[] = [intType, envType];
htb.DefineMethod("Invoke", ABSTRACT, null, invokeArgs);
var handlerType : Type = htb.CreateType();
print("handlertype=" + handlerType.FullName + " isimport=" + handlerType.IsImport);

// The shim behind it: push both arguments, call the bridge, return.
var ctb : TypeBuilder = mb.DefineType("EnvSink", TypeAttributes.Public);
ctb.AddInterfaceImplementation(handlerType);
var impl : MethodBuilder = ctb.DefineMethod("Invoke",
    MethodAttributes.Public | MethodAttributes.Virtual | MethodAttributes.HideBySig |
    MethodAttributes.NewSlot | MethodAttributes.Final,
    null, invokeArgs);
var onEnv : MethodInfo = (new Bridge()).GetType().GetMethod("OnEnv");
var il : ILGenerator = impl.GetILGenerator();
il.Emit(OpCodes.Ldarg_1);
il.Emit(OpCodes.Ldarg_2);
il.Emit(OpCodes.Call, onEnv);
il.Emit(OpCodes.Ret);
ctb.DefineMethodOverride(impl, handlerType.GetMethod("Invoke"));
var sinkType : Type = ctb.CreateType();
var sink : Object = Activator.CreateInstance(sinkType);
print("sink=" + handlerType.IsInstanceOfType(sink));

// The stubs. LoadLibraryW first so the entry point resolves against a module
// already loaded from the path this program chose.
var ntb : TypeBuilder = mb.DefineType("N", TypeAttributes.Public);
var PINV : MethodAttributes = MethodAttributes.Public | MethodAttributes.Static | MethodAttributes.PinvokeImpl;
var loadArgTypes : Type[] = [ptrType];
var m1 : MethodBuilder = ntb.DefinePInvokeMethod("LoadLibraryW", "kernel32.dll", "LoadLibraryW",
    PINV, CallingConventions.Standard, ptrType, loadArgTypes,
    CallingConvention.Winapi, CharSet.Auto);
m1.SetImplementationFlags(m1.GetMethodImplementationFlags() | MethodImplAttributes.PreserveSig);

// Two shapes, because the entry point may be the documented one or the
// runtime's own, and the difference between them is one leading flag.
var plainTypes : Type[] = [ptrType, ptrType, ptrType, handlerType];
var m2 : MethodBuilder = ntb.DefinePInvokeMethod("CreatePlain", "@ENTRYDLL@", "@ENTRYNAME@",
    PINV, CallingConventions.Standard, intType, plainTypes,
    CallingConvention.Winapi, CharSet.Auto);
m2.SetImplementationFlags(m2.GetMethodImplementationFlags() | MethodImplAttributes.PreserveSig);

var flaggedTypes : Type[] = [boolType, ptrType, ptrType, ptrType, handlerType];
var m3 : MethodBuilder = ntb.DefinePInvokeMethod("CreateFlagged", "@ENTRYDLL@", "@ENTRYNAME@",
    PINV, CallingConventions.Standard, intType, flaggedTypes,
    CallingConvention.Winapi, CharSet.Auto);
m3.SetImplementationFlags(m3.GetMethodImplementationFlags() | MethodImplAttributes.PreserveSig);

var nat : Type = ntb.CreateType();

var loaderStr : IntPtr = Marshal.StringToCoTaskMemUni("@ENTRYPATH@");
var loadArgs : Object[] = [loaderStr];
var modObj : Object = nat.GetMethod("LoadLibraryW").Invoke(null, loadArgs);
Marshal.FreeCoTaskMem(loaderStr);
var loaded : boolean = (String(modObj) != "0" && String(modObj) != "");
print("loadlibrary=" + loaded + " handle=" + modObj);

if (!loaded) {
    print("create=NO could not load @ENTRYPATH@");
} else {
    var udf : IntPtr = Marshal.StringToCoTaskMemUni("@UDF@");
    var shapes : String[] = ["CreatePlain", "CreateFlagged"];
    for (var si : int = 0; si < shapes.Length && !Bridge.done; si++) {
        var callArgs : Object[];
        if (shapes[si] == "CreatePlain") {
            callArgs = [IntPtr.Zero, udf, IntPtr.Zero, sink];
        } else {
            callArgs = [true, IntPtr.Zero, udf, IntPtr.Zero, sink];
        }
        var hrObj : Object = null;
        try {
            hrObj = nat.GetMethod(shapes[si]).Invoke(null, callArgs);
            print("call " + shapes[si] + " hr=" + hrObj);
        } catch (e) {
            print("call " + shapes[si] + " threw " + e);
            continue;
        }
        var spins : int = 0;
        while (!Bridge.done && spins < 3000) {
            Application.DoEvents();
            System.Threading.Thread.Sleep(16);
            spins++;
        }
        print("callback " + shapes[si] + " done=" + Bridge.done + " hr=" + Bridge.hr + " spins=" + spins);
    }
    print("environment=" + (Bridge.env != null));
    if (Bridge.env != null) {
        // Typed on the way out of Invoke rather than cast afterwards: IntPtr
        // has no Parse to go back through a string with, and the boxed value
        // is already the right type.
        var pv : IntPtr = envType.GetMethod("BrowserVersionStringOut").Invoke(Bridge.env, null);
        print("versionptr=" + pv);
        if (pv != IntPtr.Zero) {
            print("version=" + Marshal.PtrToStringUni(pv));
            Marshal.FreeCoTaskMem(pv);
        }
    }
    Marshal.FreeCoTaskMem(udf);
}
'@

    $udf = (Join-Path $work "userdata").Replace("\", "\\")
    $srcCreate = $srcCreate.Replace("@ENVIID@", $envIid).Replace("@HANDLERIID@", $handlerIid)
    $srcCreate = $srcCreate.Replace("@ENVDEFS@", $envDefs)
    $srcCreate = $srcCreate.Replace("@ENTRYDLL@", [IO.Path]::GetFileName($entryDll))
    $srcCreate = $srcCreate.Replace("@ENTRYNAME@", $entryName)
    $srcCreate = $srcCreate.Replace("@ENTRYPATH@", $entryDll.Replace("\", "\\"))
    $srcCreate = $srcCreate.Replace("@UDF@", $udf)
    Set-Content -Path (Join-Path $work "create-source.js") -Value $srcCreate -Encoding ASCII

    $exe = Join-Path $work "create.exe"
    Build-Js "create.js" $srcCreate $exe @("System.Windows.Forms.dll", "System.Drawing.dll") "exe"
    if (-not $buildOk) {
        Fail "create build=NO $buildLog"
        Report "create source kept at $work\create-source.js"
    } else {
        Run-Probe $exe "create" 180000
        Report "create build=YES run=$runCode out='$runOut' err='$runErr'"
        if ($runOut -notmatch 'environment=True') {
            Fail "create no environment came back; the Evergreen path does not stand up as written"
        } elseif ($runOut -notmatch 'version=\d') {
            Fail "create an environment came back but would not name a version; S_OK with nothing behind it is what a wrong vtable slot returns"
        } else {
            Report "create the runtime answered without a package anywhere on disk"
        }
    }
}

# =====================================================================
Section "drive - a window, a document, and a message back from the page"
# =====================================================================
#
# `create` proved the environment. Everything the driver actually does is on the
# other side of a controller, and three things there are unlike anything proved
# so far: a second completion handler, a struct passed by value, and an event
# whose argument is an interface the handler has to call back into. If those
# work the rest of the driver is transcription; if one does not, the design
# changes again, and finding that out here costs a step rather than a rewrite.
#
# One rule makes the codegen tractable: every interface pointer and every string
# in these signatures is an IntPtr. The marshaller is then never asked to guess
# -- no BSTR-or-LPWStr question on a string, no [in] interface to get right --
# and, more usefully, no emitted interface refers to another, so they can be
# built in any order. What that costs is doing the QueryInterface and the
# PtrToStringUni by hand, which is a line each.
#
# RECT is the exception and has to be a real type, because a 16-byte struct is
# not passed the way a pointer is and getting that wrong is a crash rather than
# an error. It is emitted with SequentialLayout and four int fields.
#
# The page is the reading. It is navigated to as a string, and the only thing it
# does is postMessage -- so a message arriving means NavigateToString ran, the
# subscription took, the event args interface answered, and the channel this
# driver's whole API rides on is open.
#
# It shows a window, which nothing else in this file does. It is bounded twice:
# the program exits itself when it has its answer or its own patience runs out,
# and Run-Probe kills it either way.

# The signatures that have to be right. Everything not named here becomes a
# placeholder holding its index -- an uncalled slot only has to be in the right
# place. `ret` and `args` are JScript.NET expressions, evaluated in the
# generated program where ptrType and friends are in scope.
$sigs = @{
    "ICoreWebView2Environment.CreateCoreWebView2Controller"                = @{ ret = "null";     args = "twoPtrs" }
    "ICoreWebView2Environment.get_BrowserVersionString"                    = @{ ret = "ptrType";  args = "noArgs" }
    "ICoreWebView2Controller.put_IsVisible"                                = @{ ret = "null";     args = "oneInt" }
    "ICoreWebView2Controller.put_Bounds"                                   = @{ ret = "null";     args = "oneRect" }
    "ICoreWebView2Controller.get_CoreWebView2"                             = @{ ret = "ptrType";  args = "noArgs" }
    "ICoreWebView2Controller2.put_DefaultBackgroundColor"                  = @{ ret = "v";        args = "oneColour" }
    "ICoreWebView2.NavigateToString"                                       = @{ ret = "null";     args = "onePtr" }
    "ICoreWebView2.add_WebMessageReceived"                                 = @{ ret = "longType"; args = "onePtr" }
    "ICoreWebView2.AddScriptToExecuteOnDocumentCreated"                    = @{ ret = "v";        args = "twoPtrs" }
    "ICoreWebView2.get_DocumentTitle"                                      = @{ ret = "ptrType";  args = "noArgs" }
    "ICoreWebView2.get_Source"                                             = @{ ret = "ptrType";  args = "noArgs" }
    "ICoreWebView2WebMessageReceivedEventArgs.get_Source"                  = @{ ret = "ptrType";  args = "noArgs" }
    "ICoreWebView2WebMessageReceivedEventArgs.TryGetWebMessageAsString"    = @{ ret = "ptrType";  args = "noArgs" }
}

# One emitted interface, from the header's own order.
function New-InterfaceSource($varName, $jsName, $ifaceName, $baseName) {
    $iid = $script:iidOf[$ifaceName]
    # COM single inheritance: a derived interface's vtable is the base's
    # followed by its own, so the base's methods have to occupy their indices
    # here or every slot after them is off by however many were left out.
    $slots = @()
    if ($baseName) { $slots += @($script:slotsOf[$baseName]) }
    $slots += @($script:slotsOf[$ifaceName])
    $out = "// $ifaceName$(if ($baseName) { " : $baseName" })`n"
    $out += "var $varName : TypeBuilder = defineInterface(mb, `"$jsName`", `"$iid`");`n"
    $i = 0
    foreach ($slot in $slots) {
        $key = "$ifaceName.$slot"
        if (-not $script:sigs.ContainsKey($key) -and $baseName) {
            $key = "$baseName.$slot"
        }
        if ($script:sigs.ContainsKey($key)) {
            $sig = $script:sigs[$key]
            $ret = $sig.ret
            if ($ret -eq "v") { $ret = "null" }
            $out += "$varName.DefineMethod(`"$slot`", ABSTRACT, $ret, $($sig.args)); // slot $i`n"
        } else {
            $out += "$varName.DefineMethod(`"slot$i`", ABSTRACT, null, fourPtrs); // $slot`n"
        }
        $i++
    }
    return $out
}

$driveNeeds = @("ICoreWebView2Environment", "ICoreWebView2Controller",
                "ICoreWebView2Controller2", "ICoreWebView2",
                "ICoreWebView2WebMessageReceivedEventArgs",
                "ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler",
                "ICoreWebView2CreateCoreWebView2ControllerCompletedHandler",
                "ICoreWebView2WebMessageReceivedEventHandler")
$missing = @($driveNeeds | Where-Object { -not $slotsOf.ContainsKey($_) -or -not @($slotsOf[$_]).Count })

if (-not $emittedOk) {
    Report "drive not attempted: the emitted-interop technique did not stand up."
} elseif (-not $entryName) {
    Report "drive not attempted: no entry point, same as create."
} elseif ($missing.Count) {
    Fail "drive the header parse gave nothing for $($missing -join ','); nothing below would be a reading"
} else {
    $ifaceSrc = ""
    $ifaceSrc += New-InterfaceSource "tbEnv" "IEnv" "ICoreWebView2Environment"
    $ifaceSrc += New-InterfaceSource "tbCtl" "ICtl" "ICoreWebView2Controller"
    $ifaceSrc += New-InterfaceSource "tbWeb" "IWeb" "ICoreWebView2"
    $ifaceSrc += New-InterfaceSource "tbArgs" "IMsgArgs" "ICoreWebView2WebMessageReceivedEventArgs"
    $ifaceSrc += New-InterfaceSource "tbCtl2" "ICtl2" "ICoreWebView2Controller2" "ICoreWebView2Controller"

    $srcDrive = @'
import System;
import System.Collections;
import System.Drawing;
import System.Reflection;
import System.Reflection.Emit;
import System.Runtime.InteropServices;
import System.Windows.Forms;

// Everything the emitted shims call back into. A .NET static is the only thing
// IL four instructions long can reach, and it is also the only thing on this
// side of the file that can be written to from a callback.
// What makeSink hands back. Two typed fields rather than an Object[], so
// nothing downstream has to cast an element back to a Type.
class Sink {
    var itf : Type;
    var obj : Object;
}

class Bridge {
    static var envDone : boolean = false;
    static var envHr : int = -1;
    static var env : IntPtr = IntPtr.Zero;
    static var ctlDone : boolean = false;
    static var ctlHr : int = -1;
    static var ctl : IntPtr = IntPtr.Zero;
    static var argsType : Type = null;
    static var messages : ArrayList = new ArrayList();
    static var failures : ArrayList = new ArrayList();

    static function OnEnv(errorCode : int, environment : IntPtr) : void {
        Bridge.envHr = errorCode;
        // The pointer outlives the call only if this holds a reference to it,
        // and an IntPtr parameter is one the marshaller did not count.
        if (environment != IntPtr.Zero) { Marshal.AddRef(environment); }
        Bridge.env = environment;
        Bridge.envDone = true;
    }

    static function OnController(errorCode : int, controller : IntPtr) : void {
        Bridge.ctlHr = errorCode;
        if (controller != IntPtr.Zero) { Marshal.AddRef(controller); }
        Bridge.ctl = controller;
        Bridge.ctlDone = true;
    }

    // The args object is alive for the duration of this call and no longer, so
    // the string is taken here rather than queued for the loop.
    static var scriptAdded : int = -1;
    static function OnScriptAdded(errorCode : int, id : IntPtr) : void {
        Bridge.scriptAdded = errorCode;
    }

    static function OnMessage(sender : IntPtr, args : IntPtr) : void {
        try {
            var o : Object = Marshal.GetTypedObjectForIUnknown(args, Bridge.argsType);
            var p : IntPtr = Bridge.argsType.GetMethod("TryGetWebMessageAsString").Invoke(o, null);
            if (p != IntPtr.Zero) {
                Bridge.messages.Add(Marshal.PtrToStringUni(p));
                Marshal.FreeCoTaskMem(p);
            } else {
                Bridge.messages.Add("<null>");
            }
        } catch (e) {
            Bridge.failures.Add("OnMessage: " + e);
        }
    }
}

var intType : Type = Type.GetType("System.Int32");
var longType : Type = Type.GetType("System.Int64");
var ptrType : Type = Type.GetType("System.IntPtr");
var strType : Type = Type.GetType("System.String");
var boolType : Type = Type.GetType("System.Boolean");
var noArgs : Type[] = new Type[0];
var onePtr : Type[] = [ptrType];
var twoPtrs : Type[] = [ptrType, ptrType];
var fourPtrs : Type[] = [ptrType, ptrType, ptrType, ptrType];
var oneInt : Type[] = [intType];
var ABSTRACT : MethodAttributes = MethodAttributes.Public | MethodAttributes.Virtual |
    MethodAttributes.Abstract | MethodAttributes.HideBySig | MethodAttributes.NewSlot;
var IMPL : MethodAttributes = MethodAttributes.Public | MethodAttributes.Virtual |
    MethodAttributes.HideBySig | MethodAttributes.NewSlot | MethodAttributes.Final;
var PINV : MethodAttributes = MethodAttributes.Public | MethodAttributes.Static |
    MethodAttributes.PinvokeImpl;

var guidAttrType : Type = Type.GetType("System.Runtime.InteropServices.GuidAttribute");
var guidCtorArgs : Type[] = [strType];
var itfAttrType : Type = Type.GetType("System.Runtime.InteropServices.InterfaceTypeAttribute");
var itfCtorArgs : Type[] = [Type.GetType("System.Runtime.InteropServices.ComInterfaceType")];
var itfValues : Object[] = [ComInterfaceType.InterfaceIsIUnknown];

var ab : AssemblyBuilder = AppDomain.CurrentDomain.DefineDynamicAssembly(
    new AssemblyName("NeutrinoCom"), AssemblyBuilderAccess.Run);
var mb : ModuleBuilder = ab.DefineDynamicModule("m");

function defineInterface(m : ModuleBuilder, name : String, iid : String) : TypeBuilder {
    var tb : TypeBuilder = m.DefineType(name,
        TypeAttributes.Public | TypeAttributes.Interface | TypeAttributes.Abstract | TypeAttributes.Import);
    var g : Object[] = [iid];
    tb.SetCustomAttribute(new CustomAttributeBuilder(guidAttrType.GetConstructor(guidCtorArgs), g));
    tb.SetCustomAttribute(new CustomAttributeBuilder(itfAttrType.GetConstructor(itfCtorArgs), itfValues));
    return tb;
}

// A 16-byte struct is not passed the way a pointer is, so this one is real.
var rtb : TypeBuilder = mb.DefineType("RECT",
    TypeAttributes.Public | TypeAttributes.SequentialLayout | TypeAttributes.Sealed,
    Type.GetType("System.ValueType"));
rtb.DefineField("left", intType, FieldAttributes.Public);
rtb.DefineField("top", intType, FieldAttributes.Public);
rtb.DefineField("right", intType, FieldAttributes.Public);
rtb.DefineField("bottom", intType, FieldAttributes.Public);
var rectType : Type = rtb.CreateType();
var oneRect : Type[] = [rectType];
print("rect=" + rectType.FullName + " size=" + Marshal.SizeOf(rectType));

// COREWEBVIEW2_COLOR, the second thing here that is not pointer-shaped. Four
// bytes by value: small enough that getting the layout wrong is not obviously
// a crash and is still not a colour.
var byteType : Type = Type.GetType("System.Byte");
var ctb2 : TypeBuilder = mb.DefineType("COLOR",
    TypeAttributes.Public | TypeAttributes.SequentialLayout | TypeAttributes.Sealed,
    Type.GetType("System.ValueType"));
ctb2.DefineField("A", byteType, FieldAttributes.Public);
ctb2.DefineField("R", byteType, FieldAttributes.Public);
ctb2.DefineField("G", byteType, FieldAttributes.Public);
ctb2.DefineField("B", byteType, FieldAttributes.Public);
var colourType : Type = ctb2.CreateType();
var oneColour : Type[] = [colourType];
print("colour=" + colourType.FullName + " size=" + Marshal.SizeOf(colourType));

@IFACES@
var envType : Type = tbEnv.CreateType();
var ctlType : Type = tbCtl.CreateType();
var webType : Type = tbWeb.CreateType();
var argsType : Type = tbArgs.CreateType();
var ctl2Type : Type = tbCtl2.CreateType();
Bridge.argsType = argsType;
print("interfaces=" + envType.IsImport + "," + ctlType.IsImport + "," + webType.IsImport + "," + argsType.IsImport);

// The three callbacks. Each is an emitted interface with one method and an
// emitted class whose body is push, push, call, return.
function makeSink(m : ModuleBuilder, iid : String, iname : String, cname : String,
                  argTypes : Type[], target : MethodInfo) : Sink {
    var itb : TypeBuilder = defineInterface(m, iname, iid);
    itb.DefineMethod("Invoke", ABSTRACT, null, argTypes);
    var itype : Type = itb.CreateType();
    var ctb : TypeBuilder = m.DefineType(cname, TypeAttributes.Public);
    ctb.AddInterfaceImplementation(itype);
    var impl : MethodBuilder = ctb.DefineMethod("Invoke", IMPL, null, argTypes);
    var il : ILGenerator = impl.GetILGenerator();
    il.Emit(OpCodes.Ldarg_1);
    il.Emit(OpCodes.Ldarg_2);
    il.Emit(OpCodes.Call, target);
    il.Emit(OpCodes.Ret);
    ctb.DefineMethodOverride(impl, itype.GetMethod("Invoke"));
    var ctype : Type = ctb.CreateType();
    var made : Sink = new Sink();
    made.itf = itype;
    made.obj = Activator.CreateInstance(ctype);
    return made;
}

var bridgeType : Type = (new Bridge()).GetType();
var intAndPtr : Type[] = [intType, ptrType];
var envSink : Sink = makeSink(mb, "@ENVHANDLERIID@", "IEnvSinkItf", "EnvSink",
    intAndPtr, bridgeType.GetMethod("OnEnv"));
var ctlSink : Sink = makeSink(mb, "@CTLHANDLERIID@", "ICtlSinkItf", "CtlSink",
    intAndPtr, bridgeType.GetMethod("OnController"));
var msgSink : Sink = makeSink(mb, "@MSGHANDLERIID@", "IMsgSinkItf", "MsgSink",
    twoPtrs, bridgeType.GetMethod("OnMessage"));
print("sinks=" + (envSink.obj != null) + "," + (ctlSink.obj != null) + "," + (msgSink.obj != null));

// The entry point, in the shape create measured.
var ntb : TypeBuilder = mb.DefineType("N", TypeAttributes.Public);
var loadArgTypes : Type[] = [ptrType];
var m1 : MethodBuilder = ntb.DefinePInvokeMethod("LoadLibraryW", "kernel32.dll", "LoadLibraryW",
    PINV, CallingConventions.Standard, ptrType, loadArgTypes, CallingConvention.Winapi, CharSet.Auto);
m1.SetImplementationFlags(m1.GetMethodImplementationFlags() | MethodImplAttributes.PreserveSig);
var createTypes : Type[] = [boolType, ptrType, ptrType, ptrType, envSink.itf];
var m2 : MethodBuilder = ntb.DefinePInvokeMethod("Create", "@ENTRYDLL@", "@ENTRYNAME@",
    PINV, CallingConventions.Standard, intType, createTypes, CallingConvention.Winapi, CharSet.Auto);
m2.SetImplementationFlags(m2.GetMethodImplementationFlags() | MethodImplAttributes.PreserveSig);
var nat : Type = ntb.CreateType();

var pathPtr : IntPtr = Marshal.StringToCoTaskMemUni("@ENTRYPATH@");
var loadArgs : Object[] = [pathPtr];
var modObj : Object = nat.GetMethod("LoadLibraryW").Invoke(null, loadArgs);
Marshal.FreeCoTaskMem(pathPtr);
print("loadlibrary=" + (String(modObj) != "0"));

var form : Form = new Form();
form.Text = "EVERGREEN-PROBE";
form.ClientSize = new Size(480, 320);
form.StartPosition = FormStartPosition.CenterScreen;
form.Show();
var hwnd : IntPtr = form.Handle;
print("window=" + (hwnd != IntPtr.Zero));

function pumpUntil(what : String, ms : int) : void {
    var spins : int = ms / 16;
    for (var i : int = 0; i < spins; i++) {
        if (what == "env" && Bridge.envDone) { return; }
        if (what == "ctl" && Bridge.ctlDone) { return; }
        if (what == "msg" && Bridge.messages.Count > 0) { return; }
        Application.DoEvents();
        System.Threading.Thread.Sleep(16);
    }
}

var udf : IntPtr = Marshal.StringToCoTaskMemUni("@UDF@");
var createArgs : Object[] = [true, IntPtr.Zero, udf, IntPtr.Zero, envSink.obj];
var hr : Object = nat.GetMethod("Create").Invoke(null, createArgs);
print("create hr=" + hr);
pumpUntil("env", 48000);
print("env done=" + Bridge.envDone + " hr=" + Bridge.envHr + " ptr=" + (Bridge.env != IntPtr.Zero));

if (Bridge.env == IntPtr.Zero) {
    print("drive=NO no environment");
} else {
    var envObj : Object = Marshal.GetTypedObjectForIUnknown(Bridge.env, envType);
    var version : IntPtr = envType.GetMethod("get_BrowserVersionString").Invoke(envObj, null);
    print("version=" + Marshal.PtrToStringUni(version));
    Marshal.FreeCoTaskMem(version);

    // The controller handler goes in as a pointer, which is the rule this
    // program follows everywhere: nothing is asked of the marshaller that a
    // QueryInterface here cannot answer for.
    var ctlSinkPtr : IntPtr = Marshal.GetComInterfaceForObject(ctlSink.obj, ctlSink.itf);
    var ctlArgs : Object[] = [hwnd, ctlSinkPtr];
    envType.GetMethod("CreateCoreWebView2Controller").Invoke(envObj, ctlArgs);
    pumpUntil("ctl", 60000);
    print("controller done=" + Bridge.ctlDone + " hr=" + Bridge.ctlHr + " ptr=" + (Bridge.ctl != IntPtr.Zero));

    if (Bridge.ctl == IntPtr.Zero) {
        print("drive=NO no controller");
    } else {
        var ctlObj : Object = Marshal.GetTypedObjectForIUnknown(Bridge.ctl, ctlType);

        var zero : int = 0;
        var wide : int = 480;
        var tall : int = 320;
        var rect : Object = Activator.CreateInstance(rectType);
        rectType.GetField("left").SetValue(rect, zero);
        rectType.GetField("top").SetValue(rect, zero);
        rectType.GetField("right").SetValue(rect, wide);
        rectType.GetField("bottom").SetValue(rect, tall);
        var boundsArgs : Object[] = [rect];
        try {
            ctlType.GetMethod("put_Bounds").Invoke(ctlObj, boundsArgs);
            print("bounds=ok");
        } catch (eb) {
            print("bounds=THREW " + eb);
        }
        var visible : int = 1;
        var visArgs : Object[] = [visible];
        try {
            ctlType.GetMethod("put_IsVisible").Invoke(ctlObj, visArgs);
            print("visible=ok");
        } catch (ev) {
            print("visible=THREW " + ev);
        }

        // The background the view paints before it has anything to paint, which
        // is the flash this driver spends so much effort not having. It is on
        // ICoreWebView2Controller2, a separate interface with its own IID, so a
        // runtime too old to have it refuses the QueryInterface and that is the
        // whole of the failure -- which is why this is tried and reported
        // rather than assumed.
        try {
            var ctl2Obj : Object = Marshal.GetTypedObjectForIUnknown(Bridge.ctl, ctl2Type);
            var colour : Object = Activator.CreateInstance(colourType);
            // Through Convert rather than a typed local: a JScript.NET number
            // literal boxes as Double, and Double to Byte is a narrowing the
            // reflection binder will not do for you.
            colourType.GetField("A").SetValue(colour, Convert.ToByte(255));
            colourType.GetField("R").SetValue(colour, Convert.ToByte(32));
            colourType.GetField("G").SetValue(colour, Convert.ToByte(32));
            colourType.GetField("B").SetValue(colour, Convert.ToByte(32));
            var colourArgs : Object[] = [colour];
            ctl2Type.GetMethod("put_DefaultBackgroundColor").Invoke(ctl2Obj, colourArgs);
            print("background=ok");
        } catch (ec) {
            print("background=THREW " + ec);
        }

        var webPtr : IntPtr = ctlType.GetMethod("get_CoreWebView2").Invoke(ctlObj, null);
        print("webview=" + (webPtr != IntPtr.Zero));
        if (webPtr != IntPtr.Zero) {
            var webObj : Object = Marshal.GetTypedObjectForIUnknown(webPtr, webType);

            var msgSinkPtr : IntPtr = Marshal.GetComInterfaceForObject(msgSink.obj, msgSink.itf);
            var subArgs : Object[] = [msgSinkPtr];
            var token : Object = webType.GetMethod("add_WebMessageReceived").Invoke(webObj, subArgs);
            print("subscribed token=" + token);

            var addSink : Sink = makeSink(mb, "@ADDSCRIPTIID@", "IAddSinkItf", "AddSink",
                intAndPtr, bridgeType.GetMethod("OnScriptAdded"));
            var addSinkPtr : IntPtr = Marshal.GetComInterfaceForObject(addSink.obj, addSink.itf);
            var preload : IntPtr = Marshal.StringToCoTaskMemUni(
                "window.chrome.webview.postMessage('from-preload');");
            var addArgs : Object[] = [preload, addSinkPtr];
            try {
                webType.GetMethod("AddScriptToExecuteOnDocumentCreated").Invoke(webObj, addArgs);
                print("addscript=ok");
            } catch (ea) {
                print("addscript=THREW " + ea);
            }
            Marshal.FreeCoTaskMem(preload);

            var page : String = "<!doctype html><meta charset=utf-8><title>EVERGREEN</title>" +
                "<script>window.chrome.webview.postMessage('hello-from-page');</scr" + "ipt>";
            var pagePtr : IntPtr = Marshal.StringToCoTaskMemUni(page);
            var navArgs : Object[] = [pagePtr];
            webType.GetMethod("NavigateToString").Invoke(webObj, navArgs);
            print("navigated=ok");
            pumpUntil("msg", 60000);
            Marshal.FreeCoTaskMem(pagePtr);

            print("scriptAdded=" + Bridge.scriptAdded);
            print("messages=" + Bridge.messages.Count);
            for (var mi : int = 0; mi < Bridge.messages.Count; mi++) {
                print("message[" + mi + "]=" + Bridge.messages[mi]);
            }
            var title : IntPtr = webType.GetMethod("get_DocumentTitle").Invoke(webObj, null);
            print("title=" + Marshal.PtrToStringUni(title));
            Marshal.FreeCoTaskMem(title);

            // What the view says it is showing, which the driver's trust gate
            // is built on. On the managed path Source stays about:blank for the
            // life of the view while the navigation event reports the data: url
            // -- remembering one and comparing the other is a guard that can
            // never pass, and it shipped once and took every title on the lane
            // with it. So this is asked before that gate is written against it
            // rather than after.
            var src : IntPtr = webType.GetMethod("get_Source").Invoke(webObj, null);
            print("source=" + Marshal.PtrToStringUni(src));
            Marshal.FreeCoTaskMem(src);
        }
    }
}
for (var fi : int = 0; fi < Bridge.failures.Count; fi++) {
    print("failure=" + Bridge.failures[fi]);
}
Marshal.FreeCoTaskMem(udf);
form.Hide();
form.Close();
// Nothing here is allowed to outlive its step.
Environment.Exit(0);
'@

    $udf2 = (Join-Path $work "userdata-drive").Replace("\", "\\")
    $srcDrive = $srcDrive.Replace("@IFACES@", $ifaceSrc)
    $srcDrive = $srcDrive.Replace("@ENVHANDLERIID@", $iidOf["ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler"])
    $srcDrive = $srcDrive.Replace("@CTLHANDLERIID@", $iidOf["ICoreWebView2CreateCoreWebView2ControllerCompletedHandler"])
    $srcDrive = $srcDrive.Replace("@MSGHANDLERIID@", $iidOf["ICoreWebView2WebMessageReceivedEventHandler"])
    $srcDrive = $srcDrive.Replace("@ADDSCRIPTIID@", $iidOf["ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler"])
    $srcDrive = $srcDrive.Replace("@ENTRYDLL@", [IO.Path]::GetFileName($entryDll))
    $srcDrive = $srcDrive.Replace("@ENTRYNAME@", $entryName)
    $srcDrive = $srcDrive.Replace("@ENTRYPATH@", $entryDll.Replace("\", "\\"))
    $srcDrive = $srcDrive.Replace("@UDF@", $udf2)
    Set-Content -Path (Join-Path $work "drive-source.js") -Value $srcDrive -Encoding ASCII

    $exe = Join-Path $work "drive.exe"
    # The launcher's own reference list, not a shorter one. `winexe` plus two
    # references got JS1259 -- a referenced assembly depending on one that is
    # not referenced -- and JS1135 on `print`, which is the JScript.NET global
    # going missing behind it rather than a second fault. The shipped artifact
    # names these five and compiles, so they are what a program using this much
    # of Windows Forms needs; `exe` because `print` is what every other section
    # here reports through and a console target is where it is known to work.
    # A console subsystem does not stop a Form from opening.
    Build-Js "drive.js" $srcDrive $exe @("mscorlib.dll", "System.dll", "System.Configuration.dll", "Accessibility.dll", "System.Drawing.dll", "System.Windows.Forms.dll") "exe"
    if (-not $buildOk) {
        Fail "drive build=NO $buildLog"
        Report "drive source kept at $work\drive-source.js"
    } else {
        Run-Probe $exe "drive" 240000
        Report "drive build=YES run=$runCode out='$runOut' err='$runErr'"
        if ($runOut -notmatch 'controller done=True') {
            Fail "drive no controller; a window is where this driver lives and it cannot get one"
        } elseif ($runOut -notmatch 'bounds=ok') {
            Fail "drive put_Bounds did not take; a struct passed by value is the one signature here that cannot be an IntPtr"
        } elseif ($runOut -notmatch 'hello-from-page') {
            Fail "drive the page's message never arrived; the channel the whole API rides on is not open"
        } elseif ($runOut -notmatch 'background=ok') {
            Fail "drive put_DefaultBackgroundColor did not take; this lane paints white behind a dark app"
        } elseif ($runOut -notmatch 'from-preload') {
            Fail "drive the injected script never ran; the driver's API reaches the page this way and no other"
        } else {
            Report "drive a window, a document and a message back, with nothing downloaded"
        }
    }
}

Write-Output "report: kept $work"
Write-Output "=== evergreen: $failures failure(s) ==="
if ($failures -gt 0) { exit 1 }
exit 0
