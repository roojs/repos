#!/usr/bin/env bash
# Delete every secret key from the job keyring and stop gpg-agent, dropping
# any preset passphrase, so later steps cannot sign with the repository key.
set -euo pipefail

mapfile -t fingerprints < <(
  gpg --batch --with-colons --list-secret-keys 2> /dev/null \
    | awk -F: '$1 == "sec" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }'
)

for fingerprint in "${fingerprints[@]}"; do
  gpg --batch --yes --delete-secret-keys "$fingerprint"
done

gpgconf --kill gpg-agent

if gpg --batch --with-colons --list-secret-keys 2> /dev/null | grep -q '^sec'; then
  echo "Secret keys remain in the job keyring." >&2
  exit 1
fi
