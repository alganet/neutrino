// SPDX-FileCopyrightText: 2025 Alexandre Gomes Gaigalas <alganet@gmail.com>
//
// SPDX-License-Identifier: ISC

var NeutrinoWindowsApp = {
    config: {
        title: "neutrino - Windows",
        url: "https://alganet.github.io/",
        width: 900,
        height: 600
    }
};

NeutrinoWindowsApp.Run = function () {
    var startupPath = System.Windows.Forms.Application.StartupPath;
    System.Reflection.Assembly.LoadFrom(System.IO.Path.Combine(startupPath, "Microsoft.Web.WebView2.Core.dll"));
    System.Reflection.Assembly.LoadFrom(System.IO.Path.Combine(startupPath, "Microsoft.Web.WebView2.WinForms.dll"));

    System.Windows.Forms.Application.EnableVisualStyles();
    System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);

    var window = new System.Windows.Forms.Form();
    window.Text = NeutrinoWindowsApp.config.title;
    window.ClientSize = new System.Drawing.Size(NeutrinoWindowsApp.config.width, NeutrinoWindowsApp.config.height);
    window.StartPosition = System.Windows.Forms.FormStartPosition.CenterScreen;

    var webViewType = System.Type.GetType("Microsoft.Web.WebView2.WinForms.WebView2, Microsoft.Web.WebView2.WinForms");
    if (!webViewType) {
        throw new Error("Could not load Microsoft.Web.WebView2.WinForms.WebView2 type.");
    }

    var webView = System.Activator.CreateInstance(webViewType);
    webView.Dock = System.Windows.Forms.DockStyle.Fill;
    webView.Source = new System.Uri(NeutrinoWindowsApp.config.url);

    window.Controls.Add(webView);
    System.Windows.Forms.Application.Run(window);
};

NeutrinoWindowsHost.RunMain(null);
