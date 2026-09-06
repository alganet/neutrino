<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
SPDX-License-Identifier: ISC
-->

# The polyglot, and the twenty-six lines it lives in

`skeleton.cmd` is the whole of neutrino that is more than one language at once.
Everything else in this directory is ordinary source in exactly one language,
pulled in by an `@@include <path>` line, and `assemble.sh` puts the two together
into an app.

There used to be a second program. `assemble.sh` built a template and `build.sh`
spliced an app into it with four text replacements — the app into a slot, a tier
list into a stamp, five config keys into an object, and a rebuilt document line. Each of those was a pattern with no failure path of its own, so each
needed a read-back to say whether it had landed. There is one directive now and
no substitutions: an app is a directory laid over this one with `--overlay`, and
the things `build.sh` used to splice are parts it carries.

That split is the reason this directory exists. A comment can be removed by a
program that knows which language it is reading; in a single file that is five
languages at the same character it cannot, and every attempt is a rule about
where a `//` is safe that is wrong on the first string containing a URL. Split
by language, the strip is trivial and the artifact is a little over half the
size of its source — 386 KB became 153 KB the day this landed, for the same
program.

## The skeleton

```
 1  if (":" == "<!--") then : 0 /*\;:\
 2  @ECHO OFF||:;fi;:||REM<<'EXIT'
 3  GOTO :W
 4  SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 5  SPDX-License-Identifier: ISC
 6  :W
 7  @@include cmd/launcher.cmd
 8  EXIT
 9  @@include sh/parts.list
10  exit $?;:<<'//</script></body></html>' #-->
11  @@include html/document.html
12  <script type=text/javascript>//*/
13
14  @@include js/parts.list
15
16      /*@cc_on
17          @if (@_jscript_version >= 7)
18  @@include jsc/parts.list
19          @else @*/
20
21  @@include else/parts.list
22
23      /*@end @*/
24
25  @@include js/launch.js
26  //</script></body></html>
```

Five readers, and none of them is told which one it is.

### Lines 1 and 2 — the opening

The trailing `\` on line 1 is a shell line continuation, so a shell reads lines
1 and 2 as one line and the four readers diverge immediately.

**A shell** sees `if (":" == "<!--")` — a subshell running the `:` builtin with
two arguments, which is true — then `: 0 /*;:@ECHO OFF`, another `:`, and
finally `REM<<'EXIT'`. `REM` never runs, because the `:` before the `||` already
succeeded. The here-document is still *parsed*, and that is the whole point:
everything from line 3 down to the line reading exactly `EXIT` is swallowed as
here-document text. The Windows batch region is invisible to the shell because
the shell thinks it is reading a string.

**cmd.exe** sees `IF (":" == "<!--") then : 0 ...`. Its string comparison is
between the literal tokens `(":"` and `"<!--")`, which differ, so the rest of
the line is not executed and no syntax error is raised. Line 2 runs `@ECHO OFF`,
which succeeds, so the `||` chain after it — the shell's half — is skipped.

**A JavaScript engine** sees `if (":" == "<!--") then : 0` — a false condition
followed by a labelled statement, `then` being the label and `0` the statement —
and then `/*`, which opens a block comment that does not close until line 12.
The batch region, the shell region and the document line are all inside it.

**A browser** handed the raw file sees `<!--` inside line 1 and reads everything
through the `-->` on line 10 as an HTML comment.

### Lines 3 to 6 — the licence, and getting past it

`GOTO :W` and `:W` exist so that cmd.exe jumps over the two SPDX lines instead
of trying to run them as commands. The other three readers are already inside a
here-document, a comment or a comment.

### Line 8 — `EXIT`

To cmd.exe, the command that ends the process when the batch region falls
through to it. To the shell, the terminator of the here-document opened on line
2. The batch region ends and the shell region begins on the same word.

### Line 10 — the second seam

```
exit $?;:<<'//</script></body></html>' #-->
```

The shell exits here with the status of whatever ran last, and it never reads
another line — but it *parses* one more, and `<<'//</script></body></html>'`
opens a here-document that runs to the end of the file. That is why line 21 is
spelled the way it is: it is the terminator, and it has to be alone on its line
with nothing after it.

`#-->` closes the HTML comment that line 1 opened. To JavaScript the whole line
is still inside the block comment from line 1.

### Line 11 — the document

The first `<!doctype html>` in the file, and it has to stay the first one: the
launcher cuts the document from the doctype to the `<script` tag after it, and
the page script from that same tag. `test/parse.sh` refuses a source where
anything above the doctype so much as mentions a doctype, and `assemble.sh`
refuses a `style.css` or a `body.html` carrying one.

It used to have to be one physical line, because the style and the body were
folded and spliced into it. They are `@@include`d parts now, so the document is
a region: the doctype opens it, `style.css` and `body.html` arrive whole, and
`</style></head><body>` sits between them. An app's stylesheet can be a
stylesheet.

### Line 12 — `<script type=text/javascript>//*/`

The same twelve characters doing two different jobs. Read as part of the file,
`*/` closes the comment JavaScript opened on line 1, so a file-level engine
starts executing at line 13. Read as part of the document, the browser has just
opened a script element and `//*/` is the first line of it — a line comment.

