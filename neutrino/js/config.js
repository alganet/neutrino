    var NeutrinoWebview = {
        // The tier list is stamped here by build.sh and read back out of this
        // file by the shell section, so all three languages in this polyglot
        // see one value and there is nothing in the environment that can be set
        // to talk any of them out of it. A release build has no way to be
        // talked into "testing".
        //#TIER_START
        tiers: "default",
        //#TIER_END

        /*
         * What the native window needs before there is a document to read it
         * from, and nothing else. createWindow runs on every lane before
         * loadHTML, so these three cannot come from the markup the way the
         * style and the body now do -- there is no document yet when they are
         * asked for.
         *
         * `url` used to sit here and had not been read by anything since the
         * launcher stopped navigating to a remote page. It is gone rather than
         * kept, because a config entry nothing consumes reads as a feature.
         *
         * `background` is the fourth for the same reason the other three are
         * here: it is wanted before there is a document. Two surfaces are up
         * ahead of the first paint -- the native window, and the view inside it
         * -- and neither of them can be reached from a stylesheet. Measured on
         * WebKitGTK with the load held back: the window is the theme's bare
         * background, #F6F5F4 under Adwaita, and the view adds about two frames
         * of its own on top. Both of them are white on a default desktop, and
         * both are what the app was seen through before it painted.
         *
         * It does not touch the document. An author sets it to whatever their
         * own CSS paints, and the two are deliberately separate: this is the
         * colour of the frame the app has not arrived in yet, not a rule in
         * anybody's stylesheet.
         *
         * `auto` is the value that is not a colour, and it is what a build that
         * names no background carries. It means the colour is not known at
         * assembly because it is not a property of the app: it is a property of
         * the desktop the app is launched on, and resolveBackground reads it
         * there, from the palette readTheme took off the running toolkit. An
         * author who wants one fixed colour on every machine says so with
         * --background and gets exactly that, on every machine, forever.
         *
         * `decorations` is the fifth, and it is here because a frame is chosen
         * when a window is constructed rather than adjusted afterwards: a style
         * mask, a GtkWindow construct property, a QML `flags` value and a
         * FormBorderStyle are each read once, at the call createWindow makes.
         *
         * `none` takes the title bar and the borders, and it takes the drag
         * handle, the resize edge and the window manager's snapping with them,
         * because those are things the frame was providing. An app that asks
         * for it draws its own and moves itself with `moveBy` and `resizeBy`,
         * which every lane already carries -- that is the whole of what is
         * offered here, and the launcher adds no verb for it. `auto` is the
         * frame the desktop would have given the window anyway.
         *
         * Stamped by build.sh between the sentinels, the way the tier list is,
         * and for the same reason: one value, read by five lanes, with nothing
         * in the environment able to talk any of them out of it.
         */
        //#CONFIG_START
        config: {
            title: "neutrino",
            width: 900,
            height: 600,
            background: "auto",
            decorations: "auto"
        }
        //#CONFIG_END
    };

    NeutrinoWebview.hasTier = function (name) {
        return ("," + String(this.tiers || "default") + ",").indexOf("," + name + ",") >= 0;
    };

