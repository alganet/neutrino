    /*
     * What counts as the app's own document is not the same on every
     * engine, and getting that wrong is silent in the worst way: gjs loads
     * with a null base url and its document has no origin at all, while
     * this driver loads with the script's directory as a file: base so that
     * an app's relative assets resolve. Demanding an empty scheme therefore
     * refused every message the app itself sent, and left a window that
     * came up and then did nothing.
     *
     * So the rule is about the host, not the scheme: a document that can
     * speak to the network has one, and neither of these has one. A page
     * the webview navigated to somewhere remote is refused, which is the
     * escape worth closing.
     *
     * The origin alone is not enough, though, because a data: document has
     * no origin either -- it is the one navigation an origin check cannot
     * tell from the app's own document, and the preload here is a user
     * script the engine reinjects into whatever loads next, so the page
     * that arrives inherits the whole API. So what the view is currently
     * showing is checked as well, which is a question a message cannot lie
     * about.
     *
     * The residual left is another file: document, which is local content
     * rather than a remote origin.
     */
    NeutrinoWebview.isTrustedOrigin = function (scheme, host) {
        var s = String(scheme == null ? "" : scheme);
        var h = String(host == null ? "" : host);
        return h === "" && (s === "" || s === "file");
    };

    NeutrinoWebview.isTrustedMacSender = function (ObjCRef, message, webView) {
        /*
         * What the view is showing, independent of what the message claims.
         *
         * Nothing here fails open any more. The document to trust is
         * remembered at didCommitNavigation: now -- the load this file
         * started, before the page script the engine injects at document
         * end can run -- so a message arriving with nothing remembered is
         * not an app still getting going. Remembering it here instead, as
         * this did while the driver had no delegate to hang one on, meant a
         * page that navigated before the app ever spoke was the one that
         * got remembered.
         *
         * A bridge that will not answer is refused for the same reason. It
         * leaves a window that does nothing, which was the objection -- so
         * it says which call would not answer, and an inert window that
         * explains itself is not the failure that objection was about.
         */
        try {
            var current = webView.URL;
            var currentScheme = current
                ? String(ObjCRef.unwrap(current.scheme) || "") : "";
            var currentUrl = current
                ? String(ObjCRef.unwrap(current.absoluteString) || "") : "";
            if (!this.isTrustedOrigin(currentScheme, "")) {
                this.note("refused a message from a document at " +
                    currentScheme + ":");
                return false;
            }
            // And the same document, not merely the same kind of one.
            if (!this.isTrustedView(currentUrl)) {
                this.note("refused a message from " +
                    (currentUrl === "" ? "a view showing nothing" : currentUrl));
                return false;
            }
        } catch (e) {
            this.note("refused a message: could not read what the view is " +
                "showing: " + e);
            return false;
        }

        var frame = null;
        try {
            frame = message.frameInfo;
            if (!frame.isMainFrame) {
                this.note("refused a message from a subframe");
                return false;
            }
        } catch (e) {
            this.note("refused a message with no frame: " + e);
            return false;
        }

        /*
         * The sender's own account of itself, kept separate from reading
         * the frame because the two used to fail differently: a frame that
         * cannot be read is a message with no sender, while an origin that
         * cannot be read was this bridge not exposing something it was
         * expected to, and refusing on that would have muted the app over a
         * bridge quirk.
         *
         * They no longer fail differently, because the premise was
         * measured and did not hold: across every arrangement of the macOS
         * probe -- four navigation targets, a document that arrived from a
         * remote origin, and a view with nothing loaded at all -- the read
         * never once threw. A catch insuring against something that does
         * not happen, at the price of admitting everything if it ever did,
         * is not a trade this file makes anywhere else.
         */
        try {
            var origin = frame.securityOrigin;
            var scheme = String(ObjCRef.unwrap(origin.protocol) || "");
            var host = String(ObjCRef.unwrap(origin.host) || "");
            if (this.isTrustedOrigin(scheme, host)) {
                return true;
            }
            this.note("refused a message from " + scheme + "://" + host);
            return false;
        } catch (e) {
            this.note("refused a message whose sender's origin could not " +
                "be read: " + e);
            return false;
        }
    };

    NeutrinoWebview.parseMessage = function (raw) {
        var text = String(raw == null ? "" : raw);
        if (text.length > 4096) {
            return null;
        }

        var sep = this.messageSeparator;
        var cut = text.indexOf(sep);
        var action = (cut < 0) ? text : text.substring(0, cut);
        var rest = (cut < 0) ? null : text.substring(cut + 1);

        if (action === "close") {
            return (rest === null) ? { action: "close" } : null;
        }

        if (action === "openExternal") {
            if (rest === null || !this.isExternalUrl(rest)) {
                return null;
            }
            // Said rather than dropped, because a page whose link does
            // nothing and whose host says nothing is a build that looks
            // broken instead of a build that is offline.
            if (!this.mayOpenExternal(rest)) {
                this.note("refused openExternal: this build is offline");
                return null;
            }
            return { action: "openExternal", url: rest };
        }

        if (action === "resize" || action === "move") {
            if (rest === null) {
                return null;
            }
            var parts = rest.split(sep);
            if (parts.length !== 2) {
                return null;
            }
            if (action === "resize") {
                if (!this.isDimension(parts[0]) || !this.isDimension(parts[1])) {
                    return null;
                }
                return {
                    action: "resize",
                    width: parseInt(parts[0], 10),
                    height: parseInt(parts[1], 10)
                };
            }
            if (!this.isCoordinate(parts[0]) || !this.isCoordinate(parts[1])) {
                return null;
            }
            return { action: "move", x: parseInt(parts[0], 10), y: parseInt(parts[1], 10) };
        }

        /*
         * The two relative verbs, and both carry signed deltas rather than
         * sizes -- so they are checked with isCoordinate and never with
         * isDimension, which refuses everything at or below zero. A resize
         * of -40 is a legitimate request and the clamp that keeps the
         * result positive belongs where the current size is known, which is
         * the host and not here.
         *
         * They exist because neither could be computed in the page.
         * `screenX` is truthful on one engine of four, so `moveBy` had no
         * arithmetic available to it. `resizeBy` looked like it did --
         * innerWidth matched the native content size everywhere -- but
         * `resizeTo` means the content area on three lanes and the frame on
         * macOS, so a page-side sum would compound that difference. Asking
         * the driver for bounds in its own units is right on either side of
         * the PR that settles it.
         */
        if (action === "resizeBy" || action === "moveBy") {
            if (rest === null) {
                return null;
            }
            var deltas = rest.split(sep);
            if (deltas.length !== 2) {
                return null;
            }
            if (!this.isCoordinate(deltas[0]) || !this.isCoordinate(deltas[1])) {
                return null;
            }
            if (action === "resizeBy") {
                return {
                    action: "resizeBy",
                    width: parseInt(deltas[0], 10),
                    height: parseInt(deltas[1], 10)
                };
            }
            return { action: "moveBy", x: parseInt(deltas[0], 10), y: parseInt(deltas[1], 10) };
        }

        return null;
    };

    NeutrinoWebview.buildPreloadScript = function (transport, name, themeLiteral, fontsLiteral) {
        return '(function(){' +
            'var S=String.fromCharCode(31);' +
            'var _send=function(m){try{(' + transport + ')(m);}catch(_){}};' +
            'var _n=function(v){return String(v===undefined||v===null?"":v);};' +
            /*
             * The update half of the palette's CSS delivery. The launch
             * half is a stylesheet in the document -- see themedDocument,
             * which says why a document-start script is the wrong mechanism
             * for a value that has to be there before the first paint.
             *
             * This is the mechanism that was measured: setProperty on
             * documentElement works and reads back on all four engines. By
             * the time it runs there is certainly a document, because
             * `_theme` is only ever reached through a driver's evaluate,
             * and every one of those is gated on the commit.
             *
             * Both lists are written from this file's own two constants, in
             * one order, so the mapping from a neutrino key to a CSS
             * keyword exists once. Neither needs escaping: one is a list of
             * identifiers and the other a list of CSS keywords, and both
             * are constants here rather than anything a toolkit answered.
             */
            'var _K=["' + this.themeKeyList().join('","') + '"];' +
            'var _P=["' + String(this.systemColorNames).split(",").join('","') + '"];' +
            'var _css=function(t){' +
            'var e=document.documentElement;' +
            'if(!e||!t||!t.colors){return;}' +
            'for(var i=0;i<_K.length;i++){' +
            'try{e.style.setProperty("--neutrino-"+_P[i],t.colors[_K[i]]);}catch(_){}' +
            '}' +
            '};' +
            /*
             * And the same for the fonts, which is the same mechanism with
             * one more level to walk: three lists, all written from this
             * file's own constants -- the roles, the fields the object
             * carries, and the middles of the property names. _FF and _FP
             * are parallel and read positionally, the arrangement _K and _P
             * already have above.
             *
             * Nothing is formatted here. The object's own field values are
             * the CSS values -- `'Ubuntu',sans-serif`, `13.33px`, `500` --
             * composed once host-side by fontValueList and checked there
             * against three anchored patterns. A second spelling of that
             * formatting, page-side, is a second spelling that can drift
             * from the stylesheet the same launch wrote.
             *
             * `r.stack` is copied and never rebuilt. The object carries
             * `family` and `generic` beside it so a page can tell a desktop
             * that named a face from one that did not, but composing those
             * two here would be a second spelling of a rule the stylesheet
             * this launch already wrote follows -- and on macOS the two
             * would disagree, because that lane's tail is what makes
             * `system-ui` land somewhere on the engines that do not
             * resolve it.
             */
            'var _FR=["' + this.fontRoleList().join('","') + '"];' +
            'var _FP=["' + String(this.fontCssPrefixes).split(",").join('","') + '"];' +
            'var _fontcss=function(f){' +
            'var e=document.documentElement;' +
            'if(!e||!f){return;}' +
            'for(var i=0;i<_FR.length;i++){' +
            'var r=f[_FR[i]];if(!r){continue;}' +
            'var v=[r.stack,r.size,r.weight];' +
            'for(var j=0;j<_FP.length;j++){' +
            'try{e.style.setProperty("--neutrino-"+_FP[j]+"-"+_FR[i],v[j]);}catch(_){}' +
            '}}' +
            '};' +
            /*
             * The wire, and it is a closure rather than a member.
             *
             * It used to be `window.neutrino.send`, reachable by any page
             * script, and the README called it an extension point. It never
             * was one: the chain below names six actions and nothing else,
             * and every one of the six now has a spelling the web platform
             * already has -- so the last caller with a reason to reach it
             * directly went away with the bespoke names.
             *
             * Being unreachable is worth something on its own. The five
             * verbs written over the engine's own below route through this
             * variable and not through a property, so a page that replaces
             * `window.neutrino` cannot make `window.resizeTo` send anything
             * else. That is a consequence of the deletion and not its
             * reason -- the host checks every record it receives either way.
             */
            'var _act=function(action,data){' +
            'var d=data||{};' +
            'if(action==="resize")_send("resize"+S+_n(d.width)+S+_n(d.height));' +
            'else if(action==="resizeBy")_send("resizeBy"+S+_n(d.width)+S+_n(d.height));' +
            'else if(action==="move")_send("move"+S+_n(d.x)+S+_n(d.y));' +
            'else if(action==="moveBy")_send("moveBy"+S+_n(d.x)+S+_n(d.y));' +
            'else if(action==="openExternal")_send("openExternal"+S+_n(d.url));' +
            'else if(action==="close")_send("close");' +
            '};' +
            'window.neutrino={' +
            // Which channel the host is actually listening on. The page can
            // work this out by feature detection anyway, so naming it costs
            // nothing and lets a test report it instead of inferring it.
            'transport:"' + String(name || "unknown") + '",' +
            /*
             * The desktop's palette, in the preload rather than pushed
             * after it. An app that has to wait for an event to learn the
             * colours it launched into would paint once in the wrong ones
             * first, which is the flash this whole thing exists to close,
             * arrived at from the other side.
             *
             * `null` on a lane whose toolkit could not be read. Said out
             * loud rather than filled in with white, so an app finds out by
             * asking instead of by styling itself from a palette nobody's
             * desktop is using.
             */
            'theme:' + (themeLiteral || "null") + ',' +
            /*
             * The desktop's fonts, in the preload for the same reason the
             * palette is: an app that had to wait for an event to learn
             * what it launched into would lay out once in the wrong type
             * first, which is the flash this whole thing exists to close.
             *
             * A separate object and not a member of `theme`, because they
             * are separately available. Qt reads a font at launch and has
             * no signal to follow one with -- measured on real Plasma 6,
             * where its palette *is* live -- so a lane can have a live
             * palette and a frozen font set, and one object carrying both
             * would have to lie about one of them.
             *
             * `null` on a lane whose toolkit could not be read, said out
             * loud, exactly as `theme` is.
             */
            'fonts:' + (fontsLiteral || "null") + ',' +
            /*
             * Where an update lands. Replaced and not mutated: an app that
             * captured the object keeps a stable snapshot of the palette it
             * had, and one that reads window.neutrino.theme gets the
             * current one. The property is current before the event fires,
             * so a handler may read either.
             *
             * Nothing else in this file evaluates into a page, and nothing
             * reaches here that themeLiteral did not build.
             */
            '_theme:function(t){' +
            'window.neutrino.theme=t;' +
            '_css(t);' +
            'try{window.dispatchEvent(new CustomEvent("neutrino:themechange",{detail:t}));}catch(_){}' +
            '},' +
            /*
             * The same, one event along. Replaced and not mutated, and the
             * property is current before the event fires, so a handler may
             * read either.
             *
             * Reached only through a driver's evaluate, and nothing reaches
             * here that fontsLiteral did not build.
             */
            '_fonts:function(f){' +
            'window.neutrino.fonts=f;' +
            '_fontcss(f);' +
            'try{window.dispatchEvent(new CustomEvent("neutrino:fontchange",{detail:f}));}catch(_){}' +
            '}' +
            '};' +
            /*
             * And the five that do have a spelling, written over the
             * engine's own.
             *
             * Measured on WebKitGTK, QtWebEngine, WKWebView and WebView2:
             * all five exist, all five are writable and configurable own
             * properties of window, and all five do nothing. Four engines
             * refuse to resize or move a window a script did not open, and
             * report no error for it -- so an app calling the standard
             * spelling today gets silence. What is being replaced is that
             * silence, and nothing else: these emit the identical record
             * the bespoke names emitted and meet the identical host-side
             * guard, which is why this is a spelling change and not a
             * policy one.
             *
             * Plain assignment rather than defineProperty, because the
             * descriptor was read on all four and all four said writable.
             * Each in its own try: a lane that ever refuses one should lose
             * that verb and not the four beside it.
             *
             * close() returns nothing and does not set window.closed. The
             * engines disagree about that flag already -- three set it true
             * while the window stays up, WebView2 leaves it false -- so
             * there is no value here that would be true everywhere, and
             * inventing one is the thing this file refuses to do.
             */
            'var _def=function(n,f){try{window[n]=f;}catch(_){}};' +
            '_def("resizeTo",function(w,h){_act("resize",{width:w,height:h});});' +
            '_def("resizeBy",function(w,h){_act("resizeBy",{width:w,height:h});});' +
            '_def("moveTo",function(x,y){_act("move",{x:x,y:y});});' +
            '_def("moveBy",function(x,y){_act("moveBy",{x:x,y:y});});' +
            '_def("close",function(){_act("close");});' +
            /*
             * And the sixth, which is not like the other five: they were
             * silent everywhere and this one is silent in one direction and
             * working in the other.
             *
             * Measured on WebKitGTK, one launch per row, with the driver's
             * own refusal note read off stderr beside the call's return:
             *
             *   open(u)            null    no policy decision reached
             *   open(u,"_blank")   null    no policy decision reached
             *   open(u,"name")     null    no policy decision reached
             *   open(u,"_self")    object  refused and forwarded
             *   <a target=_blank>  --      refused and forwarded
             *
             * Two paths inside the engine and this file was on one of them.
             * A link with a target raises `decide-policy` with
             * NEW_WINDOW_ACTION, which both GTK drivers already forward.
             * `window.open` raises the `create` signal instead, nothing is
             * connected to it, and the call returns null having reached no
             * guard here at all -- so the one spelling an app author would
             * reach for was the one spelling that did nothing.
             *
             * **What is routed is the url, not the target**, and that is
             * the whole of what this round claims. A url bound for the
             * machine's browser goes there; everything else is handed to
             * the engine exactly as it arrived.
             *
             * The alternative was to key on the target -- `_blank` and any
             * name to the browser, `_self` and its two siblings to the
             * engine -- and it is wrong in the direction that costs the
             * most later. `window.open("panel.html")` is an app asking for
             * a second window of its own, and the only thing that can hand
             * a page a real WindowProxy is the engine actually creating the
             * view: WebKitGTK's `create`, Qt's newViewRequested, WebView2's
             * NewWindowRequested, WKWebView's
             * createWebViewWithConfiguration:. An override that answered
             * every target would mean those signals are never raised at
             * all, and the second window becomes unreachable from inside
             * this file rather than merely unbuilt. So the default is the
             * engine's, and this steps in front of one case only.
             *
             * Nothing is opened for a call with no url. The web platform's
             * answer there is about:blank in a new window, which is the
             * second-window case and not this one; sending it as a record
             * would be `openExternal("")` for the host to refuse, which is
             * a no-op with a wire message in front of it. It is a no-op
             * without one until there is a window to open.
             *
             * The three targets that mean *this* window are still checked,
             * and before the url, because they are not an opening at all.
             * `_self` returns the window and navigates, and that navigation
             * meets the guard every location change meets -- which already
             * forwards an external url to the browser. Routing it here as
             * well would take a measured path away and give back a
             * different one. The match is case-insensitive: the target is a
             * keyword, and `_SELF` reaching the machine's browser is the
             * opposite of what it asked for.
             *
             * The scheme test here is a *routing* question and not a
             * security one, which is why it is allowed to be this small.
             * isExternalUrl still decides what may leave -- length, control
             * characters, the shape of the host -- and mayOpenExternal
             * still decides whether this build may let anything leave at
             * all. Both run on the host, on the record this sends. What
             * this picks is only which of two paths the call takes; a url
             * that gets the wrong one is refused at the other end either
             * way.
             *
             * null is returned rather than a window-shaped object. Three of
             * four engines already answer null here and QtWebEngine answers
             * an object; nothing this file can hand back is a window in this
             * page's process, because the url went to the machine's browser.
             * A truthful null beats a proxy that would answer questions
             * about a window that does not exist.
             *
             * The record is the one openExternal has always emitted, so an
             * offline build refuses this exactly as it refuses the bespoke
             * spelling. A spelling change, not a policy change.
             */
            'var _open=window.open;' +
            'var _eng=function(u,t){try{return _open.call(window,u,t);}catch(_){return null;}};' +
            '_def("open",function(url,target){' +
            'var u=(url==null)?"":String(url);' +
            'if(u===""){return null;}' +
            'var t=String(target==null?"":target).toLowerCase();' +
            'if(t==="_self"||t==="_parent"||t==="_top"){return _eng(url,target);}' +
            'if(!/^(https?|mailto):/i.test(u)){return _eng(url,target);}' +
            '_act("openExternal",{url:u});' +
            'return null;' +
            '});' +
            '})();';
    };

    NeutrinoWebview.routeMessage = function (actions, raw) {
        var msg = this.parseMessage(raw);
        if (msg && actions[msg.action]) {
            actions[msg.action](msg);
        }
    };

