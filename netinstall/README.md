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

## Options

```
--info      show what this name resolves to, then exit
--fetch     download and verify, but do not run
--verify    re-hash the cached script and report
--help, -h
--version, -v
--          end netinstall options; the rest goes to the script
```

`--info` is the audit path — it prints the resolved URL, the full SHA-256, every cache path, and
the confinement that would actually be applied.

## Layout

```
$NEUTRINO_HOME/                    # XDG_CACHE_HOME/neutrino
                                   # ~/Library/Caches/neutrino
                                   # %LOCALAPPDATA%\neutrino
├── blobs/<full-sha256>            # content-addressed, read-only
└── apps/<spec>/                   # read + execute only
    ├── <name>.cmd                 # read-only, hardlink to the blob
    └── <name>/                    # the only writable directory
```

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

## Trust model

**HTTPS is the trust anchor, not the pin.** There is no bundled TLS stack and no bundled CA set —
the fetch is delegated to the machine's own `curl` (or `wget`), using the OS trust store and the
user's own curl configuration. Nothing here expires or rots, and the trust decision stays where
the user can see and change it. This is the same posture as `curl | sh`.

`curl` is resolved from absolute paths rather than `$PATH`, so a planted `curl` cannot take over
the fetch. Its own configuration is *not* scrubbed: that config is the trust anchor you chose,
and removing your control over it would defeat the point. `--info` prints the effective command.

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
| **Linux** | Landlock. Writes confined to the app dir (plus `/proc`, `/dev`, `/dev/shm`); reads unrestricted. |
| **OpenBSD** | `unveil` + `pledge` execpromises, inherited by the child. |
| **macOS** | Seatbelt profile: `deny file-write*` outside the app dir, plus read denials on `~/.ssh`, Keychains, Mail, Safari and browser profiles. |
| **Windows** | Job object — process limits only. **No filesystem confinement** by default; see the tight tier. |
| **FreeBSD** | None. |

If nothing is available the binary **runs anyway and warns on stderr**, naming what was and
wasn't applied; confinement here is defence in depth, not the trust anchor. Building with
`-DNEUTRINO_STRICT_SANDBOX` produces a binary that refuses to run unconfined instead.

### Where confinement is theatre

Be clear-eyed about this. Landlock does not mediate `connect()` to a pathname unix socket before
ABI 9, so an app can still reach whatever sockets exist:

- **Session D-Bus** lets an app call `StartTransientUnit` and launch a process outside the
  sandbox entirely. If it can reach the session bus, it is not confined.
- **X11** lets any client keylog and screenshot every other client. On an X11 session, the
  filesystem restriction is the only thing that holds.

### Why Linux restricts writes but not reads by default

A read allowlist forces WebKitGTK's `bubblewrap` and Chromium's zygote to fight our ruleset, and
Landlock unconditionally denies `mount` and `pivot_root` to any domain that handles a filesystem
right — by design, even inside a fresh namespace. `PR_SET_NO_NEW_PRIVS`, which Landlock requires,
also neuters Chromium's SUID sandbox helper. Buying our allowlist by disabling the renderer's own
sandbox trades protection from the app author for protection from web content, and that is not
obviously a win. The XDG redirection above gets most of the benefit for none of that cost.

### The tight tier (experimental)

Building with `-DNEUTRINO_CONFINE_TIGHT` turns on a second, stronger tier. It means something
different on each platform, because the mechanisms differ in what they can express:

| Platform | What the tight tier adds |
|---|---|
| **Linux** | Landlock handles read rights too, so `$HOME` becomes deny-by-default. |
| **macOS** | Seatbelt denies reads of all of `$HOME` rather than a named list of secrets. |
| **Windows** | The process drops to low integrity, so writes outside the app dir fail. |
| **OpenBSD** | Nothing — `unveil` is already an allowlist, so the default tier is the tight one. |

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

### Why Windows gets so little

Low integrity was the obvious next step and does not work: it blocks writes but not reads,
`%TEMP%` does not redirect so `jsc.exe` fails, and WebView2 is documented to break in low-IL
hosts. AppContainer is the only mechanism that would confine reads, but nesting it inside
Chromium's own lowbox tokens is unsupported. Both are follow-ups, not v1 promises.

The job object also carries no `KILL_ON_JOB_CLOSE`. The windows polyglot compiles itself, `START`s
the result and returns, so this launcher exits while the app is still starting; killing the job on
close would take the app down with it.

## Building

```bash
./build.sh          # every os/arch, needs zig
./build.sh host     # just this machine, needs cc
```

Two build-time flags change behaviour rather than platform: `-DNEUTRINO_STRICT_SANDBOX` refuses to
run when no confinement is available instead of warning, and `-DNEUTRINO_CONFINE_TIGHT` enables the
experimental tier described above. Pass them through `NETINSTALL_CFLAGS`.

Targets: `linux-{x86_64,aarch64}` (musl, static), `macos-{x86_64,arm64}`,
`windows-{x86_64,aarch64}`. OpenBSD and FreeBSD build natively with `./build.sh host`.

## Testing

```bash
test/run.sh
```

Builds a release binary, a `-DNEUTRINO_TESTING` binary and a `-DNEUTRINO_CONFINE_TIGHT` one, then
runs five suites: `names.sh` (the grammar, accepted and rejected), `verify.sh` (pin mismatch,
non-text payloads, oversized responses, offline cache, tampered cache), `confine.sh` (a hostile
script that tries to escape), `confine-strict.sh` (the tight tier, and whether a webview still
starts under it), and `e2e.sh` (a real neutrino polyglot fetched, verified and launched).

The `NEUTRINO_TEST_ORIGIN` override the suite needs to serve fixtures from loopback is compiled
in only under `-DNEUTRINO_TESTING`; release binaries ignore it entirely.
