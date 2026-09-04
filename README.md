<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# neutrino

`neutrino` is a single-file, cross-platform desktop launcher that opens a native window containing a web page. 

Every app it builds is one polyglot `.cmd` file that runs on Windows, Linux, and macOS with no dependencies beyond what each OS provides.

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

A neutrino app is a polyglot file that is simultaneously valid as a Windows batch script, a Unix shell script, JavaScript, and an HTML document. Each platform runtime loads the same file, creates a native window, and renders the embedded HTML in a webview.

The launcher that half of that file is made of lives in `neutrino/`, one language per file under a twenty-one line polyglot skeleton, and `neutrino/assemble.sh` puts it together on every build. `neutrino/POLYGLOT.md` walks the skeleton line by line and says what each of the five readers makes of it.

The embedded JavaScript includes the `NeutrinoWebview` object which detects the runtime environment and dispatches to a platform-specific driver. Each driver implements a common interface (`createWindow`, `createWebView`, `loadHTML`, etc.) called by a shared `boot()` orchestrator.

When the webview loads the HTML, the script runs again in the browser context and calls `runWeb()` , the entry point for the web application.

### The environment an app is launched with

Before any engine starts, neutrino removes the environment variables a toolkit reads as *open this file*, *run this program* or *do not sandbox yourself* — `GTK_MODULES`, `WEBKIT_INJECTED_BUNDLE_PATH`, `QT_PLUGIN_PATH`, `QTWEBENGINE_CHROMIUM_FLAGS`, everything under `LD_`, `DYLD_` and `PYTHON`, and anything else matching those shapes inside a namespace a toolkit owns. Each of them can otherwise load code of the caller's choosing into the process that renders your page, and two of them switch off the renderer sandbox neutrino turns on for you.

Variables that carry data or a mode rather than a file are untouched: `DISPLAY`, `GDK_BACKEND`, `QT_QPA_PLATFORM`, `XDG_RUNTIME_DIR`, the locale, and your `PATH`. If your app needs a plugin path or a module directory, set it from inside the app rather than expecting it to be inherited.

---

## Building apps

An app is a directory laid over `neutrino/`. Put your JavaScript in `app.js`
and hand the directory to the assembler:

```bash
mkdir myapp
cp somewhere/myapp.js myapp/app.js
./neutrino/assemble.sh --overlay myapp myapp.cmd
```

`assemble.sh` builds the polyglot out of `neutrino/`, one `@@include` at a time,
and looks in your directory first for every part it needs. `app.js` is the part
that becomes the `runWeb()` body, so yours goes in and the launcher's greeting
does not. The resulting `.cmd` file is a self-contained app that runs on all
platforms.

There is no separate splicing step and no template file. An overlay part either
replaces the launcher's or it does not exist, which is why a build that produces
an artifact produces the one you asked for.

Your JS runs in the browser context with access to `document`, `window`, and the `window.neutrino` API.

