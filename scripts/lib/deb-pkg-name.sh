#!/usr/bin/env bash
# Derive the Debian binary package name from a .deb filename.
deb_pkg_name_from_filename() {
  local filename="$1" base="" arch

  for arch in amd64 arm64 all i386; do
    if [[ "$filename" == *"_${arch}.deb" ]]; then
      base="${filename%_${arch}.deb}"
      break
    fi
  done
  [[ -n "$base" ]] || return 1

  if [[ "$base" == *_* ]]; then
    printf '%s\n' "${base%%_*}"
    return 0
  fi

  # tree-sitter release files use hyphens: libtree-sitter-bash-0.20.5-1_amd64.deb
  if [[ "$base" =~ -[0-9] ]]; then
    sed -E 's/-[0-9][0-9A-Za-z.+~:]*(-[0-9]+)?$//' <<< "$base"
    return 0
  fi

  printf '%s\n' "$base"
}

deb_arch_from_filename() {
  local filename="$1" arch
  for arch in amd64 arm64 all i386; do
    if [[ "$filename" == *"_${arch}.deb" ]]; then
      printf '%s\n' "$arch"
      return 0
    fi
  done
  return 1
}

deb_version_from_filename() {
  local filename="$1" base="" arch
  for arch in amd64 arm64 all i386; do
    if [[ "$filename" == *"_${arch}.deb" ]]; then
      base="${filename%_${arch}.deb}"
      break
    fi
  done
  [[ -n "$base" && "$base" == *_* ]] || return 1
  printf '%s\n' "${base#*_}"
}

deb_local_suite_from_version() {
  local version="$1" suite
  [[ "$version" == *+* ]] || return 1
  suite="${version#*+}"
  suite="${suite%%~*}"
  [[ -n "$suite" ]] || return 1
  printf '%s\n' "$suite"
}

deb_local_suite_from_filename() {
  local version suite
  version="$(deb_version_from_filename "$1")" || return 1
  deb_local_suite_from_version "$version"
}

# Per-suite .deb builds encode the target suite as upstream+SUITE in the version.
# Ignore other +suffixes (e.g. webkit +webdriver6, Debian +dfsg).
deb_file_suites_json() {
  local filename="$1" default_suites_json="$2" apt_suites_json="${3:-[]}"
  local suite
  if suite="$(deb_local_suite_from_filename "$filename" 2>/dev/null)"; then
    if jq -en --arg s "$suite" --argjson allowed "$apt_suites_json" \
      '$allowed | index($s) != null' >/dev/null; then
      jq -nc --arg s "$suite" '[ $s ]'
      return 0
    fi
  fi
  printf '%s\n' "$default_suites_json"
}