### Lines 16 to 23 — the branch each engine gets, and the one it does not

```
    /*@cc_on
        @if (@_jscript_version >= 7)
            ...jsc/parts.list...
        @else @*/

    ...else/parts.list...

    /*@end @*/
```

One conditional with both of its branches used, which makes three regions of
JavaScript in this file rather than one: `js/`, which everybody compiles, and
these two, which are each the half of the program one reader never sees.

To gjs, QtWebEngine, JavaScriptCore and every browser, everything from `/*@cc_on`
to the `@*/` on the `@else` line is a block comment: the typed JScript.NET is
inside it, and the file resumes at `else/`. To `jsc.exe` it is conditional
compilation, the `@if` is true, and the `@else` branch is skipped — so `jsc/` is
the only part of the file that compiles for it and `else/` is the only part that
does not.

`else/` is named for the branch and not for an audience, because its audience is
everyone except one compiler. What is in there is what no `jsc.exe`-compiled
program can reach: the app, the macOS and gjs drivers and their palettes, the
engine dispatch for every engine that is not the Windows launcher, and the place
a line of output goes when `printerr` or `console` is the way to write one.

### What moving it bought

An artifact that carries no app at all, measured on a Windows 11 client:

| | before | after |
|---|---|---|
| the compile `cmd/launcher.cmd` does once | 1.10s | 0.89s |
| the assembly it produces | 700,416 B | 460,800 B |

And with a 731 KB `app.js` — large enough to see, not realistic — the compile was
1.73s and the assembly 5,209,600 bytes before any of this, against 0.89s and
460,800 after: an app costs the Windows launcher nothing now, because the app is
not in it.

`prefix`, the milliseconds a launch spends before the driver's first line, is the
half that is paid every time rather than once. Loading and JIT-ing the assembly
is most of it, and the assembly is a third smaller.

What it bought the author is the larger half. Every rule this project used to
hand out about app code — write `eval("window")` and not `window`, do not declare
`var int` or `var short`, ES5 only because one of the five engines is a .NET
compiler from 2005 — was one rule wearing five hats, and it is gone. The engines
that run `runWeb` are the four web engines, and an app may use whatever they have.

### The dispatch, and the policy that followed it

`run()` used to ask which engine was running, five times, through `eval`:
`hasGlobalExpr("typeof ObjC !== 'undefined' && typeof $ !== 'undefined'")` and
four more like it, each a string because the function was compiled by a typed
compiler that resolves globals and has none of those names.

It is not a question any more. Which engine is running is decided by which branch
this program was built from, so `jsc/dispatch.jsc` answers it for the Windows
launcher — `runEngine` is `runWindows`, and a program in which that line compiled
*is* the Windows launcher — and `else/engine.js` answers it for everyone else, in
the plain spelling. `js/run.js` calls whichever is there.

That is what let the document's content policy become `script-src 'none'`. It
said `'unsafe-eval'` for exactly those five calls: the page runs this dispatch on
load, so the one document in this project that is meant to be unable to execute
anything had to permit `eval` in order to find out where it was. The same move
took the three `eval` calls out of `note()`, which is why `else/note.js` exists.
`test/neutrinoattack.js` reports `evl=BLOCKED` on every engine, beside the
inline-script check it has always carried.

What it costs an app is real: `eval` and `new Function` no longer run in this
document. An app that wants them writes its own `html/policy.html`, which is an
overlay part like any other.

### The one rule each branch still has

