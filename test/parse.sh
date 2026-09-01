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
# The object is lifted out of an artifact itself rather than copied, so these
# assertions cannot pass against a stale duplicate of the code that ships.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Named on the command line by every caller in CI, which is what makes this the
# assertion on the thing that shipped rather than on the source it came from.
# With no argument it assembles the launcher and asserts against that, which is
# the useful default while working in neutrino/ -- there is no file in the tree
# to fall back to any more.
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    TARGET="$WORK/template.cmd"
    bash "$ROOT/neutrino/assemble.sh" > "$TARGET"
fi
# Resolved before anything changes directory, because the assertions run from a
# work directory and a relative path would quietly stop meaning the same file.
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

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

# The document opens its own body, and it opens it exactly once.
#
# It used to have to be one physical line, because the style and the body were
# spliced into it whole and a newline anywhere in there put the body below the
# cut -- silently, since the halves still split and the policy was still in the
# head. They are ordinary `@@include`d parts now and the document is a region
# rather than a line, which is why an app's stylesheet can be a stylesheet. What
# still has to hold is the order: doctype, then the style element, then the tag
# that opens the body, all of them above the seam the halves are cut on.
if [ "$(grep -c '^<!doctype html><html>' "$TARGET")" != "1" ]; then
    echo "parse.sh: the document does not open exactly once" >&2
    exit 1
fi
DOC_BODY="$(grep -n '^</style></head><body>$' "$TARGET" | head -1 | cut -d: -f1)"
if [ -z "$DOC_BODY" ] || [ "$DOC_BODY" -lt "$DOC_LINE" ] || [ "$DOC_BODY" -gt "$DOC_TAG" ]; then
    echo "parse.sh: the document does not open its own body between its doctype and its script" >&2
    echo "          doctype at line ${DOC_LINE:-none}, </style></head><body> at ${DOC_BODY:-none}," >&2
    echo "          script tag at ${DOC_TAG:-none}" >&2
    exit 1
fi
echo "  PASS: the document opens the body the app's markup is included into"

# The names jsc.exe will not let an app use.
#
# node parses this file and so does every engine but one. JScript.NET is typed,
# and its reserved words include the CLR's type aliases -- `short`, `int`,
# `long`, `char`, `float`, `boolean` and the rest -- so an app declaring `var
# short` is valid JavaScript everywhere, parses here, and fails to compile on
# the one platform that compiles it. What that looks like from outside is a
# Windows lane whose app never opens a window, four minutes of a verifier
# waiting for one, and no statement anywhere about why.
#
# Measured, at the cost of a round: `var short = ...` in a probe app took the
# windows-content lane down and said only "no window from 'neutrinostdwin'
# within 240s".
#
# Declarations only. Property access is a separate hazard with a separate
# answer -- the launcher quotes "close" for it and says why beside the line --
# and widening this to every occurrence of these words would refuse the prose
# that explains them, which is how the sentinel census went red on its own
# first run.
NT_JSC_RESERVED='abstract|boolean|byte|char|class|const|debugger|decimal|double'
NT_JSC_RESERVED="$NT_JSC_RESERVED|enum|export|extends|final|float|goto|implements"
NT_JSC_RESERVED="$NT_JSC_RESERVED|import|int|interface|internal|long|native|package"
NT_JSC_RESERVED="$NT_JSC_RESERVED|private|protected|public|sbyte|short|static|super"
NT_JSC_RESERVED="$NT_JSC_RESERVED|synchronized|throws|transient|uint|ulong|ushort|volatile"

# The whole JavaScript region, and not the app's part of it.
#
# This used to cut the app out from between a pair of `//#` markers, because the
# app was spliced in and the markers were where it landed. Nothing is spliced
# and there are no markers, and it turns out the narrower question was the wrong
# one anyway: jsc.exe compiles this whole region, so a declaration the launcher
# grew would fail exactly the same way and this would not have seen it. The
# launcher declares none today, which is what makes widening it free.
sed -n '/^<script type=text\/javascript>/,$p' "$TARGET" > "$WORK/app.js"
NT_BAD="$(grep -nE "\b(var|function)[[:space:]]+($NT_JSC_RESERVED)\b" "$WORK/app.js" || true)"
if [ -n "$NT_BAD" ]; then
    echo "parse.sh: the javascript declares a name jsc.exe reserves" >&2
    printf '%s\n' "$NT_BAD" | sed 's/^/          /' >&2
    echo "          valid JavaScript everywhere else; on Windows it will not compile" >&2
    echo "          and the lane reports only that no window ever appeared" >&2
    exit 1
fi
echo "  PASS: nothing in the javascript declares a name jsc.exe reserves"

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

