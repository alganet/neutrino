# Nothing. A release build does not read QTWEBENGINE_DISABLE_SANDBOX, because
# nothing in it would consume the answer -- see sh/qt-sandbox.sh, which is where
# the only consumer lives and which is likewise empty here.
#
# The capture has to happen at this point and not beside its consumer: the scrub
# below unsets the variable, so a read in qt.sh would be a read of something
# already gone. That is the whole reason this is a second file.
