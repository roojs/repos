# 3. OLLMchat RPMs and openSUSE FAISS

Status: proposed

Checklist: `docs/guide-to-writing-plans.md`

## Purpose

- 🔷 Long term, OLLMchat will ship RPMs. This repo must ingest them the same way it does RooTerm / sherpa.
- 🔷 Prefer nicking FAISS from openSUSE (Fedora has no `libfaiss`).
- 🔷 Do not list library deps in JSON. The script works those out.
- ℹ️ Fedora already has `llama-cpp` / `llama-cpp-devel` (ggml is inside that package).
- 🔷 llama.cpp is published quite often from the source we use on Debian. On Fedora we do not mirror it. Users get those frequent updates from Fedora itself.
- ℹ️ Tumbleweed official OSS has `libfaiss` and `faiss-devel` (current: `libfaiss-1.10.0-2.6.x86_64.rpm`).
- 🔷 Skip old Fedoras for FAISS / OLLMchat. Tumbleweed `libfaiss` needs `GLIBC_2.43` (`fc44`+).
- 🔷 ⏳ Fetch those FAISS RPMs into our DNF repo for Fedora versions that lack FAISS (`fc44` and newer).
- 🔷 ⏳ Turn on `rpm` for `OLLMchat` when that project publishes `.rpm` assets.

## Current behaviour

- ℹ️ `OLLMchat` in `config/repos.json` has no `"rpm": true`. Fetch skips it for RPM.
- ℹ️ `scripts/build-rpm-repos.sh` only accepts filenames matching `.fc([0-9]+).([^.]+).rpm`.
- ℹ️ openSUSE names are `libfaiss-1.10.0-2.6.x86_64.rpm` (no `.fc44.`).
- ℹ️ Published RPMs today: RooTerm, sherpa / ibus `fc44`.

## Will nicking Tumbleweed FAISS work

- 🔷 Preference is openSUSE, not a Fedora rebuild.
- ℹ️ Inspected `libfaiss-1.10.0-2.6.x86_64.rpm` from `https://download.opensuse.org/tumbleweed/repo/oss/x86_64/`.
- ℹ️ Requires are SONAMEs (`libstdc++.so.6`, `libgomp.so.1`, `libopenblas.so.0`), not SUSE package names. Fedora provides those.
- ℹ️ Also requires `libm.so.6(GLIBC_2.43)`. Fedora 44 has glibc 2.43. Fedora 43 is 2.42. Fedora 42 is 2.41.
- 🔷 Skip `fc42` / `fc43` for this FAISS import. No Leap snapshot, no rebuild for old Fedora.

## Config

Edits are Remove / Replace with / Add from the tree.
Verify surrounding context before applying.

### 1. `config/repos.json` — openSUSE FAISS pool (RPM only)

Why: 🔷 nick FAISS from openSUSE. JSON is the project + pool, not the dep list.

Where: `projects` array, after `OLLMchat`.

Depends on: none.

#### Add — FAISS as an RPM pool source

`rpm_pool` means fetch from that openSUSE directory instead of `gh release`.
`fedora` is the allowlist of `fc` numbers (same idea as `deb.suites`).
No `packages` list.

```json
    {
      "repo": "faiss",
      "rpm": true,
      "deb": false,
      "rpm_pool": "https://download.opensuse.org/tumbleweed/repo/oss/x86_64/",
      "fedora": [44]
    },
```

- 🔷 `fedora: [44]` and newer that still lack FAISS. Not 42 or 43.
- 💩 aarch64 pool is a second URL (`tumbleweed/repo/oss/aarch64/` or Ports). First cut can be `x86_64` only.

### 2. `config/repos.json` — `OLLMchat` RPM flag (when they publish)

Why: 🔷 this end ingests OLLMchat RPMs.

Where: the existing `OLLMchat` project object.

Depends on: OLLMchat release assets named `*.fcN.arch.rpm`.

#### Replace with

```json
    { "repo": "OLLMchat", "rpm": true },
```

## Fetch

- 🔷 Extend `scripts/fetch-upstream.sh` for `rpm_pool` the same way plan 1 extends it for Debian `pool`.
- 🔷 Seed `lib*` from that directory (`libfaiss`, `faiss-devel`). Skip `python*-faiss`.
- 🔷 Walk `rpm -qp --requires` (or the RPM header) and pull extra RPMs from the same repo if they are not already on Fedora.

### 3. `scripts/fetch-upstream.sh` — `rpm_pool` branch

Why: 🔷 nick from openSUSE. Script works out deps.

Where: in the project loop, RPM path, before `gh release view`.

Depends on: §1.

Keep — existing `repos_config_fetch_rpms` check.

Add — if `rpm_pool` is set, download seed `lib*` / `faiss-devel` from that index, walk Requires, skip GitHub.

Place files in `incoming-rpms/faiss/`.
`tag` in the index is `opensuse-tumbleweed`.

- 💩 do not follow Requires that Fedora already has (`libc.so.6`, `libstdc++.so.6`, `libopenblas.so.0`, `libgomp.so.1`). Same stop rule as plan 1 Essential / already-in-distro.

## Ingest

### 4. `scripts/build-rpm-repos.sh` — pool RPMs have no `.fcN.` in the name

Why: 🔷 openSUSE filenames will not match the current regex.

Where: the loop that parses `base` with `.fc([0-9]+).([^.]+).rpm`.

Depends on: §1 (`fedora` allowlist), §3 (index must carry dest `fc` + arch).

#### Add — if the incoming index lists `fedora` + `arch` for a file, copy to `rpm/fc${fc}/${arch}/` even when the filename has no `.fcN.`

Keep the existing filename parse for GitHub-built RPMs (RooTerm, sherpa, later OLLMchat).

## LLM notes

- Do not nick `llama-cpp` from openSUSE. Fedora already has it.
- Do not publish `python313-faiss` / `python314-faiss`.
- Do not put Tumbleweed `libfaiss` or OLLMchat RPMs on `fc42` / `fc43`.
- Do not add `noble`.
