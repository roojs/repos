# 4. Repository catalog HTML

Status: proposed

Checklist: `docs/guide-to-writing-plans.md`

## Purpose

- 🔷 Generate an HTML page that documents exactly what is in this repository.
- 🔷 That page lives on GitHub Pages (`gh-pages`), at the site root.
- 🔷 A grid of what is available where: package vs suite / Fedora.
- 🔷 Put the install instructions on that same page. One merged reference (how to add the repo, then what you can install where).
- 🔷 For referencing (what we actually publish, not a hand-written list).
- 🔷 ✔️ Emit `index.html` on `gh-pages` from the published tree.

## Current behaviour

- ℹ️ Pages serve `dists/`, `pool/`, `rpm/`, `sources`, `repo`, `key.gpg`. No package list page.
- ℹ️ Incoming indexes are deleted after ingest. Do not build the page from those.
- ℹ️ `reprepro` is only installed when the publish job actually ingests.

## Page

- 🔷 One page at the site root: `https://roojs.github.io/repos/`
- 🔷 Top: install instructions (APT, then DNF). Same steps as the README (`key.gpg`, `sources` / `repo`, `apt update` / `dnf makecache`).
- ℹ️ Commands live in `README.md` and the templates `docs/sources`, `docs/repo`.
- 💩 ✔️ Pull those command blocks from the templates when generating, so the page does not drift from the files clients already download.
- 🔷 Below that: support grids, not a flat dump of every `.deb`.
- 🔷 ✔️ Separate tables per product block (OLLMchat including llama.cpp / FAISS, WebKit, speech STT/TTS, plus RooTerm and RooBuilder).
- 🔷 ✔️ Rows: package name, with a short subtext of what it is (Packages `Description` synopsis).
- 🔷 ✔️ One table per product block. Debian, Ubuntu, and Fedora are column groups in that table, not separate tables.
- 🔷 ✔️ The “already in …” grade means the package is not required from this repo (it is already upstream in that distro).
- 🔷 ✔️ Debian columns: `trixie` (and later Debian suites). Ubuntu columns: `plucky`, `questing`, `resolute`. Fedora columns only where we still publish (`fc44` for RooTerm, sherpa, …).
- 🔷 ✔️ Version cells stay narrow: headline version only (not the packaging revision), architecture on the next line.
- 🔷 Cell is a support grade, not only a version:
  - We ship it: show the version from our repo.
  - Already upstream: we do not package it for that distro. The cell says `already in Debian` / `already in Ubuntu` / `already in Fedora` (not “default”).
  - Not available from us or from the suite: empty or a dash.
- 🔷 That grade is how we show llama.cpp on `resolute` (Ubuntu already has `libllama0`; we do not republish) vs `plucky` / `questing` / `trixie` (we import a fitting Debian build).
- 🔷 Same idea for packages we never ship because every supported suite already has them (faiss / `libfaiss-dev`). Still a row, APT cells “already in Debian/Ubuntu”, so the page can tell you to `apt install` from the distro.
- 🔷 Generate from what is on `gh-pages` after ingest:
  - APT: `dists/<suite>/main/binary-<arch>/Packages` (or `.gz`)
  - DNF: `rpm/fc<ver>/<arch>/*.rpm` filenames
- ℹ️ “We ship it” comes from those indexes. “Already in Debian/Ubuntu” is the complement of the per-project suite allowlist in `config/repos.json` (suites in `apt.suites` that are not in that project’s `deb.suites`), plus any package we omit entirely because every APT suite has it. “Already in Fedora” is for packages we skip because Fedora already ships them (llama.cpp).
- 💩 ✔️ Legend on the page so the three grades are obvious without reading this plan.
- 💩 ✔️ If both `amd64` and `arm64` exist, show the version once; architecture goes on the line below.
- 💩 ✔️ Sort packages by name inside each table. Column order: APT suites from `config/repos.json`, then Fedora numbers ascending.

## Script

Edits are Remove / Replace with / Add from the tree.
Verify surrounding context before applying.

### 1. `scripts/generate-index-html.sh` — write `index.html` from `pages/` ✔️

Why: 🔷 generated catalog, not a hand-edited table.

Where: new file. Args: pages directory, then write `pages/index.html`.

Depends on: none.

#### Add — new `scripts/generate-index-html.sh`

Read every `Packages` / `Packages.gz` under `dists/`.
For each stanza take `Package`, `Version`, `Architecture`.
Suite is the `dists/<suite>/` directory name.

For each `rpm/fc<ver>/<arch>/*.rpm` parse name, version, release from the filename.
Skip `debuginfo` / `debugsource`.

Write a single HTML file: title, APT install, DNF install, then the grid.
One grid is fine if APT and DNF columns can sit together. Two stacked grids (APT, then DNF) if that reads better.
No external CSS or JS. Deterministic output so unchanged packages do not create a noisy diff.

```bash
#!/usr/bin/env bash
set -euo pipefail

pages="${1:?pages directory required}"
out="${pages}/index.html"
```

The rest of the file is the scan + HTML write. Keep it in this script. Do not add a second helper.

## Workflow

### 2. `.github/workflows/publish-repos.yml` — generate the page on every run ✔️

Why: 🔷 the live site is the reference. First run must create `index.html` even if packages did not change.

Where: in “Sync client setup files”, after copying `sources` and `repo`.

Depends on: §1.

#### Add — after the `cp` of `docs/sources` and `docs/repo`

```yaml
          chmod +x main/scripts/generate-index-html.sh
          main/scripts/generate-index-html.sh "${GITHUB_WORKSPACE}/pages"
```

`git-auto-commit` already commits `pages/`. A new or changed `index.html` is enough to publish the catalog.

## LLM notes

- Do not build the page from `incoming-debs` / `incoming-rpms` (those are deleted).
- Do not require `reprepro` for generation (it is not installed on the unchanged path).
