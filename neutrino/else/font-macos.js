    /*
     * The macOS fonts, and this is the lane with the most to say.
     *
     * NSFont names thirteen roles and gives every one of them a distinct
     * size -- system 13, small 11, label 10, user 12, fixed-pitch 11 --
     * where GTK needs three GSettings schemas to reach three of them, Qt
     * exposes exactly one, and Windows names six that measured identical.
     * So this lane is the ceiling of the normalized set, and the five roles
     * fonts.js carries are the five that had a real, distinct answer here.
     *
     * It is also the lane with the trap. Eleven of those thirteen report a
     * familyName of `.AppleSystemUIFont`: a dot-prefixed hidden family that
     * WebKit **refuses by name, silently**, falling through to whatever
     * comes next in the list and reporting nothing. A launcher that shipped
     * it would deliver a family the engine ignores and would never hear
     * about it. The CSS spelling of that face is the token `system-ui`, so
     * this is the one lane that needs a name *translation* rather than a
     * name.
     *
     * Two of the thirteen are real names and pass through: `userFontOfSize`
     * is Helvetica 12 -- TextEdit's own default, which is why the document
     * role delivers it rather than falling back -- and
     * `userFixedPitchFontOfSize` is Menlo 11.
     */

    /*
     * The five roles, and the NSFont class method each is read from. Size
     * `0` means "the standard size for this role" and not a zero-point
     * font; `small` is the system face asked for at the small system size,
     * which is what that role *is* on this platform -- same face, 11 rather
     * than 13.
     */
    NeutrinoWebview.macFontRoles = "ui:systemFontOfSize,document:userFontOfSize," +
        "monospace:userFixedPitchFontOfSize,titlebar:titleBarFontOfSize," +
        "small:smallSystemFont";

    /*
     * AppKit's weight scale to CSS's.
     *
     * `NSFontManager.weightOfFont:` answers 0..15 where 5 is regular and 9
     * is bold, and measured on the runner every regular role came back 5
     * and both bold ones -- `titleBar` and `boldSystem` -- came back 9.
     *
     * It is read from the font manager and not from the descriptor because
     * `fontDescriptor.objectForKey(NSFontTraitsAttribute)` answered nothing
     * at all for all thirteen roles: a system font's descriptor carries no
     * traits dictionary until one is asked for explicitly.
     *
     * And it matters for exactly one role. `titleBar` and `ui` report the
     * same family and the same 13 points and differ only in their
     * PostScript name -- `.AppleSystemUIFaceHeadline` against
     * `.AppleSystemUIFont`, "System Font Bold" against "System Font
     * Regular". A titlebar role carrying family and size alone would
     * deliver a regular face where the desktop draws a bold one.
     */
    NeutrinoWebview.macWeightSteps = "0:100,1:100,2:200,3:300,4:350,5:400," +
        "6:500,7:600,8:600,9:700,10:800,11:800,12:900,13:900,14:900,15:900";

    /*
     * macOS points are CSS pixels.
     *
     * NSFont.systemFontSize is 13 and renders as 13px in WKWebView, so this
     * lane does not get the 4/3 the other three do. Named here beside the
     * three lanes that do multiply, so the asymmetry is visible rather than
     * buried in whichever expression happens to omit it.
     */
    NeutrinoWebview.macFontUnit = "px";

    /*
     * One role's font, taken apart.
     *
     * A dot-prefixed family delivers no name and the `system-ui` token
     * instead. That translation is here, but it is not the only thing
     * standing between a hidden family and a page: fontFamilyPattern in
     * fonts.js refuses a leading full stop outright, so a name that got
     * past this would be refused there rather than silently ignored by the
     * engine. Two answers to one hazard, deliberately, because the failure
     * this prevents is invisible.
     */
    NeutrinoWebview.readMacFont = function (ObjCRef, dollar, font) {
        if (!font) {
            return null;
        }
        var out = { family: "", generic: "", size: "", weight: "" };
        try {
            var family = String(ObjCRef.unwrap(font.familyName) || "");
            if (family.charAt(0) === ".") {
                out.generic = "system-ui";
            } else if (family !== "") {
                out.family = family;
            }
            out.size = font.pointSize;
        } catch (e) {
            return null;
        }
        try {
            var step = dollar.NSFontManager.sharedFontManager.weightOfFont(font);
            var mapped = this.fontLookup(this.macWeightSteps, String(Math.round(step)));
            if (mapped !== "") {
                out.weight = mapped;
            }
        } catch (_) {}
        return out;
    };

    /*
     * The read.
     *
     * `setCurrentAppearance` is deliberately *not* called here, and the
     * difference from readMacTheme is the point. That function has to set
     * it because NSColor's system colours resolve against the current
     * appearance and JXA has no drawing context, so a nil appearance
     * silently reports light colours on a dark Mac -- a defect that cost
     * that lane a whole live-watcher round.
     *
     * Nothing here is documented as appearance-resolved: a family, a point
     * size and a weight are not per-appearance the way a colour is. That is
     * a reading of the API and not a measurement -- the probe has only ever
     * run on a light runner -- so it is stated as the reasoning it is. What
     * would settle it is one probe run under each appearance with the
     * thirteen sizes and weights compared; if they ever differ, the call
     * belongs here after all and this comment is the thing that was wrong.
     *
     * A role that answers nothing is left out rather than filled, and
     * normalizeFonts takes it. `ui` answering nothing is the whole read
     * failing, which is what its check there enforces.
     */
    NeutrinoWebview.readMacFonts = function (ObjCRef, dollar) {
        var pairs = String(this.macFontRoles).split(",");
        var raw = { source: "macos", unit: this.macFontUnit };
        var found = 0;
        for (var i = 0; i < pairs.length; i++) {
            var cut = pairs[i].indexOf(":");
            var role = pairs[i].substring(0, cut);
            var name = pairs[i].substring(cut + 1);
            var font = null;
            try {
                font = (name === "smallSystemFont")
                    ? dollar.NSFont.systemFontOfSize(dollar.NSFont.smallSystemFontSize)
                    : dollar.NSFont[name](0);
            } catch (e) {
                this.noteOnce("no NSFont answered to " + name + ": " + e);
                continue;
            }
            var got = this.readMacFont(ObjCRef, dollar, font);
            if (!got) {
                this.noteOnce("could not read the " + role + " font");
                continue;
            }
            found++;
            raw[role + "Family"] = got.family;
            raw[role + "Generic"] = got.generic;
            raw[role + "Size"] = got.size;
            raw[role + "Weight"] = got.weight;
        }
        if (!found) {
            return null;
        }
        return raw;
    };
