#!/bin/busybox sh
# Stand-in for the gh CLI inside a job container. It records release assets
# on disk. It refuses to print GH_TOKEN. The host-side fake gh reads the
# same directory layout.
set -eu

db="${GITHUB_RELEASE_DB:-/var/lib/github-releases}"

require_token() {
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "gh: GH_TOKEN is not set" >&2
    exit 1
  fi
}

tag_dir() {
  printf '%s/%s' "$db" "$1"
}

release_exists() {
  [ -d "$(tag_dir "$1")" ]
}

cmd_view() {
  tag=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -R|--json|-q|--jq)
        shift
        [ "$#" -gt 0 ] && shift
        ;;
      --*)
        shift
        ;;
      *)
        tag="$1"
        shift
        ;;
    esac
  done
  [ -n "$tag" ] || exit 1
  if ! release_exists "$tag"; then
    echo "release not found" >&2
    exit 1
  fi
  printf '%s\n' "$tag"
}

cmd_create() {
  require_token
  tag=""
  files=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title|--notes|--target)
        shift
        [ "$#" -gt 0 ] && shift
        ;;
      --*)
        shift
        ;;
      *)
        if [ -z "$tag" ]; then
          tag="$1"
        else
          files="$files $1"
        fi
        shift
        ;;
    esac
  done
  [ -n "$tag" ] || exit 1
  dest="$(tag_dir "$tag")"
  mkdir -p "$dest"
  for file in $files; do
    cp -f "$file" "$dest/$(basename "$file")"
  done
  : > "$dest/.release"
}

if [ "${1:-}" != "release" ]; then
  echo "gh: unsupported command" >&2
  exit 1
fi
shift
verb="${1:-}"
shift || true
case "$verb" in
  view) cmd_view "$@" ;;
  create) cmd_create "$@" ;;
  *)
    echo "gh: unsupported release command" >&2
    exit 1
    ;;
esac