# And the other half of the polyglot, which had no check at all until a round
# where three lanes went red for one line of it.
#
# The file is a shell script as much as it is JavaScript, and the two hazards
# are not the same hazard. The QML region is a here-document opened *unquoted*
# -- it has to be, because the QML reads $qml_url out of this shell -- so a
# backtick pair anywhere in it is a command substitution the shell runs at
# launch. Five of them sat in QML comments for months, each running a word and
# writing "command not found" to stderr, harmless. Then a comment quoted an
# anchor tag with a target: the shell read "<a" and a trailing ">" as
# redirections, and the artifact stopped parsing as a shell script at all. gjs
# and windows-launch could not run the built .cmd, kde came up with no window,
# and not one of the three failures was in the lane the comment was about.
#
# This is a shape and it is checked as one, the way the @cc_on block above is.
# Asking a parser instead was the first attempt and it does not travel: on the
# same corrupted file `sh -n` exits 2 where /bin/sh is dash and 0 where it is
# bash, so the check would have been real on the Linux runners and decorative
# on macOS. A rule about the file is true on every runner at once.
QML_BEGIN='    cat >&8 <<QMLEOF'
QML_BODY="$(awk -v b="$QML_BEGIN" 'index($0, b) { on = 1; next } on && /^QMLEOF$/ { exit } on' "$TARGET")"
# The region has to have been found, or this passes by matching nothing -- the
# same way a probe passes forever once the verb it attacked is deleted.
if [ "$(printf '%s\n' "$QML_BODY" | wc -l)" -lt 50 ]; then
    echo "parse.sh: the QML here-document was not found or is too short to be it" >&2
    echo "          (the opener this looks for is: $QML_BEGIN)" >&2
    exit 1
fi
if printf '%s' "$QML_BODY" | grep -q '`'; then
    echo "parse.sh: a backtick in the QML here-document" >&2
    printf '%s' "$QML_BODY" | grep -n '`' | sed 's/^/          /' >&2
    echo "          That here-document is unquoted, so the shell runs what is" >&2
    echo "          between backticks -- in a comment as much as anywhere else." >&2
    exit 1
fi
echo "  PASS: nothing in the QML here-document is a command the shell would run"

# And the parser, kept beside the shape because it catches everything else a
# shell region can get wrong. It is allowed to be weak: where /bin/sh is bash it
# will not see the defect above, which is the whole reason that one is a shape
# check. Not a control on this, because the thing a control would prove is
# already proven by the line above it running everywhere.
if command -v sh >/dev/null 2>&1; then
    if ! sh -n "$TARGET" 2>"$WORK/shell.err"; then
        echo "parse.sh: the polyglot does not parse as a shell script" >&2
        sed 's/^/          /' "$WORK/shell.err" >&2
        exit 1
    fi
    echo "  PASS: the whole file still parses as a shell script"
fi

# The whole object: the literal that carries the two stamps, and the hundred and
# twelve members assigned onto it after it. The range ends at the call that
# starts the launcher, and that line is dropped rather than kept -- node is
# being asked for the object, not for a window.
#
# The end anchor used to be the first line reading `    };`, back when the
# object was one literal. The app is spliced into runWeb() and is inside this
# range, so any app that closed an object literal at that indent ended the lift
# early and what came out was the launcher cut in half. `NeutrinoWebview.run();`
# is not a line an app writes by accident, which is the same check with a
# stronger anchor rather than a rule the author has to remember.
sed -n '/^    var NeutrinoWebview = {/,/^    NeutrinoWebview\.run();$/p' "$TARGET" |
    sed '$d' > "$WORK/obj.js"
echo "module.exports = NeutrinoWebview;" >> "$WORK/obj.js"

if [ ! -s "$WORK/obj.js" ]; then
    echo "parse.sh: could not lift NeutrinoWebview out of $TARGET" >&2
    exit 1
fi

# Without this the failure is node reporting "Unexpected end of input" against a
# line number in a temporary directory, which names neither the app nor the
# reason. Measured on the old anchor: adding one `    };` line to
# test/neutrinotest.js produced exactly that and nothing else.
if command -v node >/dev/null 2>&1 && ! node --check "$WORK/obj.js" >/dev/null 2>&1; then
    echo "parse.sh: the lifted NeutrinoWebview does not parse" >&2
    echo "          the lift runs from 'var NeutrinoWebview = {' to the" >&2
    echo "          'NeutrinoWebview.run();' that follows it; an app carrying" >&2
    echo "          either of those lines ends it somewhere else" >&2
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
N.config.tiers = "default";

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
eq("separator in a url", N.parseMessage("openExternal" + S + "https://a" + S + "https://b"), null);

console.log("malformed records are dropped, not repaired");
eq("close with a payload", N.parseMessage("close" + S + "x"), null);
eq("resize missing a field", N.parseMessage("resize" + S + "1"), null);
eq("resize with an extra field", N.parseMessage("resize" + S + "1" + S + "2" + S + "3"), null);
eq("resize with code in a field",
   N.parseMessage("resize" + S + "1;GLib.spawn_command_line_sync('x')" + S + "2"), null);
eq("resize to zero", N.parseMessage("resize" + S + "0" + S + "0"), null);
eq("resize to negative", N.parseMessage("resize" + S + "-5" + S + "-5"), null);

// The relative pair carries deltas, so the rule that refuses a zero or negative
// *size* must not be the rule applied to them. Shrinking by forty is a request;
// what keeps the result above zero is the clamp where the current size is
// known, and that is not here.
eq("resizeBy", N.parseMessage("resizeBy" + S + "40" + S + "-20"),
   { action: "resizeBy", width: 40, height: -20 });
