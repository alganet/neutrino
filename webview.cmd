if (":" == "<!--") then : 0 /*\;:\
@ECHO OFF||:;fi;:||REM<<'EXIT'
<NUL SET /P =[1A[K[1A
    SETLOCAL ENABLEEXTENSIONS

    SET "SCRIPT_NAME=%~n0"
    SET "SCRIPT_DIR=%~dp0"
    SET "FX_DIR=%WINDIR%\Microsoft.NET\Framework\v4.0.30319"
    SET "JSC=%FX_DIR%\jsc.exe"
    SET "WEBVIEW2_ROOT=%SCRIPT_DIR%%SCRIPT_NAME%\Microsoft.Web.WebView2"

    IF NOT EXIST "%JSC%" (
        SET "FX_DIR=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319"
        SET "JSC=%FX_DIR%\jsc.exe"
    )

    IF NOT EXIST "%JSC%" ( EXIT /B 1 )

    "%JSC%" /nologo /debug- /t:winexe /out:"%SCRIPT_DIR%%SCRIPT_NAME%.exe" ^
        /autoref+ ^
        /lib:"%FX_DIR%" ^
        /r:"%FX_DIR%\mscorlib.dll" ^
        /r:"%FX_DIR%\System.dll" ^
        /r:"%FX_DIR%\System.Configuration.dll" ^
        /r:"%FX_DIR%\Accessibility.dll" ^
        /r:"%FX_DIR%\System.Drawing.dll" ^
        /r:"%FX_DIR%\System.Windows.Forms.dll" ^
        "%~f0"
        IF ERRORLEVEL 1 EXIT /B 1

    START "" /D "%SCRIPT_DIR%" "%SCRIPT_DIR%%SCRIPT_NAME%.exe"
    IF ERRORLEVEL 1 EXIT /B 1
    EXIT /B 0

EXIT
script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
if command -v gjs
then NEUTRINO_SCRIPT_PATH="$script_path" gjs "$script_path"
elif command -v osascript
then NEUTRINO_SCRIPT_PATH="$script_path" osascript -l JavaScript "$script_path"
else echo "No suitable JavaScript runtime found to run webview.js" >&2
fi
exit $?;:<<'//</script>' #-->
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
                this.runLinux();
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

        runLinux: function () {
            var importsRef = eval("imports");
            importsRef["gi"]["versions"]["Gtk"] = "3.0";
            importsRef["gi"]["versions"]["WebKit2"] = this.resolveLinuxWebKitVersion();

            var Gtk = importsRef["gi"]["Gtk"];
            var WebKit2 = importsRef["gi"]["WebKit2"];
            var GLib = importsRef["gi"]["GLib"];
            var ByteArray = importsRef["byteArray"];

            Gtk.init(null);

            var window = new Gtk.Window({
                title: this.config.title + " - Linux",
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

            // compute base folder named after the executable (used for both
            // locating the WebView2 package and for deriving the user-data path)
            var appFolder = null;
            var userDataDir = null;
            try {
                var exeName = SystemRef.IO.Path.GetFileNameWithoutExtension(SystemRef.Windows.Forms.Application.ExecutablePath);
                appFolder = SystemRef.IO.Path.Combine(startupPath, exeName);
                userDataDir = SystemRef.IO.Path.Combine(appFolder, "data");
            } catch (_) {
                appFolder = null;
                userDataDir = null;
            }

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

            var exeNameForDoc = SystemRef.IO.Path.GetFileNameWithoutExtension(SystemRef.Windows.Forms.Application.ExecutablePath);
            var scriptPath = SystemRef.IO.Path.Combine(startupPath, exeNameForDoc + ".cmd");

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