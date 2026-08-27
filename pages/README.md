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

## demo.js

ES5 only — the same source runs under JScript.NET, gjs, QtWebEngine and WKWebView. One
constraint worth knowing: no top-level closing brace may be indented four spaces, because
[`test/parse.sh`](../test/parse.sh) lifts the `NeutrinoWebview` object out of a built `.cmd`
with a `sed` range ending at `/^    };$/`, and an app carrying that line truncates it.
