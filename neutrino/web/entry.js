    /*
     * The entry point for the web application, and the one part of this file
     * jsc.exe is told not to read.
     *
     * Everything else under here is compiled twice over: once by jsc.exe into
     * the Windows launcher, and once by whichever engine hosts the page. This
     * half is only ever the second of those. A Windows launch reaches
     * runWindows and returns; it never calls runWeb, and until this part
     * moved into the `@else` branch above it paid to compile it anyway --
     * every line of an app's own JavaScript, in the one place where compiling
     * is a step a user waits through.
     *
     * What that buys an author is bigger than the milliseconds. The rules the
     * README used to hand out -- `eval("window")` rather than `window`, no
     * `var int`, no name from a typed language's reserved list -- were all one
     * rule: your code is compiled by a JScript.NET compiler that has none of
     * the browser's globals and half a CLR's keywords. It is not, any more.
     * An app names `window` and `document` because it runs in a window and
     * has a document.
     *
     * The two spellings jsc still reads in here are `@if` and `@end`: those
     * are its own directives and it looks for them even in a branch it is
     * skipping, so either one resumes the compile in the middle of an app.
     * test/parse.sh refuses a build carrying one and says so.
     */
    // The question js/run.js used to ask through eval("window"), asked here
    // because here it can be written down. Both names are the browser's and
    // neither exists on the lanes above; this file is the half of the polyglot
    // that only a browser ever compiles, so naming them costs nothing.
    NeutrinoWebview.isWeb = function () {
        return typeof window !== "undefined" && typeof document !== "undefined";
    };

    NeutrinoWebview.runWeb = function () {
@@include app.js
    };
