script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# The tier list lives in exactly one place, the JavaScript region below, between
# the TIER_START and TIER_END sentinels, where build.sh stamps it. Reading it
# back out of the file rather than taking it from the environment means the
# shell and the JavaScript cannot disagree, and means no caller can weaken a
# build by exporting something.
#
# The sentinels are named here without their comment prefix on purpose. build.sh
# refuses a template that carries any of them more than once, and this paragraph
# spelling one in full is a second one -- caught by that check on the first
# build after it was written, which is the shape of hazard parse.sh exists for.
#
# Read between the sentinels rather than by taking the first line in the file
# that looks like a stamp. Everything below the RUNWEB_START sentinel is the
# app, it is arbitrary JavaScript, and a line of it shaped like the stamp is
# not the stamp.
# Measured on the three seds that assemble this project -- GNU, the one Git bash
# carries, and the BSD sed macOS ships -- a range address reads the same on each.
#
# An empty read used to become "default", which is the weakest tier this file
# has: an artifact stamped tight,offline would have launched with neither of
# them and said nothing about it. There is no artifact build.sh will produce
# without exactly one stamp -- it refuses to write one -- so a stamp this cannot
# read means the file is not the file it was built as. That is a refusal and not
# a fallback.
neutrino_tiers="$(sed -n '/\/\/#TIER_START/,/\/\/#TIER_END/s/^ *tiers: "\([a-z,]*\)",.*$/\1/p' "$script_path" | head -1)"
if [ -z "$neutrino_tiers" ]; then
    echo "neutrino: no readable tier stamp in $script_path; refusing to launch" >&2
    exit 1
fi
has_tier() { case ",$neutrino_tiers," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

