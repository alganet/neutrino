    /*
     * The GTK named colours, in themeKeys order.
     *
     * One list, walked by the two lanes that drive GTK -- this file's gjs
     * driver and the PyGObject shim, which reads the string back out of
     * here rather than carrying a second copy of it. A palette that
     * disagreed between the two would be a desktop that looked different
     * depending on which interpreter the launcher happened to find.
     *
     * The GTK3 spellings, because they are the ones measured present. Under
     * Mint-L-Dark every name below answered, while libadwaita's newer
     * `accent_bg_color`, `window_bg_color` and `view_bg_color` all came back
     * not found. Those are an upgrade for a later round and never the only
     * read: a lane that asked for them alone would report nothing on a
     * desktop that is working perfectly well.
     */
    NeutrinoWebview.gtkColorNames = "theme_bg_color,theme_fg_color,theme_base_color,theme_text_color," +
        "theme_selected_bg_color,theme_selected_fg_color,borders";

    /*
     * The palette, off any realized-or-not widget's style context.
     *
     * A style context and not a window, because the read happens before
     * there is a window: boot asks for the theme ahead of createWindow, so
     * the caller hands in a throwaway widget. Measured on Gtk.Box, Gtk.Label
     * and Gtk.Window -- all three answer identically, because these are
     * theme-level names and not widget-level ones -- so the cheapest of the
     * three is what the driver builds.
     *
     * `borders` is the one that comes back translucent on some themes and
     * `insensitive_fg_color` always does, which is why the alpha travels
     * with each colour to flattenColor rather than being dropped here. The
     * background is read first so there is something to flatten against.
     *
     * One name failing means null, not a palette with six colours in it:
     * normalizeTheme would refuse it anyway, and refusing here says which
     * name was missing.
     */
    NeutrinoWebview.readGtkTheme = function (styleContext) {
        if (!styleContext) {
            return null;
        }
        var keys = this.themeKeyList();
        var names = String(this.gtkColorNames).split(",");
        var hex = [];
        var alpha = [];
        for (var i = 0; i < names.length; i++) {
            var found = null;
            try {
                found = styleContext.lookup_color(names[i]);
            } catch (e) {
                this.noteOnce("could not look up " + names[i] + ": " + e);
                return null;
            }
            if (!found || !found[0] || !found[1]) {
                this.noteOnce("this theme defines no " + names[i]);
                return null;
            }
            hex[i] = this.toHex(found[1]);
            alpha[i] = found[1].alpha;
        }
        var raw = { source: "gtk" };
        for (var j = 0; j < keys.length; j++) {
            raw[keys[j]] = this.flattenColor(hex[j], alpha[j], hex[0]);
        }
        return raw;
    };

    /*
     * Whether GTK's prefer-dark flag should be raised for this palette,
     * asked by both lanes that drive GTK so that neither decides it.
     *
     * It is not a preference being restated. `prefers-color-scheme` in the
     * page is the engine's own answer and on WebKitGTK it is a *name*: the
     * flag below, or a theme whose name carries the dark variant. It is not
     * the palette. Measured on this desk, one launch per row, the media
     * query beside `neutrino.theme.scheme`:
     *
     *   GTK_THEME=Adwaita            f6f5f4   mq=light   scheme=light
     *   GTK_THEME=Adwaita:dark       353535   mq=dark    scheme=dark
     *   GTK_THEME=Adwaita-dark       353535   mq=dark    scheme=dark
     *   GTK_THEME=Mint-Y-Dark        2e2e33   mq=dark    scheme=dark
     *   GTK_THEME=Mint-Y-Dark-Grey   2e2e33   mq=light   scheme=dark
     *   GTK_THEME=Mint-L-Dark-Blue   383838   mq=light   scheme=dark
     *
     * The last two are stock Mint themes, installed by the distribution and
     * selectable from its settings panel. `Mint-Y-Dark-Grey` is the same
     * dark grey as `Mint-Y-Dark` and the engine calls it light, because the
     * name ends in the colour and not in the variant -- and the `-Dark-`
     * families are twenty-odd themes shipped that way. So this is a defect
     * an ordinary desktop reaches by picking a theme from a list.
     *
     * `gtk-application-prefer-dark-theme` reads False on every row above,
     * including the three the engine calls dark, which is the flag this
     * file's luminance rule already refuses to trust for the palette. What
     * is measured here is that *writing* it moves the media query, both
     * before the web process exists and after it is up.
     *
     * Raised and never lowered, and the asymmetry is the engine's. Setting
     * it False under `Adwaita-dark` left the query at dark: the rule there
     * is the flag OR the name, so the name cannot be argued with. The half
     * that can be fixed is the one that occurs -- a dark desktop reported
     * light -- and the half that cannot is a theme named for a variant it
     * does not have, which no distribution ships.
     *
     * Raising it can move the palette, and only in the direction this never
     * asks for: on a light theme with a dark variant, GTK switches to the
     * variant, and `Adwaita` went f6f5f4 to 353535 under it. This returns
     * true only where the palette already measured dark, and on the three
     * dark themes above the flag moved nothing. A theme that did move would
     * be re-read by the watcher, measure dark again, and ask for the same
     * flag -- one repaint, not a loop.
     */
    NeutrinoWebview.gtkPreferDark = function (theme) {
        return !!theme && theme.scheme === "dark";
    };

    /*
     * The two surfaces GTK puts up before the document, painted from one
     * value, on the two lanes that drive GTK -- this one and the PyGObject
     * one, which calls in here rather than reading the colour itself.
     *
     * The window is styled through its own style context and not through
     * add_provider_for_screen: the screen-wide call reaches every window in
     * the process, and there is one here today only by accident of there
     * being one window. A provider on the widget cannot grow that reach.
     *
     * Neither of these throws. A background that will not paint is a window
     * that comes up in the theme colour, which is exactly where this
     * started -- worth a note on stderr and not worth a launch.
     */
    NeutrinoWebview.paintGtkWindow = function (Gtk, Gdk, win, background) {
        var rgb = this.parseColor(background);
        if (!rgb || !Gtk || !Gdk) {
            return false;
        }
        var css = "window, .background { background-color: rgb(" +
            Math.round(rgb.red * 255) + "," +
            Math.round(rgb.green * 255) + "," +
            Math.round(rgb.blue * 255) + "); }";
        try {
            var provider = new Gtk.CssProvider();
            provider.load_from_data(css);
            win.get_style_context().add_provider(
                provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            return true;
        } catch (e) {
            this.note("could not paint the window: " + e);
            return false;
        }
    };

    NeutrinoWebview.paintWebKitView = function (Gdk, wv, background) {
        var rgb = this.parseColor(background);
        if (!rgb || !Gdk) {
            return false;
        }
        try {
            var rgba = new Gdk.RGBA();
            rgba.red = rgb.red;
            rgba.green = rgb.green;
            rgba.blue = rgb.blue;
            rgba.alpha = 1;
            wv.set_background_color(rgba);
            return true;
        } catch (e) {
            this.note("could not paint the view: " + e);
            return false;
        }
    };

