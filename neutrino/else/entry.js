    /*
     * The entry point for the web application, and the part of this file that
     * exists to be replaced: `app.js` is the app.
     *
     * It is in the `@else` branch because a Windows launch never calls it.
     * That lane reaches runWindows and returns, and until this moved here it
     * compiled every line of an author's JavaScript anyway -- in the one place
     * where compiling is a step a user waits through, and into an assembly
     * that is loaded and JIT-ed on every launch after.
     *
     * What that buys an author is bigger than the milliseconds. The rules the
     * README used to hand out -- `eval("window")` rather than `window`, no
     * `var int`, no name from a typed language's reserved list, ES5 only --
     * were all one rule: your code is compiled by a JScript.NET compiler that
     * has none of the browser's globals and half a CLR's keywords. It is not,
     * any more. An app names `window` and `document` because it runs in a
     * window and has a document.
     *
     * Two spellings are still read in here, and this comment does not write
     * them down -- which is the rule demonstrating itself. jsc.exe scans a
     * branch it is skipping for its own conditional-compilation directives,
     * the opening one and the closing one, and it scans prose as readily as
     * code: an artifact built with --comments carries this paragraph.
     *
     * Measured on a Windows 11 client, with each spelling put in a comment in
     * else/ and the artifact handed to jsc.exe. The closing one alone is the
     * bad one: the compiler reports an unmatched directive and then compiles
     * the whole rest of this branch as JScript.NET, which is how a build learns
     * that `window`, `document` and `imports` are not declared there. The
     * opening one alone leaves a conditional that never closes. A balanced pair
     * on one line compiles -- and that is exactly how this paragraph used to
     * pass, by naming both. Depending on balance is not a rule anybody can
     * hold, so test/parse.sh refuses either.
     *
     * POLYGLOT.md spells them out, because POLYGLOT.md is not in the artifact.
     *
     * Last in else/parts.list, and that is not arbitrary -- everything above
     * it is the launcher's, and an app that redefines something is meant to
     * win.
     */
    NeutrinoWebview.runWeb = function () {
@@include app.js
    };
