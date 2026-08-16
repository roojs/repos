#!/usr/bin/env bash
set -euo pipefail

pages="${1:?pages directory required}"
config="${2:?config path required}"
distributions="${3:?distributions file required}"
output="${4:-}"

read_index() {
  local file="$1"
  if [[ -f "$file" ]]; then
    jq -c . "$file"
  else
    echo '{}'
  fi
}

current="$(jq -n \
  --argjson debs "$(read_index "${pages}/incoming-debs/.package-index.json")" \
  --argjson rpms "$(read_index "${pages}/incoming-rpms/.package-index.json")" \
  --arg repos_json_sha256 "$(sha256sum "$config" | awk '{print $1}')" \
  --arg distributions_sha256 "$(sha256sum "$distributions" | awk '{print $1}')" \
  '{
    debs: $debs,
    rpms: $rpms,
    repos_json_sha256: $repos_json_sha256,
    distributions_sha256: $distributions_sha256
  }')"

previous='{}'
if [[ -f "${pages}/.publish-manifest.json" ]]; then
  previous="$(jq -c . "${pages}/.publish-manifest.json")"
fi

changed=false
if ! jq -en --argjson current "$current" --argjson previous "$previous" '$current == $previous' >/dev/null; then
  changed=true
fi
if jq -en --argjson current "$current" --argjson previous "$previous" \
  '(($previous.debs // {}) == {}) and (($current.debs // {}) != {})' >/dev/null; then
  changed=true
fi

if [[ -n "$output" ]]; then
  printf '%s\n' "$current" | jq . > "$output"
fi

if [[ "$changed" == true ]]; then
  echo "Upstream packages or repository config changed."
else
  echo "No upstream package changes detected."
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "changed=${changed}" >> "$GITHUB_OUTPUT"
fi
