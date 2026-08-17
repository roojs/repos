#!/usr/bin/env bash
# Remove APT packages from reprepro that are no longer in the publish manifest.
set -euo pipefail

repo_root="${1:?repo root required}"
config="${2:?config path required}"
manifest="${3:?manifest path required}"

if [[ ! -f "$manifest" ]]; then
  echo "Missing manifest: ${manifest}" >&2
  exit 1
fi

deb_pkg_from_filename() {
  local filename="$1"
  printf '%s\n' "${filename%%_*}"
}

removed=0
declare -A allowed=()

while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    pkg="$(deb_pkg_from_filename "$filename")"
    while IFS= read -r suite; do
      [[ -n "$suite" ]] || continue
      allowed["${suite}:${pkg}"]=1
    done < <(jq -r --arg repo "$repo" --arg file "$filename" '
      .debs[$repo].packages[$file].suites[]? // empty
    ' "$manifest")
  done < <(jq -r --arg repo "$repo" '.debs[$repo].packages | keys[]?' "$manifest")
done < <(jq -r '.debs | keys[]?' "$manifest")

while IFS= read -r suite; do
  [[ -n "$suite" ]] || continue
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pkg="$(awk '{print $1}' <<< "$line")"
    [[ -n "$pkg" ]] || continue
    if [[ -n "${allowed[${suite}:${pkg}]:-}" ]]; then
      continue
    fi
    echo "Removing ${pkg} from ${suite} (not in manifest)"
    reprepro -b "$repo_root" remove "$suite" "$pkg"
    removed=$((removed + 1))
  done < <(reprepro -b "$repo_root" list "$suite" 2>/dev/null || true)
done < <(jq -r '.apt.suites[]' "$config")

if [[ "$removed" -gt 0 ]]; then
  echo "Pruned ${removed} package(s) from reprepro."
else
  echo "No stale reprepro packages to prune."
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "pruned=$([[ "$removed" -gt 0 ]] && echo true || echo false)" >> "$GITHUB_OUTPUT"
  echo "removed_count=${removed}" >> "$GITHUB_OUTPUT"
fi
