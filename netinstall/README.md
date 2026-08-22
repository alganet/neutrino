<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# netinstall

A name-addressed launcher. It is a small compiled binary that derives everything it does from
its own filename — rename it, and it fetches and runs something else.

```
neutrino-io-github-alganet-0a1b2c3d4e5f60718
└─name─┘└─host reversed──┘└──────pin───────┘

  fetch  https://alganet.github.io/neutrino.cmd
  verify sha256 starts with "a1b2c3d4e5f60718"
  run    sh ~/.cache/neutrino/apps/neutrino-io-github-alganet-0a1b2c3d4e5f60718/neutrino.cmd
```

No config file, no registry, no subcommand, no state that isn't derivable from the name.

This is a separate subproject. `neutrino` itself is unchanged and still works as a plain script;
you never need netinstall to run one.

---

## Names

```
<name> "-" <label_n> "-" ... "-" <label_1> "-" <token>  [".exe" on Windows]
```

- The **first** segment is the app name and the URL path stem.
- The **last** segment is always the token. Position decides, so nothing is ambiguous.
- The **middle** segments are the host's DNS labels, reversed. At least three segments total.
- **`_` means `-`** in the resolved value, so `my_app-com-example-0a1b2c3d4e5f60718` resolves to
  `https://example.com/my-app.cmd`. DNS labels cannot contain `_`, so only app names give
  anything up.
- The **token** is one version character plus the pin. `0` means "SHA-256, lowercase hex,
  truncated to the length given". **Minimum sixteen pin characters**; longer is stronger and free.
- Only `[a-z0-9_-]` is accepted. Rejecting everything else also rules out path traversal.

Copy or hardlink the binary to rename it. **Symlinks do not work**: the real executable path is
used, never `argv[0]`, because deriving a fetch URL from a caller-controlled string would make
this a confused deputy.

**Except on OpenBSD**, which has neither `/proc` nor `KERN_PROC_PATHNAME`, so there is no way to ask
the kernel what is running. There netinstall resolves `argv[0]` instead, and the guarantee that the
name cannot be spoofed by the caller does not hold.

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
exact downloader command that would run, the confinement that would be applied, and how much of the
environment would be dropped. It describes
without enforcing, so it changes nothing and reports what a real launch would do.

## Layout

```
$NEUTRINO_HOME/                    # XDG_CACHE_HOME/neutrino
                                   # ~/Library/Caches/neutrino
                                   # %LOCALAPPDATA%\neutrino
├── blobs/<full-sha256>            # content-addressed, read-only, every version
└── apps/<name>-<host reversed>/   # keyed WITHOUT the pin
    ├── <name>.cmd                 # read-only, hardlink to the current pin
    └── <name>/                    # the only writable directory
```

**The app directory is keyed on the app, not the pin.** A new pin of the same name and host replaces
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
- **Uninstall is `rm -rf apps/<name>-<host reversed>/`**, which takes the app and its state together.

The script sits one level *above* the only writable directory, so an app cannot rewrite the
launcher it was verified from. neutrino puts its own generated files in `<name>/` because it
derives that path from the script's own location, so this costs nothing.

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
the fetch. Its own configuration is *not* scrubbed: that config is the trust anchor you chose,
and removing your control over it would defeat the point. `--info` prints the effective command.

The `wget` fallback is weaker and only used when no `curl` exists. `--https-only` governs recursive
link following rather than redirects for a single file, and wget has no equivalent of
`--max-filesize`, so the fallback **refuses redirects entirely** and its response size is bounded
only after transfer rather than during it. Install `curl` if that matters to you.

**The pin is a content pin.** It catches corruption, mirror drift, and a host silently changing
the file after you pinned it. Sixteen hex characters is 64 bits, which puts a second preimage —
a host grinding a *different* file that matches a pin you already chose — out of reach at 2^64.

What 64 bits does not buy you is collision resistance against a **malicious publisher**, who can
craft two files sharing a truncated digest for about 2^32 work: one benign to get reviewed and
pinned, one hostile to serve later. If you are pinning something you did not build and the
publisher is part of your threat model, use a longer pin — 32 characters restores 2^64 against
that attack too. `--info` prints the full digest, so lengthening one is a copy-paste.

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

Best-effort, and genuinely uneven. A webview needs the GPU, DBus, the compositor socket, fonts
and the network, so "deny everything" is not on the table.

