#!/usr/bin/env bash
# Shared helpers for reading config/repos.json

set -euo pipefail

repos_config_default_suites() {
  jq -r '.apt.suites[]' "$1"
}

repos_config_project_json() {
  local config="$1" repo="$2"
  jq -c --arg repo "$repo" '.projects[] | select(.repo == $repo)' "$config"
}

repos_config_project_names() {
  local config="$1" filter="${2:-}"
  if [[ -n "$filter" ]]; then
    local names=()
    IFS=',' read -r -a names <<< "${filter}"
    local config_path="$config"
    for name in "${names[@]}"; do
      name="${name//[[:space:]]/}"
      [[ -n "$name" ]] || continue
      jq -r --arg name "$name" '.projects[] | select(.repo == $name) | .repo' "$config_path"
    done
    return 0
  fi
  jq -r '.projects[].repo' "$config"
}

repos_config_fetch_debs() {
  local project="$1"
  [[ "$(jq -r '.deb // true' <<< "$project")" != "false" ]]
}

repos_config_fetch_rpms() {
  local project="$1"
  [[ "$(jq -r '.rpm // false' <<< "$project")" == "true" ]]
}

repos_config_rpm_fedora_allowlist() {
  local project="$1"
  jq -c '.fedora // null' <<< "$project"
}

repos_config_rpm_publish_fedora() {
  local project="$1"
  jq -c '.publish_fedora // null' <<< "$project"
}

repos_config_rpm_publish_opensuse() {
  local project="$1"
  jq -c '.publish_opensuse // null' <<< "$project"
}

repos_config_opensuse_releases() {
  local config="$1"
  jq -r '.opensuse.releases[]? // empty' "$config"
}

repos_config_deb_is_object() {
  local project="$1"
  jq -e '(.deb | type) == "object"' <<< "$project" >/dev/null
}

repos_config_release_tag_patterns() {
  local project="$1"
  if repos_config_deb_is_object "$project" \
    && jq -e '(.deb.release_tags | type) == "object"' <<< "$project" >/dev/null; then
    jq -r '.deb.release_tags | keys[]' <<< "$project"
    return 0
  fi
  if jq -e '(.release_tags | type) == "object"' <<< "$project" >/dev/null; then
    jq -r '.release_tags | keys[]' <<< "$project"
    return 0
  fi
  return 1
}

repos_config_release_tag_suites() {
  local config="$1" project="$2" pattern="$3"
  local suites_val
  if repos_config_deb_is_object "$project"; then
    suites_val="$(jq -r --arg pattern "$pattern" '.deb.release_tags[$pattern] // empty' <<< "$project")"
  else
    suites_val="$(jq -r --arg pattern "$pattern" '.release_tags[$pattern] // empty' <<< "$project")"
  fi
  [[ -n "$suites_val" && "$suites_val" != "null" ]] || return 1
  if [[ "$suites_val" == "default" ]]; then
    repos_config_default_suites "$config"
  else
    jq -r --arg pattern "$pattern" '
      if (.deb.release_tags? | type) == "object" then .deb.release_tags[$pattern][]
      else .release_tags[$pattern][]
      end
    ' <<< "$project"
  fi
}

repos_config_deb_suites() {
  local config="$1" project="$2" tag="$3"

  if [[ "$(jq -r '.deb // true' <<< "$project")" == "false" ]]; then
    return 1
  fi

  local pattern
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if [[ "$tag" == $pattern ]]; then
      repos_config_release_tag_suites "$config" "$project" "$pattern"
      return 0
    fi
  done < <(repos_config_release_tag_patterns "$project" || true)
  if repos_config_release_tag_patterns "$project" >/dev/null 2>&1; then
    return 1
  fi

  if jq -e '.deb.suites' >/dev/null <<< "$project"; then
    if [[ "$(jq -r '.deb.suites' <<< "$project")" == '"default"' ]]; then
      repos_config_default_suites "$config"
      return 0
    fi
    jq -r '.deb.suites[]' <<< "$project"
    return 0
  fi

  repos_config_default_suites "$config"
}
