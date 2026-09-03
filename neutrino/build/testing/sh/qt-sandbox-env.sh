# Read before the scrub takes it, and consumed only by sh/qt-sandbox.sh, which
# this overlay also replaces. CI cannot start Chromium in its container without
# it.
neutrino_qt_disable_sandbox="${QTWEBENGINE_DISABLE_SANDBOX:-}"
