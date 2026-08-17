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
