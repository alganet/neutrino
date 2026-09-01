    NeutrinoWebview.boot = function (driver, config) {
        driver.init();

        /*
         * Before the window, because the window is painted from it and
         * there is exactly one chance to get that right -- a window
         * repainted after it is on screen is the flash, in a different
         * colour.
         *
         * A lane with no reader, or a reader that could not reach its
         * toolkit, leaves this null. That is a build that paints white and
         * hands the page `neutrino.theme === null`, which is what this file
         * did before any of this existed: no worse than it was, and the
         * page can tell.
         */
        if (driver.readTheme) {
            this.theme = this.normalizeTheme(driver.readTheme());
            if (!this.theme) {
                this.note("could not read the desktop palette; using " +
                    this.resolveBackground(null));
            }
        }

        /*
         * And here for the same reason the read is here: before the window,
         * because `prefers-color-scheme` is a value the page's first paint
         * is already styled by. A media query corrected after the document
         * has laid out is the flash again, in the other direction -- the
         * app's dark stylesheet arriving over a light one it already drew.
         *
         * Ungated by followsTheme, unlike the repaint below it. That gate
         * asks whether this build named its own background, and a build
         * that did still gets `neutrino.theme.scheme` and still gets the
         * palette pushed to the page. The scheme the desktop is at is the
         * same reading however this window is painted.
         */
        if (driver.forceScheme) {
            try {
                driver.forceScheme(this.theme);
            } catch (e) {
                this.note("could not force the colour scheme: " + e);
            }
        }

        var scriptPath = driver.getScriptPath();
        var source = driver.readFile(scriptPath);
        var html = this.themedDocument(
            this.titledDocument(
                this.applyContentPolicy(this.extractHtmlDocument(source)),
                config.title),
            this.theme);
        var pageScript = this.extractPageScript(source);

        var win = driver.createWindow(config);

        if (driver.onWebMessage) {
            var self = this;
            var driverRef = driver;
            var winRef = win;
            var actions = {};
            if (driverRef.resize) actions.resize = function (m) { try { driverRef.resize(winRef, m.width, m.height); } catch (_) {} };
            if (driverRef.move) actions.move = function (m) { try { driverRef.move(winRef, m.x, m.y); } catch (_) {} };
            /*
             * The relative pair, resolved here rather than in five drivers.
             * One arithmetic and one clamp, against a reading each driver
             * supplies in whatever units its own resize and move already
             * speak -- which is what lets this be right on macOS both
             * before and after the PR that switches that lane from sizing
             * its frame to sizing its content.
             *
             * The clamp is here and not in the splitter because the
             * splitter sees a delta and cannot know what it is a delta
             * from. A width of zero is a refused window on some toolkits
             * and a crash on others, so the floor is one pixel.
             */
            if (driverRef.getBounds && driverRef.resize) actions.resizeBy = function (m) {
                try {
                    var b = driverRef.getBounds(winRef);
                    if (!b) { return; }
                    var w = b.width + m.width;
                    var h = b.height + m.height;
                    driverRef.resize(winRef, w < 1 ? 1 : w, h < 1 ? 1 : h);
                } catch (_) {}
            };
            if (driverRef.getBounds && driverRef.move) actions.moveBy = function (m) {
                try {
                    var p = driverRef.getBounds(winRef);
                    if (!p) { return; }
                    driverRef.move(winRef, p.x + m.x, p.y + m.y);
                } catch (_) {}
            };
            if (typeof driverRef["close"] === "function") actions["close"] = function (m) { try { driverRef["close"](winRef); } catch (_) {} };
            if (driverRef.openExternal) actions.openExternal = function (m) { try { driverRef.openExternal(m.url); } catch (_) {} };
            driver.onWebMessage(function (json) {
                self.routeMessage(actions, json);
            });
        }

        /*
         * Every driver injects through its engine now, so the preload is
         * never spliced into the markup as text. The old splice looked for
         * a literal "<head>" and silently injected nothing when it did not
         * find one, which meant the API could go missing without anything
         * saying so.
         */
        if (driver.webMessageTransport) {
            driver.injectPreload(null, this.buildPreloadScript(
                driver.webMessageTransport, driver.transportName,
                this.themeLiteral(this.theme)));
        }

        if (driver.injectPageScript) {
            driver.injectPageScript(pageScript);
        }

        var wv = driver.createWebView();

        driver.loadHTML(wv, html, scriptPath);
        driver.attachWebView(win, wv);
        driver.showWindow(win);
        driver.runEventLoop(win, wv);
    };

    NeutrinoWebview.runMacOS = function () {
        // Any one of the bridge calls in this driver failing leaves no
        // window at all, which is the least informative outcome available.
        try {
            this.boot(this.createMacDriver(), this.config);
        } catch (e) {
            this.note("could not start: " + e);
            throw e;
        }
    };

    NeutrinoWebview.runGjs = function () {
        /*
         * An interpreter with imports.gi is not an interpreter that can
         * reach GTK and WebKit2: the typelibs are separate packages, and a
         * GNOME box without gir1.2-webkit2 has the first and not the
         * second. That used to be a traceback and the end of the launch,
         * with the shell's `elif` chain already committed -- so a machine
         * with a working qml6 sitting next to a broken gjs got no window at
         * all. One line and the reserved status instead, and the walk
         * carries on to the engine that does work.
         *
         * Anything not tagged is the app's own failure and keeps its
         * traceback, because that is a program to debug and not a lane to
         * skip.
         */
        try {
            this.boot(this.createGjsDriver(), this.config);
        } catch (e) {
            if (!e || !e.neutrinoEngineUnavailable) {
                throw e;
            }
            this.note("this interpreter cannot reach GTK and WebKit2: " +
                (e.message ? e.message : e));
            eval("imports")["system"]["exit"](69);
        }
    };

