// SPDX-FileCopyrightText: 2025 Alexandre Gomes Gaigalas <alganet@gmail.com>
//
// SPDX-License-Identifier: ISC

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

    detectRuntime: function () {
        if (typeof System !== "undefined" && System.Windows && System.Windows.Forms) {
            return "windows";
        }
        if (this.hasGlobalExpr("typeof ObjC !== 'undefined' && typeof $ !== 'undefined'")) {
            return "macos";
        }
        if (this.hasGlobalExpr("typeof imports !== 'undefined' && !!imports.gi")) {
            return "linux";
        }
        return "unknown";
    },

    run: function () {
        var runtime = this.detectRuntime();
        if (runtime === "macos") {
            this.runMacOS();
            return;
        }
        if (runtime === "linux") {
            this.runLinux();
            return;
        }
        if (runtime === "windows") {
            this.runWindows();
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

        var webView = dollar.WKWebView.alloc.initWithFrameConfiguration(
            frame,
            dollar.WKWebViewConfiguration.alloc.init
        );
        webView.loadRequest(dollar.NSURLRequest.requestWithURL(dollar.NSURL.URLWithString(this.config.url)));

        window.contentView = webView;
        window.makeKeyAndOrderFront(null);
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
        window.connect("destroy", function () { Gtk.main_quit(); });

        var webView = new WebKit2.WebView();
        webView.load_uri(this.config.url);

        window.add(webView);
        window.show_all();

        Gtk.main();
    },

    logWindows: function (message) {
        if (typeof NeutrinoWindowsHost !== "undefined" &&
            NeutrinoWindowsHost &&
            typeof NeutrinoWindowsHost.Log === "function") {
            NeutrinoWindowsHost.Log(message);
        }
    },

    runWindows: function () {
        var startupPath = System.Windows.Forms.Application.StartupPath;
        this.logWindows("Loading WebView2 assemblies from " + startupPath);

        System.Reflection.Assembly.LoadFrom(System.IO.Path.Combine(startupPath, "Microsoft.Web.WebView2.Core.dll"));
        System.Reflection.Assembly.LoadFrom(System.IO.Path.Combine(startupPath, "Microsoft.Web.WebView2.WinForms.dll"));

        System.Windows.Forms.Application.EnableVisualStyles();
        System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);

        var window = new System.Windows.Forms.Form();
        window.Text = this.config.title + " - Windows";
        window.ClientSize = new System.Drawing.Size(this.config.width, this.config.height);
        window.StartPosition = System.Windows.Forms.FormStartPosition.CenterScreen;

        var webViewType = System.Type.GetType("Microsoft.Web.WebView2.WinForms.WebView2, Microsoft.Web.WebView2.WinForms");
        if (!webViewType) {
            throw new Error("Could not load Microsoft.Web.WebView2.WinForms.WebView2 type.");
        }

        var webView = System.Activator.CreateInstance(webViewType);
        webView.Dock = System.Windows.Forms.DockStyle.Fill;
        webView.Source = new System.Uri(this.config.url);

        window.Controls.Add(webView);
        this.logWindows("Starting Windows message loop.");
        System.Windows.Forms.Application.Run(window);
    },

    handleError: function (error) {
        var message = String(error);
        var runtime = this.detectRuntime();

        if (runtime === "windows") {
            if (typeof NeutrinoWindowsHost !== "undefined" &&
                NeutrinoWindowsHost &&
                typeof NeutrinoWindowsHost.Log === "function") {
                NeutrinoWindowsHost.Log("Exception: " + message);
            }
            if (typeof NeutrinoWindowsHost !== "undefined" &&
                NeutrinoWindowsHost &&
                typeof NeutrinoWindowsHost.ShowError === "function") {
                NeutrinoWindowsHost.ShowError(message);
                return;
            }
            if (System && System.Windows && System.Windows.Forms) {
                System.Windows.Forms.MessageBox.Show(
                    message,
                    this.config.title + " - Windows",
                    System.Windows.Forms.MessageBoxButtons.OK,
                    System.Windows.Forms.MessageBoxIcon.Error
                );
            }
            return;
        }

        if (this.hasGlobalExpr("typeof print === 'function'")) {
            eval("print")(message);
        }
        throw error;
    }
};

try {
    NeutrinoWebview.run();
} catch (e) {
    NeutrinoWebview.handleError(e);
}
