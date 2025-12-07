// SPDX-FileCopyrightText: 2025 Alexandre Gomes Gaigalas <alganet@gmail.com>
//
// SPDX-License-Identifier: ISC

const GIRepository = imports.gi.GIRepository;
imports.gi.versions.Gtk = "3.0";

const repository = GIRepository.Repository.get_default();
const webkitVersions = repository.enumerate_versions("WebKit2");

if (webkitVersions.includes("4.1")) {
    imports.gi.versions.WebKit2 = "4.1";
} else if (webkitVersions.includes("4.0")) {
    imports.gi.versions.WebKit2 = "4.0";
} else {
    throw new Error("WebKit2 introspection typelibs not found");
}

const { Gtk, WebKit2 } = imports.gi;

Gtk.init(null);

const window = new Gtk.Window({
    title: "neutrino - Linux",
    default_width: 900,
    default_height: 600,
});

window.connect("destroy", () => Gtk.main_quit());

const webView = new WebKit2.WebView();
webView.load_uri("https://alganet.github.io/");

window.add(webView);
window.show_all();

Gtk.main();
