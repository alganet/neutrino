# The renderer sandbox, off, because CI's containers cannot create user
# namespaces. `neutrino_qt_disable_sandbox` is captured by this overlay's
# sh/qt-sandbox-env.sh, so a testing build on a machine that can sandbox still
# does -- and a release build reads neither the variable nor this.
if [ "$neutrino_qt_disable_sandbox" = "1" ]; then
    QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS} --no-sandbox"
fi
