    /*
     * The GTK fonts, and the decisions about them, in one place for the two
     * lanes that drive GTK -- this branch's gjs driver and the PyGObject
     * shim.
     *
     * The palette had to be reimplemented in Python because readGtkTheme
     * takes a `Gtk.Box` style context and a GTK widget cannot cross into
     * JavaScriptCore. Fonts have no such object: everything GTK says about
     * one is a string, and strings cross fine. What cannot cross is
     * `Pango.FontDescription`, which lives in each lane's own runtime.
     *
     * So the split here is by *what needs a runtime*, not by lane:
     *
     *   gather  every candidate string, from every schema present   lane
     *   choose  which schema wins, and what each role takes         here
     *   parse   Pango, on the five strings choose picked            lane
     *   build   aliases, units, fallbacks, the raw object           here
     *
     * Only `gather` and `parse` are written twice, and neither is a
     * decision -- the same rule shim.py's read_theme already states about
     * its duplicated loop. Every judgement is in this file, once.
     */

    /*
     * The schema families that carry a desktop's font settings, in
     * precedence order for the tie-break below.
     *
     * Three, because three exist and they disagree. Measured on one Mint
     * desktop in a single run: org.gnome.desktop.interface held
     * `document-font-name` "Sans 10" and `monospace-font-name`
     * "DejaVu Sans Mono 10", org.cinnamon.desktop.interface carried
     * `font-name` and *neither* of the other two keys, and
     * org.mate.interface held a `monospace-font-name` of "Monospace 10".
     * A reader that took the first schema it found would report a font
     * nothing on that desktop is drawing with.
     */
    NeutrinoWebview.gtkFontSchemas = "org.gnome.desktop.interface," +
        "org.cinnamon.desktop.interface,org.mate.interface";

    NeutrinoWebview.gtkFontWmSchemas = "org.gnome.desktop.wm.preferences," +
        "org.cinnamon.desktop.wm.preferences";

    // The keys read out of an interface schema, and out of a wm one.
    NeutrinoWebview.gtkFontKeys = "font-name,document-font-name,monospace-font-name";
    NeutrinoWebview.gtkFontWmKeys = "titlebar-font,titlebar-uses-system-font";

    /*
     * `text-scaling-factor` is deliberately absent from those lists.
     *
     * Measured: setting it to 1.5 moved `gtk-xft-dpi` to 144 *and*
     * `devicePixelRatio` to 1.5, and left CSS px exactly where they were --
     * a 10pt font stayed 13.33 CSS px and simply occupied more device
     * pixels. GTK's text scaling is absorbed by the engine's own device
     * pixel ratio, so a lane that divided by the toolkit's DPI, or
     * multiplied by this factor, would count the same scaling twice and
     * deliver a page whose type was half again too large.
     *
     * This is the exact mistake the next reader of this file will want to
     * make, which is why the constant that is not here has a comment.
     */

    /*
     * Pango's generic aliases, which it hands back as *family names*.
     *
     * `Sans`, `Serif` and `Monospace` are fontconfig aliases and not
     * families; `font-family: Sans` matches nothing in any engine here.
     * Measured on real desktops as the literal value of
     * `document-font-name` ("Sans 10") and `monospace-font-name`
     * ("Monospace 10"), so this is the ordinary case on a stock GNOME box
     * rather than an edge one.
     *
     * A role whose family is one of these delivers no name at all and the
     * generic instead -- which is exactly what the alias meant.
     */
    NeutrinoWebview.gtkFontAliases = "Sans:sans-serif,Serif:serif,Monospace:monospace," +
        "System-ui:system-ui";

    /*
     * Which schema family this desktop is actually following.
     *
     * `gtk-font-name` off GtkSettings is the rendered truth -- it is what
     * GTK draws with and, measured, what WebKitGTK agrees with. GSettings
     * is where a settings daemon *writes* what it wants GTK to use. On a
     * desktop with a daemon running the two agree, and whichever schema
     * family matches is the family the other three roles should come from.
     *
     * On a runner with no daemon they do not agree at all: GtkSettings read
     * "Sans 10" while GNOME's key read "Cantarell 11", and the page
     * reported `13px|Sans` -- the toolkit's answer, not the setting's. So
     * this returns "" for that case and the caller falls back to fixed
     * order with a note, because there is no evidence to prefer any schema
     * and the alternative is silently picking one.
     *
     * themeflip.sh recorded the same disagreement for `gtk-theme` and drew
     * the same conclusion: the toolkit is the authority on what is on
     * screen.
     */
    NeutrinoWebview.gtkFontSchemaChoice = function (uiString, names) {
        var list = String(this.gtkFontSchemas).split(",");
        var i;
        for (i = 0; i < list.length; i++) {
            if (names[list[i]] !== undefined && names[list[i]] === uiString) {
                return list[i];
            }
        }
        for (i = 0; i < list.length; i++) {
            if (names[list[i]] !== undefined) {
                this.noteOnce("no GSettings schema agrees with GtkSettings' " +
                    "font-name; the other roles come from " + list[i]);
                return list[i];
            }
        }
        return "";
    };

    /*
     * Which font description string each role takes, given everything the
     * lane could gather.
     *
     * `gathered` carries `gtkFontName` (the GtkSettings value), `names`
     * (one entry per present interface schema that has `font-name`),
     * `interface` (the winning schema's three keys), and `titlebar` /
     * `titlebarSystem` from whichever wm schema answered.
     *
     * `ui` is always `gtkFontName` and never a GSettings value -- see
     * gtkFontSchemaChoice for the measurement that settles it. The other
     * three may be empty, which is the ordinary case rather than a failure:
     * Cinnamon's interface schema was measured carrying `font-name` and
     * neither `document-font-name` nor `monospace-font-name`, so a Mint
     * desktop reaches this with two of the four roles unanswered and the
     * fill rule in normalizeFonts takes them.
     */
    NeutrinoWebview.gtkChooseFontStrings = function (gathered) {
        var chosen = gathered.interface || {};
        var out = {
            ui: String(gathered.gtkFontName || ""),
            document: String(chosen["document-font-name"] || ""),
            monospace: String(chosen["monospace-font-name"] || ""),
            titlebar: ""
        };
        /*
         * `titlebar-uses-system-font` is a boolean and it means what it
         * says: when it is true the desktop draws its title bars in the UI
         * font and `titlebar-font` is a value nothing is reading. Measured
         * true on the CI runner and false on a developer's Mint desktop, so
         * both branches are live.
         *
         * Leaving `titlebar` empty here is not a special case downstream --
         * it is the ordinary unread role, and normalizeFonts fills it from
         * `ui`, which is what the flag asked for.
         */
        if (!gathered.titlebarSystem) {
            out.titlebar = String(gathered.titlebar || "");
        }
        return out;
    };

    /*
     * One parsed Pango description, turned into the three fields a role
     * carries.
     *
     * `parsed` is what the lane's own Pango handed back, undecided:
     * `family`, `size` in points, `absolute`, `weight`, `italic`. Pango is
     * what makes this safe, and it is worth saying what it saves: the
     * format is `FAMILY-LIST [STYLE-OPTIONS] [SIZE]` with the style words
     * unquoted in the middle, so a launcher splitting on the last space
     * reads "Ubuntu Medium 10" as a family called "Ubuntu Medium" that no
     * fontconfig will match. Measured, from_string gets all three of the
     * hard cases right:
     *
     *   Ubuntu Medium 10                 family=Ubuntu     weight=500
     *   Noto Sans Semi-Bold Condensed 11 family=Noto Sans  weight=600
     *   Segoe UI Variable Text 9         family=Segoe UI Variable Text
     *
     * The third is the control: `Text` is a word that looks like a style
     * option and is not one.
     *
     * Weights pass through. Pango's scale is already CSS's, and it is not
     * in hundreds -- SEMILIGHT is 350 and BOOK is 380 -- which CSS Fonts 4
     * accepts and normalizeFonts' 1..1000 check allows.
     *
     * An absolute size is in device units rather than points, so it is
     * handed over already in pixels and the caller says so. The lane passes
     * `absolute` through for exactly this branch rather than dividing
     * silently.
     */
    NeutrinoWebview.gtkRoleFields = function (role, parsed) {
        var out = { family: "", generic: "", size: "", weight: "" };
        if (!parsed) {
            return out;
        }
        var family = String(parsed.family || "");
        var alias = this.fontLookup(this.gtkFontAliases, family);
        if (alias !== "") {
            out.generic = alias;
        } else if (family !== "") {
            out.family = family;
        }
        if (parsed.size > 0) {
            out.size = parsed.size;
        }
        if (parsed.weight > 0) {
            out.weight = parsed.weight;
        }
        return out;
    };

    /*
     * The raw object, from the five roles the lane parsed.
     *
     * `parsedByRole` carries one entry per role that had a string, each the
     * shape gtkRoleFields takes. A role the desktop did not answer for is
     * simply absent, which is what normalizeFonts reads as "fill this one".
     *
     * The unit is points for every role except one parsed from an absolute
     * description, and Pango is the only source here that can produce a
     * mixed set. Rather than carry a unit per role -- which every other
     * lane would then have to think about -- an absolute size is converted
     * to points on the way in by the lane, so what leaves here is points
     * throughout and `unit` is a constant.
     */
    NeutrinoWebview.gtkFontsFromParsed = function (parsedByRole) {
        var roles = this.fontRoleList();
        var raw = { source: "gtk", unit: "pt" };
        for (var i = 0; i < roles.length; i++) {
            var got = parsedByRole[roles[i]];
            if (!got) {
                continue;
            }
            raw[roles[i] + "Family"] = got.family;
            raw[roles[i] + "Generic"] = got.generic;
            raw[roles[i] + "Size"] = got.size;
            raw[roles[i] + "Weight"] = got.weight;
        }
        return raw;
    };
