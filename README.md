# roojs/repos

Automated Debian/Ubuntu APT repository (and eventually DNF) for distributing packages built from other roojs projects.

## APT repository (GitHub Pages)

Published from the `gh-pages` branch using [reprepro](https://wiki.debian.org/DebianRepository/UseReprepro). The layout follows the standard Debian archive format:

```
gh-pages/
├── KEY.gpg
├── conf/
│   ├── distributions
│   └── options
├── dists/
└── pool/
```

### Supported suites

| Codename | Distribution |
|----------|--------------|
| `questing` | Ubuntu 25.10 |
| `resolute` | Ubuntu 26.04 LTS |

Architectures: `amd64`, `arm64`.

### Publishing workflow

1. Create a GitHub Release on this repository and attach one or more `.deb` files.
2. The [Publish APT Repo via Reprepro](.github/workflows/deploy-apt.yml) workflow runs on `release: published` (or via `workflow_dispatch`).
3. The workflow downloads release `.deb` assets, ingests them into every configured suite with reprepro, exports `KEY.gpg`, and commits the updated `gh-pages` branch.

### Repository secrets

Configure these secrets before the first publish:

| Secret | Description |
|--------|-------------|
| `APT_GPG_PRIVATE_KEY` | Armor-encoded GPG private key used to sign the repository |
| `APT_GPG_PASSPHRASE` | Passphrase for the signing key (leave empty if the key has none) |

Generate a dedicated signing key (example):

```bash
gpg --full-generate-key
gpg --armor --export-secret-keys YOUR_KEY_ID > signing-key.asc
```

Add `signing-key.asc` as `APT_GPG_PRIVATE_KEY` in the repository secrets.

### GitHub Pages

Enable GitHub Pages for this repository:

- **Source:** Deploy from a branch
- **Branch:** `gh-pages` / root

The public URL is `https://roojs.github.io/repos/`.

## Client installation

Install the signing key:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://roojs.github.io/repos/KEY.gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/roojs.gpg
sudo chmod a+r /etc/apt/keyrings/roojs.gpg
```

Add the repository ([DEB822](https://repolib.readthedocs.io/en/latest/deb822-format.html) format):

```bash
sudo cp docs/roojs.sources /etc/apt/sources.list.d/roojs.sources
# or paste the contents of docs/roojs.sources manually
sudo apt update
```

Install packages as they are published, for example:

```bash
sudo apt install ibus-sherpa-onnx
```

## Source projects

Packages are built and released from individual project repositories, then aggregated here for apt/dnf distribution. Planned sources include:

- [OLLMchat](https://github.com/roojs/OLLMchat)
- [app.RooTerm](https://github.com/roojs/app.RooTerm)
- [ibus-sherpa-onnx](https://github.com/roojs/ibus-sherpa-onnx)
- [sherpa-onnx](https://github.com/roojs/sherpa-onnx)
- [webkitgtk-automation](https://github.com/roojs/webkitgtk-automation)
- [roobuilder](https://github.com/roojs/roobuilder)

## DNF repository (planned)

RPM publishing via a DNF/YUM repo on GitHub Pages will be added after the APT pipeline is stable.

## AI assistance

This repository was developed with the assistance of artificial intelligence.

- Requirements and direction were set by the author
- Workflow, reprepro configuration, and documentation were largely AI-generated
- The author has reviewed the overall approach and defaults, but not every line in detail
- Treat scripts and config as provisional until exercised in production
