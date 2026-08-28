#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# parse.sh - Assertions for the host-side message splitter.
#
# The splitter is the boundary between page content and the native driver, and
# it is pure JavaScript with no window, no engine and no display behind it. So
# it can be asserted directly, in a second, on every push -- which is worth
# doing, because the adversarial app that exercises the same boundary end to end
# needs a display, a real engine and about a minute per platform.
#
# The object is lifted out of webview.cmd itself rather than copied, so these
# assertions cannot pass against a stale duplicate of the code that ships.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-$ROOT/webview.cmd}"
# Resolved before anything changes directory, because the assertions run from a
# work directory and a relative path would quietly stop meaning the same file.
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! command -v node >/dev/null 2>&1; then
    echo "parse.sh: node not found; cannot assert the splitter" >&2
    exit 1
fi

# The conditional-compilation block holds JScript.NET that only jsc may see,
# and it hides it inside a block comment. JavaScript has no nested block
# comments, so a single "*/" written in there ends the outer comment early and
# spills typed JScript into gjs, JXA and QML at once. It costs a line to check
# and it is invisible until three engines break together.
CC_BLOCK="$(sed -n '/\/\*@cc_on/,/@\*\//p' "$TARGET")"
if printf '%s' "$CC_BLOCK" | sed 's/@\*\///' | grep -q '[*]/'; then
    echo "parse.sh: a block comment is closed inside the @cc_on block" >&2
    echo "          use line comments in there; the block is already a comment" >&2
    exit 1
fi

# And the document's doctype has to be the first one in the file, because both
# halves are cut from it: the document runs from the doctype to the script tag
# after it, and the page script from that same tag. A line in the shell region
# that merely mentions the doctype -- a comment, a here-document, a message --
# starts the cut hundreds of lines early, and the document that comes out has
# the launcher's own text ahead of its <head>. That was measured on four
# engines: a content policy meta outside head is in the DOM and is not a
# policy, Chromium enforces none of it, WebKit enforces only the element-driven
# half, and the page reports the policy it can see either way. The launcher
# refuses such a source at run time; this catches it a push earlier, where the
# message can say what happened.
FIRST_DOC="$(grep -in '<!doctype html' "$TARGET" | head -1 | cut -d: -f1)"
DOC_LINE="$(grep -n '^<!doctype html><html>' "$TARGET" | head -1 | cut -d: -f1)"
if [ -z "$DOC_LINE" ] || [ "$FIRST_DOC" != "$DOC_LINE" ]; then
    echo "parse.sh: the document's doctype is not the first one in the file" >&2
    echo "          first at line ${FIRST_DOC:-none}, the document's at line ${DOC_LINE:-none}" >&2
    echo "          both halves are cut from it; do not name it earlier" >&2
    exit 1
fi
# The script tag no longer has to be first -- extraction anchors on the doctype
# and searches from there -- but it does have to be after it, which is the same
# check said the way the code now reads.
DOC_TAG="$(grep -n '^<script type=text/javascript>' "$TARGET" | head -1 | cut -d: -f1)"
if [ -z "$DOC_TAG" ] || [ "$DOC_TAG" -lt "$DOC_LINE" ]; then
    echo "parse.sh: the document's script tag is not after its doctype" >&2
    echo "          doctype at line ${DOC_LINE:-none}, script tag at line ${DOC_TAG:-none}" >&2
    exit 1
fi
echo "  PASS: the document is cut from the first doctype in the file"

# The document's body opens on the document line and closes on the last line of
# the file, and that last line is also the shell's here-document delimiter --
# the one on line 1374 has to match it character for character. They are the
# only two lines in the polyglot that have to agree with each other, they are
# nowhere near each other, and nothing else notices when they stop: a shell
# reading a here-document that never terminates warns and carries on, so the
# launcher still runs and the file is no longer an HTML document.
DELIM_OPEN="$(sed -n "s/^exit \$?;:<<'\(.*\)' #-->\$/\1/p" "$TARGET" | head -1)"
DELIM_CLOSE="$(tail -1 "$TARGET")"
if [ -z "$DELIM_OPEN" ] || [ "$DELIM_OPEN" != "$DELIM_CLOSE" ]; then
    echo "parse.sh: the here-document delimiter and the last line disagree" >&2
    echo "          opens with '${DELIM_OPEN:-nothing}', ends with '$DELIM_CLOSE'" >&2
    exit 1
fi
echo "  PASS: the here-document delimiter is the line that closes the document"

