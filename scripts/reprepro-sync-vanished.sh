#!/usr/bin/env bash
# Drop reprepro database targets removed from conf/distributions (e.g. arm64).
set -euo pipefail

repo_root="${1:?repo root required}"
config="${2:-}"

if [[ -n "$config" && -f "$config" && -d "${repo_root}/pool" ]]; then
  allowed="$(jq -c '.apt.architectures' "$config")"
  while IFS= read -r -d '' deb; do
    base="$(basename "$deb")"
    [[ "$base" =~ _([^_]+)\.deb$ ]] || continue
    arch="${BASH_REMATCH[1]}"
    # Architecture "all" is not a CPU architecture. Those packages are indexed
    # into every binary-* list (php-faiss, php-llamacpp, …) and must stay in
    # the pool. Deleting them leaves signed Packages entries that 404.
    if [[ "$arch" == "all" ]]; then
      continue
    fi
    if jq -en --arg arch "$arch" --argjson allowed "$allowed" '$allowed | index($arch) != null' >/dev/null; then
      continue
    fi
    echo "Removing ${deb#${repo_root}/} (architecture ${arch} not configured)"
    rm -f "$deb"
  done < <(find "${repo_root}/pool" -type f -name '*.deb' -print0)
fi

echo "Clearing reprepro targets no longer listed in conf/distributions ..."
reprepro -b "$repo_root" --delete clearvanished

echo "Exporting APT tree after clearvanished ..."
reprepro -b "$repo_root" export
