    /*
     * The macOS palette, in themeKeys order, with the fallbacks each entry
     * needs spelled after a `|`.
     *
     * The fallbacks are versions and not preferences. `controlAccentColor`
     * and `separatorColor` are 10.14, `labelColor` is 10.10, and a lane that
     * asked for the newest spelling alone would report nothing at all on a
     * Mac where everything else works. First one the runtime answers to
     * wins.
     */
    NeutrinoWebview.macColorNames = "windowBackgroundColor," +
        "labelColor|controlTextColor," +
        "textBackgroundColor," +
        "textColor," +
        "controlAccentColor|selectedContentBackgroundColor|alternateSelectedControlColor," +
        "alternateSelectedControlTextColor|selectedMenuItemTextColor," +
        "separatorColor|gridColor";

    NeutrinoWebview.readMacColor = function (dollar, names) {
        var list = String(names).split("|");
        for (var i = 0; i < list.length; i++) {
            try {
                var color = dollar.NSColor[list[i]];
                if (!color) {
                    continue;
                }
                // Through sRGB rather than off the colour as it stands: a
                // catalog colour has no components at all until it is
                // converted, and asking one for redComponent raises.
                var srgb = color.colorUsingColorSpace(dollar.NSColorSpace.sRGBColorSpace);
                if (!srgb) {
                    continue;
                }
                return {
                    hex: this.toHex({
                        red: srgb.redComponent,
                        green: srgb.greenComponent,
                        blue: srgb.blueComponent
                    }),
                    alpha: srgb.alphaComponent
                };
            } catch (_) {}
        }
        return null;
    };

    /*
     * And the read, which is also a correctness fix rather than a feature.
     *
     * NSColor's system colours are *dynamic*: they resolve against
     * NSAppearance.currentAppearance at the moment they are asked. A JXA
     * script has no drawing context, so currentAppearance is nil, and nil
     * resolves to Aqua -- which means reading windowBackgroundColor without
     * doing anything about it reports **light colours on a dark Mac**. Not
     * an error, not empty, just wrong, and wrong in exactly the direction
     * that would make an app paint white on a dark desktop.
     *
     * So the appearance is set here, from AppleInterfaceStyle, before a
     * single colour is read. That default is the plainest reading macOS
     * offers -- the string "Dark", or nothing at all for light -- and it is
     * used to *choose the appearance to resolve under*, never to report the
     * scheme: the scheme still comes from the luminance of what came back,
     * on this lane as on every other.
     */
    NeutrinoWebview.readMacTheme = function (ObjCRef, dollar) {
        try {
            var style = dollar.NSUserDefaults.standardUserDefaults
                .stringForKey("AppleInterfaceStyle");
            var wantsDark = String(ObjCRef.unwrap(style) || "").indexOf("Dark") === 0;
            // The constants are these strings. Written out rather than
            // taken from $.NSAppearanceNameDarkAqua, which is a global the
            // bridge does not always carry, and a nil name here would give
            // a nil appearance and put the read straight back where it
            // started.
            var appearance = dollar.NSAppearance.appearanceNamed(
                wantsDark ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua");
            if (appearance) {
                dollar.NSAppearance.currentAppearance = appearance;
            }
        } catch (e) {
            this.noteOnce("could not set the drawing appearance: " + e);
        }
        var keys = this.themeKeyList();
        var names = String(this.macColorNames).split(",");
        var found = [];
        for (var i = 0; i < names.length; i++) {
            found[i] = this.readMacColor(dollar, names[i]);
            if (!found[i]) {
                this.noteOnce("no NSColor answered to " + names[i]);
                return null;
            }
        }
        var raw = { source: "macos" };
        for (var j = 0; j < keys.length; j++) {
            raw[keys[j]] = this.flattenColor(found[j].hex, found[j].alpha, found[0].hex);
        }
        return raw;
    };

    /*
     * The same pair on macOS, where the colour has to be taken apart
     * because NSColor is built from components and reads no string.
     * parseColor is where that happens, so this lane and the four that hand
     * a string to a toolkit are all reading one value.
     *
     * The view is the harder half. WKWebView draws an opaque white behind
     * the page and the property that says otherwise is not public: the
     * supported spelling, underPageBackgroundColor, is macOS 12 and later,
     * and drawsBackground is a key that has answered to setValue:forKey:
     * for far longer. Both are tried, neither is required, and the window
     * underneath is painted either way -- so the worst outcome here is the
     * white this was opened to close, and never a lane that will not start.
     */
    NeutrinoWebview.paintMacWindow = function (win, background) {
        var dollar = eval("$");
        var rgb = this.parseColor(background);
        if (!rgb) {
            return false;
        }
        try {
            win.backgroundColor = dollar.NSColor.colorWithSRGBRedGreenBlueAlpha(
                rgb.red, rgb.green, rgb.blue, 1.0);
            return true;
        } catch (e) {
            this.note("could not paint the window: " + e);
            return false;
        }
    };

    NeutrinoWebview.paintMacView = function (wv, background) {
        var dollar = eval("$");
        var rgb = this.parseColor(background);
        if (!rgb) {
            return false;
        }
        var painted = false;
        try {
            wv.underPageBackgroundColor = dollar.NSColor.colorWithSRGBRedGreenBlueAlpha(
                rgb.red, rgb.green, rgb.blue, 1.0);
            painted = true;
        } catch (_) {}
        // Lets the window's own colour through instead of the view's
        // white, which is the older answer and the one that covers the
        // releases the property above does not exist on.
        try {
            wv.setValueForKey(false, "drawsBackground");
            painted = true;
        } catch (_) {}
        if (!painted) {
            this.note("could not paint the view; it will show its own background");
        }
        return painted;
    };

