    /*
     * Everything arriving on this channel was written by whatever page the
     * webview is currently showing, which makes it attacker-controlled text
     * by definition. It used to be handed to eval, which on gjs meant
     * evaluating that text in a scope holding imports.gi.GLib and Gio.
     *
     * The fix is not a JSON parser. The action set is fixed, flat and tiny,
     * so the host does not parse a message, it splits one: each action has a
     * known arity, and any free-form field is always last and takes the rest
     * of the string verbatim. A separator inside a title therefore cannot
     * invent an extra field, nothing needs escaping, and JScript.NET not
     * having a JSON global stops being a problem worth solving.
     */
    NeutrinoWebview.messageSeparator = String.fromCharCode(31);

    NeutrinoWebview.hasControlCharacters = function (value) {
        var text = String(value);
        for (var i = 0; i < text.length; i++) {
            var code = text.charCodeAt(i);
            if (code < 32 || code === 127) {
                return true;
            }
        }
        return false;
    };

    NeutrinoWebview.isCoordinate = function (value) {
        return /^-?[0-9]{1,6}$/.test(String(value));
    };

    NeutrinoWebview.isDimension = function (value) {
        return /^[0-9]{1,6}$/.test(String(value)) && parseInt(String(value), 10) > 0;
    };

    /*
     * An allowlist, so every scheme this does not name is refused without
     * having to be enumerated -- file:, javascript:, data:, ms-settings:,
     * search-ms:, and whichever one the platform invents next. This matters
     * more than it looks: on Windows the other end of openExternal is
     * Process.Start, and on Linux it is the desktop's URI handler.
     */
    NeutrinoWebview.isExternalUrl = function (value) {
        var url = String(value == null ? "" : value);
        if (!url || url.length > 2048 || this.hasControlCharacters(url)) {
            return false;
        }
        return /^https?:\/\/[^\/?#]/i.test(url) || /^mailto:[^@\s]+@[^@\s]+$/i.test(url);
    };

    /*
     * Whether this build may hand a url to the machine's browser at all.
     *
     * isExternalUrl answers a question about the string. This answers one
     * about the build, and the two are separate on purpose: the allowlist
     * above is about schemes and stays true whatever tier is stamped.
     *
     * The offline tier says the page has no network. A url handed to the
     * desktop's handler is the page reaching the network in another
     * program, and it was measured going out that way on all four engines,
     * by both routes -- `window.open`, which any page script may call, and
     * a navigation this file refuses and then forwards on gjs and Qt
     * without the page having to ask twice. Neither is something a content
     * policy can see: CSP governs subresources, and this is not a load.
     *
     * So the tier closes it, and every place that was asking isExternalUrl
     * before opening asks this instead -- including the four drivers' own
     * end-of-the-line checks, which exist because that is where a string
     * becomes ShellExecute, NSWorkspace or the desktop's URI handler.
     *
     * The cost is real and is the overlay's whole point: an offline app cannot
     * open a link in the user's browser. An app that wants to do that wants a
     * build without it.
     */
    NeutrinoWebview.mayOpenExternal = function (value) {
        if (!this.isExternalUrl(value)) {
            return false;
        }
        return this.externalAllowed();
    };