# One line, and it has to stay one line. The style and the body an author builds
# in are spliced into it whole, so a newline anywhere in there puts the body
# below the cut and the launcher loads a document without it -- silently, since
# the halves still split and the policy is still in the head.
if [ "$(grep -c '^<!doctype html><html>' "$TARGET")" != "1" ]; then
    echo "parse.sh: the document line is not there exactly once" >&2
    exit 1
fi
if ! grep -q '^<!doctype html><html>.*<style>.*</style></head><body>' "$TARGET"; then
    echo "parse.sh: the document line does not open its own body" >&2
    echo "          wanted: <!doctype html><html>...<style>...</style></head><body>..." >&2
    exit 1
fi
echo "  PASS: the document line opens the body build.sh splices into"

for nt_mark in CONFIG_START CONFIG_END; do
    if [ "$(grep -c "//#$nt_mark" "$TARGET")" != "1" ]; then
        echo "parse.sh: the //#$nt_mark sentinel is not there exactly once" >&2
        echo "          build.sh stamps the title and the size between them" >&2
        exit 1
    fi
done
echo "  PASS: the config sentinels build.sh stamps between are both there"

# The same hazard, everywhere else in the file, caught by its consequence
# rather than by its shape. Everything from the first line to the <script> tag
# is one block comment, and the shell region lives inside it -- so a sed
# expression ending in ".*" then "/" closes the comment two hundred lines early
# and gjs, jsc, JXA and QML all fail at once on a line that is not the one that
# broke them. The check above only ever looked at the @cc_on block; this asks
# the parser, which is what actually decides.
#
# node is not the engine any lane ships, and it does not have to be: what is
# being caught here is a file that stopped being one comment, which every
# JavaScript parser agrees about.
cp "$TARGET" "$WORK/whole.js"
if ! node --check "$WORK/whole.js" 2>"$WORK/whole.err"; then
    echo "parse.sh: the polyglot does not parse as JavaScript" >&2
    sed 's/^/          /' "$WORK/whole.err" >&2
    exit 1
fi
echo "  PASS: the whole file still parses as JavaScript"

sed -n '/^    var NeutrinoWebview = {/,/^    };$/p' "$TARGET" > "$WORK/obj.js"
echo "module.exports = NeutrinoWebview;" >> "$WORK/obj.js"

if [ ! -s "$WORK/obj.js" ]; then
    echo "parse.sh: could not lift NeutrinoWebview out of $TARGET" >&2
    exit 1
fi

cat > "$WORK/assert.js" <<'JSEOF'
var N = require("./obj.js");
var S = String.fromCharCode(31);
var failures = 0;

// The splitter's own assertions are about the splitter, so they are taken at a
// known tier rather than at whichever one the artifact under test was stamped
// with. Without this an offline build fails the openExternal cases below by
// behaving exactly as it is supposed to, and the tier's behaviour is asserted
// on its own terms further down.
N.tiers = "default";

function eq(name, got, want) {
    var ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        failures++;
        console.log("  FAIL: " + name + " -- got " + JSON.stringify(got) +
                    ", wanted " + JSON.stringify(want));
    } else {
        console.log("  PASS: " + name);
    }
}

console.log("legitimate traffic still arrives");
eq("setTitle", N.parseMessage("setTitle" + S + "Hello World"),
   { action: "setTitle", title: "Hello World" });
eq("resize", N.parseMessage("resize" + S + "500" + S + "400"),
   { action: "resize", width: 500, height: 400 });
eq("move", N.parseMessage("move" + S + "0" + S + "0"),
   { action: "move", x: 0, y: 0 });
eq("move accepts negative coordinates", N.parseMessage("move" + S + "-10" + S + "-20"),
   { action: "move", x: -10, y: -20 });
eq("close", N.parseMessage("close"), { action: "close" });
eq("openExternal", N.parseMessage("openExternal" + S + "https://example.com/x"),
   { action: "openExternal", url: "https://example.com/x" });

console.log("a field cannot be split into two");
eq("separator in a title", N.parseMessage("setTitle" + S + "a" + S + "b"), null);
eq("separator in a url", N.parseMessage("openExternal" + S + "https://a" + S + "https://b"), null);

console.log("malformed records are dropped, not repaired");
eq("close with a payload", N.parseMessage("close" + S + "x"), null);
eq("resize missing a field", N.parseMessage("resize" + S + "1"), null);
eq("resize with an extra field", N.parseMessage("resize" + S + "1" + S + "2" + S + "3"), null);
eq("resize with code in a field",
   N.parseMessage("resize" + S + "1;GLib.spawn_command_line_sync('x')" + S + "2"), null);
