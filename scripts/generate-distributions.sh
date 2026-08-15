#!/usr/bin/env bash
set -euo pipefail

config="${1:?config path required}"

architectures="$(jq -r '.apt.architectures | join(" ")' "$config")"

while IFS= read -r suite; do
  [[ -n "$suite" ]] || continue
  cat <<EOF
Codename: ${suite}
Origin: roojs
Label: roojs
Architectures: ${architectures}
Components: main
Description: Official APT repository for roojs packages
SignWith: default

EOF
done < <(jq -r '.apt.suites[]' "$config")
