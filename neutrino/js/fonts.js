    /*
     * The desktop's fonts, in one place, for the same reason theme.js holds
     * the palette in one: five readers, one normalizer and two payload
     * checks all have to agree about what a role is called and what a role
     * carries. Comma-separated strings rather than array literals, because
     * jsc.exe is the engine that has to compile this file and a
     * comma-separated set is how the launcher already spells one.
     *
     * Five roles and not thirteen. macOS names thirteen and is the ceiling
     * -- a title bar font, a menu font, a message font, a palette font and
     * a fixed-pitch font, all distinct. GTK reaches four of these through
     * one GtkSettings key and three GSettings ones. Qt exposes exactly one.
     * Windows names six that measured identical on a stock desktop. These
     * are the five that had a distinct, real answer on the lane with the
     * most to say, and the fill rule below is what lets a lane that reaches
     * fewer of them still deliver all five.
     */
    NeutrinoWebview.fontRoles = "ui,document,monospace,titlebar,small";

    /*
     * What a role is, and the order everything positional in this file is
     * written in.
     *
     * `family` and `generic` are two fields and not one, and that is the
     * measurement rather than a preference. macOS reports
     * `.AppleSystemUIFont` for eleven of its thirteen roles -- a hidden
     * family WebKit refuses by name, silently, falling through to whatever
     * comes next in the list -- so that lane has to deliver the *token*
     * `system-ui` where every other lane delivers a name. Windows has no
     * monospace family at all. And Pango hands out `Sans`, `Serif` and
     * `Monospace` as family names when they are fontconfig aliases and not
     * families. One string cannot be both a quoted name and a bare keyword,
     * so it is two.
     */
    NeutrinoWebview.fontFields = "family,generic,size,weight";

    /*
     * The three custom properties a role becomes, in the order
     * fontCssNameList emits them.
     *
     *     font-family: var(--neutrino-font-ui, sans-serif);
     *     font-size:   var(--neutrino-font-size-ui, 1rem);
     *     font-weight: var(--neutrino-font-weight-ui, 400);
     *
     * Three longhands and not one variable carrying a `font` shorthand.
     * A shorthand can only be used by substituting the whole shorthand,
     * which resets line-height, font-style, font-variant and font-stretch
     * to their initial values at every use -- so an app that wanted the
     * desktop's family and its own line height could not have both.
     *
     * There is no `--neutrino-font-generic-*`. The generic is not a
     * property an author sets; it is the tail of the family list, and
     * fontCssValue composes it in.
     */
    NeutrinoWebview.fontCssPrefixes = "font,font-size,font-weight";

    /*
     * The generic each role falls back to, in fontRoles order.
     *
     * Not `system-ui`, and the measurement is why. Across three probe
     * rounds `system-ui` resolved on WKWebView and was the right face
     * there; did not resolve *at all* on WebKitGTK, where `ui-monospace`
     * was not even monospace; and on QtWebEngine resolved to plain
     * sans-serif. A generic that resolves to nothing leaves the previous
     * value in place, which is the one failure this delivery must not
     * have -- the same argument that put `Highlight` rather than
     * `AccentColor` in systemColorNames.
     *
     * So these are the CSS1 generics, which every engine has always had.
     * A lane may name a better one for a role; see fontSafeGenerics.
     */
    NeutrinoWebview.fontGenerics = "sans-serif,sans-serif,monospace,sans-serif,sans-serif";

    /*
     * The generics that resolve on every engine measured, and therefore
     * the only ones a family list may *end* on.
     *
     * `system-ui` is a legitimate value for a role's generic -- it is the
     * only way to name macOS's hidden system face -- but it is not a
     * legitimate last resort, because two of the four engines do not
     * resolve it. fontCssValue appends the role's CSS1 generic after any
     * generic that is not in this list, so every delivered family list ends
     * somewhere every engine can follow.
     */
    NeutrinoWebview.fontSafeGenerics = "sans-serif,serif,monospace";

    /*
     * Every token a lane may name as a role's generic.
     */
    NeutrinoWebview.fontFamilyTokens = "system-ui,sans-serif,serif,monospace";

    /*
     * What the `document` role falls back to when a lane has no answer for
     * it, by lane, because the convention it is imitating is not the same
     * on all four.
     *
     * `document` is the one role that does *not* fall back to `ui`. It is
     * the face a desktop puts inside a document rather than on its chrome,
     * and an app that asks for it has said it wants something distinct from
     * its buttons; handing back the UI font would answer a different
     * question. So an unread `document` keeps its own generic, and which
     * generic that is is a fact about the platform:
     *
     *   windows   serif, on the convention Times New Roman set and that
     *             every Windows browser still defaults its serif face to.
     *   gtk, qt   sans-serif, because GNOME's own `document-font-name`
     *             ships as `Sans` and that is the Linux desktop's answer
     *             to this question where it has one.
     *   macos     sans-serif, the tail behind Helvetica -- which that lane
     *             does read, from `userFontOfSize`, and which is TextEdit's
     *             own default.
     */
    NeutrinoWebview.fontDocumentGenerics =
        "gtk:sans-serif,qt:sans-serif,macos:sans-serif,windows:serif";

    /*
     * Qt's generic family names, which it hands back as families the way
     * Pango hands back "Sans".
     *
     * Here rather than in the Qt reader because the reader is QML and this
     * is a constant, and because gtkFontAliases sits beside it in the same
     * shape -- two toolkits with the same habit, spelled once each.
     * Measured: `Sans Serif` is what Qt reports under QGtk3Theme, where it
     * is Qt's own default and not anything the desktop said.
     */
    NeutrinoWebview.qtFontAliases = "Sans Serif:sans-serif,Serif:serif," +
        "Monospace:monospace,System:system-ui";

    /*
     * What unit a lane's sizes arrive in, said by the lane rather than
     * inferred from which lane it is.
     */
    NeutrinoWebview.fontUnits = "pt,px";

    /*
     * Points to CSS pixels, flat, with no DPI term in it.
     *
     * Confirmed three independent ways, and it is the finding that decides
     * where the conversion happens. GTK: raising text-scaling-factor to 1.5
     * moved gtk-xft-dpi to 144 *and* devicePixelRatio to 1.5 and left CSS
     * px alone, so a lane that divided by the toolkit's DPI would have
     * counted the same scaling twice. Windows: Graphics.DpiX reads 96 and
     * the launcher's exe carries no DPI-awareness manifest. Qt:
     * Screen.logicalPixelDensity gives the same 1.3333.
     *
     * macOS is the asymmetry and does not get this multiplier at all:
     * NSFont.systemFontSize is 13 and renders as 13px, so that lane's
     * points *are* CSS pixels. It says unit "px" and this is not applied.
     */
    NeutrinoWebview.ptToPx = 4 / 3;

    // The current set, alongside NeutrinoWebview.theme and read by
    // everything that delivers.
    NeutrinoWebview.fonts = null;

    NeutrinoWebview.fontRoleList = function () {
        return String(this.fontRoles).split(",");
    };

    NeutrinoWebview.fontFieldList = function () {
        return String(this.fontFields).split(",");
    };

    /*
     * The fifteen property names, role-major and field-minor -- the same
     * order fontValueList appends its values in, so the two are read
     * against each other with one index. Written from this file's own two
     * constants, so the mapping from a role to a property exists once and
     * both deliveries take it from here.
     */
    NeutrinoWebview.fontCssNameList = function () {
        var roles = this.fontRoleList();
        var prefixes = String(this.fontCssPrefixes).split(",");
        var out = [];
        for (var i = 0; i < roles.length; i++) {
            for (var j = 0; j < prefixes.length; j++) {
                out[out.length] = "--neutrino-" + prefixes[j] + "-" + roles[i];
            }
        }
        return out;
    };

    /*
     * One `key:value` out of a comma-separated constant, by key. The
     * fontDocumentGenerics idiom, kept here rather than inlined so that a
     * second such constant cannot spell the lookup differently.
     */
    NeutrinoWebview.fontLookup = function (pairs, key) {
        var list = String(pairs).split(",");
        for (var i = 0; i < list.length; i++) {
            var cut = list[i].indexOf(":");
            if (cut > 0 && list[i].substring(0, cut) === String(key)) {
                return list[i].substring(cut + 1);
            }
        }
        return "";
    };

    /*
     * The CSS1 generic a role ends on, whatever lane it came from. This is
     * the last resort and nothing overrides it: it is what makes every
     * delivered family list end somewhere all four engines resolve.
     */
    NeutrinoWebview.fontRoleSafeGeneric = function (role) {
        var roles = this.fontRoleList();
        var generics = String(this.fontGenerics).split(",");
        for (var i = 0; i < roles.length; i++) {
            if (roles[i] === role) {
                return generics[i];
            }
        }
        return "sans-serif";
    };

    /*
     * The generic a role takes when its lane named none. The same as above,
     * except that `document` is a question the four platforms answer
     * differently -- see fontDocumentGenerics.
     */
    NeutrinoWebview.fontRoleGeneric = function (role, source) {
        if (role === "document") {
            var byLane = this.fontLookup(this.fontDocumentGenerics, source);
            if (byLane !== "") {
                return byLane;
            }
        }
        return this.fontRoleSafeGeneric(role);
    };

    /*
     * A size in CSS pixels, as text, built out of integers.
     *
     * `String(13.333333333333334)` is a number-to-string conversion, and
     * this file is compiled by jsc.exe on one lane and interpreted by four
     * other engines on the rest. The anchored check in fontValueList would
     * catch a spelling that came out differently -- by dropping the whole
     * set, on Windows only, with nothing on screen saying why. Integers to
     * two places is the same shape toHex already uses for the same reason:
     * one spelling out, whoever did the arithmetic.
     */
    NeutrinoWebview.fontSizeText = function (px) {
        var hundredths = Math.round(px * 100);
        if (!(hundredths >= 100) || !(hundredths <= 99999)) {
            return null;
        }
        var whole = Math.floor(hundredths / 100);
        var frac = hundredths - whole * 100;
        if (!frac) {
            return String(whole) + "px";
        }
        return String(whole) + "." + (frac < 10 ? "0" : "") + String(frac) + "px";
    };

    /*
     * A family name the desktop answered, checked before it is allowed
     * anywhere near a page.
     *
     * Letters, digits, spaces, full stops and hyphens; a letter first; not
     * a space last; sixty-three characters at most. What it refuses is the
     * point:
     *
     *   - no quote and no backslash, so the same string is closed inside a
     *     CSS string *and* inside a JavaScript string literal, which is why
     *     there is no escaping scheme in either direction -- the rule
     *     theme.js:170 holds for colours, held here for names.
     *   - no `<` and no `/`, so `</style>` cannot be spelled. A <style>
     *     element is raw text, so `<` was the only way out of it.
     *   - no `}`, `;`, `(`, `*`, `@` or `:`, so a value cannot end a
     *     declaration, end a rule, open a url(), open a comment or start an
     *     at-rule.
     *   - no leading full stop, which refuses `.AppleSystemUIFont`
     *     centrally. That is macOS's hidden system family, and WebKit
     *     ignores it silently rather than reporting it -- so even if that
     *     lane's translation to `system-ui` were ever dropped, the name
     *     cannot reach a stylesheet from here.
     *
     * Every family measured across three probe rounds is inside it:
     * Ubuntu, DejaVu Serif, Noto Sans, Cantarell, Helvetica, Menlo,
     * Sans Serif, Segoe UI.
     */
    NeutrinoWebview.fontFamilyPattern = /^[A-Za-z]([A-Za-z0-9 .\-]{0,61}[A-Za-z0-9.])?$/;

    /*
     * A family list, composed once, host-side.
     *
     * Quoted, because an unquoted CSS family is a sequence of identifiers
     * and `MS Shell Dlg 2` ends in one that is not. Quoting is not an
     * escaping scheme -- it is a fixed wrapper around a value already
     * proved to hold no character that could leave it.
     *
     * Single quotes, because the same string goes into a JavaScript literal
     * built with double ones, so neither delimiter can be the other's
     * problem.
     */
    NeutrinoWebview.fontCssValue = function (family, generic, role) {
        var parts = [];
        if (family !== "") {
            parts[parts.length] = "'" + family + "'";
        }
        parts[parts.length] = generic;
        if (!this.inSet(this.fontSafeGenerics, generic)) {
            parts[parts.length] = this.fontRoleSafeGeneric(role);
        }
        return parts.join(",");
    };

    /*
     * What a lane hands over, checked, and what every consumer sees.
     *
     * A reader returns a flat object -- `source`, `unit`, and up to four
     * values per role named `<role>Family`, `<role>Generic`, `<role>Size`
     * and `<role>Weight`. Flat and not nested, for the three reasons the
     * palette's readers are flat: the PyGObject lane crosses it with one
     * json.dumps, jsc.exe compiles the Windows one, and a missing key is
     * then unambiguously *absent* rather than present-and-empty.
     *
     * Absence and refusal are different, and the difference is the whole
     * of the fill rule. A key that is missing, null or empty is a role this
     * lane has no answer for, and is filled below. A key that is present
     * and does not pass its check is a *refusal*, and nulls the whole
     * object -- because a font set with a hole in it is worse than no font
     * set, for the reason normalizeTheme gives about a half-read palette:
     * an app would style itself from it and have no way to tell.
     */
    NeutrinoWebview.normalizeFonts = function (raw) {
        if (!raw || typeof raw !== "object") {
            return null;
        }
        var source = String(raw.source || "");
        if (!this.inSet(this.themeSources, source)) {
            return null;
        }
        var unit = String(raw.unit || "");
        if (!this.inSet(this.fontUnits, unit)) {
            return null;
        }
        var scale = (unit === "pt") ? this.ptToPx : 1;
        var roles = this.fontRoleList();
        var out = { source: source };
        var i;

        for (i = 0; i < roles.length; i++) {
            var role = roles[i];
            var got = { family: null, generic: null, size: null, weight: null };

            var family = raw[role + "Family"];
            if (family !== undefined && family !== null && String(family) !== "") {
                var name = String(family);
                if (!this.fontFamilyPattern.test(name)) {
                    this.noteOnce("this desktop's " + role +
                        " font cannot be delivered by name");
                    return null;
                }
                got.family = name;
            }

            var generic = raw[role + "Generic"];
            if (generic !== undefined && generic !== null && String(generic) !== "") {
                if (!this.inSet(this.fontFamilyTokens, String(generic))) {
                    return null;
                }
                got.generic = String(generic);
            }

            var size = raw[role + "Size"];
            if (size !== undefined && size !== null && String(size) !== "") {
                var px = Number(size) * scale;
                if (!(px > 0) || !(px < 1000)) {
                    return null;
                }
                got.size = this.fontSizeText(px);
                if (!got.size) {
                    return null;
                }
            }

            var weight = raw[role + "Weight"];
            if (weight !== undefined && weight !== null && String(weight) !== "") {
                var w = Math.round(Number(weight));
                if (!(w >= 1) || !(w <= 1000)) {
                    return null;
                }
                got.weight = String(w);
            }

            out[role] = got;
        }

        /*
         * `ui` is what makes the fill total, so a lane that could not read
         * it has not read the desktop's fonts and says so rather than
         * inventing one. Its family may legitimately be empty -- that is
         * every macOS role, where the face has no name a page may use --
         * but its size may not, because a size is the one field nothing
         * else can stand in for.
         */
        var ui = out[roles[0]];
        if (!ui.size) {
            return null;
        }
        if (!ui.generic) {
            ui.generic = this.fontRoleGeneric(roles[0], source);
        }
        if (!ui.weight) {
            ui.weight = "400";
        }
        if (ui.family === null) {
            ui.family = "";
        }

        /*
         * And the four that may fall back, in two groups, because they are
         * two different questions.
         *
         * `titlebar` and `small` take `ui`'s face, because they *are* user
         * interface -- a desktop that draws its title bar in something
         * other than its UI font has said so, and one that has not is
         * drawing the UI font.
         *
         * `document` and `monospace` keep their own generic and stay
         * nameless. Filling `monospace` from `ui` would ship Segoe UI under
         * a name that promises fixed pitch on the one platform that has no
         * monospace setting -- a delivery worse than no delivery. Filling
         * `document` from `ui` would answer a different question than the
         * one the role's name asks.
         *
         * Size and weight always come from `ui`, on all four. Neither is a
         * kind-of-face question.
         */
        for (i = 1; i < roles.length; i++) {
            var r = out[roles[i]];
            var fromUi = (roles[i] === "titlebar" || roles[i] === "small");
            var unread = (r.family === null);
            if (unread) {
                r.family = fromUi ? ui.family : "";
            }
            if (!r.generic) {
                r.generic = (unread && fromUi)
                    ? ui.generic
                    : this.fontRoleGeneric(roles[i], source);
            }
            if (!r.size) {
                r.size = ui.size;
            }
            if (!r.weight) {
                r.weight = ui.weight;
            }
        }

        /*
         * And the composed family list, once, after every fallback has
         * resolved -- because it is a function of `family` and `generic`
         * and neither is settled until the loop above has run.
         *
         * It is on the object because the two deliveries must not compose
         * it separately. The launch half is a stylesheet this launcher
         * writes and the update half is a `setProperty` the page runs, and
         * a page that composed `family` and `generic` itself would spell
         * the macOS case `system-ui` where the stylesheet had said
         * `system-ui,sans-serif` -- the two accounts of one desktop
         * disagreeing after the first font change, on the one lane where
         * the tail is load-bearing. So it is built here, by the same
         * function fontValueList uses, and the page only ever copies it.
         */
        for (i = 0; i < roles.length; i++) {
            out[roles[i]].stack = this.fontCssValue(
                out[roles[i]].family, out[roles[i]].generic, roles[i]);
        }
        return out;
    };

    /*
     * Whether anything actually changed, and it is load-bearing rather than
     * tidy for the same reason themesDiffer is. The GTK watcher is
     * `style-updated`, which was measured firing *twice* for one font
     * change with the toolkit still holding the old value the first time --
     * so the first firing is a duplicate this gate drops, and the Windows
     * lane can re-read on a clock at all because of it.
     */
    NeutrinoWebview.fontsDiffer = function (a, b) {
        if (!a || !b) {
            return a !== b;
        }
        if (a.source !== b.source) {
            return true;
        }
        var roles = this.fontRoleList();
        var fields = this.fontFieldList();
        for (var i = 0; i < roles.length; i++) {
            var ra = a[roles[i]];
            var rb = b[roles[i]];
            if (!ra || !rb) {
                return true;
            }
            for (var j = 0; j < fields.length; j++) {
                if (ra[fields[j]] !== rb[fields[j]]) {
                    return true;
                }
            }
        }
        return false;
    };

    /*
     * The fifteen values, role-major and field-minor, or null for the whole
     * set.
     *
     * Two deliveries read this -- the object the page gets and the CSS the
     * document carries -- and they have to agree about what a presentable
     * font set is, for the reason themeColorList gives: a set good enough
     * to hand to script and not good enough to put in a stylesheet would be
     * a window whose two accounts of the desktop disagree.
     *
     * Three named checks and not a table indexed by field: a pattern chosen
     * by subscript is a pattern that can be chosen wrong.
     */
    NeutrinoWebview.fontValueList = function (fonts) {
        if (!fonts) {
            return null;
        }
        var roles = this.fontRoleList();
        var out = [];
        for (var i = 0; i < roles.length; i++) {
            var r = fonts[roles[i]];
            if (!r) {
                return null;
            }
            var family = String(r.family);
            if (family !== "" && !this.fontFamilyPattern.test(family)) {
                return null;
            }
            if (!this.inSet(this.fontFamilyTokens, String(r.generic))) {
                return null;
            }
            var size = String(r.size);
            if (!/^[1-9][0-9]{0,2}(\.[0-9]{1,2})?px$/.test(size)) {
                return null;
            }
            var weight = String(r.weight);
            if (!/^([1-9][0-9]{0,2}|1000)$/.test(weight)) {
                return null;
            }
            out[out.length] = this.fontCssValue(family, String(r.generic), roles[i]);
            out[out.length] = size;
            out[out.length] = weight;
        }
        return out;
    };

    /*
     * The set as a JavaScript object literal, for the two places that need
     * one: the preload, where it is the snapshot the page starts with, and
     * the push below, where it is an update.
     *
     * Everything is checked again here even though normalizeFonts built it,
     * and that is the point rather than belt and braces. This and
     * themeLiteral are the only strings the launcher evaluates *into* a
     * page, so the rule parseMessage holds coming in is held going out: a
     * fixed shape, a known key set, and values that match one anchored
     * pattern or the whole update is dropped.
     *
     * The literal carries `family` and `generic` separately, because an app
     * reading `fonts.monospace.family === ""` learns something a composed
     * list would have hidden: that this desktop named no monospace face and
     * the engine's own is what it will get.
     */
    NeutrinoWebview.fontsLiteral = function (fonts) {
        if (!fonts || !this.inSet(this.themeSources, fonts.source)) {
            return null;
        }
        var values = this.fontValueList(fonts);
        if (!values) {
            return null;
        }
        var roles = this.fontRoleList();
        var parts = [];
        var at = 0;
        for (var i = 0; i < roles.length; i++) {
            var r = fonts[roles[i]];
            parts[parts.length] = roles[i] + ':{family:"' + String(r.family) +
                '",generic:"' + String(r.generic) +
                '",stack:"' + values[at] +
                '",size:"' + values[at + 1] +
                '",weight:"' + values[at + 2] + '"}';
            at += 3;
        }
        return '{source:"' + fonts.source + '",' + parts.join(",") + "}";
    };

    NeutrinoWebview.buildFontScript = function (fonts) {
        var literal = this.fontsLiteral(fonts);
        if (!literal) {
            return null;
        }
        return "window.neutrino&&window.neutrino._fonts&&window.neutrino._fonts(" +
            literal + ");";
    };

    /*
     * One place every lane's watcher ends up, and it is shorter than
     * applyTheme by exactly the part that has no counterpart here.
     *
     * There is no repaint and no forceScheme. The two surfaces a palette
     * change has to repaint are flat colour, and the window's title is
     * drawn by the desktop's own frame in the desktop's own font whatever
     * this process does -- so a font change has no native surface to touch
     * and `followsTheme` has no font twin to gate on. This function is the
     * push and nothing else.
     *
     * `win` is not a parameter for that reason. An unused argument that
     * existed only to look like applyTheme would be a promise that
     * something native happens here, and nothing does.
     *
     * The push is allowed to fail. A page that did not get an update still
     * has the set it started with, which is a window one change out of date
     * rather than a window that is gone.
     */
    NeutrinoWebview.applyFonts = function (driver, wv, raw) {
        var next = this.normalizeFonts(raw);
        if (!next) {
            this.noteOnce("could not read the desktop fonts");
            return false;
        }
        if (!this.fontsDiffer(this.fonts, next)) {
            return false;
        }
        this.fonts = next;
        var js = this.buildFontScript(next);
        if (js && driver.evaluate) {
            try {
                driver.evaluate(wv, js);
            } catch (e) {
                this.noteOnce("could not deliver the fonts: " + e);
            }
        }
        return true;
    };
