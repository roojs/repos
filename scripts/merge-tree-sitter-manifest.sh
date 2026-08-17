#!/usr/bin/env bash
# Merge deb, Fedora rpm, and openSUSE rpm tree-sitter manifest fragments.
set -euo pipefail

deb_manifest="${1:?deb manifest path required}"
rpm_manifest="${2:?Fedora rpm manifest path required}"
suse_manifest="${3:?openSUSE rpm manifest path required}"
output="${4:?output path required}"

jq -s '
  .[0].parsers as $deb | .[1].parsers as $rpm | .[2].parsers as $suse |
  {
    parsers: (
      (($deb | keys) + ($rpm | keys) + ($suse | keys) | unique) |
      map(. as $id |
        {
          ($id): {
            identity: ($deb[$id].identity // $rpm[$id].identity // $suse[$id].identity),
            deb: ($deb[$id].deb // empty),
            rpm: ($rpm[$id].rpm // empty),
            suse_rpm: ($suse[$id].suse_rpm // empty)
          }
        }
      ) | add
    )
  }
' "$deb_manifest" "$rpm_manifest" "$suse_manifest" > "$output"
