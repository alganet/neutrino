# The renderer sandbox, off, because CI's containers cannot create user
# namespaces. `neutrino_qt_disable_sandbox` is still asked, so a testing build
# on a machine that can sandbox still does.
if [ "$neutrino_qt_disable_sandbox" = "1" ]; then
    QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS} --no-sandbox"
fi
