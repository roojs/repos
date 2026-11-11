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
#
# $4 is a JSON array of suites that already have their own +suite build of this
# same package. The unsuffixed build is kept off those suites. OLLMchat's
# Ubuntu libocrpc1 depends on libgirepository-2.0-0; the +trixie build depends
# on libgirepository-1.0-1. Publishing the Ubuntu .deb into trixie as well
# makes that suite uninstallable.
#
# A release that ships one unsuffixed .deb, with no +suite sibling, is published
# to every suite in $2. pixie-pkg does this: the package is a shell script
# (Architecture: all) and the apt suites share that one file.
deb_file_suites_json() {
  local filename="$1" default_suites_json="$2" apt_suites_json="${3:-[]}" exclude_suites_json="${4:-[]}"
  local suite
  if suite="$(deb_local_suite_from_filename "$filename" 2>/dev/null)"; then
    if jq -en --arg s "$suite" --argjson allowed "$apt_suites_json" \
      '$allowed | index($s) != null' >/dev/null; then
      jq -nc --arg s "$suite" '[ $s ]'
      return 0
    fi
  fi
  if [[ -z "$exclude_suites_json" || "$exclude_suites_json" == "[]" ]]; then
    printf '%s\n' "$default_suites_json"
    return 0
  fi
  jq -nc --argjson defaults "$default_suites_json" --argjson exclude "$exclude_suites_json" \
    '$defaults - $exclude'
}

# Filenames on stdin. For each build whose +suffix is a configured APT suite,
# print "pkg:arch<TAB>suite". Callers use this to keep the unsuffixed sibling
# off that suite.
deb_dedicated_suites_tsv() {
  local apt_suites_json="$1" filename suite pkg arch
  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    suite="$(deb_local_suite_from_filename "$filename" 2>/dev/null)" || continue
    if ! jq -en --arg s "$suite" --argjson allowed "$apt_suites_json" \
      '$allowed | index($s) != null' >/dev/null; then
      continue
    fi
    pkg="$(deb_pkg_name_from_filename "$filename")" || continue
    arch="$(deb_arch_from_filename "$filename")" || continue
    printf '%s:%s\t%s\n' "$pkg" "$arch" "$suite"
  done
}
