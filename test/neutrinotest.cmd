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

IF EXIST "%APP_FOLDER%\%SCRIPT_NAME%.exe" (
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

:START_APP
SET "NEUTRINO_SCRIPT_PATH=%~f0"
START "" /D "%APP_FOLDER%" "%APP_FOLDER%\%SCRIPT_NAME%.exe"
IF ERRORLEVEL 1 EXIT /B 1
EXIT /B 0
EXIT
script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
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

NeutrinoWebview.routeQmlMessage = function (jsonString) {
    var msg = null
    try { msg = eval("(" + jsonString + ")") } catch (_) { return }
    if (!msg || !msg.action || !_qmlRoot) return
    if (msg.action === "setTitle" && msg.title) _qmlRoot.title = msg.title
    else if (msg.action === "resize" && msg.width && msg.height) { _qmlRoot.width = msg.width; _qmlRoot.height = msg.height }
    else if (msg.action === "move" && msg.x !== undefined && msg.y !== undefined) { _qmlRoot.x = msg.x; _qmlRoot.y = msg.y }
    else if (msg.action === "openExternal" && msg.url && _qt) _qt.openUrl(msg.url)
}

NeutrinoWebview.qmlPreloadScript = NeutrinoWebview.buildPreloadScript(
    'function(m){console.log("__NEUTRINO__"+m);}'
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
        onLoadingChanged: function(info) {
            if (!preloadInjected && info.status === WebEngineView.LoadSucceededStatus) {
                preloadInjected = true
                view.runJavaScript(Neutrino.NeutrinoWebview.qmlPreloadScript)
            }
        }
        onJavaScriptConsoleMessage: function(level, message, lineNumber, sourceID) {
            if (message.indexOf("__NEUTRINO__") === 0) {
                Neutrino.NeutrinoWebview.routeQmlMessage(message.substring(12))
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
    [ "$QTWEBENGINE_DISABLE_SANDBOX" = "1" ] && QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS} --no-sandbox"

    QML_XHR_ALLOW_FILE_READ=1 \
    QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}" \
    LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}" \
    QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS:---disable-dev-shm-usage}" \
    "$qml_runner" "$app_qml"
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
<!doctype html><html><head><meta charset="utf-8"><style> html, body { background: white; color: black; font-size: 2em; }</style></head>
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
    win.setTimeout(runNext, 1000);
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

        createMacDriver: function () {
            var ObjCRef = eval("ObjC");
            var dollar = eval("$");
            var app;
            var self = this;
            var messageCallback = null;
            var lastDocTitle = "";
            var webViewRef = null;
            var windowDelegateRef = null;

            return {
                webMessageTransport: "function(m){document.title='__NEUTRINO__'+m;}",
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
                    var wv = dollar.WKWebView.alloc.initWithFrameConfiguration(frame, wkConfig);
                    webViewRef = wv;
                    return wv;
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
                    dollar.NSWorkspace.sharedWorkspace.openURL(dollar.NSURL.URLWithString(url));
                },
                onWebMessage: function (cb) {
                    messageCallback = cb;
                },
                attachWebView: function (win, wv) {
                    win.contentView = wv;
                },
                loadHTML: function (wv, html, basePath) {
                    var baseUrl = dollar.NSURL.fileURLWithPath(basePath).URLByDeletingLastPathComponent;
                    wv.loadHTMLStringBaseURL(html, baseUrl);
                },
                showWindow: function (win) {
                    win.makeKeyAndOrderFront(null);
                    try { app.activateIgnoringOtherApps(true); } catch (_) {}
                },
                runEventLoop: function () {
                    try {
                        if (messageCallback && webViewRef) {
                            ObjCRef.registerSubclass({
                                name: "NeutrinoPoller",
                                superclass: "NSObject",
                                methods: {
                                    "pollTitle": {
                                        types: ["void", ["id", "SEL"]],
                                        implementation: function () {
                                            try {
                                                var rawTitle = webViewRef.title;
                                                if (rawTitle) {
                                                    var docTitle = rawTitle.js ? String(rawTitle.js) : String(rawTitle);
                                                    if (docTitle !== lastDocTitle && docTitle.indexOf("__NEUTRINO__") === 0) {
                                                        lastDocTitle = docTitle;
                                                        messageCallback(docTitle.substring(12));
                                                    }
                                                }
                                            } catch (_) {}
                                        }
                                    }
                                }
                            });
                            var poller = dollar.NeutrinoPoller.alloc.init;
                            dollar.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(
                                0.05, poller, "pollTitle", null, true
                            );
                        }
                    } catch (_) {}
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

            return {
                webMessageTransport: "window.webkit.messageHandlers.neutrino.postMessage",
                init: function () {
                    importsRef["gi"]["versions"]["Gtk"] = "3.0";
                    importsRef["gi"]["versions"]["WebKit2"] = self.resolveLinuxWebKitVersion();
                    Gtk = importsRef["gi"]["Gtk"];
                    WebKit2 = importsRef["gi"]["WebKit2"];
                    GLib = importsRef["gi"]["GLib"];
                    ByteArray = importsRef["byteArray"];
                    Gtk.init(null);
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
                    return new WebKit2.WebView({ user_content_manager: ucm });
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
                    try {
                        var Gio = importsRef["gi"]["Gio"];
                        Gio.AppInfo.launch_default_for_uri(url, null);
                    } catch (_) {
                        GLib.spawn_command_line_async("xdg-open " + url);
                    }
                },
                onWebMessage: function (cb) {
                    messageCallback = cb;
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

        buildPreloadScript: function (transport) {
            return '(function(){' +
                'var _send=function(m){try{(' + transport + ')(m);}catch(_){}};' +
                'window.neutrino={' +
                'send:function(action,data){' +
                'var msg={action:action};' +
                'if(data){for(var k in data){if(data.hasOwnProperty(k))msg[k]=data[k];}}' +
                '_send(JSON.stringify(msg));' +
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

        routeMessage: function (actions, jsonString) {
            var msg = null;
            try {
                msg = (typeof jsonString === "string") ? eval("(" + jsonString + ")") : jsonString;
            } catch (_) {
                return;
            }
            if (msg && msg.action && actions[msg.action]) {
                actions[msg.action](msg);
            }
        },

        boot: function (driver, config) {
            driver.init();
            var scriptPath = driver.getScriptPath();
            var html = this.extractHtmlDocument(driver.readFile(scriptPath));
            var preloadJs = null;

            if (driver.webMessageTransport) {
                preloadJs = this.buildPreloadScript(driver.webMessageTransport);
                if (!driver.injectPreload) {
                    html = html.replace("<head>", "<head><script>" + preloadJs + "<\/script>");
                }
            }

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

            if (driver.injectPreload && preloadJs) {
                driver.injectPreload(null, preloadJs);
            }

            var wv = driver.createWebView();

            driver.loadHTML(wv, html, scriptPath);
            driver.attachWebView(win, wv);
            driver.showWindow(win);
            driver.runEventLoop(win, wv);
        },

        runMacOS: function () {
            this.boot(this.createMacDriver(), this.config);
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

        createWindowsDriver: function () {
            var SystemRef = eval("System");
            var webViewWinFormsAssembly, webViewType;
            var appFolder, userDataDir;
            var self = this;
            var messageCallback = null;
            var lastDocTitle = "";
            var pendingPreload = null;

            return {
                webMessageTransport: "function(m){document.title='__NEUTRINO__'+m;}",
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
                    SystemRef.Diagnostics.Process.Start(url);
                },
                showWindow: function () {},
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
                            if (coreWv2 && messageCallback) {
                                if (!titleProp) {
                                    titleProp = coreWv2.GetType().GetProperty("DocumentTitle");
                                }
                                if (titleProp) {
                                    var docTitle = String(titleProp.GetValue(coreWv2, null) || "");
                                    if (docTitle !== lastDocTitle && docTitle.indexOf("__NEUTRINO__") === 0) {
                                        lastDocTitle = docTitle;
                                        messageCallback(docTitle.substring(12));
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
