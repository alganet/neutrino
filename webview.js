// SPDX-FileCopyrightText: 2025 Alexandre Gomes Gaigalas <alganet@gmail.com>
//
// SPDX-License-Identifier: ISC

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
        throw new Error("Unsupported JS runtime for webview.js");
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
        webView.loadRequest(dollar.NSURLRequest.requestWithURL(dollar.NSURL.URLWithString(this.config.url)));

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

        Gtk.init(null);

        var window = new Gtk.Window({
            title: this.config.title + " - Linux",
            default_width: this.config.width,
            default_height: this.config.height
        });
        window.set_position(Gtk.WindowPosition.CENTER);
        window.connect("destroy", function () { Gtk.main_quit(); });

        var webView = new WebKit2.WebView();
        webView.load_uri(this.config.url);

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

    findWebView2LibDir: function (SystemRef, startupPath) {
        var envLibDir = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR");
        if (this.hasWebView2Assemblies(SystemRef, envLibDir)) {
            return envLibDir;
        }

        var directNet462 = SystemRef.IO.Path.Combine(startupPath, "packages", "Microsoft.Web.WebView2", "lib", "net462");
        if (this.hasWebView2Assemblies(SystemRef, directNet462)) {
            return directNet462;
        }

        var directNet45 = SystemRef.IO.Path.Combine(startupPath, "packages", "Microsoft.Web.WebView2", "lib", "net45");
        if (this.hasWebView2Assemblies(SystemRef, directNet45)) {
            return directNet45;
        }

        var packagesRoot = SystemRef.IO.Path.Combine(startupPath, "packages");
        if (SystemRef.IO.Directory.Exists(packagesRoot)) {
            var packageDirs = SystemRef.IO.Directory.GetDirectories(packagesRoot, "Microsoft.Web.WebView2*");
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

    runWindows: function () {
        var SystemRef = eval("System");
        var startupPath = SystemRef.Windows.Forms.Application.StartupPath;
        var webView2LibDir = this.findWebView2LibDir(SystemRef, startupPath);
        if (!webView2LibDir) {
            SystemRef.Environment.Exit(1);
            return;
        }

        SystemRef.Environment.SetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR", webView2LibDir);
        this.prependLoaderPaths(SystemRef, webView2LibDir);

        SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.Core.dll"));
        var webViewWinFormsAssembly = SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.WinForms.dll"));

        SystemRef.Windows.Forms.Application.EnableVisualStyles();
        SystemRef.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);

        var window = new SystemRef.Windows.Forms.Form();
        window.Text = this.config.title + " - Windows";
        window.ClientSize = new SystemRef.Drawing.Size(this.config.width, this.config.height);
        window.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;

        var webViewType = webViewWinFormsAssembly.GetType("Microsoft.Web.WebView2.WinForms.WebView2");
        if (!webViewType) {
            throw new Error("Could not load Microsoft.Web.WebView2.WinForms.WebView2 type.");
        }

        var webView = SystemRef.Activator.CreateInstance(webViewType);
        webView.Dock = SystemRef.Windows.Forms.DockStyle.Fill;
        webView.Source = new SystemRef.Uri(this.config.url);

        window.Controls.Add(webView);
        SystemRef.Windows.Forms.Application.Run(window);
    }
};

NeutrinoWebview.run();
