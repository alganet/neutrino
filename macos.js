// SPDX-FileCopyrightText: 2025 Alexandre Gomes Gaigalas <alganet@gmail.com>
//
// SPDX-License-Identifier: ISC

ObjC.import('Cocoa');
ObjC.import('WebKit');

const app = $.NSApplication.sharedApplication;

// Window frame
const frame = $.NSMakeRect(0, 0, 900, 600);

// Create window
const window = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    frame,
    $.NSTitledWindowMask | $.NSClosableWindowMask | $.NSResizableWindowMask,
    $.NSBackingStoreBuffered,
    false
);

window.title = "neutrino - macOS";

// Create WKWebView configuration
const config = $.WKWebViewConfiguration.alloc.init;

// Create WKWebView
const webView = $.WKWebView.alloc.initWithFrameConfiguration(frame, config);

// Load the page
const url = $.NSURL.URLWithString("https://alganet.github.io/");
const req = $.NSURLRequest.requestWithURL(url);

webView.loadRequest(req);

// Put webview inside window
window.contentView = webView;
window.makeKeyAndOrderFront(null);

// Run the app
app.run();
