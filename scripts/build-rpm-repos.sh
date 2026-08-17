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

publish_rpm_opensuse() {
  local rpm="$1" release="$2" arch="$3"
  local base dest
  base="$(basename "${rpm}")"
  dest="${repo_root}/rpm/${release}/${arch}"
  mkdir -p "${dest}"
  cp -f "${rpm}" "${dest}/"
  echo "Added ${base} -> rpm/${release}/${arch}/"
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

  if [[ -f "$index" ]]; then
    meta="$(jq -c --arg file "$base" '
      [
        .[]
        | .packages[$file]?
        | select(.fedora and .arch)
        | {fedora: .fedora, arch: .arch}
      ]
      | .[0] // empty
    ' "$index")"
    if [[ -n "$meta" ]]; then
      arch="$(jq -r '.arch' <<< "$meta")"
      while IFS= read -r fc; do
        [[ -n "$fc" ]] || continue
        publish_rpm "$rpm" "$fc" "$arch"
      done < <(jq -r '.fedora[]' <<< "$meta")
      continue
    fi

    meta="$(jq -c --arg file "$base" '
      [
        .[]
        | .packages[$file]?
        | select(.opensuse and .arch)
        | {opensuse: .opensuse, arch: .arch}
      ]
      | .[0] // empty
    ' "$index")"
    if [[ -n "$meta" ]]; then
      arch="$(jq -r '.arch' <<< "$meta")"
      while IFS= read -r release; do
        [[ -n "$release" ]] || continue
        publish_rpm_opensuse "$rpm" "$release" "$arch"
      done < <(jq -r '.opensuse[]' <<< "$meta")
      continue
    fi
  fi

  if [[ "${base}" =~ \.fc([0-9]+)\.([^.]+)\.rpm$ ]]; then
    publish_rpm "$rpm" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    continue
  fi

  echo "Skipping ${base}: cannot parse Fedora release/arch from filename." >&2
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
