#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:?repo root required}"
gpg_key_id="${2:?gpg key id required}"
config="${3:-}"

incoming="${repo_root}/incoming-debs"
index="${incoming}/.package-index.json"

if [[ ! -f "$index" ]]; then
  echo "Missing incoming-debs/.package-index.json" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deb-pkg-name.sh
source "${script_dir}/lib/deb-pkg-name.sh"

if [[ -n "$config" && -f "$config" ]]; then
  owner="$(jq -r '.owner' "$config")"
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    tag="$(jq -r --arg repo "$repo" '.[$repo].tag // empty' "$index")"
    [[ -n "$tag" ]] || continue
    mkdir -p "${incoming}/${repo}"
    while IFS= read -r filename; do
      [[ -n "$filename" ]] || continue
      deb="${incoming}/${repo}/${filename}"
      [[ -f "$deb" ]] && continue
      echo "Re-downloading missing ${filename} from ${owner}/${repo}@${tag}"
      gh release download "$tag" -R "${owner}/${repo}" \
        --pattern "$filename" \
        -D "${incoming}/${repo}" \
        --clobber
    done < <(jq -r --arg repo "$repo" '.[$repo].packages | keys[]?' "$index")
  done < <(jq -r 'keys[]' "$index")
fi

sed -i "s/SignWith: default/SignWith: ${gpg_key_id}/g" "${repo_root}/conf/distributions"

while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  tag="$(jq -r --arg repo "$repo" '.[$repo].tag' "$index")"

  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    deb="${incoming}/${repo}/${filename}"
    if [[ ! -f "$deb" ]]; then
      echo "Skipping ingest for ${filename} (${repo}@${tag}): not re-downloaded."
      continue
    fi

    mapfile -t suites < <(jq -r --arg repo "$repo" --arg file "$filename" '.[$repo].packages[$file].suites[]?' "$index")
    if [[ "${#suites[@]}" -eq 0 ]]; then
      echo "Skipping ${filename}: no suites in package index." >&2
      continue
    fi

    for suite in "${suites[@]}"; do
      if reprepro -b "$repo_root" includedeb "$suite" "$deb" 2>/tmp/reprepro.err; then
        echo "Added ${filename} to ${suite} (${repo}@${tag})"
        continue
      fi
      if grep -qiE 'already (exists|there|listed|in pool)|already registered' /tmp/reprepro.err; then
        echo "Already published: ${filename} (${suite})"
        continue
      fi
      cat /tmp/reprepro.err >&2
      exit 1
    done
  done < <(jq -r --arg repo "$repo" '.[$repo].packages | keys[]' "$index")
done < <(jq -r 'keys[]' "$index")