Each is a shape `test/parse.sh` refuses:

- **Nothing under `jsc/` may contain `*/`.** JavaScript has no nested block
  comments, so a single one there ends the outer comment early and spills typed
  JScript.NET into three engines at once. `assemble.sh` strips only line comments
  in those files for the same reason.
- **Nothing under `else/` may contain `@if` or `@end`,** in code, in a string or
  in prose. `jsc.exe` skips a branch by scanning it for its own directives rather
  than by ignoring it, and it does not stop at a comment or a quote — which
  matters for prose because `--comments` ships it.

  Measured on a Windows 11 client, one spelling per build:

  | in the skipped branch | `jsc.exe` |
  |---|---|
  | `@end` alone | JS1104, unmatched `@end` — and the rest of the branch is then compiled as JScript.NET, so `window`, `document` and `imports` are reported undeclared |
  | `@if` alone | JS1029, expected `@end`; JS1107, unexpected end of source |
  | `@if` … `@end` on one line | compiles |
  | `"a@end.example"` in a string | ended the skip; the compiler resumed mid-string and reported an unterminated string constant against a line of the app |
  | `@endpoint`, `@else`, `@cc_on`, `@set`, a bare `@` | inert |

  The first row is the useful one twice over: it is the failure this rule exists
  to prevent, and the three undeclared names in it are the proof that the branch
  is otherwise never compiled.

  A balanced pair compiles, and that is a trap rather than an allowance — the
  paragraph in `else/entry.js` that explains this rule used to name both
  directives on one line and passed for that reason alone. `test/parse.sh`
  refuses either, because balance is not a property a comment can be asked to
  maintain. Everything else in an app is fine: `class`, arrow functions,
  template literals, and text that is not JavaScript at all all compiled without
  a word.

The `jsc/` region is a `parts.list` like `sh/` and `js/` rather than one named
file. It became one when the Evergreen path arrived and there were two kinds of
thing that have to be typed .NET — a delegate the runtime hands a type for, and a
set of types this file builds itself — and `import` is the region's, not any one
part's, so the imports are a part of their own at the top. Those imports now sit
below every line of `js/`, which is where moving the block to the seam the app
needed put them, and `jsc.exe` reads them there.

### Line 25 — `@@include js/launch.js`

`NeutrinoWebview.run();`, and it is in the skeleton rather than at the end of
`js/parts.list` because it has to be below the `@else` branch — everything it
starts has to be assigned before it runs.

### Line 26 — `//</script></body></html>`

The here-document terminator from line 10, a JavaScript line comment, and the
end of the document. `extractPageScript` finds it with `lastIndexOf`, so it is
also where the page script stops.

## The parts

| Path | Language | What it is |
|---|---|---|
| `cmd/launcher.cmd` | Windows batch | compiles the file with `jsc.exe`, caches the exe against a digest of the source, writes the manifest and starts it |
| `sh/script-path.sh` | POSIX shell | the artifact's own path, which every lane below needs |
| `sh/loaders.sh` | POSIX shell | removes every environment variable that names a file to load or a program to run |
| `sh/qt.sh` | POSIX shell | finds a QML runtime and hands it a document with no name |
| `sh/webkit.sh` | POSIX shell | measures whether bubblewrap can start, before anything else does |
| `sh/macos.sh` | POSIX shell | the seatbelt profile, and the JXA launch |
| `sh/pygobject.sh` | POSIX shell | the lane of last resort |
| `sh/dispatch.sh` | POSIX shell | the engine search, and the refusal when there is none |
| `qml/window.qml` | QML | the Qt window, inside an unquoted here-document — so `$qml_url` is the shell's and **no backticks** may appear |
| `py/shim.py` | Python | the PyGObject lane, inside a quoted here-document |
| `jsc/imports.jsc` | JScript.NET | the region's `import` lines; one compilation unit, so they are everyone's |
| `jsc/sink.jsc` | JScript.NET | the WebMessageReceived delegate and the navigation policy, which cannot be written in the shared JavaScript |
| `jsc/interop.jsc` | JScript.NET | the Evergreen path: COM interfaces and P/Invoke stubs built with `Reflection.Emit`, because `jsc.exe` will declare neither |
| `html/document.html` | HTML | the doctype, the head, the content policy, and the two includes the early shell arrives through |
| `style.css` | CSS | the early shell's stylesheet; an app lays its own over it |
| `body.html` | HTML | the early shell's markup; likewise |
| `config.json` | JSON | the window, laid into `js/config.js` verbatim |
| `html/policy.html` | HTML | the document's content policy; the offline overlay replaces it |
| `jsc/dispatch.jsc` | JavaScript | `runEngine` for the Windows launcher, which is every program this branch compiled |
| `else/engine.js` | JavaScript | `runEngine` for the other four engines, in the plain spelling, since no compiler resolves these globals |
| `else/note.js` | JavaScript | where a line goes when `printerr` or `console` is how you write one |
| `else/entry.js` | JavaScript | `runWeb`, and the `app.js` inside it |
| `else/driver-gjs.js`, `else/driver-macos.js` | JavaScript | the two lanes no Windows exe can reach, and the WebKit2 version probe with them |
| `else/theme-gtk.js`, `else/theme-macos.js`, `else/macos-status.js` | JavaScript | their palettes, and the status line the macOS lane writes |
| `app.js` | JavaScript | the body of `runWeb`, which is where an app's code goes |
| `js/config.js` | JavaScript | declares `NeutrinoWebview`, and includes `config.json` as its config object |
| `js/*.js` | JavaScript | one group of members per file, assigned onto the object; the order is in `js/parts.list` |
| `js/launch.js` | JavaScript | `NeutrinoWebview.run();`, and it goes last — named by the skeleton, below the `@else` branch |

