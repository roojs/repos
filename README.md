# roojs/repos

Official APT and DNF package repositories for [roojs](https://github.com/roojs) desktop projects.

**Repository URL:** `https://roojs.github.io/repos/`

Client setup files (`sources`, `repo`, `key.gpg`) are served from the same site as the packages. Source copies live in `docs/` on `main`.

Packages are built and released from individual project repositories, then aggregated here. The repository is refreshed daily (and whenever `main` is updated).

Maintainer setup (GPG keys, GitHub secrets, Pages): **[docs/setup.md](docs/setup.md)**

---

## Supported platforms

### APT (Debian / Ubuntu)

| Use this suite | Distribution |
|----------------|--------------|
| `trixie` | Debian 13 |
| `plucky` | Ubuntu 25.04 |
| `questing` | Ubuntu 25.10 |
| `resolute` | Ubuntu 26.04 LTS |

Architectures: `amd64`, `arm64`.

### DNF (Fedora)

Repositories are published per Fedora release under `rpm/fc<version>/<arch>/` (for example `rpm/fc44/x86_64/`).

Check your Fedora version:

```bash
rpm -E %fedora
```

Currently published RPMs target **Fedora 42** (RooTerm) and **Fedora 44** (ibus-sherpa-onnx, sherpa-onnx libraries).

---

## Using the APT repository

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://roojs.github.io/repos/key.gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/roojs.gpg

curl -fsSL https://roojs.github.io/repos/sources \
  | sed "s/@suite@/$(lsb_release -cs)/" \
  | sudo tee /etc/apt/sources.list.d/roojs.sources

sudo apt update
sudo apt install ibus-sherpa-onnx ollmchat rooterm
```

Template: [docs/sources](docs/sources) (`@suite@` is replaced with your suite from `lsb_release -cs`). `Architectures:` is `amd64 arm64` so apt does not request `i386` from this repo.

### APT troubleshooting

| Problem | What to try |
|---------|-------------|
| `NO_PUBKEY` / signature errors | Re-run step 1 (signing key) |
| `404` on `apt update` | Confirm your suite name matches your OS (see table above) |
| Package not found | The upstream project may not publish a `.deb` yet, or the daily sync has not run since the release |

---

## Using the DNF repository

```bash
sudo curl -fsSL https://roojs.github.io/repos/key.gpg \
  -o /etc/pki/rpm-gpg/RPM-GPG-KEY-roojs
sudo curl -fsSL https://roojs.github.io/repos/repo \
  -o /etc/yum.repos.d/roojs.repo
sudo dnf makecache
sudo dnf install ibus-sherpa-onnx rooterm
```

`gpgcheck=0` because CI-built RPMs are not individually signed. `repo_gpgcheck=1` verifies signed repository metadata.

Template: [docs/repo](docs/repo).

### DNF troubleshooting

| Problem | What to try |
|---------|-------------|
| `Status code: 404` on `dnf makecache` | No packages are published for your Fedora `$releasever` yet (check `rpm -E %fedora`) |
| GPG / repomd errors | Re-download `key.gpg`; confirm `gpgkey=` URL is reachable |
| Dependency errors on install | Install `libsherpa-onnx-c-api` from this repo before `ibus-sherpa-onnx` |

---

## Available packages (upstream sources)

| Project | APT | DNF | Notes |
|---------|-----|-----|-------|
| [OLLMchat](https://github.com/roojs/OLLMchat) | yes | — | `ollmchat` |
| [app.RooTerm](https://github.com/roojs/app.RooTerm) | yes | yes (fc42) | `rooterm` |
| [ibus-sherpa-onnx](https://github.com/roojs/ibus-sherpa-onnx) | yes | yes (fc44) | IBus engine |
| [sherpa-onnx](https://github.com/roojs/sherpa-onnx) | yes | yes (fc44) | `libsherpa-onnx-c-api*` libraries |
| [webkitgtk-automation](https://github.com/roojs/webkitgtk-automation) | yes | — | `libwebkitgtk-6.0-*` (series-specific builds) |
| [roobuilder](https://github.com/roojs/roobuilder) | yes | — | `roobuilder`, `roojspacker` |

New releases appear after the [publish workflow](.github/workflows/publish-repos.yml) detects a change in upstream packages (checked daily, or on demand).

---

## For maintainers

- **Workflow:** [Publish package repositories](.github/workflows/publish-repos.yml) — checks upstream GitHub Releases daily; commits to `gh-pages` only when packages or repo config change
- **Upstream list:** `config/repos.json` — projects, APT suites, and per-release suite rules
- **Setup guide:** [docs/setup.md](docs/setup.md)
- **Plan guide:** [docs/guide-to-writing-plans.md](docs/guide-to-writing-plans.md)
- **Plans:** [docs/plans/1-import-debian-pool-deps.md](docs/plans/1-import-debian-pool-deps.md), [docs/plans/2-tree-sitter-batch-release.md](docs/plans/2-tree-sitter-batch-release.md), [docs/plans/3-ollmchat-rpm-opensuse-faiss.md](docs/plans/3-ollmchat-rpm-opensuse-faiss.md), [docs/plans/4-repo-catalog-html.md](docs/plans/4-repo-catalog-html.md)

## AI assistance

This repository was developed with the assistance of artificial intelligence.

- Requirements and direction were set by the author
- Workflow, reprepro configuration, and documentation were largely AI-generated
- The author has reviewed the overall approach and defaults, but not every line in detail
- Treat scripts and config as provisional until exercised in production
