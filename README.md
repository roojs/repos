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
| `trixie` | Debian 13 (current stable) |
| `questing` | Ubuntu 25.10 |
| `resolute` | Ubuntu 26.04 LTS |

Architectures: `amd64`, `arm64`.

### Publishing workflow

Manual for now: push to `main` (or run the workflow by hand) to refresh the repo from upstream GitHub Releases.

Setup (GPG key, GitHub secrets, Pages, first publish): **[docs/setup.md](docs/setup.md)**

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

Packages are built and released from individual project repositories, then aggregated here. Upstream repos polled by the workflow (`config/upstream-repos.json`):

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
