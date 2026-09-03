# The artifact's own path, which every lane below needs: the engines are handed
# this file to read, and two of them look at the directory it sits in.
#
# This file used to also carry a tier list and `has_tier`. It read the list back
# out of the artifact at launch with a `sed` range, because a second program had
# stamped it into the JavaScript region and the shell had to go and find where
# it landed. There is nothing to find any more, and nothing to name: `testing`
# is an overlay a build either contains or does not, the two that varied the
# confinement are gone, and a launcher cannot ask which because there is no
# branch left to take. What a release artifact does not carry, it cannot be
# talked into.
script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
