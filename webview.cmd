if (":" == "<!--") then : 0 /*\;:\
@ECHO OFF||:;fi;:||REM<<'EXIT'
<NUL SET /P =[1A[K[1A
    SETLOCAL ENABLEEXTENSIONS

    SET "SCRIPT_NAME=%~n0"
    SET "SCRIPT_DIR=%~dp0"
    SET "APP_FOLDER=%SCRIPT_DIR%%SCRIPT_NAME%"
    SET "FX_DIR=%WINDIR%\Microsoft.NET\Framework\v4.0.30319"
    SET "JSC=%FX_DIR%\jsc.exe"
    SET "MANIFEST=%APP_FOLDER%\%SCRIPT_NAME%.exe.manifest"
    SET "WEBVIEW2_ROOT=%APP_FOLDER%\Microsoft.Web.WebView2"

    IF NOT EXIST "%JSC%" (
        SET "FX_DIR=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319"
        SET "JSC=%FX_DIR%\jsc.exe"
    )

    IF NOT EXIST "%JSC%" ( EXIT /B 1 )

    IF NOT EXIST "%APP_FOLDER%" MKDIR "%APP_FOLDER%"
    IF ERRORLEVEL 1 EXIT /B 1

    IF EXIST "%APP_FOLDER%\%SCRIPT_NAME%.exe" (
        GOTO :START_APP
    )

    "%JSC%" /nologo /debug- /t:winexe /out:"%APP_FOLDER%\%SCRIPT_NAME%.exe" ^
        /autoref+ ^
        /lib:"%FX_DIR%" ^
        /r:"%FX_DIR%\mscorlib.dll" ^
        /r:"%FX_DIR%\System.dll" ^
        /r:"%FX_DIR%\System.Configuration.dll" ^
        /r:"%FX_DIR%\Accessibility.dll" ^
        /r:"%FX_DIR%\System.Drawing.dll" ^
        /r:"%FX_DIR%\System.Windows.Forms.dll" ^
        "%~f0"
        SET "JSC_EXIT=%ERRORLEVEL%"
        IF NOT "%JSC_EXIT%"=="0" EXIT /B %JSC_EXIT%

    > "%MANIFEST%" (
        ECHO ^<?xml version="1.0" encoding="UTF-8" standalone="yes"?^>
        ECHO ^<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"^>
        ECHO   ^<assemblyIdentity version="1.0.0.0" processorArchitecture="*" name="neutrino.webview" type="win32" /^>
        ECHO   ^<description^>neutrino webview^</description^>
        ECHO   ^<compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"^>
        ECHO     ^<application^>
        ECHO       ^<supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}" /^>
        ECHO       ^<supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}" /^>
        ECHO       ^<supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}" /^>
        ECHO       ^<supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}" /^>
        ECHO       ^<supportedOS Id="{e2011457-1546-43c5-a5fe-008deee3d3f0}" /^>
        ECHO     ^</application^>
        ECHO   ^</compatibility^>
        ECHO   ^<application xmlns="urn:schemas-microsoft-com:asm.v3"^>
        ECHO     ^<windowsSettings^>
        ECHO       ^<dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings"^>true/pm^</dpiAware^>
        ECHO       ^<dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings"^>PerMonitorV2, PerMonitor^</dpiAwareness^>
        ECHO     ^</windowsSettings^>
        ECHO   ^</application^>
        ECHO ^</assembly^>
    )

    :START_APP
    SET "NEUTRINO_SCRIPT_PATH=%~f0"
    START "" /D "%APP_FOLDER%" "%APP_FOLDER%\%SCRIPT_NAME%.exe"
    IF ERRORLEVEL 1 EXIT /B 1
    EXIT /B 0

EXIT
script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
find_qt_runtime() {
    if command -v qml6 >/dev/null 2>&1; then
        command -v qml6
        return 0
    fi
    if command -v qmlscene6 >/dev/null 2>&1; then
        command -v qmlscene6
        return 0
    fi
    if command -v qmlscene-qt6 >/dev/null 2>&1; then
        command -v qmlscene-qt6
        return 0
    fi
    if command -v qml >/dev/null 2>&1; then
        command -v qml
        return 0
    fi
    if command -v qmlscene >/dev/null 2>&1; then
        command -v qmlscene
        return 0
    fi
    if [ -x "/usr/lib/qt6/bin/qmlscene" ]; then
        printf '%s\n' "/usr/lib/qt6/bin/qmlscene"
        return 0
    fi
    if [ -x "/usr/lib/qt6/bin/qml" ]; then
        printf '%s\n' "/usr/lib/qt6/bin/qml"
        return 0
    fi
    if [ -x "/usr/lib/qt5/bin/qmlscene" ]; then
        printf '%s\n' "/usr/lib/qt5/bin/qmlscene"
        return 0
    fi
    if [ -x "/usr/lib/qt5/bin/qml" ]; then
        printf '%s\n' "/usr/lib/qt5/bin/qml"
        return 0
    fi
    return 1
}

extract_embedded_html() {
    awk '
        BEGIN { found = 0 }
        {
            lower = tolower($0)
            if (!found && lower ~ /^<!doctype html><html><head><meta charset="utf-8"><\/head>/) {
                found = 1
            }
            if (found) {
                print
            }
        }
    ' "$script_path"
}

run_qt() {
    qml_runner="$1"
    if [ -z "$qml_runner" ]; then
        echo "No Qt QML runtime found (tried: qmlscene6, qmlscene-qt6, qml6, qmlscene)" >&2
        return 1
    fi

    tmp_root="${TMPDIR:-/tmp}/neutrino-qt-${USER:-user}"
    mkdir -p "$tmp_root" || return 1
    tmp_qml="$tmp_root/window.qml"
    qt_url="${NEUTRINO_QT_URL:-https://alganet.github.io/}"
    esc_qt_url="$(printf '%s' "$qt_url" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    qml_imports='import QtQuick
import QtQuick.Window
import QtWebEngine'

    case "$qml_runner" in
        *qt6*)
            ;;
        *)
            qml_imports='import QtQuick 2.12
import QtQuick.Window 2.12
import QtWebEngine 1.7'
            ;;
    esac

    cat > "$tmp_qml" <<EOF
${qml_imports}

Window {
    id: root
    width: 900
    height: 600
    visible: true
    title: "neutrino - Qt"

    WebEngineView {
        id: view
        anchors.fill: parent
        url: "${esc_qt_url}"
    }
}
EOF

    if [ ! -s "$tmp_qml" ]; then
        echo "Qt entry QML file was not created: $tmp_qml" >&2
        return 1
    fi

    echo "Qt launch: runner=$qml_runner qml=$tmp_qml" >&2

    qt_qpa_platform="${QT_QPA_PLATFORM:-xcb}"
    qt_libgl_software="${LIBGL_ALWAYS_SOFTWARE:-1}"
    qt_disable_sandbox="${QTWEBENGINE_DISABLE_SANDBOX:-0}"
    qt_chromium_flags="${QTWEBENGINE_CHROMIUM_FLAGS:---disable-dev-shm-usage}"

    if [ "$qt_disable_sandbox" = "1" ]; then
        qt_chromium_flags="$qt_chromium_flags --no-sandbox"
    fi

    case "$qml_runner" in
        qmlscene6|qmlscene)
            QT_QPA_PLATFORM="$qt_qpa_platform" \
            LIBGL_ALWAYS_SOFTWARE="$qt_libgl_software" \
            QTWEBENGINE_CHROMIUM_FLAGS="$qt_chromium_flags" \
            "$qml_runner" "$tmp_qml"
            ;;
        qml6|qml)
            QT_QPA_PLATFORM="$qt_qpa_platform" \
            LIBGL_ALWAYS_SOFTWARE="$qt_libgl_software" \
            QTWEBENGINE_CHROMIUM_FLAGS="$qt_chromium_flags" \
            "$qml_runner" "$tmp_qml"
            ;;
        *)
            QT_QPA_PLATFORM="$qt_qpa_platform" \
            LIBGL_ALWAYS_SOFTWARE="$qt_libgl_software" \
            QTWEBENGINE_CHROMIUM_FLAGS="$qt_chromium_flags" \
            "$qml_runner" "$tmp_qml"
            ;;
    esac
}

if command -v gjs >/dev/null 2>&1
then NEUTRINO_SCRIPT_PATH="$script_path" gjs "$script_path"
elif qt_runner="$(find_qt_runtime)"
then run_qt "$qt_runner"
elif command -v osascript >/dev/null 2>&1
then NEUTRINO_SCRIPT_PATH="$script_path" osascript -l JavaScript "$script_path"
else echo "No suitable runtime found (expected gjs, Qt QML runtime, or osascript)" >&2
fi
exit $?;:<<'//</script></head><body></body>' #-->
<!doctype html><html><head><meta charset="utf-8"></head>
<script type=text/javascript>//*/

    /*@cc_on
        @if (@_jscript_version >= 7)
            import System;
            import System.IO;
            import System.Drawing;
            import System.Windows.Forms;
            import System.Reflection;
        @end
    @*/

    var NeutrinoWebview = {
        config: {
            title: "neutrino",
            url: "https://alganet.github.io/",
            width: 900,
            height: 600
        },

        hasGlobalExpr: function (expression) {
            try {
                return eval(expression);
            } catch (_) {
                return false;
            }
        },

        extractHtmlDocument: function (content) {
            var text = String(content || "");
            var lower = text.toLowerCase();
            var doctypeIndex = lower.indexOf("<!doctype html");
            if (doctypeIndex >= 0) {
                return text.substring(doctypeIndex);
            }
            return text;
        },

        getMacScriptPath: function (ObjCRef, dollar) {
            var fileManager = dollar.NSFileManager.defaultManager;
            var currentDir = String(fileManager.currentDirectoryPath);

            var envPathObj = dollar.NSProcessInfo.processInfo.environment.objectForKey("NEUTRINO_SCRIPT_PATH");
            if (envPathObj) {
                var envPath = String(envPathObj);
                if (envPath && fileManager.fileExistsAtPath(envPath)) {
                    return envPath;
                }
            }

            var argv = [];
            try {
                argv = ObjCRef.deepUnwrap(dollar.NSProcessInfo.processInfo.arguments);
            } catch (_) {
                argv = [];
            }

            for (var i = argv.length - 1; i >= 0; i--) {
                var candidate = String(argv[i] || "");
                if (!candidate || /^-/.test(candidate)) {
                    continue;
                }

                if (fileManager.fileExistsAtPath(candidate)) {
                    return candidate;
                }

                var combined = currentDir + "/" + candidate;
                if (fileManager.fileExistsAtPath(combined)) {
                    return combined;
                }
            }

            throw new Error("Could not resolve current script path on macOS.");
        },

        getLinuxScriptPath: function (importsRef) {
            var GLib = importsRef["gi"]["GLib"];
            var systemRef = importsRef["system"];
            var programPath = String(systemRef.programPath);
            if (!GLib.path_is_absolute(programPath)) {
                programPath = GLib.build_filenamev([GLib.get_current_dir(), programPath]);
            }
            return programPath;
        },

        run: function () {
            if (this.hasGlobalExpr("typeof System !== 'undefined' && System && System.Windows && System.Windows.Forms && System.Windows.Forms.Application")) {
                this.runWindows();
                return;
            }
            if (this.hasGlobalExpr("typeof ObjC !== 'undefined' && typeof $ !== 'undefined'")) {
                this.runMacOS();
                return;
            }
            if (this.hasGlobalExpr("typeof imports !== 'undefined' && !!imports.gi")) {
                this.runGjs();
                return;
            }
            if (this.hasGlobalExpr("typeof window !== 'undefined'")) {
                this.runWeb();
                return;
            }
            throw new Error("Unsupported JS runtime for webview.js");
        },

        runWeb: function () {
            var win = eval("window");
            win.location = this.config.url;
        },

        runMacOS: function () {
            var ObjCRef = eval("ObjC");
            var dollar = eval("$");

            ObjCRef["import"]("Cocoa");
            ObjCRef["import"]("WebKit");

            var app = dollar.NSApplication.sharedApplication;
            var frame = dollar.NSMakeRect(0, 0, this.config.width, this.config.height);

            var window = dollar.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
                frame,
                dollar.NSTitledWindowMask | dollar.NSClosableWindowMask | dollar.NSResizableWindowMask,
                dollar.NSBackingStoreBuffered,
                false
            );

            window.title = this.config.title + " - macOS";
            try {
                window.center();
            } catch (_) {
            }

            var webView = dollar.WKWebView.alloc.initWithFrameConfiguration(
                frame,
                dollar.WKWebViewConfiguration.alloc.init
            );

            var scriptPath = this.getMacScriptPath(ObjCRef, dollar);
            var htmlData = dollar.NSData.dataWithContentsOfFile(scriptPath);
            if (!htmlData) {
                throw new Error("Could not read local document: " + scriptPath);
            }

            var htmlNSString = dollar.NSString.alloc.initWithDataEncoding(
                htmlData,
                dollar.NSUTF8StringEncoding
            );
            if (!htmlNSString) {
                throw new Error("Could not decode local document as UTF-8: " + scriptPath);
            }

            var htmlText = this.extractHtmlDocument(ObjCRef.unwrap(htmlNSString));
            var baseUrl = dollar.NSURL.fileURLWithPath(scriptPath).URLByDeletingLastPathComponent;
            webView.loadHTMLStringBaseURL(htmlText, baseUrl);

            window.contentView = webView;
            window.makeKeyAndOrderFront(null);
            try {
                app.activateIgnoringOtherApps(true);
            } catch (_) {
            }
            app.run();
        },

        resolveLinuxWebKitVersion: function () {
            var importsRef = eval("imports");
            var GIRepository = importsRef["gi"]["GIRepository"];
            var repository = GIRepository["Repository"]["get_default"]();
            var versions = repository.enumerate_versions("WebKit2");

            if (versions.indexOf("4.1") !== -1) {
                return "4.1";
            }
            if (versions.indexOf("4.0") !== -1) {
                return "4.0";
            }
            throw new Error("WebKit2 introspection typelibs not found");
        },

        runGtkWebView: function (platformLabel) {
            var importsRef = eval("imports");
            importsRef["gi"]["versions"]["Gtk"] = "3.0";
            importsRef["gi"]["versions"]["WebKit2"] = this.resolveLinuxWebKitVersion();

            var Gtk = importsRef["gi"]["Gtk"];
            var WebKit2 = importsRef["gi"]["WebKit2"];
            var GLib = importsRef["gi"]["GLib"];
            var ByteArray = importsRef["byteArray"];

            Gtk.init(null);

            var window = new Gtk.Window({
                title: this.config.title + " - " + platformLabel,
                default_width: this.config.width,
                default_height: this.config.height
            });
            window.set_position(Gtk.WindowPosition.CENTER);
            window.connect("destroy", function () { Gtk.main_quit(); });

            var webView = new WebKit2.WebView();
            var scriptPath = this.getLinuxScriptPath(importsRef);
            var fileRead = GLib.file_get_contents(scriptPath);
            if (!fileRead[0]) {
                throw new Error("Could not read local document: " + scriptPath);
            }
            var htmlText = this.extractHtmlDocument(ByteArray.toString(fileRead[1]));
            webView.load_html(htmlText, null);

            window.add(webView);
            window.show_all();

            Gtk.main();
        },

        runGjs: function () {
            this.runGtkWebView("Linux");
        },

        hasWebView2Assemblies: function (SystemRef, libDir) {
            if (!libDir) {
                return false;
            }
            return SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.Core.dll")) &&
                SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.WinForms.dll"));
        },

        findWebView2LibDir: function (SystemRef, appFolder) {
            var envLibDir = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR");
            if (this.hasWebView2Assemblies(SystemRef, envLibDir)) {
                return envLibDir;
            }

            var directNet462 = SystemRef.IO.Path.Combine(appFolder, "Microsoft.Web.WebView2", "lib", "net462");
            if (this.hasWebView2Assemblies(SystemRef, directNet462)) {
                return directNet462;
            }

            var directNet45 = SystemRef.IO.Path.Combine(appFolder, "Microsoft.Web.WebView2", "lib", "net45");
            if (this.hasWebView2Assemblies(SystemRef, directNet45)) {
                return directNet45;
            }

            if (SystemRef.IO.Directory.Exists(appFolder)) {
                var packageDirs = SystemRef.IO.Directory.GetDirectories(appFolder, "Microsoft.Web.WebView2*");
                for (var i = 0; i < packageDirs.Length; i++) {
                    var candidateNet462 = SystemRef.IO.Path.Combine(packageDirs[i], "lib", "net462");
                    if (this.hasWebView2Assemblies(SystemRef, candidateNet462)) {
                        return candidateNet462;
                    }

                    var candidateNet45 = SystemRef.IO.Path.Combine(packageDirs[i], "lib", "net45");
                    if (this.hasWebView2Assemblies(SystemRef, candidateNet45)) {
                        return candidateNet45;
                    }
                }
            }

            return null;
        },

        prependLoaderPaths: function (SystemRef, webView2LibDir) {
            if (!webView2LibDir) {
                return;
            }

            var packageRoot = SystemRef.IO.Path.GetFullPath(SystemRef.IO.Path.Combine(webView2LibDir, "..", ".."));
            var loaderPaths = "";

            var x86Loader = SystemRef.IO.Path.Combine(packageRoot, "runtimes", "win-x86", "native", "WebView2Loader.dll");
            if (SystemRef.IO.File.Exists(x86Loader)) {
                loaderPaths = SystemRef.IO.Path.GetDirectoryName(x86Loader) + ";" + loaderPaths;
            }

            var x64Loader = SystemRef.IO.Path.Combine(packageRoot, "runtimes", "win-x64", "native", "WebView2Loader.dll");
            if (SystemRef.IO.File.Exists(x64Loader)) {
                loaderPaths = SystemRef.IO.Path.GetDirectoryName(x64Loader) + ";" + loaderPaths;
            }

            var arm64Loader = SystemRef.IO.Path.Combine(packageRoot, "runtimes", "win-arm64", "native", "WebView2Loader.dll");
            if (SystemRef.IO.File.Exists(arm64Loader)) {
                loaderPaths = SystemRef.IO.Path.GetDirectoryName(arm64Loader) + ";" + loaderPaths;
            }

            if (loaderPaths) {
                var currentPath = SystemRef.Environment.GetEnvironmentVariable("PATH");
                if (!currentPath) {
                    currentPath = "";
                }
                SystemRef.Environment.SetEnvironmentVariable("PATH", loaderPaths + currentPath);
            }
        },

        escapeForSingleQuotedPowerShell: function (value) {
            if (!value) {
                return "";
            }
            return String(value).replace(/'/g, "''");
        },

        extractArchiveWithPowerShell: function (SystemRef, archivePath, destinationPath) {
            var psCommand = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; Expand-Archive -LiteralPath '" +
                this.escapeForSingleQuotedPowerShell(String(archivePath)) +
                "' -DestinationPath '" +
                this.escapeForSingleQuotedPowerShell(String(destinationPath)) +
                "' -Force";

            var encodedCommand = SystemRef.Convert.ToBase64String(SystemRef.Text.Encoding.Unicode.GetBytes(psCommand));

            var startInfo = new SystemRef.Diagnostics.ProcessStartInfo();
            startInfo.FileName = "powershell.exe";
            startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encodedCommand;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;

            var process = SystemRef.Diagnostics.Process.Start(startInfo);
            process.WaitForExit();

            if (process.ExitCode !== 0) {
                throw new Error("Expand-Archive failed with exit code " + process.ExitCode + ".");
            }
        },

        showWindowsError: function (SystemRef, title, message) {
            try {
                SystemRef.Windows.Forms.MessageBox.Show(
                    String(message),
                    String(title),
                    SystemRef.Windows.Forms.MessageBoxButtons.OK,
                    SystemRef.Windows.Forms.MessageBoxIcon.Error
                );
            } catch (_) {
            }
        },

        downloadWebView2WithProgress: function (SystemRef, appFolder) {
            var packageRoot = SystemRef.IO.Path.Combine(appFolder, "Microsoft.Web.WebView2");
            var tempPackagePath = SystemRef.IO.Path.Combine(
                SystemRef.IO.Path.GetTempPath(),
                "Microsoft.Web.WebView2." + SystemRef.Guid.NewGuid().ToString("N") + ".zip"
            );
            var packageUrl = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2";

            var progressForm = new SystemRef.Windows.Forms.Form();
            progressForm.Text = "Downloading WebView2 Runtime";
            progressForm.FormBorderStyle = SystemRef.Windows.Forms.FormBorderStyle.FixedDialog;
            progressForm.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;
            progressForm.ClientSize = new SystemRef.Drawing.Size(440, 92);
            progressForm.ControlBox = false;
            progressForm.TopMost = true;

            var progressLabel = new SystemRef.Windows.Forms.Label();
            progressLabel.AutoSize = false;
            progressLabel.TextAlign = SystemRef.Drawing.ContentAlignment.MiddleLeft;
            progressLabel.SetBounds(16, 12, 408, 20);
            progressLabel.Text = "Starting download...";

            var progressBar = new SystemRef.Windows.Forms.ProgressBar();
            progressBar.SetBounds(16, 40, 408, 22);
            progressBar.Minimum = 0;
            progressBar.Maximum = 100;
            progressBar.Style = SystemRef.Windows.Forms.ProgressBarStyle.Continuous;

            progressForm.Controls.Add(progressLabel);
            progressForm.Controls.Add(progressBar);
            progressForm.Show();
            progressForm.Refresh();
            SystemRef.Windows.Forms.Application.DoEvents();

            var response = null;
            var responseStream = null;
            var fileStream = null;

            try {
                if (SystemRef.IO.Directory.Exists(packageRoot)) {
                    SystemRef.IO.Directory.Delete(packageRoot, true);
                }

                try {
                    var tls12 = 3072;
                    var tls11 = 768;
                    var tls10 = 192;
                    SystemRef.Net.ServicePointManager.SecurityProtocol = tls12 | tls11 | tls10;
                } catch (_) {
                }

                var request = SystemRef.Net.WebRequest.Create(packageUrl);
                response = request.GetResponse();
                responseStream = response.GetResponseStream();

                var totalBytes = response.ContentLength;
                if (totalBytes <= 0) {
                    progressBar.Style = SystemRef.Windows.Forms.ProgressBarStyle.Marquee;
                    progressLabel.Text = "Downloading package...";
                }

                fileStream = new SystemRef.IO.FileStream(tempPackagePath, SystemRef.IO.FileMode.Create, SystemRef.IO.FileAccess.Write, SystemRef.IO.FileShare.None);
                var buffer = System.Array.CreateInstance(System.Byte, 32768);
                var downloadedBytes = 0;
                var lastPercentage = -1;
                var bytesRead = 0;

                while ((bytesRead = responseStream.Read(buffer, 0, buffer.Length)) > 0) {
                    fileStream.Write(buffer, 0, bytesRead);
                    downloadedBytes += bytesRead;

                    if (totalBytes > 0) {
                        var percentage = System.Math.Min(100, System.Convert.ToInt32((downloadedBytes * 100.0) / totalBytes));
                        if (percentage !== lastPercentage) {
                            progressBar.Value = percentage;
                            progressLabel.Text = "Downloading package... " + percentage + "%";
                            lastPercentage = percentage;
                        }
                    }

                    SystemRef.Windows.Forms.Application.DoEvents();
                }

                fileStream.Close();
                fileStream = null;
                responseStream.Close();
                responseStream = null;
                response.Close();
                response = null;

                if (totalBytes > 0) {
                    progressBar.Value = 100;
                }
                progressLabel.Text = "Extracting package...";
                SystemRef.Windows.Forms.Application.DoEvents();

                this.extractArchiveWithPowerShell(SystemRef, tempPackagePath, packageRoot);
            } catch (exDownload) {
                var message = "Download/extract failed.";
                try {
                    if (exDownload && exDownload.message) {
                        message = message + "\n\n" + String(exDownload.message);
                    }
                } catch (_) {
                }
                try {
                    message = message + "\n\n" + String(exDownload);
                } catch (_) {
                }
                throw new Error(message);
            } finally {
                if (fileStream) {
                    fileStream.Close();
                }
                if (responseStream) {
                    responseStream.Close();
                }
                if (response) {
                    response.Close();
                }
                if (SystemRef.IO.File.Exists(tempPackagePath)) {
                    SystemRef.IO.File.Delete(tempPackagePath);
                }
                progressForm.Close();
                progressForm.Dispose();
            }
        },

        ensureWebView2Package: function (SystemRef, appFolder) {
            var existingLibDir = this.findWebView2LibDir(SystemRef, appFolder);
            if (existingLibDir) {
                return existingLibDir;
            }

            if (!SystemRef.IO.Directory.Exists(appFolder)) {
                SystemRef.IO.Directory.CreateDirectory(appFolder);
            }

            this.downloadWebView2WithProgress(SystemRef, appFolder);

            var libDir = this.findWebView2LibDir(SystemRef, appFolder);

            if (!libDir) {
                throw new Error("WebView2 package download completed but required assemblies were not found.");
            }
            return libDir;
        },

        runWindows: function () {
            var SystemRef = eval("System");
            try {
                SystemRef.Windows.Forms.Application.EnableVisualStyles();
                SystemRef.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);

                var startupPath = SystemRef.Windows.Forms.Application.StartupPath;
                var appFolder = startupPath;
                var userDataDir = SystemRef.IO.Path.Combine(appFolder, "data");

                var webView2LibDir = this.ensureWebView2Package(SystemRef, appFolder);
                if (!webView2LibDir) {
                    SystemRef.Environment.Exit(1);
                    return;
                }

            SystemRef.Environment.SetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR", webView2LibDir);
            this.prependLoaderPaths(SystemRef, webView2LibDir);

            SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.Core.dll"));
            var webViewWinFormsAssembly = SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.WinForms.dll"));

            var window = new SystemRef.Windows.Forms.Form();
            window.Text = this.config.title + " - Windows";
            window.ClientSize = new SystemRef.Drawing.Size(this.config.width, this.config.height);
            window.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;

            var webViewType = webViewWinFormsAssembly.GetType("Microsoft.Web.WebView2.WinForms.WebView2");
            if (!webViewType) {
                throw new Error("Could not load Microsoft.Web.WebView2.WinForms.WebView2 type.");
            }

            var webView = SystemRef.Activator.CreateInstance(webViewType);

            // apply user-data folder as early as possible
            if (userDataDir) {
                try {
                    var cpType = webViewWinFormsAssembly.GetType("Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties");
                    if (cpType) {
                        var cp = SystemRef.Activator.CreateInstance(cpType);
                        try {
                            cp.UserDataFolder = userDataDir;
                            SystemRef.IO.Directory.CreateDirectory(cp.UserDataFolder);
                            webView.CreationProperties = cp;
                        } catch (_) {
                            // property might not exist on older versions
                        }
                    }
                } catch (_) {
                    // ignore failures, continue with default folder
                }
            }

            webView.Dock = SystemRef.Windows.Forms.DockStyle.Fill;

            var scriptPath = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH");
            if (!scriptPath) {
                throw new Error("Environment variable NEUTRINO_SCRIPT_PATH was not set.");
            }

            if (!SystemRef.IO.File.Exists(scriptPath)) {
                throw new Error("Could not find local document: " + scriptPath);
            }

            var htmlText = this.extractHtmlDocument(SystemRef.IO.File.ReadAllText(scriptPath));
            var dataUrl = "data:text/html;charset=utf-8," + SystemRef.Uri.EscapeDataString(htmlText);
            webView.Source = new SystemRef.Uri(dataUrl);

                window.Controls.Add(webView);
                SystemRef.Windows.Forms.Application.Run(window);
            } catch (ex) {
                var detail = "Failed to initialize WebView2 package/download.";
                try {
                    if (ex && ex.message) {
                        detail = detail + "\n\n" + String(ex.message);
                    }
                } catch (_) {
                }
                this.showWindowsError(SystemRef, "neutrino", detail);
                SystemRef.Environment.Exit(1);
            }
        }
    };

    NeutrinoWebview.run();

//</script></head><body></body>