eq("resize to zero", N.parseMessage("resize" + S + "0" + S + "0"), null);
eq("resize to negative", N.parseMessage("resize" + S + "-5" + S + "-5"), null);
eq("an action nobody implements", N.parseMessage("evalThis" + S + "whatever"), null);
eq("control character in a title", N.parseMessage("setTitle" + S + "a\nb"), null);
eq("a title larger than any real one", N.parseMessage("setTitle" + S + new Array(5000).join("x")), null);
eq("an empty record", N.parseMessage(""), null);
eq("no record at all", N.parseMessage(null), null);

console.log("openExternal takes an allowlist, not a denylist");
var urls = [
    ["https://example.com", true],
    ["http://example.com/a?b#c", true],
    ["HTTPS://EXAMPLE.COM/", true],
    ["mailto:someone@example.com", true],
    ["file:///etc/passwd", false],
    ["javascript:alert(1)", false],
    ["data:text/html,x", false],
    ["ms-settings:", false],
    ["search-ms:query=x", false],
    ["vscode://x", false],
    ["\\\\server\\share", false],
    ["https://", false],
    ["  https://example.com", false],
    ["https:evil", false],
    ["javascript:alert(1)\nhttps://example.com", false]
];
for (var i = 0; i < urls.length; i++) {
    eq(JSON.stringify(urls[i][0]), N.isExternalUrl(urls[i][0]), urls[i][1]);
}

console.log("only a document with no network origin may drive the window");
var origins = [
    ["", "", true],
    ["file", "", true],
    ["https", "example.com", false],
    ["http", "localhost", false],
    ["https", "", false],
    ["file", "evil.example", false],
    ["ftp", "example.com", false]
];
for (var o = 0; o < origins.length; o++) {
    eq(JSON.stringify(origins[o][0] + "://" + origins[o][1]),
       N.isTrustedOrigin(origins[o][0], origins[o][1]), origins[o][2]);
}

console.log("a message is judged by the document the view is showing");
// trustedView is state, so each case starts from nothing rather than from
// whatever the case above it left behind.
function withView(uri) {
    N.trustedView = null;
    if (uri !== undefined) N.rememberTrustedView(uri);
    return N;
}
// The fail-open this used to assert. It was defensible only while the macOS
// driver remembered its document at the first message and so could not
// distinguish "the app has not spoken yet" from "a page navigated before it
// did"; every driver now arms at the load it started, before any page script
// exists to send anything.
eq("nothing committed yet is refused",
   withView().isTrustedView("https://example.com/"), false);
// A view that will not say what it committed is not a document to pin the
// session to -- remembering the empty answer would refuse the app itself
// forever after, and silently.
eq("an empty answer is not remembered",
   withView("").trustedView, null);
eq("the remembered document is trusted",
   withView("about:blank").isTrustedView("about:blank"), true);
// The half that would have muted working apps: hash routing changes the uri
// every engine here reports, and it navigates nowhere.
eq("a fragment on the remembered document is trusted",
   withView("about:blank").isTrustedView("about:blank#route/2"), true);
eq("the document was remembered without its fragment",
   withView("about:blank#one").isTrustedView("about:blank#two"), true);
eq("a remote origin is refused",
   withView("about:blank").isTrustedView("https://example.com/"), false);
// Qt hands the document over as a data: url, so the whole url is the identity
// and a different data: document is a different document.
eq("the data: document the view was given is trusted",
   withView("data:text/html,neutrino").isTrustedView("data:text/html,neutrino"), true);
eq("another data: document is not",
   withView("data:text/html,neutrino").isTrustedView("data:text/html,evil"), false);
// Stricter than the macOS origin rule it joins, which admits any file: url.
eq("another local document is refused",
   withView("file:///app/").isTrustedView("file:///app/other.html"), false);
var remembered = withView("about:blank");
remembered.rememberTrustedView("https://example.com/");
eq("the first document remembered is the only one",
   remembered.isTrustedView("about:blank"), true);
N.trustedView = null;

console.log("a fragment is not a navigation away from the document");
eq("about:blank", N.isOwnDocument("about:blank"), true);
eq("about:blank with a fragment", N.isOwnDocument("about:blank#route"), true);
eq("a bare fragment", N.isOwnDocument("#route"), true);
eq("empty", N.isOwnDocument(""), true);
eq("a remote origin with a fragment", N.isOwnDocument("https://example.com/#x"), false);
eq("a fragment that only looks local", N.isOwnDocument("https://about:blank"), false);

