    NeutrinoWebview.scriptPathOverride = function (SystemRef) {
        var fromEnv = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH");
        // Tested against null and "" rather than for truth. Every value here is
        // a .NET String arriving through a late-bound call, and whether an empty
        // one is falsy is a question the four engines do not have to answer the
        // same way. Nothing below asks.
        if (fromEnv == null || String(fromEnv) === "") {
            return null;
        }
        if (!SystemRef.IO.File.Exists(fromEnv)) {
            throw new Error("neutrino: NEUTRINO_SCRIPT_PATH names no file: " + fromEnv);
        }
        return fromEnv;
    };
