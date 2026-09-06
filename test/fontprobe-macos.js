// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// fontprobe-macos.js - what NSFont will tell a launcher about the desktop's
// fonts, and the one thing about the answer that a CSS delivery cannot use
// as it stands.
//
// PROBE. The macOS half of the round fontprobe-gtk.js opens.
//
// Usage: osascript -l JavaScript fontprobe-macos.js
//
// This is the lane with the *most* roles -- NSFont names a title bar font, a
// menu font, a message font, a palette font and a fixed-pitch font, where GTK
// needs three GSettings schemas to reach three of those and Windows has no
// spelling for monospace at all. So this lane decides the ceiling of the
// normalized set.
//
// It is also the lane with the trap. The system UI font's familyName is
// `.AppleSystemUIFont` -- a dot-prefixed hidden family that fontconfig-style
// name matching will not resolve and that WebKit deliberately refuses by name.
// A launcher that shipped it into `font-family` would deliver a family the
// engine ignores, silently, and fall through to the next entry in the list. The
// CSS spelling for that face is `system-ui` or `-apple-system`, so this lane
// needs a name *translation* that no other lane needs, and this probe's job is
// to say exactly which of the readings are dot-prefixed.
//
// The theme round's lesson applies here and is why setCurrentAppearance is
// called below: JXA has no drawing context, so anything resolved against the
// current appearance answers under Aqua unless the appearance is set first.
// Font sizes are not appearance-dependent the way colours are, but the accessed
// font *is* resolved through the same machinery, so the read is done under a
// known appearance rather than under nil.

ObjC.import("Cocoa");

// console.log, which under osascript writes to stderr, and which is what
// else/note.js already uses on this lane for exactly this reason.
//
// The first draft built the line through
// `$.NSFileHandle.fileHandleWithStandardError.writeData($.NSString.alloc...)`
// and it printed nothing at all on the runner: `$.NSUTF8StringEncoding` is not
// defined under a bare `ObjC.import("Cocoa")`, so dataUsingEncoding returned
// nil, writeData raised, and the whole probe died on its first line. It went
// unattributed for a round because fontflip.sh piped the probe through
// `grep '^FONTPROBE'` and the exception went out with everything else that did
// not match -- which is why that harness now shows the output when no FONTPROBE
// line appeared. A lane's own idiom would have avoided both.
function say(s) { console.log("FONTPROBE " + s); }