console.log("the preload the page receives is valid javascript");
var vm = require("vm");
var transports = [
    "window.webkit.messageHandlers.neutrino.postMessage",
    "function(m){document.title='__NEUTRINO__'+encodeURIComponent(m);}",
    'function(m){console.log("__NEUTRINO__"+m);}'
];
for (var t = 0; t < transports.length; t++) {
    var built = N.buildPreloadScript(transports[t]);
    var parsed = true;
    try { new vm.Script(built); } catch (e) { parsed = false; }
    eq("transport " + t + " builds a parsable preload", parsed, true);
}

console.log("what the page sends is what the host accepts");
var sent = [];
var sandbox = { window: {}, String: String, JSON: JSON, __t: function (m) { sent.push(m); } };
vm.createContext(sandbox);
new vm.Script(N.buildPreloadScript("__t")).runInContext(sandbox);
sandbox.window.neutrino.window.setTitle("STEP1-Test Title");
sandbox.window.neutrino.window.resize(500, 400);
sandbox.window.neutrino.window.move(0, 0);
sandbox.window.neutrino.window.close();
sandbox.window.neutrino.shell.openExternal("https://example.com");
eq("setTitle round trip", N.parseMessage(sent[0]), { action: "setTitle", title: "STEP1-Test Title" });
eq("resize round trip", N.parseMessage(sent[1]), { action: "resize", width: 500, height: 400 });
eq("move round trip", N.parseMessage(sent[2]), { action: "move", x: 0, y: 0 });
eq("close round trip", N.parseMessage(sent[3]), { action: "close" });
eq("openExternal round trip", N.parseMessage(sent[4]), { action: "openExternal", url: "https://example.com" });
var before = sent.length;
sandbox.window.neutrino.send("evalThis", { payload: "x" });
eq("an action nobody implements never reaches the wire", sent.length, before);

console.log("the webview2 package is pinned, and only what is pinned is unpacked");
// This app downloads its Windows engine assemblies and loads them, so what it
// fetches and what it writes are both part of the boundary. None of that needs
// Windows to assert: the pin is data and the unpack command is a string this
// object builds.
var HEX64 = /^[0-9a-f]{64}$/;
eq("the pinned version is a version", /^[0-9]+(\.[0-9]+)+$/.test(N.webView2PinnedVersion), true);
eq("the archive digest is a sha-256", HEX64.test(N.webView2PinnedSha256), true);
// The version and the url are two ways of saying the same thing, and a bump
// that changes one and not the other fetches a package the digests do not
// describe.
eq("the url names the pinned version",
   N.webView2PackageUrl().split(N.webView2PinnedVersion).length - 1, 2);
eq("the url is the flat container", N.webView2PackageUrl().indexOf("https://api.nuget.org/v3-flatcontainer/") , 0);

// The member paths are what become filesystem paths, so they are the thing that
// has to be safe. The old code took that name from the archive instead, and a
// backslash in it walked out of the package directory.
eq("there are members to pin at all", N.webView2Members.length > 0, true);
var seenMember = {};
for (var mi = 0; mi < N.webView2Members.length; mi++) {
    var mem = N.webView2Members[mi];
    eq(mem.path + " has a sha-256", HEX64.test(mem.sha256), true);
    eq(mem.path + " is a relative forward-slash path",
       /^[A-Za-z0-9][A-Za-z0-9._-]*(\/[A-Za-z0-9][A-Za-z0-9._-]*)+$/.test(mem.path) &&
       mem.path.indexOf("..") < 0, true);
    eq(mem.path + " is pinned once", seenMember[mem.path] === undefined, true);
    seenMember[mem.path] = true;
}

