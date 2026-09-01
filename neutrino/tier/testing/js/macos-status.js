    /*
     * The macOS status file, which is scaffolding: the verifiers read window
     * geometry out of it because a screenshot cannot report a frame origin.
     *
     * It used to be a method on the driver's window object that returned early
     * unless the build was stamped `testing`, so every release artifact carried
     * the geometry reader, the file write and the temporary path. It is a part
     * now and the release build's is empty, so a shipped app has no code in it
     * that writes a file beside itself.
     *
     * It takes the driver object rather than living on it, because an overlay
     * replaces a file and the driver is one file. `mac` is what `this` used to
     * be, and it is only ever asked for windowTitle and toTopLeftY.
     */
    NeutrinoWebview.writeMacStatus = function (mac, dollar, win) {
            try {
                var title = mac.windowTitle(win);
                var f = win.frame;
                var topLeftY = Math.round(mac.toTopLeftY(f.origin.y, f.size.height));
                var inner = "?x?";
                try {
                    var cv = win.contentView.frame;
                    inner = Math.round(cv.size.width) + "x" + Math.round(cv.size.height);
                } catch (_) {}
                /*
                 * Widened, not renumbered: this line carried the work
                 * area's size and now carries its top-left corner too.
                 * Appending to this file or widening a line is safe and
                 * inserting into it is not -- verify-std.sh reads the
                 * seven lines positionally as l1..l7, so a line added
                 * in the middle silently reassigns every one below it.
                 * Nothing reads l5 today, which is what makes this the
                 * cheap line to widen.
                 *
                 * The conversion is here and not in the verifier
                 * because toTopLeftY is here. `visibleFrame` is in
                 * AppKit's bottom-left coordinates and its *top* edge
                 * is what a window cannot be placed above -- the menu
                 * bar is the thing the fifty-pixel position tolerance
                 * in verify-macos.sh has been paying for. Deriving
                 * that in bash would be a second copy of a coordinate
                 * flip that already exists, and the two would be free
                 * to disagree.
                 */
                var work = "?x?";
                try {
                    var vf = dollar.NSScreen.mainScreen.visibleFrame;
                    work = Math.round(vf.size.width) + "x" + Math.round(vf.size.height) +
                        "+" + Math.round(vf.origin.x) +
                        "+" + Math.round(mac.toTopLeftY(vf.origin.y, vf.size.height));
                } catch (_) {}
                var windows = "?";
                try { windows = String(dollar.NSApp.windows.count); } catch (_) {}
                /*
                 * An eighth line, appended, which is the safe direction
                 * this file's own note above describes.
                 *
                 * `windowNumber` is the CGWindowID, and it is here so
                 * the verifier can tell when this window reaches the
                 * screen. The pictures are of the whole display -- the
                 * machine is the subject, consent sheet and all -- but
                 * a window has a number before it is composited, and
                 * `screencapture -l` on that number is the one call
                 * that fails until it is. So the shutter waits on it
                 * and then photographs the display: `00-initial` was an
                 * empty desktop until something on this side could say
                 * when the window had arrived.
                 *
                 * Scaffolding like the rest of writeStatus, behind the
                 * same tier gate, and read by nothing that asserts.
                 */
                var winNum = "?";
                try { winNum = String(win.windowNumber); } catch (_) {}
                this.macStatusTicks = (this.macStatusTicks || 0) + 1;
                var status = title + "\n" +
                    Math.round(f.size.width) + "x" + Math.round(f.size.height) + "\n" +
                    Math.round(f.origin.x) + "," + topLeftY + "\n" +
                    inner + "\n" +
                    work + "\n" +
                    windows + "\n" +
                    this.macStatusTicks + "\n" +
                    winNum;
                var statusPath = dollar.NSTemporaryDirectory().js + "neutrino-title.txt";
                dollar.NSString.alloc.initWithUTF8String(status)
                    .writeToFileAtomicallyEncodingError(statusPath, true, 4, null);
            } catch (_) {}
    };
