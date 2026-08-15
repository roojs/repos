# roojs/repos

Automated APT and DNF repositories for distributing packages built from other roojs projects. Published on GitHub Pages from the `gh-pages` branch.

Push to `main` (or run the workflow manually) to refresh both repos from upstream GitHub Releases.

Setup: **[docs/setup.md](docs/setup.md)**

## APT repository

Uses [reprepro](https://wiki.debian.org/DebianRepository/UseReprepro):

```
gh-pages/
├── KEY.gpg
├── conf/
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

### Publishing

Workflow: [Publish package repositories](.github/workflows/publish-repos.yml)

## APT client installation

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

## DNF repository

Uses [createrepo_c](https://github.com/rpm-software-management/createrepo_c). RPMs are sorted by Fedora release and architecture from the package filename (e.g. `.fc44.x86_64.rpm` → `rpm/fc44/x86_64/`):

```
gh-pages/
├── KEY.gpg
├── rpm/
│   ├── fc42/x86_64/
│   └── fc44/x86_64/
```

Currently published from upstream releases: **app.RooTerm** (fc42), **ibus-sherpa-onnx** and **sherpa-onnx** (fc44). Debuginfo/debugsource RPMs are skipped.

### DNF client installation

```bash
sudo curl -fsSL https://roojs.github.io/repos/KEY.gpg \
  -o /etc/pki/rpm-gpg/RPM-GPG-KEY-roojs
sudo cp docs/roojs.repo /etc/yum.repos.d/roojs.repo
sudo dnf makecache
```

Install packages, for example:

```bash
sudo dnf install ibus-sherpa-onnx
```

`gpgcheck=0` because upstream CI RPMs are not individually signed; `repo_gpgcheck=1` verifies signed repository metadata.

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