eq("moveBy", N.parseMessage("moveBy" + S + "-10" + S + "30"),
   { action: "moveBy", x: -10, y: 30 });
eq("resizeBy of nothing is still a record", N.parseMessage("resizeBy" + S + "0" + S + "0"),
   { action: "resizeBy", width: 0, height: 0 });
eq("resizeBy missing a field", N.parseMessage("resizeBy" + S + "1"), null);
eq("moveBy with an extra field", N.parseMessage("moveBy" + S + "1" + S + "2" + S + "3"), null);
eq("resizeBy with code in a field",
   N.parseMessage("resizeBy" + S + "1;GLib.spawn_command_line_sync('x')" + S + "2"), null);
eq("an action nobody implements", N.parseMessage("evalThis" + S + "whatever"), null);
eq("a record nobody sends any more", N.parseMessage("setTitle" + S + "Hello World"), null);
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

// What a document's title is allowed to do to the name of the window it is in.
// Five lanes connect five different engine signals to this one gate, and node
// is the only place it can be asked anything without an engine underneath it.
console.log("a document names the window it is in, within limits");
eq("the app's own document names the window",
   withView("about:blank").acceptDocumentTitle("about:blank", "My App"), "My App");
// Two lanes read the title on a clock that starts before the document commits.
// Silence there, not a refusal: a note on every launch saying the app was
// refused its own window is a build that looks broken and is not.
eq("nothing committed yet is silence",
   withView().acceptDocumentTitle("about:blank", "My App"), null);
// The new spelling is a channel from the document to the native window, and
// the native window is the channel every verifier in this tree reads. A page
// that got itself loaded here would otherwise be filing the run's report.
eq("a document the view was not given names nothing",
   withView("about:blank").acceptDocumentTitle("https://example.com/", "Evil"), null);
// A document that never named itself. The window keeps the name the build gave
// it rather than losing it to markup that said nothing.
eq("an empty title is not a title",
   withView("about:blank").acceptDocumentTitle("about:blank", ""), null);
eq("and neither is a missing one",
   withView("about:blank").acceptDocumentTitle("about:blank", null), null);
// WebView2 documents DocumentTitle as falling back to the uri of the document,
// and this lane loads its document into a view whose uri is about:blank -- so
// the fallback is reachable and it is not a name anybody chose.
eq("the engine's fallback to the url is not a name",
   withView("about:blank").acceptDocumentTitle("about:blank", "about:blank"), null);
// And the fallback is not always the url the view reports. QtWebEngine answers
// `about:blank` for a document whose title the page had just emptied, on a view
// whose own url is the data: document Qt navigated to -- so the two spellings
// are separate rules and the second one shipped missing.
eq("the placeholder is not a name either",
   withView("data:text/html,neutrino")
       .acceptDocumentTitle("data:text/html,neutrino", "about:blank"), null);
// Asked separately from judging a title, because the two lanes that poll have
// to know it before they record what they read.
eq("nothing committed yet", withView().hasCommittedDocument(), false);
eq("a document committed", withView("about:blank").hasCommittedDocument(), true);
// Where the title is also the transport, a record and a title share one
// property. Refused on every lane rather than only that one, so that
// test/neutrinoattack.js's planted record reads the same everywhere.
eq("a record is never a title",
   withView("about:blank").acceptDocumentTitle("about:blank",
       "__NEUTRINO__resize"), null);
// The bounds parseMessage put on a title, for the reason it had them: this
// ends up in a window title that shell and PowerShell verifiers read line by
// line.
eq("a control character in a title",
   withView("about:blank").acceptDocumentTitle("about:blank", "a\nb"), null);
eq("a title larger than any real one",
   withView("about:blank").acceptDocumentTitle("about:blank",
       new Array(5000).join("x")), null);
N.trustedView = null;

// And the other half of the same answer: the build's name goes into the
// document, so the first title every engine reports is the one the window
// already has and nothing has to special-case the launch.
console.log("the build's name goes into the document it loads");
var bare = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>x</body></html>";
eq("a document that named nothing is named",
   N.titledDocument(bare, "My App").indexOf("<title>My App</title></head>") > 0, true);
// An author who wrote one meant it more recently than whoever wrote the title
// in config.json, and that is what <title> means everywhere else.
eq("a document that named itself keeps its name",
   N.titledDocument("<html><head><title>Mine</title></head><body></body></html>", "My App"),
   "<html><head><title>Mine</title></head><body></body></html>");
// The title arrives as a JSON string and JSON escapes what a JavaScript string
// literal escapes, so a quote or a backslash in it is already the author's
// problem and already solved. build.sh refused both, because it was stamping
// raw text into a literal. `<` and `&` were never that problem and they are
// this one's.
eq("the name is escaped for markup",
   N.titledDocument(bare, "a<b&c").indexOf("<title>a&lt;b&amp;c</title>") > 0, true);
