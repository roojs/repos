#!/usr/bin/env bash
set -euo pipefail

incoming_dir="${1:?incoming directory required}"
repo_root="${2:?repo root required}"
index="${incoming_dir}/.package-index.json"

publish_rpm() {
  local rpm="$1" fc="$2" arch="$3"
  local base dest
  base="$(basename "${rpm}")"
  dest="${repo_root}/rpm/fc${fc}/${arch}"
  mkdir -p "${dest}"
  cp -f "${rpm}" "${dest}/"
  echo "Added ${base} -> rpm/fc${fc}/${arch}/"
}

shopt -s nullglob globstar
mapfile -t rpms < <(find "${incoming_dir}" -mindepth 2 -maxdepth 2 -type f -name '*.rpm' | sort)
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

  if [[ "${base}" =~ \.fc([0-9]+)\.([^.]+)\.rpm$ ]]; then
    publish_rpm "$rpm" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    continue
  fi

  if [[ ! -f "$index" ]]; then
    echo "Skipping ${base}: cannot parse Fedora release/arch from filename." >&2
    continue
  fi

  meta="$(jq -c --arg file "$base" '
    [
      .[]
      | .packages[$file]?
      | select(.fedora and .arch)
      | {fedora: .fedora, arch: .arch}
    ]
    | .[0] // empty
  ' "$index")"
  if [[ -z "$meta" ]]; then
    echo "Skipping ${base}: no Fedora metadata in package index." >&2
    continue
  fi

  arch="$(jq -r '.arch' <<< "$meta")"
  while IFS= read -r fc; do
    [[ -n "$fc" ]] || continue
    publish_rpm "$rpm" "$fc" "$arch"
  done < <(jq -r '.fedora[]' <<< "$meta")
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
