# roojs/repos

Official APT and DNF package repositories for [roojs](https://github.com/roojs) desktop projects.

**Repository URL:** `https://roojs.github.io/repos/`

Packages are built and released from individual project repositories, then aggregated here. The repository is refreshed daily (and whenever `main` is updated).

Maintainer setup (GPG keys, GitHub secrets, Pages): **[docs/setup.md](docs/setup.md)**

---

## Supported platforms

### APT (Debian / Ubuntu)

| Use this suite | Distribution |
|----------------|--------------|
| `trixie` | Debian 13 |
| `questing` | Ubuntu 25.10 |
| `resolute` | Ubuntu 26.04 LTS |

Architectures: `amd64`, `arm64`.

Check your suite:

```bash
. /etc/os-release
if [ -f /etc/debian_version ] && [ "$ID" = debian ]; then echo trixie; else echo "$VERSION_CODENAME"; fi
```

### DNF (Fedora)

Repositories are published per Fedora release under `rpm/fc<version>/<arch>/` (for example `rpm/fc44/x86_64/`).

Check your Fedora version:

```bash
rpm -E %fedora
```

Currently published RPMs target **Fedora 42** (RooTerm) and **Fedora 44** (ibus-sherpa-onnx, sherpa-onnx libraries).

---

## Using the APT repository

### 1. Install the signing key

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://roojs.github.io/repos/KEY.gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/roojs.gpg
sudo chmod a+r /etc/apt/keyrings/roojs.gpg
```

### 2. Add the repository

Create `/etc/apt/sources.list.d/roojs.sources` using **only the suite that matches your system**.

**Debian 13 (trixie):**

```
Types: deb
URIs: https://roojs.github.io/repos/
Suites: trixie
Components: main
Signed-By: /etc/apt/keyrings/roojs.gpg
```

**Ubuntu 25.10 (questing):**

```
Types: deb
URIs: https://roojs.github.io/repos/
Suites: questing
Components: main
Signed-By: /etc/apt/keyrings/roojs.gpg
```

**Ubuntu 26.04 (resolute):**

```
Types: deb
URIs: https://roojs.github.io/repos/
Suites: resolute
Components: main
Signed-By: /etc/apt/keyrings/roojs.gpg
```

Or copy the template and edit the `Suites:` line:

```bash
curl -fsSL https://raw.githubusercontent.com/roojs/repos/main/docs/roojs.sources \
  | sudo tee /etc/apt/sources.list.d/roojs.sources
# Edit Suites: to keep only your codename
sudo nano /etc/apt/sources.list.d/roojs.sources
```

### 3. Update and install

```bash
sudo apt update
```

Example installs:

```bash
sudo apt install ibus-sherpa-onnx    # speech-to-text IBus engine
sudo apt install ollmchat            # OLLMchat desktop app
sudo apt install rooterm             # RooTerm terminal
```

Search for available packages:

```bash
apt-cache search '' | grep -E 'ibus-sherpa|ollmchat|rooterm|roobuilder|sherpa|webkitgtk'
```

### APT troubleshooting

| Problem | What to try |
|---------|-------------|
| `NO_PUBKEY` / signature errors | Re-run the signing key step; confirm `Signed-By:` points at `/etc/apt/keyrings/roojs.gpg` |
| `404` on `apt update` | Confirm your suite name matches your OS (see table above) |
| Package not found | The upstream project may not publish a `.deb` yet, or the daily sync has not run since the release |

---

## Using the DNF repository

### 1. Install the signing key

```bash
sudo curl -fsSL https://roojs.github.io/repos/KEY.gpg \
  -o /etc/pki/rpm-gpg/RPM-GPG-KEY-roojs
```

### 2. Add the repository

Create `/etc/yum.repos.d/roojs.repo`:

```ini
[roojs]
name=roojs packages (Fedora $releasever)
baseurl=https://roojs.github.io/repos/rpm/fc$releasever/$basearch/
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=https://roojs.github.io/repos/KEY.gpg
```

Or install the template from this repository:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/roojs/repos/main/docs/roojs.repo \
  -o /etc/yum.repos.d/roojs.repo
```

`gpgcheck=0` because CI-built RPMs are not individually signed. `repo_gpgcheck=1` verifies signed repository metadata.

### 3. Update and install

```bash
sudo dnf makecache
```

Example installs:

```bash
sudo dnf install ibus-sherpa-onnx
sudo dnf install rooterm
sudo dnf install libsherpa-onnx-c-api libsherpa-onnx-c-api-devel
```

List packages from this repo:

```bash
dnf repo-pkgs roojs list
```

### DNF troubleshooting

| Problem | What to try |
|---------|-------------|
| `Status code: 404` on `dnf makecache` | No packages are published for your Fedora `$releasever` yet (check `rpm -E %fedora`) |
| GPG / repomd errors | Re-download `KEY.gpg`; confirm `gpgkey=` URL is reachable |
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
- **Upstream list:** `config/upstream-repos.json`
- **Setup guide:** [docs/setup.md](docs/setup.md)

## AI assistance

This repository was developed with the assistance of artificial intelligence.

- Requirements and direction were set by the author
- Workflow, reprepro configuration, and documentation were largely AI-generated
- The author has reviewed the overall approach and defaults, but not every line in detail
- Treat scripts and config as provisional until exercised in production