eq("a document with no head keeps whatever it has",
   N.titledDocument("<body>x</body>", "My App"), "<body>x</body>");

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
// The engine's own `open`, so the target rule below can be read from both
// sides: what the wire got, and what was left for the engine. A plain object
// with nothing on it would make "did not intercept" and "intercepted and threw"
// the same reading, because the override calls through inside a try.
var enginesOpen = [];
var sandbox = {
    window: { open: function (u, t) { enginesOpen.push(String(u) + "|" + String(t)); return "ENGINE"; } },
    String: String, JSON: JSON, __t: function (m) { sent.push(m); }
};
vm.createContext(sandbox);
new vm.Script(N.buildPreloadScript("__t")).runInContext(sandbox);
// The standard spellings, driven the way an app now writes them. The preload
// assigns these onto `window` itself, so the sandbox's plain object receives
// them exactly as an engine's global would.
sandbox.window.resizeTo(500, 400);
sandbox.window.resizeBy(40, -20);
sandbox.window.moveTo(0, 0);
sandbox.window.moveBy(-10, 30);
sandbox.window.close();
eq("resizeTo round trip", N.parseMessage(sent[0]), { action: "resize", width: 500, height: 400 });
eq("resizeBy round trip", N.parseMessage(sent[1]), { action: "resizeBy", width: 40, height: -20 });
eq("moveTo round trip", N.parseMessage(sent[2]), { action: "move", x: 0, y: 0 });
eq("moveBy round trip", N.parseMessage(sent[3]), { action: "moveBy", x: -10, y: 30 });
eq("close round trip", N.parseMessage(sent[4]), { action: "close" });

// `window.resizeTo` emits the record `neutrino.window.resize` used to emit,
// which is the whole claim this change makes: the same bytes, meeting the same
// host-side guard, under a name an app author already knows.
eq("the standard spelling is the same record", sent[0], "resize" + S + "500" + S + "400");

// And the names they replace are gone rather than aliased. Asserted here because
// this is the only place that can see the built preload without an engine, and
// because a wrapper left behind is a second way to do one thing that nobody
// would notice until it drifted.
//
// `shell.openExternal` was the last of them: `window.open` sends the record it
// used to send, so what is left is the object an app cannot get any other way.
eq("neutrino.window is gone", typeof sandbox.window.neutrino.window, "undefined");
eq("neutrino.shell is gone", typeof sandbox.window.neutrino.shell, "undefined");
eq("neutrino.send is gone", typeof sandbox.window.neutrino.send, "undefined");
eq("and what is left is the palette and the channel's name",
   Object.keys(sandbox.window.neutrino).sort().join(","), "_theme,theme,transport");

console.log("");
console.log("window.open routes on the url, not on the target");
// Measured on WebKitGTK before any of this was written: `open` with no target,
// with `_blank` and with a name all returned null having reached no guard in
// the launcher at all -- the engine raises its `create` signal for those and
// nothing is connected to it. `_self` returned the window, navigated, and was
// refused and forwarded by the navigation guard like any other location change.
//
// What this file now steps in front of is one case: a url bound for the
// machine's browser. Everything else is handed to the engine as it arrived, and
// that is not politeness -- the engine's own new-window signal is the only
// thing that can ever hand a page a real WindowProxy, so an override that
// answered every call would put the second window out of reach rather than
// merely leaving it unbuilt.
var nOpen = sent.length;
eq("an external url goes out", sandbox.window.open("https://example.com/a"), null);
eq("and it is the openExternal record",
   N.parseMessage(sent[nOpen]), { action: "openExternal", url: "https://example.com/a" });
eq("the target does not change that", sandbox.window.open("https://example.com/b", "_blank"), null);
eq("nor does a name", sandbox.window.open("https://example.com/c", "ntwin"), null);
eq("mailto is external too", sandbox.window.open("mailto:a@b.example", "_blank"), null);
eq("four records for four external urls", sent.length - nOpen, 4);
eq("and the engine was never asked for any of them", enginesOpen.length, 0);

// Everything the launcher does not route. The engine gets the call with the
// arguments it was given, and nothing reaches the wire -- this is the path the
// second window will arrive on.
var nEng = sent.length;
eq("a relative url is the engine's", sandbox.window.open("panel.html", "_blank"), "ENGINE");
eq("about:blank is the engine's", sandbox.window.open("about:blank", "_blank"), "ENGINE");
eq("and so is a scheme this file never sends out",
   sandbox.window.open("ftp://example.com/x", "_blank"), "ENGINE");
eq("none of them is a record", sent.length - nEng, 0);
eq("the engine got the url and the target it was given",
   enginesOpen[0], "panel.html|_blank");

// The three targets that mean this window, checked before the url because they
// are not an opening at all. An external url here still reaches the browser --
// by the navigation guard, which is where a location change has always gone.
var nSelf = sent.length;
eq("_self goes to the engine", sandbox.window.open("https://example.com/d", "_self"), "ENGINE");
eq("_parent too", sandbox.window.open("https://example.com/e", "_parent"), "ENGINE");
eq("_top too", sandbox.window.open("https://example.com/f", "_top"), "ENGINE");
eq("and the match is case-insensitive",
   sandbox.window.open("https://example.com/g", "_SELF"), "ENGINE");
eq("none of them is a record either", sent.length - nSelf, 0);

