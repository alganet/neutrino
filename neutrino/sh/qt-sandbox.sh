# Chromium's own sandbox is the only thing standing between hostile page content
# and this machine, and a release build has no way to turn it off -- there is
# nothing here to turn.
#
# CI needs it off, because its containers cannot create user namespaces. The
# testing overlay replaces this file with the line that adds --no-sandbox, so a
# build that disables the renderer sandbox is a build somebody assembled with
# that overlay, and not a build that read a variable and agreed.
