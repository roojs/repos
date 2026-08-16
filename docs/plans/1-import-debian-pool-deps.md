# 1. Import Debian-pool dependencies

Status: proposed

Checklist: `docs/guide-to-writing-plans.md`

## Purpose

- 🔷 Add libfaiss and llama.cpp to this repo’s sources.
- 🔷 Extend the repository build script to hunt their Debian `.deb`s (same hunter OLLMchat already uses for older Ubuntu).
- 🔷 Import those files into our APT repo so OLLMchat deps work on suites that lack them.
- 🔷 Only apply that import to suites that need it.
- 🔷 libfaiss is already on some Ubuntus. Do not distribute it for those newer suites.
- 🔷 We do not support `noble`. Suites stay `trixie`, `plucky`, `questing`, `resolute`.
- 🔷 Do not list library dependencies in `config/repos.json`. The script works those out (llama.cpp needs `libggml*`, faiss may need `libfaiss1`).
- 🔷 llama.cpp is published quite often from the Debian pool we hunt. Expect new `.deb`s regularly. That is normal.
- ℹ️ Hunter: `/home/alan/gitlive/OLLMchat/scripts/ci/debian-pool-deb.sh`
- ℹ️ Faiss install wrapper: `/home/alan/gitlive/OLLMchat/scripts/ci/install-libfaiss-dev-debian.sh`
- ℹ️ llama.cpp fetch: `/home/alan/gitlive/OLLMchat/scripts/fetch-libllama.sh`
- 🔷 ✔️ Wire fetch + suite allowlists. Ingest is the existing reprepro path.

## Current behaviour

- ℹ️ `scripts/fetch-upstream.sh` only downloads GitHub Release assets for `roojs/<repo>`.
- ℹ️ `deb.suites` / `deb.release_tags` already limit which suites get a project.
- ℹ️ Current `apt.suites`: `trixie`, `plucky`, `questing`, `resolute`.
- ℹ️ The pool hunter already takes the newest matching `.deb`. For llama.cpp that will move often. The daily publish will commit when those hashes change.

## Suite allowlist

- 🔷 Each imported project lists the suites that receive it.
- 🔷 Suites that already have the package from Ubuntu/Debian get nothing from us.
- 🔷 No `noble` suite. Do not add it to `apt.suites`.
- 🔷 If every supported suite already has faiss, do not add a faiss project.

### Checked 16 Aug 2026

- ℹ️ faiss: `trixie`, `plucky`, `questing`, `resolute` all have `libfaiss-dev`. Omit a faiss project.
- ℹ️ `libllama0`:
  - `resolute` has it (Ubuntu universe).
  - `questing` does not.
  - `plucky` does not.
  - `trixie` does not (`libggml0` is only in `trixie-backports`).
- ℹ️ libc6 on those suites:
  - `trixie` `2.41`
  - `plucky` `2.41`
  - `questing` `2.42`
  - `resolute` `2.43`

## What broke the planned Depends walk

Stopped before coding. §4 as written would either publish uninstallable llama.cpp, or ingest sid `libc6`.

### Newest Debian llama.cpp needs glibc 2.43 — this part is recent

- ℹ️ `ggml` `0.19.0-1` uploaded **10 Aug 2026**. `Depends: libc6 (>= 2.43)`.
- ℹ️ `llama.cpp` `10344+dfsg-1` uploaded **10 Aug 2026**. Bumps ggml to 0.19.0. Same `libc6 (>= 2.43)`.
- ℹ️ Pool files from **4–5 Aug 2026** still work on older glibc:
  - `libggml0` `0.18.1-1` — `libc6 (>= 2.38)`
  - `libllama0` `10271+dfsg-1` — `libc6 (>= 2.38)`
- ℹ️ Not a llama.cpp feature change. Debian sid rebuilt them against glibc 2.43. That landed this week.
- ℹ️ The hunter always takes the newest `.deb`. Today that is the 2.43 build.
- ℹ️ Suites that lack `libllama0` (`trixie` / `plucky` / `questing`) cannot install that newest build.
- ℹ️ The one suite that can (`resolute`) already has Ubuntu’s `libllama0`. We must not republish it there.

### `Priority: required` / `essential` does not keep libc6 out — this part is not recent

- ℹ️ §4 said: stop when the dep is `Priority: required` or `essential`. That was supposed to keep `libc6` / `libstdc++6` / `libblas` out.
- ℹ️ On **Debian sid** (the index §4 actually queries):
  - `libc6` is `Priority: optional`. No `Essential: yes`.
  - `libstdc++6`, `libssl3t64`, `libblas3` are also `optional`.
