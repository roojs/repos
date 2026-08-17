#!/usr/bin/env bash
# Merge deb and rpm tree-sitter manifest fragments into one release manifest.
set -euo pipefail

deb_manifest="${1:?deb manifest path required}"
rpm_manifest="${2:?rpm manifest path required}"
output="${3:?output path required}"

jq -s '
  .[0].parsers as $deb | .[1].parsers as $rpm |
  {
    parsers: (
      (($deb | keys) + ($rpm | keys) | unique) |
      map(. as $id |
        {
          ($id): {
            identity: ($deb[$id].identity // $rpm[$id].identity),
            deb: ($deb[$id].deb // empty),
            rpm: ($rpm[$id].rpm // empty)
          }
        }
      ) | add
    )
  }
' "$deb_manifest" "$rpm_manifest" > "$output"
