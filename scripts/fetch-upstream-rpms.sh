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
downloaded=0

for repo in "${repos[@]}"; do
  repo="${repo//[[:space:]]/}"
  [[ -n "${repo}" ]] || continue

  release_json="$(gh release view -R "${owner}/${repo}" --json tagName 2>/dev/null || true)"
  if [[ -z "${release_json}" ]]; then
    echo "Skipping ${owner}/${repo}: no latest release." >&2
    continue
  fi

  tag="$(jq -r '.tagName' <<< "${release_json}")"
  echo "Downloading .rpm assets from ${owner}/${repo}@${tag} ..."

  if ! gh release download -R "${owner}/${repo}" \
    --pattern '*.rpm' \
    -D "${incoming_dir}" \
    --clobber 2>/dev/null; then
    echo "Skipping ${owner}/${repo}@${tag}: no .rpm assets." >&2
    continue
  fi

  downloaded=1
done

shopt -s nullglob
rpms=("${incoming_dir}"/*.rpm)
if [[ "${#rpms[@]}" -eq 0 ]]; then
  echo "No .rpm packages downloaded from upstream releases." >&2
  exit 0
fi

echo "Downloaded RPM packages:"
ls -lh "${incoming_dir}"/*.rpm
