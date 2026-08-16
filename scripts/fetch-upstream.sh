#!/usr/bin/env bash
set -euo pipefail

config="${1:?config path required}"
output="${2:?output directory required}"
package_type="${3:?deb or rpm required}"
repo_filter="${4:-}"
previous_manifest="${5:-}"

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
previous_index="{}"
can_skip=false
fetch_force="${FETCH_FORCE:-false}"

if [[ -n "$previous_manifest" && -f "$previous_manifest" ]]; then
  previous_index="$(jq -c --arg kind "$package_type" '
    if $kind == "deb" then (.debs // {}) else (.rpms // {}) end
  ' "$previous_manifest")"
  if [[ "$fetch_force" != "true" ]]; then
    prev_config_sha="$(jq -r '.repos_json_sha256 // empty' "$previous_manifest")"
    curr_config_sha="$(sha256sum "$config" | awk '{print $1}')"
    if [[ -n "$prev_config_sha" && "$prev_config_sha" == "$curr_config_sha" ]]; then
      can_skip=true
    fi
  fi
fi

if [[ "$can_skip" == "true" ]]; then
  echo "Skipping downloads for unchanged ${package_type} packages."
elif [[ "$fetch_force" == "true" ]]; then
  echo "FETCH_FORCE=true: downloading all ${package_type} packages."
else
  echo "Downloading ${package_type} packages (no matching previous publish)."
fi

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

pool_sid_index() {
  local arch="$1" dest="${pool_work}/sid-${arch}.packages"
  if [[ -f "$dest" ]]; then
    printf '%s\n' "$dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if ! curl -fsSL "https://deb.debian.org/debian/dists/sid/main/binary-${arch}/Packages.xz" | xzcat > "$dest"; then
    rm -f "$dest"
    return 1
  fi
  printf '%s\n' "$dest"
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

pool_index_depends() {
  local idx="$1" name="$2"
  awk -v pkg="$name" '
    $0 == "Package: " pkg { hit = 1; next }
    hit && /^Depends:/ {
      val = substr($0, 10)
      collecting = 1
      next
    }
    hit && collecting && /^ / {
      val = val $0
      next
    }
    hit && collecting { print val; exit }
    hit && /^$/ { exit }
  ' "$idx"
}

pool_sid_libc_need() {
  local name="$1" arch="$2" idx depends
  idx="$(pool_sid_index "$arch")" || return 1
  if ! grep -qx "Package: ${name}" "$idx"; then
    return 1
  fi
  depends="$(pool_index_depends "$idx" "$name")"
  sed -n 's/.*libc6 (>= \([^)]*\)).*/\1/p' <<< "$depends" | head -n1
}

# True when the sid (newest) build of this package can install on an allowlisted suite.
pool_newest_fits_allowlist() {
  local name="$1" arch="$2" allowlisted="$3" idx need suite suite_libc
  idx="$(pool_sid_index "$arch")" || return 1
  if ! grep -qx "Package: ${name}" "$idx"; then
    return 1
  fi
  need="$(pool_sid_libc_need "$name" "$arch" || true)"
  if [[ -z "$need" ]]; then
    return 0
  fi
  while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    suite_libc="$(pool_suite_libc6 "$suite" "$arch")" || continue
    [[ -n "$suite_libc" ]] || continue
    if dpkg --compare-versions "$suite_libc" ge "$need"; then
      return 0
    fi
  done <<< "$allowlisted"
  return 1
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

previous_repo_json() {
  jq -c --arg repo "$1" '.[$repo] // empty' <<< "$previous_index"
}

keep_previous_repo() {
  local repo="$1" reason="$2" prev
  prev="$(previous_repo_json "$repo")"
  if [[ -z "$prev" ]]; then
    return 1
  fi
  echo "$reason" >&2
  index="$(jq --arg repo "$repo" --argjson prev "$prev" '. + {($repo): $prev}' <<< "$index")"
  found=1
  return 0
}

github_should_skip() {
  local prev_repo="$1" release_json="$2" ext="$3"
  [[ "$can_skip" == "true" ]] || return 1
  [[ -n "$prev_repo" ]] || return 1
  jq -en --argjson prev "$prev_repo" --argjson rel "$release_json" --arg ext "$ext" '
    def relevant_name:
      select(.name | endswith("." + $ext))
      | select($ext != "rpm" or (.name | test("debuginfo|debugsource") | not))
      | .name;
    ($prev.tag == $rel.tagName)
    and (($prev.packages | keys | sort) == ([ $rel.assets[] | relevant_name ] | sort))
    and (
      [
        $rel.assets[]
        | select((.digest // "") != "")
        | select(.name | endswith("." + $ext))
        | select($ext != "rpm" or (.name | test("debuginfo|debugsource") | not))
      ]
      | all(
          (.digest | sub("^sha256:"; "")) == ($prev.packages[.name].sha256 // "")
        )
    )
  ' >/dev/null
}

github_latest_release_tag() {
  local owner="$1" repo="$2" project="$3" tag pattern
  if jq -e '.deb.release_tags' >/dev/null <<< "$project"; then
    while IFS= read -r tag; do
      [[ -n "$tag" ]] || continue
      while IFS= read -r pattern; do
        [[ -n "$pattern" ]] || continue
        if [[ "$tag" == $pattern ]]; then
          printf '%s\n' "$tag"
          return 0
        fi
      done < <(jq -r '.deb.release_tags | keys[]' <<< "$project")
    done < <(gh release list -R "${owner}/${repo}" --limit 100 --json tagName --jq '.[].tagName')
    return 1
  fi
  gh release view -R "${owner}/${repo}" --json tagName -q '.tagName // empty'
}

pool_should_skip() {
  local pool="$1" prev_repo="$2" allowlisted="$3" arch html filename name ver prev_file prev_ver
  [[ "$can_skip" == "true" ]] || return 1
  [[ -n "$prev_repo" ]] || return 1

  html="$(curl -fsSL "${pool}/")" || return 1

  declare -A newest_ver=()
  while IFS= read -r arch; do
    [[ -n "$arch" ]] || continue
    while IFS= read -r filename; do
      [[ -n "$filename" ]] || continue
      name="${filename%%_*}"
      [[ "$name" == lib* ]] || continue
      pool_skip_name "$name" && continue
      ver="$(pool_filename_version "$name" "$arch" "$filename")"
      if [[ -z "${newest_ver[${name}:${arch}]:-}" ]] \
        || dpkg --compare-versions "$ver" gt "${newest_ver[${name}:${arch}]}"; then
        newest_ver["${name}:${arch}"]="$ver"
      fi
    done < <(
      grep -oE "href=\"lib[^\"]+_${arch}\\.deb\"" <<< "$html" \
        | sed 's/^href="//;s/"$//' \
        || true
    )
  done < <(jq -r '.apt.architectures[]' "$config")

  [[ "${#newest_ver[@]}" -gt 0 ]] || return 1

  local key
  for key in "${!newest_ver[@]}"; do
    name="${key%%:*}"
    arch="${key#*:}"
    prev_file="$(
      jq -r --arg prefix "${name}_" --arg suffix "_${arch}.deb" '
        [.packages | keys[] | select(startswith($prefix) and endswith($suffix))] | first // empty
      ' <<< "$prev_repo"
    )"
    if [[ -z "$prev_file" ]]; then
      if pool_newest_fits_allowlist "$name" "$arch" "$allowlisted"; then
        echo "Pool has new package ${name} (${arch}) that fits a suite." >&2
        return 1
      fi
      echo "Pool has new ${name} (${arch}) that does not fit suite libc; ignoring." >&2
      continue
    fi
    prev_ver="$(pool_filename_version "$name" "$arch" "$prev_file")"
    if dpkg --compare-versions "${newest_ver[$key]}" gt "$prev_ver"; then
      if pool_newest_fits_allowlist "$name" "$arch" "$allowlisted"; then
        echo "Pool has newer ${name} ${arch} that fits a suite: ${newest_ver[$key]} > ${prev_ver}." >&2
        return 1
      fi
      echo "Pool has newer ${name} ${arch} (${newest_ver[$key]}) that does not fit suite libc; keeping ${prev_ver}." >&2
    fi
  done
  return 0
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
    if pool_should_skip "$pool" "$(previous_repo_json "$repo")" "$suites"; then
      if keep_previous_repo "$repo" "Skipping pool download for ${repo}: no newer packages that fit any suite."; then
        continue
      fi
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
      if keep_previous_repo "$repo" "Keeping previously published ${repo}: no pool .deb fitted any suite."; then
        continue
      fi
      echo "Skipping ${repo}: no pool .deb fitted any suite." >&2
      continue
    fi
  else
    tag="$(github_latest_release_tag "$owner" "$repo" "$project")"
    if [[ -n "$tag" ]]; then
      release_json="$(gh release view "$tag" -R "${owner}/${repo}" --json tagName,assets 2>/dev/null || true)"
    else
      release_json=""
    fi
    if [[ -z "$tag" || -z "$release_json" ]]; then
      if keep_previous_repo "$repo" "Keeping previously published ${owner}/${repo}: no latest release."; then
        continue
      fi
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

    if github_should_skip "$(previous_repo_json "$repo")" "$release_json" "$package_type"; then
      if keep_previous_repo "$repo" "Skipping download for ${owner}/${repo}@${tag}: already published."; then
        continue
      fi
    fi

    pattern='*.deb'
    [[ "$package_type" == "rpm" ]] && pattern='*.rpm'

    echo "Downloading ${pattern} from ${owner}/${repo}@${tag} ..."
    if ! gh release download -R "${owner}/${repo}" \
      --pattern "$pattern" \
      -D "$repo_dir" \
      --clobber 2>/dev/null; then
      if keep_previous_repo "$repo" "Keeping previously published ${owner}/${repo}@${tag}: no ${package_type} assets."; then
        continue
      fi
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

if [[ -n "$repo_filter" ]]; then
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    if jq -e --arg repo "$repo" 'has($repo)' <<< "$index" >/dev/null; then
      continue
    fi
    keep_previous_repo "$repo" "Keeping previously published ${repo}: not in this run's repo filter."
  done < <(jq -r 'keys[]' <<< "$previous_index")
fi

printf '%s\n' "$index" | jq . > "${output}/.package-index.json"

if [[ "$found" -eq 0 ]]; then
  echo "No ${package_type} packages downloaded." >&2
  exit 1
fi

jq . "${output}/.package-index.json"
