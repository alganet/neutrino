    /*
     * The Windows fonts, and the one lane where a role is delivered by
     * saying the platform has no answer for it.
     *
     * `System.Drawing.SystemFonts` is the read, and unlike SystemColors --
     * which the palette round found frozen at their classic light values
     * whatever the app theme says -- these are live: they come from
     * SPI_GETNONCLIENTMETRICS and follow the user's text size. So this
     * needs none of the registry work the palette's reader does.
     *
     * What it does need is a monospace role with nothing behind it.
     * Measured on the runner, `MessageBoxFont`, `CaptionFont`,
     * `SmallCaptionFont`, `MenuFont`, `StatusFont` and `IconTitleFont` were
     * all Segoe UI 9pt -- identical -- and there is no seventh that is a
     * fixed-pitch face. The console's `FaceName` is the nearest thing and
     * it is not one: it came back `__DefaultTTFont__`, a placeholder, and
     * it is a per-application preference of a different program that
     * nothing on the desktop reads. So `monospace` is left unanswered here
     * and normalizeFonts gives it the engine's own monospace at the
     * desktop's size, which is not an invention -- where filling it from
     * the UI font would ship a proportional face under a name that promises
     * fixed pitch.
     *
     * `document` is left unanswered for the same reason and takes `serif`,
     * which is that platform's own convention rather than this file's
     * choice; see fontDocumentGenerics.
     *
     * The three that do have an answer are read separately even though they
     * measured identical, because a user who changes the caption font moves
     * them apart -- and a lane that read one font three times would report
     * a desktop nobody is running. That is the reasoning theme-windows.js
     * gives for reading the accent pair in both schemes.
     *
     * They are named literally, and there was a comma-string walk here for
     * one round: this
     * file read them as `SystemFonts[name]`, which every runner refused with
     * `TypeError: Function expected`. JScript.NET does not treat a string
     * index on a CLR *type* as a property lookup -- it looks for a default
     * indexer, and a static class has none. theme-windows.js names its seven
     * colours literally for the same reason, and that is why it works.
     *
     * The reader said so itself, three times a launch, and that is the only
     * reason this cost one round rather than several: `noteOnce` named the
     * property and quoted the exception, so the log said what was wrong
     * rather than that something was.
     */
    NeutrinoWebview.readWindowsFonts = function (SystemRef) {
        var raw = { source: "windows", unit: "pt" };
        var found = 0;
        try {
            var system = SystemRef.Drawing.SystemFonts;
            found += this.takeWindowsFont(SystemRef, raw, "ui",
                system.MessageBoxFont) ? 1 : 0;
            found += this.takeWindowsFont(SystemRef, raw, "titlebar",
                system.CaptionFont) ? 1 : 0;
            found += this.takeWindowsFont(SystemRef, raw, "small",
                system.SmallCaptionFont) ? 1 : 0;
        } catch (e) {
            this.noteOnce("could not reach System.Drawing.SystemFonts: " + e);
            return null;
        }
        if (!found) {
            return null;
        }
        return raw;
    };

    /*
     * One font, taken and handed back.
     *
     * `SizeInPoints` and never `Size`. `Size` is expressed in the font's own
     * `Unit`, which for a system font is normally Point and is not promised
     * to be -- so a reader taking `Size` and calling it points would be
     * wrong on exactly the machines configured unusually, which is the worst
     * place to be wrong.
     *
     * `.Bold` and not `.Style`, which is a flags enum; the booleans are what
     * JScript.NET's overload picking survives.
     *
     * And Disposed, every time. System.Drawing.Font is IDisposable and
     * SystemFonts hands back a **new** one on every property access, so this
     * is three GDI font handles per read -- and this read is on the event
     * loop's clock for the life of the app. The palette's reader has no such
     * duty because SystemColors hands back value types. That difference is
     * the one genuinely new hazard on this lane, so it is written down
     * rather than left to look like ceremony.
     */
    NeutrinoWebview.takeWindowsFont = function (SystemRef, raw, role, font) {
        if (!font) {
            this.noteOnce("this machine names no " + role + " font");
            return false;
        }
        var ok = false;
        try {
            raw[role + "Family"] = String(font.Name);
            raw[role + "Size"] = SystemRef.Convert.ToDouble(font.SizeInPoints);
            raw[role + "Weight"] = font.Bold ? 700 : 400;
            ok = true;
        } catch (e) {
            this.noteOnce("could not read the " + role + " font: " + e);
        }
        try {
            font.Dispose();
        } catch (_) {}
        return ok;
    };
