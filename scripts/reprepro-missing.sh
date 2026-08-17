#!/usr/bin/env bash
# True when the publish manifest lists packages not present in reprepro.
set -euo pipefail

repo_root="${1:?repo root required}"
config="${2:?config path required}"
manifest="${3:?manifest path required}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deb-pkg-name.sh
source "${script_dir}/lib/deb-pkg-name.sh"

suite_has_package() {
  local suite="$1" pkg="$2" arch pkgfile
  while IFS= read -r arch; do
    [[ -n "$arch" ]] || continue
    pkgfile="${repo_root}/dists/${suite}/main/binary-${arch}/Packages"
    [[ -f "$pkgfile" ]] || continue
    if grep -qx "Package: ${pkg}" "$pkgfile"; then
      return 0
    fi
  done < <(jq -r '.apt.architectures[]' "$config")
  return 1
}

missing=0

while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    pkg="$(deb_pkg_name_from_filename "$filename")"
    while IFS= read -r suite; do
      [[ -n "$suite" ]] || continue
      if suite_has_package "$suite" "$pkg"; then
        continue
      fi
      echo "Missing from ${suite}: ${pkg} (${filename})"
      missing=$((missing + 1))
    done < <(jq -r --arg repo "$repo" --arg file "$filename" '
      .debs[$repo].packages[$file].suites[]? // empty
    ' "$manifest")
  done < <(jq -r --arg repo "$repo" '.debs[$repo].packages | keys[]?' "$manifest")
done < <(jq -r '.debs | keys[]?' "$manifest")

if [[ "$missing" -gt 0 ]]; then
  echo "${missing} manifest package(s) missing from reprepro."
else
  echo "All manifest packages are published."
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "missing=$([[ "$missing" -gt 0 ]] && echo true || echo false)" >> "$GITHUB_OUTPUT"
  echo "missing_count=${missing}" >> "$GITHUB_OUTPUT"
fi
