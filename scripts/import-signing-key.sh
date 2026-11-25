#!/usr/bin/env bash
# Import the repository signing key into the job keyring and preset its
# passphrase in gpg-agent so reprepro and gpg can sign without a prompt.
# Reads APT_GPG_PRIVATE_KEY and APT_GPG_PASSPHRASE from the environment.
set -euo pipefail

if [[ "${APT_GPG_PRIVATE_KEY:-}" != *"BEGIN PGP PRIVATE KEY BLOCK"* ]]; then
  echo "APT_GPG_PRIVATE_KEY is not an armored private key." >&2
  exit 1
fi

gnupg_home="$(gpgconf --list-dirs homedir)"
mkdir -p "$gnupg_home"
chmod 700 "$gnupg_home"

printf '%s\n' "$APT_GPG_PRIVATE_KEY" | gpg --batch --import

if [[ -z "${APT_GPG_PASSPHRASE:-}" ]]; then
  exit 0
fi

cat > "${gnupg_home}/gpg-agent.conf" <<'EOF'
default-cache-ttl 21600
max-cache-ttl 31536000
allow-preset-passphrase
EOF
gpg-connect-agent RELOADAGENT /bye > /dev/null

passphrase_hex="$(printf '%s' "$APT_GPG_PASSPHRASE" | od -An -v -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')"

mapfile -t keygrips < <(gpg --batch --with-colons --with-keygrip --list-secret-keys | awk -F: '$1 == "grp" { print $10 }')
if [[ "${#keygrips[@]}" -eq 0 ]]; then
  echo "No secret key found after import." >&2
  exit 1
fi

for keygrip in "${keygrips[@]}"; do
  reply="$(printf 'PRESET_PASSPHRASE %s -1 %s\n' "$keygrip" "$passphrase_hex" | gpg-connect-agent)"
  if [[ "$reply" != OK* ]]; then
    echo "Could not preset passphrase for keygrip ${keygrip}: ${reply}" >&2
    exit 1
  fi
done
