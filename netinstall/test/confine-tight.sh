#!/bin/bash
# confine-tight.sh - confine.sh, pointed at the tight tier
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# The /proc write grant is the one rule that differs between the two tiers, and
# confine.sh keys those assertions on what the binary reports rather than on how
# it was invoked -- so the only way to hold the tight tier to its own answer is
# to hand confine.sh the tight binary. Same instrument as the default tier's
# run, which is what makes the two comparable; a second payload would only be
# comparable to itself.
#
# confine-strict.sh drives the same binary for what the tier is mainly about --
# reads, write xor execute, and whether a webview still starts under it. This is
# the narrower question of what the ruleset does to /proc, asked with the tool
# that asked it of the default tier.
exec bash "$(dirname "$0")/confine.sh" "$@"
