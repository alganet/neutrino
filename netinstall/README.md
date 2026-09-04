<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# netinstall

A name-addressed launcher. It is a small compiled binary that derives everything it does from
its own filename — rename it, and it fetches and runs something else.

```
demo-neutrino-alganet-github-io-3a1b2c3d4e5f60718a1b2c3d4e5f60718
└──┘ └──────┘ └──── host ─────┘ │└─────────────pin──────────────┘
file  dir                       └ shape 3: one directory, and the file is named

  fetch  https://alganet.github.io/neutrino/demo.cmd
  verify sha256 starts with "a1b2c3d4e5f60718a1b2c3d4e5f60718"
  run    sh ~/.cache/neutrino/apps/demo-neutrino-alganet-github-io-3/demo.cmd
```

No config file, no registry, no subcommand, no state that isn't derivable from the name.

This is a separate subproject. `neutrino` itself is unchanged and still works as a plain script;
you never need netinstall to run one.

There is a live one at **<https://alganet.github.io/neutrino/>**, which publishes a sample app
alongside netinstall binaries whose filenames already pin it — nothing to rename.
[`pages/`](../pages/) is what builds it.

---

## Names

The name is the URL read inside-out — the file, then its directory, then the host's labels in
the order anyone writes them — and the token comes last.

```
[<file>] "-" [<dir>] "-" <label_1> "-" ... "-" <label_n> "-" <shape><pin>  [".exe" on Windows]
```

The host has no fixed label count and neither does a path, so something has to say where one
stops. That is the **shape**: the token's first character, and the one fact the name cannot
carry by itself.

```
shape = 2 × directories + (1 if the file is named)
```

| shape | example | resolves to |
| ----- | ------- | ----------- |
| `0` | `alganet-dev-0<pin>` | `https://alganet.dev/netinstall.cmd` |
| `1` | `calc-alganet-dev-1<pin>` | `https://alganet.dev/calc.cmd` |
| `2` | `demo-alganet-github-io-2<pin>` | `https://alganet.github.io/demo/netinstall.cmd` |
| `3` | `calc-toy-alganet-dev-3<pin>` | `https://alganet.dev/toy/calc.cmd` |

- **Odd shapes name the file; even ones take `netinstall.cmd`.** That default is what makes
  `alganet-dev-0<pin>` a whole spec, and it is why shape `2` covers a project GitHub Pages site
  — `alganet.github.io/demo/` — without writing `demo` twice.
- **One directory is the cap.** Shapes `4` through `f` are unassigned and every one of them is
  refused by name, which is also where a second digest algorithm goes if there is ever one. That
  is why the shape and the algorithm share a character instead of taking two: `0` has always
  meant SHA-256 and still does.
- The **pin** is 32 to 64 lowercase hex characters of the SHA-256 the fetched file must start
  with. **Minimum thirty-two**: sixteen is 64 bits, which puts a second preimage out of reach and
  does not touch the attack that matters when you did not build what you are pinning — a
  publisher grinding two files to one truncated digest, benign to get pinned and hostile to
  serve, at about 2^32. Longer is stronger and free. A name below the floor is refused by length,
  and the refusal says which rather than leaving you to count.
- The pin is in the binary's name and in **no directory netinstall creates**: the cache is keyed
  on everything *but* the pin, so lengthening a pin re-verifies against a blob already there. The
  shape stays in the key, because two names that differ only in shape point at different URLs.
- **`_` means `-`** in the resolved value, so `my_app-example-com-1<pin>` resolves to
  `https://example.com/my-app.cmd`. DNS labels cannot contain `_`, so only file and directory
  names give anything up.
- Only `[a-z0-9_-]` is accepted. Rejecting everything else also rules out path traversal.

### The host labels are not reversed

They used to be — `neutrino-io-github-alganet-0<pin>`. Reversal pays for itself only if something
groups by suffix, and that needs a public suffix list this does not carry, so it cost a reading
of `app-uk-co-example-www` and bought nothing. Reading them forward also makes the whole name one
uniform walk from the file outward to the TLD, which is what leaves the shape with exactly one
thing to say.

### A miscounted shape

Nothing can catch it. `calc-toy-alganet-dev-0<pin>` is shape `0`, so all four leading segments are
host, and it resolves to `https://calc.toy.alganet.dev/netinstall.cmd` — a well-formed URL that is
simply not the one meant. The pin is what makes that safe: the wrong URL either 404s or returns
something whose digest does not match, so a miscount **misfetches and cannot misrun**. The one
case the parser does refuse is a shape that leaves nothing at all for the host, since that is a
miscount with no valid reading.

Copy or hardlink the binary to rename it. **Symlinks do not work**: the real executable path is
used, never `argv[0]`, because deriving a fetch URL from a caller-controlled string would make
this a confused deputy.

**Except on OpenBSD**, which has neither `/proc` nor `KERN_PROC_PATHNAME`, so there is no way to ask
the kernel what is running. There netinstall resolves `argv[0]` instead, and the guarantee that the
name cannot be spoofed by the caller does not hold.

On the other two BSDs the kernel is asked, but not with the same words: FreeBSD hangs
`KERN_PROC_PATHNAME` off `KERN_PROC` with the pid last, and NetBSD makes it a subcommand of
`KERN_PROC_ARGS` with the pid at `mib[2]`. Both constants exist on both systems, so for as long as
this file had a BSD branch NetBSD was asked FreeBSD's question — and answered it with **success and
zero bytes**, which was taken for an answer. Every name on that platform was then refused as
`"" is not a valid spec`. The length is checked now as well as the return value, and the path the
kernel returns is resolved before use, because NetBSD hands back the name the exec used and a
symlink would otherwise have resolved to itself.

## Options

```
--info      show what this name resolves to, then exit
--fetch     download and verify, but do not run
--verify    re-hash the cached script and report
--help, -h
--version, -v
--          end netinstall options; the rest goes to the script
```

`--info` is the audit path — it prints the resolved URL, the full SHA-256, every cache path, the
downloader command that would run, **what that downloader reads besides that command**, the
confinement that would be applied, and how much of the environment would be dropped. It describes
without enforcing, so it changes nothing and reports what a real launch would do.

## The window

A cold run downloads before it can launch anything, and until this it did that behind nothing at
all: `curl -fsSL`, `wget -q`, no output, for up to the 120 second deadline. So a cache miss opens a
small window with a moving indicator in it, and closes it when the wait is over.

**When the wait is over is not always when the download is.** On Windows this program does not
exec — it spawns `cmd.exe` on the `.cmd` and waits for it — so the window stays up over that too,
and comes down when the `.cmd` returns. That matters there more than anywhere: what happens after
the bytes stop is a `certutil` over the whole script and a full `jsc.exe` compile — on the launch
that owes one. It used to be every launch, because there was nowhere to keep a compiled exe the
app itself could not rewrite; the build slot is that somewhere. The download is the short half of
that wait and it used to be the only half wearing a window. It still comes down one
`CreateProcess` short of the app's own window, which is as far as anything here can see.

Everywhere else the window goes when the bytes stop, and that is the platform rather than a
choice: `nt_exec` execs `/bin/sh`, so there is no "after" — the process that would hold the window
has become the app. The last moment this program exists is already too late, because the run
phase's confinement runs first and after it the kill that removes the forked holder no longer
reaches it. What is left to cover there is a digest, a rename and a link, which is not a wait.
`NT_SPLASH_OUTLIVES_HANDOFF` in `splash.h` is the one place that rule is written down, and
`splash.sh` asserts it by order: the payload's own output and the teardown line go to one stream,
and which of the two comes first is the whole reading.

Only a cache miss. A run that already holds the verified payload has nothing to wait for and goes
straight to the script, drawing nothing — the window marks a download, not a launch.

