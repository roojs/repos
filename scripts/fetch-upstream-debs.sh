#!/usr/bin/env bash
set -euo pipefail

incoming_dir="${1:-incoming}"
config_file="${2:-config/upstream-repos.json}"
repo_filter="${3:-}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required." >&2
  exit 1
fi

if [[ ! -f "${config_file}" ]]; then
  echo "Missing config file: ${config_file}" >&2
  exit 1
fi

owner="$(jq -r '.owner' "${config_file}")"
mapfile -t repos < <(jq -r '.repos[]' "${config_file}")

if [[ -n "${repo_filter}" ]]; then
  IFS=',' read -r -a filter_repos <<< "${repo_filter}"
  repos=("${filter_repos[@]}")
fi

mkdir -p "${incoming_dir}"
found=0

for repo in "${repos[@]}"; do
  repo="${repo//[[:space:]]/}"
  [[ -n "${repo}" ]] || continue

  release_json="$(gh release view -R "${owner}/${repo}" --json isPrerelease,tagName 2>/dev/null || true)"
  if [[ -z "${release_json}" ]]; then
    echo "Skipping ${owner}/${repo}: no latest release." >&2
    continue
  fi

  tag="$(jq -r '.tagName' <<< "${release_json}")"
  echo "Downloading .deb assets from ${owner}/${repo}@${tag} ..."

  if ! gh release download -R "${owner}/${repo}" \
    --pattern '*.deb' \
    -D "${incoming_dir}" \
    --clobber 2>/dev/null; then
    echo "Skipping ${owner}/${repo}@${tag}: no .deb assets." >&2
    continue
  fi

  found=1
done

shopt -s nullglob
debs=("${incoming_dir}"/*.deb)
if [[ "${#debs[@]}" -eq 0 ]]; then
  echo "No .deb packages downloaded from upstream releases." >&2
  exit 1
fi

echo "Downloaded packages:"
ls -lh "${incoming_dir}"/*.deb
