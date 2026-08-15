#!/usr/bin/env bash
set -euo pipefail

config="${1:?config path required}"
output="${2:?output directory required}"
package_type="${3:?deb or rpm required}"
repo_filter="${4:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repos-config.sh
source "${script_dir}/lib/repos-config.sh"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required." >&2
  exit 1
fi

owner="$(jq -r '.owner' "$config")"
mkdir -p "$output"
index="{}"
found=0

while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  project="$(repos_config_project_json "$config" "$repo")"
  [[ -n "$project" ]] || continue

  if [[ "$package_type" == "deb" ]]; then
    repos_config_fetch_debs "$project" || continue
  else
    repos_config_fetch_rpms "$project" || continue
  fi

  tag="$(gh release view -R "${owner}/${repo}" --json tagName -q .tagName 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    echo "Skipping ${owner}/${repo}: no latest release." >&2
    continue
  fi

  if [[ "$package_type" == "deb" ]]; then
    if ! suites="$(repos_config_deb_suites "$config" "$project" "$tag")"; then
      echo "Skipping ${owner}/${repo}@${tag}: no deb suite mapping in config." >&2
      continue
    fi
    suites_json="$(printf '%s\n' "$suites" | jq -R . | jq -s .)"
  else
    suites_json="null"
  fi

  pattern='*.deb'
  [[ "$package_type" == "rpm" ]] && pattern='*.rpm'

  repo_dir="${output}/${repo}"
  mkdir -p "$repo_dir"
  echo "Downloading ${pattern} from ${owner}/${repo}@${tag} ..."
  if ! gh release download -R "${owner}/${repo}" \
    --pattern "$pattern" \
    -D "$repo_dir" \
    --clobber 2>/dev/null; then
    echo "Skipping ${owner}/${repo}@${tag}: no ${package_type} assets." >&2
    continue
  fi

  packages="{}"
  shopt -s nullglob
  for file in "${repo_dir}/${pattern}"; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    if [[ "$package_type" == "rpm" ]] && [[ "$base" == *debuginfo* || "$base" == *debugsource* ]]; then
      rm -f "$file"
      echo "Skipping ${base}" >&2
      continue
    fi
    sha="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$package_type" == "deb" ]]; then
      packages="$(jq \
        --arg name "$base" \
        --arg sha "$sha" \
        --argjson suites "$suites_json" \
        '. + {($name): {sha256: $sha, suites: $suites}}' \
        <<< "$packages")"
    else
      packages="$(jq \
        --arg name "$base" \
        --arg sha "$sha" \
        '. + {($name): {sha256: $sha}}' \
        <<< "$packages")"
    fi
  done

  if [[ "$packages" == "{}" ]]; then
    continue
  fi

  index="$(jq \
    --arg repo "$repo" \
    --arg tag "$tag" \
    --argjson packages "$packages" \
    '. + {($repo): {tag: $tag, packages: $packages}}' \
    <<< "$index")"
  found=1
done < <(repos_config_project_names "$config" "$repo_filter")

printf '%s\n' "$index" | jq . > "${output}/.package-index.json"

if [[ "$found" -eq 0 ]]; then
  echo "No ${package_type} packages downloaded." >&2
  exit 1
fi

jq . "${output}/.package-index.json"