// No url, no window, no record. The platform's answer is about:blank in a new
// window, which is the second-window case; until there is one to open this does
// nothing rather than sending the host an empty url to refuse.
var nNone = sent.length;
eq("open with no url is a no-op", sandbox.window.open(), null);
eq("and so is an empty one", sandbox.window.open(""), null);
eq("neither reaches the wire", sent.length - nNone, 0);
eq("and neither reaches the engine", enginesOpen.length, 7);

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

// What the native window needs before there is a document to read it from,
// plus the tier list, and nothing else. `url` sat here unread for the length of
// the project; a key nobody consumes is the shape this asserts against coming
// back -- and config.json is the app's own file, so a key it grows is a key
// that ships whether or not anything reads it.
eq("config carries only what createWindow needs, and the tiers",
   Object.keys(N.config).sort(),
   ["background", "decorations", "height", "tiers", "title", "width"]);
eq("the title is a non-empty string", typeof N.config.title === "string" && N.config.title.length > 0, true);
eq("the size is two positive whole numbers",
   [N.config.width > 0 && N.config.width === Math.floor(N.config.width),
    N.config.height > 0 && N.config.height === Math.floor(N.config.height)], [true, true]);

// The colour every lane paints its two pre-document surfaces with. Four of the
// five hand the string straight to a toolkit that parses it; the fifth builds
// an NSColor from components. This is the one reading they all come from, and a
// build whose background none of them can read is a window that comes up in the
// theme colour -- which is the shape this whole value exists to close.
//
// `auto` is the one value here that is not a colour, and it is what a build
// that named no background carries: the colour is not the app's, it is the
// desktop's, and resolveBackground reads it there.
//
// Two spellings and no third. This file is run against a built artifact as
// often as against the template, so it cannot assert *which* of the two is
// there -- that the template ships `auto` is assemble.sh's assertion, made
// against the template itself. What holds for every artifact is that the value
// is one this file's lanes can act on, and a config carrying anything else is
// five lanes painting white with nothing said.
eq("the background is a colour or it is `auto`",
   N.config.background === "auto" || N.parseColor(N.config.background) !== null, true);

// The frame, on the same terms as the colour above: two spellings and no third,
// asserted on the artifact rather than on which of the two the template ships.
//
// The predicate and not the string is what the five lanes ask, so the predicate
// is what this asserts against. A build carrying a third word would leave
// `undecorated` answering false for it -- a window that quietly kept its frame
// after config.json asked for it to go, which is the value failing silently and
// is the reason assemble.sh refuses the word rather than passing it through.
eq("the decorations are `auto` or `none`",
   N.config.decorations === "auto" || N.config.decorations === "none", true);
eq("and `undecorated` follows the value, both ways", [
    (function () { var was = N.config.decorations; N.config.decorations = "none";
                   var r = N.undecorated(); N.config.decorations = was; return r; })(),
    (function () { var was = N.config.decorations; N.config.decorations = "auto";
                   var r = N.undecorated(); N.config.decorations = was; return r; })()
], [true, false]);
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

// The desktop's palette, and the rules five lanes share so that one reading
// cannot disagree with another. All of it is pure -- no window, no toolkit, no
// display -- which is why it is asserted here rather than only on a runner.
console.log("");
console.log("the desktop is dark when it takes light text better than dark");
// The crossing is near 0.179 and is computed rather than written down, so
// these pin the answer either side of it and at the two ends. #808080 is the
// one a fixed 0.5 threshold would have called dark.
var surfaces = [
    ["#ffffff", false], ["#f6f5f4", false], ["#808080", false],
    ["#767676", false], ["#747474", true],
    ["#404040", true], ["#383838", true], ["#000000", true]
];
for (var s = 0; s < surfaces.length; s++) {
    eq("isDarkSurface " + surfaces[s][0],
       N.isDarkSurface(N.parseColor(surfaces[s][0])), surfaces[s][1]);
}
// The reading this desk was measured at: Mint-L-Dark's theme_bg_color is
// rgb(56,56,56), which is dark, while gtk-application-prefer-dark-theme reads
// False on the same machine. Asserted to the measured luminance so that a
// change to the curve is a failure and not a silently different answer.
eq("the measured GTK dark background is 0.0395",
   Math.round(N.relativeLuminance(N.parseColor("#383838")) * 10000) / 10000, 0.0395);

console.log("");
console.log("a colour comes back one spelling however the toolkit spelled it");
eq("toHex pads and lowercases", N.toHex(N.parseColor("#0A0B0C")), "#0a0b0c");
eq("toHex expands the short form", N.toHex(N.parseColor("#fff")), "#ffffff");
eq("toHex clamps above one", N.toHex({ red: 2, green: 1, blue: 0 }), "#ffff00");
eq("toHex clamps below zero", N.toHex({ red: -1, green: 0, blue: 0.5 }), "#000080");

console.log("");
console.log("alpha is flattened over the surface behind it, not over white");
// GTK hands over rgba(218,218,218,0.5) for insensitive text and macOS spells
// separatorColor the same way. Flattened against white on a dark desktop this
// would be the one thing the whole feature exists not to do.
eq("half over black", N.flattenColor("#ffffff", 0.5, "#000000"), "#808080");
eq("half over the measured dark background",
   N.flattenColor("#dadada", 0.5, "#383838"), "#898989");
