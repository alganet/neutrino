    /*
     * A colour, as the four toolkits want it.
     *
     * Three of the five lanes take the string as written -- Gdk.RGBA.parse,
     * a QML colour property and ColorTranslator.FromHtml all read `#rrggbb`
     * themselves -- so this exists for the one that does not. NSColor is
     * built from components, and a lane that parsed its own would be a
     * second reading of the same value that could disagree with the others.
     *
     * `#rgb` and `#rrggbb` and nothing else, and a value it cannot read
     * comes back null rather than as black. A background nobody can parse
     * is a build that should have been refused, and build.sh refuses it;
     * this returning null is what lets each lane leave its surface alone
     * instead of painting it a colour nobody asked for.
     */
    NeutrinoWebview.parseColor = function (value) {
        var text = String(value || "");
        if (!/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(text)) {
            return null;
        }
        var hex = text.substring(1);
        if (hex.length === 3) {
            hex = hex.charAt(0) + hex.charAt(0) +
                  hex.charAt(1) + hex.charAt(1) +
                  hex.charAt(2) + hex.charAt(2);
        }
        return {
            red: parseInt(hex.substring(0, 2), 16) / 255,
            green: parseInt(hex.substring(2, 4), 16) / 255,
            blue: parseInt(hex.substring(4, 6), 16) / 255
        };
    };
    // The palette the desktop is using, as normalizeTheme returns it, or
    // null on a lane that could not read one. Written once at boot and
    // again by applyTheme, and read by everything that paints.
    NeutrinoWebview.theme = null;

    /*
     * A note that is worth making once and not once a second.
     *
     * Everything the theme watchers report is on a path that repeats: the
     * Windows lane re-reads the palette on a clock, and the GTK lanes read
     * it on every style-updated, which is emitted rather more often than
     * the theme actually changes. A toolkit that cannot be read is a
     * standing condition, so saying so on every attempt would bury the rest
     * of this file's stderr under one sentence -- and stderr is the app's,
     * not this file's, on four of the five lanes.
     *
     * Once per distinct message for the life of the process, which means a
     * condition that clears and returns is reported only the first time.
     * That is the trade, and it is the right way round: the first one is
     * the one that says what happened.
     */
    NeutrinoWebview.notedOnce = null;

    NeutrinoWebview.noteOnce = function (message) {
        if (!this.notedOnce) {
            this.notedOnce = {};
        }
        // Prefixed, so a message that happens to read like a name on
        // Object.prototype -- "constructor" is the one that bites -- is a
        // key of this set and not a truthy thing it inherited.
        var key = " " + String(message);
        if (this.notedOnce[key]) {
            return;
        }
        this.notedOnce[key] = true;
        this.note(message);
    };

    /*
     * The other direction: components back to the spelling every lane and
     * the page both read. parseColor takes `#rgb` and `#rrggbb` and hands
     * back components; this hands back `#rrggbb`, lower case, always six
     * digits. One spelling out means themesDiffer can compare strings and
     * that the payload check below is a real check rather than a formality.
     */
    NeutrinoWebview.toHex = function (rgb) {
        var pair = function (value) {
            var n = Math.round(value * 255);
            n = (n < 0) ? 0 : ((n > 255) ? 255 : n);
            return (n < 16 ? "0" : "") + n.toString(16);
        };
        return "#" + pair(rgb.red) + pair(rgb.green) + pair(rgb.blue);
    };

    /*
     * A colour with alpha, over the surface behind it.
     *
     * The palette below is `#rrggbb` throughout, and some of what the
     * toolkits hand over is not: GTK's `insensitive_fg_color` came back
     * `rgba(218,218,218,0.5)` on the desk this was written at, and macOS
     * spells `separatorColor` the same way. Every reader has the alpha its
     * own toolkit gave it, so the readers pass it here rather than each
     * flattening it their own way -- the rule is one rule for the same
     * reason parseColor is one parser.
     *
     * Over the surface behind it and not over white: a translucent border
     * flattened against white is a light border on a dark desktop, which is
     * the one thing this whole file is trying not to do.
     */
    NeutrinoWebview.flattenColor = function (hex, alpha, overHex) {
        var top = this.parseColor(hex);
        if (!top) {
            return null;
        }
        var a = Number(alpha);
        if (!(a >= 0 && a <= 1)) {
            a = 1;
        }
        var under = this.parseColor(overHex);
        if (a >= 1 || !under) {
            return this.toHex(top);
        }
        return this.toHex({
            red: top.red * a + under.red * (1 - a),
            green: top.green * a + under.green * (1 - a),
            blue: top.blue * a + under.blue * (1 - a)
        });
    };

    /*
     * sRGB relative luminance, the standard curve. What it is for is the
     * one question every lane has to answer the same way: is the desktop
     * dark?
     *
     * Not the toolkit's own flag, and that is a measurement rather than a
     * preference. On the desk this was written at
     * `gtk-application-prefer-dark-theme` reads False while the theme is
     * `Mint-L-Dark` -- the flag says light and the window is dark grey. The
     * XDG portal gets it right and `gsettings ... color-scheme` returns
     * `default`, so there is no one flag to read even on one desktop.
     *
     * The palette is what is on screen, so the luminance of the palette is
     * the truth about it. That makes this the definition rather than a
     * fallback, and it means five lanes answer with one rule instead of
     * five APIs that can each drift.
     */
    NeutrinoWebview.relativeLuminance = function (rgb) {
        var linear = function (u) {
            return (u <= 0.03928) ? (u / 12.92) : Math.pow((u + 0.055) / 1.055, 2.4);
        };
        return 0.2126 * linear(rgb.red) +
            0.7152 * linear(rgb.green) +
            0.0722 * linear(rgb.blue);
    };

    /*
     * And the threshold, which is not a number written down here.
     *
     * A surface is dark when it takes light text better than dark text, so
     * the two contrast ratios are computed and compared. That puts the
     * crossing at a luminance of about 0.179 -- mid grey `#808080` is 0.216
     * and comes out light, which is right, and a fixed 0.5 would have
     * called it dark. The rule says what it means and there is no constant
     * to get wrong.
     */
    NeutrinoWebview.isDarkSurface = function (rgb) {
        var lum = this.relativeLuminance(rgb);
        var againstWhite = 1.05 / (lum + 0.05);
        var againstBlack = (lum + 0.05) / 0.05;
        return againstWhite > againstBlack;
    };