And only a download that takes long enough to be worth one. The window is not raised until the
downloader has been running for 100 ms, so a small payload from a near host — which is most of
them, once — never gets a window at all. Once raised it stays up for at least 400 ms, however soon
the bytes stop: a download that crossed the first line by a hair is otherwise a window that appears
and is gone inside a blink, which is not information. The delay is measured inside the fetch,
because the wait it is about is the fetch's own and nothing outside it can see how far along that
wait is; the hold is the splash's, because it is the same on every platform and about nothing but
the window. A testing build reads `NEUTRINO_SPLASH_HOLD_MS` to lengthen the hold — it is how the
suite keeps the window still for a photograph, and how a person gets to look at it for longer than
four hundred milliseconds — and it can only lengthen it. A release binary reads nothing.

It carries no words, and that is a limit rather than a taste. What an app looks like — its title,
its size, its colour — lives inside the payload, and this runs before there is a payload to read it
from. A launcher that invented an appearance here would be describing something it has not
downloaded yet.

It said `Loading...` until recently, and two things were wrong with that at once. **Language**: a
launcher that has not downloaded anything yet has nothing to read a locale out of, so the word could
only ever be English, and shipping one language to everybody is a choice nothing else here makes.
**Font**: five platforms drew that word five ways — the X server's `fixed`, a bitmap table compiled
into the binary for wayland, `DEFAULT_GUI_FONT` on Windows, whatever `NSTextField` picked on macOS —
and the CI sheets showed it, four lanes photographing one feature and no two pictures alike.

What replaced it is twelve cells in a row, three of them dark, the dark run moving by one cell every
90 ms and wrapping, inside a one-pixel edge each platform draws for itself — X11 had a border width
of 1, Windows had `WS_BORDER` in a colour the system picked, and macOS had nothing, which is three
answers to a question the window should be answering once. It belongs to no language, and it is rectangles — which is the one thing all
four mechanisms can be asked for at exactly the same size, so the four lanes now photograph the same
260×96 window with the same track in the same place. It says nothing about how far along the
download is and must not: the size of what is being fetched comes from a header this program does
not require and does not check, so a bar claiming a fraction would be claiming one it cannot know.
All of the geometry and both colours are in `splash.h`, once, because five files draw them.

| Platform | Drawn by | Notes |
|---|---|---|
| Windows | `user32`, in this process, on its own thread | no child process, so nothing that looks like an unsigned download launching a scripting host |
| macOS | AppKit, in a second copy of this binary | AppKit is main-thread only and the main thread is the one waiting on the download; see below |
| Linux, BSD | the wayland protocol, over the compositor's socket | preferred whenever `WAYLAND_DISPLAY` is set |
| Linux, BSD | the X11 protocol, over the server's socket | the fallback, and the only path on an X session |
| anything else | nothing, silently | a machine that cannot draw a window still installs |

No toolkit is linked and none is loaded. The Linux binaries are static musl, where `dlopen` is a
stub that always fails, so a toolkit could only be reached by linking it — which would trade a
launcher that runs anywhere for one that runs where its libraries are. Both display servers are
spoken directly, as a socket and a few dozen bytes of structs. macOS is the exception and can
`dlopen` AppKit, because static linking is unsupported there and every binary is already dynamic;
nothing is linked at build time, so the cross-compile still needs no SDK.

Wayland costs more than X11, for a reason worth knowing: X11 has `PolyFillRectangle` and fills the
cells for you, and wayland has no drawing in it at all. The compositor takes finished pixels, so
that path writes every cell's pixels itself and hands over a whole new buffer per frame — two of
them, alternated, so that a frame is never written into the buffer the compositor is reading. It
also cannot place its own window — position is the compositor's to choose — while the X11 path is
override-redirect and centres itself. That difference in placement is the one thing the four lanes'
pictures still disagree about, and it is not this program's to settle.

The animation is a clock in whatever loop each platform already had: `poll` with the frame as its
timeout in the two socket paths, a `WM_TIMER` in the message pump on Windows, and a hand-pumped
event loop on macOS — where `-[NSApplication run]` had to go, because a timer there needs a target
object and a target object means building an Objective-C class at runtime. Each of them advances the
phase against the clock and not against how often it was woken, so a busy display server cannot
speed the window up.

On every platform but Windows the window is held by a separate process, because between raising it
and lowering it this program is blocked in `waitpid` on the downloader, and neither display server
tolerates a client that stops reading its socket for two minutes. Those processes are killed when
the download ends. They are also killed if this program dies without getting the chance —
`PR_SET_PDEATHSIG` on Linux, and a pipe whose end-of-file the child watches for on macOS, which has
no equivalent.

The window comes down when the download does, and not at the moment the app appears. That is the
one place a gap is visible, and it is deliberate: the run phase's confinement scopes signals, so
after it there is no way left to reach the process holding the window. A teardown scheduled any
later is a teardown that deadlocks.

macOS re-executes this binary with `--splash <deathfd> <readyfd>` to get a process whose main
thread is free for AppKit. It is the only argument netinstall has that is not for a person to type,
and the only departure from having no subcommands at all; that copy installs nothing and draws until
it is killed. The two descriptors are a pipe each way: the parent holds one open so that its own
death is an end-of-file the child exits on, and the child writes a byte down the other once the
window is actually on screen — so the answer this platform reports is a window that exists, and not
a process that was started.

## Windows has no console

The Windows binaries are linked for the GUI subsystem, so running one no longer opens a black
window. `CREATE_NO_WINDOW` goes on both spawns for the same reason — without it, stripping this
program's console only moves the problem, and Windows hands a fresh console to `curl.exe` during
the fetch and to the `cmd.exe` that runs the payload.

**This reaches the payload.** netinstall runs an arbitrary `.cmd`, and one that prints output or
waits for input now does so with nowhere to write and nobody to type. That is the intended trade for
a launcher whose job is opening windowed apps, and it is the one behaviour here that a payload can
notice.

Diagnostics do not disappear with the console. A redirected stderr is inherited and keeps working,
so `netinstall 2>log` is unchanged; a netinstall started from a terminal attaches to the console
that is already open, so nothing is lost there either and no window is created to do it; and a run
with neither — launched from Explorer — collects what it wrote and shows it in a message box before
exiting. A refusal nobody can read is a refusal that did not happen.

## Layout

```
$NEUTRINO_HOME/                    # XDG_CACHE_HOME/neutrino
                                   # ~/Library/Caches/neutrino
                                   # %LOCALAPPDATA%\neutrino
├── blobs/<full-sha256>            # content-addressed, read-only, every version
└── apps/<spec without the pin>/   # shape kept, pin dropped
    ├── <file>.cmd                 # read-only, hardlink to the current pin
    ├── <file>.build/              # writable only on a launch that owes a build
    ├── <file>.build.stamp         # what is in it, and what it was built from
    └── <file>/                    # the always-writable directory
```

**The app directory is keyed on the app, not the pin.** A new pin of the same name, shape and host replaces
the launcher in place and inherits the directory, so whatever the app keeps there survives a version
change. That is the difference between an update and a reinstall, and it matters concretely: on
Windows neutrino downloads the WebView2 package into that directory — 8.8 MiB fetched, 45.4 MiB on
disk — and a per-pin directory paid that again for every version.

Consequences worth knowing:

- **Last pin wins.** Two pins of the same app do not coexist; launching one replaces the launcher for
  the other. There is no way to run two versions side by side, by design.
- **Versions of an app share state.** A later version can alter what an earlier one reads back. They
  come from the same name and host, so it is the same publisher either way — but if you pin a version
  specifically because you audited it, note that a subsequent pin can leave things behind for it.
- **Nothing is re-downloaded when switching back.** `blobs/` is content-addressed and keeps every
  version ever fetched, so re-pinning an older one is a relink. It also means `blobs/` grows until you
  delete it.
- **Uninstall is `rm -rf apps/<spec without the pin>/`**, which takes the app and its state together.

The script sits one level *above* every directory an app can write, so an app cannot rewrite the
launcher it was verified from. neutrino puts its own generated files in `<name>/` because it
derives that path from the script's own location, so this costs nothing.

