# neutrino

Cross-platform experiment for launching the same URL in a native desktop webview window on:

- macOS (JXA + Cocoa/WebKit)
- Linux (gjs + Gtk/WebKit2)
- Windows (JScript.NET + WinForms + WebView2)

CI validates each platform by opening the window and taking a screenshot artifact.

## Project Layout

- `webview.js`: single isomorphic script with runtime/feature detection and OS-specific implementations.
- `windows.bat`: Windows build/bootstrap runner (downloads WebView2 SDK package, stages DLLs, compiles with `jsc`, launches app).
- `.github/workflows/ci.yml`: Linux/macOS/Windows screenshot jobs.

Legacy per-OS scripts are still present (`macos.js`, `linux.js`, `windows.js`) but CI now uses `webview.js`.

## How It Works

`webview.js` selects an implementation at runtime:

1. Windows if `System.Windows.Forms` is present.
2. macOS if JXA globals are present.
3. Linux if `imports.gi` is present.

Then it creates a titled native window and embeds a webview pointed at `https://alganet.github.io/`.

## Running Locally

### macOS

```bash
osascript -l JavaScript webview.js
```

### Linux

```bash
gjs webview.js
```

### Windows

```bat
windows.bat
```

Debug mode:

```bat
windows.bat --debug
```

This prints extra output and dumps `windows-app.log` if present.

## CI Validation

`ci.yml` does:

- Linux: `gjs webview.js` under `Xvfb`, then ImageMagick `import` screenshot.
- macOS: `osascript -l JavaScript webview.js`, then `screencapture`.
- Windows: `windows.bat`, then PowerShell screen capture.

## Gotchas and Why the Code Looks Like This

### 1) One JS file must parse in three very different engines

`webview.js` is parsed by:

- JXA parser (macOS)
- gjs parser (Linux)
- JScript.NET compiler (`jsc`) on Windows

So syntax must be accepted by all three, even if branches are never executed.

### 2) `jsc` rejects undeclared globals at compile time

Windows compile failed on direct references to non-Windows globals (`ObjC`, `$`, `imports`, `print`) even behind runtime checks.

Workaround used:

- No direct non-Windows global references in parse-critical places.
- Feature checks and access are done through `eval(...)` indirection in `webview.js`.

### 3) `ObjC.import(...)` breaks `jsc` parsing

`import` as a member name caused parser conflicts in JScript.NET.

Workaround:

- Use `ObjC["import"]("...")` instead of `ObjC.import("...")`.

### 4) WebView2 Runtime != WebView2 SDK assemblies

Having WebView2 runtime installed is not enough for this build flow.
Compilation/execution needs managed SDK DLLs:

- `Microsoft.Web.WebView2.Core.dll`
- `Microsoft.Web.WebView2.WinForms.dll`

`windows.bat` ensures they exist locally.

### 5) `Expand-Archive` does not accept `.nupkg` extension directly

PowerShell `Expand-Archive` accepts zip archives. NuGet package bytes are zip-compatible, so the runner downloads to `.zip` and extracts.

### 6) `jsc` option and entrypoint quirks

- `/main:...` is not supported on the `jsc` variant used in CI.
- Entry behavior can be non-obvious across multi-file JScript.NET compilation.

Current approach avoids relying on unsupported flags and keeps startup explicit through script flow.

### 7) `JS1259` (assembly dependency resolution) issues

Referencing WebView2 assemblies directly during compile was brittle in this environment.

Workaround:

- Compile app code only against framework assemblies.
- Load WebView2 assemblies at runtime via reflection in `webview.js`.

### 8) WebView2 native loader must be staged

The managed WebView2 DLLs are not sufficient alone.
`windows.bat` also stages `WebView2Loader.dll` (architecture-aware) beside `windows-app.exe`.

### 9) Linux WebKit2 typelib version differences

Some environments expose WebKit2 `4.1`, others `4.0`.
`webview.js` probes available typelibs and selects supported version dynamically.

## Windows Build Flow (Summary)

`windows.bat`:

1. Resolves `jsc.exe` path.
2. Finds WebView2 package under local `packages/`.
3. Downloads and extracts package if missing.
4. Stages required managed + native WebView2 DLLs next to output exe.
5. Compiles `webview.js` with `jsc`.
6. Runs the app (or runs in-process in `--debug` mode).

## License

ISC (see `LICENSE`).
