// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// A SystemPalette under observation: what it started at, and every time it
// moves. Driven by themeflip.sh live_half_qt, which takes the control reading
// with it before it blames the lane; the argument is how many seconds to wait
// before reporting the count and quitting.
//
// console.warn and not console.log, which cost a probe round: Fedora builds
// Qt against journald, so qDebug -- which is what console.log becomes --
// leaves stderr entirely when stderr is not a tty. The probe ran, exited 0,
// and printed nothing, and so did `qml -h`. qWarning survives with
// QT_FORCE_STDERR_LOGGING=1, which the driver exports.
import QtQuick
Window {
    id: root
    visible: true; width: 200; height: 120
    SystemPalette { id: sp; colorGroup: SystemPalette.Active }
    property int fired: 0
    function hex(c) { return Qt.rgba(c.r, c.g, c.b, 1).toString() }

    // QStyleHints::colorScheme is Qt 6.5 and later; on 6.4 this is undefined
    // rather than an error, which is the reading itself and not a failure.
    function scheme() {
        var s = (Qt.styleHints === undefined) ? undefined : Qt.styleHints.colorScheme
        return (s === undefined) ? "undefined" : String(s)
    }
    function line(tag) {
        return tag + " window=" + hex(sp.window) + " highlight=" + hex(sp.highlight)
             + " text=" + hex(sp.windowText) + " scheme=" + scheme()
    }
    Component.onCompleted: console.warn("QTPROBE " + line("start"))

    // Both the per-property notifies and the whole-palette one, because they
    // are separate signals and a plugin may emit either.
    Connections {
        target: sp
        function onWindowChanged() { root.bump("window") }
        function onHighlightChanged() { root.bump("highlight") }
        function onPaletteChanged() { root.bump("palette") }
    }
    Connections {
        target: Qt.styleHints
        ignoreUnknownSignals: true
        function onColorSchemeChanged() { root.bump("colorScheme") }
    }
    function bump(what) {
        fired = fired + 1
        console.warn("QTPROBE " + line("change#" + fired + " " + what))
    }
    Timer {
        interval: (Number(Qt.application.arguments[1]) || 9) * 1000
        running: true
        onTriggered: { console.warn("QTPROBE done fired=" + root.fired); Qt.quit() }
    }
}