Every part is a document its own language can read on its own. `node --check`
passes on each `js/` file, `bash -n` on each `sh/` file, `python3` compiles the
shim, and the QML and the batch launcher are ordinary files of their kind.

That is what the shape costs. The members are `NeutrinoWebview.parseColor = ...`
assignments rather than `parseColor: ...` entries inside one literal, because a
run of entries out of the middle of a literal is not a document and no editor,
linter or checker can read one. `this` still means the object inside them, since
they are called as `this.parseColor(...)` from each other, and the order is free
except at the two ends: `js/config.js` declares the object first, and
`js/launch.js` starts it last, from the skeleton, below the branch that carries
the app.

Some things in here are not whole documents, and they are named rather than
hidden. `html/document.html` opens tags the skeleton's last line closes, which
is also the here-document terminator. `app.js` is the body of a function rather
than a program. `js/config.js` and `else/entry.js` carry an `@@include` and are
therefore templates rather than JavaScript — `test/assemble.sh` works out which
parts those are by looking for the directive rather than by keeping a list. And
the include lists are `.list` files rather than `.js` and `.sh` ones,
because a list of `@@include` lines is a manifest and not a program — giving it
a language's extension would make it the only lying file in the tree.

## Includes

`@@include <path>` on a line of its own, path relative to this directory, and
that is the entire directive. The line is replaced by the file, verbatim, at the
column the file was written at — there is no indenting, no substitution and no
conditional form, so a part reads exactly as it will ship.

Includes nest. `skeleton.cmd` includes `sh/parts.list`, which includes `sh/qt.sh`,
which includes `qml/window.qml` in the middle of a here-document.

Includes resolve against a search path. `--overlay <dir>` puts a directory
ahead of this one, more than one may be given, and the last named wins; this
directory is always last. Any part is overridable and not only the four an app
usually writes — an overlay carrying `js/policy.js` replaces the launcher's,
because whoever writes the overlay is whoever ships the artifact.

That is also what `build/testing` is: an overlay replacing the few parts a test
build varies. There used to be three such directories under `tier/`, a tier list
stamped into the config object, a `sed` that read it back at every launch, and
nine runtime conditionals that consulted it. All of it is gone, and the thing it
was trying to guarantee is now structural. A release build cannot be talked into
the testing scaffolding because the scaffolding is not in it.

The parts that exist to be replaced are worth naming, because each is a file
whose whole content is one `return`: `js/trace.js`, `js/windows-trace.js`,
`js/windows-libdir.js`, `js/windows-scriptpath.js`, `else/macos-status.js`,
`js/external-allow.js`, `sh/qt-sandbox.sh`, `sh/macos-confine.sh` and
`html/policy.html`. A variation point is a file here, and that is the whole
mechanism.

The expansion and all five strip rules are one recursive `awk` function, and
that is a platform fact rather than a preference. A shell function per language
and a `while read` loop per part is forty processes for one template; on Windows
process creation is the cost of everything, and forty became sixteen thousand
across a suite that builds fifty artifacts. One `awk` is one process.

