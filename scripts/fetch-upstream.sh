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
declare -A pool_file_suites=()
pool_work=""

pool_ensure_index() {
  local dest="$1" url="$2"
  if [[ -f "$dest" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if ! curl -fsSL "$url" | xzcat > "$dest"; then
    rm -f "$dest"
    return 1
  fi
}

pool_suite_index() {
  local suite="$1" arch="$2" dest="${pool_work}/suite-${suite}-${arch}.packages"
  if [[ -f "$dest" ]]; then
    printf '%s\n' "$dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  : > "$dest"
  if curl -fsSL "https://deb.debian.org/debian/dists/${suite}/main/binary-${arch}/Packages.xz" -o "${dest}.xz" 2>/dev/null; then
    xzcat "${dest}.xz" > "$dest"
    rm -f "${dest}.xz"
    printf '%s\n' "$dest"
    return 0
  fi
  rm -f "${dest}.xz"
  : > "$dest"
  local base="https://archive.ubuntu.com/ubuntu"
  if [[ "$arch" != "amd64" && "$arch" != "i386" ]]; then
    base="https://ports.ubuntu.com/ubuntu-ports"
  fi
  local comp
  for comp in main universe; do
    if ! curl -fsSL "${base}/dists/${suite}/${comp}/binary-${arch}/Packages.xz" | xzcat >> "$dest"; then
      rm -f "$dest"
      return 1
    fi
  done
  printf '%s\n' "$dest"
}

pool_suite_has_package() {
  local suite="$1" arch="$2" name="$3" idx
  idx="$(pool_suite_index "$suite" "$arch")" || return 1
  grep -qx "Package: ${name}" "$idx"
}

pool_suite_libc6() {
  local suite="$1" arch="$2" idx
  idx="$(pool_suite_index "$suite" "$arch")" || return 1
  awk '
    $0 == "Package: libc6" { hit = 1 }
    hit && /^Version:/ { print $2; exit }
    hit && /^$/ { exit }
  ' "$idx"
}

pool_sid_index() {
  local arch="$1" dest="${pool_work}/sid-${arch}.packages"
  pool_ensure_index "$dest" "https://deb.debian.org/debian/dists/sid/main/binary-${arch}/Packages.xz" || return 1
  printf '%s\n' "$dest"
}

pool_url_for_package() {
  local name="$1" arch="$2" idx filename
  idx="$(pool_sid_index "$arch")" || return 1
  filename="$(
    awk -v pkg="$name" '
      $0 == "Package: " pkg { hit = 1 }
      hit && /^Filename:/ { print $2; exit }
      hit && /^$/ { exit }
    ' "$idx"
  )"
  if [[ -z "$filename" ]]; then
    return 1
  fi
  printf 'https://deb.debian.org/debian/%s\n' "$(dirname "$filename")"
}

pool_list_filenames() {
  local pool="$1" name="$2" arch="$3" html
  html="$(curl -fsSL "${pool}/")"
  grep -oE "href=\"${name}_[^\"]+_${arch}\\.deb\"" <<< "$html" \
    | sed 's/^href="//;s/"$//' \
    | sort -V \
    | tac \
    || true
}

pool_filename_version() {
  local name="$1" arch="$2" filename="$3" ver
  ver="${filename#"${name}_"}"
  ver="${ver%"_${arch}.deb"}"
  printf '%s\n' "$ver"
}

pool_deb_fits_libc() {
  local deb="$1" suite_libc="$2" depends need
  depends="$(dpkg-deb -f "$deb" Depends 2>/dev/null || true)"
  need="$(sed -n 's/.*libc6 (>= \([^)]*\)).*/\1/p' <<< "$depends" | head -n1 || true)"
  if [[ -z "$need" ]]; then
    return 0
  fi
  dpkg --compare-versions "$suite_libc" ge "$need"
}

pool_deb_fits_suite() {
  local deb="$1" suite_libc="$2" arch="$3"
  local name op ver child_pool filename staged
  pool_deb_fits_libc "$deb" "$suite_libc" || return 1
  while IFS=$'\t' read -r name op ver; do
    [[ "$op" == "=" ]] || continue
    [[ "$name" == libc6 ]] && continue
    child_pool="$(pool_url_for_package "$name" "$arch")" || return 1
    filename="${name}_${ver}_${arch}.deb"
    staged="${pool_work}/staging/${filename}"
    mkdir -p "${pool_work}/staging"
    if [[ ! -s "$staged" ]]; then
      echo "Downloading ${filename}" >&2
      if ! curl -fsSL "${child_pool}/${filename}" -o "$staged"; then
        rm -f "$staged"
        return 1
      fi
    fi
    pool_deb_fits_libc "$staged" "$suite_libc" || return 1
  done < <(pool_relation_packages "$deb" Depends)
}

pool_skip_name() {
  local name="$1"
  [[ "$name" == python3-* ]] && return 0
  [[ "$name" == *-examples || "$name" == *-tests || "$name" == *-tools ]] && return 0
  [[ "$name" == libggml0-backend-hip ]] && return 0
  return 1
}

pool_seed_names() {
  local pool="$1" arch="$2" html filename name
  html="$(curl -fsSL "${pool}/")"
  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    name="${filename%%_*}"
    [[ "$name" == lib* ]] || continue
    pool_skip_name "$name" && continue
    printf '%s\n' "$name"
  done < <(
    grep -oE "href=\"lib[^\"]+_${arch}\\.deb\"" <<< "$html" \
      | sed 's/^href="//;s/"$//' \
      || true
  ) | sort -u
}

pool_relation_packages() {
  local deb="$1" field="$2" raw clause name rest
  raw="$(dpkg-deb -f "$deb" "$field" 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0
  raw="${raw//[$'\n']/ }"
  IFS=',' read -r -a clauses <<< "$raw"
  for clause in "${clauses[@]}"; do
    clause="${clause%%\[*}"
    clause="${clause%%|*}"
    clause="${clause#"${clause%%[![:space:]]*}"}"
    clause="${clause%"${clause##*[![:space:]]}"}"
    [[ -n "$clause" ]] || continue
    name="${clause%% *}"
    rest="${clause#"$name"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    pool_skip_name "$name" && continue
    if [[ "$rest" == \(*\) ]]; then
      rest="${rest#(}"
      rest="${rest%)}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      local rel_op="${rest%% *}"
      local rel_ver="${rest#* }"
      printf '%s\t%s\t%s\n' "$name" "$rel_op" "$rel_ver"
    else
      printf '%s\t\t\n' "$name"
    fi
  done
}

pool_pick_deb() {
  local pool="$1" name="$2" arch="$3" suite_libc="$4" op="${5:-}" ver="${6:-}"
  local filename deb_ver staged
  mkdir -p "${pool_work}/staging"
  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    deb_ver="$(pool_filename_version "$name" "$arch" "$filename")"
    if [[ -n "$op" && -n "$ver" ]]; then
      dpkg --compare-versions "$deb_ver" "$op" "$ver" || continue
    fi
    staged="${pool_work}/staging/${filename}"
    if [[ ! -s "$staged" ]]; then
      echo "Downloading ${filename}" >&2
      if ! curl -fsSL "${pool}/${filename}" -o "$staged"; then
        rm -f "$staged"
        continue
      fi
    fi
    if pool_deb_fits_suite "$staged" "$suite_libc" "$arch"; then
      printf '%s\n' "$staged"
      return 0
    fi
  done < <(pool_list_filenames "$pool" "$name" "$arch")
  return 1
}

pool_add_file_suite() {
  local base="$1" suite="$2" existing
  existing="${pool_file_suites[$base]:-}"
  if [[ " $existing " == *" $suite "* ]]; then
    return 0
  fi
  pool_file_suites[$base]="${existing} ${suite}"
}

pool_fetch_into() {
  local pool="$1" repo_dir="$2" allowlisted="$3"
  local arch suite libc name staged base op ver parent_suites child_pool
  local -a queue=()
  local -A queued=()

  while IFS= read -r arch; do
    [[ -n "$arch" ]] || continue
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      while IFS= read -r suite; do
        [[ -n "$suite" ]] || continue
        if pool_suite_has_package "$suite" "$arch" "$name"; then
          continue
        fi
        libc="$(pool_suite_libc6 "$suite" "$arch")"
        if [[ -z "$libc" ]]; then
          echo "Skipping ${name} for ${suite}/${arch}: could not read libc6 version." >&2
          continue
        fi
        if ! staged="$(pool_pick_deb "$pool" "$name" "$arch" "$libc")"; then
          echo "No Debian pool .deb for ${name} ${arch} fits ${suite} libc6 ${libc}." >&2
          continue
        fi
        base="$(basename "$staged")"
        cp -n "$staged" "${repo_dir}/${base}" 2>/dev/null || cp "$staged" "${repo_dir}/${base}"
        pool_add_file_suite "$base" "$suite"
        if [[ -z "${queued[$base]:-}" ]]; then
          queue+=("${repo_dir}/${base}")
          queued[$base]=1
        fi
      done <<< "$allowlisted"
    done < <(pool_seed_names "$pool" "$arch")
  done < <(jq -r '.apt.architectures[]' "$config")

  while [[ "${#queue[@]}" -gt 0 ]]; do
    local parent="${queue[0]}"
    queue=("${queue[@]:1}")
    base="$(basename "$parent")"
    parent_suites="${pool_file_suites[$base]:-}"
    arch="$(dpkg-deb -f "$parent" Architecture)"
    [[ "$arch" == "all" ]] && arch="$(jq -r '.apt.architectures[0]' "$config")"
    local field
    for field in Depends Recommends Suggests; do
      while IFS=$'\t' read -r name op ver; do
        [[ -n "$name" ]] || continue
        if ! child_pool="$(pool_url_for_package "$name" "$arch")"; then
          continue
        fi
        for suite in $parent_suites; do
          [[ -n "$suite" ]] || continue
          if pool_suite_has_package "$suite" "$arch" "$name"; then
            continue
          fi
          libc="$(pool_suite_libc6 "$suite" "$arch")"
          if [[ -z "$libc" ]]; then
            echo "Skipping ${name} for ${suite}/${arch}: could not read libc6 version." >&2
            continue
          fi
          if ! staged="$(pool_pick_deb "$child_pool" "$name" "$arch" "$libc" "$op" "$ver")"; then
            echo "No Debian pool .deb for ${name} ${arch} fits ${suite} libc6 ${libc}." >&2
            continue
          fi
          base="$(basename "$staged")"
          cp -n "$staged" "${repo_dir}/${base}" 2>/dev/null || cp "$staged" "${repo_dir}/${base}"
          pool_add_file_suite "$base" "$suite"
          if [[ -z "${queued[$base]:-}" ]]; then
            queue+=("${repo_dir}/${base}")
            queued[$base]=1
          fi
        done
      done < <(pool_relation_packages "$parent" "$field")
    done
  done
}

while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  project="$(repos_config_project_json "$config" "$repo")"
  [[ -n "$project" ]] || continue

  if [[ "$package_type" == "deb" ]]; then
    repos_config_fetch_debs "$project" || continue
  else
    repos_config_fetch_rpms "$project" || continue
  fi

  pool="$(jq -r '.pool // empty' <<< "$project")"
  pool_file_suites=()
  tag=""
  suites_json="null"
  repo_dir="${output}/${repo}"
  mkdir -p "$repo_dir"

  if [[ -n "$pool" ]]; then
    if [[ "$package_type" != "deb" ]]; then
      continue
    fi
    if ! suites="$(repos_config_deb_suites "$config" "$project" "")"; then
      echo "Skipping ${repo}: no deb suite mapping in config." >&2
      continue
    fi
    if [[ -z "$pool_work" ]]; then
      pool_work="$(mktemp -d)"
      trap 'rm -rf "$pool_work"' EXIT
    fi
    echo "Downloading pool packages for ${repo} ..."
    pool_fetch_into "$pool" "$repo_dir" "$suites"
    shopt -s nullglob
    for file in "${repo_dir}"/*.deb; do
      [[ -f "$file" ]] || continue
      if [[ "$(basename "$file")" == libllama0_* ]]; then
        tag="$(dpkg-deb -f "$file" Version)"
        break
      fi
    done
    if [[ -z "$tag" ]]; then
      for file in "${repo_dir}"/*.deb; do
        [[ -f "$file" ]] || continue
        tag="$(dpkg-deb -f "$file" Version)"
        break
      done
    fi
    if [[ -z "$tag" ]]; then
      echo "Skipping ${repo}: no pool .deb fitted any suite." >&2
      continue
    fi
  else
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

    echo "Downloading ${pattern} from ${owner}/${repo}@${tag} ..."
    if ! gh release download -R "${owner}/${repo}" \
      --pattern "$pattern" \
      -D "$repo_dir" \
      --clobber 2>/dev/null; then
      echo "Skipping ${owner}/${repo}@${tag}: no ${package_type} assets." >&2
      continue
    fi
  fi

  packages="{}"
  shopt -s nullglob
  for file in "${repo_dir}"/*."${package_type}"; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    if [[ "$package_type" == "rpm" ]] && [[ "$base" == *debuginfo* || "$base" == *debugsource* ]]; then
      rm -f "$file"
      echo "Skipping ${base}" >&2
      continue
    fi
    sha="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$package_type" == "deb" ]]; then
      file_suites_json="$suites_json"
      if [[ -n "${pool_file_suites[$base]+x}" ]]; then
        file_suites_json="$(printf '%s\n' ${pool_file_suites[$base]} | awk 'NF' | jq -R . | jq -s .)"
      fi
      packages="$(jq \
        --arg name "$base" \
        --arg sha "$sha" \
        --argjson suites "$file_suites_json" \
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