- ℹ️ Same on **Debian bookworm** (2023) and **trixie**: `libc6` is already `Priority: optional`.
- ℹ️ `libc6` has not been `Essential: yes` for a long time (Debian glibc maintainers stated that years ago).
- ℹ️ **Ubuntu still marks `libc6` `Priority: required`** (`plucky`, `questing`, `resolute`).
- ℹ️ The stop might have looked true if we read Ubuntu’s `Packages`. It is false for Debian sid. Walking Depends from sid with only that stop would download sid `libc6` into our repo.

### Backends are Suggests — put them in our repo anyway

- 🔷 Follow `Suggests` (and `Recommends`) of packages we import, same libc check, same “suite already has it” stop.
- 🔷 They must be in our APT repo so `apt install libggml0-backend-vulkan` (etc.) works when OLLMchat says to try installing them. Optional. Not pulled in by `Depends` alone.
- 🔷 Skip `libggml0-backend-hip` by name. OLLMchat never installs it (breaks ROCm).
- ℹ️ `libggml0` Suggests: `libggml0-backend-blas`, `…-cuda`, `…-hip`, `…-rpc`, `…-vulkan`.
- ℹ️ Debian has no CUDA backend package. If a Suggests name is not in the pool, skip it (same as any missing dep).
- ℹ️ Backends `Depends: libggml0 (= same version)`. For plucky that is `0.18.1-1`, not `0.19.0-1`.
- ℹ️ `libggml0-backend-blas` Recommends `libopenblas0` / `libblas3`. Those suites already have them. Do not import them.

## This machine (plucky) already has llama.cpp — why it is still flagged

- ℹ️ This host is Ubuntu 25.04 `plucky`, libc6 `2.41`.
- ℹ️ Installed: `libllama0` / `libllama-dev` `9555+dfsg-1`, `libggml0` / `libggml-dev` `0.14.0-1`.
- ℹ️ Those Depends are `libc6 (>= 2.38)`. They run here. Installed around June (files dated 8–13 Jun).
- ℹ️ `apt-cache policy libllama0` shows only `/var/lib/dpkg/status`. Ubuntu plucky does not ship `libllama0`. This is a local `dpkg -i` of an older Debian pool nick (OLLMchat’s hunter), not an apt package from the suite.
- ℹ️ The flag is “the suite does not publish it”, not “this laptop lacks it”. That is the gap this repo is meant to fill, so other plucky machines can `apt install` instead of nicking by hand.
- ℹ️ Today’s newest Debian `libllama0` (`10344`, `libc6 (>= 2.43)`) would **not** install on this machine. apt would refuse. Forcing `dpkg -i` would still fail at load (`GLIBC_2.43` symbols). What is installed here is an older snapshot.

## libc: can a newer-glibc library run on an older suite?

- 🔷 No. Do not publish a `.deb` into a suite whose `libc6` is older than that `.deb`’s `Depends`.
- ℹ️ There is no Debian/Ubuntu guidance that says this is OK. The `Depends: libc6 (>= …)` is the declared GLIBC the binary was linked against. apt will not install it. The `.so` will not load if you force it.
- 🔷 Use the newest pool file whose `libc6` Depends the target suite can satisfy. If none exist, flag it as a problem and do not publish that project into that suite.

### Last Debian build that runs on this plucky (libc6 2.41) — checked 16 Aug 2026

- ℹ️ Live Debian pool currently keeps two `libllama0` amd64 builds:
  - `10344+dfsg-1` — `libc6 (>= 2.43)`, `libggml0 (>= 0.19.0)` — too new
  - `10271+dfsg-1` — `libc6 (>= 2.38)`, `libggml0 (>= 0.18.0)` — last one that fits
- ℹ️ Matching ggml:
  - `0.19.0-1` — `libc6 (>= 2.43)` — too new
  - `0.18.1-1` — `libc6 (>= 2.38)` — last one that fits (`0.18.1-1~bpo13+1` is the same libc floor)
- 🔷 So for `plucky` / `trixie` / `questing` (all libc6 `< 2.43`): import `libllama0` `10271+dfsg-1` and `libggml0` `0.18.1-1` (and their `-dev`), plus matching Suggests backends (`libggml0-backend-vulkan`, `libggml0-backend-blas`, `libggml0-backend-rpc` if present). Not today’s newest. Not hip.
- ℹ️ This machine’s installed `9555` / `0.14.0` is older than that. The pool still has `10271` / `0.18.1` and they will install here.
- ℹ️ Do not resolve those deps from current sid `Packages.xz`. That index only has `10344` / `0.19.0`. Hunt each package from its pool, newest-that-fits, same libc check.
- 🚫 snapshot.debian.org fallback. Not needed. First ingest uses the live pool (`10271` is there today). After that we keep what we published. If the live pool later has no fitting file, flag and leave the repo as-is.

