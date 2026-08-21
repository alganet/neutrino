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

console.log("the document carries a content policy");
var fs = require("fs");
var html = N.extractHtmlDocument(fs.readFileSync(process.argv[2], "utf8"));
function policyOf(doc) {
    var m = doc.match(/<meta http-equiv="Content-Security-Policy" content="([^"]*)"/);
    return m ? m[1] : null;
}
eq("the document starts at the doctype", html.toLowerCase().indexOf("<!doctype html"), 0);

eq("default tier gets the default policy", policyOf(html), N.defaultContentPolicy);
N.tiers = "default,offline";
eq("offline tier gets the offline policy", policyOf(N.applyContentPolicy(html)), N.offlineContentPolicy);
N.tiers = "default";
eq("default tier leaves the document alone", policyOf(N.applyContentPolicy(html)), N.defaultContentPolicy);

if (failures > 0) {
    console.log("");
    console.log(failures + " assertion(s) failed");
    process.exit(1);
}
console.log("");
console.log("splitter assertions passed");
JSEOF

cd "$WORK" && node assert.js "$TARGET"
