# llama.cpp missing on Ubuntu 26.04 (resolute) after upstream-skip fix

Status: fixed (`scripts/fetch-upstream.sh` — seed exception + version-aware upstream skip)

Checklist: `docs/guide-to-writing-plans.md`

Related plan: `docs/plans/1-import-debian-pool-deps.md`

## Symptoms

- On the package catalog (`index.html`), **OLLMchat → llama.cpp rows show `—` for resolute** (Ubuntu 26.04).
- `dists/resolute/main/binary-*/Packages` on `gh-pages` has **no** `libllama0`, `libggml0`, or related pool packages.
- Other suites (trixie, plucky, questing) still show the imported stack (`10271` / `0.18.1` on amd64, etc.).
- OLLMchat itself still publishes to resolute; only the pool-imported llama stack is missing.

## Timeline

| When | What |
| ---- | ---- |
| `dd2d426` | Added `resolute` to `llama.cpp` `deb.suites` so 26.04 can get the newest pool build its libc allows (`10344` / `0.19.0` on amd64). |
| `3ec3405` | Added `pool_suite_has_package` to stop republishing packages the target suite already ships (fixes ~120-package splatter). |
| After `3ec3405` | Resolute llama rows went blank: upstream skip runs for every seed and dep, Ubuntu already publishes `libllama0` / `libggml0`, so nothing is fetched or ingested for resolute. |

## Root cause

`pool_suite_has_package` in `scripts/fetch-upstream.sh` treats “package name exists in the suite’s Ubuntu/Debian index” as “do not import”.

That is correct for **walked dependencies** (`libc6`, `libgcc-s1`, `libkrb5`, `libblas`, …).

It is **wrong for the llama stack on resolute**:

- Ubuntu ships **older** `libllama0` / `libggml0`.
- We intend to publish **newer** Debian pool builds on resolute (`10344` / `0.19.0` on amd64) because libc 2.43 allows it.
- The seed step only lists `libllama0` and `libllama-dev` from the llama.cpp pool URL; `libggml0` and backends come from the **Depends walk** (ggml pool). Both paths hit the upstream skip on resolute.

The catalog shows `—` instead of “we ship it” or “already in Ubuntu” because:

- Nothing is ingested for resolute.
- `resolute` is in `deb.suites`, so `is_default_source` in `scripts/generate-index-html.sh` does not fall back to “already in Ubuntu”.

## Why reverting the upstream skip entirely is wrong

Removing `pool_suite_has_package` from the **Depends walk** brings back the original splatter:

- Walk `Depends` / `Recommends` / `Suggests` from sid.
- Republish `libc6`, `libgcc-s1`, `libkrb5`, `libblas`, etc. into our repo.
- ~120 stale packages until prune runs; wrong in principle.

The anti-splatter fix must stay on the **dependency walk**. See **Intended fix** below.

## Intended fix

Two narrow exceptions; do **not** remove upstream skip globally.

### 1. Seed download (llama.cpp pool only)

- **Where:** first loop in `pool_fetch_into` (packages from `pool_seed_names` on the project `pool` URL).
- **Rule:** do **not** call `pool_suite_has_package` for seeds.
- **Why safe:** the llama.cpp pool directory only contains `libllama0` and `libllama-dev` (bounded set). It does not list `libc6`, `libgcc-s1`, or other system libs.
- **Effect:** `libllama0` / `libllama-dev` publish to resolute again with libc-aware version pick (`10344` amd64 when suite libc is 2.43).

### 2. Depends walk (version-aware upstream skip)

- **Where:** second loop in `pool_fetch_into` (deps of downloaded `.deb`s).
- **Keep** `pool_suite_has_package` for unpinned deps and for packages where upstream is new enough.
- **Add exception:** when the parent `Depends` uses a pinned version (`libggml0 (= 0.19.0-1)`) and the suite’s upstream version is **older** than that pin, still import from the pool.
- **Why safe:** `libc6` / `libgcc-s1` / `libblas` are not pinned `=` runtime deps of our llama packages in a way that would force re-import; they stay skipped when the suite already ships them.
- **Effect:** `libggml0` `0.19.0` and matching backends publish to resolute amd64 alongside `libllama0` `10344`.

### 3. Re-fetch when allowlisted suite was dropped

- **Where:** `pool_should_skip`.
- **Rule:** if the previous `.package-index.json` entry for the pool project has **no** package mapped to an allowlisted suite (e.g. resolute vanished after a bad publish), do not skip the pool fetch.
- **Why:** otherwise a one-off regression can leave a suite empty until `force=true`.

### 4. Catalog

- Once resolute packages are ingested, `generate-index-html.sh` shows versions under resolute automatically.
- No separate “already in Ubuntu” cell is needed for resolute when we ship newer builds.

## Verification

After fix + publish:

```bash
# Manifest includes resolute for llama pool debs
jq '.debs["llama.cpp"].packages | to_entries[] | select([.value.suites[]] | index("resolute")) | .key' \
  <(git show origin/gh-pages:.publish-manifest.json)

# Live suite index lists llama stack
git show origin/gh-pages:dists/resolute/main/binary-amd64/Packages | grep -E '^Package: lib(llama|ggml)'

# Catalog grid (resolute column not —)
curl -fsSL https://roojs.github.io/repos/index.html | grep -A5 libllama0
```

Expect on resolute amd64: `libllama0` `10344+dfsg`, `libggml0` `0.19.0`, matching `-dev` and Suggests backends.

Confirm splatter did **not** return:

```bash
git show origin/gh-pages:dists/trixie/main/binary-amd64/Packages | grep -E '^Package: (libc6|libgcc|libkrb5|libblas)'
# should print nothing
```

## LLM notes

- Do not remove `pool_suite_has_package` from the Depends walk without a narrower replacement.
- Do not add `libc6` to `pool_never_republish` only — that is already blocked; the splatter was dozens of other `lib*` packages.
- `config/repos.json` correctly lists `resolute` in `llama.cpp` `deb.suites`; do not remove it to “fix” the catalog — fix the fetch rules instead.
