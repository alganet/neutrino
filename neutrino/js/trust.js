    /*
     * The fragment is not part of the answer. Setting location.hash is how
     * a great many apps move between screens; it does not navigate
     * anywhere, and every engine here reports it in the uri anyway --
     * measured on all three. Without this the guard refuses a navigation
     * that is going to happen regardless and says so in a note, which is a
     * refusal that did not take place.
     */
    NeutrinoWebview.isOwnDocument = function (url) {
        var u = this.viewIdentity(url);
        return u === "" || u === "about:blank";
    };

    /*
     * The document a message is allowed to come from, as the engine names
     * it rather than as this file would guess.
     *
     * The three engines answer differently and an origin rule that fits one
     * mutes the others: gjs reports about:blank for a document loaded from
     * a string, QtWebEngine reports the whole data: url it navigated to in
     * order to hand the document over, and the macOS driver reports the
     * file: directory it was given as a base. All three measured. A check
     * built on schemes admits only the last, and the other two get a window
     * that comes up and then ignores its own app.
     *
     * What all three can answer is whether the view is still showing the
     * document that arrived first. So that one is remembered and every
     * later message is judged against it, which needs no per-engine table
     * and no allowlist. On macOS it is stricter than the origin rule it
     * joins rather than replaces: that one admits any file: document, which
     * is the residual its own comment names.
     */
    NeutrinoWebview.trustedView = null;

    NeutrinoWebview.viewIdentity = function (uri) {
        var text = String(uri == null ? "" : uri);
        var fragment = text.indexOf("#");
        return fragment < 0 ? text : text.substring(0, fragment);
    };

    /*
     * The first one wins and only the first. A driver calls this where it
     * knows the document is the one it loaded: at the load it started,
     * before anything the page does has run.
     *
     * A view that cannot say what it is showing has not handed over a
     * document to trust, and remembering the empty answer would pin the
     * whole session to it. Said out loud, because what follows from it is a
     * window that comes up and then refuses everything, and a refusal
     * nobody can account for is the failure this file keeps legislating
     * against.
     */
    NeutrinoWebview.rememberTrustedView = function (uri) {
        if (this.trustedView !== null) {
            return;
        }
        var identity = this.viewIdentity(uri);
        if (identity === "") {
            this.note("the view did not say which document it committed");
            return;
        }
        this.trustedView = identity;
    };

    /*
     * No longer fails open on a view that has committed nothing yet.
     *
     * That choice was made when the macOS driver remembered its document at
     * the *first message*, having no load event to hang one on -- so a page
     * that navigated before the app ever spoke got itself remembered as the
     * view to trust, and the guard adopted the attacker. Every driver now
     * arms at the load it started and before any page script exists to send
     * anything: gjs at COMMITTED, Qt immediately before it injects the
     * preload, macOS at didCommitNavigation:, WebView2 at the turn of its
     * loop where the navigation sink says the document arrived. A message
     * arriving with nothing remembered is therefore not an app that has not
     * got going yet; it is a view that never committed the document this
     * file loaded.
     *
     * The reason the fail-open was there in the first place still holds and
     * is answered rather than dropped: every caller says why it refused, so
     * the inert window explains itself instead of merely being inert.
     */
    NeutrinoWebview.isTrustedView = function (uri) {
        if (this.trustedView === null) {
            return false;
        }
        return this.viewIdentity(uri) === this.trustedView;
    };

    /*
     * Whether there is a document to judge a title against yet, asked
     * separately from judging one.
     *
     * The two lanes that read the title on a clock have to know the
     * difference before they record what they read. Both keep a last-seen
     * title so that a poll becomes an edge, and a poll that latches a value
     * the gate then refuses for "nothing has committed" would swallow that
     * title for the rest of the run -- the next read is equal to the last
     * one and never fires again. So they ask this first and read nothing
     * until it is true.
     */
    NeutrinoWebview.hasCommittedDocument = function () {
        return this.trustedView !== null;
    };

    /*
     * The transport's marker, as a value rather than as a literal.
     *
     * It is written five times in this file and only two of those can read
     * it from here: the WebView2 loop, which decides whether a document
     * title is a record or a name, and the gate below, which has to refuse
     * exactly what that loop accepts. The other three are page-side or
     * QML-side source being built as a string, where a literal is what
     * there is.
     *
     * So this is not "the marker in one place". It is the pair that has to
     * agree about it not having two spellings between them, which is the
     * disagreement that would matter: a record delivered as a window title.
     */
    NeutrinoWebview.recordPrefix = "__NEUTRINO__";

    /*
     * What a document is allowed to do to the name of the window it is in.
     *
     * `document.title` is the standard spelling of the verb this file used
     * to expose as `neutrino.window.setTitle`, and every one of the four
     * engines raises a signal when it changes -- `notify::title`,
     * `onTitleChanged`, `WKWebView.title`, `DocumentTitleChanged`.
     * Measured, all four: the DOM takes the value and the native window
     * never sees it, so connecting those signals is the whole change. What
     * each lane connects differs; what any of them may pass through does
     * not, which is why the rule is here and not written five times.
     *
     * It is a gate rather than a passthrough for four reasons, and each of
     * them is a reading rather than a precaution.
     *
     * The view has to be the one this launcher handed a document to. The
     * old spelling arrived over the IPC surface, which every driver
     * sender-checks; a title arrives from whatever the engine currently has
     * loaded, and on lanes whose preload the engine reinjects, a page that
     * got navigated to inherits the API and the document alike. The window
     * title is also the channel every verifier in this tree reads, so a
     * foreign document writing it is a foreign document filing this run's
     * report. A view that has committed nothing is a third case and is
     * neither: it is answered below, before the refusal, because two of
     * the five lanes ask this question on a clock that starts first.
     *
     * A record is never a title. Where the title *is* the transport --
     * WebView2 with no `postMessage` wired -- a record and a title share
     * one property, and the marker is what tells them apart. Refusing the
     * marker on every lane rather than only on that one keeps
     * `test/neutrinoattack.js`'s planted record reading the same
     * everywhere, and costs an app nothing it would ever want.
     *
     * An empty title is not a title. A document that never named itself
     * reports one on some engines and nothing on others, and a window whose
     * name disappears because its author wrote no `<title>` is worse than
     * the name the build gave it. `boot` puts the build's title into the
     * document for the same reason, so this is the second of two answers to
     * the same question and the one that does not need the markup to
     * cooperate.
     *
     * Neither is the document's own url, and that rule needed two spellings
     * rather than one. WebView2 documents `DocumentTitle` as falling back
     * to the URI of the document. QtWebEngine was then measured reporting
     * `about:blank` as the view's title the moment the page set
     * `document.title` to the empty string -- on a view whose own url is
     * the `data:` document Qt navigated to, so comparing the title against
     * what the view says it is showing let it straight through and the
     * window took `about:blank` for a name. Both are refused: the identity
     * the view reports, and the placeholder every driver here loads its
     * content into.
     *
     * The bounds are the ones `parseMessage` already put on a title, for
     * the same reason it had them: this ends up in a window title that
     * shell and PowerShell verifiers read line by line, and a control
     * character in it breaks the reader rather than the window.
     */
    NeutrinoWebview.acceptDocumentTitle = function (showing, title) {
        /*
         * Nothing committed yet is silence and not a refusal. Two lanes
         * read the title on a clock -- macOS off the view, WebView2 off
         * CoreWebView2 -- and both of those clocks start before the
         * document arrives, so every launch would otherwise open with a
         * note saying the app was refused its own window.
         */
        if (this.trustedView === null) {
            return null;
        }
        if (!this.isTrustedView(showing)) {
            this.noteOnce("refused a window title from a document the view " +
                "was not given");
            return null;
        }
        var text = String(title == null ? "" : title);
        if (text === "") {
            return null;
        }
        if (text.indexOf(this.recordPrefix) === 0) {
            return null;
        }
        if (text === "about:blank" || text === this.viewIdentity(showing)) {
            return null;
        }
        if (text.length > 1024 || this.hasControlCharacters(text)) {
            this.noteOnce("refused a window title this launcher cannot carry");
            return null;
        }
        return text;
    };