eq("opaque ignores the surface", N.flattenColor("#123456", 1, "#000000"), "#123456");
eq("no surface to flatten against keeps the colour",
   N.flattenColor("#123456", 0.5, "not a colour"), "#123456");
eq("an alpha outside the range is treated as opaque",
   N.flattenColor("#123456", 7, "#000000"), "#123456");
eq("a colour nobody can parse is refused", N.flattenColor("nope", 1, "#000000"), null);

// A palette a lane could actually return, and the shape everything downstream
// reads. Built from the values measured on this desk under Mint-L-Dark.
function rawTheme(overrides) {
    var raw = {
        source: "gtk",
        background: "#383838", foreground: "#dadada",
        base: "#404040", text: "#dadada",
        accent: "#8fa876", accentText: "#ffffff",
        border: "#292929"
    };
    for (var k in overrides) { raw[k] = overrides[k]; }
    return raw;
}

console.log("");
console.log("a palette is taken whole or not at all");
var theme = N.normalizeTheme(rawTheme());
eq("the measured GTK palette normalizes", theme, {
    scheme: "dark",
    source: "gtk",
    colors: {
        background: "#383838", foreground: "#dadada",
        base: "#404040", text: "#dadada",
        accent: "#8fa876", accentText: "#ffffff",
        border: "#292929"
    }
});
eq("the scheme is derived, never reported by the lane",
   N.normalizeTheme(rawTheme({ scheme: "light" })).scheme, "dark");
eq("a light background makes a light scheme",
   N.normalizeTheme(rawTheme({ background: "#f6f5f4" })).scheme, "light");
eq("the short form is accepted and expanded",
   N.normalizeTheme(rawTheme({ accent: "#f0a" })).colors.accent, "#ff00aa");
// Whole, and this is the assertion that matters: a palette with one bad value
// is refused rather than repaired, because an app would style itself from a
// repaired one and have no way to tell.
var keys = N.themeKeyList();
for (var tk = 0; tk < keys.length; tk++) {
    var broken = {};
    broken[keys[tk]] = "rgb(1,2,3)";
    eq("a palette missing a readable " + keys[tk] + " is refused whole",
       N.normalizeTheme(rawTheme(broken)), null);
}
eq("and one with a key missing entirely",
   N.normalizeTheme({ source: "gtk", background: "#383838" }), null);
eq("a lane nobody has heard of is refused",
   N.normalizeTheme(rawTheme({ source: "elsewhere" })), null);
eq("and a palette with no lane at all", N.normalizeTheme(rawTheme({ source: "" })), null);
eq("nothing at all is refused rather than thrown", N.normalizeTheme(null), null);
eq("and a string is not a palette", N.normalizeTheme("#383838"), null);
eq("every lane this file has a reader for is accepted",
   ["gtk", "qt", "macos", "windows"].map(function (src) {
       return N.normalizeTheme(rawTheme({ source: src })) !== null;
   }), [true, true, true, true]);

console.log("");
console.log("the background a build named beats the one the desktop is using");
var savedConfigBackground = N.config.background;
N.config.background = "#12141a";
eq("a named colour is not overridden by the desktop", N.resolveBackground(theme), "#12141a");
eq("and the build does not follow the desktop at all", N.followsTheme(), false);
N.config.background = "auto";
eq("`auto` follows the desktop", N.followsTheme(), true);
// base and not background: the view is nearly the whole window, and an app
// following the desktop paints its body like a content surface.
eq("`auto` borrows the content surface", N.resolveBackground(theme), "#404040");
eq("and falls back to white when no lane could read a palette",
   N.resolveBackground(null), "#ffffff");
eq("as it does for a palette with no colours in it",
   N.resolveBackground({ scheme: "dark", source: "gtk", colors: {} }), "#ffffff");
N.config.background = savedConfigBackground;

console.log("");
console.log("an update that changes nothing is not an update");
// Load-bearing rather than tidy: painting a GTK window adds a CssProvider to
// it, which emits the style-updated the watcher listens on. Without this the
// watcher feeds itself for as long as the app is open.
eq("the same palette twice is not a change",
   N.themesDiffer(theme, N.normalizeTheme(rawTheme())), false);
eq("one colour different is", 
   N.themesDiffer(theme, N.normalizeTheme(rawTheme({ accent: "#000000" }))), true);
eq("a different scheme is",
   N.themesDiffer(theme, N.normalizeTheme(rawTheme({ background: "#f6f5f4" }))), true);
eq("a different lane is",
   N.themesDiffer(theme, N.normalizeTheme(rawTheme({ source: "qt" }))), true);
eq("having nothing yet is a change", N.themesDiffer(null, theme), true);
eq("and having nothing twice is not", N.themesDiffer(null, null), false);

console.log("");
console.log("the flag the two GTK lanes raise, and the one they never lower");
// The engine's `prefers-color-scheme` on WebKitGTK follows the theme's *name*
// -- the prefer-dark flag, or a name carrying the dark variant -- and not the
// palette, so a stock `Mint-Y-Dark-Grey` is dark on screen and light in the
// media query. Raising the flag is what closes that.
//
// Only ever raised. Setting it false under a name that already says dark left
// the query at dark: the engine's rule there is the flag OR the name, and the
// name cannot be argued with. So the answer is a single boolean and "leave it
// alone" is what false means, which is the shape asserted here.
eq("a dark palette raises it", N.gtkPreferDark(theme), true);
eq("a light one does not",
   N.gtkPreferDark(N.normalizeTheme(rawTheme({ background: "#f6f5f4" }))), false);