`<file>.build/` is the exception that proves the sentence, and it is the subject of
[The build slot](#the-build-slot-and-the-launch-that-owes-a-build) below: it is writable on
the one launch that has a program to build and read-only on every launch after it, and it is
never the script.

The pin is re-checked on every launch, not just on download, which keeps the name-to-content
binding true even where no confinement is available.

Before running an app, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`
and `TMPDIR` are redirected into its own directory. That is what makes "writable footprint ==
app dir" true without needing a read allowlist. `HOME` is deliberately left alone, because
overriding it breaks `$XAUTHORITY` discovery.

`TMPDIR` is not redirected on macOS: `NSTemporaryDirectory()` is what Cocoa actually reads, it
expects the Darwin per-user temp directory, and the seatbelt profile already allows writes there.
Overriding it only makes Foundation and its callers disagree about where files went.

## The environment

The rest of the environment is reduced to an allowlist before the script starts, on **every**
platform — including the ones that get no confinement at all. A filesystem sandbox does not touch
environment variables, and some of the most valuable things on a developer machine live nowhere
else: `SSH_AUTH_SOCK` is a live agent that will sign anything handed to it, and CI tokens and cloud
keys are routinely just a variable in a shell.

It is an allowlist rather than a denylist on purpose. A denylist has to enumerate every
secret-shaped name anyone has ever invented and silently passes the next one; an allowlist passes
only what a toolkit is known to need. What comes through is the locale and session variables, the
display (`DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`), the `XDG_*`, `GTK_*`, `GDK_*`, `QT_*` and
Mesa namespaces, the handful of names cmd.exe and the CRT need on Windows, and anything starting
with `NEUTRINO_`. `LD_*` and `DYLD_*` are absent by construction. `--info` reports how many
variables that drops.

**How they are dropped, because for a while the answer mattered.** On POSIX the kept entries are
collected into a new array and `environ` is pointed at it. Nothing is removed by name, so there is
no name to spell and no walk to get stuck in. The first version did remove names one at a time with
`unsetenv`, restarting the walk after every removal — `unsetenv` rewrites `environ` underneath the
caller — and bounding the restarts by the number of entries it had counted. A name it could not
spell was then a name the next pass found in exactly the same place: the walk stopped at it, and
everything the allowlist was going to drop after that point went to the app while the count went on
saying otherwise. Two entries could do it — a name longer than 255 characters, which the drop
truncated into something that did not exist (and occasionally into the name of a variable the
allowlist meant to *keep*), and an entry whose name is empty, where `unsetenv("")` is `EINVAL`.
Both were measured on all four POSIX lanes and both are closed; `netinstall/test/envlen.sh` asserts
the readings in both directions. Windows still removes by name, because its environment is a block
owned by the CRT rather than an array this program may replace — there the name is built on the
heap at whatever length it is, and one that cannot be built is reported rather than counted.

**A prefix admits a namespace, not every name in it.** A toolkit namespace is mostly modes and
sizes, but it also contains the names that answer *which file should I load*, *which program should
I run* and *should I sandbox myself* — `GTK_MODULES`, `GDK_PIXBUF_MODULE_FILE`, `QT_PLUGIN_PATH`,
`QTWEBENGINE_PROCESS_PATH`, `WEBKIT_INJECTED_BUNDLE_PATH`, `WEBKIT_EXEC_PATH`, `LIBGL_DRIVERS_PATH`,
`VK_LAYER_PATH`, and `QTWEBENGINE_CHROMIUM_FLAGS`, which Qt appends to Chromium's own command line.
Those are matched by shape rather than by a list, so a knob a toolkit grows later is denied before
anyone here hears about it, and they are dropped even though their prefix is admitted. Names that
carry data rather than code stay: `XDG_DATA_DIRS` and `GSETTINGS_SCHEMA_DIR` point at icons and
schemas, and `XDG_RUNTIME_DIR` at the directory holding the session's sockets — dropping that one
would cost every Wayland session its display and buy nothing, since a socket is not something this
process loads.

That this is worth doing at all is a measurement rather than an argument, and it is in
`netinstall/test/env.sh`: `GTK_MODULES` loads the file it names into the app, and
`WEBKIT_INJECTED_BUNDLE_PATH` loads one into the *web* process, the one holding page content;
`--renderer-cmd-prefix` inside `QTWEBENGINE_CHROMIUM_FLAGS` chooses the program the renderer runs.
Neither sandbox covers for it — both platforms refuse to `execve` a file the app has written and
then map a library out of that same directory without a word, in both tiers, because the rights
these sandboxes mediate are about `execve` and not about `mmap`. On Windows nothing changes: that
allowlist admits one prefix, `PROCESSOR_`, so `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER`, `COR_PROFILER`
and `DOTNET_STARTUP_HOOKS` were already dropped and are now asserted to stay that way.

Worth being precise about what this buys. A secret that exists **only** as a variable is now
completely out of reach. A socket whose path is guessable — the session bus at
`$XDG_RUNTIME_DIR/bus`, X11 at `/tmp/.X11-unix/X0` — is not: dropping the variable raises the bar,
it does not close the door, and on Linux `/proc/<pid>/environ` of your other same-uid processes
stays readable anyway. Closing those needs the mechanisms below, and on Linux not even those are
enough today.

## Inherited descriptors

Whatever the invoking shell had open is otherwise still open in the app: a log file, a lock, a pipe
to something else, an fd a caller meant for a different program entirely. None of it is reachable
by path, so no filesystem rule closes it — an already-open descriptor is never looked up again.
Only 0, 1 and 2 survive into the script, and into the fetch child.

A script that expected an fd on 3 stops getting one. That is intended, and it is the reason this is
written down rather than left as a detail.

**Windows too, but only where it can be done safely.** The launch goes through `CreateProcess` with
an explicit handle list, which is the only way to say "these and nothing else" — `bInheritHandles`
on its own is all-or-nothing.

Console handles are what complicate it. They cannot appear in a handle list, because `CreateProcess`
refuses the call outright if one does, and a handle named in `STARTF_USESTDHANDLES` must be in the
list or the child receives an invalid one. Both rules cannot hold at once for a console, so there
are three cases:

| standard handles | what happens |
|---|---|
| all files or pipes | restricted to exactly those |
| none a file or pipe | nothing inherited; a console child attaches to the parent's console and gets working handles anyway |
| a mixture | left alone |

The mixture is a real invocation — `app.exe > out.txt` leaves stderr on the console — and there is
no way to restrict it without either breaking the redirection or handing the child a broken handle.
Stray inheritable handles come from scripted and redirected launches, which is the first case, so
the case that can be covered is also the one that matters. If the list cannot be built at all, the
app is given no inherited handles rather than all of them, and it says so on stderr.

## Core dumps

A crash is a write the confinement never sees. `core_pattern` normally pipes the dump to
systemd-coredump or apport — a process outside the sandbox, storing it outside the app dir — so an
app that crashes on purpose gets bytes written somewhere no rule here reaches, as many times as it
likes. `RLIMIT_CORE` is set to zero so no core is produced at all.

It applies on every POSIX platform, confined or not, and `--info` reports it on its own line rather
than folding it into the confinement description, because it is not confinement.

## Trust model

**HTTPS is the trust anchor, not the pin.** There is no bundled TLS stack and no bundled CA set —
the fetch is delegated to the machine's own `curl` (or `wget`), using the OS trust store and the
user's own curl configuration. Nothing here expires or rots, and the trust decision stays where
the user can see and change it. This is the same posture as `curl | sh`.

`curl` is resolved from absolute paths rather than `$PATH`, so a planted `curl` cannot take over
the fetch. That list has to carry every prefix a platform actually installs into: it did not have
`/usr/pkg/bin`, which is where pkgsrc puts everything, on the one platform whose base ships neither
downloader — so netinstall could not fetch anything at all on NetBSD.

Its own configuration is *not* scrubbed: that config is the trust anchor you chose,
and removing your control over it would defeat the point.

That is a decision about **trust**, and a config file is not limited to trust — so `--info` prints
a `config` line naming the files each downloader reads, beside the command line it prints, because
the command line alone is not the whole command. What a config can and cannot do, measured on curl
8.5, 8.7, 8.16 and 8.21 and on wget 1.21 and 1.25, across all six lanes:

| | |
|---|---|
| raise `--max-filesize`, lower `--max-time` | **no** — curl parses the config *before* the command line, so a last-wins option is won by the argv. The two bounds below hold. |
| redirect the download with `output` | **yes** — `-o` does not last-win, it pairs with URLs in order, so a config's `output` takes the URL and netinstall's `-o` is left holding nothing |
| …and where those bytes land | wherever the fetch phase allows: refused outside `blobs` on Linux, macOS and OpenBSD, and on Windows refused outside the payload file itself |
| the same through `wget` | **no** — `output_document` loses to the argv's `-O`, and that branch's two bounds are held by the kernel, where no config reaches |

A redirected download is a failed one: nothing arrives where netinstall told the downloader to put
it, so nothing is verified and nothing is cached. netinstall says exactly that — *"the downloader
reported success and wrote nothing to …"* — rather than reporting the missing file as an unreadable
payload, which is what it used to say.

**Two bounds, and where each comes from.** A host you have pinned is a host you do not trust, and
the pin is checked after the bytes are on disk — so something has to bound what a compromised host
can spend of yours before anything verifies it. The bounds are 16 MiB and 120 seconds, and `--info`
prints them on a `bounds` line, because on one of the two branches they are not visible in the
command it prints.

On `curl` both are flags: `--max-filesize` and `--max-time`. `--max-filesize` refuses a declared
`Content-Length` before any body arrives, and — measured on curl 8.5, 8.7, 8.16 and 8.21, across
Linux, macOS, Windows and OpenBSD — stops a chunked or close-delimited body mid-transfer at exactly
the limit. A response that declares a small length and then sends more gets no further than the
length it declared, and the digest refuses it.

The `wget` fallback is only used when no `curl` exists, and it can express neither bound: it has no
equivalent of `--max-filesize`, and `--timeout` is per read rather than a total, so a host sending
one byte a second satisfies it forever. So the kernel holds them instead — `RLIMIT_FSIZE` and an
`alarm` set on the child before `execv`, which no flag can be missing. Exceeding either kills the
downloader, and netinstall says which of the two it was rather than blaming the network.
`--https-only` governs recursive link following rather than redirects for a single file, so the
fallback also **refuses redirects entirely**. Install `curl` anyway if you have the choice: its
bounds stop the transfer, and the kernel's stop the process.

**The pin is a content pin.** It catches corruption, mirror drift, and a host silently changing
the file after you pinned it. Sixteen hex characters would be 64 bits, which puts a second
preimage — a host grinding a *different* file that matches a pin you already chose — out of
reach at 2^64.

What 64 bits does not buy you is collision resistance against a **malicious publisher**, who can
craft two files sharing a truncated digest for about 2^32 work: one benign to get reviewed and
pinned, one hostile to serve later. Thirty-two characters restores 2^64 against that attack too,
and thirty-two is the floor — for a while it was only the advice, while the parser went on
taking half of it. `--info` prints the full digest, so lengthening a pin further is a copy-paste.

Defends against: a network attacker between you and the host; the host silently changing the
file; mirror drift and corrupt downloads; a rogue `curl` earlier in `$PATH`; being tricked into
executing a binary rather than a script; and, where confinement lands, an app trashing the rest
of your `$HOME`.

Does not defend against: a publisher who is malicious from the start — you pinned their file and
asked for it to run; a compromised CA or a hostile OS trust store; a host grinding a short pin;
anything the webview is vulnerable to once it is running.

**Updates are out of scope.** A pin is immutable by construction, so a new version is a new name.
There is no update channel, no signature chain, no revocation. That is a feature; the honest cost
is that a publisher cannot push you a security fix.

**This runs any pinned text script, not just neutrino apps.** It will never execute a binary — a
payload containing a NUL byte is refused — but it does not check that what it runs is a neutrino
polyglot. That is why the confinement below matters rather than being a nicety.

## Confinement

**Every neutrino app runs confined, on every platform. There is nothing to turn on and nothing to
choose.**

- It cannot write to your files. It writes its own directory and the scratch and cache locations its
  web engine needs, and nothing else.
- It cannot gain privileges it was not started with.
- It cannot load code through the environment.
- The download that installed it could write nothing but the file it was downloading, and was
  verified against its pin before anything ran it.
- **Reads are not confined, on any platform.** An app can read what you can read.
- If any of that cannot be applied, the app does not start.

That is the whole of it. It is the same list on Linux, macOS, Windows and OpenBSD, and it is the
same list in every build — there are no tiers, no flags and no combinations. Where a platform needs
a different mechanism to keep one of those lines it uses one; where a platform could keep more than
the list says, it does not, because a promise that is stronger on three platforms than on the fourth
is not a promise, it is a support matrix.

The rest of this section is how each platform keeps that list, and what was measured to decide it.
A webview needs the GPU, DBus, the compositor socket, fonts and the network, so "deny everything"
was never on the table.

| Platform | What is applied |
|---|---|
| **Linux** | Landlock. Writes confined to the app dir, `/dev`, `/dev/shm` and `/proc/self` — this process's own entry and no peer's. Reads unrestricted. A seccomp filter on top. The session bus stays reachable; see [what is still open](#what-is-still-open). |
| **OpenBSD** | `unveil` + `pledge` execpromises, inherited by the child. Writes confined to the app dir and `/dev`, plus files that already exist under `/tmp`, and **write xor execute** on the app dir — the one directory the app can write to is one it cannot run anything from, at every tier. Reads are an allowlist too, because `unveil` is one. See the caveat below. |
| **macOS** | Seatbelt profile: `deny file-write*` outside the app dir, the Darwin per-user temp directory, four `~/Library` subtrees and six `/dev` nodes — the carve-outs are what CFPreferences and WebKit need and are listed in [write xor execute on macOS](#write-xor-execute-on-macos). Read denials on `~/.ssh`, Keychains, Mail, Safari and browser profiles, and denials on securityd, tccd, Apple Events and task ports. |
| **Windows** | Low integrity: writes outside the app dir fail, except the two places the label leaves open by design, `AppData\LocalLow` and `HKCU\Software\AppDataLow`. Plus a job object and every token privilege but `SeChangeNotify` removed. Measured: `%USERPROFILE%`, the user temp directory, `C:\Windows\Temp` and `HKCU\Software` all refuse. On a launch that owes a build, and only then, the [build slot](#the-build-slot-and-the-launch-that-owes-a-build) is writable too, and `--info` says so. |

Each of those sets is what `--info`'s `confine` line names, in full. It named the app dir alone
until it was measured: every platform grants writes somewhere else as well, deliberately and for
a reason, and a sentence that describes one of five is the same defect as a sentence that
describes none. The set was enumerated from inside the confinement on all six lanes —
`netinstall/test/writable.sh` is that measurement, and it now asserts every letter of it.

If nothing is available the binary **refuses to run**, naming what could not be applied. There is no
build that warns and continues; that used to be the default and `-DNEUTRINO_STRICT_SANDBOX` was the
flag that changed it.

### The fetch is a phase of its own, and it is confined too

The downloader is the one process here that reads bytes an attacker chose, off the network, before
anything has verified them. It gets its own, narrower confinement — writes confined to
`~/.cache/neutrino/blobs`, plus the handful of `/dev` nodes a downloader opens on macOS and in
and nothing else on Linux, macOS and OpenBSD.
`--info` prints it on a `fetch` line next to the run phase's `confine` line, so a platform that
applies nothing does not look like one that does.

**Windows confines it to a single file**, and it is the narrowest fetch grant here.
Everywhere else the downloader may write a directory; here it may write the payload and nothing
else — not even the rest of `blobs`. The mechanism is a low integrity token, and unlike every other
confinement in this program it is applied to the *child*: integrity is a one-way trip, and the
digest, the pin, the rename and the hard link all happen after the download returns, so a launcher
that lowered itself would trade the download's confinement for the install's. So netinstall creates
the destination, puts a `Low` label on that one file, spawns the downloader under a lowered token,
and **takes the label back off before hashing it** — while it is on, any low integrity process on
the machine can rewrite that file, and nothing re-reads it between the digest and the rename.

Two narrower-looking routes were measured and are not taken. Labelling the `blobs` **directory** is
the obvious version and is wrong twice: it lets every low integrity process on the machine write
there, and because the commit is a `CreateHardLink` — a second name for one file object, sharing its
descriptor — the label reaches `apps/<app>/<name>.cmd`, the file that is then run. A
**write-restricted token** admits only objects naming `S-1-5-33`, which is authority nothing holds
unless it asked for it; a trivial child runs under one, but `curl` returns `STATUS_DLL_INIT_FAILED`
under the same token even with the window station and desktop granted that sid. Reads are not
confined at either tier, for the same reason the run phase's are not.

The fetch refuses when nothing applied, on the same terms the run phase does. The answer used to be
thrown away, so a strict build downloaded the payload unconfined and refused afterwards — which is
not strict, it is late. `phases.sh` asserts both halves on every
platform, including that a strict build still fetches and runs when both phases *are* confined.

### The build slot, and the launch that owes a build

The Windows payload compiles itself. `jsc.exe` turns the polyglot `.cmd` into an exe, which is
about a third of a second, and until this it happened on **every** netinstall launch — the
launcher keeps its exe beside the script, that directory is the shelf, and the shelf is exactly
the place this design refuses to make writable.

So there is one more directory, `apps/<app>/<name>.build`, and netinstall opens it for writing on
the launch that owes a build and closes it again when the `.cmd` returns. A launch that does not
owe one grants nothing: the slot is read-only, the launcher runs what is in it, and nothing is
compiled and nothing is hashed.

**What decides.** `<name>.build.stamp` sits beside the slot, is written by netinstall at its own
integrity level and is never granted to anything. It holds the digest of the script the slot was
built from and the size and SHA-256 of every file in the slot. A launch owes a build unless all
of that still matches — so a slot holding a file the record does not name owes one too, which is
what a plant looks like.

That record is the difference between keeping the exe and trusting it. Without it, the pin would
stop reaching what actually runs: netinstall re-checks the `.cmd` against the pin on every launch,
but a cache keyed on nothing would let a same-user process at *this program's own* integrity level
replace the exe while the `.cmd` still passed. With it, the pin's guarantee survives the cache.

**The grant is a directory**, and that is wider than the fetch's and deliberately so. The launcher
compiles to `<name>.new<random>.exe` and renames — Windows will rename a running image but not
overwrite one — so the payload needs create and delete in the directory itself. netinstall cannot
pre-create a random name, so the fetch's one-file grant is not available here. What it costs is
that, for the length of a build run, any low integrity process on the machine can create, delete
and rename in the slot.

**The label comes off before the record is taken**, which is the fetch phase's rule and its
reason: while it is on, what the record would be vouching for can still change. `OICI` is
inheritable, so every file the payload created carries a label of its own and the revoke clears
each of them as well as the container. A revoke that could not close the slot empties it instead
and writes no record, so the next launch builds into a directory this one could not leave open.

**A payload that builds nothing gets an open slot on every launch, and that is
vacuous rather than lax.** There is nothing to record, so nothing is sealed, so the next launch
grants again. What the seal protects is the program that gets run out of the slot, and an app that
never puts one there has none to protect — the slot is a directory inside that app's own tree, and
writing it reaches nothing the app dir does not already reach. `--info` says so on every launch
rather than hiding it.

**A grant that fails is not a refusal.** Everywhere else here a confinement that did not apply is
a reason to stop, because what was promised did not happen. This is the other direction: the slot
is a relaxation, so a launch that does not get one is *more* confined, not less. netinstall says
so on stderr and the app compiles on every launch, which is what it did before any of this.

**The launcher is told nothing.** It finds the slot beside its own script and probes it, and the
slot being writable *is* netinstall having granted it this launch — no variable, no marker, and
nothing in the `NEUTRINO_` prefix the allowlist admits. It is `<name>.build` rather than `build`
because the launcher cannot tell this shelf from a source tree, and a `.cmd` next to an ordinary
`build/` directory is not exotic.

**Windows only.** Everywhere else `nt_exec` execs, so there is no "after" in which to take a grant
back — the same asymmetry `NT_SPLASH_OUTLIVES_HANDOFF` names — and no other platform's launcher
compiles anything.

### What was measured

Every mechanism below was applied on its own to a real webview, on both Linux
engines, on macOS and on Windows, with an unrestricted control run before and
after each table. The harness that did it is not in the tree: it was a
throwaway that swapped the confinement for one named technique under
`-DNEUTRINO_TESTING`, and it was deleted once it had answered. What it answered
is here, because that is the part worth keeping. The controls are not decoration: `landlock-scope-unix` on Linux
and denying WindowServer on macOS both break the app, which is what says the
method can see a break at all. An earlier macOS control denied `trustd` and
survived — the test app loads a local page and never opens a TLS connection, so
it measured nothing.

**Everything currently shipped survives on its own**, on both WebKitGTK and
QtWebEngine: all the Landlock rights, both scopes, the whole seccomp filter and
each of its eleven syscall groups separately, `no_new_privs`, and the two opt-in
tiers. Nothing in the default set is carrying hidden cost.

What the probing did *not* find is much worth adding. That is the honest result:

- **`IOCTL_DEV` is compatible and pointless.** It survives, including a variant
  granting it only to the GPU and sound devices and withholding the terminal.
  But Landlock exempts a list of safe ioctls anyway, and the one worth
  withholding — `TIOCSTI` — is refused by the kernel itself: `dev.tty.legacy_tiocsti`
  defaults to `0` and the call returns `EIO` unconfined.
- **`mount` and `unshare` in seccomp survive, unmeasurably.** The Qt lane runs
  with `QTWEBENGINE_DISABLE_SANDBOX=1`, so Chromium's own sandbox — which is
  built on exactly those calls — was not running. Landlock already denies mount
  whenever it handles a filesystem right, so the first adds nothing regardless.
- **`RLIMIT_NPROC` survives CI and would break a desktop.** The limit is
  per-UID, not per-process; a fixed ceiling fails on a machine that is already
  above it.
- **`PR_SET_DUMPABLE` survives and is aimed the wrong way.** It stops others
  inspecting the app, and here the app is the adversary. `RLIMIT_CORE` already
  covers the dump.
- **On macOS every denial tried survives except writing sysctls**, which breaks
  startup and is therefore out. The rest — pasteboard, IOKit, opendirectory,
  exec under `$HOME` — are *startup*-compatible and nothing more, and the
  clipboard is a thing users press keys for, so none of those is shipped on
  this evidence.

  **LaunchServices was in that list and has been taken out of it.** The reason
  given for passing it over — that `NSWorkspace.openURL` needs it — is false,
  and what it was hiding is an escape rather than a nicety. See
  [the door that is not a file](#launchservices-and-the-door-that-is-not-a-file).
- **Namespaces work where the distribution allows them, and the verdict here was
  the conclusion rather than the symptom.** An earlier version of this file
  recorded `unshare` succeeding and the `uid_map` write then returning `EPERM`,
  and concluded that namespaces could not be tested. The symptom is exactly
  right and still reproduces: on Ubuntu 24.04 AppArmor hands an unprofiled
  binary the namespace and refuses to let it map anything, which is worse than a
  flat refusal — a process that gets that far is left as the overflow uid, with
  its view of the filesystem unchanged and every file it owns suddenly
  unreadable. It is why the tier asks the question in a throwaway child before
  entering anything, and why `--info` now names the step: `uid map refused:
  Operation not permitted` is what GitHub's runners say.

  What changed is the conclusion. On a distribution without that restriction the
  same code enters the namespace, writes the map and does the work — measured on
  Mint 22.3 with kernel 7.0, and in CI with the sysctl lifted for the length of
  the suite. That reopened the section below, and
  a session tier is what came of it, and it is gone with the other tiers.

  One trap worth leaving behind for whoever measures this next: **the same errno
  has a second cause, and that one is ours.** A probe that reads its own uid
  *after* entering the namespace is asking for 65534 to be mapped, which is
  refused identically by a kernel that would have accepted the real one. Read the
  ids first, and make the probe say which step failed — "unshare refused" and
  "namespace granted, uid map refused" are not the same machine.

### What is still open

Worth being concrete about the ceiling, because further tightening has sharply diminishing returns
while these stand:

- **A build run's slot is writable by every low integrity process on the machine, not only by the
  app.** A mandatory label cannot name one process, so this is the same exposure the fetch phase's
  single-file grant has. It is worse here in two ways, both of them the entry above: the grant is a
  directory, and the app is alive for the tail of the window because `cmd.exe` `START`s it and
  returns. What a plant landing inside that window buys is the program the *next* launch runs — the
  record is taken after the label comes off, so it seals what is there at that moment and cannot
  tell a compiler's output from a plant. The window does not exist on a launch that does not build,
  which is every launch after the first of a pin. Closing it needs the payload to be told "build,
  do not launch", and that is a protocol netinstall cannot have: it runs arbitrary `.cmd` files, and
  one that did not implement it would simply launch twice.
- **Session D-Bus and X11 are reachable in the default tier**, and either is a full escape.
  Connecting to a pathname unix socket is not mediated by any filesystem rule — measured on ABI 8,
  with a ruleset granting nothing but `/usr`, the session bus, the ssh-agent socket and
  `/tmp/.X11-unix/X0` all still connect. Landlock cannot express this and no amount of tightening it
  will. A session tier once closed both with namespaces and the X11 SECURITY extension; it was
  Linux-only and unavailable outright on Ubuntu 24.04 and its derivatives, so it could never be part
  of a promise made everywhere. This is the ceiling.
- **The default tier's `/proc` write grant reaches every same-uid process.** Landlock is granted
  `WRITE_FILE` on all of `/proc`, and that is not only the app's own entry. Measured: thirteen
  files under a peer's `/proc/<pid>` open for writing — `oom_score_adj`, `sched`, `clear_refs`,
  `coredump_filter`, `timerslack_ns` and the id maps among them — and a real write to a peer's
  `oom_score_adj` succeeds. Marking a same-uid process for the OOM killer is not code execution
  and reads nothing, but it reaches across at a process this same ruleset scopes *signals* away
  from, so the guarantee two lines up is narrower than it sounds. `/proc/<pid>/mem` is **not** in
  that set: Landlock implements the LSM ptrace hook as well as the filesystem one, and a domain
  may not reach a task outside itself whatever the rights say — measured against an in-domain
  child, which does answer, under an identical rule.

  The grant is `/proc/self` now, on every build, and `confine.sh` asserts `PEEROOM_BLOCKED` where it
  used to assert the escape.
- **The default tier on macOS leaves the LaunchServices door open**, and it is an escape rather than
  a nuisance: an `.app` bundle written into the app dir and handed to LaunchServices is spawned
  outside every profile in the stack. It is closed on every build now, and `confine.sh` asserts the
  refusal where it used to assert the escape. An **already-installed** app can still be launched —
  what is closed is launching a bundle the app itself wrote. See
  [the door that is not a file](#launchservices-and-the-door-that-is-not-a-file).
- **No platform confines reads**, and windows is why. See
  [why Windows gets less](#why-windows-gets-less-and-why-nobody-else-gets-more).
- **OpenBSD leaves existing files under `/tmp` writable.** `/tmp` is unveiled `rw`, which is not
  `c`: the app cannot create a file there, and cannot write one through a shell redirection either
  — `>` is `O_CREAT`, which `unveil` refuses whether or not the file exists — but a deliberate
  `open(2)` without `O_CREAT` on a file that is already there succeeds. Measured from inside the
  confinement, all three operations separately, on a lane running as root so that nothing was
  refused by ordinary permissions instead. It stays because an X11 client reaches the display
  through `/tmp/.X11-unix`, and there is no display on any OpenBSD runner to measure a narrower
  rule against; narrowing it blind would be the kind of change this file exists to avoid. So it is
  in the sentence: `--info` says `writes confined to <app dir> and /dev, plus files that already
  exist under /tmp`.
- **OpenBSD's fetch phase cannot read a user's curl config.** `unveil` is an allowlist for reads,
  and the fetch list grants the blobs directory, `/usr`, `/bin`, the TLS trust store,
  `resolv.conf`, `/dev/urandom` and `ld.so`'s hints file — nothing else. On Linux and macOS the
  default tier restricts writes and leaves reads alone, so `~/.curlrc` is read there and is part
  of the trust model [above](#trust-model). On OpenBSD it is not read at all. Narrower, and
  different; said here rather than discovered by someone whose proxy settings stopped applying.
- **FreeBSD and NetBSD get no confinement**, and that is unlikely to change while Capsicum needs the
  target's cooperation, and jail, chroot and ugidfw all need root. They do get the environment
  allowlist and no core dumps, and FreeBSD gets `PROC_NO_NEW_PRIVS_CTL` on top; none of that is a
  boundary. A strict build refuses to run on either — measured on both, where it stops at the fetch
  phase rather than the run phase, because the fetch is the first thing it will not do unconfined.

### Write xor execute on macOS

This held for the app dir and nowhere else, which meant it did not hold. The profile has to grant
writes to a handful of paths outside the app dir or nothing starts — the Library subtrees
CFPreferences and WebKit insist on, and the Darwin per-user temp directory, which is not redirected
here for reasons given above. Every one of those was writable *and* executable, so dropping a
binary and running it was a two-line script.

`process-exec*` is now denied on all of them. Which is the point of naming it precisely: it is
**not** a blanket deny on `$HOME`. An app running `node` from `~/.nvm` or a tool from a user prefix
is not the attack, and nothing under there is writable by a confined app in the first place.

### What macOS denies that is not a file

The seatbelt profile named `~/Library/Keychains` in its read denials, which was theatre: a keychain
is not read by opening a file. The request goes to `securityd` over Mach, and the file denial never
saw it. Denying the service is what actually closes it, so `com.apple.SecurityServer` and
`com.apple.securityd.xpc` are now unreachable and the file rule is the belt to that pair of braces.

Certificate trust lives in a *different* daemon, `com.apple.trustd`, which is deliberately left
reachable — deny that one and TLS inside the webview stops working.

Both halves are measured rather than argued. The suite plants a real password in the login keychain
from outside the sandbox and tries to read it back from inside, because searching for an item that
does not exist fails identically whether `securityd` was reachable or not; under the profile the
read is refused. It also fetches an HTTPS URL, which returns 200. So the denial is a boundary and
not a second piece of theatre, and the carve-out for `trustd` is doing exactly the work it was left
in to do.

Also denied:

- **`com.apple.tccd`**, the gatekeeper for camera, microphone, screen recording and the Documents
  and Desktop folders. Unreachable, those fail closed instead of showing a consent prompt
  attributed to a launcher the user did not think was asking.
- **`appleevent-send`**, which is the large one. `osascript` driving Finder or Terminal is a
  complete escape from everything above. The polyglot's own JXA path uses the ObjC bridge rather
  than sending events, so it does not need this.
- **`mach-priv-task-port`**, the macOS spelling of `ptrace` — a task port is read and write access
  to another process's memory — and **`signal` to processes outside the sandbox**, which is what
  `LANDLOCK_SCOPE_SIGNAL` buys on the other side.

### LaunchServices, and the door that is not a file

Write xor execute stops an app running what it wrote. It does not stop the app asking someone else
to run it. An app writes an `.app` bundle into the directory the profile makes writable, hands it to
LaunchServices, and the spawn is done by a daemon that is in nobody's sandbox — so the bundle runs
outside this profile, and outside netinstall's too when netinstall is what launched it. A write from
inside a seatbelt sandbox sets no quarantine attribute, so Gatekeeper does not intervene either.
This is the same two-line escape the `process-exec*` denials were added to close, taking a different
door.

Denying `/usr/bin/open` would settle nothing. Anything that can reach AppKit calls
`NSWorkspace.openURL` instead, and under netinstall the app is arbitrary `sh` with `osascript` on
it. **Both doors were measured open** under the shipped profile, so the service is the boundary and
the binary is not.

**Two names are denied, and it has to be both:**

```
(deny mach-lookup
  (global-name "com.apple.coreservices.launchservicesd")
  (global-name "com.apple.coreservices.quarantine-resolver"))
```

That pair is not a guess and not belt-and-braces. Each candidate below was applied on its own to a
bundle written from inside the sandbox, on a macos-latest runner, with an unconfined control after
every attempt so a wedged daemon could not answer for a boundary:

| denied | `.app` via `open` | via `NSWorkspace` |
|---|---|---|
| nothing — the shipped default tier | **launches** | **launches** |
| `com.apple.coreservices.launchservicesd` — the obvious one | launches | launches |
| `com.apple.lsd.openurl` | launches | launches |
| all of `com.apple.lsd.*` | launches | launches |
| `com.apple.runningboard` | launches — and it is never even looked up | launches |
| `com.apple.coreservices.quarantine-resolver` | launches | launches |
| `com.apple.coreservices.sharedfilelistd.xpc` | launches — never looked up either | launches |
| **`launchservicesd` + `quarantine-resolver`** | **refused** | **refused** |
| all of `com.apple.coreservices.*` | refused | refused |

LaunchServices has a way round each name and no way round the two. Which way round is Apple's
business and is not documented; what is recorded here is the measurement. `confine.sh` asserts the
outcome in **both** tiers, so a macOS that makes either name sufficient — or neither — is a failure
and not a silence.

**What it costs: nothing that could be measured.** A real webview renders under the profile carrying
it, and `shell.openExternal` keeps working — an http url still reaches the browser, because a url is
not a file and has no quarantine to resolve. The user-visible trade this denial was expected to make
does not exist, and the older note that `NSWorkspace.openURL` needs LaunchServices was measuring the
wrong call.

**What it does not close**, said here rather than letting the denial look total: an app that is
**already installed and registered still launches**. What is closed is getting LaunchServices to
spawn a bundle the app itself wrote, which is the escape. Launching Calculator hands an attacker
nothing; launching a bundle they authored hands them everything.

Both halves are asserted, in the polyglot's tier as well as netinstall's: `verify-macos-tight.sh`
plants a bundle in the app dir, proves it launches unconfined, and then fails if either door reaches
LaunchServices under the profile `webview.cmd` generated for itself.

### The seccomp filter

Landlock mediates paths and nothing else, so everything that reaches across a process boundary or
into the kernel's own machinery stayed open. A denylist filter closes the worst of it: `ptrace`,
`process_vm_readv`/`writev`, `userfaultfd`, `perf_event_open`, `bpf`, `kcmp`, the keyring calls,
`io_uring`, `setns`, the file-handle calls, and the module and kexec family.

A **denylist**, and deliberately. An allowlist a webview survives is a large piece of archaeology
that rebreaks whenever an engine changes libc — and Chromium and WebKit already ship exactly that
filter for their own renderers. Filters stack, so theirs still installs on top of this one; that is
verified rather than assumed.

Everything returns `EPERM` rather than raising `SIGSYS`. A kill action turns an
unexpected-but-harmless syscall into a crash, and a crash inside a webview is indistinguishable
from a bug in netinstall.

Three details worth knowing if you edit the list:

- **Foreign architectures are refused outright.** A process can reach the same kernel code through a
  different syscall table, so the filter checks the audit arch first, and on x86-64 also rejects x32
  — which shares the audit arch and differs only by a bit in the syscall number. The practical cost
  is that a 32-bit process cannot run under the filter.
- **The mount family is pointedly absent.** Landlock already denies it whenever it handles a
  filesystem right, and on a kernel too old for Landlock, denying it here would newly break
  WebKitGTK's `bubblewrap` for nothing.
- **It applies even when Landlock does not**, since it is worth having on an old kernel too. It is
  still not filesystem confinement, so a kernel that offers seccomp and no Landlock is one the
  binary refuses to run on rather than settling for half.

### Scoping, and where confinement is still theatre

Scoping is the only part of Landlock that is not about paths, and it needs ABI 6. It comes in two
halves that turned out to be nothing alike.

`LANDLOCK_SCOPE_SIGNAL` stops the app signalling anything outside its own domain. It is free and
always applied.

`LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET` closes a namespace that has no paths and therefore could never
have had a rule written about it. It is applied **only when `DISPLAY` is unset**, and the reason is
worth stating exactly, because the obvious assumption — the one an earlier version of this file
made — is wrong.

An X11 client asks for the abstract socket `@/tmp/.X11-unix/X0` first and is documented to fall back
to the pathname socket. It does not fall back here: libxcb only retries on `ENOENT` and
`ECONNREFUSED`, and scoping answers `EPERM`, which is not on that list. Under `strace` in a scoped
domain there is exactly one `connect()`, to the abstract address, refused — and `/tmp/.X11-unix/X0`
is never tried, even though it is reachable and would have worked. So on an X11 session this does
not tighten the sandbox, **it removes the display**, which is the whole point of the program.

Where there is no X11 display it costs nothing and closes a real class, so that is where it is used.
`--info` reports `signals scoped` or `sockets+signals scoped` so you can see which you got, and the
suite asserts both: it runs the hostile payload once with the display CI provides and once with
`DISPLAY` unset.

Be clear-eyed about what all of this leaves. **Connecting to a pathname unix socket is not mediated
by any filesystem rule.** Measured rather than inferred: on ABI 8, with a ruleset that grants nothing
but `/usr`, connects to `/run/user/1000/bus`, the ssh-agent socket and `/tmp/.X11-unix/X0` all still
succeed. So:

- **Session D-Bus** lets an app call `StartTransientUnit` and launch a process outside the
  sandbox entirely. If it can reach the session bus, it is not confined. On a systemd session the
  bus is a pathname socket, so scoping does not touch it either way.
- **X11** lets any client keylog and screenshot every other client, and on an X11 session the
  filesystem restriction is the only thing that holds.

Both were what a session tier existed for, and it is gone: it was Linux-only and unavailable on
Ubuntu 24.04 and its derivatives, so it could never be a line in a promise made everywhere. Two
things it turned up are kept here, next to the mechanism they are about, because they are facts
about X11 and namespaces rather than about a tier:

- **A network namespace closes the abstract namespace on an X11 session, and Landlock scoping
  cannot.** The two refusals are not the same refusal. Scoping answers `EPERM`, which libxcb does
  not retry, so the client never tries the pathname socket and the display is gone. A network
  namespace answers `ECONNREFUSED`, which libxcb *does* retry, so it falls back to
  `/tmp/.X11-unix/X0` and the window comes up.
- **Hiding `/tmp/.X11-unix` does not remove the display.** The abstract name belongs to the network
  namespace, not the mount namespace, so a client covered out of the directory simply connects to
  `@/tmp/.X11-unix/X0` instead. It takes both to leave an app with no display at all.

### Why Windows gets less, and why nobody else gets more

Windows cannot confine a read. Low integrity is a no-write-up rule and leaves reads alone, and
AppContainer -- the only mechanism that would close them -- does not work: launched inside a real
one, with its capabilities granted and the app dir handed to its SID, no window appears at all.
Every unprivileged mechanism the platform offers has now been tried against a real webview.

That is why no platform confines reads. macOS had a working `$HOME` denial and Linux had a working
read allowlist, and both are gone, because a capability three platforms have and the fourth cannot
is the shape that gets reported as a bug against the fourth. The promise is the intersection or it
is a support matrix, and this file used to be one.

What survives on macOS is not a read rule and is the reason this costs less than it looks: a
keychain is not read by opening a file -- the request goes to securityd over Mach -- so denying the
service was always the half that worked, and it is still denied, along with tccd, the task port,
Apple Events and both LaunchServices names.

What it costs on Linux is write-xor-execute. Landlock takes the union of every rule matching along
a path, so execute has to be an allowlist, and the allowlist was the read one. `env.sh` asserts the
consequence rather than leaving it to be discovered: a file in the app's own directory execs, and a
library anywhere under `$HOME` maps and runs. That makes the environment deny list the only thing
between a loader variable and code of the caller's choosing in the process that renders your page.

Two more capabilities are absent for a different reason: they were decided by the kernel version
underneath rather than by this program. Landlock's scoping needs ABI 6, which is 6.12, and its
TCP-bind rule needs ABI 4, which is 6.7 -- while Debian 12 ships 6.1 and Ubuntu 24.04 ships 6.8,
both in support. An app that could bind a port on one supported machine and not another, with
nothing in the artifact to say which, is the thing this document exists to stop having.
## Building

```bash
./build.sh          # every os/arch, needs zig
./build.sh host     # just this machine, needs cc
```

**No build-time flags change the confinement.** There used to be four —
`-DNEUTRINO_STRICT_SANDBOX`, `-DNEUTRINO_CONFINE_TIGHT`, `-DNEUTRINO_CONFINE_OFFLINE` and
`-DNEUTRINO_CONFINE_NOSESSION`, sixteen combinations — and every one is gone. What they enabled is
either always on or deleted; there is nothing to pass through `NETINSTALL_CFLAGS` and nothing to get
wrong.

Targets: `linux-{x86_64,aarch64}` (musl, static), `macos-{x86_64,arm64}`,
`windows-{x86_64,aarch64}`. OpenBSD builds natively with `./build.sh host` and runs the suite in CI.
FreeBSD and NetBSD used to as well; neither can be confined without root, so neither is a target any
more — see [why Windows gets less](#why-windows-gets-less-and-why-nobody-else-gets-more).

## Testing

```bash
test/run.sh
```

Builds three binaries — a release one, a `-DNEUTRINO_TESTING` one, and one that prefers the `wget`
fallback, because every machine that can be rented resolves `curl` so that branch is otherwise never
taken. It used to build nine.

Then it runs the suites: `names.sh` (the grammar, accepted and rejected), `fetchbound.sh` (what
bounds a hostile response's size and duration, on both downloader branches), `verify.sh` (pin
mismatch, non-text payloads, oversized responses, offline cache, tampered cache), `confine.sh` (a
hostile script that tries to escape — the filesystem, the environment, an inherited descriptor, an
abstract socket, another process's memory, and on macOS a bundle it wrote handed to LaunchServices
two different ways), `phases.sh` (what confines the downloader on each platform, measured through
curl's own config file rather than asserted from the source, and that a build refuses to fetch when
nothing does), `writable.sh` (what a confined app can actually put bytes into, enumerated from
inside the confinement), `env.sh` (the loader environment, and what the sandbox does *not* do about
it), `splash.sh` (the splash window: raised once for a download that was stalled long enough to
deserve one, not at all for one that was not, held for as long as it must be, torn down on every
path out, and photographed for the lane's sheet — once for the portrait, then six frames in a row to
show the indicator moving), and `e2e.sh` (a real neutrino polyglot
fetched, verified and launched).

**What a launch is asked here, and what it is not.** `e2e.sh` starts a real webview and wants one
thing from it: that the confinement just applied still lets a webview come up and run the page's
script. That is `nt_app_probe` in `test/lib.sh`, and its answer is one of `NO_WINDOW`,
`WINDOW_NO_CONTENT` or `CONTENT_OK`.

It used to answer that by running `test/verify-linux.sh` and its macOS and Windows siblings —
neutrino's own verifiers, which assert the window title at each of six states, the size to the pixel,
the frame's corner and the desktop's palette, and keep a screenshot of every one. Every lane that
runs this suite already runs that verifier against a standalone launch in a step of its own, minutes
earlier, so the second run measured nothing the first had not. It cost about twenty-four seconds per
launch and, worse than the time, a regression in neutrino's geometry or palette turned three sandbox
suites red on four lanes, each reporting a webview defect under a sandbox's name.

The app is `test/alive.js`, which this suite owns. It sets one title and holds the window, so there
is no eleven-second head start to wait out and no step list to fall out of step with. The pictures
the suites here take are not of the webview: `splash.sh` photographs the splash window, over a
download `hostile.py` stalled on purpose so the window was due and with `NEUTRINO_SPLASH_HOLD_MS`
keeping it up while the shutters fired. They go to the lane's sheet under its own heading, on the
four lanes that draw one — X11 under Xvfb, wayland under a headless sway, Windows, and macOS — when
`NEUTRINO_SPLASH_SHOTS` names a directory, and nowhere otherwise.

Two shutters, because the window moves and one photograph cannot show that. The portrait is what a
reader compares across the four lanes; the burst is six frames about a tenth of a second apart,
which `sheet.sh` plays back as one figure that cycles. The burst is also the suite's only assertion
about what is inside the window: six photographs of a moving indicator are not six copies of one
photograph, and at least three of them have to differ. That is a floor rather than a proof — a
desktop doing something else behind the window would also make frames differ — which is why the
count is reported beside the verdict, and why the lanes it runs on have nothing else on screen.

Those four lanes also name the mechanism they expect in `NEUTRINO_SPLASH_EXPECT`, and the suite
fails when the measured one differs. That is not belt and braces: the splash declines silently
wherever it cannot draw, which is correct on a headless machine and indistinguishable from a lane
whose display server failed to start. Without the expectation such a lane skips every window case
and goes green having measured nothing. Unset — a developer's machine, and the BSD guests — the
mechanism stays a reading.

The wayland half had never run anywhere until it got a lane of its own. Every other lane is X11,
AppKit or `user32`, so the longest of the five platform files was compiled six times a push and
executed never, and both of the suite's wayland cases ended in "no compositor on this machine". The
lane brings up a headless `sway` (see `test/wayland-up.sh` for why sway and not weston: `grim` can
photograph it) and an X server beside it, which is also the only place the two cases about the
*choice* between the protocols can be more than a skip — a stale `WAYLAND_DISPLAY` falling back to
X11, and a reachable compositor being preferred when `DISPLAY` is set too.

Two probes do not run by default. `crashdump.sh` (Windows) measures where a crash puts bytes, and
`landlockfloor.sh` (Linux, needs Docker) reads what kernel each supported distribution ships; both
print `report:` lines and assert nothing. `job-ui.sh` is the Windows job UI bisect described above,
behind `NEUTRINO_JOB_UI_BISECT=1`, and takes about ten minutes because every flag costs a real
webview launch.

The `NEUTRINO_TEST_ORIGIN` override the suite needs to serve fixtures from loopback is compiled
in only under `-DNEUTRINO_TESTING`; release binaries ignore it entirely. So are the two splash
knobs: `NEUTRINO_SPLASH_TRACE`, which narrates the window's lifecycle on stderr for `splash.sh`,
and `NEUTRINO_SPLASH_HOLD_MS`, which lengthens the hold and cannot shorten it.