// The unpack, driven rather than described. This used to build a PowerShell
// command and the assertions read the string; it now takes the archive apart
// itself, so the fake is System.IO.Compression and what is asserted is what it
// did with it.
var zipOpened = null;
var zipDisposed = false;
var zipAsked = [];
var zipWrote = [];
var zipMadeDirs = [];
var zipEntries = {};
for (var zi = 0; zi < N.webView2Members.length; zi++) {
    zipEntries[N.webView2Members[zi].path] = { tag: N.webView2Members[zi].path };
}
function zipSystem(entries) {
    return {
        Convert: { ToInt32: function (x) { return x; } },
        IO: {
            Path: {
                Combine: function (a, b) { return a + "\\" + b; },
                GetDirectoryName: function (p) { return p.substring(0, p.lastIndexOf("\\")); }
            },
            Directory: {
                Exists: function (_d) { return false; },
                CreateDirectory: function (d) { zipMadeDirs.push(d); }
            },
            Compression: {
                ZipFile: {
                    OpenRead: function (path) {
                        zipOpened = path;
                        return {
                            GetEntry: function (name) {
                                zipAsked.push(name);
                                return Object.prototype.hasOwnProperty.call(entries, name)
                                    ? entries[name] : null;
                            },
                            Dispose: function () { zipDisposed = true; }
                        };
                    }
                },
                ZipFileExtensions: {
                    ExtractToFile: function (entry, out, overwrite) {
                        zipWrote.push({ tag: entry.tag, out: out, overwrite: overwrite });
                    }
                }
            }
        }
    };
}

N.extractWebView2Members(zipSystem(zipEntries), "C:\\tmp\\p.zip", "C:\\app\\Microsoft.Web.WebView2");
eq("the unpack opens the archive it was handed", zipOpened, "C:\\tmp\\p.zip");
eq("the unpack closes it", zipDisposed, true);
eq("the unpack asks for every pinned member and nothing else",
   zipAsked.join("|"), (function () {
       var names = [];
       for (var k = 0; k < N.webView2Members.length; k++) { names.push(N.webView2Members[k].path); }
       return names.join("|");
   })());
