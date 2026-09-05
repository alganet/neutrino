# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# A real Plasma 6 desktop for test/qtkde.sh to run the Qt lane's live theme
# half on. Fedora because it carries Qt 6.10 and plasma-integration 6.6 in the
# same release; Ubuntu's plasma-integration is built against Qt 5, so the Qt 6
# KDE platform theme cannot be installed there at all and Qt falls back to
# QGtk3Theme, which is the plugin the question was about in the first place.
#
# Pinned to a release rather than :latest, because the whole value of this
# image is that a reading taken in it can be quoted with a version beside it.
FROM registry.fedoraproject.org/fedora:42

# qt6-qtdeclarative-devel and not just qt6-qtdeclarative: Fedora puts the `qml`
# runtime in the devel subpackage, and the library alone leaves nothing to run
# a QML file with.
#
# plasma-workspace is here for one binary, plasma-apply-colorscheme. It is the
# knob that matters: KDE delivers a colour scheme change over a DBus
# notification, so writing kdeglobals by hand moves the file and tells no
# running application anything.
RUN dnf -y install --setopt=install_weak_deps=False \
      qt6-qtdeclarative qt6-qtdeclarative-devel qt6-qtbase-gui qt6-qtwebengine \
      plasma-integration plasma-workspace kf6-kconfig \
      xorg-x11-server-Xvfb dbus-daemon dbus-x11 xdotool \
      procps-ng findutils which \
 && dnf clean all

# Chromium refuses to start as root without --no-sandbox, and the launcher does
# not pass one -- nor should it, on a user's behalf. So the probe is a user.
RUN useradd -m probe
