# neutrino

`neutrino` is a single-file, cross-platform launcher that opens a native desktop window containing a web page.

<table align="center"><tr>
<td><img width=300 src=assets/macos-screenshot.png></td>
<td><img width=300 src=assets/windows-screenshot.png></td>
</tr><tr>
<td><img width=300 src=assets/gjs-screenshot.png></td>
<td><img width=300 src=assets/kde-screenshot.png></td>
</tr></table>

---

It uses one polyglot entrypoint (`webview.cmd`) that can run on:

- Windows (`cmd` + JScript.NET + WinForms/WebView2)
- Linux (`sh` + `gjs`/GTK WebKit, with Qt QML fallback)
- macOS (`sh` + `osascript`/JXA + Cocoa WebKit)

Default page:

- `https://alganet.github.io/` (for testing purposes, can be changed)

---

## How it works

`webview.cmd` is intentionally written as a multi-runtime script.

- On **Windows**, it compiles its embedded JScript.NET section with `jsc.exe` to an executable and launches it.
- On **Linux/macOS**, it behaves like a shell script that invokes the best available runtime.
- The same file also embeds an HTML payload used by the runtime-specific logic.

The script automatically tries available runtimes in this order on Unix-like systems:

1. `gjs`
2. Qt QML runtime (`qml6`, `qmlscene6`, `qmlscene-qt6`, `qml`, `qmlscene`)
3. `osascript` (macOS)

The QML runtime integration is currently experimental and under development.

---

## Requirements

### Windows

- .NET Framework with `jsc.exe` (v4.x) - Available on modern Windows machines by default.
- WebView2 runtime installed - Downloaded with progress bar upon first run.

### Linux

- Preferred: `gjs` + GTK/WebKit2 bindings - Available on all major GNOME distros.
- Fallback: Qt runtime with `QtWebEngine` - Available on all major KDE distros.

### macOS

- `osascript` with JavaScript support (JXA) - Available on macos by default.

---

## Run

From the project root:

### Linux / macOS

```bash
chmod +x webview.cmd
./webview.cmd
```

### Windows

```bat
webview.cmd
```

---

## Configuration

### Page URL

- Default URL is embedded in the script as `https://alganet.github.io/`.

### Script path propagation

- The launcher exports `NEUTRINO_SCRIPT_PATH` so child runtimes can resolve the source script consistently.

---

## Output layout (Windows)

When executed as `webview.cmd`, Windows creates/uses a sibling directory named after the script base name:

```text
./webview.cmd
./webview/
  webview.exe
  webview.exe.manifest
  ...runtime assets...
```

---

## Repository

- `webview.cmd` — polyglot entrypoint and runtime implementation
- `LICENSE` — ISC license

---

## License

ISC. See `LICENSE`.