function appearance() {
    try {
        var style = $.NSUserDefaults.standardUserDefaults.stringForKey("AppleInterfaceStyle");
        var wantsDark = String(ObjC.unwrap(style) || "").indexOf("Dark") === 0;
        var a = $.NSAppearance.appearanceNamed(
            wantsDark ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua");
        // The setter called and not the property assigned -- JXA does not route
        // an assignment to a class property to the class setter, which the
        // theme round measured at the cost of a whole live-watcher round.
        if (a) { $.NSAppearance.setCurrentAppearance(a); }
        return wantsDark ? "DarkAqua" : "Aqua";
    } catch (e) { return "<threw:" + e + ">"; }
}

// One font, taken apart. `fontName` is the PostScript name and `familyName` is
// the one CSS would want; both are reported because on the system faces they
// differ in a way that matters (`.AppleSystemUIFont` against `.SFNS-Regular`).
function describe(font) {
    if (!font) { return "<nil>"; }
    try {
        var family = String(ObjC.unwrap(font.familyName));
        var name = String(ObjC.unwrap(font.fontName));
        var display = "";
        try { display = String(ObjC.unwrap(font.displayName) || ""); } catch (_) {}
        // The weight, from NSFontManager rather than from the descriptor's
        // traits dictionary.
        //
        // `fontDescriptor.objectForKey(NSFontTraitsAttribute)` was the first
        // spelling and it answered `absent` for all thirteen roles on the
        // runner -- a system font's descriptor carries no traits dictionary
        // until one is asked for explicitly. `weightOfFont:` is the API that
        // always answers, on AppKit's own 0..15 scale where 5 is regular and 9
        // is bold; the mapping to CSS 100..900 is a decision and this file does
        // not make decisions.
        //
        // It matters for exactly one role. Every hidden face below reports the
        // same family, and `titleBar` is distinguished from `system` only by
        // its PostScript name -- .AppleSystemUIFaceHeadline against
        // .AppleSystemUIFont -- so a titlebar role that carried family and size
        // alone would deliver a regular face where the desktop draws a bold
        // one.
        var weight = "?";
        try {
            weight = String($.NSFontManager.sharedFontManager.weightOfFont(font));
        } catch (_) { weight = "<threw>"; }
        var traits = "?";
        try {
            traits = String(font.fontDescriptor.symbolicTraits);
        } catch (_) { traits = "<threw>"; }
        return "family=" + JSON.stringify(family) +
            " postscript=" + JSON.stringify(name) +
            " display=" + JSON.stringify(display) +
            " pointSize=" + font.pointSize +
            " weight=" + weight + " symbolicTraits=" + traits +
            // The whole reason this probe exists in this shape.
            " hidden=" + (family.charAt(0) === "." ? "YES" : "no");
    } catch (e) { return "<threw:" + e + ">"; }
}

function tryFont(label, fn) {
    try { say("  " + label + " " + describe(fn())); }
    catch (e) { say("  " + label + " <threw:" + e + ">"); }
}

say("start appearance=" + appearance());

// The sizes first, because three of the roles below are only distinguishable by
// theirs -- macOS gives the small system font and the system font the same face
// and different sizes, which is the exact shape of the `small` role.
try {
    say("sizes system=" + $.NSFont.systemFontSize +
        " smallSystem=" + $.NSFont.smallSystemFontSize +
        " label=" + $.NSFont.labelFontSize);
} catch (e) { say("sizes <threw:" + e + ">"); }

// Every role NSFont names, asked with size 0, which means "the standard size
// for this role" rather than "a zero-point font".
tryFont("system        ", function () { return $.NSFont.systemFontOfSize(0); });
tryFont("boldSystem    ", function () { return $.NSFont.boldSystemFontOfSize(0); });
tryFont("smallSystem   ", function () { return $.NSFont.systemFontOfSize($.NSFont.smallSystemFontSize); });
tryFont("user          ", function () { return $.NSFont.userFontOfSize(0); });
tryFont("userFixedPitch", function () { return $.NSFont.userFixedPitchFontOfSize(0); });
tryFont("message       ", function () { return $.NSFont.messageFontOfSize(0); });
tryFont("titleBar      ", function () { return $.NSFont.titleBarFontOfSize(0); });
tryFont("menu          ", function () { return $.NSFont.menuFontOfSize(0); });
tryFont("menuBar       ", function () { return $.NSFont.menuBarFontOfSize(0); });
tryFont("label         ", function () { return $.NSFont.labelFontOfSize(0); });
tryFont("palette       ", function () { return $.NSFont.paletteFontOfSize(0); });
tryFont("toolTips      ", function () { return $.NSFont.toolTipsFontOfSize(0); });
tryFont("controlContent", function () { return $.NSFont.controlContentFontOfSize(0); });

// Whether the hidden family has a name the engine will take. `-apple-system`
// and `system-ui` are CSS tokens rather than families, so nothing here can
// confirm they render -- that is the page probe's half. What this can say is
// whether NSFont itself will resolve the two spellings a launcher might be
// tempted to ship.
try {
    var byName = $.NSFont.fontWithNameSize(".AppleSystemUIFont", 13);
    say("fontWithName('.AppleSystemUIFont') = " + describe(byName));
} catch (e) { say("fontWithName('.AppleSystemUIFont') <threw:" + e + ">"); }
try {
    var helv = $.NSFont.fontWithNameSize("Helvetica", 13);
    say("fontWithName('Helvetica') control = " + describe(helv));
} catch (e) { say("fontWithName('Helvetica') <threw:" + e + ">"); }

// And the live question, which this lane is expected to answer "nothing".
//
// There is no documented NSNotification for a UI font change, and the setting
// that would cause one -- the accessibility text size -- is not a knob a
// runner has. So this reports the notification names worth *trying* rather
// than pretending to have tested them, and the round after this decides
// whether the Windows answer (re-read on the tick the theme watcher already
// runs) is the honest one for macOS too.
say("live: no NSNotification tried; candidates are " +
    "NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification and " +
    "the distributed AppleInterfaceThemeChangedNotification the palette uses");

say("done");
