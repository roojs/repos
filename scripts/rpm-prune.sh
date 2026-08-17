#!/usr/bin/env bash
# Remove RPM files from gh-pages that are no longer in the publish manifest.
set -euo pipefail

repo_root="${1:?repo root required}"
manifest="${2:?manifest path required}"

if [[ ! -f "$manifest" ]]; then
  echo "Missing manifest: ${manifest}" >&2
  exit 1
fi

if [[ ! -d "${repo_root}/rpm" ]]; then
  echo "No RPM repository directories to prune."
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "pruned=false" >> "$GITHUB_OUTPUT"
    echo "removed_count=0" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

declare -A allowed=()
while IFS= read -r filename; do
  [[ -n "$filename" ]] || continue
  allowed["$filename"]=1
done < <(jq -r '.rpms[]?.packages | keys[]?' "$manifest")

removed=0
declare -A touched_dirs=()

shopt -s nullglob globstar
for rpm in "${repo_root}"/rpm/*/*/*.rpm; do
  [[ -f "$rpm" ]] || continue
  base="$(basename "$rpm")"
  if [[ -n "${allowed[$base]:-}" ]]; then
    continue
  fi
  echo "Removing ${rpm#${repo_root}/} (not in manifest)"
  rm -f "$rpm"
  touched_dirs["$(dirname "$rpm")"]=1
  removed=$((removed + 1))
done
shopt -u nullglob globstar

for dir in "${!touched_dirs[@]}"; do
  rm -rf "${dir}/repodata"
  if ! compgen -G "${dir}/*.rpm" > /dev/null; then
    echo "Removing empty directory ${dir#${repo_root}/}"
    rmdir "$dir" 2>/dev/null || true
    parent="$(dirname "$dir")"
    if [[ -d "$parent" ]] && [[ -z "$(ls -A "$parent" 2>/dev/null || true)" ]]; then
      rmdir "$parent" 2>/dev/null || true
    fi
  fi
done

if [[ "$removed" -gt 0 ]]; then
  echo "Pruned ${removed} RPM file(s)."
else
  echo "No stale RPM packages to prune."
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "pruned=$([[ "$removed" -gt 0 ]] && echo true || echo false)" >> "$GITHUB_OUTPUT"
  echo "removed_count=${removed}" >> "$GITHUB_OUTPUT"
fi
