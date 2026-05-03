#!/bin/sh
# lgpl_audit.sh — walk a vendored libcrun (or libseccomp) source tree
# and print a Markdown table mapping each *.c / *.h to the SPDX license
# tag it declares.
#
# Usage:
#   scripts/lgpl_audit.sh <dir>
#
# Exit code:
#   0 — all files declare LGPL-2.1-or-later, LGPL-2.1-only, BSD-*, ISC,
#       MIT, Apache-2.0, CC0-1.0, or otherwise LGPL-compatible licences,
#       OR no SPDX tag (logged but not fatal — manual review needed).
#   1 — at least one file declares GPL-2.0 / GPL-3.0 (without LGPL
#       counterpart) AND is in build/cdeps/crun/SOURCES.md (i.e. compiled
#       into rind). Halts T17 adoption per the escape hatch.
#
# Output is on stdout; pipe into THIRD_PARTY_LICENSES.md "Per-file LGPL
# audit" table.

set -eu

if [ $# -ne 1 ]; then
    printf 'usage: %s <dir>\n' "$0" >&2
    exit 2
fi

dir=$1

if [ ! -d "$dir" ]; then
    printf 'lgpl_audit.sh: not a directory: %s\n' "$dir" >&2
    exit 2
fi

# A files file lives next to this script — one rel-path-from-vendor per
# line — listing the source files actually compiled by build.zig. Used
# only for the BLOCKER check; absent file → audit emits the table but
# never blocks.
sources_list=
case "$dir" in
    */libcrun*) sources_list=build/cdeps/crun/SOURCES.md ;;
    *seccomp*)  sources_list=build/cdeps/seccomp/SOURCES.md ;;
esac

# Header.
printf '| File | Declared license | Action |\n'
printf '|---|---|---|\n'

blocker_hit=0

# Iterate deterministically.
files=$(find "$dir" \( -name '*.c' -o -name '*.h' \) -print | LC_ALL=C sort)

for f in $files; do
    rel=${f#"$dir/"}
    spdx=$(head -n 30 "$f" | grep -i 'SPDX-License-Identifier' | head -n 1 \
            | sed -E 's/^.*SPDX-License-Identifier:[[:space:]]*//I; s/[[:space:]]*\*\/.*$//; s/[[:space:]]*$//' \
        || true)

    if [ -z "$spdx" ]; then
        # No SPDX tag. Try fuzzy classification on the comment header.
        if head -n 30 "$f" | grep -q 'GNU Lesser General Public'; then
            spdx='LGPL-2.1 (no SPDX; from comment)'
        elif head -n 30 "$f" | grep -q 'GNU General Public License'; then
            spdx='GPL-2.0 (no SPDX; from comment)'
        else
            spdx='UNKNOWN (no SPDX; manual review)'
        fi
    fi

    action=linked
    case "$spdx" in
        *GPL-2.0* | *GPL-3.0*)
            case "$spdx" in
                *LGPL*) ;;
                *)
                    action='**BLOCKER (GPL)**'
                    if [ -n "$sources_list" ] && [ -f "$sources_list" ] \
                            && grep -qF "$rel" "$sources_list"; then
                        blocker_hit=1
                    fi
                    ;;
            esac
            ;;
    esac

    printf '| %s | %s | %s |\n' "$rel" "$spdx" "$action"
done

if [ "$blocker_hit" -ne 0 ]; then
    printf '\n**BLOCKER:** at least one GPL-licensed file is compiled into rind.\n' >&2
    printf 'Per T17 escape hatch (THIRD_PARTY_LICENSES.md): pivot to youki.\n' >&2
    exit 1
fi
