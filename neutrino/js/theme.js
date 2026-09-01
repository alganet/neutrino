    // The palette, in one place, because five readers and one normalizer
    // and one payload check all have to agree on it. A string rather than
    // an array literal walk: JScript.NET is the engine that has to compile
    // this file, and a comma-separated set is how the launcher already
    // spells one.
    NeutrinoWebview.themeKeys = "background,foreground,base,text,accent,accentText,border";
    NeutrinoWebview.themeSources = "gtk,qt,macos,windows";

    /*
     * The same seven, spelled as CSS. In themeKeys order and read
     * positionally, because two lists that have to stay parallel are safer
     * as two lists in one order than as a map anyone can add half an entry
     * to.
     *
     * These are the non-deprecated `<system-color>` keywords, and the names
     * are the keywords exactly so that the fallback idiom reads itself:
     *
     *     background: var(--neutrino-Canvas, Canvas);
     *     color:      var(--neutrino-CanvasText, CanvasText);
     *
     * The desktop's real colour where a lane read one, the engine's own
     * system colour where it did not -- said at the point of use, with no
     * branch in script, which is strictly better than an app testing
     * `theme === null` and picking something.
     *
     * `Highlight` and not `AccentColor` for the accent pair, and the flip
     * is what decided it. `AccentColor` matched the desktop only on macOS.
     * `Highlight` matched WebView2 and came within one unit on WebKitGTK --
     * *and that near-match was a coincidence*: it stayed `3484e4` when the
     * desktop's accent moved to `15539e`. So neither keyword is the
     * desktop's accent anywhere but one lane, the custom property carries
     * the measured value in either spelling, and what is left to choose on
     * is the fallback. `Highlight` and `HighlightText` are CSS2 and resolve
     * on all four engines; `AccentColor` is newer and does not everywhere.
     * A fallback that resolves to nothing leaves the previous value in
     * place, which is the one failure this delivery must not have.
     *
     * It is also the more honest name for what is being read: on three of
     * the four lanes the source is literally the selection colour, and only
     * macOS asks for `controlAccentColor` first.
     */
    NeutrinoWebview.systemColorNames = "ButtonFace,ButtonText,Canvas,CanvasText," +
        "Highlight,HighlightText,ButtonBorder";

    NeutrinoWebview.inSet = function (set, name) {
        return ("," + set + ",").indexOf("," + String(name) + ",") >= 0;
    };

    NeutrinoWebview.themeKeyList = function () {
        return String(this.themeKeys).split(",");
    };

    /*
     * What a lane hands over, checked, and what every consumer sees.
     *
     * A reader returns a flat object -- seven colours and the name of the
     * lane that read them -- and nothing else in this file trusts it. Each
     * colour goes through parseColor, which is the same reading the
     * background has always had, and comes back out through toHex so the
     * palette is one spelling however the toolkit spelled it. The scheme is
     * derived here rather than reported by the lane, for the reason
     * relativeLuminance gives.
     *
     * A raw object with a colour nobody can parse returns null, whole. Not
     * a palette with a hole in it and not one with white where a value
     * should be: a half-read palette is worse than no palette, because an
     * app would style itself from it and have no way to tell. The caller
     * keeps whatever it had, which at launch is nothing and afterwards is
     * the last palette that did parse.
     */
    NeutrinoWebview.normalizeTheme = function (raw) {
        if (!raw || typeof raw !== "object") {
            return null;
        }
        var source = String(raw.source || "");
        if (!this.inSet(this.themeSources, source)) {
            return null;
        }
        var keys = this.themeKeyList();
        var colors = {};
        for (var i = 0; i < keys.length; i++) {
            var rgb = this.parseColor(raw[keys[i]]);
            if (!rgb) {
                return null;
            }
            colors[keys[i]] = this.toHex(rgb);
        }
        return {
            scheme: this.isDarkSurface(this.parseColor(colors.background)) ? "dark" : "light",
            source: source,
            colors: colors
        };
    };

    /*
     * The colour the two pre-document surfaces are painted, once the
     * desktop has been read.
     *
     * `base` and not `background`, and it is the one judgement call in
     * here. The view is very nearly the whole window, and an app that
     * follows the desktop paints its body like a content surface -- white
     * under GNOME light, where the window chrome is #F6F5F4. Borrowing the
     * chrome colour would put the app's own body colour a shade away from
     * the frame it arrives in, which is a seam rather than a flash but
     * still something to look at. The chrome colour is in the palette for
     * an app that wants it.
     *
     * A build that named a colour is answered from the config and never
     * from the desktop -- that is what naming one means. The white at the
     * end is not a default anybody chooses; it is what is left when a lane
     * could not read its toolkit at all, and it is the colour this file
     * shipped before any of it existed.
     */
    NeutrinoWebview.followsTheme = function () {
        return !this.parseColor(this.config.background);
    };

    /*
     * One question, asked by five drivers, so a sixth spelling of the same
     * comparison cannot drift from the other five. The equality is against
     * the one value that means it and not against anything falsy: `auto` is
     * a value here, not an absence, and a config that somehow carried
     * neither word keeps the frame rather than losing it -- removing a
     * window's only handle is not the safe side of an unreadable value.
     */
    NeutrinoWebview.undecorated = function () {
        return this.config.decorations === "none";
    };

    NeutrinoWebview.resolveBackground = function (theme) {
        if (!this.followsTheme()) {
            return this.config.background;
        }
        if (theme && theme.colors && this.parseColor(theme.colors.base)) {
            return theme.colors.base;
        }
        return "#ffffff";
    };

    /*
     * Whether anything actually changed, and it is load-bearing rather than
     * tidy. The GTK watcher is `style-updated` on the window, and painting
     * the window is adding a CssProvider to it, which emits `style-updated`
     * -- so a watcher that pushed whatever it was handed would feed itself
     * for as long as the app was open. Every lane goes through here for
     * that reason, and the Windows lane can re-read on a timer at all
     * because of it.
     */
    NeutrinoWebview.themesDiffer = function (a, b) {
        if (!a || !b) {
            return a !== b;
        }
        if (a.scheme !== b.scheme || a.source !== b.source) {
            return true;
        }
        var keys = this.themeKeyList();
        for (var i = 0; i < keys.length; i++) {
            if (a.colors[keys[i]] !== b.colors[keys[i]]) {
                return true;
            }
        }
        return false;
    };

    /*
     * The palette as a JavaScript object literal, for the two places that
     * need one: the preload, where it is the snapshot the page starts with,
     * and the push below, where it is an update.
     *
     * Everything in it is checked again here even though normalizeTheme
     * built it, and that is the point rather than belt and braces. This is
     * the only string this file ever evaluates *into* a page -- every other
     * direction is the page talking to the host -- so the rule parseMessage
     * holds coming in is held going out: a fixed shape, a known key set, and
     * values that match one anchored pattern or the whole update is dropped.
     * There is no escaping scheme here for the same reason there is none
     * there, and nothing that fails this can reach a page as text.
     */
    NeutrinoWebview.themeLiteral = function (theme) {
        if (!theme || !theme.colors) {
            return null;
        }
        if (theme.scheme !== "dark" && theme.scheme !== "light") {
            return null;
        }
        if (!this.inSet(this.themeSources, theme.source)) {
            return null;
        }
        var values = this.themeColorList(theme);
        if (!values) {
            return null;
        }
        var keys = this.themeKeyList();
        var parts = [];
        for (var i = 0; i < keys.length; i++) {
            parts[parts.length] = keys[i] + ':"' + values[i] + '"';
        }
        return '{scheme:"' + theme.scheme + '",source:"' + theme.source +
            '",colors:{' + parts.join(",") + '}}';
    };

    /*
     * The seven colours, in themeKeys order, or null for the whole palette.
     *
     * Two deliveries read this now -- the object the page gets and the CSS
     * the document carries -- and they have to agree about what a
     * presentable palette is. A palette that is good enough to hand to
     * script and not good enough to put in a stylesheet would be a window
     * whose two accounts of the desktop disagree.
     *
     * The check is the anchored one this file has always applied. It is
     * also what makes themeCssText closed by construction: every value that
     * reaches a stylesheet matched `^#[0-9a-f]{6}$`, and every property
     * name came from a constant in this file.
     */
    NeutrinoWebview.themeColorList = function (theme) {
        if (!theme || !theme.colors) {
            return null;
        }
        var keys = this.themeKeyList();
        var out = [];
        for (var i = 0; i < keys.length; i++) {
            var value = String(theme.colors[keys[i]]);
            if (!/^#[0-9a-f]{6}$/.test(value)) {
                return null;
            }
            out[out.length] = value;
        }
        return out;
    };

    NeutrinoWebview.buildThemeScript = function (theme) {
        var literal = this.themeLiteral(theme);
        if (!literal) {
            return null;
        }
        return "window.neutrino&&window.neutrino._theme&&window.neutrino._theme(" +
            literal + ");";
    };

    /*
     * One place every lane's watcher ends up, so the order is the same on
     * all five: check what was read, drop it if it is not different,
     * repaint the native surfaces if this build follows the desktop, then
     * tell the page.
     *
     * The native repaint is first because it is the surface the page is
     * about to be drawn over, and it is skipped entirely for a build that
     * named its own colour -- an author who said #12141a means it through a
     * theme change as much as through a launch.
     *
     * The push is allowed to fail. A page that did not get an update still
     * has the palette it started with, which is a window one theme change
     * out of date rather than a window that is gone.
     */
    NeutrinoWebview.applyTheme = function (driver, win, wv, raw) {
        var next = this.normalizeTheme(raw);
        if (!next) {
            this.noteOnce("could not read the desktop palette");
            return false;
        }
        if (!this.themesDiffer(this.theme, next)) {
            return false;
        }
        this.theme = next;
        /*
         * Before the repaint, because on GTK the flag that carries this is
         * one the toolkit may answer by changing the palette -- and a
         * repaint that ran first would be painting the palette the flag was
         * about to replace.
         */
        if (driver.forceScheme) {
            try {
                driver.forceScheme(next);
            } catch (e0) {
                this.noteOnce("could not force the colour scheme: " + e0);
            }
        }
        if (this.followsTheme() && driver.repaint) {
            try {
                driver.repaint(win, wv, this.resolveBackground(next));
            } catch (e) {
                this.noteOnce("could not repaint for the new theme: " + e);
            }
        }
        var js = this.buildThemeScript(next);
        if (js && driver.evaluate) {
            try {
                driver.evaluate(wv, js);
            } catch (e2) {
                this.noteOnce("could not deliver the theme: " + e2);
            }
        }
        return true;
    };

