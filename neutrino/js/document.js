    /*
     * The build's title, put where a browser would look for it.
     *
     * Every engine here reports the loaded document's title, and an app
     * whose markup names nothing therefore reports nothing -- which would
     * make the first title-changed signal of every launch an instruction to
     * blank the window's name. Naming the document is what stops that being
     * a special case: the first signal now carries the title the window was
     * already created with, so it changes nothing, and every signal after
     * it is the app's own.
     *
     * It also makes the read side true. An app that assigns
     * `document.title` expects to be able to read it back, and before this
     * the answer was the empty string until the app itself wrote one.
     *
     * A document that named itself keeps its name, and the window takes it:
     * that is what `<title>` means everywhere else, and an author who wrote
     * one meant it more recently than whoever passed `--title`.
     *
     * Escaped for markup rather than trusted. `build.sh` refuses a title
     * carrying a quote, a backslash or a control character, because it is
     * stamped into a JavaScript string literal -- `<` and `&` were never
     * its problem and are this one's.
     */
    /*
     * The palette as a stylesheet, or null where there is no palette to
     * write. `:root` because these have to inherit into everything the app
     * draws, and one declaration per key in the fixed order above.
     *
     * Nothing here can escape the element it lands in: every value matched
     * the anchored hex check in themeColorList and every property name is a
     * substring of a constant in this file. There is no path from a
     * toolkit's answer to markup.
     */
    NeutrinoWebview.themeCssText = function (theme) {
        var values = this.themeColorList(theme);
        if (!values) {
            return null;
        }
        var names = String(this.systemColorNames).split(",");
        var parts = [];
        for (var i = 0; i < names.length; i++) {
            parts[parts.length] = "--neutrino-" + names[i] + ":" + values[i];
        }
        return ":root{" + parts.join(";") + "}";
    };

    /*
     * The launch palette, delivered as markup rather than as a script that
     * runs at document start.
     *
     * The measured mechanism for an *update* is
     * `documentElement.style.setProperty`, which works and reads back on
     * all four engines, and that is what `_theme` uses. The launch is a
     * different question and it is the one the flash exists in: the values
     * have to be there before the first paint, and a document-start script
     * has an element to set them on only if the parser has produced one.
     * `document.title` taught this file that lesson at the cost of a round
     * -- on WebView2 the page script's first statement runs at `loading`,
     * with no `<head>` yet -- and a stylesheet in the markup has no such
     * moment. It is parsed with the document that carries it.
     *
     * Permitted by the policy this file writes, which restricts no styles
     * at all. An app that replaces `html/policy.html` with a stricter one
     * needs `style-src 'unsafe-inline'` in it, which is what an inline
     * `<style>` needs and what an external one is denied.
     *
     * Placed immediately before the document's own `<style>`, and both
     * halves of that are load-bearing.
     *
     * *Before* the author's stylesheet, because an author who writes
     * `:root{--neutrino-Canvas:#123}` means it, and two `:root` rules of
     * equal specificity are decided by which comes last. Overriding the
     * desktop is the app's to do and this must not be the thing that stops
     * it.
     *
     * *After* the head's meta elements, because one of them is the content
     * policy, and a policy governs what follows it in the document rather
     * than what precedes it. Injecting at the top of the head would put the
     * launcher's own stylesheet outside the policy the launcher wrote,
     * which is a small hole and an embarrassing one.
     *
     * A document with no `<style>` of its own gets the rule at the end of
     * the head, which is the same anchor titledDocument uses. That loses
     * the author-wins property and keeps the policy one; a document with no
     * stylesheet has no author declarations to lose to.
     *
     * A lane that read no palette gets no rule, which is the whole point of
     * naming the properties after the keywords: `var(--neutrino-Canvas,
     * Canvas)` then falls through to the engine's own system colour.
     */
    NeutrinoWebview.themedDocument = function (html, theme) {
        var text = String(html);
        var css = this.themeCssText(theme);
        if (!css) {
            return text;
        }
        var head = text.indexOf("</head>");
        if (head < 0) {
            this.noteOnce("this document has no <head>, so the palette is " +
                "on window.neutrino.theme and not in its stylesheet");
            return text;
        }
        var at = text.substring(0, head).indexOf("<style");
        if (at < 0) {
            at = head;
        }
        return text.substring(0, at) + "<style>" + css + "</style>" +
            text.substring(at);
    };

    /*
     * An app's own script, held back until there is a document to run it
     * against.
     *
     * Four of the five lanes get this from their engine and never call this
     * function. WebKitGTK takes a DOCUMENT_END user script, WKWebView takes
     * injection time 1, and Qt runs the page script from
     * LoadSucceededStatus -- so on all four the app's first statement runs
     * with the early shell parsed and `document.body` in hand.
     *
     * WebView2 has one hook before a navigation and it is
     * AddScriptToExecuteOnDocumentCreated, which runs before the parser has
     * produced anything at all. That is where the asymmetry came from, and it
     * was the worst shape a difference can have: an app that reads its own
     * markup works on four platforms and silently does nothing on the fifth.
     * The published sample app was exactly that app --
     * `getElementById("close").onclick = ...` threw on the one platform where
     * getElementById answered null, so the button on the demo everybody
     * downloads did nothing on Windows and everywhere else it worked.
     *
     * The preload is not deferred and must not be: `window.neutrino` is in
     * scope before the app's first statement on every lane, which is a promise
     * about the API and not about the document. It still goes in at document
     * creation, ahead of this, so what this changes is when the app runs and
     * not what it finds when it does.
     *
     * A function body and not a bare listener, because the source being
     * wrapped is this whole file: `var NeutrinoWebview` becomes local to the
     * wrapper, which nothing page-side reads. The readyState test is there for
     * the document that is already past parsing by the time the listener would
     * be registered -- a state this hook cannot reach today, and the branch
     * costs nothing against the launch that would silently never run.
     */
    NeutrinoWebview.deferredPageScript = function (source) {
        return "(function(){var _r=function(){\n" + String(source) + "\n};" +
            "if(document.readyState===\"loading\"){" +
            "document.addEventListener(\"DOMContentLoaded\",function(){_r();});" +
            "}else{_r();}})();";
    };

    NeutrinoWebview.titledDocument = function (html, title) {
        var text = String(html);
        var name = String(title == null ? "" : title);
        if (name === "" || /<title[\s>]/i.test(text)) {
            return text;
        }
        var head = text.indexOf("</head>");
        if (head < 0) {
            this.noteOnce("this document has no <head>, so the window keeps " +
                "its own name whatever the page calls itself");
            return text;
        }
        var escaped = name.replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");
        return text.substring(0, head) + "<title>" + escaped + "</title>" +
            text.substring(head);
    };

