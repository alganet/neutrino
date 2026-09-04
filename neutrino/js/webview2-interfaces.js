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
     * test/evergreen.ps1 lifts this object out of the built artifact, parses
     * that header, and fails on any disagreement -- which is the same
     * arrangement webView2Members has, and for the same reason: a pinned
     * constant nobody re-checks is a constant that is right until it is
     * silently not.
     *
     * `name` is what makes that check possible and is the only field here the
     * driver never reads: it says which interface in the header each of these
     * is, so the comparison needs no second table mapping one to the other. A
     * mapping kept outside the thing it maps is a mapping that goes stale on
     * the day an interface is added, which is the day it matters.
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
     *   r   RECT, four ints by value
     *   c   COREWEBVIEW2_COLOR, four bytes by value
     *
     * Interface pointers and strings are IntPtr on purpose and not as a
     * shortcut. Declared as an interface, a parameter makes the marshaller
     * responsible for a QueryInterface it cannot be told the rules for;
     * declared as String, it raises a BSTR-or-LPWStr question whose wrong
     * answer is silent. As IntPtr neither question is asked, and -- the part
     * that matters for a generated table -- no interface here refers to any
     * other, so they can be built in any order.
     *
     * The two structs are the exception because they have to be. A struct is
     * not passed the way a pointer is, whatever its size, and a struct passed
     * as a pointer is not a wrong value -- it is a crash. Both layouts are read
     * out of the pinned header by test/evergreen.ps1 rather than remembered.
     */
    NeutrinoWebview.webView2Interfaces = {
        environment: {
            name: "ICoreWebView2Environment",
            iid: "b96d755e-0319-4e92-a296-23436f46a1fc",
            calls: {
                CreateCoreWebView2Controller: [0, "v", "pp"],
                get_BrowserVersionString:     [2, "p", ""]
            }
        },
        controller: {
            name: "ICoreWebView2Controller",
            iid: "4d00c0d1-9434-4eb6-8078-8697a560334f",
            calls: {
                put_IsVisible:     [1,  "v", "i"],
                put_Bounds:        [3,  "v", "r"],
                /*
                 * The two the WinForms control did for free, and neither is a
                 * nicety.
                 *
                 * MoveFocus is where the keyboard goes. A controller is a child
                 * window of the form and nothing routes WM_SETFOCUS into it, so
                 * a launch that does not call this comes up with the caret
                 * nowhere: an app opens, an input is on screen, and typing does
                 * nothing until the user clicks the page. The control's own
                 * WndProc is what did this on the package path.
                 *
                 * NotifyParentWindowPositionChanged is what a dropdown, an
                 * autofill panel or an IME candidate window is positioned
                 * against. The runtime caches the parent's screen position and
                 * has no way to learn that it moved, so without this a window
                 * dragged across the desktop opens its popups where it used to
                 * be. Both are measured through the same loop that sizes the
                 * view, because a controller is a rectangle somebody has to
                 * maintain and this is the rest of that job.
                 */
                MoveFocus:         [9,  "v", "i"],
                NotifyParentWindowPositionChanged: [20, "v", ""],
                Close:             [21, "v", ""],
                get_CoreWebView2:  [22, "p", ""]
            }
        },
        /*
         * The one derived interface here, and the reason the slot number looks
         * large for an interface with two methods. COM single inheritance puts
         * the base's vtable first, so ICoreWebView2Controller2's own methods
         * start after ICoreWebView2Controller's twenty-three:
         * put_DefaultBackgroundColor is its second, and so slot 24.
         *
         * This is what the package path gets from the WinForms control's
         * DefaultBackgroundColor property. Without it the view paints its own
         * default behind a window this launcher has already themed, which is
         * the flash the whole theme lane exists to prevent.
         *
         * A runtime too old to offer it refuses the QueryInterface, and that is
         * the entire failure -- the window is still painted, so what is lost is
         * the gap before the document arrives and not the app.
         */
        controller2: {
            name: "ICoreWebView2Controller2",
            iid: "c979903e-d4ca-4228-92eb-47ee3fa96eab",
            calls: {
                put_DefaultBackgroundColor: [24, "v", "c"]
            }
        },
        webview: {
            name: "ICoreWebView2",
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
         * Four of the nine doors the managed path closes, and the four that are
         * on the interface a runtime has had since the beginning.
         */
        settings: {
            name: "ICoreWebView2Settings",
            iid: "e562e4f0-d7fa-43ac-8d71-c05150499f00",
            calls: {
                put_IsStatusBarEnabled:           [7,  "v", "i"],
                put_AreDevToolsEnabled:           [9,  "v", "i"],
                put_AreDefaultContextMenusEnabled: [11, "v", "i"],
                put_AreHostObjectsAllowed:        [13, "v", "i"]
            }
        },
        /*
         * And the other five, which used to be the difference between the two
         * Windows paths and are not any more.
         *
         * They are not on ICoreWebView2Settings. Each arrived in a later
         * revision -- Settings3 through 6 -- and every revision is a separate
         * IID to QueryInterface for rather than more slots on the one this file
         * already has. That is why they were left out, and it is not a reason:
         * the package path turns all nine off through property names the
         * managed wrapper resolves for it, so a machine that took the Evergreen
         * path was getting browser accelerator keys, autofill, password
         * autosave, pinch zoom and swipe-to-navigate that the very same build
         * closed on a machine that took the other one. A promise that holds on
         * the rarer of two paths is not a promise.
         *
         * Four QueryInterfaces rather than one for Settings6, deliberately.
         * Each revision is a superset of the one before, so the newest would
         * carry all five -- and on a runtime too old to offer it, that single
         * refusal would lose the four doors the older interfaces do have.
         * Asked one at a time, a runtime closes every door it knows about.
         *
         * The slot numbers count the inherited vtable, the way controller2's
         * does: Settings3's own first method is slot 20 because Settings and
         * Settings2 fill nought to nineteen ahead of it.
         */
        settings3: {
            name: "ICoreWebView2Settings3",
            iid: "fdb5ab74-af33-4854-84f0-0a631deb5eba",
            calls: {
                put_AreBrowserAcceleratorKeysEnabled: [21, "v", "i"]
            }
        },
        settings4: {
            name: "ICoreWebView2Settings4",
            iid: "cb56846c-4168-4d53-b04f-03b6d6796ff2",
            calls: {
                put_IsPasswordAutosaveEnabled: [23, "v", "i"],
                put_IsGeneralAutofillEnabled:  [25, "v", "i"]
            }
        },
        settings5: {
            name: "ICoreWebView2Settings5",
            iid: "183e7052-1d03-43a0-ab99-98e043b66b39",
            calls: {
                put_IsPinchZoomEnabled: [27, "v", "i"]
            }
        },
        settings6: {
            name: "ICoreWebView2Settings6",
            iid: "11cb3acd-9bc8-43b8-83bf-f40753714f87",
            calls: {
                put_IsSwipeNavigationEnabled: [29, "v", "i"]
            }
        },
        messageArgs: {
            name: "ICoreWebView2WebMessageReceivedEventArgs",
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
            name: "ICoreWebView2NavigationStartingEventArgs",
            iid: "5b495469-e119-438a-9b18-7604f25f2e49",
            calls: {
                get_Uri:    [0, "p", ""],
                put_Cancel: [5, "v", "i"]
            }
        },
        newWindowArgs: {
            name: "ICoreWebView2NewWindowRequestedEventArgs",
            iid: "34acb11c-fc37-4418-9132-f9c21d1eafb9",
            calls: {
                get_Uri:     [0, "p", ""],
                put_Handled: [3, "v", "i"]
            }
        }
    };

    /*
     * Which of the interfaces above carry a door to close, in the order they
     * are asked for. Written once and read by the Evergreen view's harden(),
     * so that adding a revision is adding an entry to the table above and a
     * name here -- and never a fifth copy of the same walk.
     */
    NeutrinoWebview.webView2SettingsInterfaces =
        ["settings", "settings3", "settings4", "settings5", "settings6"];

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
            name: "ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler",
            iid: "4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d",
            args: "ip",
            target: "OnEnvironment"
        },
        controllerCompleted: {
            name: "ICoreWebView2CreateCoreWebView2ControllerCompletedHandler",
            iid: "6c4819f3-c9b7-4260-8127-c9f5bde7f68c",
            args: "ip",
            target: "OnController"
        },
        webMessageReceived: {
            name: "ICoreWebView2WebMessageReceivedEventHandler",
            iid: "57213f19-00e6-49fa-8e07-898ea01ecbd2",
            args: "pp",
            target: "OnWebMessage"
        },
        navigationStarting: {
            name: "ICoreWebView2NavigationStartingEventHandler",
            iid: "9adbe429-f36d-432b-9ddc-f8881fbd76e3",
            args: "pp",
            target: "OnNavigationStarting"
        },
        contentLoading: {
            name: "ICoreWebView2ContentLoadingEventHandler",
            iid: "364471e7-f2be-4910-bdba-d72077d51c4b",
            args: "pp",
            target: "OnContentLoading"
        },
        newWindowRequested: {
            name: "ICoreWebView2NewWindowRequestedEventHandler",
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
            name: "ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler",
            iid: "b99369f3-9b11-47b5-bc6f-8e7895fcea17",
            args: "ip",
            target: "OnScriptAdded"
        },
        scriptRan: {
            name: "ICoreWebView2ExecuteScriptCompletedHandler",
            iid: "49511172-cc67-4bca-9923-137112f4c4cc",
            args: "ip",
            target: "OnScriptRan"
        }
    };
