<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# pages

The site published at **<https://alganet.github.io/neutrino/>**: a sample neutrino app, the
[netinstall](../netinstall/) binaries for all six targets, and a page listing both and
explaining neither. The list is the page — resist adding prose to it.

```
pages/build.sh  ->  _site/index.html
                    _site/demo.cmd                        the sample app
                    _site/<platform>/<spec>[.exe]         netinstall, six of them
                    _site/.nojekyll
```

Run `bash pages/build.sh` to produce `_site/` locally; it needs `zig` for the cross-compile and
refuses to run without it. `.github/workflows/pages.yml` runs the same script on pushes to
`main` and deploys the result — nowhere else, because cross-compiling six targets to publish two
files is not a check worth attaching to every branch. Run it locally before merging.

## Nobody renames anything

netinstall reads its own filename, so the file someone downloads has to already *be* the spec.
Six binaries cannot share one directory under one name, so each platform gets a directory and
the basename is identical in all of them:

```
linux-x86_64/demo-neutrino-alganet-github-io-3<pin>
windows-x86_64/demo-neutrino-alganet-github-io-3<pin>.exe
```

A browser's save and `curl -O` both keep the basename, which is the whole point. On macOS and
Linux the file still arrives without its executable bit, and the page does not mention it.

## Why this needed a shape

A project Pages site lives under a path — `alganet.github.io/`**`neutrino/`** — and netinstall
could once only address the root of a host. Shape `3` names a directory and a file:

```
demo-neutrino-alganet-github-io-3<pin>   ->   alganet.github.io/neutrino/demo.cmd
└──┘ └──────┘ └──── host ─────┘│
file  dir                      └ shape 3: one directory, and the file is named
```

## The pin is derived, never written

`build.sh` hashes the app it just built and uses that digest for the binaries' filenames.
Nobody types a pin, so a download cannot come to name a digest its neighbour does not have —
which for a pinning launcher turns "verified" into "verification failed" for everyone who
follows the link. CI re-checks the published names against the published file anyway, because a
script agreeing with itself is not two files agreeing, and it checks that every row in the list
is a file that actually shipped.

## demo/

The sample app is an overlay laid over `neutrino/` — `app.js`, `config.json`,
`style.css` and `body.html` — and `pages/build.sh` hands the directory to
`neutrino/assemble.sh`. There are no build flags here: everything the app
declares lives in the app's own directory.

It is the app most people will ever run, so it is written to be read: every
button on it is one of the standard calls the README documents — `resizeBy`,
`moveTo`, `document.title`, `open`, `close` — and every colour on it is one of
the seven custom properties the launcher writes from the desktop's own palette,
so the window is the desktop's on any machine and follows a theme change with no
script at all. `config.json` says `"background": "auto"` for the other half of
that: the native window and the view are painted from the same palette before
the document exists.

`app.js` is ES5 only — the same source runs under JScript.NET, gjs, QtWebEngine
and WKWebView. One constraint worth knowing: no line may read
`NeutrinoWebview.run();`, because [`test/parse.sh`](../test/parse.sh) lifts the
launcher's object out of a built `.cmd` with a `sed` range that ends there and
the app is spliced inside that range.

### What broke here once

The first version of this app set `getElementById("close").onclick` on its third
line. That works on four of the five lanes and threw on the fifth: WebView2's
only pre-navigation hook runs the page script before the parser has produced
anything, so `getElementById` answered null and the Close button on the
published demo did nothing on Windows. Nothing caught it, because nothing in CI
runs this app and the suites that do run wait for a document by hand.

The launcher holds an app's script until the document is there now, on every
lane, and `body0=yes` is asserted on all five on every push — see
[`test/neutrinostddoc.js`](../test/neutrinostddoc.js). This app is written the
way that fix allows: no polling, no ready guard, `getElementById` on the first
line.