### Once it is in our repo

- 🔷 After ingest, those `.deb`s live in reprepro on `gh-pages`. Incoming is deleted. They stay. We do not need to import that version again.
- 🔷 ✔️ Do not re-download the pool just because Debian published a newer build. Skip the hunt unless that newer build’s `libc6` Depends can be satisfied by an allowlisted suite.
- ℹ️ Debian llama.cpp uploads often against glibc 2.43. Our suites cannot install those. Treating “pool has something newer” as a fetch was re-downloading the world every day.
- ℹ️ The daily job still hunts, same as other projects. If it picks the same files, hashes match, nothing is committed. reprepro would also no-op (“already published”).
- 🔷 Do not replace a published fitting version with a newer Debian build the suite cannot install (`10344` onto plucky).
- 🔷 If a newer Debian build still fits that suite’s libc6, taking it is the existing “new `.deb`s are normal” behaviour.
- 🔷 If the hunt later finds no fitting file (Debian dropped `10271` from the live pool), keep what we already published. Flag. Do not remove it.

## Do not import packages the suite already has

- 🔷 Do not add a dependency to our repo if the target suite already ships that package name.
- 🔷 That is the Depends stop. Not `Priority: required` / `essential`.
- ℹ️ That keeps `libc6` / `libstdc++6` / `libssl3t64` / `libblas` out. It still pulls `libggml0` on suites that lack it.

## Config

- 🔷 ✔️ Add llama.cpp as a pool source in `config/repos.json` after the `OLLMchat` entry.
  - `pool`: `https://deb.debian.org/debian/pool/main/l/llama.cpp`
  - `deb.suites`: suites that lack `libllama0` (`trixie`, `plucky`, `questing`). Not `resolute`.
- 🔷 `pool` means fetch from the Debian pool, not `gh release`.
- 🔷 No `packages` list. No `ggml` project.
- 🔷 Omit faiss unless a supported suite is missing it. Do not invent a `noble` allowlist.

## Fetch

- 🔷 ✔️ Extend `scripts/fetch-upstream.sh`.
- ℹ️ ✔️ Copy `/home/alan/gitlive/OLLMchat/scripts/ci/debian-pool-deb.sh` to `scripts/lib/debian-pool-deb.sh` (same file).
- ℹ️ Not exercised with a full local download. First real fetch is CI.

### When a project has `pool`, do not use GitHub

- ℹ️ Today the fetch script assumes every project is a `roojs` GitHub repo. It asks `gh` for the latest release tag (e.g. `v1.2.3`), downloads that release’s `.deb`s, and writes `.package-index.json`.
- ℹ️ That JSON has a `tag` field per project. Ingest logs it (`OLLMchat@v1.2.3`). The publish manifest uses the whole index (including hashes) to decide if anything changed.
- 🔷 llama.cpp is not a GitHub repo. If the project has `pool`, download from that Debian directory instead. Do not call `gh release`.
- 🔷 Deb only. Use `apt.architectures` from config (`amd64`, `arm64`).
- 🔷 After the files are on disk, record them in `.package-index.json` the same way as GitHub projects (filename, sha256, which suites).
- 🔷 For `tag`, store the Debian version we actually imported (e.g. `10271+dfsg-1`), not a dummy string. That is what changed if we later take a newer fitting build.
- 🚫 Do not invent a `tag` value `debian-pool`. That was an LLM placeholder and means nothing.

### Walk Depends after the seed download

- 🔷 JSON only has the project + pool. The script works out lib deps.
- 🔷 Seed: every `lib*` `.deb` in that pool for the arch (e.g. `libllama0`, `libllama-dev`). Skip `python3-*`, `*-examples`, `*-tests`, `*-tools`.
- 🔷 For each downloaded `.deb`, read `Depends`, `Recommends`, and `Suggests`. Parse package names, hunt missing ones from the Debian pool (same newest-that-fits libc check as the seed). Recurse.
- 🔷 Stop walking a dep if the target suite already ships that package name, or it is not in the pool. See **Do not import packages the suite already has**.
- ℹ️ `libllama0` Depends on `libggml0`. Seeding `libllama-dev` also pulls `libggml-dev`.
- 🔷 Skip `libggml0-backend-hip` by name.

## LLM notes

- Do not add `noble` to `apt.suites` or any `deb.suites` allowlist.
- Do not add a `packages` array or a `ggml` project to `config/repos.json`.
- Do not add faiss / llama.cpp as `roojs` GitHub repos.
- Do not republish a package into a suite that already has it.
