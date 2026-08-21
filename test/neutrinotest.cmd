if (":" == "<!--") then : 0 /*\;:\
@ECHO OFF||:;fi;:||REM<<'EXIT'
GOTO :W
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
SPDX-License-Identifier: ISC
:W
FOR /F %%E IN ('ECHO PROMPT $E ^| CMD') DO SET "ESC=%%E"
<NUL SET /P =[1A[K[1A
SETLOCAL ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION
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

REM The app folder can outlive any single version of this script, so a compiled
REM exe is only reused when the source it was built from is unchanged.
SET "APP_EXE=%APP_FOLDER%\%SCRIPT_NAME%.exe"
SET "APP_STAMP=%APP_FOLDER%\%SCRIPT_NAME%.stamp"
FOR %%A IN ("%~f0") DO SET "SRC_ID=%%~zA %%~tA"
SET "OLD_ID="
IF EXIST "%APP_STAMP%" SET /P OLD_ID=<"%APP_STAMP%"

IF EXIST "%APP_EXE%" IF "!OLD_ID!"=="!SRC_ID!" (
    GOTO :START_APP
)

SET "MSG=Your application is getting ready to run for the first time..."
SET "N=0"
FOR /F "tokens=2 delims=:" %%A IN ('MODE CON ^| FINDSTR [0-9]') DO (
    SET /A N+=1
    IF !N!==1 SET /A ROWS=%%A
    IF !N!==2 SET /A COLS=%%A
)
SET /A HALF_ROW=ROWS / 2
SET /A PAD="(COLS - 62) / 2"
SET "SPACES="
FOR /L %%I IN (1,1,!PAD!) DO SET "SPACES=!SPACES! "
CLS
<NUL SET /P =[!HALF_ROW!;1H!SPACES!!MSG!

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

> "%APP_STAMP%" ECHO !SRC_ID!

:START_APP
SET "NEUTRINO_SCRIPT_PATH=%~f0"
START "" /D "%APP_FOLDER%" "%APP_FOLDER%\%SCRIPT_NAME%.exe"
IF ERRORLEVEL 1 EXIT /B 1
EXIT /B 0
EXIT
script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# The tier list lives in exactly one place, the JavaScript region below, where
# build.sh stamps it. Reading it back out of the file rather than taking it from
# the environment means the shell and the JavaScript cannot disagree, and means
# no caller can weaken a build by exporting something.
neutrino_tiers="$(sed -n 's/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$script_path" | head -1)"
[ -z "$neutrino_tiers" ] && neutrino_tiers="default"
has_tier() { case ",$neutrino_tiers," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
find_qt_runtime() {
    for cmd in qml6 qml; do
        if command -v "$cmd" >/dev/null 2>&1; then
            command -v "$cmd"
            return 0
        fi
    done
    for path in /usr/lib/qt6/bin/qml; do
        if [ -x "$path" ]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

run_qt() {
    qml_runner="$1"
    [ -z "$qml_runner" ] && return 1

    script_dir="$(dirname "$script_path")"
    script_name="$(basename "$script_path")"
    script_name="${script_name%.*}"
    app_dir="$script_dir/$script_name"
    mkdir -p "$app_dir" || return 1
    app_qml="$app_dir/window.qml"
    app_config_js="$app_dir/neutrino.js"

    cat > "$app_config_js" <<JSEOF
.pragma library
var NeutrinoQml = true
var xhr = new XMLHttpRequest()
xhr.open("GET", "file://$script_path", false)
xhr.send()
var _neutrinoRawSource = xhr.responseText
eval(_neutrinoRawSource)

var _qmlRoot = null

var _qt = null

NeutrinoWebview.initQml = function (root, callbacks) {
    _qmlRoot = root
    _qt = callbacks
}

NeutrinoWebview.routeQmlMessage = function (raw) {
    var msg = NeutrinoWebview.parseMessage(raw)
    if (!msg) {
        console.warn("neutrino: refused a malformed record")
        return
    }
    if (!_qmlRoot) return
    if (msg.action === "setTitle") _qmlRoot.title = msg.title
    else if (msg.action === "resize") { _qmlRoot.width = msg.width; _qmlRoot.height = msg.height }
    else if (msg.action === "move") { _qmlRoot.x = msg.x; _qmlRoot.y = msg.y }
    else if (msg.action === "close") _qmlRoot.close()
    else if (msg.action === "openExternal" && _qt) _qt.openUrl(msg.url)
}

// Encoded for the same reason the Windows title is: a record separator is a
// control character, and a console message is a diagnostic channel that nothing
// promises will carry one through Chromium and out the other side unchanged.
NeutrinoWebview.qmlPreloadScript = NeutrinoWebview.buildPreloadScript(
    'function(m){console.log("__NEUTRINO__"+encodeURIComponent(m));}',
    "console"
)
JSEOF

    cat > "$app_qml" <<'EOF'
import QtQuick
import QtWebEngine
import "neutrino.js" as Neutrino

Window {
    id: root
    readonly property var cfg: Neutrino.NeutrinoWebview.config
    visible: true
    title: cfg.title + " - Qt"
    Component.onCompleted: {
        root.width = cfg.width
        root.height = cfg.height
        root.x = (Screen.width - root.width) / 2
        root.y = (Screen.height - root.height) / 2
    }

    WebEngineView {
        id: view
        anchors.fill: parent
        property bool preloadInjected: false
        property bool documentLoaded: false
        property bool contentLoaded: false
        onLoadingChanged: function(info) {
            if (info.status === WebEngineView.LoadSucceededStatus) {
                if (!preloadInjected) {
                    preloadInjected = true
                    view.runJavaScript(Neutrino.NeutrinoWebview.qmlPreloadScript)
                }
                view.documentLoaded = true
            }
        }
        onJavaScriptConsoleMessage: function(level, message, lineNumber, sourceID) {
            if (String(message).indexOf("__NEUTRINO__") !== 0) {
                // Overriding this signal replaces Qt's own handler, so without
                // this every error the page reports goes nowhere and a broken
                // document looks identical to a silent one.
                console.warn("neutrino page: " + message + " (" + sourceID + ":" + lineNumber + ")")
                return
            }
            Neutrino.NeutrinoWebview.routeQmlMessage(
                decodeURIComponent(String(message).substring(12))
            )
        }
        // The document is loaded once, from this file, and never navigates
        // again. Without this a link or a script assignment could replace it
        // with a remote origin, and that origin would then be holding the
        // channel to the native window. http and https go to the desktop's
        // handler instead, which is what a user clicking a link expects;
        // everything else is refused, including file: and the schemes the
        // platform keeps inventing.
        onNavigationRequested: function(request) {
            var target = String(request.url)
            if (Neutrino.NeutrinoWebview.isOwnDocument(target)) {
                return
            }
            // QtWebEngine hands this file's document to the view by navigating
            // to a data: url, so exactly one of those is the app arriving and
            // every one after it is a page moving itself somewhere this cannot
            // tell apart by origin. Allowing the first and refusing the rest is
            // the difference between naming the engine's own mechanism and
            // leaving the same-null-origin hole open for anyone to walk through.
            if (target.indexOf("data:") === 0 && !view.contentLoaded) {
                view.contentLoaded = true
                return
            }
            console.warn("neutrino: refused navigation to " + request.url)
            if (typeof request.reject === "function") {
                request.reject()
            } else {
                request.action = WebEngineNavigationRequest.IgnoreRequest
            }
            if (Neutrino.NeutrinoWebview.isExternalUrl(String(request.url))) {
                Qt.openUrlExternally(request.url)
            }
        }
        Component.onCompleted: {
            Neutrino.NeutrinoWebview.initQml(root, {
                openUrl: function(url) { Qt.openUrlExternally(url) }
            })
            view.loadHtml(Neutrino.NeutrinoWebview.extractHtmlDocument(Neutrino._neutrinoRawSource))
        }
    }
}
EOF

    [ ! -s "$app_qml" ] && return 1

    # Chromium's own sandbox is the only thing standing between hostile page
    # content and this machine, so a release build has no way to turn it off.
    # CI needs it off because its containers cannot create user namespaces, and
    # CI builds with --tier=testing to say so out loud.
    if has_tier testing && [ "$QTWEBENGINE_DISABLE_SANDBOX" = "1" ]; then
        QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS} --no-sandbox"
    fi

    QML_XHR_ALLOW_FILE_READ=1 \
    QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}" \
    LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}" \
    QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS:---disable-dev-shm-usage}" \
    "$qml_runner" "$app_qml"
}

# WebKitGTK's sandbox is bubblewrap, and bubblewrap needs an unprivileged user
# namespace. Whether it can have one is not a property of this program: Ubuntu
# 24.04 and its derivatives set kernel.apparmor_restrict_unprivileged_userns to
# 1 and refuse, while the same kernel elsewhere allows it. Under netinstall it
# is refused again for an unrelated reason, since Landlock denies mount to any
# domain handling a filesystem right.
#
# None of that can be recovered from after the fact. Asking WebKitGTK to turn
# the sandbox off once a web process exists aborts the program outright --
# "Sandboxing cannot be changed after subprocesses were spawned" -- and asking
# for a sandbox that cannot start gives a window with nothing in it. So the
# question is settled here, before anything is launched, by running the actual
# mechanism rather than by looking for the parts it is made of.
#
# The value is always assigned, never defaulted from the environment, so this
# is a measurement being passed inward and not a switch anyone can set.
neutrino_webkit_sandbox=0
if command -v bwrap >/dev/null 2>&1 &&
   bwrap --unshare-user --ro-bind / / /bin/true >/dev/null 2>&1
then neutrino_webkit_sandbox=1
fi
export NEUTRINO_WEBKIT_SANDBOX="$neutrino_webkit_sandbox"

if command -v gjs >/dev/null 2>&1
then
    # gjs is a system binary; a bundled caller (snap, flatpak, AppImage, ...)
    # may export GLib/GTK loader overrides pointing at its own libraries,
    # which then get loaded against the system glibc and crash. Clear them so
    # gjs resolves modules from the system defaults.
    unset GTK_PATH GTK_EXE_PREFIX GTK_IM_MODULE_FILE \
          GDK_PIXBUF_MODULE_FILE GDK_PIXBUF_MODULEDIR \
          GIO_MODULE_DIR GSETTINGS_SCHEMA_DIR LOCPATH \
          LD_PRELOAD LD_LIBRARY_PATH
    NEUTRINO_SCRIPT_PATH="$script_path" gjs "$script_path"
elif qt_runner="$(find_qt_runtime)"
then run_qt "$qt_runner"
elif command -v osascript >/dev/null 2>&1
then NEUTRINO_SCRIPT_PATH="$script_path" osascript -l JavaScript "$script_path"
else echo "No suitable runtime found (expected gjs, Qt QML runtime, or osascript)" >&2
fi
exit $?;:<<'//</script></head><body></body>' #-->
<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'"><style> html, body { background: white; color: black; font-size: 2em; }</style></head>
<script type=text/javascript>//*/

    /*@cc_on
        @if (@_jscript_version >= 7)
            import System;
            import System.IO;
            import System.Collections;
            import System.Drawing;
            import System.Windows.Forms;
            import System.Reflection;

            // Line comments only in here. This whole block is itself a block
            // comment to every engine but jsc, and JavaScript has no nested
            // block comments -- an inner close would end the outer one and
            // spill JScript.NET syntax into three engines that cannot read it.
            //
            // The only reason this class exists is that CoreWebView2's
            // WebMessageReceived wants a delegate, and the delegate's type
            // comes from an assembly loaded at run time, so it cannot be named
            // here. Delegate.CreateDelegate binds a method to a delegate type
            // discovered at run time, and accepts a method whose parameters are
            // wider than the delegate's -- Object is wider than every event
            // args type there is -- so a method typed this way binds to
            // EventHandler of anything.
            //
            // It queues the arguments rather than calling back out. A .NET
            // static is not reachable from page script, so unlike a title the
            // queue cannot be written by the document, and draining it from the
            // existing loop avoids asking whether a JScript class method may
            // call a JScript global -- the one part of this that would fail at
            // compile time rather than at run time.
            class NeutrinoWebMessageSink {
                static var queue : ArrayList = new ArrayList();
                function Handle(sender : Object, args : Object) : void {
                    NeutrinoWebMessageSink.queue.Add(args);
                }
            }
        @end
    @*/

    var NeutrinoWebview = {
        // The tier list is stamped here by build.sh and read back out of this
        // file by the shell section, so all three languages in this polyglot
        // see one value and there is nothing in the environment that can be set
        // to talk any of them out of it. A release build has no way to be
        // talked into "testing".
        //#TIER_START
        tiers: "default",
        //#TIER_END

        hasTier: function (name) {
            return ("," + String(this.tiers || "default") + ",").indexOf("," + name + ",") >= 0;
        },

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
            if (this.hasGlobalExpr("typeof NeutrinoQml !== 'undefined'")) {
                return;
            }
            if (this.hasGlobalExpr("typeof window !== 'undefined'")) {
                this.runWeb();
                return;
            }
            throw new Error("Unsupported JS runtime for webview.js");
        },

        runWeb: function () {
            //#RUNWEB_START
var win = eval("window");
var doc = eval("document");

function startTests() {
    var el = doc.createElement("div");
    el.style.cssText = "font-family:monospace;font-size:24px;padding:20px;";
    doc.body.appendChild(el);

    var steps = [
        function () { el.textContent = "Step 0: Ready"; win.neutrino.window.setTitle("STEP0"); },
        function () { el.textContent = "Step 1: setTitle"; win.neutrino.window.setTitle("STEP1-Test Title"); },
        function () { el.textContent = "Step 2: resize"; win.neutrino.window.resize(500, 400); },
        function () { el.textContent = "Step 2: resize done"; win.neutrino.window.setTitle("STEP2"); },
        function () { el.textContent = "Step 3: move"; win.neutrino.window.move(0, 0); },
        function () { el.textContent = "Step 3: move done"; win.neutrino.window.setTitle("STEP3"); },
        function () { el.textContent = "TESTS DONE"; win.neutrino.window.setTitle("TESTS DONE"); },
        function () { el.textContent = "Closing window..."; win.neutrino.window.close(); }
    ];

    var current = 0;
    function runNext() {
        if (current < steps.length) {
            steps[current]();
            current++;
            if (current < steps.length) win.setTimeout(runNext, 1000);
        }
    }
    // The whole sequence takes about eight seconds, and a verifier that is not
    // watching by then misses steps it can never see again. verify-windows.ps1
    // compiles inline C# with Add-Type before its first poll, which on a cold
    // runner can cost longer than that -- so the app waits for its audience
    // rather than racing it.
    win.setTimeout(runNext, 8000);
}

function waitForReady() {
    if (doc.body && win.neutrino) startTests();
    else win.setTimeout(waitForReady, 200);
}
waitForReady();
            //#RUNWEB_END
        },

        resolveLinuxWebKitVersion: function () {
            var importsRef = eval("imports");
            var GIRepository = importsRef["gi"]["GIRepository"];
            var Repository = GIRepository["Repository"];
            var repository = Repository["dup_default"]
                ? Repository["dup_default"]()
                : Repository["get_default"]();
            var versions = repository.enumerate_versions("WebKit2");

            if (versions.indexOf("4.1") !== -1) {
                return "4.1";
            }
            if (versions.indexOf("4.0") !== -1) {
                return "4.0";
            }
            throw new Error("WebKit2 introspection typelibs not found");
        },

        createMacDriver: function () {
            var ObjCRef = eval("ObjC");
            var dollar = eval("$");
            var app;
            var self = this;
            var messageCallback = null;
            var webViewRef = null;
            var windowDelegateRef = null;
            var scriptHandlerRef = null;
            var pendingPreload = null;

            return {
                webMessageTransport: "window.webkit.messageHandlers.neutrino.postMessage",
                transportName: "wkscriptmessage",
                init: function () {
                    ObjCRef["import"]("Cocoa");
                    ObjCRef["import"]("WebKit");
                    app = dollar.NSApplication.sharedApplication;
                    ObjCRef.registerSubclass({
                        name: "NeutrinoWindowDelegate",
                        superclass: "NSObject",
                        methods: {
                            "windowWillClose:": {
                                types: ["void", ["id"]],
                                implementation: function () {
                                    try { app.terminate(null); } catch (_) {}
                                }
                            }
                        }
                    });

                    /*
                     * A real message handler, replacing a timer that read
                     * document.title twenty times a second. The title was never
                     * a channel: it is a property of whatever document happens
                     * to be loaded, so any page in this webview -- including one
                     * it navigated to -- could set it and drive the native
                     * window. This has a sender attached to it, which is the
                     * thing the title could never have.
                     */
                    try {
                    ObjCRef.registerSubclass({
                        name: "NeutrinoScriptHandler",
                        superclass: "NSObject",
                        /*
                         * No protocols key. Declaring WKScriptMessageHandler
                         * here fails with "protocol does not exist": a protocol
                         * only exists as a runtime object if something in the
                         * process references it, and nothing in an osascript
                         * process does. Conformance is not what makes this
                         * work in any case -- the content controller sends the
                         * selector, and a class that implements it answers.
                         * NeutrinoWindowDelegate above is an NSWindowDelegate
                         * on exactly the same terms.
                         */
                        methods: {
                            "userContentController:didReceiveScriptMessage:": {
                                types: ["void", ["id", "id"]],
                                implementation: function (_, message) {
                                    try {
                                        if (!messageCallback) {
                                            return;
                                        }
                                        self.trace("message handler fired");
                                        if (!self.isTrustedMacSender(ObjCRef, message, webViewRef)) {
                                            return;
                                        }
                                        messageCallback(ObjCRef.unwrap(message.body));
                                    } catch (_) {}
                                }
                            }
                        }
                    });
                    } catch (e) {
                        self.note("could not register the message handler: " + e);
                    }
                },
                readFile: function (path) {
                    var data = dollar.NSData.dataWithContentsOfFile(path);
                    if (!data) {
                        throw new Error("Could not read local document: " + path);
                    }
                    var nsStr = dollar.NSString.alloc.initWithDataEncoding(data, dollar.NSUTF8StringEncoding);
                    if (!nsStr) {
                        throw new Error("Could not decode local document as UTF-8: " + path);
                    }
                    return ObjCRef.unwrap(nsStr);
                },
                getScriptPath: function () {
                    return self.getMacScriptPath(ObjCRef, dollar);
                },
                createWindow: function (config) {
                    var frame = dollar.NSMakeRect(0, 0, config.width, config.height);
                    var win = dollar.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
                        frame,
                        dollar.NSTitledWindowMask | dollar.NSClosableWindowMask | dollar.NSResizableWindowMask,
                        dollar.NSBackingStoreBuffered,
                        false
                    );
                    win.title = config.title + " - macOS";
                    try { win.center(); } catch (_) {}
                    windowDelegateRef = dollar.NeutrinoWindowDelegate.alloc.init;
                    win["delegate"] = windowDelegateRef;
                    this.writeStatus(config.title + " - macOS", win);
                    return win;
                },
                createWebView: function () {
                    var frame = dollar.NSMakeRect(0, 0, 100, 100);
                    var wkConfig = dollar.WKWebViewConfiguration.alloc.init;

                    /*
                     * Every call in here goes through the ObjC bridge, and a
                     * bridge that does not expose one of them throws. Letting
                     * that propagate means no window at all, which is the least
                     * informative thing that can happen -- there is nothing on
                     * screen and nothing said. Degrading instead leaves a
                     * window with no channel into it, which is inert rather
                     * than dangerous, and says which call was missing.
                     */
                    try {
                        var ucc = dollar.WKUserContentController.alloc.init;

                        if (messageCallback) {
                            scriptHandlerRef = dollar.NeutrinoScriptHandler.alloc.init;
                            ucc.addScriptMessageHandlerName(scriptHandlerRef, "neutrino");
                        }

                        // Injected by the engine rather than spliced into the
                        // markup, so the preload does not have to be something
                        // the document's content policy is asked to permit.
                        if (pendingPreload) {
                            ucc.addUserScript(
                                dollar.WKUserScript.alloc
                                    .initWithSourceInjectionTimeForMainFrameOnly(
                                        pendingPreload, 0, true
                                    )
                            );
                        }

                        wkConfig.userContentController = ucc;
                        self.trace("message channel wired, preload " +
                            (pendingPreload ? "injected" : "MISSING"));
                    } catch (e) {
                        self.note("no message channel: " + e);
                    }

                    var wv = dollar.WKWebView.alloc.initWithFrameConfiguration(frame, wkConfig);
                    try { wv.allowsLinkPreview = false; } catch (_) {}
                    webViewRef = wv;
                    return wv;
                },

                injectPreload: function (_, js) {
                    pendingPreload = js;
                },
                screenHeight: function () {
                    return dollar.NSScreen.mainScreen.frame.size.height;
                },
                toMacY: function (y, winHeight) {
                    return this.screenHeight() - y - winHeight;
                },
                toTopLeftY: function (macY, winHeight) {
                    return this.screenHeight() - macY - winHeight;
                },
                writeStatus: function (title, win) {
                    // Scaffolding for verify-macos.sh, which has no other way to
                    // read a window's geometry back. It is not part of running an
                    // app, so a release build does not write it anywhere.
                    if (!self.hasTier("testing")) {
                        return;
                    }
                    try {
                        var f = win.frame;
                        var topLeftY = Math.round(this.toTopLeftY(f.origin.y, f.size.height));
                        var status = title + "\n" +
                            Math.round(f.size.width) + "x" + Math.round(f.size.height) + "\n" +
                            Math.round(f.origin.x) + "," + topLeftY;
                        var statusPath = dollar.NSTemporaryDirectory().js + "neutrino-title.txt";
                        dollar.NSString.alloc.initWithUTF8String(status)
                            .writeToFileAtomicallyEncodingError(statusPath, true, 4, null);
                    } catch (_) {}
                },
                setTitle: function (win, title) {
                    win.title = title;
                    this.writeStatus(title, win);
                },
                resize: function (win, w, h) {
                    var frame = win.frame;
                    win.setFrameDisplay(dollar.NSMakeRect(frame.origin.x, frame.origin.y, w, h), true);
                    this.writeStatus(String(win.title), win);
                },
                move: function (win, x, y) {
                    var frame = win.frame;
                    var macY = this.toMacY(y, frame.size.height);
                    win.setFrameDisplay(dollar.NSMakeRect(x, macY, frame.size.width, frame.size.height), true);
                    this.writeStatus(String(win.title), win);
                },
                "close": function (win) {
                    win.performClose(null);
                },
                openExternal: function (url) {
                    if (!self.isExternalUrl(url)) {
                        return;
                    }
                    dollar.NSWorkspace.sharedWorkspace.openURL(
                        dollar.NSURL.URLWithString(String(url))
                    );
                },
                onWebMessage: function (cb) {
                    messageCallback = cb;
                },
                attachWebView: function (win, wv) {
                    win.contentView = wv;
                },
                loadHTML: function (wv, html, basePath) {
                    var baseUrl = dollar.NSURL.fileURLWithPath(basePath).URLByDeletingLastPathComponent;
                    self.trace("loading " + html.length + " bytes with base " + basePath);
                    wv.loadHTMLStringBaseURL(html, baseUrl);
                },
                showWindow: function (win) {
                    win.makeKeyAndOrderFront(null);
                    try { app.activateIgnoringOtherApps(true); } catch (_) {}
                },
                runEventLoop: function () {
                    dollar.NSApp.setActivationPolicy(0);
                    app.run();
                }
            };
        },

        createGjsDriver: function () {
            var importsRef = eval("imports");
            var Gtk, WebKit2, GLib, ByteArray;
            var self = this;
            var messageCallback = null;
            var pendingPreload = null;
            var documentLoaded = false;

            return {
                webMessageTransport: "window.webkit.messageHandlers.neutrino.postMessage",
                transportName: "scriptmessage",
                init: function () {
                    importsRef["gi"]["versions"]["Gtk"] = "3.0";
                    importsRef["gi"]["versions"]["WebKit2"] = self.resolveLinuxWebKitVersion();
                    Gtk = importsRef["gi"]["Gtk"];
                    WebKit2 = importsRef["gi"]["WebKit2"];
                    GLib = importsRef["gi"]["GLib"];
                    ByteArray = importsRef["byteArray"];
                    Gtk.init(null);

                    /*
                     * WebKitGTK's own bubblewrap sandbox is opt-in, and until
                     * now neutrino never opted in -- so the process rendering
                     * whatever the page contains had nothing around it at all.
                     * This is the protection against hostile page content, and
                     * it is a different thing from netinstall's protection
                     * against the app's author.
                     *
                     * The two do not compose on Linux. netinstall's Landlock
                     * denies mount to any domain handling a filesystem right,
                     * and PR_SET_NO_NEW_PRIVS is required for Landlock, so
                     * under netinstall bubblewrap cannot initialise here. That
                     * trade is netinstall's README to explain; what this file
                     * can do is stop giving up the sandbox for nothing when it
                     * runs on its own, which is the normal case.
                     */
                    /*
                     * WebKitGTK's sandbox is bubblewrap, and bubblewrap needs
                     * an unprivileged user namespace. Whether it can have one
                     * is not a property of this program: Ubuntu 24.04 and its
                     * derivatives set kernel.apparmor_restrict_unprivileged_-
                     * userns to 1 and refuse, while the same kernel version
                     * elsewhere allows it -- netinstall's README records the
                     * same split for the same reason, and its test suite has to
                     * lift that knob to exercise the session tier at all.
                     *
                     * It also does not degrade when it cannot start. The web
                     * process simply fails and the window comes up empty, which
                     * is a worse outcome than not having asked. And it cannot
                     * be probed honestly beforehand: the helper is resolved by
                     * an absolute path compiled into WebKitGTK, so looking for
                     * it on PATH answers a different question than the one
                     * being asked.
                     *
                     * So it is asked for, and taken back if it does not arrive.
                     * That covers every reason it might not -- a missing
                     * helper, a refused namespace, a seccomp filter in front of
                     * clone -- rather than the one reason a probe could name.
                     */
                    if (GLib.getenv("NEUTRINO_WEBKIT_SANDBOX") === "1") {
                        try {
                            WebKit2.WebContext.get_default().set_sandbox_enabled(true);
                        } catch (e) {
                            self.note("webkit sandbox unavailable: " + e);
                        }
                    } else {
                        self.note("webkit sandbox off: this system refused a user namespace");
                    }
                },
                readFile: function (path) {
                    var result = GLib.file_get_contents(path);
                    if (!result[0]) {
                        throw new Error("Could not read local document: " + path);
                    }
                    return ByteArray.toString(result[1]);
                },
                getScriptPath: function () {
                    return self.getLinuxScriptPath(importsRef);
                },
                createWindow: function (config) {
                    var win = new Gtk.Window({
                        title: config.title + " - Linux",
                        default_width: config.width,
                        default_height: config.height
                    });
                    win.set_position(Gtk.WindowPosition.CENTER);
                    win.connect("destroy", function () { Gtk.main_quit(); });
                    return win;
                },
                createWebView: function () {
                    var ucm = new WebKit2.UserContentManager();
                    if (messageCallback) {
                        ucm.register_script_message_handler("neutrino");
                        ucm.connect("script-message-received::neutrino", function (_, result) {
                            messageCallback(result.get_js_value().to_string());
                        });
                    }

                    if (pendingPreload) {
                        // Injected by the engine rather than spliced into the
                        // markup, so the preload does not have to be something
                        // the document's own content policy is asked to permit.
                        try {
                            ucm.add_script(WebKit2.UserScript["new"](
                                pendingPreload,
                                WebKit2.UserContentInjectedFrames.TOP_FRAME,
                                WebKit2.UserScriptInjectionTime.START,
                                null,
                                null
                            ));
                        } catch (_) {}
                    }

                    var wv = new WebKit2.WebView({ user_content_manager: ucm });
                    wv.connect("load-changed", function (_, loadEvent) {
                        if (loadEvent === WebKit2.LoadEvent.FINISHED) {
                            documentLoaded = true;
                        }
                    });

                    var settings = wv.get_settings();
                    try {
                        settings.set_enable_developer_extras(false);
                        settings.set_allow_file_access_from_file_urls(false);
                        settings.set_allow_universal_access_from_file_urls(false);
                        settings.set_javascript_can_access_clipboard(false);
                        settings.set_enable_write_console_messages_to_stdout(false);
                    } catch (_) {}

                    /*
                     * The document is loaded once, from this file, and never
                     * navigates again. Without this a link or a location
                     * assignment could replace it with a remote origin, and
                     * that origin would then be holding the channel to the
                     * native window -- the preload is registered on the user
                     * content manager, so it would be reinjected into whatever
                     * document arrived next.
                     */
                    var driverRef = this;
                    wv.connect("decide-policy", function (_, decision, decisionType) {
                        var types = WebKit2.PolicyDecisionType;
                        if (decisionType !== types.NAVIGATION_ACTION &&
                            decisionType !== types.NEW_WINDOW_ACTION) {
                            return false;
                        }
                        var uri = "";
                        try {
                            uri = String(decision.get_navigation_action().get_request().get_uri());
                        } catch (_) {
                            uri = "";
                        }
                        // Until the first document has finished loading, the
                        // only navigation in flight is the one this file
                        // started. Keying on that rather than only on the url
                        // means an engine that spells the initial load
                        // differently cannot lock the app out of its own
                        // document.
                        if (!documentLoaded || self.isOwnDocument(uri)) {
                            return false;
                        }
                        decision.ignore();
                        self.note("refused navigation to " + uri);
                        driverRef.openExternal(uri);
                        return true;
                    });
                    return wv;
                },
                setTitle: function (win, title) {
                    win.set_title(title);
                },
                resize: function (win, w, h) {
                    win.resize(w, h);
                },
                move: function (win, x, y) {
                    win.move(x, y);
                },
                openExternal: function (url) {
                    // Checked here as well as in the splitter: this is the end
                    // of the line, and it hands a string to the desktop's URI
                    // handler, which will happily act on file: or on a .desktop
                    // entry if it is given one.
                    if (!self.isExternalUrl(url)) {
                        return;
                    }
                    try {
                        var Gio = importsRef["gi"]["Gio"];
                        Gio.AppInfo.launch_default_for_uri(String(url), null);
                    } catch (_) {
                        // An argv, never a command line. The old fallback built
                        // "xdg-open " + url and handed it to a function that
                        // word-splits, so a url containing a space became two
                        // arguments and a url containing a quote became
                        // something else entirely.
                        try {
                            GLib.spawn_async(
                                null,
                                ["xdg-open", String(url)],
                                null,
                                GLib.SpawnFlags.SEARCH_PATH,
                                null
                            );
                        } catch (_) {}
                    }
                },
                "close": function (win) {
                    win.destroy();
                },
                onWebMessage: function (cb) {
                    messageCallback = cb;
                },
                injectPreload: function (_, js) {
                    pendingPreload = js;
                },
                attachWebView: function (win, wv) {
                    win.add(wv);
                },
                loadHTML: function (wv, html) {
                    wv.load_html(html, null);
                },
                showWindow: function (win) {
                    win.show_all();
                },
                runEventLoop: function () {
                    Gtk.main();
                }
            };
        },

        /*
         * Everything arriving on this channel was written by whatever page the
         * webview is currently showing, which makes it attacker-controlled text
         * by definition. It used to be handed to eval, which on gjs meant
         * evaluating that text in a scope holding imports.gi.GLib and Gio.
         *
         * The fix is not a JSON parser. The action set is fixed, flat and tiny,
         * so the host does not parse a message, it splits one: each action has a
         * known arity, and any free-form field is always last and takes the rest
         * of the string verbatim. A separator inside a title therefore cannot
         * invent an extra field, nothing needs escaping, and JScript.NET not
         * having a JSON global stops being a problem worth solving.
         */
        messageSeparator: String.fromCharCode(31),

        hasControlCharacters: function (value) {
            var text = String(value);
            for (var i = 0; i < text.length; i++) {
                var code = text.charCodeAt(i);
                if (code < 32 || code === 127) {
                    return true;
                }
            }
            return false;
        },

        isCoordinate: function (value) {
            return /^-?[0-9]{1,6}$/.test(String(value));
        },

        isDimension: function (value) {
            return /^[0-9]{1,6}$/.test(String(value)) && parseInt(String(value), 10) > 0;
        },

        /*
         * An allowlist, so every scheme this does not name is refused without
         * having to be enumerated -- file:, javascript:, data:, ms-settings:,
         * search-ms:, and whichever one the platform invents next. This matters
         * more than it looks: on Windows the other end of openExternal is
         * Process.Start, and on Linux it is the desktop's URI handler.
         */
        isExternalUrl: function (value) {
            var url = String(value == null ? "" : value);
            if (!url || url.length > 2048 || this.hasControlCharacters(url)) {
                return false;
            }
            return /^https?:\/\/[^\/?#]/i.test(url) || /^mailto:[^@\s]+@[^@\s]+$/i.test(url);
        },

        /*
         * The document is loaded from this file, so it has no origin of its own
         * and every engine here reports it as about:blank. Anything else is a
         * navigation away from it.
         *
         * data: is deliberately not on this list. A data: document is same-null-
         * origin, so it would inherit the injected channel to the native window
         * while carrying content this file never wrote.
         */
        /*
         * A refusal that leaves no trace is indistinguishable from a window that
         * simply never came up, and those want opposite fixes. eval, because
         * JScript.NET resolves globals at compile time and has neither of these
         * -- the same reason the README gives for eval("window").
         */
        note: function (message) {
            try {
                eval("printerr")("neutrino: " + message);
                return;
            } catch (_) {}
            try {
                eval("console").warn("neutrino: " + message);
                return;
            } catch (_) {}
            try {
                eval("console").log("neutrino: " + message);
            } catch (_) {}
        },

        /*
         * A note worth making in a release build is a refusal or a failure.
         * Anything that is only interesting while working out why a lane is red
         * belongs here instead, where a release build never says it.
         */
        trace: function (message) {
            if (this.hasTier("testing")) {
                this.note(message);
            }
        },

        isOwnDocument: function (url) {
            var u = String(url == null ? "" : url);
            return u === "" || u === "about:blank";
        },

        /*
         * A note worth making in a release build is a refusal or a failure.
         * Anything that is only interesting while working out why a lane is red
         * belongs here instead, where a release build never says it.
         */
        trace: function (message) {
            if (this.hasTier("testing")) {
                this.note(message);
            }
        },

        isOwnDocument: function (url) {
            var u = String(url == null ? "" : url);
            return u === "" || u === "about:blank";
        },

        /*
         * What counts as the app's own document is not the same on every
         * engine, and getting that wrong is silent in the worst way: gjs loads
         * with a null base url and its document has no origin at all, while
         * this driver loads with the script's directory as a file: base so that
         * an app's relative assets resolve. Demanding an empty scheme therefore
         * refused every message the app itself sent, and left a window that
         * came up and then did nothing.
         *
         * So the rule is about the host, not the scheme: a document that can
         * speak to the network has one, and neither of these has one. A page
         * the webview navigated to somewhere remote is refused, which is the
         * escape worth closing.
         *
         * The origin alone is not enough, though, because a data: document has
         * no origin either -- it is the one navigation an origin check cannot
         * tell from the app's own document, and the preload here is a user
         * script the engine reinjects into whatever loads next, so the page
         * that arrives inherits the whole API. So what the view is currently
         * showing is checked as well, which is a question a message cannot lie
         * about.
         *
         * The residual left is another file: document, which is local content
         * rather than a remote origin.
         */
        isTrustedOrigin: function (scheme, host) {
            var s = String(scheme == null ? "" : scheme);
            var h = String(host == null ? "" : host);
            return h === "" && (s === "" || s === "file");
        },

        isTrustedMacSender: function (ObjCRef, message, webView) {
            // What the view is showing, independent of what the message claims.
            // Fails open on a bridge that will not answer, for the same reason
            // the origin check does: refusing every message leaves a window
            // that does nothing and says nothing about why.
            try {
                var current = webView.URL;
                if (current) {
                    var currentScheme = String(ObjCRef.unwrap(current.scheme) || "");
                    if (!this.isTrustedOrigin(currentScheme, "")) {
                        this.note("refused a message from a document at " +
                            currentScheme + ":");
                        return false;
                    }
                }
            } catch (_) {}

            var frame = null;
            try {
                frame = message.frameInfo;
                if (!frame.isMainFrame) {
                    this.note("refused a message from a subframe");
                    return false;
                }
            } catch (e) {
                this.note("refused a message with no frame: " + e);
                return false;
            }

            /*
             * The real protection is here: a document the webview navigated to
             * has a scheme, and the document this file loads does not. Reading
             * the origin is kept separate from reading the frame because the
             * two fail differently -- a frame that cannot be read is a message
             * with no sender and is refused, while an origin that cannot be
             * read is this bridge not exposing something it was expected to,
             * which is a reason to say so rather than to refuse every message
             * the app ever sends and leave a window that does nothing.
             */
            try {
                var origin = frame.securityOrigin;
                var scheme = String(ObjCRef.unwrap(origin.protocol) || "");
                var host = String(ObjCRef.unwrap(origin.host) || "");
                if (this.isTrustedOrigin(scheme, host)) {
                    return true;
                }
                this.note("refused a message from " + scheme + "://" + host);
                return false;
            } catch (e) {
                this.note("could not read the sender's origin: " + e);
                return true;
            }
        },

        parseMessage: function (raw) {
            var text = String(raw == null ? "" : raw);
            if (text.length > 4096) {
                return null;
            }

            var sep = this.messageSeparator;
            var cut = text.indexOf(sep);
            var action = (cut < 0) ? text : text.substring(0, cut);
            var rest = (cut < 0) ? null : text.substring(cut + 1);

            if (action === "close") {
                return (rest === null) ? { action: "close" } : null;
            }

            if (action === "setTitle") {
                if (rest === null || rest.length > 1024 || this.hasControlCharacters(rest)) {
                    return null;
                }
                return { action: "setTitle", title: rest };
            }

            if (action === "openExternal") {
                if (rest === null || !this.isExternalUrl(rest)) {
                    return null;
                }
                return { action: "openExternal", url: rest };
            }

            if (action === "resize" || action === "move") {
                if (rest === null) {
                    return null;
                }
                var parts = rest.split(sep);
                if (parts.length !== 2) {
                    return null;
                }
                if (action === "resize") {
                    if (!this.isDimension(parts[0]) || !this.isDimension(parts[1])) {
                        return null;
                    }
                    return {
                        action: "resize",
                        width: parseInt(parts[0], 10),
                        height: parseInt(parts[1], 10)
                    };
                }
                if (!this.isCoordinate(parts[0]) || !this.isCoordinate(parts[1])) {
                    return null;
                }
                return { action: "move", x: parseInt(parts[0], 10), y: parseInt(parts[1], 10) };
            }

            return null;
        },

        buildPreloadScript: function (transport, name) {
            return '(function(){' +
                'var S=String.fromCharCode(31);' +
                'var _send=function(m){try{(' + transport + ')(m);}catch(_){}};' +
                'var _n=function(v){return String(v===undefined||v===null?"":v);};' +
                'window.neutrino={' +
                // Which channel the host is actually listening on. The page can
                // work this out by feature detection anyway, so naming it costs
                // nothing and lets a test report it instead of inferring it.
                'transport:"' + String(name || "unknown") + '",' +
                'send:function(action,data){' +
                'var d=data||{};' +
                'if(action==="setTitle")_send("setTitle"+S+_n(d.title));' +
                'else if(action==="resize")_send("resize"+S+_n(d.width)+S+_n(d.height));' +
                'else if(action==="move")_send("move"+S+_n(d.x)+S+_n(d.y));' +
                'else if(action==="openExternal")_send("openExternal"+S+_n(d.url));' +
                'else if(action==="close")_send("close");' +
                '},' +
                'shell:{' +
                'openExternal:function(url){window.neutrino.send("openExternal",{url:url});}' +
                '},' +
                'window:{' +
                'setTitle:function(t){window.neutrino.send("setTitle",{title:t});},' +
                'resize:function(w,h){window.neutrino.send("resize",{width:w,height:h});},' +
                'move:function(x,y){window.neutrino.send("move",{x:x,y:y});},' +
                'close:function(){window.neutrino.send("close");}' +
                '}' +
                '};' +
                '})();';
        },

        routeMessage: function (actions, raw) {
            var msg = this.parseMessage(raw);
            if (msg && actions[msg.action]) {
                actions[msg.action](msg);
            }
        },

        /*
         * The app's own JavaScript is an inline script inside this document --
         * that is what the polyglot is -- so script-src has to permit inline
         * and there is no version of this that does not. What the default
         * policy is good for is the rest: no plugins, no base tag rewriting
         * where every relative url points, no form posting somewhere else, no
         * framing.
         *
         * Denying the page the network is a real change to what an app can do,
         * so it is the offline tier's business and not the default's. An app
         * that fetches from its own backend is an ordinary app, not a
         * misbehaving one.
         */
        defaultContentPolicy: "object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'",

        offlineContentPolicy: "default-src 'none'; script-src 'unsafe-inline'; " +
            "style-src 'unsafe-inline'; img-src data:; font-src data:; " +
            "object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'",

        applyContentPolicy: function (html) {
            if (!this.hasTier("offline")) {
                return html;
            }
            // Anchored on the attribute, so it cannot match this file's own
            // mention of the policy string further down the document -- the
            // whole script region is inside the document it is describing.
            return String(html).replace(
                'content="' + this.defaultContentPolicy + '"',
                'content="' + this.offlineContentPolicy + '"'
            );
        },

        boot: function (driver, config) {
            driver.init();
            var scriptPath = driver.getScriptPath();
            var html = this.applyContentPolicy(this.extractHtmlDocument(driver.readFile(scriptPath)));

            var win = driver.createWindow(config);

            if (driver.onWebMessage) {
                var self = this;
                var driverRef = driver;
                var winRef = win;
                var actions = {};
                if (driverRef.setTitle) actions.setTitle = function (m) { try { driverRef.setTitle(winRef, m.title); } catch (_) {} };
                if (driverRef.resize) actions.resize = function (m) { try { driverRef.resize(winRef, m.width, m.height); } catch (_) {} };
                if (driverRef.move) actions.move = function (m) { try { driverRef.move(winRef, m.x, m.y); } catch (_) {} };
                if (typeof driverRef["close"] === "function") actions["close"] = function (m) { try { driverRef["close"](winRef); } catch (_) {} };
                if (driverRef.openExternal) actions.openExternal = function (m) { try { driverRef.openExternal(m.url); } catch (_) {} };
                driver.onWebMessage(function (json) {
                    self.routeMessage(actions, json);
                });
            }

            /*
             * Every driver injects through its engine now, so the preload is
             * never spliced into the markup as text. The old splice looked for
             * a literal "<head>" and silently injected nothing when it did not
             * find one, which meant the API could go missing without anything
             * saying so.
             */
            if (driver.webMessageTransport) {
                driver.injectPreload(null, this.buildPreloadScript(
                    driver.webMessageTransport, driver.transportName));
            }

            var wv = driver.createWebView();

            driver.loadHTML(wv, html, scriptPath);
            driver.attachWebView(win, wv);
            driver.showWindow(win);
            driver.runEventLoop(win, wv);
        },

        runMacOS: function () {
            // Any one of the bridge calls in this driver failing leaves no
            // window at all, which is the least informative outcome available.
            try {
                this.boot(this.createMacDriver(), this.config);
            } catch (e) {
                this.note("could not start: " + e);
                throw e;
            }
        },

        runGjs: function () {
            this.boot(this.createGjsDriver(), this.config);
        },

        hasWebView2Assemblies: function (SystemRef, libDir) {
            if (!libDir) {
                return false;
            }
            return SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.Core.dll")) &&
                SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.WinForms.dll"));
        },

        findWebView2LibDir: function (SystemRef, appFolder) {
            /*
             * This is an environment variable that ends at Assembly.LoadFrom,
             * so anything able to set it chooses which code this process loads.
             * netinstall's environment allowlist keeps the whole NEUTRINO_
             * prefix, so it arrives intact even there. A release build does not
             * read it; the tests that need to point at a prepared package build
             * with the testing tier.
             */
            var envLibDir = this.hasTier("testing")
                ? SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR")
                : null;
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

        /*
         * The package is ~45 MB unpacked and almost all of it is native build
         * headers and import libs for C++ hosts. Only the managed assemblies
         * and the loaders are ever used, so extract those and skip the rest.
         * The pattern avoids backslashes so it survives being embedded here.
         */
        webView2KeepPattern: "^(lib/net4[0-9]+/[^/]+[.]dll|runtimes/win-(x86|x64|arm64)/native/WebView2Loader[.]dll)$",

        extractArchiveWithPowerShell: function (SystemRef, archivePath, destinationPath) {
            var psCommand = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; " +
                "Add-Type -AssemblyName System.IO.Compression.FileSystem; " +
                "$src='" + this.escapeForSingleQuotedPowerShell(String(archivePath)) + "'; " +
                "$dst='" + this.escapeForSingleQuotedPowerShell(String(destinationPath)) + "'; " +
                "$keep='" + this.webView2KeepPattern + "'; " +
                "$zip=[System.IO.Compression.ZipFile]::OpenRead($src); " +
                "try { foreach ($e in $zip.Entries) { if ($e.FullName -match $keep) { " +
                "$out=Join-Path $dst ($e.FullName.Replace([char]47,[char]92)); " +
                "$dir=Split-Path -Parent $out; " +
                "if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }; " +
                "[System.IO.Compression.ZipFileExtensions]::ExtractToFile($e,$out,$true) } } } " +
                "finally { $zip.Dispose() }";

            var encodedCommand = SystemRef.Convert.ToBase64String(SystemRef.Text.Encoding.Unicode.GetBytes(psCommand));

            var startInfo = new SystemRef.Diagnostics.ProcessStartInfo();
            startInfo.FileName = "powershell.exe";
            startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encodedCommand;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;

            var process = SystemRef.Diagnostics.Process.Start(startInfo);
            process.WaitForExit();

            if (process.ExitCode !== 0) {
                throw new Error("WebView2 package extraction failed with exit code " + process.ExitCode + ".");
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

                /*
                 * TLS 1.0 and 1.1 were enabled here alongside 1.2. Turning a
                 * protocol on does not make a server offer it, but it does mean
                 * this client would accept one that did, which is the whole
                 * point of a downgrade. nuget.org has not spoken either of them
                 * for years. 1.3 is set where the framework knows the value and
                 * ignored where it does not.
                 */
                try {
                    var tls12 = 3072;
                    var tls13 = 12288;
                    SystemRef.Net.ServicePointManager.SecurityProtocol = tls12 | tls13;
                } catch (_) {
                    try {
                        SystemRef.Net.ServicePointManager.SecurityProtocol = 3072;
                    } catch (_) {
                    }
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

        /*
         * Reached by reflection because the type comes from an assembly loaded
         * at run time, and set one at a time so that a runtime too old to know
         * one property still gets the others. None of these are a sandbox --
         * WebView2 sandboxes its own renderers and that is the real boundary --
         * they close the doors this app has no use for.
         */
        hardenWebView2: function (coreWv2) {
            var settings = null;
            try {
                settings = coreWv2.GetType().GetProperty("Settings").GetValue(coreWv2, null);
            } catch (_) {
                return;
            }
            if (!settings) {
                return;
            }

            var off = [
                "AreDevToolsEnabled",
                "AreDefaultContextMenusEnabled",
                "AreHostObjectsAllowed",
                "IsStatusBarEnabled",
                "IsSwipeNavigationEnabled",
                "AreBrowserAcceleratorKeysEnabled",
                "IsGeneralAutofillEnabled",
                "IsPasswordAutosaveEnabled",
                "IsPinchZoomEnabled"
            ];

            for (var i = 0; i < off.length; i++) {
                try {
                    var prop = settings.GetType().GetProperty(off[i]);
                    if (prop && prop.CanWrite) {
                        prop.SetValue(settings, false, null);
                    }
                } catch (_) {}
            }
        },

        /*
         * Subscribe to CoreWebView2.WebMessageReceived. Everything here is
         * reflection because the types arrive with an assembly loaded at run
         * time, and the delegate is built by CreateDelegate against the event's
         * own handler type for the same reason.
         *
         * Returns true only if the subscription actually took. The caller keeps
         * reading the document title when it did not, because a Windows build
         * with no channel at all is worse than one with a channel a page can
         * write to -- but it is a real downgrade, so it is named in the report
         * rather than left to be inferred.
         */
        wireWebView2Messages: function (SystemRef, coreWv2) {
            try {
                var evt = coreWv2.GetType().GetEvent("WebMessageReceived");
                if (!evt) {
                    return false;
                }
                var sink = new NeutrinoWebMessageSink();
                var handler = SystemRef.Delegate.CreateDelegate(
                    evt.EventHandlerType, sink, sink.GetType().GetMethod("Handle")
                );
                evt.AddEventHandler(coreWv2, handler);
                return true;
            } catch (_) {
                return false;
            }
        },

        // The event args carry both the text and who sent it. Source is the url
        // of the document that called postMessage, and the document this file
        // loads through NavigateToString has none worth the name -- so a
        // message from anywhere else is from a page that was navigated to.
        readWebView2Message: function (args) {
            var source = "";
            try {
                source = String(args.GetType().GetProperty("Source").GetValue(args, null) || "");
            } catch (_) {
                return null;
            }
            if (!this.isOwnDocument(source)) {
                return null;
            }
            try {
                return String(args.GetType().GetMethod("TryGetWebMessageAsString").Invoke(args, null));
            } catch (_) {
                return null;
            }
        },

        createWindowsDriver: function () {
            var SystemRef = eval("System");
            var webViewWinFormsAssembly, webViewType;
            var appFolder, userDataDir;
            var self = this;
            var messageCallback = null;
            var lastDocTitle = "";
            var pendingPreload = null;
            var settingsApplied = false;
            var webMessagesWired = false;

            return {
                /*
                 * A placeholder. Which transport the page is given cannot be
                 * decided here, because it depends on whether the event
                 * subscription takes, and CoreWebView2 does not exist until the
                 * event loop is running. So the preload is rebuilt there and
                 * this only has to be non-empty for boot to ask for one at all.
                 *
                 * Where it does end up being the title, the record is encoded:
                 * a record separator is a control character and a window title
                 * is not a faithful carrier for those.
                 */
                webMessageTransport: "function(m){document.title='__NEUTRINO__'+encodeURIComponent(m);}",
                transportName: "title",
                init: function () {
                    SystemRef.Windows.Forms.Application.EnableVisualStyles();
                    SystemRef.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);

                    appFolder = SystemRef.Windows.Forms.Application.StartupPath;
                    userDataDir = SystemRef.IO.Path.Combine(appFolder, "data");

                    var webView2LibDir = self.ensureWebView2Package(SystemRef, appFolder);
                    if (!webView2LibDir) {
                        SystemRef.Environment.Exit(1);
                        return;
                    }

                    SystemRef.Environment.SetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR", webView2LibDir);
                    self.prependLoaderPaths(SystemRef, webView2LibDir);

                    SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.Core.dll"));
                    webViewWinFormsAssembly = SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.WinForms.dll"));

                    webViewType = webViewWinFormsAssembly.GetType("Microsoft.Web.WebView2.WinForms.WebView2");
                    if (!webViewType) {
                        throw new Error("Could not load Microsoft.Web.WebView2.WinForms.WebView2 type.");
                    }
                },
                readFile: function (path) {
                    return SystemRef.IO.File.ReadAllText(path);
                },
                getScriptPath: function () {
                    var p = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH");
                    if (!p) {
                        throw new Error("Environment variable NEUTRINO_SCRIPT_PATH was not set.");
                    }
                    if (!SystemRef.IO.File.Exists(p)) {
                        throw new Error("Could not find local document: " + p);
                    }
                    return p;
                },
                createWindow: function (config) {
                    var win = new SystemRef.Windows.Forms.Form();
                    win.Text = config.title + " - Windows";
                    win.ClientSize = new SystemRef.Drawing.Size(config.width, config.height);
                    win.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;
                    return win;
                },
                createWebView: function () {
                    var wv = SystemRef.Activator.CreateInstance(webViewType);
                    if (userDataDir) {
                        try {
                            var cpType = webViewWinFormsAssembly.GetType("Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties");
                            if (cpType) {
                                var cp = SystemRef.Activator.CreateInstance(cpType);
                                try {
                                    cp.UserDataFolder = userDataDir;
                                    SystemRef.IO.Directory.CreateDirectory(cp.UserDataFolder);
                                    wv.CreationProperties = cp;
                                } catch (_) {}
                            }
                        } catch (_) {}
                    }
                    wv.Dock = SystemRef.Windows.Forms.DockStyle.Fill;
                    return wv;
                },
                attachWebView: function (win, wv) {
                    win.Controls.Add(wv);
                },
                loadHTML: function (wv, html) {
                    wv.Source = new SystemRef.Uri("about:blank");
                },
                setTitle: function (win, title) {
                    win.Text = title;
                },
                resize: function (win, w, h) {
                    win.ClientSize = new SystemRef.Drawing.Size(parseInt(w), parseInt(h));
                },
                move: function (win, x, y) {
                    win.Location = new SystemRef.Drawing.Point(parseInt(x), parseInt(y));
                },
                openExternal: function (url) {
                    // Process.Start on a bare string is ShellExecute, which will
                    // open a document, a .desktop-equivalent, or a registered
                    // protocol handler just as happily as a web page. The
                    // allowlist is what keeps it to web pages.
                    if (!self.isExternalUrl(url)) {
                        return;
                    }
                    var info = new SystemRef.Diagnostics.ProcessStartInfo(String(url));
                    info.UseShellExecute = true;
                    SystemRef.Diagnostics.Process.Start(info);
                },
                showWindow: function () {},
                // Quoted for the same reason boot() reaches for it that way:
                // jsc.exe is stricter than the other three engines about names
                // that look like they might mean something.
                "close": function (win) {
                    win.Close();
                },
                onWebMessage: function (cb) {
                    messageCallback = cb;
                },
                injectPreload: function (wv, js) {
                    pendingPreload = js;
                },
                runEventLoop: function (win, wv) {
                    win.Show();
                    var coreWv2 = null;
                    var titleProp = null;
                    var preloadInjected = false;
                    while (win.Visible) {
                        SystemRef.Windows.Forms.Application.DoEvents();
                        SystemRef.Threading.Thread.Sleep(16);
                        try {
                            if (!coreWv2 && wv) {
                                var coreWv2Prop = wv.GetType().GetProperty("CoreWebView2");
                                if (coreWv2Prop) {
                                    coreWv2 = coreWv2Prop.GetValue(wv, null);
                                }
                            }
                            if (coreWv2 && !settingsApplied) {
                                settingsApplied = true;
                                self.hardenWebView2(coreWv2);

                                // Before the preload is built, because what the
                                // page is told to send on depends on whether
                                // this took.
                                webMessagesWired = self.wireWebView2Messages(SystemRef, coreWv2);
                                pendingPreload = self.buildPreloadScript(
                                    webMessagesWired
                                        ? "function(m){window.chrome.webview.postMessage(m);}"
                                        : "function(m){document.title='__NEUTRINO__'+encodeURIComponent(m);}",
                                    webMessagesWired ? "webmessage" : "title"
                                );
                            }
                            if (coreWv2 && pendingPreload && !preloadInjected) {
                                preloadInjected = true;
                                var addScript = coreWv2.GetType().GetMethod("AddScriptToExecuteOnDocumentCreatedAsync");
                                if (addScript) {
                                    var task = addScript.Invoke(coreWv2, [pendingPreload]);
                                    if (task) {
                                        while (!task.IsCompleted) {
                                            SystemRef.Windows.Forms.Application.DoEvents();
                                            SystemRef.Threading.Thread.Sleep(10);
                                        }
                                    }
                                }
                                var navMethod = coreWv2.GetType().GetMethod("NavigateToString");
                                var scriptPath = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH");
                                if (navMethod && scriptPath && SystemRef.IO.File.Exists(scriptPath)) {
                                    var htmlText = self.extractHtmlDocument(SystemRef.IO.File.ReadAllText(scriptPath));
                                    navMethod.Invoke(coreWv2, [htmlText]);
                                }
                            }
                            if (coreWv2 && messageCallback && webMessagesWired) {
                                // Drained here rather than handled in the event
                                // itself: the queue is a .NET static, which no
                                // document can reach, so nothing is lost by
                                // reading it on the same clock as everything
                                // else in this loop.
                                while (NeutrinoWebMessageSink.queue.Count > 0) {
                                    var queued = NeutrinoWebMessageSink.queue[0];
                                    NeutrinoWebMessageSink.queue.RemoveAt(0);
                                    var text = self.readWebView2Message(queued);
                                    if (text !== null) {
                                        messageCallback(text);
                                    }
                                }
                            } else if (coreWv2 && messageCallback) {
                                if (!titleProp) {
                                    titleProp = coreWv2.GetType().GetProperty("DocumentTitle");
                                }
                                if (titleProp) {
                                    var docTitle = String(titleProp.GetValue(coreWv2, null) || "");
                                    if (docTitle !== lastDocTitle && docTitle.indexOf("__NEUTRINO__") === 0) {
                                        lastDocTitle = docTitle;
                                        try {
                                            messageCallback(decodeURIComponent(docTitle.substring(12)));
                                        } catch (_) {}
                                    }
                                }
                            }
                        } catch (_) {}
                    }
                },
                handleError: function (ex) {
                    var detail = "Failed to initialize WebView2 package/download.";
                    try {
                        if (ex && ex.message) {
                            detail = detail + "\n\n" + String(ex.message);
                        }
                    } catch (_) {}
                    self.showWindowsError(SystemRef, "neutrino", detail);
                    SystemRef.Environment.Exit(1);
                }
            };
        },

        runWindows: function () {
            var driver = this.createWindowsDriver();
            try {
                this.boot(driver, this.config);
            } catch (ex) {
                driver.handleError(ex);
            }
        }
    };

    NeutrinoWebview.run();

//</script></head><body></body>
