    /*
     * The WebView2 COM surface, as data: an IID per interface, and for every
     * method this driver calls, the slot it sits in and the shape of the call.
     *
     * This is here because the Evergreen path has no managed assembly to ask.
     * The package's `Microsoft.Web.WebView2.Core.dll` is a set of .NET types
     * with names and signatures on them, which is what makes the other path a
     * matter of `GetType().GetMethod(...)`; the runtime installed on the
     * machine offers a vtable and nothing else. A vtable is positions, so the
     * positions have to be written down.
     *
     * Every one of these numbers came out of `build/native/include/WebView2.h`
     * in the package this build already pins, and none was counted by hand.
     * test/evergreen.ps1 re-derives the whole table from that header on every
     * push and fails on any disagreement -- which is the same arrangement
     * webView2Members has, and for the same reason: a pinned constant nobody
     * re-checks is a constant that is right until it is silently not.
     *
     * A slot index is load-bearing in a way a name is not. Calling the wrong
     * name is an error; calling the wrong slot is whatever the function in that
     * slot does with arguments meant for another, and there is no reading that
     * tells you which happened. So the check is against the header, not against
     * a second copy of this file.
     *
     * The shapes are two short strings, a return code and one code per
     * parameter:
     *
     *   v   nothing -- an HRESULT-only call
     *   p   IntPtr, which is every interface pointer and every string here
     *   i   Int32, which is how BOOL arrives
     *   l   Int64, the EventRegistrationToken an add_ hands back
     *   r   RECT, the one thing in this file that is not pointer-shaped
     *
     * Interface pointers and strings are IntPtr on purpose and not as a
     * shortcut. Declared as an interface, a parameter makes the marshaller
     * responsible for a QueryInterface it cannot be told the rules for;
     * declared as String, it raises a BSTR-or-LPWStr question whose wrong
     * answer is silent. As IntPtr neither question is asked, and -- the part
     * that matters for a generated table -- no interface here refers to any
     * other, so they can be built in any order.
     *
     * RECT is the exception because it has to be. A 16-byte struct is not
     * passed the way a pointer is, and a struct passed as a pointer is not a
     * wrong value, it is a crash.
     */
    NeutrinoWebview.webView2Interfaces = {
        environment: {
            iid: "b96d755e-0319-4e92-a296-23436f46a1fc",
            calls: {
                CreateCoreWebView2Controller: [0, "v", "pp"],
                get_BrowserVersionString:     [2, "p", ""]
            }
        },
        controller: {
            iid: "4d00c0d1-9434-4eb6-8078-8697a560334f",
            calls: {
                put_IsVisible:     [1,  "v", "i"],
                put_Bounds:        [3,  "v", "r"],
                Close:             [21, "v", ""],
                get_CoreWebView2:  [22, "p", ""]
            }
        },
        webview: {
            iid: "76eceacb-0462-4d94-ac83-423a6793775e",
            calls: {
                get_Settings:                        [0,  "p", ""],
                get_Source:                          [1,  "p", ""],
                NavigateToString:                    [3,  "v", "p"],
                add_NavigationStarting:              [4,  "l", "p"],
                add_ContentLoading:                  [6,  "l", "p"],
                AddScriptToExecuteOnDocumentCreated: [24, "v", "pp"],
                ExecuteScript:                       [26, "v", "pp"],
                add_WebMessageReceived:              [31, "l", "p"],
                add_NewWindowRequested:              [41, "l", "p"],
                get_DocumentTitle:                   [45, "p", ""]
            }
        },
        /*
         * Four of the nine doors the managed path closes. The rest --
         * IsSwipeNavigationEnabled, AreBrowserAcceleratorKeysEnabled,
         * IsGeneralAutofillEnabled, IsPasswordAutosaveEnabled,
         * IsPinchZoomEnabled -- are not on this interface at all. They arrived
         * in ICoreWebView2Settings3 through 6, each of which is a separate IID
         * to QueryInterface for, and adding them is adding interfaces rather
         * than adding slots.
         *
         * Named here rather than left to be noticed: a build on this path
         * hardens less than a build on the other one, and that is a difference
         * between the two that has to be visible from the source.
         */
        settings: {
            iid: "e562e4f0-d7fa-43ac-8d71-c05150499f00",
            calls: {
                put_IsStatusBarEnabled:           [7,  "v", "i"],
                put_AreDevToolsEnabled:           [9,  "v", "i"],
                put_AreDefaultContextMenusEnabled: [11, "v", "i"],
                put_AreHostObjectsAllowed:        [13, "v", "i"]
            }
        },
        messageArgs: {
            iid: "0f99a40c-e962-4207-9e92-e3d542eff849",
            calls: {
                get_Source:               [0, "p", ""],
                TryGetWebMessageAsString: [2, "p", ""]
            }
        },
        /*
         * Cancel is written, not read. The engine reads it the moment the
         * handler returns, which is why the navigation policy has to live in a
         * .NET static rather than be drained from the driver's loop -- the same
         * constraint sink.jsc's NeutrinoNavSink is built around, arriving here
         * in the other spelling.
         */
        navigationArgs: {
            iid: "5b495469-e119-438a-9b18-7604f25f2e49",
            calls: {
                get_Uri:    [0, "p", ""],
                put_Cancel: [5, "v", "i"]
            }
        },
        newWindowArgs: {
            iid: "34acb11c-fc37-4418-9132-f9c21d1eafb9",
            calls: {
                get_Uri:     [0, "p", ""],
                put_Handled: [3, "v", "i"]
            }
        }
    };

    /*
     * The callbacks, which go the other way: these are interfaces this process
     * implements and the runtime calls. Each has exactly one method, `Invoke`,
     * and `args` is its shape in the same code as above.
     *
     * `target` names a static on NeutrinoEvergreen. The emitted class that
     * implements the interface has a body four instructions long -- push both
     * arguments, call that static, return -- so every decision stays on the
     * JScript.NET side and the emitted half exists only to be callable.
     */
    NeutrinoWebview.webView2Handlers = {
        environmentCompleted: {
            iid: "4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d",
            args: "ip",
            target: "OnEnvironment"
        },
        controllerCompleted: {
            iid: "6c4819f3-c9b7-4260-8127-c9f5bde7f68c",
            args: "ip",
            target: "OnController"
        },
        webMessageReceived: {
            iid: "57213f19-00e6-49fa-8e07-898ea01ecbd2",
            args: "pp",
            target: "OnWebMessage"
        },
        navigationStarting: {
            iid: "9adbe429-f36d-432b-9ddc-f8881fbd76e3",
            args: "pp",
            target: "OnNavigationStarting"
        },
        contentLoading: {
            iid: "364471e7-f2be-4910-bdba-d72077d51c4b",
            args: "pp",
            target: "OnContentLoading"
        },
        newWindowRequested: {
            iid: "d4c185fe-c81c-4989-97af-2d3fa7ab5651",
            args: "pp",
            target: "OnNewWindowRequested"
        },
        /*
         * Neither of these reports anything the driver acts on, and neither
         * call can be made without one: AddScriptToExecuteOnDocumentCreated and
         * ExecuteScript both take a completion handler, and the API this driver
         * gives the page arrives through the first of them and no other. A null
         * there would be a build with no neutrino object in it, so it is
         * measured rather than assumed -- the runtime takes a handler this
         * process supplies and answers 0 through it.
         */
        scriptAdded: {
            iid: "b99369f3-9b11-47b5-bc6f-8e7895fcea17",
            args: "ip",
            target: "OnScriptAdded"
        },
        scriptRan: {
            iid: "49511172-cc67-4bca-9923-137112f4c4cc",
            args: "ip",
            target: "OnScriptRan"
        }
    };
