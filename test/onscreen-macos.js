// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// onscreen-macos.js - what is on this screen, and who owns it.
//
// The x11 verifiers have had this since the round that named the three stray
// windows sitting over their captures; the macOS lane has never had it, and so
// every account of what is in a macOS picture has been written by looking at
// the picture. That is fine once and useless in a matrix.
//
// One line per on-screen window: owner, pid, layer, window number, geometry and
// the title if there is one. Run as
//
//     osascript -l JavaScript test/onscreen-macos.js
//
// which is the same interpreter and the same ObjC bridge the app itself is
// built on, so a lane that can run the app can run this.
function run() {
    try {
        ObjC.import('CoreGraphics');
    } catch (e) {
        return 'unreadable: CoreGraphics did not import: ' + e;
    }

    var wins;
    try {
        // 1 is kCGWindowListOptionOnScreenOnly, 16 is
        // kCGWindowListExcludeDesktopElements, 0 is kCGNullWindowID. Spelled as
        // numbers on purpose: the bridge exports this framework's functions and
        // not its enumerations, and a missing constant reads as undefined, which
        // ors to zero and quietly asks for every window that ever existed.
        wins = ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(1 | 16, 0));
    } catch (e) {
        return 'unreadable: the window list threw: ' + e;
    }

    if (!wins) { return 'unreadable: the window list came back nil'; }
    if (!wins.length) {
        // Not "nothing is on screen". Measured: this came back empty on every
        // shot of a run whose pictures show the app window, the Dock, the menu
        // bar and two system dialogs. Since macOS 14 the window list is
        // filtered to the caller's own windows unless the caller holds the
        // screen recording permission, and osascript here holds none -- the
        // grant on this runner belongs to the agent that spawns the shell.
        // So an empty list is a statement about this process, not the desktop.
        return 'no windows this process is allowed to see';
    }

    var lines = [];
    for (var i = 0; i < wins.length; i++) {
        var w = wins[i];
        var b = w.kCGWindowBounds || {};
        var n = function (v) { return Math.round(v || 0); };
        // The title comes last because it is the part most likely to be empty:
        // window names need the screen recording permission, and a lane that
        // has it for `screencapture` may still be reading this from a process
        // that does not.
        lines.push(
            (w.kCGWindowOwnerName || '?') +
            ' pid=' + (w.kCGWindowOwnerPID === undefined ? '?' : w.kCGWindowOwnerPID) +
            ' layer=' + (w.kCGWindowLayer === undefined ? '?' : w.kCGWindowLayer) +
            ' num=' + (w.kCGWindowNumber === undefined ? '?' : w.kCGWindowNumber) +
            ' ' + n(b.Width) + 'x' + n(b.Height) + '+' + n(b.X) + '+' + n(b.Y) +
            (w.kCGWindowName ? ' "' + w.kCGWindowName + '"' : '')
        );
    }
    return lines.join('\n');
}
