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

previous='{}'
if [[ -f "${pages}/.publish-manifest.json" ]]; then
  previous="$(jq -c . "${pages}/.publish-manifest.json")"
fi

incoming_debs="$(read_index "${pages}/incoming-debs/.package-index.json")"
incoming_rpms="$(read_index "${pages}/incoming-rpms/.package-index.json")"
previous_debs="$(jq -c '.debs // {}' <<< "$previous")"
previous_rpms="$(jq -c '.rpms // {}' <<< "$previous")"

# Keep cached package metadata when a fetch step fails before writing its index.
merged_debs="$(jq -n \
  --argjson incoming "$incoming_debs" \
  --argjson previous "$previous_debs" \
  'if ($incoming | length) > 0 then $incoming else $previous end')"
merged_rpms="$(jq -n \
  --argjson incoming "$incoming_rpms" \
  --argjson previous "$previous_rpms" \
  'if ($incoming | length) > 0 then $incoming else $previous end')"

current="$(jq -n \
  --argjson debs "$merged_debs" \
  --argjson rpms "$merged_rpms" \
  --arg repos_json_sha256 "$(sha256sum "$config" | awk '{print $1}')" \
  --arg distributions_sha256 "$(sha256sum "$distributions" | awk '{print $1}')" \
  '{
    debs: $debs,
    rpms: $rpms,
    repos_json_sha256: $repos_json_sha256,
    distributions_sha256: $distributions_sha256
  }')"

changed=false
if ! jq -en --argjson current "$current" --argjson previous "$previous" '$current == $previous' >/dev/null; then
  changed=true
fi

manifest_cache_stale=false
if jq -en \
  --argjson incoming_debs "$incoming_debs" \
  --argjson incoming_rpms "$incoming_rpms" \
  --argjson previous_debs "$previous_debs" \
  --argjson previous_rpms "$previous_rpms" '
    (($incoming_debs | length) > 0 and $incoming_debs != $previous_debs)
    or (($incoming_rpms | length) > 0 and $incoming_rpms != $previous_rpms)
  ' >/dev/null; then
  manifest_cache_stale=true
fi

if [[ -n "$output" ]]; then
  printf '%s\n' "$current" | jq . > "$output"
fi

if [[ "$changed" == true ]]; then
  echo "Upstream packages or repository config changed."
else
  echo "No upstream package changes detected."
fi

if [[ "$manifest_cache_stale" == true ]]; then
  echo "Publish manifest cache is out of date."
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "changed=${changed}" >> "$GITHUB_OUTPUT"
  echo "manifest_cache_stale=${manifest_cache_stale}" >> "$GITHUB_OUTPUT"
fi
