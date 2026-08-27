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

| Platform            | Runtime                          | Web Engine             |
|---------------------|----------------------------------|------------------------|
| **Windows**         | `cmd` + JScript.NET (`jsc.exe`)  | WebView2 (Chromium)    |
| **Linux/GNOME**     | `sh` + `gjs`                     | GTK WebKit2            |
| **Linux/Cinnamon**  | `sh` + `cjs`                     | GTK WebKit2            |
| **Linux/KDE**       | `sh` + Qt QML runtime            | QtWebEngine (Chromium) |
| **Linux, anywhere** | `sh` + `python3` with PyGObject  | GTK WebKit2            |
| **macOS**           | `sh` + `osascript` (JXA)         | WKWebView (WebKit)     |

On Unix-like systems the script tries runtimes in order: `gjs` > `cjs` > Qt QML > `osascript` >
`python3` with PyGObject.

Nothing is probed before an engine is chosen — every candidate test is a shell builtin, so a machine
that has the first one does no extra work. A lane that turns out not to be able to reach its engine
says so with a reserved exit status and the search moves on, which is how a `gjs` installed without
its WebKit2 typelibs stops taking the whole launch down with it. When no lane can open a window the
launcher **fails**, rather than reporting success with nothing on screen.

The PyGObject lane reimplements nothing. JavaScriptCore ships with WebKitGTK, so Python hosts this
file's own JavaScript and calls back into it for every decision the other lanes make — the content
policy, the message parser, the navigation rules and the external-URL check all stay in one copy.

---

## How it works

`webview.cmd` is a polyglot file that is simultaneously valid as a Windows batch script, a Unix shell script, JavaScript, and an HTML document. Each platform runtime loads the same file, creates a native window, and renders the embedded HTML in a webview.

The embedded JavaScript includes the `NeutrinoWebview` object which detects the runtime environment and dispatches to a platform-specific driver. Each driver implements a common interface (`createWindow`, `createWebView`, `loadHTML`, etc.) called by a shared `boot()` orchestrator.

When the webview loads the HTML, the script runs again in the browser context and calls `runWeb()` , the entry point for the web application.

### The environment an app is launched with

Before any engine starts, neutrino removes the environment variables a toolkit reads as *open this file*, *run this program* or *do not sandbox yourself* — `GTK_MODULES`, `WEBKIT_INJECTED_BUNDLE_PATH`, `QT_PLUGIN_PATH`, `QTWEBENGINE_CHROMIUM_FLAGS`, everything under `LD_`, `DYLD_` and `PYTHON`, and anything else matching those shapes inside a namespace a toolkit owns. Each of them can otherwise load code of the caller's choosing into the process that renders your page, and two of them switch off the renderer sandbox neutrino turns on for you.

Variables that carry data or a mode rather than a file are untouched: `DISPLAY`, `GDK_BACKEND`, `QT_QPA_PLATFORM`, `XDG_RUNTIME_DIR`, the locale, and your `PATH`. If your app needs a plugin path or a module directory, set it from inside the app rather than expecting it to be inherited.

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
  The launcher compiles the script into the app folder on every launch, about a
  third of a second, rather than reusing what it finds there: the app folder is
  writable by everything running as you, so an executable sitting in it is not
  evidence of anything.
- WebView2 runtime, downloaded automatically with progress bar on first run.
  The package is pinned to one version and one SHA-256, and every file taken out
  of it is pinned too; all of it is re-checked on every launch. If that fails,
  the reason goes on screen for twenty seconds and into `neutrino-error.log` in
  the app folder, which is where to look when nobody was watching the screen.

### Linux

- **GNOME:** `gjs` + GTK/WebKit2 bindings, available on all major GNOME distros.
- **Cinnamon:** `cjs`, the fork Linux Mint ships, against the same GTK/WebKit2 bindings.
- **KDE:** Qt QML runtime + QtWebEngine, available on all major KDE distros.
- **Anything else:** `python3` with PyGObject and the same GTK/WebKit2 bindings, which is what the
  desktop's own tooling is written against.

A lane that cannot reach its typelibs steps aside for the next one instead of failing the launch,
so a machine only ends up without a window when none of them can open one — and then it says so
and exits non-zero.

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

## Installing over the network

[`netinstall/`](netinstall/) is a separate subproject: a small compiled binary that derives
everything it does from its own filename. Rename it, and it fetches, pins and runs something
else. **<https://alganet.github.io/neutrino/>** publishes a sample app and netinstall binaries
already named for it — download one for your platform and run it, and a window opens.

`neutrino` itself is unchanged by any of that and still works as a plain script; you never need
netinstall to run one.

---

## Repository

- `webview.cmd`: polyglot entrypoint and runtime
- `build.sh`: polyglot assembler (JS + template -> .cmd)
- `test/`: test harness and platform verification scripts
- `netinstall/`: the name-addressed launcher, and its own suite
- `pages/`: the demo site published at alganet.github.io/neutrino/
- `LICENSE`: ISC license

---

## License

ISC. See `LICENSE`.
