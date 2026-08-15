#!/usr/bin/env bash
# Print space-separated reprepro codenames for a .deb, or nothing to skip it.
set -euo pipefail

base="$(basename "${1:?deb path required}")"

# Legacy builds for suites we do not publish.
if [[ "$base" =~ 0ubuntu0\.24\.04|ubuntu0\.24\.04 ]]; then
  exit 0
fi

if [[ "$base" =~ 0ubuntu0\.26\.04|ubuntu0\.26\.04 ]]; then
  printf '%s' resolute
elif [[ "$base" =~ 0ubuntu25\.10|ubuntu0\.25\.10|0ubuntu0\.25\.10 ]]; then
  printf '%s' questing
elif [[ "$base" =~ \+deb13|_deb13 ]]; then
  printf '%s' trixie
else
  printf '%s' 'trixie questing resolute'
fi