**Note:** Use `eval("window")` and `eval("document")` instead of bare globals to avoid JScript.NET compile errors (the same file is compiled by `jsc.exe` on Windows where these globals don't exist at compile time).

### The early shell

What your app looks like *before* a line of its JavaScript has run.

Three more parts, beside `app.js` in the same directory:

```
myapp/
  app.js         your code, the body of runWeb()
  config.json    the window
  style.css      the early shell's stylesheet
  body.html      the early shell's markup
```

```json
{
    "title": "My App",
    "width": 1024,
    "height": 768,
    "background": "#12141a",
    "decorations": "none"
}
```

The style and the body are included into the polyglot's document, so they are in
the first paint — there is no frame in which the window is up and your markup is
not. Write them across as many lines as you like; they are ordinary files.

`config.json` is laid into the launcher's config object verbatim, because JSON
*is* a JavaScript object literal. Nothing rewrites it, so what the artifact
carries is the file you wrote. The values are read before there is a document,
which is why the window's title, size, background and frame live here and not in
your markup.

Leave a part out and you get the launcher's. Write `config.json` and you write
all five keys — there is no merge, and a file that named only a title would take
the rest from nowhere.

### What an app is allowed to do

**Every neutrino app runs confined, on every platform. There is nothing to turn on and nothing to
choose.**

- It cannot write to your files. It writes its own directory and the scratch and cache locations its
  web engine needs, and nothing else.
- It cannot gain privileges it was not started with.
- It cannot load code through the environment.
- **Reads are not confined, on any platform.** An app can read what you can read.
- If any of that cannot be applied, the app does not start.

It is the same list on Linux, macOS, Windows and OpenBSD, and the same list in every build. Where a
platform needs a different mechanism to keep one of those lines it uses one; where a platform could
keep more than the list says, it does not — a promise that is stronger on three platforms than on
the fourth is not a promise, it is a support matrix. [netinstall's README](netinstall/#confinement)
has the mechanisms and the measurements.

There used to be three overlays under `neutrino/tier/` — `tight`, `offline` and `testing` — and
four build flags on netinstall's side. The first two are gone. `testing` remains and was never a
security tier: it is the trace channel, the macOS status file, the two Windows environment
overrides and Qt's `--no-sandbox`, none of which a release build carries.

An overlay is still how you replace a part. An app that wants a denying content policy replaces
`html/policy.html`; one that wants `window.open` to stop handing urls to the browser replaces
`js/external-allow.js`. `test/nav-hermetic/` is a two-file example of the second.

```bash
./neutrino/assemble.sh --overlay myapp myapp.cmd
```


Without this, an app draws itself from script, and every launch shows the
launcher's own document first — the shape that made the sample app blink.

**`background` is not CSS.** Two surfaces are up before your document, and
neither can be reached from a stylesheet: the native window, and the view inside
it. Measured on WebKitGTK with the load held back, under a default desktop, the
window is `#F6F5F4` — the GTK theme's bare background — and the view adds about
two frames of its own on top. That is the white flash, and it is what this flag
paints. Set it to whatever your CSS paints, and the app appears out of its own
colour instead of out of the desktop's.

| Lane | Window | View |
|---|---|---|
| gjs / cjs / PyGObject | `GtkCssProvider` on the widget | `webkit_web_view_set_background_color` |
| Qt | `Window.color` | `WebEngineView.backgroundColor` |
| macOS | `NSWindow.backgroundColor` | `underPageBackgroundColor`, then `drawsBackground` |
| Windows | `Form.BackColor` | `WebView2.DefaultBackgroundColor` |

`#rgb` or `#rrggbb`, or `auto`; anything else is refused at build time. It is
deliberately separate from your stylesheet — this is the colour of the frame your
app has not arrived in yet, not a rule in your CSS.

**Say `auto` and the colour comes from the desktop.** `auto` is what the
launcher's own `config.json` carries, and it means the launcher reads the palette off
the running toolkit and paints both surfaces the desktop's own content colour.
Measured on the same two GTK lanes: Adwaita gives `#ffffff`, Adwaita-dark gives
`#2d2d2d`, Mint-L-Dark gives `#404040`. So an app that follows the OS gets no
flash on either kind of desktop without naming a colour at all — and an app that
wants one fixed colour everywhere still says `"background": "#12141a"` and gets
exactly that, on every machine, through every theme change.

**`"decorations": "none"` takes the frame off.** No title bar, no borders, no
resize edge — the window is the web view and nothing else. `auto` is the
default and is the frame the desktop would have given it anyway.

| Lane | How |
|---|---|
| gjs / cjs / PyGObject | `Gtk.Window(decorated=False)`, a construct property |
| Qt | `Qt.Window \| Qt.FramelessWindowHint` |
| macOS | `NSBorderlessWindowMask`, on an `NSWindow` subclass that can still become key |
| Windows | `Form.FormBorderStyle = None` |

**What you give up, and what you write instead.** The title bar was the drag
handle, the borders were the resize edge, and the frame was what the window
manager snapped and tiled and cascaded. All of that goes with it. Nothing in
neutrino replaces them, and there is no `startDrag` verb — your app already has
the two calls it needs:

```javascript
var win = eval("window");
// a title bar of your own
bar.onmousedown = function (down) {
    var ox = down.screenX, oy = down.screenY;
    function moved(e) { win.moveBy(e.screenX - ox, e.screenY - oy); ox = e.screenX; oy = e.screenY; }
    function up() { win.removeEventListener("mousemove", moved); win.removeEventListener("mouseup", up); }
    win.addEventListener("mousemove", moved);
    win.addEventListener("mouseup", up);
};
```

`-webkit-app-region: drag` is not the answer here. Measured on all four
engines: the property is retained on QtWebEngine and WebView2 and dropped on
WebKit — but retaining a property is the parser accepting it, not the embedder
honouring it, and neither of those two embedders implements the behaviour.
It is an Electron feature, and this is not Electron.

A chromeless window also has no close button, so an app that removes the frame
owns `window.close()` as well. Give the user something to press.

**What the early shell may not carry.** `style.css` and `body.html` are included
into a region that is simultaneously inside a JavaScript block comment, inside a
shell here-document, and the span both halves of the file are cut from. Write
them across as many lines as you like — that region is not one line, and nothing
is folded. CSS comments are removed for you, whether or not you asked for them
to be, because the pair that closes one also closes the comment the whole region
lives inside. Four sequences are refused rather than escaped, and the error says
what each one would have done:

| Refused | Because |
|---|---|
| `*/` | ends the block comment the whole shell region lives inside |
| `<script` | moves where both halves of the file are cut |
| `<!doctype` | is a second doctype, which the launcher refuses |
| `Content-Security-Policy` | is a second policy, which would sit in the document enforcing nothing |

So you have a choice rather than a limit. Put the whole window in the early
shell and it loads with nothing to wait for. Or keep the shell to the frame your
app appears in and build the rest from script once the engine is up, where none
of these rules apply. The sample app does the first: `pages/demo/style.css` and
`pages/demo/body.html` are the whole window, and `pages/demo/app.js` fills in
the two words that only the runtime knows.

---

## The API

`window.neutrino` is in scope before your app's first statement. You do not need
to poll for it, wait for `DOMContentLoaded`, or listen for a ready event — there
isn't one. Measured on every lane and asserted on every push: WebKitGTK under
gjs, cjs and PyGObject, QtWebEngine, WKWebView and WebView2 all have the API in
scope when the first line of the app script runs.

**Your markup is in scope too.** The early shell — your `body.html` and
`style.css` — is parsed before your app's first statement, on every lane, so
`document.getElementById` answers on the first line and you do not have to wait
for anything to read your own page.

That is four engines doing it and one being asked to. WebKitGTK takes a
`DOCUMENT_END` user script, WKWebView takes injection time 1 and Qt runs the
page script from `LoadSucceeded`; WebView2 has one hook before a navigation and
it runs before the parser has produced anything, so the launcher holds your
script until `DOMContentLoaded` there. It was not always so, and what that cost
is worth writing down: the sample app on the download page did
`getElementById("close").onclick = …` on its third line, which threw on Windows
and nowhere else, and the Close button on the demo everybody downloads did
nothing there for as long as that was true. `body0=yes` is asserted on every
lane on every push now.

`document.readyState` is a separate question and it is *not* uniform — it reads
`interactive` on WebKit and WebView2 and `complete` on QtWebEngine. That is a
difference between engines rather than between launchers, and none of the three
is a state in which your markup is missing.

Your app moves and names its window with the spelling it would use in a
browser.

```javascript
var win = eval("window");
var doc = eval("document");

doc.title = "My App";     // and the window's title bar says so
win.resizeTo(800, 600);   // and resizeBy(dw, dh)
win.moveTo(100, 50);      // and moveBy(dx, dy)
win.close();
```

These are the CSSOM View methods, written over in the webview at document start.
They are not there because the engine provides them. **Measured on WebKitGTK,
QtWebEngine, WKWebView and WebView2: all five exist, all five are writable and
configurable properties of `window`, and all five do nothing.** A browser
refuses to resize or move a window a script did not open — it protects a user
from a page moving a tab they opened for something else — and it reports no
error for the refusal, so an app calling the standard spelling gets silence.

Here the window and the page are one artifact, launched from a file the user
ran. There is no third party whose window is at risk, so neutrino does not
honour that restriction. What it replaces is the silence; the call emits the
same record the launcher has always used and meets the same checks on the way
in.

`document.title` is the one of these the engines do implement, and none of them
carries it any further than the DOM — **measured on all four: the document takes
the value and the native window never moves.** So the launcher connects the
signal each engine raises when a document's title changes (`notify::title`,
`onTitleChanged`, `WKWebView.title`, `DocumentTitleChanged`) and puts the value
on the window. A `<title>` in your markup works for the same reason, and your
build's `title` is put into the document if you wrote none, so reading
`document.title` back gives you the name your window already has.

Only the document this launcher loaded can name the window. A page that somehow
got itself loaded in the view cannot, and neither can a frame — a subframe's
title is its own document's on every engine here.

**You can name it on the first line.** `document.title` writes into the
`<title>` of a `<head>`, and where the page has neither yet the DOM's own rule
is to do nothing — no error, no title. That used to be a real hazard on one
platform: your script started before the head was parsed on WebView2, so a title
written at the top of the file was silently dropped on Windows and landed
everywhere else, and this section carried a `doc.body` poll to work around it.

The launcher holds your script until the document is there instead, so the poll
is gone and so is the difference. `doc.title = "My App"` on line one is a title
on all five lanes.

Two consequences worth knowing. `close()` does not run `beforeunload`, and it
does not set `window.closed` — the engines already disagree about that flag,
three setting it true while the window stays up and one leaving it false, and
there is no value here that would be true everywhere. And `resizeTo` sizes the
**content area**, not the frame, on every platform: `resizeTo(800, 600)` leaves
`innerWidth` at 800 and `outerWidth` at whatever the decoration adds. That is
also what `width` and `height` have always meant, so a window opened at `900x600` and one
resized to `900x600` are the same window.

`moveTo` is the other half of that pair and it goes the other way: it places the
**frame**, so `moveTo(0, 0)` puts the window's outside corner — title bar
included — in the corner of the screen, and the content lands below the
decoration rather than under it. A size an app asks for is the size it draws in;
a position it asks for is where the window appears.

`window.open` hands an **external** url to the machine's browser, under the name
an app author already knows:

```javascript
win.open("https://example.com");            // the user's browser
win.open("https://example.com", "_blank");  // the same; the url decides, not the target
```

It routes on the **url**, not on the target. `http`, `https` and `mailto` go
out; everything else is handed to the engine untouched, which today opens
nothing and returns `null`. That is deliberate: a second window of your own is
not built yet, and the only thing that can ever hand a page a real `WindowProxy`
is the engine creating the view — so this steps in front of one case rather than
answering every call and putting that window out of reach. `open()` with no url
does nothing for the same reason.

`_self`, `_parent` and `_top` are left to the engine. They are not an opening;
they navigate this window, and that navigation meets the same guard a
`location` assignment meets — which already sends an external url to the
browser.

A **link** with a target — `<a href="…" target="_blank">` — is the engine's own
path and not this one. On WebKitGTK, QtWebEngine and WebView2 the new window is
refused and its url handed to the browser under the same `mayOpenExternal` rule,
so a link behaves like the call. On macOS the window is refused and the url is
**not** forwarded — the refusal is the framework's own and the launcher has no
hook on that path. On WebKitGTK the engine only offers the path for a real
click: a script synthesising one gets nothing, because
`javascript-can-open-windows-automatically` is off.

The return value is `null` for anything sent outward. Nothing here is a window
in your page's process, and three of the four engines already answer `null`.

An app that replaces `js/external-allow.js` refuses all of it, because a url handed to the desktop's
browser is the page reaching the network in another program.

**There is no bespoke spelling for any of this.** `document.title`,
`resizeTo`, `resizeBy`, `moveTo`, `moveBy`, `close` and `open` are the whole of
what your page drives the window with, and they are the names your editor and
`lib.dom` already know. What is left on `window.neutrino` is one reading and one
label — `theme`, the desktop's palette, which no engine offers; and `transport`,
naming the channel the host is listening on. Both are below.

All coordinates use top-left origin on every platform (macOS coordinates are normalized internally).

**Do not read the window's geometry back from the engine.** `outerWidth` and
`outerHeight` report the frame truthfully on QtWebEngine only — WebKitGTK and
WebView2 return the content size, and WKWebView returns `0`. `screenX` and
`screenY` are truthful on WebView2 only. `innerWidth` and `innerHeight` are
correct everywhere and are what `resizeTo` sets.

### Following the desktop

The palette is delivered twice, because the two ways a page wants it are not the
same way. In CSS it is seven custom properties named for the non-deprecated
`<system-color>` keywords, in the document's own stylesheet before the first
paint:

```css
body {
  background: var(--neutrino-Canvas, Canvas);
  color:      var(--neutrino-CanvasText, CanvasText);
  border:     1px solid var(--neutrino-ButtonBorder, ButtonBorder);
}
::selection { background: var(--neutrino-Highlight, Highlight); }
```

| neutrino | property | what it is |
|---|---|---|
| `base` | `--neutrino-Canvas` | content surface |
| `text` | `--neutrino-CanvasText` | text on it |
| `background` | `--neutrino-ButtonFace` | window chrome |
| `foreground` | `--neutrino-ButtonText` | text on that |
| `border` | `--neutrino-ButtonBorder` | separators |
| `accent` | `--neutrino-Highlight` | selection / accent |
| `accentText` | `--neutrino-HighlightText` | text on the accent |

The fallback in each `var()` is the point of naming them after the keywords. On
a lane where the launcher could not read a toolkit it sets **no** property, so
the declaration falls through to the engine's own system colour — the desktop's
real value where there is one, the engine's guess where there is not, decided at
the point of use with no branch in your script. **None of these keywords follows
the desktop on its own**: measured on all four engines, every one of the fifteen
system colours is a constant. macOS reports `Canvas` as `ffffff` against a
content surface that is `1e1e1e`; both WebKit lanes report `ButtonFace` as
Windows 3.1 grey. That is what the custom properties are for.

The rule sits after the document's content policy and before your own
stylesheet, so your `:root` declarations override it.

And in script, `window.neutrino.theme` is the same palette at document start —
not pushed after load — so your first paint can use it either way.

```javascript
var theme = win.neutrino.theme;   // null if this lane could not read one

theme.scheme;              // "dark" | "light"
theme.source;              // "gtk" | "qt" | "macos" | "windows"
theme.colors.background;   // window chrome      e.g. "#f6f5f4"
theme.colors.foreground;   //                         "#2e3436"
theme.colors.base;         // content surface         "#ffffff"
theme.colors.text;         //                         "#000000"
theme.colors.accent;       //                         "#3584e4"
theme.colors.accentText;   //                         "#ffffff"
theme.colors.border;       //                         "#cdc7c2"
```

Every value is `#rrggbb`. `scheme` is derived from the luminance of
`background` rather than read from a settings flag — measured on a Mint desktop,
`gtk-application-prefer-dark-theme` reads false while the theme is `Mint-L-Dark`,
so the flag says light and the window is dark grey. The palette is what is on
screen, so the palette is what decides.

`@media (prefers-color-scheme: dark)` agrees with it. That is not free, and on
one engine it is not the engine's own answer: WebKitGTK decides the media query
from the theme's **name** — the prefer-dark flag, or a name carrying the dark
variant — and not from the palette. Mint's stock `Mint-Y-Dark-Grey` and the
twenty-odd themes in its `-Dark-<colour>` families are the same dark grey as
`Mint-Y-Dark`, named for the accent instead of the variant, and the engine calls
every one of them light. So the launcher raises the flag itself where it
measured a dark palette, and the query follows.

One direction only, and it is the engine's asymmetry rather than a choice: the
rule there is the flag *or* the name, so a light theme whose name ends in `-dark`
reports dark and there is nothing to set that would say otherwise. That is a
theme named for a variant it does not have, and no distribution ships one. There
is no in-page spelling of any of this either — `color-scheme` as a stylesheet
rule, through CSSOM, and as a `<meta>` all leave `prefers-color-scheme` where it
was on this engine.

When the desktop changes, the object is **replaced** and an event fires:

```javascript
win.addEventListener("neutrino:themechange", function (e) {
    e.detail.scheme;   // the new scheme
    e.detail.colors;   // the new palette
});
```

`win.neutrino.theme` is already the new palette when the handler runs, so a
handler may read either, and the custom properties are rewritten on the same
update — through `documentElement.style.setProperty`, which is measured working
on all four engines. A reference you captured earlier keeps the palette it
had. If your build's background is `auto`, the two native surfaces are repainted
to match at the same time; if you named a colour, they are never repainted.

| Lane | Palette | Change signal |
|---|---|---|
| gjs / cjs / PyGObject | `GtkStyleContext.lookup_color` | `style-updated` on the window |
| Qt | `SystemPalette` | the binding re-evaluates itself |
| macOS | `NSColor`, resolved under the current `NSAppearance` | `AppleInterfaceThemeChangedNotification` |
| Windows | `SystemColors`, plus the app-theme registry value | re-read on the event loop |

**Only the live scheme, not both.** There is no `theme.light` and `theme.dark`:
of the four toolkits only macOS can resolve a palette under an appearance it is
not currently using, and inventing the other half by inverting luminance would
be a colour nobody's desktop is running. If you need both, define them in CSS and
switch on `theme.scheme`.

**`theme` is `null` on a lane that could not read its toolkit.** Said out loud
rather than filled in with white, so you can tell the difference between a light
desktop and no answer.

### Which channel the host is listening on

```javascript
win.neutrino.transport;   // "scriptmessage", "wkscriptmessage", "console",
                          // "webmessage", "title" or "unwired"
```

The other half of `window.neutrino`, and the only reason it is named at all is
that a test reporting the channel it used beats one inferring it. Your page never
needs it: the verbs above go out on whichever channel this lane has, and feature
detection would find the same answer.

---

## Requirements

### Windows

- .NET Framework with `jsc.exe` (v4.x), available on modern Windows by default.
  The launcher compiles the script into the app folder on every launch, about a
  third of a second, rather than reusing what it finds there: the app folder is
  writable by everything running as you, so an executable sitting in it is not
  evidence of anything.
- WebView2 runtime. Usually nothing to do: it ships with Windows 11 and reached
  Windows 10 through Windows Update, and the launcher renders through the one
  the machine already has. It reads the version out of EdgeUpdate, loads the
  runtime's own library by path, and drives the COM surface behind it from the
  same `jsc.exe` that compiles everything else — so on very nearly every machine
  a first run downloads nothing at all.

  **The two paths render the same app.** Whichever one a machine takes, it gets
  the same nine engine settings closed, the same navigation guard, the same
  keyboard focus and the same window verbs. That is asserted rather than
  intended: both halves report how many doors they shut, in one spelling, and
  CI fails a launch where the count differs from the list. It was not always
  true — the installed-runtime path used to close four of the nine, because the
  other five live on interface revisions it has to ask for one at a time.
- WebView2 SDK package, on a machine that has no runtime — Server, LTSC, a
  stripped image — where the above finds nothing to render through. Then it is
  downloaded automatically with a progress bar on first run, 8.8 MiB, which is
  what every Windows first run used to cost.
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

An app is the file `assemble.sh` writes, and running it is running that file.

```bash
./neutrino/assemble.sh --overlay myapp myapp.cmd

# Linux / macOS
chmod +x myapp.cmd
./myapp.cmd

# Windows
myapp.cmd
```

---

## Testing

The test suite verifies IPC works end-to-end on all platforms:

```bash
# Build the test app. mkapp.sh writes the overlay a one-file app would
# otherwise be a directory for, and is what this suite builds with.
bash test/mkapp.sh test/neutrinotest.js test/neutrinotest.cmd

# Run with verification (Linux, requires xdotool)
bash test/neutrinotest.cmd &
bash test/verify-linux.sh screenshots/
```

Tests exercise `document.title`, `window.resizeTo` and `window.moveTo` with external scripts that poll window state and assert expected values. CI runs these automatically on all four platforms.

### Reading a CI run

Every job publishes one artifact holding one file: `<lane>.html`, a self-contained page with that lane's screenshots and verifier logs in it. Nothing to unpack beyond the zip GitHub wraps every artifact in, and nothing to fetch — the pictures are inlined, so it opens offline in a browser.

The screenshots are the human verification step. Each is captioned with what it is a picture of, and the pairs the suite exists to compare — a decorated window against a chromeless one, a light desktop against a dark one — sit beside each other rather than in two different downloads.

Each sheet also lists what its lane asserted, normalised and counted, and carries the same list as JSON. To ask which assertions are being made on more than one lane:

```bash
gh run download <run-id> -D /tmp/sheets
python3 test/sheetdiff.py /tmp/sheets/*/*.html
```

That prints candidates, not a verdict: some repetition is the point. The engine walk asserts what an exit status means on four lanes deliberately, and `test/assemble.sh` runs on three because the three `sed`s are not the same program.

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

- `neutrino/`: the launcher, split by language under a polyglot skeleton -- see `neutrino/POLYGLOT.md`
- `neutrino/assemble.sh`: the assembler (neutrino/ + your overlay -> .cmd)
- `test/`: test harness and platform verification scripts
- `netinstall/`: the name-addressed launcher, and its own suite
- `pages/`: the demo site published at alganet.github.io/neutrino/
- `LICENSE`: ISC license

---

## License

ISC. See `LICENSE`.
