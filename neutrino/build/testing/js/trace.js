    /*
     * When this file was reached, which is a mark and not a message.
     *
     * `start: 934ms of this process before its first line` is one number over
     * the CLR starting, mscorlib and Microsoft.JScript loading, thirty-two
     * parts of global code running, and System.Windows.Forms arriving because
     * init calls EnableVisualStyles three statements before the trace exists.
     * Six times the runner's 155ms, and nothing in it says which of the four
     * grew.
     *
     * This part is fifteenth of the thirty-two, and the two largest things
     * below it are the 313-line table of COM vtable slots and the toolkit. So
     * a timestamp here cuts that one number in half along a seam that means
     * something: everything before it is the runtime arriving, everything
     * after it is mostly ours.
     *
     * eval, and guarded, because this file is read by five engines and only
     * one of them has a System namespace to ask. The other four leave the mark
     * null and lose nothing -- no lane but this one has a prefix it cannot see.
     */
    try {
        NeutrinoWebview.traceLoadedAt = eval("System").DateTime.UtcNow;
    } catch (_) {
        NeutrinoWebview.traceLoadedAt = null;
    }

    NeutrinoWebview.trace = function (message) {
        this.note(message);
    };
