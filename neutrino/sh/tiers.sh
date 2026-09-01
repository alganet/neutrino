script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# The tier list, out of the app's own config.json, included here as a here
# document -- the way qml/window.qml and py/shim.py are included into the lanes
# below.
#
# It used to be read back out of the artifact at run time, by a `sed` range
# bounded with a pair of `//#` comments. That was not a choice about where to
# read from; it was the only way to read at all. The tier list was stamped into
# the JavaScript region by a second program, so the shell had to go and find
# where that stamp had landed, and it had to be told where to stop looking --
# everything below is the app, it is arbitrary JavaScript, and a line of it
# shaped like the stamp is not the stamp.
#
# Nothing is stamped now. The JavaScript region and this here document carry the
# same file, included twice by one assembler, so the two languages cannot be
# built disagreeing about it. That is what the range and the sentinels were for,
# and it is now a property of the build rather than a search performed at every
# launch.
#
# What has not changed is where it does not come from. A release build has no
# way to be talked into "testing" by a caller, because there is nothing in the
# environment either language consults.
#
# `[[:space:]]` and not ` `, and the refusal below is what found out why.
#
# assemble.sh reads this same file to validate it, and it trims a tab as
# readily as a space before it looks at a line. This anchor did not: a
# config.json indented with tabs passed validation, assembled without a word,
# and read as nothing here. Measured, on an app asking for `default,tight` --
# it built, and every has_tier below it answered false, which is the tight tier
# silently not applied on a build that named it.
#
# So the two readers agree on the shape now, and that is the fix. What the
# refusal is for is the next time they do not. It is not a defence against
# anybody editing the artifact -- somebody who can delete the tier list can
# delete these four lines -- it is the fail-closed side of a format read by two
# programs in two languages, where the failure is otherwise a confinement that
# quietly does not happen. An empty read used to become "default" outright,
# which is the weakest tier this file has.
neutrino_tiers="$(sed -n 's/^[[:space:]]*"tiers": "\([a-z,]*\)".*$/\1/p' <<'NEUTRINO_CONFIG_JSON'
@@include config.json
NEUTRINO_CONFIG_JSON
)"
if [ -z "$neutrino_tiers" ]; then
    echo "neutrino: no readable tier list in $script_path; refusing to launch" >&2
    exit 1
fi
has_tier() { case ",$neutrino_tiers," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

