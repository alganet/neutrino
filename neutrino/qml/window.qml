import QtQuick
import QtWebEngine

Window {
    id: root

    // The polyglot's own source, read once, by XHR rather than by import:
    // this document has no directory for an import to resolve against, which
    // is the point of it.
    readonly property string ntSource: ntRead()
    readonly property var nt: ntBuild(ntSource)
    readonly property var cfg: nt.config

    // Encoded for the same reason the Windows title is: a record separator is
    // a control character, and a console message is a diagnostic channel that
    // nothing promises will carry one through Chromium and out the other side
    // unchanged.
    readonly property string ntPreload: nt.buildPreloadScript(
        'function(m){console.log("__NEUTRINO__"+encodeURIComponent(m));}',
        "console",
        // In the preload rather than pushed after it, so the page has the
        // palette at document start. This is a binding like everything else
        // here, so a desktop that changes its colours between this document
        // loading and the view injecting still hands over the current one.
        nt.themeLiteral(root.ntTheme),
        // And the fonts, which unlike the palette will never be replaced on
        // this lane -- see ntFonts.
        nt.fontsLiteral(root.ntFonts))

    // The desktop's palette, read once. Everything downstream of it -- the
    // window colour, the view colour, the push below -- is a binding, so a
    // palette that moves carries to all three with no signal connected
    // anywhere.
    //
    // On KDE it moves, and the bindings are the whole watcher. Measured in a
    // Fedora 42 container, Qt 6.10.2, plasma-integration 6.6.4, with
    // KDEPlasmaPlatformTheme6.so confirmed loaded in the plugin loader log
    // rather than assumed. `plasma-apply-colorscheme` under a running
    // process, one launch:
    //
    //   start                      window=#eff0f1 text=#232629 scheme=1
    //   change#1 window            window=#202326 text=#fcfcfc
    //   change#2 highlight
    //   change#3 palette
    //   change#4 colorScheme                                    scheme=2
    //
    // Four signals for one flip: SystemPalette's per-property notifies, its
    // whole-palette notify, and QStyleHints::colorScheme. The palette lands
    // first and colorScheme catches up after, so a reader that wants the two
    // to agree should read the palette and derive, which is what this file
    // already does. Autodetected the same way from XDG_CURRENT_DESKTOP=KDE
    // with QT_QPA_PLATFORMTHEME unset, which is what a KDE user actually has.
    //
    // The channel is the DBus change notification, not the file. Writing
    // kdeglobals with kwriteconfig6 and no --notify moved the file and fired
    // nothing -- so a probe that edits kdeglobals by hand reports a false
    // negative on a KDE that works. System Settings and
    // plasma-apply-colorscheme both notify; that is the knob to test with.
    //
    // Under QGtk3Theme it does not move, and that is a fact about the plugin
    // rather than about the lane. Qt asks its platform theme for the palette,
    // and that one does not rebuild one when the desktop moves. On Qt 6.4.2
    // with QGtk3ThemePlugin loaded, one job, three launches:
    //
    //   Net/ThemeName=Adwaita-dark before launch    window=#323232
    //   GTK_THEME=Adwaita-dark                      window=#323232
    //   the same flipped under a running process    window=#efefef, 0 changes
    //
    // So XSettings is a channel Qt reads at startup and that plugin never
    // reads again. There is no repair to make there from here: polling
    // SystemPalette would re-read the same stale value, and QGuiApplication
    // has no earlier signal to connect that this does not already sit
    // downstream of. It is the platform theme's to fix, and KDE's has.
    //
    // What works on both is every launch: an app started after a theme change
    // gets the new palette, which is what the suite's two halves assert.
    SystemPalette {
        id: sysPalette
        colorGroup: SystemPalette.Active
    }

    // A QML colour carries its components as reals, so it goes to the
    // launcher's own toHex and flattenColor rather than being formatted here.
    // Four other lanes read a palette and all five have to agree about what a
    // colour is.
    function ntHex(c, over) {
        return root.nt.flattenColor(
            root.nt.toHex({ red: c.r, green: c.g, blue: c.b }), c.a, over)
    }

    // Read at the binding site rather than inside, so the dependency on each
    // palette entry is captured here and cannot be lost to a refactor of the
    // function below.
    readonly property var ntTheme: root.ntReadTheme(
        sysPalette.window, sysPalette.windowText, sysPalette.base, sysPalette.text,
        sysPalette.highlight, sysPalette.highlightedText, sysPalette.mid)

    /*
     * The desktop's fonts, read once, and read once is all this lane gets.
     *
     * `Qt.application.font` is the only font QML exposes.
     * QPlatformTheme::font carries a dozen more -- menu, title bar, fixed --
     * and none of them is reachable from here, so four of the five roles
     * take the fill rule in normalizeFonts.
     *
     * The read is at the binding site, as ntTheme's is, and here that buys
     * nothing -- which is the point worth writing down rather than leaving
     * to look like an oversight.
     *
     * **This lane is launch-only for fonts, and it is measured rather than
     * assumed.** `Connections { target: Qt.application; function
     * onFontChanged() }` is the spelling the property implies, and Qt
     * refused it in as many words on the runner: "no signal of the target
     * matches the name". So there is no NOTIFY QML can reach and a binding
     * on it would never re-evaluate. Polling settled the other half: the
     * value did not move in eight seconds across a `kwriteconfig6 --notify`
     * write of [General] font, on real Plasma 6, with
     * KDEPlasmaPlatformTheme6 confirmed loaded in the plugin loader log
     * rather than assumed. That is the strongest form the negative takes on
     * this lane -- the palette round established that the same channel does
     * move a colour scheme, so it is this property that is not on it.
     *
     * There is therefore no `onNtFontsChanged` below, and an empty one
     * would be worse than none: it would compile, read correctly, and never
     * run -- code that looks like a guarantee and is not, which is the
     * shape the macOS observer's NSNull defect had for a whole round. If Qt
     * ever gains the notify, ntFonts is already a binding and the handler
     * is three lines.
     */
    readonly property var ntFonts: root.ntReadFonts(
        Qt.application.font.family,
        Qt.application.font.pointSize,
        Qt.application.font.pixelSize,
        Qt.application.font.weight)

    /*
     * pixelSize where Qt gives one, and it usually does.
     *
     * A QFont answers -1 for whichever of the two sizes it was not set
     * with, which is the hazard a reader has to expect -- but what QML
     * hands out carries both: measured "Noto Sans" pointSize=10
     * pixelSize=13 on real Plasma, and "Sans Serif" 9/12 under QGtk3Theme.
     * pixelSize is what Qt will actually render at and is CSS px directly,
     * so it is preferred and the point size is the fallback.
     */
    function ntReadFonts(family, pointSize, pixelSize, weight) {
        var raw = { source: "qt" }
        if (pixelSize > 0) {
            raw.unit = "px"
            raw.uiSize = pixelSize
        } else if (pointSize > 0) {
            raw.unit = "pt"
            raw.uiSize = pointSize
        } else {
            return null
        }
        // Qt 6's QFont::Weight is already the CSS 1..1000 scale --
        // Normal is 400 and Bold is 700 -- and this document is Qt 6 by
        // construction, since it imports QtQuick unversioned beside
        // QtWebEngine.
        raw.uiWeight = weight

        /*
         * Qt's own generic names, which it hands back as families exactly
         * the way Pango hands back "Sans".
         *
         * Measured on both Qt runners this suite has: `Sans Serif` under
         * QGtk3Theme, where it is Qt's default rather than anything the
         * desktop said. `font-family: "Sans Serif"` matches nothing in any
         * engine here, so shipping it as a name would deliver a family the
         * engine ignores and fall through to the tail -- which works, and
         * is a name in the API that means nothing. Saying "no family, this
         * generic" is the honest reading and it is what the alias meant.
         *
         * Real Plasma reports "Noto Sans" through the same property and is
         * unaffected.
         */
        var name = String(family || "")
        var alias = root.nt.fontLookup(root.nt.qtFontAliases, name)
        if (alias !== "") {
            raw.uiFamily = ""
            raw.uiGeneric = alias
        } else {
            raw.uiFamily = name
        }
        return root.nt.normalizeFonts(raw)
    }

    // The parameters are named for the palette entries they carry rather than
    // for the SystemPalette properties they came from -- window is a name
    // with meaning in a QML document and this is not that window.
    function ntReadTheme(bgColor, fgColor, baseColor, textColor,
                         accentColor, accentTextColor, borderColor) {
        // The background first, because the rest are flattened over it.
        var bg = root.nt.toHex({ red: bgColor.r, green: bgColor.g, blue: bgColor.b })
        return root.nt.normalizeTheme({
            source: "qt",
            background: root.ntHex(bgColor, bg),
            foreground: root.ntHex(fgColor, bg),
            base: root.ntHex(baseColor, bg),
            text: root.ntHex(textColor, bg),
            accent: root.ntHex(accentColor, bg),
            accentText: root.ntHex(accentTextColor, bg),
            border: root.ntHex(borderColor, bg)
        })
    }

    // Only the push needs saying out loud. There is no diff here and none is
    // needed: a binding does not re-evaluate unless something it reads has
    // changed, which is the check the other lanes have to make for themselves.
    onNtThemeChanged: {
        if (!view.documentLoaded) {
            // Before the commit there is no document of ours to evaluate into,
            // and nothing is lost -- the preload above carries the snapshot.
            return
        }
        var js = root.nt.buildThemeScript(root.ntTheme)
        if (js) {
            view.runJavaScript(js)
        }
    }

    visible: true
    title: cfg.title

    // Through the launcher's own predicate, the way every other value on this
    // window is: nt is this file's JavaScript and it answers the question the
    // other four lanes ask it.
    //
    // Qt.Window is named rather than left out. An unset flags property is not
    // the same as one set to Qt.Window on every platform, and a frameless hint
    // on its own is a window with no type; the pair is what Qt documents for a
    // top-level that wants no frame.
    //
    // No backticks in this comment, and none anywhere in this document: the
    // here-document that carries it is unquoted, so a backtick is a command
    // the shell runs on the way past. parse.sh checks, which is how these
    // three lines were caught.
    flags: root.nt.undecorated() ? (Qt.Window | Qt.FramelessWindowHint) : Qt.Window

    // The two surfaces that are up before the document, the same pair every
    // other lane paints. A QML colour property reads #rrggbb itself, so this
    // is the string the launcher resolves -- the config's, when the build named
    // one, and the desktop's base when it did not.
    //
    // A binding and not an assignment, which is the whole of this lane's
    // repaint: when the palette changes the window colour changes with it, and
    // the view below follows the window.
    color: root.nt.resolveBackground(root.ntTheme)

    function ntRead() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "$qml_url", false)
        xhr.send()
        return xhr.responseText
    }

    // A Function body is the scope .pragma library used to provide. The flag
    // the source dispatches on goes in as a parameter, so nothing it defines
    // arrives as a global of this document's.
    function ntBuild(src) {
        return (new Function("NeutrinoQml", src + "; return NeutrinoWebview;"))(true)
    }

    // The window's own chrome, measured, because this is the one lane that
    // cannot ask for it.
    //
    // QML's Window.x and Window.y are QWindow::position, which Qt documents as
    // the corner of the window *excluding* its frame -- and on x11 that is not
    // a report, it is a request: qxcbwindow.cpp sets win_gravity to
    // XCB_GRAVITY_STATIC unless the window's position policy is frame
    // inclusive, so the window manager lands the client where it was asked and
    // the decoration goes wherever it fits, which for moveTo(0,0) is off the
    // top of the screen. QWindow::setFramePosition is the other half of that
    // pair and it is C++ only: not a Q_PROPERTY, not a slot, not Q_INVOKABLE,
    // so no QML document can reach it.
    //
    // Every other lane moves the frame -- gtk_window_move, NSWindow's
    // setFrameDisplay, Form.Location -- so until this round moveTo meant one
    // thing on four lanes and another on this one, and the kde sheet has been
    // carrying the picture of it: 04-step3.png is a 500x400 window whose
    // content starts at 0,0 with its title bar and left border off the screen,
    // while the gjs sheet's same shot has the decoration at 0,0 and the
    // content at 0,37.
    //
    // The margins come back from the engine because that is where they are
    // reachable. window.screenX and window.screenY under QtWebEngine are
    // QWindow::framePosition, so root.x minus screenX is QWindow::frameMargins
    // by another road -- both sides of the subtraction are Qt's own numbers,
    // and no window manager round trip sits between them. Measured on the
    // openbox lane, decorated: client 62,84 against screenX 61,64, with
    // _NET_FRAME_EXTENTS reading l=1 t=20. On the chromeless half of the same
    // job both readings are 62,84 and this arithmetic produces the zero that
    // is the right answer there.
    //
    // In an isolated world, so the page cannot answer for its own window. A
    // document can already move the window wherever it likes -- that is the
    // API -- but it should not be able to bend where every *other* move lands
    // by redefining a property on its own global.
    property int ntFrameL: 0
    property int ntFrameT: 0

    // Read once, when the first document commits, and not again: the frame's
    // thickness does not change while a window is up -- verify-std.sh asserts
    // exactly that and calls a run where it moved unreadable -- and a re-read
    // taken while a move is still in flight would be two numbers from either
    // side of it. It is taken before the preload goes in, so it is in hand
    // before any page script exists to ask for a move.
    function ntReadFrame() {
        view.runJavaScript("[window.screenX,window.screenY]", root.ntWorld(),
            function (p) {
                if (!p || p.length !== 2) {
                    console.warn("neutrino: the engine did not say where this"
                        + " window's frame is; a move will place the content")
                    return
                }
                var l = root.x - p[0]
                var t = root.y - p[1]
                if (!isFinite(l) || !isFinite(t) || l < 0 || t < 0
                        || l > 200 || t > 200) {
                    console.warn("neutrino: refused a frame margin of "
                        + l + "," + t + "; a move will place the content")
                    return
                }
                root.ntFrameL = l
                root.ntFrameT = t
                console.warn("neutrino: this frame measures l=" + l + " t=" + t)
            })
    }

    // Named through the enum where the import provides it, and 1 where it does
    // not. The number is the one Qt has always given ApplicationWorld, and the
    // fallback is here rather than the bare enum because an unresolved name in
    // a QML *expression* is a ReferenceError this catches, while the same name
    // in a declared handler is a document that does not load at all -- the
    // lesson newWindowRequested cost this file one round further down.
    function ntWorld() {
        var id
        try {
            id = WebEngineScript.ApplicationWorld
        } catch (e) {
            id = undefined
        }
        return (typeof id === "number") ? id : 1
    }

    function ntRoute(raw) {
        var msg = root.nt.parseMessage(raw)
        if (!msg) {
            console.warn("neutrino: refused a malformed record")
            return
        }
        if (msg.action === "resize") { root.width = msg.width; root.height = msg.height }
        // The frame's corner, spelled in the units this lane's x and y speak.
        else if (msg.action === "move") {
            root.x = msg.x + root.ntFrameL
            root.y = msg.y + root.ntFrameT
        }
        // Relative, against the same properties the two above set. No reader
        // needed here: on this lane the window's geometry is the window's own
        // bindable state, which is why boot's generic pair is not what serves
        // this driver. No frame arithmetic either, and that is not an omission:
        // a delta moves the client and the frame by the same number, so the
        // margins the absolute verb above adds would cancel here.
        else if (msg.action === "resizeBy") {
            root.width = Math.max(1, root.width + msg.width)
            root.height = Math.max(1, root.height + msg.height)
        }
        else if (msg.action === "moveBy") { root.x = root.x + msg.x; root.y = root.y + msg.y }
        else if (msg.action === "close") root.close()
        else if (msg.action === "openExternal") Qt.openUrlExternally(msg.url)
    }

    // The content is what gets centred here, and it is the one place on this
    // lane where that is the honest answer: there is no document yet, so there
    // is nothing to read the frame off, and the first window is on screen
    // before anything can be asked. The window therefore opens a title bar's
    // height above where the GTK lanes open theirs. Nothing asserts the
    // opening position -- the suites assert where a move lands -- and a launch
    // that jumped by twenty pixels once the page committed would be a worse
    // thing to look at than a window centred on its content.
    Component.onCompleted: {
        root.width = cfg.width
        root.height = cfg.height
        root.x = (Screen.width - root.width) / 2
        root.y = (Screen.height - root.height) / 2
    }

    WebEngineView {
        id: view
        anchors.fill: parent
        backgroundColor: root.color
        property bool preloadInjected: false
        property bool documentLoaded: false
        property bool contentLoaded: false
        // This lane's half of the title hook. title is a WebEngineView
        // property that follows the loaded document, so the signal is the one
        // QML generates for it and nothing has to be connected by hand.
        //
        // The assignment is what breaks the binding to cfg.title above, and
        // that is the point: from the first title this document names, the
        // window is following the document. Until then the binding holds, and
        // the gate refuses the empty title a document that names nothing
        // reports.
        onTitleChanged: {
            var name = root.nt.acceptDocumentTitle(view.url, view.title)
            if (name !== null) {
                root.title = name
            }
        }
        onLoadingChanged: function(info) {
            if (info.status === WebEngineView.LoadSucceededStatus) {
                if (!preloadInjected) {
                    preloadInjected = true
                    // Before the injection, not after: from the next line on
                    // there is page script in this view that can send.
                    root.nt.rememberTrustedView(view.url)
                    // Also before it, and for the same reason spelled the
                    // other way round: this is the last moment in the run when
                    // nothing in the view can have moved the window yet.
                    root.ntReadFrame()
                    // The API first, then the page's own code. Both are handed
                    // to the engine rather than carried by the document, which
                    // is what lets the document forbid script of its own.
                    view.runJavaScript(root.ntPreload)
                    view.runJavaScript(root.nt.extractPageScript(root.ntSource))
                }
                view.documentLoaded = true
            }
        }
        onJavaScriptConsoleMessage: function(level, message, lineNumber, sourceID) {
            if (String(message).indexOf("__NEUTRINO__") !== 0) {
                // Overriding this signal replaces Qt's own handler, so without
                // this every error the page reports goes nowhere and a broken
                // document looks identical to a silent one.
                console.warn("neutrino page: " + message + " (" + sourceID + ":" + lineNumber + ")")
                return
            }
            // The sender check. Qt routes a console message from whatever
            // document is loaded, and this is the only thing that asks which
            // one that is.
            if (!root.nt.isTrustedView(view.url)) {
                root.nt.note(
                    "refused a message from a document the view was not given")
                return
            }
            root.ntRoute(decodeURIComponent(String(message).substring(12)))
        }
        // A link with a target, which on this engine is a different signal from
        // the one below and was reaching nothing.
        //
        // QtWebEngine raises it for <a target=_blank> and for window.open;
        // navigationRequested is raised for neither, so the guard underneath
        // this had never seen one. Doing nothing is already a refusal -- a
        // request never handed to a view creates none -- so what this adds is
        // the forwarding the two GTK drivers have always done with
        // NEW_WINDOW_ACTION, and the line that says it happened.
        //
        // Connected by hand rather than declared as onNewWindowRequested, and
        // the reason is a round this cost. The signal is newWindowRequested
        // here and was newViewRequested in Qt 5; a declarative handler names
        // the signal at *load* time, so the wrong name is not a hook that does
        // nothing -- it is "Cannot assign to non-existent property" and the QML
        // document does not load at all. Every suite on the lane then reports
        // that no window ever appeared, which is a true sentence pointing
        // nowhere near the cause. Connecting from script degrades instead: an
        // engine with neither name gets a note and a window.
        //
        // Both names are tried and the one that took is reported, so the log
        // carries which signal this engine actually has rather than which one
        // this file assumed.
        function ntConnectNewWindow() {
            var names = ["newWindowRequested", "newViewRequested"]
            for (var i = 0; i < names.length; i++) {
                var sig = view[names[i]]
                if (sig && typeof sig.connect === "function") {
                    sig.connect(ntOnNewWindow)
                    console.warn("neutrino: new windows arrive on " + names[i])
                    return
                }
            }
            console.warn("neutrino: this QtWebEngine raises no new-window signal this file knows;"
                + " a link with a target will open nothing and go nowhere")
        }

        // mayOpenExternal and not isExternalUrl, the same as below: refusing a
        // window and then handing its url to the desktop's browser is the page
        // reaching the network without having asked, which is the one thing the
        // offline tier exists to stop.
        //
        // userInitiated is carried and not acted on. It is the engine's own
        // answer to whether a person did this, and it is the thing that makes a
        // synthesised click and a real one different readings -- worth having
        // in the log on the one lane that offers it, and not a rule, because no
        // other lane can say it.
        function ntOnNewWindow(request) {
            var wanted = String(request.requestedUrl)
            var byUser = "?"
            try { byUser = String(request.userInitiated) } catch (e) { byUser = "?" }
            console.warn("neutrino: refused a new window for " + wanted
                + " (userInitiated=" + byUser + ")")
            if (root.nt.mayOpenExternal(wanted)) {
                Qt.openUrlExternally(request.requestedUrl)
            }
        }
        // The document is loaded once, from this file, and never navigates
        // again. Without this a link or a script assignment could replace it
        // with a remote origin, and that origin would then be holding the
        // channel to the native window. http and https go to the desktop's
        // handler instead, which is what a user clicking a link expects;
        // everything else is refused, including file: and the schemes the
        // platform keeps inventing.
        onNavigationRequested: function(request) {
            var target = String(request.url)
            if (root.nt.isOwnDocument(target)) {
                return
            }
            // QtWebEngine hands this file's document to the view by navigating
            // to a data: url, so exactly one of those is the app arriving and
            // every one after it is a page moving itself somewhere this cannot
            // tell apart by origin. Allowing the first and refusing the rest is
            // the difference between naming the engine's own mechanism and
            // leaving the same-null-origin hole open for anyone to walk through.
            if (target.indexOf("data:") === 0 && !view.contentLoaded) {
                view.contentLoaded = true
                return
            }
            console.warn("neutrino: refused navigation to " + request.url)
            if (typeof request.reject === "function") {
                request.reject()
            } else {
                request.action = WebEngineNavigationRequest.IgnoreRequest
            }
            // mayOpenExternal and not isExternalUrl: refusing a navigation
            // and then handing the same url to the desktop's browser is the
            // page reaching the network without having asked, which is the one
            // thing the offline tier exists to stop.
            if (root.nt.mayOpenExternal(String(request.url))) {
                Qt.openUrlExternally(request.url)
            }
        }
        Component.onCompleted: {
            // Inside a try, and that is the same lesson one line further on.
            // Whatever goes wrong while wiring a hook must not stop the
            // document from loading: this block is what puts the app on
            // screen, and a throw here is a lane with no window in any suite
            // and no line saying why.
            try { ntConnectNewWindow() } catch (e) {
                console.warn("neutrino: could not connect the new-window signal: " + e)
            }
            view.loadHtml(root.nt.dressedDocument(
                root.nt.titledDocument(
                    root.nt.extractHtmlDocument(root.ntSource),
                    cfg.title),
                root.ntTheme, root.ntFonts))
        }
    }
}
