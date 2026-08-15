#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:?repo root required}"
gpg_key_id="${2:?gpg key id required}"
incoming="${repo_root}/incoming-debs"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "${repo_root}"
sed -i "s/SignWith: default/SignWith: ${gpg_key_id}/g" conf/distributions

shopt -s nullglob
debs=("${incoming}"/*.deb)

for deb in "${debs[@]}"; do
  suites="$("${script_dir}/deb-target-suites.sh" "${deb}" || true)"
  if [[ -z "${suites}" ]]; then
    echo "Skipping $(basename "${deb}") (unsupported target series)"
    continue
  fi

  for distro in ${suites}; do
    if reprepro -b . includedeb "${distro}" "${deb}" 2>/tmp/reprepro.err; then
      echo "Added $(basename "${deb}") to ${distro}"
      continue
    fi
    if grep -qiE 'already (exists|there|listed|in pool)|is already registered' /tmp/reprepro.err; then
      echo "Already published: $(basename "${deb}") (${distro})"
      continue
    fi
    cat /tmp/reprepro.err >&2
    exit 1
  done
done
