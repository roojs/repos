#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://roojs.github.io/repos/"
KEY_URL="${REPO_URL}KEY.gpg"
KEYRING="/etc/apt/keyrings/roojs.gpg"
SOURCES="/etc/apt/sources.list.d/roojs.sources"
SUPPORTED_SUITES=(trixie questing resolute)

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: curl -fsSL https://raw.githubusercontent.com/roojs/repos/main/docs/install-apt.sh | sudo bash" >&2
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "Cannot detect OS (/etc/os-release missing)." >&2
  exit 1
fi

# shellcheck source=/dev/null
source /etc/os-release

case "${ID}" in
  debian) suite="trixie" ;;
  ubuntu) suite="${VERSION_CODENAME}" ;;
  *)
    echo "Unsupported OS: ${ID}. This repository supports Debian 13 and Ubuntu 25.10 / 26.04." >&2
    exit 1
    ;;
esac

if [[ ! " ${SUPPORTED_SUITES[*]} " =~ " ${suite} " ]]; then
  echo "Unsupported suite: ${suite}." >&2
  echo "Supported: ${SUPPORTED_SUITES[*]}" >&2
  exit 1
fi

install -d -m 0755 /etc/apt/keyrings
curl -fsSL "${KEY_URL}" | gpg --dearmor -o "${KEYRING}"
chmod a+r "${KEYRING}"

cat >"${SOURCES}" <<EOF
Types: deb
URIs: ${REPO_URL}
Suites: ${suite}
Components: main
Signed-By: ${KEYRING}
EOF

apt-get update
echo "roojs apt repository enabled (${PRETTY_NAME:-${suite}})."