| Platform | What is applied |
|---|---|
| **Linux** | Landlock. Writes confined to the app dir (plus `/proc`, `/dev`, `/dev/shm`); reads unrestricted; binding a TCP port denied; signals scoped to the sandbox, and abstract unix sockets too where there is no X11 display. A seccomp filter on top. The session bus stays reachable unless the session tier is built in. The `/proc` write grant is every process's entry, not just the app's — see [what is still open](#what-is-still-open). |
| **OpenBSD** | `unveil` + `pledge` execpromises, inherited by the child. See the caveat below. |
| **macOS** | Seatbelt profile: `deny file-write*` outside the app dir, read denials on `~/.ssh`, Keychains, Mail, Safari and browser profiles, and denials on securityd, tccd, Apple Events and task ports. |
| **Windows** | Job object — process limits only — plus every token privilege but `SeChangeNotify` removed. **No filesystem confinement** by default; see the tight tier. |
| **FreeBSD** | No confinement. `PROC_NO_NEW_PRIVS_CTL` only, which is a floor rather than a boundary. |

If nothing is available the binary **runs anyway and warns on stderr**, naming what was and
wasn't applied; confinement here is defence in depth, not the trust anchor. Building with
`-DNEUTRINO_STRICT_SANDBOX` produces a binary that refuses to run unconfined instead.

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
  [the session tier](#the-session-tier-experimental) is what came of it.

  One trap worth leaving behind for whoever measures this next: **the same errno
  has a second cause, and that one is ours.** A probe that reads its own uid
  *after* entering the namespace is asking for 65534 to be mapped, which is
  refused identically by a kernel that would have accepted the real one. Read the
  ids first, and make the probe say which step failed — "unshare refused" and
  "namespace granted, uid map refused" are not the same machine.

### What is still open

Worth being concrete about the ceiling, because further tightening has sharply diminishing returns
while these stand:

- **Session D-Bus and X11 are reachable in the default tier**, and either is a full escape.
  Connecting to a pathname unix socket is not mediated by any filesystem rule — measured on ABI 8,
  with a ruleset granting nothing but `/usr`, the session bus, the ssh-agent socket and
  `/tmp/.X11-unix/X0` all still connect. Landlock cannot express this and no amount of tightening it
  will. [The session tier](#the-session-tier-experimental) closes both with namespaces and the X11
  SECURITY extension, and it is off by default and unavailable outright on Ubuntu 24.04 and its
  derivatives, so on a stock desktop this is still the ceiling.
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

  [The tight tier](#the-tight-tier-experimental) narrows the grant to the app's own entry and
  [the session tier](#the-session-tier-experimental) leaves no peer in `/proc` to write to at all.
  The default tier keeps it, and this is why.
- **The default tier on macOS leaves the LaunchServices door open**, and it is an escape rather than
  a nuisance: an `.app` bundle written into the app dir and handed to LaunchServices is spawned
  outside every profile in the stack. [The tight tier](#the-tight-tier-experimental) closes it; the
  default tier does not, and `confine.sh` asserts that it does not, so the ceiling is on the record
  in both directions. Even in the tight tier an **already-installed** app can still be launched —
  what is closed is launching a bundle the app itself wrote. See
  [the door that is not a file](#launchservices-and-the-door-that-is-not-a-file).
- **Windows cannot confine reads.** AppContainer is the only mechanism that would, and low integrity
  already stops WebView2 rendering, so there is no reason to expect AppContainer to fare better.
- **FreeBSD gets no confinement**, and that is unlikely to change while Capsicum needs the target's
  cooperation, and jail, chroot and ugidfw all need root. It does get the environment allowlist, no
  core dumps and `PROC_NO_NEW_PRIVS_CTL`, none of which is a boundary; a strict build still refuses
  to run there.

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

**The tight tier denies two names, and it has to be both:**

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
  still not filesystem confinement, so a `-DNEUTRINO_STRICT_SANDBOX` build refuses to run on
  seccomp alone rather than settling for it.

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

Both of those are what [the session tier](#the-session-tier-experimental) exists for. Two things it
turned up are worth having here, next to the mechanism they are about:

- **A network namespace closes the abstract namespace on an X11 session, and scoping cannot.** The
  two refusals are not the same refusal. Scoping answers `EPERM`, which libxcb does not retry, so
  the client never tries the pathname socket and the display is gone. A network namespace answers
  `ECONNREFUSED`, which libxcb *does* retry, so it falls back to `/tmp/.X11-unix/X0` and the window
  comes up. Measured on both engines with a display set: the offline tier closes every abstract
  socket and the webview lives.
- **Hiding `/tmp/.X11-unix` does not remove the display.** The abstract name belongs to the network
  namespace, not the mount namespace, so a client covered out of the directory simply connects to
  `@/tmp/.X11-unix/X0` instead. It takes both to leave an app with no display at all, which is now
  the probe's must-die control.

### What Landlock costs, in both tiers

This applies to the **default** tier as much as the tight one, and an earlier version of this file
wrongly implied otherwise.

Landlock unconditionally denies `mount`, `umount`, `pivot_root` and `move_mount` to any domain that
handles even one filesystem right — by design, even inside a fresh namespace. `PR_SET_NO_NEW_PRIVS`,
which Landlock requires, also neuters Chromium's SUID sandbox helper. So the moment netinstall
confines anything on Linux, WebKitGTK's `bubblewrap` cannot initialise and Chromium's namespace
sandbox may not either. Both tiers pay that; what the tight tier adds on top is only the read and
execute allowlist.

That is a real trade, not a free one: **you may be giving up the renderer's own protection against
hostile web content in exchange for protection against the app's author.** Which of those you care
more about depends on what you are running. CI does not settle it either — the Qt lane sets
`QTWEBENGINE_DISABLE_SANDBOX=1`, and WebKitGTK's sandbox is opt-in and never enabled by neutrino, so
neither engine's sandbox was active there to be starved.

If that trade is wrong for your case, run without netinstall: neutrino is a plain script and does
not need it.

The tight tier takes one more piece of that same mechanism, and this half **is** measured. Both
`bubblewrap` and Chromium's `namespace_sandbox.cc` set a child's user namespace up the same way:
fork, let the child `unshare(CLONE_NEWUSER)`, then have the **parent** write that child's
`/proc/<pid>/setgroups` and `uid_map`. That is a descendant's entry, so the default tier's grant
covers it and a rule pinned to `/proc/self` does not. `confine.sh` asserts it both ways —
`USERNSMAP_OK` in the default tier, `USERNSMAP_BLOCKED` in the tight one — so if the engines ever
do get their sandboxes started under netinstall, the suite says which tier took it away.

Two things this does *not* cost, both measured rather than argued. A confined app can still read
under its own `/proc` entry in the tight tier, because Landlock takes the union along a path and
the read rule sits above the narrowed write rule — `PROCSELFREAD_OK`. And neither engine notices
the narrowing today: `verify-linux.sh` renders identically under both grants on WebKitGTK and
QtWebEngine, with identical `oom_score_adj` on every engine process. Chromium already logs
`Failed to adjust OOM score of renderer` under the **default** grant, for a reason that is not
ours — the kernel refuses to lower `oom_score_adj` without `CAP_SYS_RESOURCE`.

### The tight tier (experimental)

Building with `-DNEUTRINO_CONFINE_TIGHT` turns on a second, stronger tier. It means something
different on each platform, because the mechanisms differ in what they can express:

| Platform | What the tight tier adds |
|---|---|
| **Linux** | Landlock handles read rights too, so `$HOME` becomes deny-by-default, and execute becomes an allowlist that omits every writable directory. `~/.Xauthority` stays readable unless the session tier replaced the cookie with an untrusted one, in which case allowlisting it would hand back exactly what that took away. The `/proc` write grant narrows from every process's entry to `/proc/self` — see [what Landlock costs](#what-landlock-costs-in-both-tiers) for what that buys and what it takes. |
| **macOS** | Seatbelt denies reads of all of `$HOME` rather than a named list of secrets, and closes the LaunchServices escape — see [the door that is not a file](#launchservices-and-the-door-that-is-not-a-file). |
| **Windows** | The process drops to low integrity, so writes outside the app dir fail. |
| **OpenBSD** | Nothing — `unveil` is already an allowlist, so the default tier is the tight one. |

On Linux and macOS the tier is also **write xor execute**: a directory an app can write to is one it
cannot run anything from, so dropping a binary and executing it is not a path. macOS gets this in
both tiers; Linux needs an execute allowlist to express it, so it arrives with the tight tier.

Worth knowing before editing the ruleset: **Landlock takes the union of every rule matching along a
path, not the closest one.** There is no way to grant a right broadly and subtract it for one
directory — anything you want withheld somewhere has to be allowlisted everywhere else instead.

On Linux and macOS the allowlist is the system tree plus the handful of `$HOME` subpaths a GTK,
Qt or Cocoa app reads on the way up: fonts, icons, themes, and the toolkit's own settings.
Everything else in `$HOME` is denied, which is what finally puts `~/.ssh`, `~/.gnupg`, `~/.aws`
and browser profiles out of reach. `--info` reports `reads and writes confined to ...`.

**Windows confines writes, not reads.** Low integrity is a no-write-up rule; a low-IL process can
still read `~/.ssh` and browser cookie stores. Only an AppContainer would close that, and it is
documented to break WebView2. The suite asserts this limitation explicitly rather than letting
the tier look stronger than it is.

**The Windows tier does not work for GUI apps.** Measured in CI, not assumed: `jsc.exe` does still
compile at low integrity once `%TEMP%` is redirected, but WebView2 never renders a window, which
is what Microsoft documents for low-IL hosts. So on Windows this tier is only useful for payloads
that do not open a webview — which netinstall does run, since it is a general script runner. The
suite records the outcome rather than failing on it, so it will tell you if that ever changes.

Two consequences of the layout are worth knowing if you change it. The script sits one level
above the writable directory so an app cannot rewrite its own launcher — and once reads are
confined, that same split hides the script from `sh`, so the parent is granted read and execute
and nothing more. On Windows the app dir must carry a Low mandatory label or the app cannot write
its own files, and `%TEMP%` has to be redirected because it does not relocate on its own at low
integrity, which would otherwise break `jsc.exe`.

It is off by default because the benefit was not proven when it was written. `test/confine-strict.sh`
is what settles it: it asserts the tier actually holds, then launches a real webview under it and
fails if it cannot start.

### The offline tier (experimental)

Building with `-DNEUTRINO_CONFINE_OFFLINE` denies the app outbound network access. It is a separate
axis from the tight tier and the two compose. A lot of what people build with neutrino is a local
UI over local data, and for those the network is pure attack surface — an app that can read your
files and reach the internet is a very different proposition from one that can only do the first.

| Platform | What it does |
|---|---|
| **Linux** | Landlock handles `CONNECT_TCP` and grants it to nothing (needs ABI 4), plus a network namespace where the distribution allows one. |
| **macOS** | `(deny network-outbound (remote ip))` and the inbound equivalent. |
| **OpenBSD** | The same `pledge` list without `inet` and `dns`. |
| **Windows** | **Nothing.** WFP needs administrator and a job object cannot express it. |

**The fetch is never offline** — the download is the one thing that has to reach the network, so the
tier applies to the run phase only.

Be precise about what "offline" means here, because it is narrower than the word suggests:

- **Linux covers TCP with Landlock, and everything with a network namespace.** Landlock's network
  rules are TCP-only, so on their own UDP — QUIC, DNS, anything else — is untouched, which is a real
  hole and not a rounding error. Where an unprivileged user namespace can be had, the tier takes a
  network namespace as well and there is no protocol left to leak through; `--info` says `offline`
  when it got one and `offline (tcp only)` when it did not, and `test/offline.sh` asserts the UDP
  half rather than assuming it. The namespace also brings loopback up, or local IPC would go down
  with the internet, and closes the abstract socket namespace as a side effect — see above for why
  that does not cost the display.
- **macOS denies IP, not sockets.** Unix domain sockets and Mach stay open, deliberately:
  WindowServer, the pasteboard and WebKit's helpers all talk over those, and denying them takes the
  window down along with the network.
- **Windows gets nothing at all**, and `--info` says so rather than letting the build look like it
  did something.

`test/offline.sh` points the app at the suite's own fixture server, which is definitely listening,
so a refusal is the tier rather than a dead port — and the same binary fetched through that server
moments earlier, which is the other half of what it asserts.

### The session tier (experimental)

Building with `-DNEUTRINO_CONFINE_NOSESSION` closes the two holes the section above calls out: the
session bus and what X11 hands every client. It is a third axis, and it composes with the other two.

| Platform | What it does |
|----------|--------------|
| **Linux** | A user, mount and pid namespace. A fresh tmpfs over the runtime directory keeping only the compositor and audio sockets; the system bus covered; the X11 directory hidden where there is no display to keep; an untrusted X cookie where there is. |
| **everywhere else** | Nothing. `--info` says so. |

**The runtime directory is sealed to an allowlist, not a list of sockets to cover.** A denylist here
would have the same problem it has in the environment: it must enumerate every socket a desktop has
ever put in `$XDG_RUNTIME_DIR` and silently passes the next one. So a tmpfs goes over the directory
and only `wayland-*`, `pulse/native` and the pipewire sockets are bound back into it. The bus, the
keyring, the portal, the document store and anything the next release adds are gone without being
named. What is left is writable, so an app that wants a runtime file of its own gets one that leaves
with it.

The keepers are pinned by an `O_PATH` descriptor *before* the tmpfs goes on, because after it there
is no path left to bind from — `/proc/self/fd/<n>` still resolves to the original, which is the
whole
trick. The system bus lives at `/run/dbus/system_bus_socket`, outside that directory, so it is
covered by hand: `/dev/null` bind-mounted over a socket, which answers `ECONNREFUSED` rather than
`EPERM`, because that is the errno a client already knows how to read as "nothing is listening
there".

**The pid namespace is not decoration.** A mount namespace on its own is not a boundary:
`/proc/<pid>/root` of any process left outside it is a path straight back to every socket that was
just covered, and `connect()` walks it like any other path. The only thing in front of that is
Yama's `ptrace_scope`, which is `1` on Debian and Ubuntu and `0` on plenty of other distributions —
a boundary that holds or does not depending on a sysctl is not one. With a pid namespace and its own
`/proc` there is no outside process left to walk through. It costs the launcher its exit: the
process that asks for a pid namespace does not enter it, so netinstall forks, becomes pid 1, and
waits — reaping until the namespace is empty rather than exiting on the first child, or a polyglot
that backgrounds its own runtime would take everything down with it.

It also closes the `/proc` write grant that [is still open](#what-is-still-open) in the default
tier, and closes it better than the tight tier's narrower rule does: there is no peer entry to
write to rather than a rule refusing to write it, so nothing is given up on the way. The errno
says which — `ENOENT` here, `EACCES` from a ruleset — and `confine.sh` records both. Where a usable
user namespace can be had, this is the answer to that finding; the tight tier's rule is for the
machines where one cannot.

**What keeps the covers on** is Landlock, which denies `mount`, `umount`, `pivot_root` and
`move_mount` to any domain that handles even one filesystem right, by design and even inside a fresh
namespace. An app that nests another user namespace to get capabilities back still cannot unmount
anything, and the mounts it inherits are locked to each other by the kernel anyway. The order
matters: namespaces first, Landlock second, because Landlock would deny our own mounts otherwise.

**The display cannot be hidden, so it is untrusted instead.** The X11 SECURITY extension splits
clients in two, and an untrusted one is refused what makes X11 an escape. `xauth generate ...
untrusted` produces a cookie in the app directory, `XAUTHORITY` points at it, and the app connects
as a client the server itself distrusts. Measured on both engines, with controls: a screen capture
of the root window is **refused** where a trusted client gets a PNG, and a client that grabs the
keyboard and waits sees **none** of the injected keys that a trusted client in the same position
sees. The cost is the extension list, which drops from twenty-three to two — no XTEST, no RECORD,
and no XKB, MIT-SHM or GLX either. WebKitGTK and QtWebEngine both still came up.

Be precise about what that is worth. **It is a boundary only while the trusted cookie is out of
reach.** In the default tier reads are unconfined, so an app can read `~/.Xauthority` and connect
trusted anyway; there it raises the bar and no more. With `-DNEUTRINO_CONFINE_TIGHT` the trusted
cookie is not on the read allowlist — this tier is why that entry is now conditional — and the seal
covers the runtime directory where a display manager keeps the other copy. And it only means
anything on a server that requires authorisation at all: measured against an `Xvfb` started with
`-auth`, a client holding no cookie is refused, which is the assumption the rest rests on.

**Where it is unavailable it says so and runs anyway.** Ubuntu 24.04 and its derivatives give an
unprofiled binary the namespace and then refuse the `uid_map` write, so `--info` reports `session
open (uid map refused: Operation not permitted)` and Landlock, seccomp and the rest still apply.
The tier asks in a throwaway child first and declines to start what it cannot finish, because a
process that enters a user namespace and fails to map itself is left as the overflow uid — every
file it owns unreadable, and a webview that cannot start. It is not made a fatal condition even in a
strict build:
that would make the tier unusable on the most common desktop base rather than making it stronger.
`test/confine-session.sh` skips itself with a note on such a machine, and lifts the sysctl for the
length of its own run on CI, which is one of them.

What the tier does **not** close:

- **Anything the app is meant to keep.** The compositor socket is the app's window and the audio
  sockets are its sound; a hostile app can still talk to all three, and on an X11 session it can
  still talk to the display as an untrusted client.
- **The system bus on a machine that puts it elsewhere.** The cover names two paths.
- **Anything at all on Ubuntu 24.04 and its derivatives**, until someone lifts the sysctl or gives
  the binary a profile.

### Why Windows gets so little

Low integrity was the obvious next step and does not work: it blocks writes but not reads,
`%TEMP%` does not redirect so `jsc.exe` fails, and WebView2 does not render in a low-IL host — the
suite still launches one there every run and still reports a window that never draws.

**AppContainer does not work either, and that is now measured rather than assumed.** It is the only
mechanism that would confine *reads*, so it was worth being sure about. The app was launched inside
a real AppContainer — profile created, the three capabilities WebView2 needs in a packaged app
granted, and the directory holding the script handed to the container's SID with an inheritable ACE,
since an AppContainer starts with access to almost nothing and would otherwise fail on the grant
rather than on the mechanism. With an unrestricted control passing on the same clock before and
after, the container produced no window at all.

Where exactly it died was not isolated — the honest claim is that a webview does not come up inside
one, not that any particular call is at fault. The likely reason is the documented one, that
WebView2 builds lowbox tokens for its own renderers and AppContainers do not nest.

So reads stay unconfined on Windows. Every unprivileged mechanism the platform offers has now been
tried against a real webview: job object limits and privilege stripping work and are shipped, job UI
restrictions break it, low integrity breaks it, and AppContainer breaks it.

**Token privileges are stripped.** Every privilege but `SeChangeNotifyPrivilege`, which path
traversal needs, is *removed* rather than merely disabled, so nothing downstream can turn it back
on, and the token is inherited by everything the launcher starts. A standard user token carries few
privileges to begin with, so this is a small win — but it is free, it survives the hop to the real
app that per-process mitigation policies do not, and it was probed on its own against a real
webview before being shipped.

The one that is kept is kept **enabled**, which is a distinction `AdjustTokenPrivileges` makes and
the obvious spelling gets wrong: the attribute `0` reads as *disable*, not as *leave alone*. For a
while this code passed `0` and shipped a token where `SeChangeNotifyPrivilege` was present and
switched off. `privs.sh` asserts the difference where it is visible rather than where it is
convenient — the payload reads a file underneath a directory the account is explicitly denied
traverse on, which is exactly the check this privilege bypasses. With the privilege disabled that
read is refused; with it enabled it succeeds. Both states have been measured on a `windows-latest`
runner.

`--info` reports the same phrase from the same code, with the adjustment skipped. It used to be a
constant in the format string, so it promised a stripping regardless of what the token turned out
to be.

**Job UI restrictions do not work with WebView2 at all**, and that is measured rather than argued.
`JOBOBJECT_BASIC_UI_RESTRICTIONS` is the obvious remaining lever, and the only mechanism here that
survives the hop to the real app — the polyglot compiles itself and `START`s the result, so job
membership is inherited where a per-process mitigation policy would land on `cmd.exe` and stop
there. It was worth being sure about, so it was bisected instead of guessed at.

`test/job-ui.sh` applies each of the eight flags on its own to a real webview, one launch each, with
an unrestricted control run on the same clock before and after the table. Both controls passed. All
eight flags failed:

| flag | webview |
|---|---|
| `handles` | dead |
| `readclipboard` | dead |
| `writeclipboard` | dead |
| `systemparameters` | dead |
| `displaysettings` | dead |
| `globalatoms` | dead |
| `desktop` | dead |
| `exitwindows` | dead |

`exitwindows` only blocks `ExitWindowsEx` and `displaysettings` only blocks `ChangeDisplaySettings`,
so neither can plausibly be responsible on its own. Eight identical results bracketed by two passing
controls do not say "these eight flags are each fatal" — they say **any** non-empty UI restriction
mask is, and there is therefore no subset worth shipping. Since every singleton mask is a minimal
non-empty mask, that is as far as bisection can go; there is no smaller experiment left to run.

What it does *not* establish is why. The probe reports `WINDOW_NO_CONTENT`, which sounds like a
window whose renderer died — but the launcher's own `cmd.exe` console carries the script path in its
title, so that outcome cannot be told apart from the app never starting. Only `CONTENT_OK` is
unambiguous, because nothing but the app sets a `STEP` title. The mechanism is unexplained and the
plausible story — that Chromium's nested sandbox needs USER and desktop objects belonging to
processes outside our job — is a guess, written down as one.

So `NT_JOB_UI_DEFAULT` is empty, `--info` says `job object` with nothing after it, and the suite is
opt-in behind `NEUTRINO_JOB_UI_BISECT=1` rather than costing ten minutes of Windows CI on every push
to re-answer a settled question. The machinery stays so a future WebView2 can be re-tested in one
command instead of rebuilt from scratch.

The job object also carries no `KILL_ON_JOB_CLOSE`. The windows polyglot compiles itself, `START`s
the result and returns, so this launcher exits while the app is still starting; killing the job on
close would take the app down with it.

## Building

```bash
./build.sh          # every os/arch, needs zig
./build.sh host     # just this machine, needs cc
```

Four build-time flags change behaviour rather than platform: `-DNEUTRINO_STRICT_SANDBOX` refuses to
run when no confinement is available instead of warning, `-DNEUTRINO_CONFINE_TIGHT` enables the
experimental read-and-execute tier, `-DNEUTRINO_CONFINE_OFFLINE` denies the app the network, and
`-DNEUTRINO_CONFINE_NOSESSION` closes the session bus and untrusts the display. The last three are
separate axes and compose. Pass them through `NETINSTALL_CFLAGS`.

Targets: `linux-{x86_64,aarch64}` (musl, static), `macos-{x86_64,arm64}`,
`windows-{x86_64,aarch64}`. OpenBSD and FreeBSD build natively with `./build.sh host`.

## Testing

```bash
test/run.sh
```

Builds a release binary, a `-DNEUTRINO_TESTING` binary, one each for the tight, offline and session
tiers, and one with the session and tight tiers together, then runs eight suites: `names.sh` (the
grammar, accepted and rejected), `verify.sh` (pin mismatch, non-text payloads, oversized responses,
offline cache, tampered cache), `confine.sh`
(a hostile script that tries to escape — the filesystem, the environment, an inherited descriptor,
an abstract socket, another process's memory, and on macOS a bundle it wrote handed to
LaunchServices two different ways), `confine-strict.sh` (the tight tier, and whether a
webview still starts under it), `confine-session.sh` (the session tier: both buses closed against a
control that reaches them, the runtime dir sealed, no outside process visible, the screen
unphotographable from inside, and a real webview under all of it), `offline.sh` (that the offline
tier really refuses outbound TCP and, where it took a network namespace, UDP too, while the fetch
still worked), `strict.sh` (that `-DNEUTRINO_STRICT_SANDBOX` really refuses to run unconfined), and
`e2e.sh` (a real neutrino polyglot fetched, verified and launched).

`session.sh` is a ninth that does not run by default. It is a probe rather than a gate: it applies
each candidate mechanism on its own — covering the buses, sealing the runtime dir, hiding the
display, a pid namespace, a network namespace, an untrusted cookie — to a real webview, with an
unconfined control on the same clock either side and one lane that has to die. It answered, and
[the session tier](#the-session-tier-experimental) is what came of it, so it now needs
`NEUTRINO_SESSION_PROBE=1` and costs eight webview launches when you ask for it. The machinery stays
so a future engine or kernel can be re-measured in one command. Both it and
`confine-session.sh` lift `kernel.apparmor_restrict_unprivileged_userns` for the length of their own
run when CI refuses the namespace, say so in their results, and put it back; nothing shipped does
that.

`job-ui.sh` is an eighth suite that does not run by default: it is the Windows job UI bisect
described above, it needs `NEUTRINO_JOB_UI_BISECT=1`, and it takes about ten minutes because every
flag costs a real webview launch.

The `NEUTRINO_TEST_ORIGIN` override the suite needs to serve fixtures from loopback is compiled
in only under `-DNEUTRINO_TESTING`; release binaries ignore it entirely.