// The whole of the zip-slip fix, and it survived the move out of PowerShell:
// the name that becomes a path comes from the list above and never from the
// archive. An unpack that read the entry's own name would join an
// attacker-supplied string onto a destination again.
eq("every destination is built from the pinned name", (function () {
    for (var w = 0; w < zipWrote.length; w++) {
        var want = "C:\\app\\Microsoft.Web.WebView2\\" +
            N.webView2Members[w].path.replace(/\//g, "\\");
        if (zipWrote[w].out !== want || zipWrote[w].tag !== N.webView2Members[w].path) {
            return zipWrote[w].out;
        }
    }
    return zipWrote.length === N.webView2Members.length ? true : "wrote " + zipWrote.length;
})(), true);
eq("an existing file is overwritten rather than left",
   zipWrote.length > 0 && zipWrote[0].overwrite === true, true);
eq("the parent directory is created before the write", zipMadeDirs.length, zipWrote.length);

// A member the package does not have is fatal, and the archive is still closed.
zipDisposed = false;
zipWrote = [];
var partial = {};
for (var pi = 1; pi < N.webView2Members.length; pi++) {
    partial[N.webView2Members[pi].path] = { tag: N.webView2Members[pi].path };
}
var missingThrew = false;
try {
    N.extractWebView2Members(zipSystem(partial), "C:\\tmp\\p.zip", "C:\\app\\Microsoft.Web.WebView2");
} catch (missingErr) {
    missingThrew = String(missingErr.message || missingErr).indexOf("is missing") >= 0;
}
eq("a member the package does not have is fatal", missingThrew, true);
eq("and the archive is closed anyway", zipDisposed, true);
eq("and nothing was written", zipWrote.length, 0);

console.log("the package directory is emptied without following what is in it");
// Not a boundary -- measured, a recursive Directory.Delete unlinks a junction
// rather than walking through it. What it also does is throw afterwards, which
// is a launch refusing for a reason nobody can act on. This is the walk that
// replaced it, and what is asserted here is that it does not descend into a
// reparse point; test/winexec.ps1 asserts the platform fact underneath.
var delRemoved = [];
var delListed = [];
// The driver walks CLR String[] and asks for `.Length`, the way every other
// array in that region does. A JavaScript array has `length` and not `Length`,
// so a fake that forgets this reports an empty directory and every assertion
// below passes for the wrong reason -- it did, once.
function clr(a) { a.Length = a.length; return a; }
function treeSystem(tree, attrs) {
    return {
        Convert: { ToInt32: function (x) { return x; } },
        IO: {
            Directory: {
                GetFiles: function (d) { delListed.push(d); return clr(tree[d] ? tree[d].files : []); },
                GetDirectories: function (d) { return clr(tree[d] ? tree[d].dirs : []); },
                Delete: function (d, recursive) { delRemoved.push(d + (recursive ? "!" : "")); }
            },
            File: {
                Delete: function (f) { delRemoved.push(f); },
                GetAttributes: function (d) { return attrs[d] || 0; }
            }
        }
    };
}
var tree = {
    "R": { files: ["R\\a.dll"], dirs: ["R\\real", "R\\link"] },
    "R\\real": { files: ["R\\real\\b.dll"], dirs: [] },
    "R\\link": { files: ["R\\link\\SHOULD-NOT-BE-TOUCHED"], dirs: [] }
};
N.deleteTree(treeSystem(tree, { "R\\link": 1024 }), "R");
eq("a reparse point is unlinked and not descended into",
   delListed.join("|"), "R|R\\real");
eq("nothing under the reparse point is touched",
   delRemoved.join("|").indexOf("SHOULD-NOT-BE-TOUCHED") < 0, true);
eq("everything else goes",
   delRemoved.join("|"), "R\\a.dll|R\\real\\b.dll|R\\real|R\\link|R");

console.log("an extracted package is checked against the pin, not its filenames");
function hexBytes(hex) {
    var out = [];
    for (var h = 0; h < hex.length; h += 2) { out.push(hex.substr(h, 2).toUpperCase()); }
    return out;
}
function fakeSystem(files) {
    return {
        IO: {
            Path: { Combine: function (a, b) { return a + "\\" + b; } },
            File: {
                Exists: function (p) { return Object.prototype.hasOwnProperty.call(files, p); },
                OpenRead: function (p) {
                    if (!Object.prototype.hasOwnProperty.call(files, p)) { throw new Error("no such file"); }
                    return { path: p, Close: function () {} };
                }
            }
        },
        Security: { Cryptography: { SHA256: { Create: function () {
            return { ComputeHash: function (stream) { return files[stream.path]; } };
        } } } },
        BitConverter: { ToString: function (bytes) { return bytes.join("-"); } }
    };
}
var PKGROOT = "C:\\app\\Microsoft.Web.WebView2";
function packageOnDisk(overrides) {
    var files = {};
    for (var k = 0; k < N.webView2Members.length; k++) {
        var m = N.webView2Members[k];
        var digest = (overrides && overrides[m.path]) || m.sha256;
        files[PKGROOT + "\\" + m.path.replace(/\//g, "\\")] = hexBytes(digest);
    }
    return files;
}
var WRONG = "0000000000000000000000000000000000000000000000000000000000000000";
// The control: the digests this object pins, formatted the way it formats them,
// have to come back matching -- otherwise every case below refuses for the
// wrong reason and the app re-downloads on every launch forever.
eq("a package matching every pin is accepted",
   N.firstBadWebView2Member(fakeSystem(packageOnDisk()), PKGROOT), null);
var lastMember = N.webView2Members[N.webView2Members.length - 1];
var swapped = {};
swapped[lastMember.path] = WRONG;
eq("one member with the wrong contents refuses the package",
   N.firstBadWebView2Member(fakeSystem(packageOnDisk(swapped)), PKGROOT), lastMember.path);
eq("a member that is not there refuses the package",
   N.firstBadWebView2Member(fakeSystem({}), PKGROOT), N.webView2Members[0].path);
// A file that cannot be read is not a file that passed.
var unreadable = packageOnDisk();
unreadable[PKGROOT + "\\" + lastMember.path.replace(/\//g, "\\")] = null;
eq("a member that cannot be hashed refuses the package",
   N.firstBadWebView2Member(fakeSystem(unreadable), PKGROOT), lastMember.path);

console.log("the document carries a content policy");
var fs = require("fs");
var html = N.extractHtmlDocument(fs.readFileSync(process.argv[2], "utf8"));
function policyOf(doc) {
    var m = doc.match(/<meta http-equiv="Content-Security-Policy" content="([^"]*)"/);
    return m ? m[1] : null;
}
eq("the document starts at the doctype", html.toLowerCase().indexOf("<!doctype html"), 0);

// The document is inert and the code is injected, so both halves are worth
// checking here: a document that still carries a script would be governed by a
// policy that forbids one, and a page script that does not parse means the app
// never starts, which otherwise only shows up as a window that renders nothing.
eq("the document carries no script of its own", html.indexOf("<script") < 0, true);
var pageScript = N.extractPageScript(fs.readFileSync(process.argv[2], "utf8"));
eq("a page script was extracted", pageScript.length > 1000, true);
var pageScriptParses = true;
try { new vm.Script(pageScript); } catch (e) { pageScriptParses = false; }
eq("the page script parses as javascript", pageScriptParses, true);
eq("default tier gets the default policy", policyOf(html), N.defaultContentPolicy);

// The early shell. The document the engine loads is the document in the file
// now, rather than the head cut with an empty body appended, and that is the
// whole of why an app can paint before its script runs. Asserted on the real
// artifact because the thing that would break it -- a build that spliced the
// style or the body somewhere the cut does not reach -- produces a file that
// still splits, still carries the policy, and comes up blank.
eq("the document opens exactly one body", (html.match(/<body>/g) || []).length, 1);
eq("and closes it at the end", html.slice(-14), "</body></html>");
eq("the document carries a style", /<style>[\s\S]*<\/style><\/head><body>/.test(html), true);
eq("nothing of the shell region is above the doctype", html.indexOf("exit") < 0, true);

// What the native window needs before there is a document to read it from, and
// nothing else. `url` sat here unread for the length of the project; a key
// nobody consumes is the shape this asserts against coming back.
eq("config carries only what createWindow needs",
   Object.keys(N.config).sort(), ["background", "height", "title", "width"]);
eq("the title is a non-empty string", typeof N.config.title === "string" && N.config.title.length > 0, true);
eq("the size is two positive whole numbers",
   [N.config.width > 0 && N.config.width === Math.floor(N.config.width),
    N.config.height > 0 && N.config.height === Math.floor(N.config.height)], [true, true]);

// The colour every lane paints its two pre-document surfaces with. Four of the
// five hand the string straight to a toolkit that parses it; the fifth builds
// an NSColor from components. This is the one reading they all come from, and a
// build whose background none of them can read is a window that comes up in the
// theme colour -- which is the shape this whole value exists to close.
eq("the background parses", N.parseColor(N.config.background) !== null, true);
var colors = [
    ["#000000", { red: 0, green: 0, blue: 0 }],
    ["#ffffff", { red: 1, green: 1, blue: 1 }],
    ["#fff", { red: 1, green: 1, blue: 1 }],
    ["#12141a", { red: 18 / 255, green: 20 / 255, blue: 26 / 255 }],
    ["#FFFFFF", { red: 1, green: 1, blue: 1 }]
];
for (var c = 0; c < colors.length; c++) {
    eq("parseColor " + colors[c][0], N.parseColor(colors[c][0]), colors[c][1]);
}
// Refused rather than read as black, so a lane can leave its surface alone
// instead of painting it a colour nobody asked for.
var badColors = ["", null, "white", "rgb(1,2,3)", "#12", "#1234", "#12345", "#1234567",
                 "12141a", "#12141g", " #121212", "#121212 "];
for (var b = 0; b < badColors.length; b++) {
    eq("parseColor refuses " + JSON.stringify(badColors[b]), N.parseColor(badColors[b]), null);
}
N.tiers = "default,offline";
eq("offline tier gets the offline policy", policyOf(N.applyContentPolicy(html)), N.offlineContentPolicy);
N.tiers = "default";
eq("default tier leaves the document alone", policyOf(N.applyContentPolicy(html)), N.defaultContentPolicy);

// The shapes this launcher refuses, and the reason they are assertions rather
// than a probe: both functions are pure, so what an engine would do with a
// document that came out wrong is a consequence and what comes out is a fact.
// The consequences were measured once, on four engines -- a document cut from
// the wrong doctype carries a policy that is in the DOM and not in force, and
// one cut with no doctype at all carries none -- and every case below returned
// something before this PR instead of refusing.
console.log("");
console.log("a source this launcher cannot split is refused, and says why");

var DOC = '<!doctype html><html><head>' +
          '<meta http-equiv="Content-Security-Policy" content="' + N.defaultContentPolicy + '">' +
          '<style>p{color:red}</style></head><body><p>the early shell</p>';
var TAG = '\n<script type=text/javascript>';
var CODE = '\nvar x = 1;\n';
var ENDS = '//</script>\n';
var WHOLE = 'shell region\n' + DOC + TAG + CODE + ENDS;
// The cut runs to the script tag, so whatever sits between the document and
// that tag belongs to the document -- here the newline TAG opens with, exactly
// as in this file. The tail used to be fabricated, and an empty body was
// appended no matter what the source said; the style and the body above are
// what an author builds in, and this asserts they arrive.
var SPLIT_DOC = DOC + '\n</body></html>';

function refuses(name, source) {
    var results = [
        ["extractHtmlDocument", function () { return N.extractHtmlDocument(source); }],
        ["extractPageScript", function () { return N.extractPageScript(source); }]
    ];
    for (var i = 0; i < results.length; i++) {
        var what = results[i][0], got = null, threw = false, msg = "";
        try { got = results[i][1](); } catch (e) { threw = true; msg = String(e.message || e); }
        if (!threw) {
            failures++;
            console.log("  FAIL: " + name + " -- " + what + " returned " +
                        JSON.stringify(String(got).slice(0, 60)) + " instead of refusing");
        } else if (msg.indexOf("neutrino: cannot tell") !== 0) {
            failures++;
            console.log("  FAIL: " + name + " -- " + what + " refused without saying why: " + msg);
        } else {
            console.log("  PASS: " + name + " (" + what + ")");
        }
    }
}

// The control. Every refusal below is only a reading if the shape they are
// derived from splits, and splits into exactly these two halves.
eq("a well-formed source gives the document", N.extractHtmlDocument(WHOLE), SPLIT_DOC);
eq("and the page script the tag encloses", N.extractPageScript(WHOLE), CODE);

// The anchoring, which is what stops the two halves being cut from different
// places. A script tag above the document used to move the page script and not
// the document; now neither moves, and parse.sh no longer has to forbid it.
var ABOVE = 'shell <script> region\n' + DOC + TAG + CODE + ENDS;
eq("a script tag above the document moves neither half",
   [N.extractHtmlDocument(ABOVE), N.extractPageScript(ABOVE)], [SPLIT_DOC, CODE]);

// Before this PR: the whole file, cut at the first script tag. On the real file
// that was 186 bytes of locateDocument's own source and no content policy.
refuses("no doctype at all", 'shell region\n<html><head></head>' + TAG + CODE + ENDS);
// Before this PR: a document starting in the shell region, with the policy meta
// outside its own head.
refuses("a doctype named above the document",
        'a line naming <!doctype html> up here\n' + DOC + TAG + CODE + ENDS);
// Before this PR: an empty page script, injected by every driver without a word.
refuses("nothing opening a script after the doctype", 'shell <script> region\n' + DOC);
refuses("nothing closing the page script", 'shell region\n' + DOC + TAG + CODE);
refuses("an empty source", "");

// The offline tier is one string replace and it used to have no failure path:
// a document that did not carry the policy came back unchanged, so a build that
// says it denies the network shipped the policy that permits it.
console.log("");
console.log("the offline tier refuses a document it cannot make offline");
var NOPOLICY = '<!doctype html><html><head></head>';
N.tiers = "default,offline";
var refusedNoPolicy = false;
try { N.applyContentPolicy(NOPOLICY); } catch (e) { refusedNoPolicy = true; }
eq("a document with no policy to replace is refused", refusedNoPolicy, true);
eq("and one that has it is still swapped",
   policyOf(N.applyContentPolicy(html)), N.offlineContentPolicy);
N.tiers = "default";
// The boundary: the default tier has nothing to swap and must not start caring.
eq("the default tier still passes a policy-less document through",
   N.applyContentPolicy(NOPOLICY), NOPOLICY);

// The half of the offline tier a content policy cannot express. `openExternal`
// hands a url to the machine's browser, which is the page reaching the network
// in another program; it was measured going out that way on all four engines
// before this, by the API call and by a navigation gjs and Qt refuse and then
// forward. Asserted here as well as end to end because this runs on every push
// with no display behind it, and because both halves matter: the tier has to
// close it, and the default tier has to still open a link.
console.log("");
console.log("the offline tier closes the route a content policy cannot see");
// Asked before it is called, because a build without it makes every line below
// a TypeError -- which is a failure, and an unreadable one. Run against the
// commit before this PR it reads exactly this way and nothing else breaks.
eq("the build has a mayOpenExternal at all", typeof N.mayOpenExternal, "function");
function may(url) {
    if (typeof N.mayOpenExternal !== "function") return "<no mayOpenExternal>";
    return N.mayOpenExternal(url);
}
eq("the default tier opens an external url", may("https://example.com/x"), true);
N.tiers = "default,offline";
eq("the offline tier does not", may("https://example.com/x"), false);
eq("and the message never becomes an action",
   N.parseMessage("openExternal" + S + "https://example.com/x"), null);
eq("the scheme allowlist is unchanged by the tier",
   N.isExternalUrl("https://example.com/x"), true);
eq("a scheme outside the allowlist is refused in the offline tier",
   may("file:///etc/passwd"), false);
N.tiers = "default";
eq("and in the default tier, which is the half that was already true",
   may("file:///etc/passwd"), false);

if (failures > 0) {
    console.log("");
    console.log(failures + " assertion(s) failed");
    process.exit(1);
}
console.log("");
console.log("splitter assertions passed");
JSEOF

cd "$WORK" && node assert.js "$TARGET"
