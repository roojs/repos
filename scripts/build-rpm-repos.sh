#!/usr/bin/env bash
set -euo pipefail

incoming_dir="${1:?incoming directory required}"
repo_root="${2:?repo root required}"

shopt -s nullglob
rpms=("${incoming_dir}"/*.rpm)
if [[ "${#rpms[@]}" -eq 0 ]]; then
  echo "No RPM packages to publish."
  exit 0
fi

for rpm in "${rpms[@]}"; do
  base="$(basename "${rpm}")"

  if [[ "${base}" == *debuginfo* || "${base}" == *debugsource* ]]; then
    echo "Skipping ${base}"
    continue
  fi

  if [[ ! "${base}" =~ \.fc([0-9]+)\.([^.]+)\.rpm$ ]]; then
    echo "Skipping ${base}: cannot parse Fedora release/arch from filename." >&2
    continue
  fi

  fc="${BASH_REMATCH[1]}"
  arch="${BASH_REMATCH[2]}"
  dest="${repo_root}/rpm/fc${fc}/${arch}"
  mkdir -p "${dest}"
  cp -f "${rpm}" "${dest}/"
  echo "Added ${base} -> rpm/fc${fc}/${arch}/"
done

mapfile -t repo_dirs < <(find "${repo_root}/rpm" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
if [[ "${#repo_dirs[@]}" -eq 0 ]]; then
  echo "No RPM repository directories were created." >&2
  exit 1
fi

for dir in "${repo_dirs[@]}"; do
  if ! compgen -G "${dir}/*.rpm" > /dev/null; then
    continue
  fi

  echo "Building repodata in ${dir} ..."
  if [[ -d "${dir}/repodata" ]]; then
    createrepo_c --update "${dir}"
  else
    createrepo_c "${dir}"
  fi

  gpg --batch --yes --detach-sign --armor \
    -o "${dir}/repodata/repomd.xml.asc" \
    "${dir}/repodata/repomd.xml"
done

echo "RPM repositories:"
find "${repo_root}/rpm" -type f \( -name '*.rpm' -o -path '*/repodata/*' \) | sort
