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
rpm_pool_work=""
previous_index="{}"
fetch_force="${FETCH_FORCE:-false}"
has_previous_manifest=false

if [[ -n "$previous_manifest" && -f "$previous_manifest" ]]; then
  has_previous_manifest=true
  previous_index="$(jq -c --arg kind "$package_type" '
    if $kind == "deb" then (.debs // {}) else (.rpms // {}) end
  ' "$previous_manifest")"
fi

if [[ "$fetch_force" == "true" ]]; then
  echo "FETCH_FORCE=true: downloading all ${package_type} packages."
elif [[ "$has_previous_manifest" == "true" ]]; then
  echo "Checking ${package_type} packages against previous publish (release tags and file names)."
else
  echo "Downloading ${package_type} packages (no previous publish manifest)."
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
  local comp tmp_xz
  for comp in main universe; do
    tmp_xz="${dest}.xz"
    if ! curl -fsSL "${base}/dists/${suite}/${comp}/binary-${arch}/Packages.xz" -o "$tmp_xz"; then
      rm -f "$dest" "$tmp_xz"
      return 1
    fi
    if ! xzcat "$tmp_xz" >> "$dest"; then
      rm -f "$dest" "$tmp_xz"
      return 1
    fi
    rm -f "$tmp_xz"
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

pool_index_package_version() {
  local idx="$1" name="$2"
  awk -v pkg="$name" '
    $0 == "Package: " pkg { hit = 1 }
    hit && /^Version:/ { print $2; exit }
    hit && /^$/ { exit }
  ' "$idx"
}

pool_libc_need_from_depends() {
  local depends="$1"
  sed -n 's/.*libc6 (>= \([^)]*\)).*/\1/p' <<< "$depends" | head -n1
}

pool_index_libc_need() {
  local idx="$1" name="$2" depends
  depends="$(pool_index_depends "$idx" "$name")"
  pool_libc_need_from_depends "$depends"
}

pool_sid_libc_need() {
  local name="$1" arch="$2" idx
  idx="$(pool_sid_index "$arch")" || return 1
  if ! grep -qx "Package: ${name}" "$idx"; then
    return 1
  fi
  pool_index_libc_need "$idx" "$name"
}

# Read libc6 (>= …) from a .deb on disk. Used only for older pool revisions
# that are no longer listed in the sid Packages index.
pool_read_deb_libc_need() {
  local deb="$1" depends
  depends="$(dpkg-deb -f "$deb" Depends 2>/dev/null || true)"
  pool_libc_need_from_depends "$depends"
}

declare -A pool_libc_cache=()

# Resolve libc requirement for a pool filename. Prefer the sid Packages index
# (no .deb download). Fall back to reading control from the .deb only for
# older revisions still in the pool but dropped from sid.
pool_libc_need_for_filename() {
  pool_effective_libc_need_for_filename "$@"
}

pool_libc_fits() {
  local need="$1" suite_libc="$2"
  [[ -z "$need" ]] && return 0
  dpkg --compare-versions "$suite_libc" ge "$need"
}

pool_depends_for_filename() {
  local name="$1" arch="$2" filename="$3" pool="$4"
  local idx sid_ver ver staged depends

  ver="$(pool_filename_version "$name" "$arch" "$filename")"
  idx="$(pool_sid_index "$arch")"
  sid_ver="$(pool_index_package_version "$idx" "$name")"
  if [[ -n "$sid_ver" && "$ver" == "$sid_ver" ]]; then
    pool_index_depends "$idx" "$name"
    return 0
  fi

  staged="${pool_work}/staging/${filename}"
  if [[ ! -s "$staged" ]]; then
    echo "Reading libc metadata from ${filename}" >&2
    mkdir -p "${pool_work}/staging"
    if ! curl -fsSL "${pool}/${filename}" -o "$staged"; then
      rm -f "$staged"
      return 1
    fi
  fi
  dpkg-deb -f "$staged" Depends 2>/dev/null || true
}

# Effective libc floor: this package's own Depends, or pinned (=) library deps.
pool_effective_libc_need_for_filename() {
  local name="$1" arch="$2" filename="$3" pool="$4"
  local cache_key="${filename}#libc"
  local depends need dep_name dep_ver child_pool child_file child_need max_need

  if [[ -n "${pool_libc_cache[$cache_key]:-}" ]]; then
    printf '%s\n' "${pool_libc_cache[$cache_key]}"
    return 0
  fi

  depends="$(pool_depends_for_filename "$name" "$arch" "$filename" "$pool")" || return 1
  need="$(pool_libc_need_from_depends "$depends")"
  max_need="$need"

  while IFS=$'\t' read -r dep_name dep_op dep_ver; do
    [[ "$dep_op" == "=" ]] || continue
    [[ -n "$dep_name" && -n "$dep_ver" ]] || continue
    pool_never_republish "$dep_name" && continue
    child_pool="$(pool_url_for_package "$dep_name" "$arch")" || continue
    child_file="${dep_name}_${dep_ver}_${arch}.deb"
    child_need="$(pool_effective_libc_need_for_filename "$dep_name" "$arch" "$child_file" "$child_pool")" || continue
    if [[ -z "$max_need" ]] || dpkg --compare-versions "$child_need" gt "$max_need"; then
      max_need="$child_need"
    fi
  done < <(pool_relation_packages_from_raw "$depends" Depends)

  pool_libc_cache[$cache_key]="${max_need:-}"
  printf '%s\n' "${max_need:-}"
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
  need="$(pool_libc_need_from_depends "$depends")"
  pool_libc_fits "$need" "$suite_libc"
}

pool_skip_name() {
  local name="$1"
  [[ "$name" == python3-* ]] && return 0
  [[ "$name" == *-examples || "$name" == *-tests || "$name" == *-tools ]] && return 0
  [[ "$name" == libggml0-backend-hip ]] && return 0
  return 1
}

# True when the target suite already publishes this package (Debian/Ubuntu).
# Those deps are satisfied from the user's normal apt sources, not this repo.
pool_suite_has_package() {
  local suite="$1" arch="$2" name="$3" idx
  idx="$(pool_suite_index "$suite" "$arch")" || return 1
  grep -qx "Package: ${name}" "$idx"
}

pool_suite_package_version() {
  local suite="$1" arch="$2" name="$3" idx
  idx="$(pool_suite_index "$suite" "$arch")" || return 1
  pool_index_package_version "$idx" "$name"
}

# libggml0 version already chosen for this suite in the current pool fetch.
pool_suite_imported_package_version() {
  local pkg_prefix="$1" suite="$2" arch="$3" base
  for base in "${!pool_file_suites[@]}"; do
    [[ " ${pool_file_suites[$base]} " == *" $suite "* ]] || continue
    [[ "$base" == "${pkg_prefix}_"*"_${arch}.deb" ]] || continue
    pool_filename_version "$pkg_prefix" "$arch" "$base"
    return 0
  done
  return 1
}

# True when a walked dependency should not be imported because upstream already
# ships it. Returns false (do not skip) when upstream is older than a version pin.
pool_skip_upstream_package() {
  local suite="$1" arch="$2" name="$3" op="${4:-}" ver="${5:-}" upstream_ver ggml_ver
  if [[ "$name" == libggml0-backend-* ]]; then
    if ! pool_suite_has_package "$suite" "$arch" "$name"; then
      return 1
    fi
    ggml_ver="$(pool_suite_imported_package_version libggml0 "$suite" "$arch")" || return 0
    upstream_ver="$(pool_suite_package_version "$suite" "$arch" "$name")" || return 0
    if dpkg --compare-versions "$upstream_ver" lt "$ggml_ver"; then
      return 1
    fi
    return 0
  fi
  if ! pool_suite_has_package "$suite" "$arch" "$name"; then
    return 1
  fi
  if [[ -z "$op" || -z "$ver" ]]; then
    return 0
  fi
  upstream_ver="$(pool_suite_package_version "$suite" "$arch" "$name")" || return 0
  if [[ "$op" == "=" || "$op" == ">=" ]]; then
    if dpkg --compare-versions "$upstream_ver" lt "$ver"; then
      return 1
    fi
  fi
  return 0
}

# Never republish libc6 or other base system packages from the Debian pool.
pool_never_republish() {
  local name="$1"
  [[ "$name" == libc6 || "$name" == libc6-* ]] && return 0
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
  local deb="$1" field="$2" raw
  raw="$(dpkg-deb -f "$deb" "$field" 2>/dev/null || true)"
  pool_relation_packages_from_raw "$raw" "$field"
}

pool_relation_packages_from_raw() {
  local raw="$1" field="$2" raw clause name rest
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

# Pick the newest pool .deb whose libc6 requirement fits the target suite.
# Uses the sid Packages index where possible; downloads at most one .deb per pick.
pool_pick_deb() {
  local pool="$1" name="$2" arch="$3" suite_libc="$4" op="${5:-}" ver="${6:-}" suite="${7:-}"
  local filename deb_ver need chosen="" staged

  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    deb_ver="$(pool_filename_version "$name" "$arch" "$filename")"
    if [[ -n "$op" && -n "$ver" ]] && ! dpkg --compare-versions "$deb_ver" "$op" "$ver"; then
      continue
    fi
    need="$(pool_libc_need_for_filename "$name" "$arch" "$filename" "$pool")" || continue
    if ! pool_libc_fits "$need" "$suite_libc"; then
      continue
    fi
    chosen="$filename"
    break
  done < <(pool_list_filenames "$pool" "$name" "$arch")

  [[ -n "$chosen" ]] || return 1

  staged="${pool_work}/staging/${chosen}"
  if [[ ! -s "$staged" ]]; then
    echo "Downloading ${chosen}" >&2
    mkdir -p "${pool_work}/staging"
    if ! curl -fsSL "${pool}/${chosen}" -o "$staged"; then
      rm -f "$staged"
      return 1
    fi
  fi
  printf '%s\n' "$staged"
}

# True when some pool revision of this package fits the suite libc (index only).
pool_pick_deb_exists() {
  local pool="$1" name="$2" arch="$3" suite_libc="$4" op="${5:-}" ver="${6:-}" suite="${7:-}"
  local filename deb_ver need

  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    deb_ver="$(pool_filename_version "$name" "$arch" "$filename")"
    if [[ -n "$op" && -n "$ver" ]] && ! dpkg --compare-versions "$deb_ver" "$op" "$ver"; then
      continue
    fi
    need="$(pool_libc_need_for_filename "$name" "$arch" "$filename" "$pool")" || continue
    if pool_libc_fits "$need" "$suite_libc"; then
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
        # Seed packages are explicit pool imports (llama.cpp pool: libllama* only).
        libc="$(pool_suite_libc6 "$suite" "$arch")"
        if [[ -z "$libc" ]]; then
          echo "Skipping ${name} for ${suite}/${arch}: could not read libc6 version." >&2
          continue
        fi
        if ! staged="$(pool_pick_deb "$pool" "$name" "$arch" "$libc" "" "" "$suite")"; then
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
        pool_never_republish "$name" && continue
        if ! child_pool="$(pool_url_for_package "$name" "$arch")"; then
          continue
        fi
        for suite in $parent_suites; do
          [[ -n "$suite" ]] || continue
          if pool_skip_upstream_package "$suite" "$arch" "$name" "$op" "$ver"; then
            echo "Skipping ${name} for ${suite}/${arch}: already in upstream suite." >&2
            continue
          fi
          libc="$(pool_suite_libc6 "$suite" "$arch")"
          if [[ -z "$libc" ]]; then
            echo "Skipping ${name} for ${suite}/${arch}: could not read libc6 version." >&2
            continue
          fi
          if ! staged="$(pool_pick_deb "$child_pool" "$name" "$arch" "$libc" "$op" "$ver" "$suite")"; then
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
  persist_package_index
  return 0
}

persist_package_index() {
  jq . <<< "$index" > "${output}/.package-index.json"
}

filter_rpm_index_by_fedora() {
  local repo project allowlist filename fc fedora_json
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    project="$(repos_config_project_json "$config" "$repo")"
    allowlist="$(repos_config_rpm_fedora_allowlist "$project")"
    [[ "$allowlist" != "null" ]] || continue
    while IFS= read -r filename; do
      [[ -n "$filename" ]] || continue
      if [[ "$filename" =~ \.fc([0-9]+)\. ]]; then
        fc="${BASH_REMATCH[1]}"
        if ! jq -en --argjson fc "$fc" --argjson list "$allowlist" '$list | index($fc) != null' >/dev/null; then
          index="$(jq --arg repo "$repo" --arg file "$filename" 'del(.[$repo].packages[$file])' <<< "$index")"
          echo "Dropping ${filename} from index: fc${fc} not in fedora allowlist." >&2
        fi
        continue
      fi
      fedora_json="$(jq -c --arg repo "$repo" --arg file "$filename" '.[$repo].packages[$file].fedora // null' <<< "$index")"
      if [[ "$fedora_json" == "null" ]]; then
        index="$(jq --arg repo "$repo" --arg file "$filename" 'del(.[$repo].packages[$file])' <<< "$index")"
        echo "Dropping ${filename} from index: no Fedora release metadata." >&2
        continue
      fi
      if ! jq -en --argjson allowlist "$allowlist" --argjson fedora "$fedora_json" '
        [ $fedora[] | select($allowlist | index(.) != null) ] | length > 0
      ' >/dev/null; then
        index="$(jq --arg repo "$repo" --arg file "$filename" 'del(.[$repo].packages[$file])' <<< "$index")"
        echo "Dropping ${filename} from index: Fedora metadata not in allowlist." >&2
      fi
    done < <(jq -r --arg repo "$repo" '.[$repo].packages | keys[]?' <<< "$index")
    if jq -e --arg repo "$repo" '.[$repo].packages | length == 0' <<< "$index" >/dev/null; then
      index="$(jq --arg repo "$repo" 'del(.[$repo])' <<< "$index")"
    fi
  done < <(jq -r 'keys[]' <<< "$index")
}

merge_repo_index_entry() {
  local repo="$1" tag="$2" packages="$3"
  if jq -e --arg repo "$repo" 'has($repo)' <<< "$index" >/dev/null; then
    index="$(jq \
      --arg repo "$repo" \
      --arg tag "$tag" \
      --argjson packages "$packages" \
      '
        .[$repo].tag = (
          if (.[$repo].tag | index($tag)) then .[$repo].tag
          elif .[$repo].tag == "" then $tag
          else .[$repo].tag + ";" + $tag
          end
        )
        | .[$repo].packages += $packages
      ' <<< "$index")"
  else
    index="$(jq \
      --arg repo "$repo" \
      --arg tag "$tag" \
      --argjson packages "$packages" \
      '. + {($repo): {tag: $tag, packages: $packages}}' \
      <<< "$index")"
  fi
  found=1
  persist_package_index
}

packages_from_repo_dir() {
  local repo_dir="$1" package_type="$2" suites_json="$3" release_json="$4" fedora_allowlist="${5:-null}" publish_fedora="${6:-null}"
  local packages="{}"
  local file base sha file_suites_json fc arch
  shopt -s nullglob
  for file in "${repo_dir}"/*."${package_type}"; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    if [[ "$package_type" == "rpm" ]] && [[ "$base" == *debuginfo* || "$base" == *debugsource* ]]; then
      rm -f "$file"
      echo "Skipping ${base}" >&2
      continue
    fi
    if [[ "$package_type" == "rpm" ]] && [[ "$fedora_allowlist" != "null" ]]; then
      if [[ ! "${base}" =~ \.fc([0-9]+)\. ]]; then
        rm -f "$file"
        echo "Skipping ${base}: cannot parse Fedora release from filename." >&2
        continue
      fi
      fc="${BASH_REMATCH[1]}"
      if ! jq -en --argjson fc "$fc" --argjson list "$fedora_allowlist" '$list | index($fc) != null' >/dev/null; then
        rm -f "$file"
        echo "Skipping ${base}: fc${fc} not in fedora allowlist." >&2
        continue
      fi
    fi
    if [[ -n "$release_json" ]] && ! jq -e --arg name "$base" --arg ext "$package_type" \
      '[.assets[] | select(.name == $name and (.name | endswith("." + $ext)))] | length > 0' \
      <<< "$release_json" >/dev/null; then
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
    elif [[ "$publish_fedora" != "null" ]] && [[ "$base" =~ \.fc[0-9]+\.([^.]+)\.rpm$ ]]; then
      arch="${BASH_REMATCH[1]}"
      packages="$(jq \
        --arg name "$base" \
        --arg sha "$sha" \
        --arg arch "$arch" \
        --argjson fedora "$publish_fedora" \
        '. + {($name): {sha256: $sha, arch: $arch, fedora: $fedora}}' \
        <<< "$packages")"
    else
      packages="$(jq \
        --arg name "$base" \
        --arg sha "$sha" \
        '. + {($name): {sha256: $sha}}' \
        <<< "$packages")"
    fi
  done
  shopt -u nullglob
  if [[ "$package_type" == "rpm" ]]; then
    jq -c . <<< "$packages"
  else
    printf '%s\n' "$packages"
  fi
}

github_release_tag_for_pattern() {
  local owner="$1" repo="$2" pattern="$3" tag
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    if [[ "$tag" == $pattern ]]; then
      printf '%s\n' "$tag"
      return 0
    fi
  done < <(gh release list -R "${owner}/${repo}" --limit 100 --json tagName -q '.[].tagName' 2>/dev/null || true)
  return 1
}

github_release_tags_for_project() {
  local owner="$1" repo="$2" project="$3" pattern tag
  if jq -e '.deb.release_tags' >/dev/null <<< "$project"; then
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      tag="$(github_release_tag_for_pattern "$owner" "$repo" "$pattern")" || continue
      printf '%s\n' "$tag"
    done < <(jq -r '.deb.release_tags | keys[]' <<< "$project")
    return 0
  fi
  tag="$(gh release view -R "${owner}/${repo}" --json tagName -q '.tagName // empty' 2>/dev/null || true)"
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "$tag"
}

github_should_skip() {
  local prev_repo="$1" release_json="$2" ext="$3"
  [[ "$fetch_force" != "true" ]] || return 1
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

pool_previous_missing_allowlisted_suites() {
  local prev_repo="$1" allowlisted="$2" suite
  [[ -n "$prev_repo" ]] || return 1
  while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    if ! jq -e --arg s "$suite" '
      [.packages[]?.suites[]?] | index($s) != null
    ' <<< "$prev_repo" >/dev/null; then
      echo "Previous index missing allowlisted suite ${suite}; re-fetching pool." >&2
      return 0
    fi
  done <<< "$allowlisted"
  return 1
}

pool_should_skip() {
  local pool="$1" prev_repo="$2" allowlisted="$3" arch html filename name ver prev_file prev_ver
  [[ "$fetch_force" != "true" ]] || return 1
  [[ -n "$prev_repo" ]] || return 1
  if pool_previous_missing_allowlisted_suites "$prev_repo" "$allowlisted"; then
    return 1
  fi

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

rpm_pool_arch_from_url() {
  local url="${1%/}"
  if [[ "$url" =~ /(x86_64|aarch64)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

rpm_pool_skip_name() {
  local name="$1"
  [[ "$name" == python*-faiss ]] && return 0
  return 1
}

rpm_pool_skip_require() {
  local req="$1"
  case "$req" in
    libc.so.*|libm.so.*|libstdc++.so.*|libgomp.so.*|libopenblas.so.*|libgcc_s.so.*|ld-linux-*)
      return 0
      ;;
    rpmlib*|rtld*)
      return 0
      ;;
  esac
  return 1
}

rpm_pool_repodata_base() {
  local pool="${1%/}"
  if curl -fsSL "${pool}/repodata/repomd.xml" >/dev/null 2>&1; then
    printf '%s\n' "$pool"
    return 0
  fi
  if [[ "$pool" =~ /(x86_64|aarch64)$ ]]; then
    pool="${pool%/*}"
    if curl -fsSL "${pool}/repodata/repomd.xml" >/dev/null 2>&1; then
      printf '%s\n' "$pool"
      return 0
    fi
  fi
  return 1
}

rpm_pool_primary_xml() {
  local pool="$1" base repomd primary_href dest cache_key
  base="$(rpm_pool_repodata_base "$pool")" || return 1
  cache_key="${base//\//_}"
  dest="${rpm_pool_work}/primary-${cache_key}.xml"
  if [[ -f "$dest" ]]; then
    printf '%s\n' "$dest"
    return 0
  fi
  repomd="$(curl -fsSL "${base}/repodata/repomd.xml")"
  primary_href="$(printf '%s\n' "$repomd" | sed -n 's/.*<location href="\([^"]*primary[^"]*\.xml\.zst\)".*/\1/p' | head -n1)"
  if [[ -z "$primary_href" ]]; then
    primary_href="$(printf '%s\n' "$repomd" | sed -n 's/.*<location href="\([^"]*primary[^"]*\.xml\.gz\)".*/\1/p' | head -n1)"
  fi
  [[ -n "$primary_href" ]] || return 1
  mkdir -p "$(dirname "$dest")"
  if [[ "$primary_href" == *.zst ]]; then
    curl -fsSL "${base}/${primary_href}" | zstd -d > "$dest"
  else
    curl -fsSL "${base}/${primary_href}" | gunzip > "$dest"
  fi
  printf '%s\n' "$dest"
}

rpm_pool_package_href() {
  local primary="$1" name="$2" arch="$3"
  awk -v pkg="$name" -v arch="$arch" '
    $0 ~ "<name>" pkg "</name>" { inpkg = 1 }
    inpkg && $0 ~ "<arch>" arch "</arch>" { inarch = 1 }
    inarch && $0 ~ "<location href=" {
      sub(/.*href="/, "")
      sub(/".*/, "")
      print
      exit
    }
    inpkg && $0 == "</package>" { inpkg = 0; inarch = 0 }
  ' "$primary"
}

rpm_pool_seed_names() {
  printf '%s\n' libfaiss faiss-devel
}

rpm_pool_download_package() {
  local pool="$1" name="$2" arch="$3" dest_dir="$4" primary href filename base
  primary="$(rpm_pool_primary_xml "$pool")" || return 1
  href="$(rpm_pool_package_href "$primary" "$name" "$arch")"
  [[ -n "$href" ]] || return 1
  filename="${href##*/}"
  if [[ -f "${dest_dir}/${filename}" ]]; then
    printf '%s\n' "$filename"
    return 0
  fi
  base="$(rpm_pool_repodata_base "$pool")" || return 1
  curl -fsSL "${base}/${href}" -o "${dest_dir}/${filename}"
  printf '%s\n' "$filename"
}

rpm_pool_fetch_into() {
  local pool="$1" repo_dir="$2" arch="$3"
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    rpm_pool_download_package "$pool" "$name" "$arch" "$repo_dir" >/dev/null
  done < <(rpm_pool_seed_names)
}

rpm_pool_packages_json() {
  local repo_dir="$1" fedora_allowlist="$2" arch="$3"
  local packages="{}"
  local file base sha
  shopt -s nullglob
  for file in "${repo_dir}"/*.rpm; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    if [[ "$base" == *debuginfo* || "$base" == *debugsource* ]]; then
      rm -f "$file"
      continue
    fi
    sha="$(sha256sum "$file" | awk '{print $1}')"
    packages="$(jq \
      --arg name "$base" \
      --arg sha "$sha" \
      --arg arch "$arch" \
      --argjson fedora "$fedora_allowlist" \
      '. + {($name): {sha256: $sha, arch: $arch, fedora: $fedora}}' \
      <<< "$packages")"
  done
  shopt -u nullglob
  jq -c . <<< "$packages"
}

rpm_pool_should_skip() {
  local prev_repo="$1" pool="$2" arch="$3"
  local primary name href filename sha prev_sha base
  [[ "$fetch_force" != "true" ]] || return 1
  [[ -n "$prev_repo" ]] || return 1
  base="$(rpm_pool_repodata_base "$pool")" || return 1
  primary="$(rpm_pool_primary_xml "$pool")" || return 1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    href="$(rpm_pool_package_href "$primary" "$name" "$arch")" || return 1
    filename="${href##*/}"
    sha="$(curl -fsSL "${base}/${href}" | sha256sum | awk '{print $1}')"
    prev_sha="$(jq -r --arg file "$filename" '.packages[$file].sha256 // empty' <<< "$prev_repo")"
    [[ -n "$prev_sha" && "$prev_sha" == "$sha" ]] || return 1
  done < <(rpm_pool_seed_names)
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
  rpm_pool="$(jq -r '.rpm_pool // empty' <<< "$project")"
  pool_file_suites=()
  tag=""
  suites_json="null"
  fedora_allowlist="null"
  publish_fedora="null"
  if [[ "$package_type" == "rpm" ]]; then
    fedora_allowlist="$(repos_config_rpm_fedora_allowlist "$project")"
    publish_fedora="$(repos_config_rpm_publish_fedora "$project")"
  fi
  repo_dir="${output}/${repo}"
  mkdir -p "$repo_dir"

  if [[ -n "$rpm_pool" ]]; then
    if [[ "$package_type" != "rpm" ]]; then
      continue
    fi
    arch="$(rpm_pool_arch_from_url "$rpm_pool")" || {
      echo "Skipping ${repo}: cannot parse arch from rpm_pool URL." >&2
      continue
    }
    if [[ -z "$rpm_pool_work" ]]; then
      rpm_pool_work="$(mktemp -d)"
      trap 'rm -rf "$pool_work" "$rpm_pool_work"' EXIT
    fi
    if rpm_pool_should_skip "$(previous_repo_json "$repo")" "$rpm_pool" "$arch"; then
      if keep_previous_repo "$repo" "Skipping rpm_pool download for ${repo}: already published."; then
        continue
      fi
    fi
    echo "Downloading RPM pool packages for ${repo} from ${rpm_pool} ..."
    if ! rpm_pool_fetch_into "$rpm_pool" "$repo_dir" "$arch"; then
      if keep_previous_repo "$repo" "Keeping previously published ${repo}: rpm_pool fetch failed."; then
        continue
      fi
      echo "Skipping ${repo}: rpm_pool fetch failed." >&2
      continue
    fi
    packages="$(rpm_pool_packages_json "$repo_dir" "$fedora_allowlist" "$arch")"
    if [[ "$packages" == "{}" ]]; then
      if keep_previous_repo "$repo" "Keeping previously published ${repo}: no rpm_pool packages downloaded."; then
        continue
      fi
      echo "Skipping ${repo}: no rpm_pool packages downloaded." >&2
      continue
    fi
    merge_repo_index_entry "$repo" "opensuse-tumbleweed" "$packages"
    continue
  fi

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
    mapfile -t release_tags < <(github_release_tags_for_project "$owner" "$repo" "$project" || true)
    if [[ "${#release_tags[@]}" -eq 0 ]]; then
      if keep_previous_repo "$repo" "Keeping previously published ${owner}/${repo}: no latest release."; then
        continue
      fi
      echo "Skipping ${owner}/${repo}: no latest release." >&2
      continue
    fi

    for tag in "${release_tags[@]}"; do
      [[ -n "$tag" ]] || continue
      release_json="$(gh release view "$tag" -R "${owner}/${repo}" --json tagName,assets 2>/dev/null || true)"
      if [[ -z "$release_json" ]]; then
        echo "Skipping ${owner}/${repo}@${tag}: could not read release metadata." >&2
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
          break
        fi
        echo "Skipping ${owner}/${repo}@${tag}: already published (no previous copy)." >&2
        continue
      fi

      pattern='*.deb'
      [[ "$package_type" == "rpm" ]] && pattern='*.rpm'

      echo "Downloading ${pattern} from ${owner}/${repo}@${tag} ..."
      if ! gh release download "$tag" -R "${owner}/${repo}" \
        --pattern "$pattern" \
        -D "$repo_dir" \
        --clobber 2>/dev/null; then
        if keep_previous_repo "$repo" "Keeping previously published ${owner}/${repo}@${tag}: no ${package_type} assets."; then
          break
        fi
        echo "Skipping ${owner}/${repo}@${tag}: no ${package_type} assets." >&2
        continue
      fi

      packages="$(packages_from_repo_dir "$repo_dir" "$package_type" "$suites_json" "$release_json" "$fedora_allowlist" "$publish_fedora")"
      if [[ "$packages" == "{}" ]]; then
        echo "Skipping ${owner}/${repo}@${tag}: no ${package_type} files matched release assets." >&2
        continue
      fi

      merge_repo_index_entry "$repo" "$tag" "$packages"
    done
    continue
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
  persist_package_index
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

if [[ "$package_type" == "rpm" ]]; then
  filter_rpm_index_by_fedora
fi

persist_package_index

if jq -e 'length == 0' <<< "$index" >/dev/null; then
  echo "No ${package_type} packages downloaded." >&2
  exit 1
fi

jq . "${output}/.package-index.json"
