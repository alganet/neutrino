# WebKitGTK's sandbox is bubblewrap, and bubblewrap needs an unprivileged user
# namespace. Whether it can have one is not a property of this program: Ubuntu
# 24.04 and its derivatives set kernel.apparmor_restrict_unprivileged_userns to
# 1 and refuse, while the same kernel elsewhere allows it. Under netinstall it
# is refused again for an unrelated reason, since Landlock denies mount to any
# domain handling a filesystem right.
#
# None of that can be recovered from after the fact. Asking WebKitGTK to turn
# the sandbox off once a web process exists aborts the program outright --
# "Sandboxing cannot be changed after subprocesses were spawned" -- and asking
# for a sandbox that cannot start gives a window with nothing in it. So the
# question is settled here, before anything is launched, by running the actual
# mechanism rather than by looking for the parts it is made of.
#
# The value is always assigned, never defaulted from the environment, so this
# is a measurement being passed inward and not a switch anyone can set.
neutrino_webkit_sandbox=0
if command -v bwrap >/dev/null 2>&1 &&
   bwrap --unshare-user --ro-bind / / /bin/true >/dev/null 2>&1
then neutrino_webkit_sandbox=1
fi
export NEUTRINO_WEBKIT_SANDBOX="$neutrino_webkit_sandbox"