// The scheme and not the colour, because the luminance rule has already been
// applied by the time this is asked. A palette whose background is dark and
// whose scheme somehow said light would be a normalizeTheme defect, and this
// reading has to point at the one value every lane pushes to the page.
eq("it reads the scheme, not the background",
   N.gtkPreferDark({ scheme: "dark", source: "gtk", colors: { background: "#ffffff" } }), true);
eq("a lane that read no toolkit is left alone", N.gtkPreferDark(null), false);
eq("and so is a palette with no scheme at all",
   N.gtkPreferDark({ source: "gtk", colors: {} }), false);

console.log("");
console.log("the one string this file evaluates into a page");
// Every other direction is the page talking to the host. This is the host
// talking to the page, so it is held to parseMessage's rule coming the other
// way: a fixed shape, a known key set, and one anchored pattern per value.
var script = N.buildThemeScript(theme);
eq("the update is valid javascript", (function () {
    try { new Function(script); return true; } catch (_) { return false; }
})(), true);
eq("it carries the palette", script.indexOf('background:"#383838"') > 0, true);
eq("and calls only through the preload's own entry point",
   script.indexOf("window.neutrino._theme(") > 0, true);
// Nothing that is not six hex digits reaches a page as text. Built by hand
// rather than through normalizeTheme, because normalizeTheme is exactly what
// this is the second check on.
function forged(key, value) {
    var t = { scheme: "dark", source: "gtk", colors: {} };
    var ks = N.themeKeyList();
    for (var i = 0; i < ks.length; i++) { t.colors[ks[i]] = "#000000"; }
    if (key === "scheme" || key === "source") { t[key] = value; } else { t.colors[key] = value; }
    return t;
}
var forgeries = [
    ["accent", '#000"};alert(1);//'],
    ["accent", "#FFFFFF"],
    ["accent", "#fff"],
    ["accent", "white"],
    ["accent", ""],
    ["accent", null],
    ["background", "#00000"],
    ["scheme", "dark\";x=1"],
    ["scheme", "auto"],
    ["source", "gtk\";x=1"],
    ["source", "elsewhere"]
];
for (var f = 0; f < forgeries.length; f++) {
    eq("refuses " + forgeries[f][0] + " as " + JSON.stringify(forgeries[f][1]),
       N.buildThemeScript(forged(forgeries[f][0], forgeries[f][1])), null);
}
eq("and refuses nothing at all", N.buildThemeScript(null), null);

console.log("");
console.log("the page starts with the palette rather than waiting for it");
var preload = N.buildPreloadScript(
    'function(m){console.log("__NEUTRINO__"+m);}', "console", N.themeLiteral(theme));
eq("the preload is still valid javascript", (function () {
    try { new Function(preload); return true; } catch (_) { return false; }
})(), true);
// Run it against a stand-in window and read back what an app would see.
//
// And a stand-in document, because the palette has a second delivery now: the
// launch value rides in the document's own stylesheet and every later one is
// written through `documentElement.style.setProperty`. That second half is
// reachable from here, so it is asserted here rather than only on an engine.
var pageWindow = { addEventListener: function () {}, dispatchEvent: function (e) { this.last = e; } };
pageWindow.CustomEvent = function (type, init) { this.type = type; this.detail = init.detail; };
var pageProps = {};
var pageDoc = {
    documentElement: {
        style: { setProperty: function (name, value) { pageProps[name] = value; } }
    }
};
(new Function("window", "CustomEvent", "document", preload))(
    pageWindow, pageWindow.CustomEvent, pageDoc);
eq("an app reads the palette at document start", pageWindow.neutrino.theme, {
    scheme: "dark",
    source: "gtk",
    colors: {
        background: "#383838", foreground: "#dadada",
        base: "#404040", text: "#dadada",
        accent: "#8fa876", accentText: "#ffffff",
        border: "#292929"
    }
});
// A lane that could not read a palette still gets an API, and the app finds
// out by asking rather than by the property not being there.
var noThemeWindow = { addEventListener: function () {}, dispatchEvent: function () {} };
(new Function("window", N.buildPreloadScript(
    'function(m){}', "console", N.themeLiteral(null))))(noThemeWindow);
eq("a lane with no palette says so rather than inventing one",
   noThemeWindow.neutrino.theme, null);

console.log("");
console.log("a standing failure is reported once, not once a second");
// The Windows lane re-reads on a clock and the GTK lanes read on every
// style-updated, which fires rather more often than the theme changes. A
// toolkit that cannot be read is a standing condition, so an unlatched note
// would bury the app's own stderr under one repeated sentence.
var said = [];
var savedSink = N.noteSink;
var savedNoted = N.notedOnce;
N.notedOnce = null;
N.noteSink = function (m) { said.push(m); };
for (var n = 0; n < 5; n++) {
    N.noteOnce("this theme defines no theme_bg_color");
}
N.noteOnce("and a different thing entirely");
eq("five identical notes are said once", said.length, 2);
// "constructor" is the one that bites: an unprefixed key would find it truthy
// on Object.prototype and swallow the message.
N.noteOnce("constructor");
N.noteOnce("constructor");
eq("a message that names something on Object.prototype is still said", said.length, 3);
N.noteSink = savedSink;
N.notedOnce = savedNoted;