Every path named anywhere in this tree is checked before a byte is written. The
expansion runs inside a pipeline, so an exit taken in there is an exit taken in
a subshell, and the assembly would otherwise carry on with a hole in it and come
out looking assembled.

## The strip

`assemble.sh` removes comments and blank lines by the rules of the language each
part is written in: `//` and `/* */` for JavaScript, JScript.NET and QML, `#`
for shell and Python, `REM` and `::` for batch. `skeleton.cmd` is never
stripped, because there is no language to strip it in — line 21 is a comment and
an end marker and a here-document terminator at once.

Three rules make the strip safe to run on source nobody in this repository
wrote:

- **Whole lines only.** A comment sharing a line with code stays. What that
  costs is a few hundred bytes; what it buys is that this program never has to
  decide whether a `//` inside a string is a comment.
- **There is no `//#` any more.** Four of them used to name regions a second
  program spliced between, and one outlived the splice for a while: the shell
  had to search the built file for that stamp and be told where to stop.
  `js/config.js` includes `config.json` as a literal now, so the artifact has
  the value instead of looking for it, and carries no marker of any kind. A rule about what the strip must not remove is one less thing to be
  right about.
- **An SPDX tag is not prose.** A build step that removes a licence notice from
  somebody else's source is not a size optimisation. A comment line carrying one
  is kept, and a block comment carrying one is kept whole — the lines of a block
  cannot stand on their own, so the choice is the whole block or none of it. An
  author who wants the notice and not the essay writes the notice as two line
  comments above the block, which is what `pages/demo/app.js` does.
- **A stylesheet is the exception, both ways.** CSS comments come off wherever
  they sit on the line rather than at the left margin only, and they come off
  under `--comments` as well — including an SPDX one. `*/` closes the block
  comment the whole shell and document region lives inside, and a stylesheet is
  the one place an author writes that pair without thinking about it.
- **Multi-line strings are stepped over.** A JavaScript template literal and a
  Python triple-quoted string both span lines, and a line inside one that
  happens to begin with `//` or `#` is content. Parity is tracked on the lines
  that are kept and never on the comments, because prose in this repository
  wraps mid-backtick often enough that counting those would put half the parts
  into the literal state and strip nothing.

An app's `app.js` is a part like any other, so it goes through the same strip
and an artifact carries no more prose than the launcher does.

The assembly comes out with unix line endings whatever the checkout had. Git for
Windows checks this tree out with CRLF, and the programs that read a part here
disagree about it: `sed` and `awk` normalise on that platform and never show a
return to their caller, while `cat` and bash `read` pass them along. The
monolith went through sed and awk and nothing else, so it got unix endings by
accident; this does it on purpose, and `test/assemble.sh` builds from a CRLF
copy of the tree on every lane and asserts the artifact is the same bytes.

Each region can be checked by the language it is written in, on the text that is
about to ship: `bash -n` on the shell, `node --check` on the JavaScript,
`compile()` on the Python. A strip that took one line too many is a syntax error
here rather than an engine that opens no window three suites later. QML and
JScript.NET have no checker to run; they are covered by the lanes.

`./assemble.sh --check` runs them and writes nothing, and every build runs them
unless it passes `--no-verify`. They reach into the overlays, so an app whose
JavaScript does not parse is refused here rather than by an engine that opens no
window. `test/mkapp.sh` passes `--no-verify` anyway: fifty builds out of one tree
means fifty `node` startups, which was a step that timed out at five minutes on
the Windows runner with nothing else wrong in the job, and the artifacts that
matter go through `test/parse.sh`, which reads the built file.

## Working on it

```sh
# the launcher on its own, with its own greeting in it
./assemble.sh /tmp/plain.cmd

# an app, built from a directory laid over this one
./assemble.sh --overlay ../myapp /tmp/myapp.cmd

# either of those with every comment still in it
./assemble.sh --comments --overlay ../myapp /tmp/readable.cmd

# the region checks on their own, writing nothing
./assemble.sh --check
```

`--comments` is what to reach for when a lane is failing and the artifact has to
be read.

Adding a part is a file plus a line in the include list beside it. Moving code
between parts changes nothing about the artifact, which is what
`test/assemble.sh` measures.
