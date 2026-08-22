<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# neutrino

`neutrino` is a single-file, cross-platform desktop launcher that opens a native window containing a web page. 

It uses one polyglot entrypoint (`webview.cmd`) that runs on Windows, Linux, and macOS with no dependencies beyond what each OS provides.

<table align="center"><tr>
<td><img width=300 src=assets/macos-screenshot.png></td>
<td><img width=300 src=assets/windows-screenshot.png></td>
</tr><tr>
<td><img width=300 src=assets/gjs-screenshot.png></td>
<td><img width=300 src=assets/kde-screenshot.png></td>
</tr></table>

---

## Platforms

| Platform        | Runtime                         | Web Engine             |
|-----------------|---------------------------------|------------------------|
| **Windows**     | `cmd` + JScript.NET (`jsc.exe`) | WebView2 (Chromium)    |
| **Linux/GNOME** | `sh` + `gjs`                    | GTK WebKit2            |
| **Linux/KDE**   | `sh` + Qt QML runtime           | QtWebEngine (Chromium) |
| **macOS**       | `sh` + `osascript` (JXA)        | WKWebView (WebKit)     |

On Unix-like systems, the script tries runtimes in order: `gjs` > Qt QML > `osascript`.

---

## How it works

`webview.cmd` is a polyglot file that is simultaneously valid as a Windows batch script, a Unix shell script, JavaScript, and an HTML document. Each platform runtime loads the same file, creates a native window, and renders the embedded HTML in a webview.

The embedded JavaScript includes the `NeutrinoWebview` object which detects the runtime environment and dispatches to a platform-specific driver. Each driver implements a common interface (`createWindow`, `createWebView`, `loadHTML`, etc.) called by a shared `boot()` orchestrator.

When the webview loads the HTML, the script runs again in the browser context and calls `runWeb()` , the entry point for the web application.

---

## Building apps

Use `build.sh` to embed your JavaScript into a neutrino polyglot:

```bash
./build.sh myapp.js myapp.cmd
```

This replaces the `runWeb()` body (between `//#RUNWEB_START` and `//#RUNWEB_END` markers) with your JS file. The resulting `.cmd` file is a self-contained app that runs on all platforms.

Your JS runs in the browser context with access to `document`, `window`, and the `window.neutrino` API.

**Note:** Use `eval("window")` and `eval("document")` instead of bare globals to avoid JScript.NET compile errors (the same file is compiled by `jsc.exe` on Windows where these globals don't exist at compile time).

---

## IPC API

The `window.neutrino` API is injected into the webview on all platforms, enabling web content to control the native window:

```javascript
var win = eval("window");

// Window management
win.neutrino.window.setTitle("My App");
win.neutrino.window.resize(800, 600);
win.neutrino.window.move(100, 50);

// Shell integration
win.neutrino.shell.openExternal("https://example.com");

// Low-level message passing
win.neutrino.send("actionName", { key: "value" });
```

All coordinates use top-left origin on every platform (macOS coordinates are normalized internally).

---

## Requirements

### Windows

- .NET Framework with `jsc.exe` (v4.x), available on modern Windows by default.
- WebView2 runtime, downloaded automatically with progress bar on first run.
  The package is pinned to one version and one SHA-256, and every file taken out
  of it is pinned too; all of it is re-checked on every launch.

### Linux

- **GNOME:** `gjs` + GTK/WebKit2 bindings, available on all major GNOME distros.
- **KDE:** Qt QML runtime + QtWebEngine, available on all major KDE distros.

### macOS

- `osascript` with JavaScript support (JXA), available by default.

---

## Run

```bash
# Linux / macOS
chmod +x webview.cmd
./webview.cmd

# Windows
webview.cmd
```

---

## Testing

The test suite verifies IPC works end-to-end on all platforms:

```bash
# Build the test app
./build.sh test/neutrinotest.js test/neutrinotest.cmd

# Run with verification (Linux, requires xdotool)
bash test/neutrinotest.cmd &
bash test/verify-linux.sh screenshots/
```

Tests exercise `setTitle`, `resize`, and `move` with external scripts that poll window state and assert expected values. CI runs these automatically on all four platforms.

---

## Repository

- `webview.cmd`: polyglot entrypoint and runtime
- `build.sh`: polyglot assembler (JS + template -> .cmd)
- `test/`: test harness and platform verification scripts
- `LICENSE`: ISC license

---

## License

ISC. See `LICENSE`.