console.log("");
console.log("a change replaces the palette and says so");
(new Function("window", "CustomEvent", "document",
    N.buildThemeScript(N.normalizeTheme(rawTheme({ background: "#f6f5f4", base: "#ffffff" })))
))(pageWindow, pageWindow.CustomEvent, pageDoc);
eq("the event carries the new palette", pageWindow.last.type, "neutrino:themechange");
eq("with the scheme derived from it", pageWindow.last.detail.scheme, "light");
// Replaced and not mutated: an app that captured the old object keeps a stable
// snapshot, and one that reads window.neutrino.theme gets the current palette.
eq("and window.neutrino.theme is the new one", pageWindow.neutrino.theme.colors.base, "#ffffff");
eq("while the object captured before it is unchanged", theme.colors.base, "#404040");
eq("the palette is current before the event fires",
   pageWindow.last.detail === pageWindow.neutrino.theme, true);
// The other delivery, written through CSSOM by the same update. The names are
// the non-deprecated <system-color> keywords, so an author can infer the
// property from the keyword and write `var(--neutrino-Canvas, Canvas)` without
// looking anything up.
eq("the update writes the palette as custom properties too", pageProps, {
    "--neutrino-ButtonFace": "#f6f5f4",
    "--neutrino-ButtonText": "#dadada",
    "--neutrino-Canvas": "#ffffff",
    "--neutrino-CanvasText": "#dadada",
    "--neutrino-Highlight": "#8fa876",
    "--neutrino-HighlightText": "#ffffff",
    "--neutrino-ButtonBorder": "#292929"
});

console.log("");
console.log("and the launch palette rides in the document, not in a script");
// The launch is the half a document-start script cannot be trusted with: the
// values have to be there before the first paint, and whether there is an
// element to set them on at that moment is a per-engine answer this project
// has already been caught by once.
var CSSDOC = '<!doctype html><html><head>' +
             '<meta http-equiv="Content-Security-Policy" content="' + N.defaultContentPolicy + '">' +
             '<style>p{color:red}</style></head><body><p>x</p></body></html>';
var themed = N.themedDocument(CSSDOC, theme);
eq("the rule carries every key", N.themeCssText(theme),
   ":root{--neutrino-ButtonFace:#383838;--neutrino-ButtonText:#dadada;" +
   "--neutrino-Canvas:#404040;--neutrino-CanvasText:#dadada;" +
   "--neutrino-Highlight:#8fa876;--neutrino-HighlightText:#ffffff;" +
   "--neutrino-ButtonBorder:#292929}");
// After the policy, because a content policy governs what follows it and the
// launcher's own stylesheet has no business sitting outside the one the
// launcher wrote.
eq("it lands after the content policy",
   themed.indexOf("Content-Security-Policy") < themed.indexOf("--neutrino-Canvas"), true);
// Before the author's, because two :root rules of equal specificity are
// decided by which comes last, and overriding the desktop is the app's to do.
eq("and before the author's stylesheet",
   themed.indexOf("--neutrino-Canvas") < themed.indexOf("p{color:red}"), true);
eq("a lane that read no palette writes no rule", N.themeCssText(null), null);
eq("and its document comes back untouched", N.themedDocument(CSSDOC, null), CSSDOC);
// No stylesheet of its own is no author declarations to lose to, so the end of
// the head is enough.
var bare = '<!doctype html><html><head><meta charset="utf-8"></head><body>x</body></html>';
eq("a document with no stylesheet gets it at the end of the head",
   N.themedDocument(bare, theme).indexOf("</style></head>") > 0, true);
eq("a document with no head keeps what it has",
   N.themedDocument("<body>x</body>", theme), "<body>x</body>");
N.config.tiers = "default,offline";
eq("offline tier gets the offline policy", policyOf(N.applyContentPolicy(html)), N.offlineContentPolicy);
N.config.tiers = "default";
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
N.config.tiers = "default,offline";
var refusedNoPolicy = false;
try { N.applyContentPolicy(NOPOLICY); } catch (e) { refusedNoPolicy = true; }
eq("a document with no policy to replace is refused", refusedNoPolicy, true);
eq("and one that has it is still swapped",
   policyOf(N.applyContentPolicy(html)), N.offlineContentPolicy);
N.config.tiers = "default";
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
N.config.tiers = "default,offline";
eq("the offline tier does not", may("https://example.com/x"), false);
eq("and the message never becomes an action",
   N.parseMessage("openExternal" + S + "https://example.com/x"), null);
eq("the scheme allowlist is unchanged by the tier",
   N.isExternalUrl("https://example.com/x"), true);
eq("a scheme outside the allowlist is refused in the offline tier",
   may("file:///etc/passwd"), false);
N.config.tiers = "default";
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
